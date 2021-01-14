/* diosix hypervisor's physical CPU core management
 *
 * (c) Chris Williams, 2019-2021.
 *
 * See LICENSE for usage and copying.
 */

/* Physical CPUs get their own private heaps to manage. Crucially, allocated memory
blocks can be shared by other CPUs. Any CPU can free any block, returning
it to its owner's heap pool. When allocating, a CPU can only draw from
its own heap, reusing any blocks freed by itself or other cores.

The hypervisor layer is unlikely to do much active allocation
so it's OK to keep it really simple for now. */

use super::lock::Mutex;
use hashbrown::hash_map::HashMap;
use platform::physmem::PhysMemSize;
use platform::cpu::{SupervisorState, CPUFeatures};
use platform::timer;
use super::vcore::{VirtualCore, VirtualCoreCanonicalID};
use super::scheduler::ScheduleQueues;
use super::capsule::{self, CapsuleID, CapsuleState};
use super::message;
use super::heap;

/* physical CPU core IDs and count */
pub type PhysicalCoreID = usize;
pub type PhysicalCoreCount = PhysicalCoreID;

pub const BOOT_PCORE_ID: PhysicalCoreID = 0;
const PCORE_MAGIC: usize = 0xc001c0de;

/* require some help from the underlying platform */
extern "C"
{
    fn platform_cpu_private_variables() -> &'static mut PhysicalCore;
    fn platform_cpu_heap_base() -> *mut heap::HeapBlock;
    fn platform_cpu_heap_size() -> PhysMemSize;
    fn platform_save_supervisor_state(state: &SupervisorState);
    fn platform_load_supervisor_state(state: &SupervisorState);
}

lazy_static!
{
    /* map running virtual CPU cores to physical CPU cores, and vice-versa
    we can't store these in Core structs because it upsets Rust's borrow checker.
    note: PCORES keeps track of the last physical CPU core to run a given virtual
    core. this is more of a hint than a concrete guarantee: the virtual core
    may have been scheduled away, though it should be in the last physical
    CPU core's scheduling queue. */
    static ref VCORES: Mutex<HashMap<PhysicalCoreID, VirtualCore>> = Mutex::new(HashMap::new());
    static ref PCORES: Mutex<HashMap<VirtualCoreCanonicalID, PhysicalCoreID>> = Mutex::new(HashMap::new());
}

/* describe a physical CPU core - this structure is stored in the per-CPU private variable space.
   this is below the per-CPU machine-level stack */
#[repr(C)]
pub struct PhysicalCore
{
    /* this magic word is used to make sure the CPU's stack hasn't overflowed
    and corrupted this adjacent structure */
    magic: usize,

    /* every physical CPU core has a hardware-assigned ID number that may be non-linear,
    while the startup code assigns each core a linear ID number from zero. we keep a copy of that
    linear runtime-assigned ID here. the hardware-assigned ID is not used in the portable code */
    id: PhysicalCoreID,

    /* platform-defined bitmask of ISA features this core provides. if a virtual core has a features bit set that
    is unset in a physical core's feature bitmask, the virtual core will not be allowed to run on that physical core */
    features: CPUFeatures,

    /* each physical CPU core gets its own heap that it can share, but it must manage its own */
    pub heap: heap::Heap,

    /* each physical CPU gets its own set of queues of virtual CPU cores to schedule */
    queues: ScheduleQueues,

    /* can this run guest operating systems? or is it a system management core? true if it can run
    supervisor-mode code, false if not */
    smode: bool,

    /* set when this physical core CPU core last ran a scheduling decision */
    timer_sched_last: Option<timer::TimerValue>
}

impl PhysicalCore
{
    /* intiialize a physical CPU core. Prepare it for running supervisor code.
    => id = diosix-assigned CPU core ID at boot time. this is separate from the hardware-assigned
            ID number, which may be non-linear. the runtime-generated core ID will
            run from zero to N-1 where N is the number of available cores */
    pub fn init(id: PhysicalCoreID)
    {
        /* the pre-hvmain startup code has allocated space for per-CPU core variables.
        this function returns a pointer to that structure */
        let mut cpu = PhysicalCore::this();

        cpu.magic = PCORE_MAGIC;
        cpu.id = id;
        cpu.features = platform::cpu::features();
        cpu.smode = platform::cpu::features_priv_check(platform::cpu::PrivilegeMode::Supervisor);
        cpu.timer_sched_last = None;

        let (heap_ptr, heap_size) = PhysicalCore::get_heap_config();
        cpu.heap.init(heap_ptr, heap_size);
      
        cpu.queues = ScheduleQueues::new();

        /* create a mailbox for messages from other cores */
        message::create_mailbox(id);
    }

    /* return pointer to the calling CPU core's fixed private data structure */
    pub fn this() -> &'static mut PhysicalCore
    {
        unsafe { platform_cpu_private_variables() }
    }

    /* return Ok if magic hasn't been overwritten, or the overwrite value as an error code */
    pub fn integrity_check() -> Result<(), usize>
    {
        match PhysicalCore::this().magic
        {
            PCORE_MAGIC => Ok(()),
            other => Err(other)
        }
    }

