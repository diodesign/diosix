# kernel low-level atomic primitives
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

.section .text
.global platform_acquire_debug_spin_lock
.global platform_release_debug_spin_lock

# include page zero locations
.include "src/platform/riscv32/qemu32_virt/asm/page_zero.s"

# See section 7.3 of https://content.riscv.org/wp-content/uploads/2017/05/riscv-spec-v2.2.pdf
# for a description of RISC-V's atomic operations.

# acquire_spin_lock
# Acquire a simple lock or spin while waiting
# => a0 = memory address of spin lock to acquire
# <= returns when lock acquired, blocks otherwise
acquire_spin_lock:
  li    t0, 1                   # writing 1 to the lock will acquire it
acquire_attempt:
  amoswap.w.aq t0, t0, (a0)     # atomically swap t0 and word at a0
  bnez  t0, acquire_attempt     # if lock was already held, then try again
  ret                           # return on success

# release_spin_lock
# Release a simple lock that we've already held
# => a0 = memory address of spin lock to release
release_spin_lock:
  amoswap.w.rl x0, x0, (a0)     # release lock by atomically writing 0 to it
  ret

# Acquire a spin lock to write to the serial debug port
# Blocks until we're clear to write to the serial port
platform_acquire_debug_spin_lock:
  # preserve return address
  addi  sp, sp, -4
  sw    ra, (sp)

  li    a0, KERNEL_DEBUG_SPIN_LOCK
  call  acquire_spin_lock

  # restore return address
  lw    ra, (sp)
  addi  sp, sp, 4
  ret

# Release a spin lock after writing to the serial debug port
platform_release_debug_spin_lock:
  # preserve return address
  addi  sp, sp, -4
  sw    ra, (sp)

  li    a0, KERNEL_DEBUG_SPIN_LOCK
  call  release_spin_lock

  # restore return address
  lw    ra, (sp)
  addi  sp, sp, 4
  ret
