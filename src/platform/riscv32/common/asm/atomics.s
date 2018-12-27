# kernel low-level atomic primitives for RV32G targets
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

.section .text
.global platform_acquire_spin_lock
.global platform_release_spin_lock
.global platform_compare_and_swap
.global platform_aq_compare_and_swap
.global platform_cpu_wait

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

# platform_compare_and_swap
# Atomically replace pointed-to word with new value if it equals the expected value.
# return the value of the word prior to any update
# => a0 = pointer to word to compare
#    a1 = expected value of word
#    a2 = new value of word 
# <= a0 = pre-update value of word (if it equals expected value then update was made)
platform_compare_and_swap:
  lr.w      t0, (a0)                        # atomically fetch current value
  bne       t0, a1, cas_fail                # if it's not expected then bail out
  sc.w      t1, a2, (a0)                    # store new value and release address
  bnez      t1, platform_compare_and_swap   # if atomic store failed (t1 != 0) then try again
  add       a0, a1, x0                      # return expected pre-store contents of word
  ret

# same as platform_compare_and_swap but enforces aquire memory ordering.
# acquire ordering means no following memory ops can be observed to take place
# before the lr completes, ie: don't reorder post-lr mem ops before the lr
platform_aq_compare_and_swap:
  lr.w.aq   t0, (a0)
  bne       t0, a1, cas_fail
  sc.w      t1, a2, (a0)
  bnez      t1, platform_aq_compare_and_swap
  add       a0, a1, x0
  ret

# return non-expected value 
cas_fail:
  add   a0, t0, x0                      # return unexpected pre-store contents of word
  ret

# platform_cpu_wait aka must-keep NOP
platform_cpu_wait:
  add   x0, a0, x0
  ret
