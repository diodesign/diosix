# kernel low-level atomic memory code for 32-bit SiFive U34 hardware series
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

.section .text
.global platform_acquire_debug_spin_lock
.global platform_release_debug_spin_lock

# this is a non-SMP system, so being single core, allow all locks to succeed
# Return zero in a0 to indicate automatic success
platform_acquire_debug_spin_lock:
platform_release_debug_spin_lock:
  add a0, x0, x0
  ret
