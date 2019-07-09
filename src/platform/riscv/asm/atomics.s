# diosix low-level atomic primitives for RV32G/RV64G targets
#
# (c) Chris Williams, 2019.
# See LICENSE for usage and copying.

.section .sshared
.align 4

.global platform_acquire_spin_lock
.global platform_release_spin_lock
.global platform_compare_and_swap
.global platform_aq_compare_and_swap
.global platform_cpu_wait

# kernel constants, such as stack and lock locations
.include "src/platform/riscv/asm/consts.s"

# See section 7.3 of https://content.riscv.org/wp-content/uploads/2017/05/riscv-spec-v2.2.pdf
# for a description of RISC-V's atomic operations.

# acquire_spin_lock
# Acquire a simple lock or spin while waiting.
# Lock is considered 32-bit wide for RV32 or 64-bit for RV64
# => a0 = memory address of spin lock to acquire
# <= returns when lock acquired, blocks otherwise
# Corrupts t0
platform_acquire_spin_lock:
  li    t0, 1                   # writing 1 to the lock will acquire it
acquire_attempt:
.if ptrwidth == 32
  amoswap.w.aq t0, t0, (a0)     # atomically swap t0 and 32-bit word at a0
.else
  amoswap.d.aq t0, t0, (a0)     # atomically swap t0 and 64-bit word at a0
.endif
  bnez  t0, acquire_attempt     # if lock was already held, then try again
  ret                           # return on success

# release_spin_lock
# Release a simple 32/64-bit lock that we've already held
# => a0 = memory address of spin lock to release
platform_release_spin_lock:
.if ptrwidth == 32
  amoswap.w.rl  x0, x0, (a0)    # release 32-bit lock by atomically writing 0 to it
.else
  amoswap.d.rl  x0, x0, (a0)    # release 64-bit lock by atomically writing 0 to it
.endif
  ret

# platform_compare_and_swap
# Atomically replace pointed-to word with new value if it equals the expected value.
# Word is 32-bit wide on RV32 or 64-bit on RV64 
# return the value of the word prior to any update
# => a0 = pointer to word to compare
#    a1 = expected value of word
#    a2 = new value of word 
# <= a0 = pre-update value of word (if it equals expected value then update was made)
platform_compare_and_swap:
.if ptrwidth == 32
  lr.w      t0, (a0)                        # atomically fetch current 32-bit value
.else
  lr.d      t0, (a0)                        # atomically fetch current 64-bsit value
.endif
  bne       t0, a1, cas_fail                # if it's not expected then bail out
.if ptrwidth == 32
  sc.w      t1, a2, (a0)                    # store new 32-bit value and release address
.else
  sc.d      t1, a2, (a0)                    # store new 64-bit value and release address
.endif
  bnez      t1, platform_compare_and_swap   # if atomic store failed (t1 != 0) then try again
  add       a0, a1, x0                      # return expected pre-store contents of word
  ret

# same as platform_compare_and_swap but enforces aquire memory ordering.
# acquire ordering means no following memory ops can be observed to take place
# before the lr completes, ie: don't reorder post-lr mem ops before the lr
platform_aq_compare_and_swap:
.if ptrwidth == 32
  lr.w.aq   t0, (a0)                          # atomically fetch current 32-bit value
.else
  lr.d      t0, (a0)                          # atomically fetch current 64-bit value
.endif
  bne       t0, a1, cas_fail                  # if it's not expected then bail out
.if ptrwidth == 32
  sc.w      t1, a2, (a0)                      # store new 32-bit value and release address
.else
  sc.d      t1, a2, (a0)                      # store new 64-bit value and release address
.endif
  bnez      t1, platform_aq_compare_and_swap  # if atomic store failed (t1 != 0) then try again
  add       a0, a1, x0                        # return expected pre-store contents of word
  ret

# return non-expected value 
cas_fail:
  add   a0, t0, x0    # return unexpected pre-store contents of word
  ret

# platform_cpu_wait aka must-keep NOP
platform_cpu_wait:
  add   x0, a0, x0
  ret
