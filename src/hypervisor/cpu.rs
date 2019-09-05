/* diosix hypervisor's physical CPU core management
 *
 * (c) Chris Williams, 2019.
 *
 * See LICENSE for usage and copying.
 */

/* Physical CPUs get their own private heaps to manage. Crucially, allocated memory
blocks can be shared by other CPUs. Any CPU can free any block, returning
it to its owner's heap pool. When allocating, a CPU can only draw from
its own heap, reusing any blocks freed by itself or other cores.

The hypervisor layer is unlikely to do much active allocation
so it's OK to keep it really simple for now. */

use super::heap;
use super::scheduler::ScheduleQueues;
use platform::cpu::{SupervisorState, CPUFeatures};
use spin::Mutex;
use hashbrown::hash_map::{HashMap, Entry};
use super::capsule::{self, CapsuleID};
use platform::physmem::PhysMemSize;
use super::vcore::VirtualCore;
use alloc::string::String;

/* physical CPU core IDs and count */
pub type CPUId = usize;
pub type CPUCount = CPUId;

pub const BOOT_CPUID: CPUId = 0;

/* require some help from the underlying platform */
extern "C"
{
    fn platform_cpu_private_variables() -> *mut Core;
    fn platform_cpu_heap_base() -> *mut heap::HeapBlock;
    fn platform_cpu_heap_size() -> PhysMemSize;
    fn platform_save_supervisor_state(state: &SupervisorState);
    fn platform_load_supervisor_state(state: &SupervisorState);
}

/* map running virtual CPU cores to physical CPU cores. 
   we can't store these in Core structs because it upsets Rust's borrow checker */
lazy_static!
{
    static ref VCORES: Mutex<HashMap<CPUId, VirtualCore>> = Mutex::new(HashMap::new());
}

/* initialize the CPU management code
   <= return number of cores present, or None for failure */
pub fn init(device_tree_buf: &u8) -> Option<CPUCount>
{
    return platform::cpu::init(device_tree_buf);
}

/* describe a physical CPU core - this structure is stored in the per-CPU private variable space */
#[repr(C)]
pub struct Core
{
    /* every physical CPU core has a hardware-assigned ID number that may be non-linear,
    while the startup code assigns each core a linear ID number from zero. we keep a copy of that
    linear, runtime-assigned ID here. the hardware-assigned ID is not used in the portable code */
    id: CPUId,

    /* platform-defined bitmask of ISA features this core provides. if a virtual core has a features bit set that
    is unset in a physical core's feature bitmask, the virtual core will not be allowed to run on that physical core */
    features: CPUFeatures,

    /* each physical CPU core gets its own heap that it can share, but it must manage */
    pub heap: heap::Heap,

    /* each physical CPU gets its own set of queues of virtual CPU cores to schedule */
    queues: ScheduleQueues
}

impl Core
{
    /* intiialize a physical CPU core. Prepare it for running supervisor code.
    => id = diosix-assigned CPU core ID at boot time. this is separate from the hardware-asigned
            ID number, which may be non-linear. the runtime-generated core ID will
            run from zero to N-1 where N is the number of available cores */
    pub fn init(id: CPUId)
    {
        /* NOTE: avoid calling hvlog/hvdebug here as debug channels have not been initialized yet */

        /* the pre-hvmain startup code has allocated space for per-CPU core variables.
        this function returns a pointer to that structure */
        let cpu = Core::this();

        /* initialize this CPU core */
        unsafe
        {
            (*cpu).id = id;
            (*cpu).features = platform::cpu::features();
            (*cpu).heap.init(platform_cpu_heap_base(), platform_cpu_heap_size());
            (*cpu).queues = ScheduleQueues::new();
        }
    }

    /* return ID of capsule of the virtual CPU core this physical CPU core is running, or None for none */
    pub fn capsule() -> Option<CapsuleID>
    {
        match VCORES.lock().entry(Core::id())
        {
            Entry::Vacant(_) => None,
            Entry::Occupied(value) =>
            {
                Some(value.get().capsule())
            }
        }
    }

    /* return pointer to the calling CPU core's fixed private data structure */
    pub fn this() -> *mut Core
    { 
        unsafe { platform_cpu_private_variables() }
    }

    /* return boot-assigned ID number */
    pub fn id() -> CPUId
    {
        unsafe { (*Core::this()).id }
    }

    /* return features bitmask */
    pub fn features() -> CPUFeatures
    {
        unsafe { (*Core::this()).features }
    }

    /* return string describing this core */
    pub fn describe() -> String
    {
        let mut descr = String::new();
        for s in platform::cpu::describe()
        {
            descr.push_str(s);
        }

        return descr;
    }

    /* return a virtual CPU core awaiting to run on this physical CPU core */
    pub fn dequeue() -> Option<VirtualCore>
    {
        unsafe { (*Core::this()).queues.dequeue() }
    }

    /* move a virtual CPU core onto this physical CPU's queue of virtual cores to run */
    pub fn queue(to_queue: VirtualCore)
    {
        unsafe { (*Core::this()).queues.queue(to_queue) }
    }
}

/* save current virtual CPU core's context, if we're running one, and load next virtual core's context.
this should be called from an IRQ context as it preserves the interrupted code's context
and overwrites the context with the next virtual core's context, so returning to supervisor
mode will land us in the new context */
pub fn context_switch(next: VirtualCore)
{
    let next_capsule = next.capsule();
    let id = Core::id();

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
            if current_vcore.capsule() != next_capsule
            {
                capsule::enforce(next_capsule);
            }

            /* queue the current virtual core on the waiting list */
            Core::queue(current_vcore);
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
    VCORES.lock().insert(id, next); /* add to the running virtual cores list */
}
