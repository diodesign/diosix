/* diosix top-level code for handling physical memory
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

/* notes: the physical memory manager's job is to allocate memory
on a per-page basis to supervisor-level code. */

/* platform-specific code must implement all this */
use platform;

/* intiialize the physical memory management
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
    return platform::common::physmem::init(device_tree_buf);
}
