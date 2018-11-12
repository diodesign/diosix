# kernel low-level entry point for the SiFive U34 (RV32) platform
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

# _start *must* be the first routine in this file
.section .entry
.global _start

# include kernel constants, such as stack and lock locations
# also defines _KERNEL_TOP_PAGE_INIT
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
# 0x80000000: DRAM base (default 128MB, min 16MB) <-- kernel + entered loaded here
#
# see consts.s for top page of global variables locations and other memory layout decisions

# the boot ROM drops us here with nothing setup
# this code is assumed to be loaded and running at 0x80000000
# set up a stack and call the main kernel code.
#
# => a0 = hart ID. Only boot CPU core 0. Park all other cores permanently
#    a1 = pointer to device tree
# <= nothing else for kernel to do
_start:
  # this is supposed to be a single CPU system. Park all cores but ID 0
  li      t0, 1
  bge     a0, t0, infinite_loop

  # stick this in the back pocket
  la      t6, __kernel_top_page_base

  # only one CPU on this system
  li      t0, 1
  addi    t1, t6, KERNEL_CPUS_ALIVE
  sw      t0, (t1)

  # set up a 16KB CPU core stack, descending downwords. the 16KB stack space is 2 * 8KB areas.
  # top 8KB for exception/interrupt handling and per-CPU variables, bottom 8KB for startup.
  # when startup is over, then the IRQ stack can claim the boot area
  la      t0, __kernel_cpu_stack_top
  li      t1, KERNEL_BOOT_STACK_OFFSET
  sub     sp, t0, t1
  addi    t0, t0, -(KERNEL_PER_CPU_VAR_SPACE)
  csrrw   x0, mscratch, t0 # store irq stack top in mscratch

  # set up top page and early exception handling
  _KERNEL_TOP_PAGE_INIT
  call    irq_early_init

  # call kmain with devicetree in a0
  add     a0, a1, x0
  call    kmain

# nowhere else to go, so: infinite loop
infinite_loop:
  wfi
  j infinite_loop
