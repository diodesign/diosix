# kernel low-level atomic primitives
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

.section .text
.global spin_lock

# See section 7.2 of https://content.riscv.org/wp-content/uploads/2017/05/riscv-spec-v2.2.pdf
# for description of RISC-V's atomic operations.

# Compare
# => a0 = byte to write out to the serial port
spin_lock:
  ret