    /* return CPU heap base and size set aside by the pre-hvmain boot code */
    fn get_heap_config() -> (*mut heap::HeapBlock, PhysMemSize)
    {
        unsafe { (platform_cpu_heap_base(), platform_cpu_heap_size()) }
    }

    /* return boot-assigned ID number */
    pub fn get_id() -> PhysicalCoreID { PhysicalCore::this().id }

    /* return features bitmask */
    pub fn get_features() -> CPUFeatures { PhysicalCore::this().features }

    /* return a structure describing this core */
    pub fn describe() -> platform::cpu::CPUDescription { platform::cpu::CPUDescription }

    /* return a virtual CPU core awaiting to run on this physical CPU core */
    pub fn dequeue() -> Option<VirtualCore>
    {
        PhysicalCore::this().queues.dequeue()
    }

    /* move a virtual CPU core onto this physical CPU's queue of virtual cores to run */
    pub fn queue(to_queue: VirtualCore)
    {
        PhysicalCore::this().queues.queue(to_queue)
    }

    /* return true if able to run supervisor code. a system management core
    that cannot or is not expected to run guest workloads should return false */
    pub fn smode_supported() -> bool
    {
        PhysicalCore::this().smode
    }

    /* return ID of capsule of the virtual CPU core this physical CPU core is running, or None for none */
    pub fn get_capsule_id() -> Option<CapsuleID>
    {
        if let Some(vcore) = VCORES.lock().get(&PhysicalCore::get_id())
        {
            Some(vcore.get_capsule_id())
        }
        else
        {
            None
        }
    }

    /* update the running virtual core's timer IRQ target. we have to do this here because
    the virtual core is held in a locked data structure. leaving this function relocks
    the structure. it's unsafe to access the vcore struct */
    pub fn set_virtualcore_timer_target(target: Option<timer::TimerValue>)
    {
        if let Some(vcore) = VCORES.lock().get_mut(&(PhysicalCore::get_id()))
        {
            vcore.set_timer_irq_at(target);
        }
    }

    /* get the virtual core's timer IRQ target */
    pub fn get_virtualcore_timer_target() -> Option<timer::TimerValue>
    {
        if let Some(vcore) = VCORES.lock().get_mut(&(PhysicalCore::get_id()))
        {
            return vcore.get_timer_irq_at();
        }
        None
    }

    /* return canonical ID for the virtual core running in the capsule on this CPU, if any */
    pub fn get_virtualcore_id(&self) -> Option<VirtualCoreCanonicalID>
    {
        let cid = match PhysicalCore::get_capsule_id()
        {
            Some(id) => id,
            None => return None
        };

        let vid = match VCORES.lock().get(&PhysicalCore::get_id())
        {
            Some(vcore) => vcore.get_id(),
            None => return None
        };

        Some(VirtualCoreCanonicalID
        {
            capsuleid: cid,
            vcoreid: vid
        })
    }

    /* set the exact per-CPU timer value of the last time this physical core make a scheduling decision */
    pub fn set_timer_sched_last(&mut self, value: Option<timer::TimerValue>)
    {
        self.timer_sched_last = value;
    }

    /* get the exact per-CPU timer value of the last time this physical core make a scheduling decision */
    pub fn get_timer_sched_last(&mut self) -> Option<timer::TimerValue>
    {
        self.timer_sched_last
    }
}

/* save current virtual CPU core's context, if we're running one, and load next virtual core's context.
this should be called from an IRQ context as it preserves the interrupted code's context
and overwrites the context with the next virtual core's context, so returning to supervisor
mode will land us in the new context */
pub fn context_switch(next: VirtualCore)
{
    let next_capsule = next.get_capsule_id();
    let pcore_id = PhysicalCore::get_id();

    /* find what this physical core was running, if anything */
    match VCORES.lock().remove(&pcore_id)
    {
        Some(current_vcore) =>
        {
            let current_capsule = current_vcore.get_capsule_id();

            /* if we're switching to a virtual CPU core in another capsule then replace the
            current hardware access permissions so that we're only allowing access to the RAM assigned
            to the next capsule to run */
            if current_capsule != next_capsule
            {
                capsule::enforce(next_capsule);
            }

            /* queue the current virtual core on the waiting list.
               however, if the vcore's capsule is dying or restarting then
               don't queue the core for later use, and drop it */
            if capsule::get_state(current_capsule) == Some(CapsuleState::Valid)
            {
                platform::cpu::save_supervisor_state(current_vcore.state_as_ref());
                PhysicalCore::queue(current_vcore);
            }
        },
        None =>
        {
            /* if we were not running a virtual CPU core then ensure we return to supervisor mode
            rather than hypervisor mode */
            platform::cpu::prep_supervisor_return();
            /* and enforce its hardware access permissions */
            capsule::enforce(next_capsule);
        }
    }

    /* prepare next virtual core to run when we leave this IRQ context */
    platform::cpu::load_supervisor_state(next.state_as_ref());

    /* link next virtual core and capsule to this physical CPU */
    PCORES.lock().insert(VirtualCoreCanonicalID
        {
            vcoreid: next.get_id(),
            capsuleid: next_capsule
        },
        pcore_id);

    /* and add the virtual core to the running virtual cores list */
    VCORES.lock().insert(pcore_id, next);
}
