/* RISC-V 32-bit hardware-specific code for managing physical memory
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

use devicetree;

/* formalize return codes from assembly functions */
#[repr(u32)]
#[derive(PartialEq)]
enum PhysMemResult
{
    Success = 0,
}

/* use Check to ensure we're not pushing over the page stack limit.
use Increment to increment the page stack limit (during initialization only) */
#[repr(u32)]
enum PhysMemStackLimit
{
    Check = 0,
    Increment = 1,
}

/* we need this code from the assembly files */
extern "C"
{
    fn platform_set_phys_mem_size(bytes: usize);
    fn platform_physmem_get_kernel_start() -> usize;
    fn platform_physmem_get_kernel_end() -> usize;
    fn platform_bitmap_clear_word(index: usize) -> bool;
    fn platform_bitmap_set_bit(index: usize) -> bool;
}

/* minimum amount of RAM allowed before boot (32MiB). this is a sanity check for
the hardware environment, and can be changed later */
const MIN_RAM_SIZE: usize = 32 * 1024 * 1024;

/* assumes RAM starts at 0x80000000 */
const PHYS_RAM_BASE: usize = 0x80000000;

/* initialize global physical memory management - call only from boot CPU!
=> device_tree_buf = device tree to parse
<= number of non-kernel bytes found total, or None for error */
pub fn init(device_tree_buf: &u8) -> Option<usize>
{
    /* get this system's vital statistics */
    let mut total_phys_bytes = match devicetree::get_ram_size(device_tree_buf)
    {
        Some(b) => b,
        None => return None
    };

    /* get the physical start and end addresses of the entire statically allocated kernel:
    its code, data, global variables, and payload */
    let phys_kernel_start = unsafe { platform_physmem_get_kernel_start() };
    let phys_kernel_end = unsafe { platform_physmem_get_kernel_end() };

    /* calculate kernel's maximum physical memory footprint in bytes */
    let footprint = phys_kernel_end - phys_kernel_start;

    /* enforce minimum and maximums for RAM. also if there isn't enough to hold the kernel
    and its structures and payload, then bail out. */
    if total_phys_bytes < MIN_RAM_SIZE || total_phys_bytes < footprint
    {
        return None; /* fail system with not enough memory */
    }
    if total_phys_bytes > <usize>::max_value()
    {
        total_phys_bytes = <usize>::max_value();
    }

    /* record size of physical RAM */
    unsafe { platform_set_phys_mem_size(total_phys_bytes) };

    return Some(total_phys_bytes - footprint);
}
