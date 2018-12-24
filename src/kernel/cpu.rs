/* diosix machine kernel's CPU core management
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

/* CPUs get their own private heaps to manage. Crucially, allocated memory
blocks can be shared by other CPUs. Any CPU can free any block, returning
it to its owner's heap pool. When allocating, a CPU can only draw from
its own heap, reusing any blocks freed by itself or other cores.

The machine/hypervisor layer is unlikely to do much active allocation
so it's OK to keep it really simple for now. */
use heap;

/* require some help from the underlying platform */
extern "C"
{
    fn platform_cpu_private_variables() -> *mut Core;
    fn platform_cpu_heap_base() -> *mut heap::HeapBlock;
    fn platform_cpu_heap_size() -> usize;
}

/* initialize the CPU management code
   <= return number of cores present, or None for failure */
pub fn init(device_tree_buf: &u8) -> Option<usize>
{
    return platform::common::cpu::init(device_tree_buf);
}

/* describe a CPU core - this structure is stored in the per-CPU private variable space */
#[repr(C)]
pub struct Core
{
    /* each CPU core gets its own heap that it can share, but it must manage */
    pub heap: heap::Heap,
}

impl Core
{
    /* intiialize a CPU core. Prepare it for running supervisor code.
    blocks until cleared to continue by the boot CPU */
    pub fn init()
    {
        /* the pre-kmain startup code has allocated space for per-CPU core variables.
        this function returns a pointer to that structure */
        let cpu = Core::this();

        /* initialize private heap */
        unsafe { (*cpu).heap.init(platform_cpu_heap_base(), platform_cpu_heap_size()); }
    }

    /* return pointer to the calling CPU core's fixed private data structure */
    pub fn this() -> *mut Core { return unsafe { platform_cpu_private_variables() } }
}
