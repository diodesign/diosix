# diosix RV32G/RV64G low-level serial output code for Qemu Virt compatible platforms
#
# (c) Chris Williams, 2019.
# See LICENSE for usage and copying.

.section .text
.global platform_serial_write_byte

# Write a byte to the serial port
# => a0 = byte to write out to the serial port
#    a1 = address of serial port
# <= corrupts t0 
platform_serial_write_byte:
  # this is way too powerful a function. rein in the serial port
  # only allow certain addreses be accessed from this function
  li    t0, 0x1001ffff
  and   t0, t0, a1
  sb    a0, (t0)
  ret
