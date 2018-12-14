# kernel low-level physical memory management
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

.section .text
.global platform_physmem_get_kernel_start
.global platform_physmem_get_kernel_end

# include kernel constants, such as stack and lock locations
.include "src/platform/riscv32/common/asm/consts.s"

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
