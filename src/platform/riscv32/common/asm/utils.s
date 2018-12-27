# kernel low-level utility code for RV32G targets
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

.section .text
.align 4

.global platform_get_cpu_id
.global platform_cpu_private_variables
.global platform_cpu_heap_base
.global platform_cpu_heap_size

# include kernel constants, such as stack and lock locations
.include "src/platform/riscv32/common/asm/consts.s"

# Look up the running core's ID
# <= a0 = CPU core / hart ID
platform_get_cpu_id:
  csrrc a0, mhartid, x0
  ret

# return pointer to this CPU's private variables
# <= a0 = pointer to kernel's CPU structure
platform_cpu_private_variables:
  # get base of private variables from top of IRQ stack, held in mscratch
  csrrs a0, mscratch, x0
  ret

# return base address of this CPU's heap - right above private vars 
# <= a0 = pointer to heap base (corrupts t0)
platform_cpu_heap_base:
  csrrs a0, mscratch, x0  # private vars start above CPU IRQ stack
  li    t0, KERNEL_CPU_PRIVATE_VARS_SIZE
  add   a0, a0, t0
  ret

# return total empty size of this CPU's heap area
# <= a0 = heap size in bytes
platform_cpu_heap_size:
  li  a0, KERNEL_CPU_HEAP_AREA_SIZE
  ret
