# kernel low-level entry point for the SiFive U34 (RV32) platform
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

# _start *must* be the first routine in this file
.section .entry
.global _start

# hardware physical memory map
# 0x00000000, size: 0x100:     Debug ROM/data
# 0x00001000, size: 0x11000:   Boot ROM
# 0x00100000, size: 0x1000:    SiFive SoC test area
# 0x02000000, size: 0x10000:   CLINT (Core Local Interruptor)
# 0x0c000000, size: 0x4000000: PLIC (Platform Level Interrupt Controller)
# 0x10013000, size: 0x1000:    UART 0
# 0x10023000, size: 0x1000:    UART 1
# 0x100900FC, size: 0x2000:    Cadence GEM ethernet controller
# 0x80000000: DRAM base (default 128MB, max 8GB, min 16MB)

# kernel DRAM layout, before device tree is probed
# 0x80000000: kernel load + start address
# 0x81000000: kernel boot stack (16MB mark)

.equ KERNEL_BOOT_STACK_TOP, 0x81000000

# the boot ROM drops us here with nothing setup
# this code is assumed to be loaded and running at 0x80000000
# set up a stack and call the main kernel code.
# we assume we have 16MB or more of DRAM fitted. this means the kernel and
# and its initialization payload is expected to fit within this space.
#
# => a0 = hart ID. Only boot CPU core 0. Park all other cores permanently
#    a1 = pointer to device tree
# <= nothing else for kernel to do
_start:
  addi  t0, x0, 1                 # get ready to select hart id > 0
  bge   a0, t0, infinite_loop     # all cores but hart 0 are parked

  li sp, KERNEL_BOOT_STACK_TOP
  call kmain

# nowhere else to go, so: infinite loop
infinite_loop:
  j infinite_loop
