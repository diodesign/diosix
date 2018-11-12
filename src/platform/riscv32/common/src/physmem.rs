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
extern "C" {
    fn platform_physmem_set_ram_size(size: usize);
    fn platform_physmem_get_kernel_start() -> usize;
    fn platform_physmem_get_kernel_end() -> usize;
    fn platform_pgstack_push(addr: usize, action: PhysMemStackLimit) -> PhysMemResult;
}

/* minimum amount of RAM allowed before boot (1MiB). this is somewhat arbitrary, may change
later. it's more of a sanity check right now for the hardware environment. */
const MIN_RAM_SIZE: usize = 1 * 1024 * 1024;

/* smallest kernel page size (4KiB) */
const PAGE_SIZE: usize = 4 * 1024;

/* initialize physical memory management
set up page stacks(s). Call only from boot CPU!
=> device_tree_buf = device tree to parse
<= number of bytes found total, or None for error */
pub fn init(device_tree_buf: &u8) -> Option<usize>
{
    /* in future, we can be fancy with per-cpu stacks or NUMA domains. for now, create
    a basic single page stack for all of physical memory and all cores to share.
    improve this later if we need to support NUMA / many-core RV32 SoCs */
    let mut total_phys_bytes = match devicetree::get_ram_size(device_tree_buf)
    {
        Some(b) => b & !(PAGE_SIZE - 1), /* round down to whole 4KB pages, skip spare bytes if any */
        None => return None,
    };

    /* get the physical start and end addresses of the entire kernel: its code, data,
    CPU stack(s), static global variables, and payload */
    let phys_kernel_start = unsafe { platform_physmem_get_kernel_start() };
    let phys_kernel_end = unsafe { platform_physmem_get_kernel_end() };

    /* calculate maximum footprint of memory required to hold kernel and payload code and data,
    and CPU stack(s) and physical page stack(s). it's assumed this is held in a contiguous
    block of physical memory after boot. each page stack entry represents a 4KiB page,
    and takes up 4 bytes. round foorprint up to next 4KiB page boundary */
    let footprint = (((phys_kernel_end - phys_kernel_start)
        + ((total_phys_bytes / PAGE_SIZE) * 4))
        & !(PAGE_SIZE - 1))
        + PAGE_SIZE;

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

    /* tell the underlying system of the max memory size */
    unsafe { platform_physmem_set_ram_size(total_phys_bytes) };
    /* keep a running total of physical memory allocated in a page stack */
    let mut phys_mem_stacked = 0;

    /* scan over all of contiguous physical memory, 4KB at a time, from the end of the
    kernel's footptint. the footprint includes kernel and payload code, data,
    CPU stack(s), variables page, and space for the physical page stack(s) */
    let mut addr = phys_kernel_start + footprint;
    loop
    {
        /* stack physical page frame address if not reserved. allow limit to increase
        as we push physical page frame addresses onto the stack */
        if unsafe { platform_pgstack_push(addr, PhysMemStackLimit::Increment) }
            != PhysMemResult::Success
        {
            /* bail out on failure */
            return None;
        }

        /* keep running tally of memory stacked */
        phys_mem_stacked = phys_mem_stacked + PAGE_SIZE;

        /* move onto next page until all done */
        addr = addr + PAGE_SIZE;
        if addr > (phys_kernel_start + total_phys_bytes)
        {
            break;
        }
    }

    return Some(phys_mem_stacked);
}
