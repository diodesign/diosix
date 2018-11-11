/* RISC-V 32-bit hardware-specific code for managing physical memory
 *
 * (c) Chris Williams, 2018.
 *
 * See LICENSE for usage and copying.
 */

use devicetree;

/* formalize return codes from assembly functions */
enum PhysMemResult
{
  Success = 0,
  Failure = 1
}

/* use Check to ensure we're not pushing over the page stack limit.
   use Increment to increment the page stack limit (during initialization only) */
enum PhysMemStackLimit
{
  Check = 0,
  Increment = 1
}

/* we need this code from the assembly files */
extern
{
  fn platform_physmem_set_ram_size(size: u64);
  fn platform_physmem_get_kernel_area() -> (u32, u32);
  fn platform_pgstack_push(addr: usize, action: PhysMemStackLimit) -> PhysMemResult;
}

/* minimum amount of RAM allowed before boot (4MB). also enforce a max amount of ram.
   RV32 supports SV32 (32-bit) physical addresses aka 4GB max. we subtract one from
   the max because you can't fit 4GiB in a 32-bit number.

   a thought: if most RV32/SV32 systems map physical memory in at 0x80000000, that leaves only
   enough physical memory map space for 2GiB anyway */
const MIN_RAM_SIZE: u64 = 4 * 1024 * 1024;
const MAX_RAM_SIZE: u64 = (4 * 1024 * 1024 * 1024) - 1;

/* smallest kernel page size (4KiB) */
const PAGE_SIZE: u64 = 4 * 1024;

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
    None => return None
  };

  /* get the physical start and end addresses of the kernel */
  let (phys_kernel_start, phys_kernel_end) = unsafe { platform_physmem_get_kernel_area() };
  /* calculate maximum footprint of memory required to hold kernel and payload code and data,
     and CPU stack(s) and physical page stack(s). it's assumed this is held in a contiguous
     block of physical memory after boot. each page stack entry represents a 4KiB page,
     and takes up 4 bytes. round foorprint up to next 4KiB page boundary */
  let footprint = (((phys_kernel_end - phys_kernel_start) as u64 +
                   ((total_phys_bytes / PAGE_SIZE) * 4)) & !(PAGE_SIZE as u64 - 1))
                   + PAGE_SIZE as u64;

  /* enforce minimum and maximums for RAM. also if there isn't enough to hold the kernel
     then bail out. */
  if total_phys_bytes < MIN_RAM_SIZE || total_phys_bytes < footprint
  {
    return None; /* fail system with not enough memory */
  }
  if total_phys_bytes > MAX_RAM_SIZE
  {
    total_phys_bytes = MAX_RAM_SIZE;
  }

  /* tell the underlying system of the max memory size */
  unsafe { platform_physmem_set_ram_size(total_phys_bytes) };
  /* keep a running total of physical memory allocated in a page stack */
  let mut phys_mem_stacked = 0;

  /* scan over all of contiguous physical memory, 4KB at a time, from the end of the
     kernel's footptint. the footprint includes kernel and payload code, data,
     CPU stack(s), variables page, and space for the physical page stack(s) */
  let mut addr = phys_kernel_start as u64 + footprint;
  loop
  {
    /* stack physical page frame address if not reserved. allow limit to increase
       as we push physical page frame addresses onto the stack */
    match unsafe { platform_pgstack_push(addr as usize, PhysMemStackLimit::Increment) }
    {
      /* bail out on failure */
      PhysMemResult::Failure => return None,
      _ => {}
    };

    /* keep running tally of memory stacked */
    phys_mem_stacked = phys_mem_stacked + PAGE_SIZE as usize;

    /* move onto next page until all done */
    addr = addr + PAGE_SIZE as u64;
    if addr > (phys_kernel_start as u64 + total_phys_bytes)
    {
      break;
    }
  }

  return Some(phys_mem_stacked);
}
