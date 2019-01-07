/* RISC-V 32-bit hardware-specific code for managing physical memory
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

use csr::CSR;
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

/* allowed physical memory access permissions */
pub enum AccessPermissions
{
    Read,
    ReadWrite,
    ReadExecute,
    NoAccess
}

/* minimum amount of RAM allowed before boot (4MiB). this is a sanity check for
the hardware configuration, and can be changed later. also the hardware allows up
to 2GB of physical RAM. don't go over this. */
const MIN_RAM_SIZE: usize = 4 * 1024 * 1024;
const MAX_RAM_SIZE: usize = 2 * 1024 * 1024 * 1024;

/* assumes RAM starts at 0x80000000 */
const PHYS_RAM_BASE: usize = 0x80000000;

/* there are a maximum number of physical memory regions */
const PHYS_PMP_MAX_REGIONS: usize = 8;
/* PMP access flags */
const PHYS_PMP_READ: usize  = 1 << 0;
const PHYS_PMP_WRITE: usize = 1 << 1;
const PHYS_PMP_EXEC: usize  = 1 << 2;
const PHYS_PMP_TOR: usize   = 1 << 3;

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

/* create a per-CPU physical memory region and apply access permissions to it. if the region already exists, overwrite it.
each region is a RISC-V physical memory protection (PMP) area. we pair up PMP addresses in TOR (top of range) mode. eg, region 0
uses pmp0cfg and pmp1cfg in pmpcfg0 for start and end, region 1 uses pmp1cfg and pmp2cfg in pmpcfg0.
   => regionid = ID number of the region to create or update
      base, end = start and end addresses of region
      access = access permissions for the region
   <= true for success, or false for failure */
pub fn protect(regionid: usize, base: usize, end: usize, access: AccessPermissions) -> bool
{
    if regionid > PHYS_PMP_MAX_REGIONS { return false; }

    let accessbits = PHYS_PMP_TOR | match access
    {
        AccessPermissions::Read => PHYS_PMP_READ,
        AccessPermissions::ReadWrite => PHYS_PMP_READ | PHYS_PMP_WRITE,
        AccessPermissions::ReadExecute => PHYS_PMP_READ | PHYS_PMP_EXEC,
        AccessPermissions::NoAccess => 0
    };

    /* select the appropriate pmpcfg bits from the region ID */
    let pmpcfg_reg = regionid >> 1;
    let shift = ((regionid - (pmpcfg_reg << 1)) << 4) + 8;
    
    /* only update the access bits for the end address, leaving the base access bits at zero.
    according to the specification, only the end address access bits are checked */
    let mask = 0xff << shift;
    let cfgbits = read_pmpcfg(pmpcfg_reg) & !mask;
    write_pmpcfg(pmpcfg_reg, cfgbits | (accessbits << shift));

    /* program in the base and end addesses */
    write_pmpaddr(regionid * 2, base);
    write_pmpaddr((regionid * 2) + 1, end);

    return true;
}

/* read the value of the given PMP configuration register (pmpcfg0-3).
warning: silently fails with a zero on bad read */
fn read_pmpcfg(register: usize) -> usize
{
    match register
    {
        0 => read_csr!(CSR::Pmpcfg0),
        1 => read_csr!(CSR::Pmpcfg1),
        2 => read_csr!(CSR::Pmpcfg2),
        3 => read_csr!(CSR::Pmpcfg3),
        _ => 0
    }
}

/* write value to the given PMP configuration register (pmpcfg0-3). warning: silently fails */
fn write_pmpcfg(register: usize, value: usize)
{
    match register
    {
        0 => write_csr!(CSR::Pmpcfg0, value),
        1 => write_csr!(CSR::Pmpcfg1, value),
        2 => write_csr!(CSR::Pmpcfg2, value),
        3 => write_csr!(CSR::Pmpcfg3, value),
        _ => ()
    };
}

/* write value to the given PMP address register (pmpaddr0-15). warning: silently fails */
fn write_pmpaddr(register: usize, value: usize)
{
    match register
    {
        0 => write_csr!(CSR::Pmpaddr0, value),
        1 => write_csr!(CSR::Pmpaddr1, value),
        2 => write_csr!(CSR::Pmpaddr2, value),
        3 => write_csr!(CSR::Pmpaddr3, value),
        4 => write_csr!(CSR::Pmpaddr4, value),
        5 => write_csr!(CSR::Pmpaddr5, value),
        6 => write_csr!(CSR::Pmpaddr6, value),
        7 => write_csr!(CSR::Pmpaddr7, value),
        8 => write_csr!(CSR::Pmpaddr8, value),
        9 => write_csr!(CSR::Pmpaddr9, value),
        10 => write_csr!(CSR::Pmpaddr10, value),
        11 => write_csr!(CSR::Pmpaddr11, value),
        12 => write_csr!(CSR::Pmpaddr12, value),
        13 => write_csr!(CSR::Pmpaddr13, value),
        14 => write_csr!(CSR::Pmpaddr14, value),
        15 => write_csr!(CSR::Pmpaddr15, value),
        _ => ()
    };
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