# kernel low-level serial output code for Qemu Virt hardware platform
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

.section .text
.global platform_serial_write_byte

.equ SERIAL_TX, 0x10000000

# Write a byte to the serial port
# => a0 = byte to write out to the serial port
platform_serial_write_byte:
  li t0, SERIAL_TX
  sb a0, (t0)
  ret
