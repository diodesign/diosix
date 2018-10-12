# kernel low-level entry point for the Qemu Virt (RV32) platform
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

# _start *must* be the first routine in this file
.section .entry
.global _start

# handy for debugging with qemu -d in_asm
.global infinite_loop

# hardware physical memory map
# 0x00000000, size: 0x100:     Debug ROM/data
# 0x00001000, size: 0x11000:   Boot ROM
# 0x00100000, size: 0x1000:    Hardware test area
# 0x02000000, size: 0x10000:   CLINT (Core Local Interruptor)
# 0x0c000000, size: 0x4000000: PLIC (Platform Level Interrupt Controller)
# 0x10000000, size: 0x100:     UART 0
# 0x10001000, size: 0x1000:    Virtual IO
# 0x80000000: DRAM base (default 128MB, min 16MB)

# kernel DRAM layout, before device tree is probed
# 0x80000000: Page zero
#             0 = global CPU spin lock (32b)
#             4 = debug spin lock (32b)
# 0x80001000: kernel load + start address
# 0x81000000: kernel boot stack (16MB mark)

.equ KERNEL_CPU_SPIN_LOCK,    0x80000000
.equ KERNEL_BOOT_STACK_TOP,   0x81000000

# the boot ROM drops us here with nothing setup
# this code is assumed to be loaded and running at 0x80001000
# set up a stack and call the main kernel code.
# we assume we have 16MB or more of DRAM fitted. this means the kernel and
# and its initialization payload is expected to fit within this space.
#
# => a0 = hart ID
#    a1 = pointer to device tree
# <= nothing else for kernel to do
_start:


  li sp, KERNEL_BOOT_STACK_TOP
  call kmain

# nowhere else to go, so: infinite loop
infinite_loop:
  j infinite_loop

#
