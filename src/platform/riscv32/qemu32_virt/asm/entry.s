# kernel low-level entry point for the Qemu Virt (RV32) platform
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
# 0x00100000, size: 0x1000:    Hardware test area
# 0x02000000, size: 0x10000:   CLINT (Core Local Interruptor)
# 0x0c000000, size: 0x4000000: PLIC (Platform Level Interrupt Controller)
# 0x10000000, size: 0x100:     UART 0
# 0x10001000, size: 0x1000:    Virtual IO
# 0x80000000: DRAM base (default 128MB, min 16MB) <-- kernel + entered loaded here
#
# see consts.s for CPU stack + top page of variables locations

# the boot ROM drops us here with nothing setup
# this code is assumed to be loaded and running at 0x80000000
# set up a per-CPU core stack and call the main kernel code.
# interrupts and exceptions are disabled within this space.
#
# => a0 = CPU core ID, aka hart ID
#    a1 = pointer to device tree
# <= nothing else for kernel to do
_start:
  # stick this in the back pocket
  la       t6, __kernel_top_page_base

  # increment CPU core count, atomically
  li       t0, 1
  addi     t1, t6, KERNEL_CPUS_ALIVE
  amoadd.w x0, t0, (t1)

  # set up a 16KB per-CPU core stack, calculated from top of the kernel boot stack, descending downwords.
  # CPU 0 takes first 16KB from the top down, then CPU 1, CPU 2, etc. the 16KB stack space is 2 * 8KB areas.
  # top 8KB for running boot code, bottom 8KB for exception/interrupt handling
  slli  t0, a0, 14        # t0 = (hart id) << 14 = (hart ID) * 16 * 1024
  la    sp, __kernel_cpu_stack_top
  sub   sp, sp, t0        # subtract per-cpu stack offset from top of stack
  li    t0, KERNEL_BOOT_IRQ_STACK_OFFSET
  sub   t0, sp, t0        # calculate top of IRQ handler stack with the 16KB reserved for this core
  csrrw x0, mscratch, t0  # store exception/interrupt handler stack in mscratch

  # set up early exception/interrupt handling
  call  irq_early_init

  # CPU core 0 is allowed to boot the kernel. All other cores are placed in
  # the waiting room, where the scheduler will feed them work
  bne   a0, x0, wait_for_work

  # if we're still here then we're CPU core 0, so continue booting the system.
  # prepare to jump to the main kernel code
  _KERNEL_TOP_PAGE_INIT
  # call kmain with devicetree in a0
  add   a0, a1, x0
  la    t0, kmain

enter_kernel:
  jalr  ra, t0, 0

infinite_loop:
  wfi
  j     infinite_loop   # fall through to loop rather than crash

# prepare to jump to the kernel's waiting room for CPU cores
wait_for_work:
  la    t0, kwait
  j     enter_kernel
