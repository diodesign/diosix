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
    static __supervisor_shared_start: u8;
    static __supervisor_shared_end: u8;
    static __supervisor_data_start: u8;
    static __supervisor_data_end: u8;
}

/* minimum amount of RAM allowed before boot (4MiB). this is a sanity check for
the hardware configuration, and can be changed later. also the hardware allows up
to 2GB of physical RAM. don't go over this. */
const MIN_RAM_SIZE: usize = 4 * 1024 * 1024;
const MAX_RAM_SIZE: usize = 2 * 1024 * 1024 * 1024;

/* assumes RAM starts at 0x80000000 */
const PHYS_RAM_BASE: usize = 0x80000000;

/* total bytes detected in the system, total available, and total used by hypervisor */
static mut PHYS_MEM_TOTAL: usize = 0;
static mut PHYS_MEM_FOOTPRINT: usize = 0;

/* each CPU has a fix memory overhead, allocated during boot */
static PHYS_MEM_PER_CPU: usize = 1 << 18; /* 256KB. see ../asm/const.s */

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

    /* enforce minimum and maximums for RAM. we can't deal with more than 2G of RAM.
    also if there isn't enough to hold the kernel and its structures and payload, then bail out. */
    if total_phys_bytes < MIN_RAM_SIZE || total_phys_bytes < footprint
    {
        return None; /* fail system with not enough memory */
    }
    if total_phys_bytes > MAX_RAM_SIZE
    {
        total_phys_bytes = MAX_RAM_SIZE;
    }

    /* record size of physical RAM. Write to this once, here, to avoid data write races */
    unsafe
    {
        PHYS_MEM_TOTAL = total_phys_bytes;
        PHYS_MEM_FOOTPRINT = footprint;
    }

    return Some(total_phys_bytes - footprint);
}

/* return the (start address, end address) of the shared supervisor kernel code in physical memory.
shared in that there is code common to the supervisor and kernel that can be shared. in effect,
this shared code appears in the supervisor's read-only code region but can be used by the hypervisor, too. */
pub fn builtin_supervisor_code() -> (usize, usize)
{
    /* derived from the .sshared linker section */
    let supervisor_start: usize = unsafe { transmute(&__supervisor_shared_start) };
    let supervisor_end: usize = unsafe { transmute(&__supervisor_shared_end) };
    return (supervisor_start, supervisor_end);
}

/* return the (start address, end address) of the builtin supervisor's private static read-write data
in physical memory */
pub fn builtin_supervisor_data() -> (usize, usize)
{
    /* derived from the .sdata linker section */
    let supervisor_start: usize = unsafe { transmute(&__supervisor_data_start) };
    let supervisor_end: usize = unsafe { transmute(&__supervisor_data_end) };
    return (supervisor_start, supervisor_end);
}

/* return (start, end) addresses of physical RAM available for allocating to supervisors */
pub fn allocatable_ram() -> (usize, usize)
{
    unsafe { (PHYS_RAM_BASE + PHYS_MEM_FOOTPRINT, PHYS_RAM_BASE + PHYS_MEM_TOTAL) }
}