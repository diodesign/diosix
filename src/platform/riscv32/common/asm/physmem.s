# kernel low-level physical memory management
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

.section .text
.global platform_set_phys_mem_size
.global platform_physmem_get_kernel_start
.global platform_physmem_get_kernel_end

# include kernel constants, such as stack and lock locations
.include "src/platform/riscv32/common/asm/consts.s"

# keep a note of the number of physical RAM bytes
# => a0 = total number of physical RAM bytes
# <= corrupts t0, t1
platform_set_phys_mem_size:
  la    t1, __kernel_globals_page_base
  sw    a0, KERNEL_PHYS_MEMORY_SIZE(t1)
  ret

# return in a0 the start of the kernel, its static structures and payload in physical RAM,
# as defined by the linker script
platform_physmem_get_kernel_start:
  la    a0, __kernel_start
  ret
# return in a0, the end of the kernel, its static structures and payload in physical RAM
# as defined by the linker script
platform_physmem_get_kernel_end:
  la    a0, __kernel_end
  ret
