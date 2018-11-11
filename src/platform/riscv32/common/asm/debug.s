# kernel low-level debug routines RV32G targets
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

.section .text
.global platform_acquire_debug_spin_lock
.global platform_release_debug_spin_lock

# include kernel constants, such as stack and lock locations
.include "src/platform/riscv32/common/asm/consts.s"

# Acquire a spin lock to write to the serial debug port
# Blocks until we're clear to write to the serial port
# <= a0 = 0 for success (it's corrupted otherwise)
platform_acquire_debug_spin_lock:
  # preserve return address
  addi  sp, sp, -4
  sw    ra, (sp)

  la    t0, __kernel_top_page_base
  addi  a0, t0, KERNEL_DEBUG_SPIN_LOCK
  call  platform_acquire_spin_lock

  # restore return address
  lw    ra, (sp)
  addi  sp, sp, 4
  # return with success
  li    a0, 0
  ret

# Release a spin lock after writing to the serial debug port
# <= a0 = 0 for success (it's corrupted otherwise)
platform_release_debug_spin_lock:
  # preserve return address
  addi  sp, sp, -4
  sw    ra, (sp)

  la    t0, __kernel_top_page_base
  addi  a0, t0, KERNEL_DEBUG_SPIN_LOCK
  call  platform_release_spin_lock

  # restore return address
  lw    ra, (sp)
  addi  sp, sp, 4
  # return with success
  li    a0, 0
  ret
