/* RISC-V 32-bit hardware-specific code for managing physical memory
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

use devicetree;

/* we need this code from the assembly files */
extern "C"
{
    fn platform_physmem_get_kernel_start() -> usize;
    fn platform_physmem_get_kernel_end() -> usize;
}

/* minimum amount of RAM allowed before boot (4MiB). this is a sanity check for
the hardware environment, and can be changed later */
const MIN_RAM_SIZE: usize = 4 * 1024 * 1024;

/* assumes RAM starts at 0x80000000 */
const PHYS_RAM_BASE: usize = 0x80000000;

/* total bytes detected in the system, and total available */
static mut PHYS_MEM_TOTAL: usize = 0;
static mut PHYS_MEM_USABLE: usize = 0;

/* each CPU has a fix memory overhead, allocated during boot */
static PHYS_MEM_PER_CPU: usize = 1 << 18; /* see ../asm/const.s */
static mut PHYS_CPU_COUNT: usize = 0;

/* initialize global physical memory management - call only from boot CPU!
=> device_tree_buf = device tree to parse
<= number of non-kernel bytes usable, or None for error */
pub fn init(device_tree_buf: &u8) -> Option<usize>
{
    /* get this system's vital statistics */
    let mut total_phys_bytes = match devicetree::get_ram_size(device_tree_buf)
    {
        Some(b) => b,
        None => return None
    };
    let mut cpu_count = match devicetree::get_cpu_count(device_tree_buf)
    {
        Some(c) => c,
        None => return None
    };

    /* get the physical start and end addresses of the entire statically allocated kernel:
    its code, data, global variables, and payload */
    let phys_kernel_start = unsafe { platform_physmem_get_kernel_start() };
    let phys_kernel_end = unsafe { platform_physmem_get_kernel_end() };

    /* calculate kernel's maximum physical memory footprint in bytes */
    let footprint = (phys_kernel_end - phys_kernel_start) +
                    (cpu_count * PHYS_MEM_PER_CPU);

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

    /* record size of physical RAM. Write to this once, here, to avoid data races */
    unsafe
    {
        PHYS_MEM_TOTAL = total_phys_bytes;
        PHYS_MEM_USABLE = total_phys_bytes - footprint;
    }

    return Some(total_phys_bytes - footprint);
}
