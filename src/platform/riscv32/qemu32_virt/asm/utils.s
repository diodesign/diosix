# kernel low-level utility code for Qemu Virt hardware environment
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

.section .text
.global platform_get_cpu_id

# Look up the running core's ID
# <= a0 = CPU core / hart ID
platform_get_cpu_id:
  csrrc a0, mhartid, x0
  ret
