# kernel low-level entry point
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

# _start *must* be the first routine in this file
.section .entry
.global _start

# physical memory map on initialization
# 0x20000000 - 0x3FFFFFFF: 512M of flash
# 0x80000000 - 0x8001FFFF: 128K of RAM

.equ KERNEL_STACK_TOP, 0x80020000

# the boot ROM drops us here with nothing setup
# this code is assumed to be loaded and running at 0x20400000
# set up a stack and call the main kernel code
#
# => a0 = hart ID
#    a1 = pointer to device tree
# <= never returns
#
_start:
  li sp, KERNEL_STACK_TOP
  call kmain

# infinite loop if we somehow end up here
loop:
  j loop
