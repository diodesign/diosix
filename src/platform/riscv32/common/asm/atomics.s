# kernel low-level atomic primitives for RV32G targets
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

.section .text
.global platform_acquire_spin_lock
.global platform_release_spin_lock

# include kernel constants, such as stack and lock locations
.include "src/platform/riscv32/common/asm/consts.s"

# See section 7.3 of https://content.riscv.org/wp-content/uploads/2017/05/riscv-spec-v2.2.pdf
# for a description of RISC-V's atomic operations.

# acquire_spin_lock
# Acquire a simple lock or spin while waiting
# => a0 = memory address of spin lock to acquire
# <= returns when lock acquired, blocks otherwise
# Corrupts t0
platform_acquire_spin_lock:
  li    t0, 1                   # writing 1 to the lock will acquire it
acquire_attempt:
  amoswap.w.aq t0, t0, (a0)     # atomically swap t0 and word at a0
  bnez  t0, acquire_attempt     # if lock was already held, then try again
  ret                           # return on success

# release_spin_lock
# Release a simple lock that we've already held
# => a0 = memory address of spin lock to release
platform_release_spin_lock:
  amoswap.w.rl  x0, x0, (a0)    # release lock by atomically writing 0 to it
  ret
