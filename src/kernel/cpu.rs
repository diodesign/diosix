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
use scheduler::{self, Thread};
use platform::common::cpu::SupervisorState;
use alloc::boxed::Box;
use spin::Mutex;
use hashmap_core::map::HashMap;

/* require some help from the underlying platform */
extern "C"
{
    fn platform_cpu_private_variables() -> *mut Core;
    fn platform_cpu_heap_base() -> *mut heap::HeapBlock;
    fn platform_cpu_heap_size() -> usize;
    fn platform_save_supervisor_state(state: &SupervisorState);
    fn platform_load_supervisor_state(state: &SupervisorState);
}

/* link a running thread to its CPU core.
    we can't store this in Core because it upsets Rust's borrow checker: you can't
    deallocate Thread from a raw struct pointer. Rust won't let you hurt yourself. */
lazy_static!
{
    static ref THREADS: Mutex<Box<HashMap<usize, Thread>>> = Mutex::new(box HashMap::new());
}

/* initialize the CPU management code
   <= return number of cores present, or None for failure */
pub fn init(device_tree_buf: &u8) -> Option<usize>
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
    id: usize,
    /* each CPU core gets its own heap that it can share, but it must manage */
    pub heap: heap::Heap
}

impl Core
{
    /* intiialize a CPU core. Prepare it for running supervisor code.
    blocks until cleared to continue by the boot CPU
    => id = boot-assigned CPU core ID. this is separate from the hardware-asigned
            ID number, which may be non-linear. the runtime-generated core ID will
            run from zero to N-1 where N is the number of available cores */
    pub fn init(id: usize)
    {
        /* the pre-kmain startup code has allocated space for per-CPU core variables.
        this function returns a pointer to that structure */
        let cpu = Core::this();

        /* stash our runtime-assigned CPU id and set up our heap */
        unsafe
        {
            (*cpu).id = id;
            (*cpu).heap.init(platform_cpu_heap_base(), platform_cpu_heap_size());
        }
    }

    /* return pointer to the calling CPU core's fixed private data structure */
    pub fn this() -> *mut Core { return unsafe { platform_cpu_private_variables() } }
    /* return boot-assigned ID number */
    pub fn id() -> usize { unsafe { (*Core::this()).id } }
}

/* save current thread's context, if we're running one, and load next thread's context.
this should be called from an IRQ context as it preserves the interrupted code's context
and overwrites the context with the next thread's context, so returning to supervisor
mode will land us in the new context */
pub fn context_switch(next: Thread)
{
    let id = Core::id();
    match THREADS.lock().remove(&id)
    {
        Some(current_thread) =>
        {
            /* if we're running a thread, copy its state */
            platform::common::cpu::save_supervisor_state(current_thread.get_state_as_ref());
            /* and queue it on the waiting list */
            scheduler::queue_thread(current_thread);
        },
        None =>
        {
            /* if we were not running a thread then ensure we return to supervisor mode
            rather than hypervisor mode */
            platform::common::cpu::prep_supervisor_return();
        }
    }

    /* prepare next thread to run when we leave this IRQ context */
    platform::common::cpu::load_supervisor_state(next.get_state_as_ref());
    THREADS.lock().insert(id, next); /* add to the running threads list */
}
