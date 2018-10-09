# kernel low-level entry point
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

# _start *must* be the first routine in this file
.section .entry
.global _start

# handy for debugging with qemu -d in_asm
.global infinite_loop

# physical memory map on initialization
# 0x20000000 - 0x3FFFFFFF: 512M of flash
# 0x80000000 - 0x80003FFF: 16K of RAM

# run the stack down from the top of RAM
.equ KERNEL_STACK_TOP, 0x80004000

# the boot ROM drops us here with nothing setup
# this code is assumed to be loaded and running at 0x20400000
# set up a stack and call the main kernel code
#
# => a0 = hart ID
#    a1 = pointer to device tree
# <= nothing else for kernel to do
_start:
  li sp, KERNEL_STACK_TOP
  call kmain

# nowhere else to go, so: infinite loop
infinite_loop:
  j infinite_loop
