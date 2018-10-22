# kernel low-level entry point for the SiFive U34 (RV32) platform
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

# _start *must* be the first routine in this file
.section .entry
.global _start

# include kernel constants, such as stack and lock locations
.include "src/platform/riscv32/common/asm/consts.s"

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
# 0x80fff000: top of kernel 16KB boot stack. Top 8KB is for normal operation.
#             Lower 8KB is for the interrupt/exception handler.
# 0x80fff000: base of locks and variables page
# 0x81000000: top of kernel boot memory

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
  # this is supposed to be a single CPU system. Park all cores but ID 0
  li      t0, 1
  bge     a0, t0, infinite_loop

  # prepare the boot stack and interrupt stack, stored in mscratch
  li      sp, KERNEL_BOOT_STACK_TOP
  li      t0, KERNEL_BOOT_IRQ_STACK_OFFSET
  sub     t0, sp, t0            # calculate top of exception stack
  csrrw   x0, mscratch, t0      # store in mscratch

  # set up early exception handling
  call    irq_early_init

  # call kmain with devicetree in a0
  add     a0, a1, x0
  call    kmain

# nowhere else to go, so: infinite loop
infinite_loop:
  wfi
  j infinite_loop
