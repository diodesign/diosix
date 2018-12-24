/* RISC-V 32-bit hardware-specific code for managing physical memory
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

use core::intrinsics::transmute;
use devicetree;
use cpu;

/* we need this code from the assembly files */
extern "C"
{
    /* linker symbols */
    static __kernel_start: u8;
    static __kernel_end: u8;
    static __supervisor_code_start: u8;
    static __supervisor_code_end: u8;
    static __supervisor_data_start: u8;
    static __supervisor_data_end: u8;
}

/* minimum amount of RAM allowed before boot (4MiB). this is a sanity check for
the hardware environment, and can be changed later */
const MIN_RAM_SIZE: usize = 4 * 1024 * 1024;

/* assumes RAM starts at 0x80000000 */
const PHYS_RAM_BASE: usize = 0x80000000;

/* total bytes detected in the system, total available, and total used by hypervisor */
static mut PHYS_MEM_TOTAL: usize = 0;
static mut PHYS_MEM_USABLE: usize = 0;
static mut PHYS_MEM_FOOTPRINT: usize = 0;

/* each CPU has a fix memory overhead, allocated during boot */
static PHYS_MEM_PER_CPU: usize = 1 << 18; /* see ../asm/const.s */

/* initialize global physical memory management - call only from boot CPU!
   call after CPU management has initialized.
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
    let cpu_count = match cpu::nr_of_cores()
    {
        Some(c) => c,
        None => return None
    };

    /* get the physical start and end addresses of the entire statically allocated kernel:
    its code, data, global variables, and payload */
    let phys_kernel_start: usize = unsafe { transmute(&__kernel_start) };
    let phys_kernel_end : usize = unsafe { transmute(&__kernel_end) };

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
        PHYS_MEM_FOOTPRINT = footprint;
    }

    return Some(total_phys_bytes - footprint);
}

/* return the (start address, end address) of the builtin supervisor kernel code in physical memory */
pub fn builtin_supervisor_code() -> (usize, usize)
{
    let supervisor_start: usize = unsafe { transmute(&__supervisor_code_start) };
    let supervisor_end: usize = unsafe { transmute(&__supervisor_code_end) };
    return (supervisor_start, supervisor_end);
}

/* return the (start address, end address) of the builtin supervisor kernel code in physical memory */
pub fn builtin_supervisor_data() -> (usize, usize)
{
    let supervisor_start: usize = unsafe { transmute(&__supervisor_data_start) };
    let supervisor_end: usize = unsafe { transmute(&__supervisor_data_end) };
    return (supervisor_start, supervisor_end);
}
