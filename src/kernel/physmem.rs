/* diosix machine kernel physical memory management
 *
 * This allocates physical memory to CPU cores to use for private stacks + heaps
 * It also allocates contiguous physical memory to supervisor kernels
 * 
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

use lock::Mutex;

/* platform-specific code must implement all this */
use platform;

static mut PHYS_TREE: Option<Mutex<SupervisorPhysRegion>> = None;

/* describe a supervisor kernel's physical memory region */
struct SupervisorPhysRegion
{
    base: usize,
    size: usize
}

/* intiialize the physical memory management.
   called once by the boot CPU core.
   Make no assumptions about the underlying hardware.
   the platform-specific code could set up per-CPU or
   per-NUMA domain page stacks, etc.
   we simply initialize the system, and then request
   and return physical pages as necessary.
   => device_tree_buf = pointer to device tree to parse
   <= number of bytes available, or None for failure
*/
pub fn init(device_tree_buf: &u8) -> Option<usize>
{
    let phys_mem_size = match platform::common::physmem::init(device_tree_buf)
    {
        Some(s) => s,
        None => return None
    };

    return Some(phys_mem_size);
}