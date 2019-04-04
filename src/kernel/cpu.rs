/* diosix machine kernel's physical CPU core management
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

/* Physical CPUs get their own private heaps to manage. Crucially, allocated memory
blocks can be shared by other CPUs. Any CPU can free any block, returning
it to its owner's heap pool. When allocating, a CPU can only draw from
its own heap, reusing any blocks freed by itself or other cores.

The machine/hypervisor layer is unlikely to do much active allocation
so it's OK to keep it really simple for now. */

use heap;
use scheduler::ScheduleQueues;
use platform::common::cpu::{SupervisorState, features_mask, CPUFeatures};
use alloc::boxed::Box;
use spin::Mutex;
use hashmap_core::map::{HashMap, Entry};
use container::{self, ContainerID};
use physmem::PhysMemSize;
use thread::Thread;

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

/* map running threads to their CPU cores. 
   we can't store these in Core structs because it upsets Rust's borrow checker: you can't
   deallocate Thread from a raw struct pointer. Rust won't let you hurt yourself. */
lazy_static!
{
    static ref THREADS: Mutex<Box<HashMap<CPUId, Thread>>> = Mutex::new(box HashMap::new());
}

/* initialize the CPU management code
   <= return number of cores present, or None for failure */
pub fn init(device_tree_buf: &u8) -> Option<CPUCount>
{
    return platform::common::cpu::init(device_tree_buf);
}

/* describe a physical CPU core - this structure is stored in the per-CPU private variable space */
#[repr(C)]
pub struct Core
{
    /* every physical CPU core has a hardware-assigned ID number that may be non-linear,
    while the startup code assigns each core a linear ID number from zero. we keep a copy of that
    linear, runtime-assigned ID here. the hardware-assigned ID is not used in the portable code */
    id: CPUId,

    /* platform-defined bitmask of ISA features this core provides. if a thread has a features bit set that
    is unset in a core's feature bitmask, the thread will not be allowed to run on that core */
    features: CPUFeatures,

    /* each CPU core gets its own heap that it can share, but it must manage */
    pub heap: heap::Heap,

    /* each CPU gets its own set of supervisor thread schedule queues */
    queues: ScheduleQueues
}

impl Core
{
    /* intiialize a CPU core. Prepare it for running supervisor code.
    blocks until cleared to continue by the boot CPU
    => id = boot-assigned CPU core ID. this is separate from the hardware-asigned
            ID number, which may be non-linear. the runtime-generated core ID will
            run from zero to N-1 where N is the number of available cores */
    pub fn init(id: CPUId)
    {
        /* the pre-kmain startup code has allocated space for per-CPU core variables.
        this function returns a pointer to that structure */
        let cpu = Core::this();

        /* initialize this CPU core */
        unsafe
        {
            (*cpu).id = id;
            (*cpu).features = features_mask();
            (*cpu).heap.init(platform_cpu_heap_base(), platform_cpu_heap_size());
            (*cpu).queues = ScheduleQueues::new();
        }
    }

    /* return ID of container of the thread this CPU core is running, or None for none */
    pub fn container() -> Option<ContainerID>
    {
        match THREADS.lock().entry(Core::id())
        {
            Entry::Vacant(_) => None,
            Entry::Occupied(value) =>
            {
                Some(value.get().container())
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

    /* return a thread awaiting to run on this CPU core */
    pub fn dequeue() -> Option<Thread>
    {
        unsafe { (*Core::this()).queues.dequeue() }
    }

    /* move a thread onto this CPU's queue of threads */
    pub fn queue(to_queue: Thread)
    {
        unsafe { (*Core::this()).queues.queue(to_queue) }
    }
}

/* save current thread's context, if we're running one, and load next thread's context.
this should be called from an IRQ context as it preserves the interrupted code's context
and overwrites the context with the next thread's context, so returning to supervisor
mode will land us in the new context */
pub fn context_switch(next: Thread)
{
    let next_container = next.container();
    let id = Core::id();

    match THREADS.lock().remove(&id)
    {
        Some(current_thread) =>
        {
            /* if we're running a thread, preserve its state */
            platform::common::cpu::save_supervisor_state(current_thread.state_as_ref());

            /* if we're switching to a thread in another container then replace the
            hardware access permissions */
            if current_thread.container() != next_container
            {
                container::enforce(next_container);
            }

            /* queue current thread on the waiting list */
            Core::queue(current_thread);
        },
        None =>
        {
            /* if we were not running a thread then ensure we return to supervisor mode
            rather than hypervisor mode */
            platform::common::cpu::prep_supervisor_return();
            /* and enforce its hardware access permissions */
            container::enforce(next_container);
        }
    }

    /* prepare next thread to run when we leave this IRQ context */
    platform::common::cpu::load_supervisor_state(next.state_as_ref());
    THREADS.lock().insert(id, next); /* add to the running threads list */
}
