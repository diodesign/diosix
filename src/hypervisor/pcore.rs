/* diosix hypervisor's physical CPU core management
 *
 * (c) Chris Williams, 2019-2020.
 *
 * See LICENSE for usage and copying.
 */

/* Physical CPUs get their own private heaps to manage. Crucially, allocated memory
blocks can be shared by other CPUs. Any CPU can free any block, returning
it to its owner's heap pool. When allocating, a CPU can only draw from
its own heap, reusing any blocks freed by itself or other cores.

The hypervisor layer is unlikely to do much active allocation
so it's OK to keep it really simple for now. */

use spin::Mutex;
use hashbrown::hash_map::HashMap;
use platform::physmem::PhysMemSize;
use platform::cpu::{SupervisorState, CPUFeatures};
use super::vcore::{VirtualCore, VirtualCoreID, VirtualCoreCanonicalID};
use super::scheduler::ScheduleQueues;
use super::capsule::{self, CapsuleID};
use super::message;
use super::heap;

/* physical CPU core IDs and count */
pub type PhysicalCoreID = usize;
pub type PhysicalCoreCount = PhysicalCoreID;

pub const BOOT_PCORE_ID: PhysicalCoreID = 0;

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

/* when performing an action on behalf of a less-privileged mode, using information from
that mode, know who to blame for any faults -- the less-privileged mode */
#[derive(Clone, Copy)]
pub enum Blame
{
    Supervisor,
    Hypervisor
}

/* describe a physical CPU core - this structure is stored in the per-CPU private variable space */
#[repr(C)]
pub struct PhysicalCore
{
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

    /* the next fault that comes in will be blamed on this privilege mode */
    blame: Blame
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

        cpu.id = id;
        cpu.features = platform::cpu::features();
        cpu.smode = platform::cpu::features_priv_check(platform::cpu::PrivilegeMode::Supervisor);

        let (heap_ptr, heap_size) = PhysicalCore::get_heap_config();
        cpu.heap.init(heap_ptr, heap_size);
      
        cpu.queues = ScheduleQueues::new();

        /* create a mailbox for messages from other cores */
        message::create_mailbox(id);

        cpu.blame = Blame::Hypervisor; /* blame hypervisor by default */
    }

    /* return pointer to the calling CPU core's fixed private data structure */
    pub fn this() -> &'static mut PhysicalCore
    {
        unsafe { platform_cpu_private_variables() }
    }

    /* return CPU heap base and size set aside by the pre-hvmain boot code */
    fn get_heap_config() -> (*mut heap::HeapBlock, PhysMemSize)
    {
        unsafe { (platform_cpu_heap_base(), platform_cpu_heap_size()) }
    }

    /* return boot-assigned ID number */
    pub fn get_id() -> PhysicalCoreID
    {
        PhysicalCore::this().id
    }

    /* return features bitmask */
    pub fn get_features() -> CPUFeatures
    {
        PhysicalCore::this().features
    }

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

    /* return ID for the virtual core running on this CPU, if any */
    pub fn get_virtualcore_id() -> Option<VirtualCoreID>
    {
        if let Some(vcore) = VCORES.lock().get(&PhysicalCore::get_id())
        {
            Some(vcore.get_id())
        }
        else
        {
            None
        }
    }

    /* allow us to define who to blame when a fault comes in */
    pub fn blame(to_blame: Blame) { PhysicalCore::this().blame = to_blame; }
    pub fn blame_who() -> Blame { PhysicalCore::this().blame }
}

/* save current virtual CPU core's context, if we're running one, and load next virtual core's context.
this should be called from an IRQ context as it preserves the interrupted code's context
and overwrites the context with the next virtual core's context, so returning to supervisor
mode will land us in the new context */
pub fn context_switch(next: VirtualCore)
{
    let next_capsule = next.get_capsule_id();
    let id = PhysicalCore::get_id();

    /* find what this physical core was running, if anything */
    match VCORES.lock().remove(&id)
    {
        Some(current_vcore) =>
        {
            /* if we're running a virtual CPU core, preserve its state */
            platform::cpu::save_supervisor_state(current_vcore.state_as_ref());

            /* if we're switching to a virtual CPU core in another capsule then replace the
            current hardware access permissions so that we're only allowing access to the RAM assigned
            to the next capsule to run */
            if current_vcore.get_capsule_id() != next_capsule
            {
                capsule::enforce(next_capsule);
            }

            /* queue the current virtual core on the waiting list */
            PhysicalCore::queue(current_vcore);
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

    /* link virtual core and capsule to this physical CPU */
    PCORES.lock().insert(VirtualCoreCanonicalID
        {
            vcoreid: next.get_id(),
            capsuleid: next_capsule
        },
        id);

    /* and add the virtual core to the running virtual cores list */
    VCORES.lock().insert(id, next);
}
