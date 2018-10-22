# kernel low-level entry point for the Qemu Virt (RV32) platform
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
# 0x00100000, size: 0x1000:    Hardware test area
# 0x02000000, size: 0x10000:   CLINT (Core Local Interruptor)
# 0x0c000000, size: 0x4000000: PLIC (Platform Level Interrupt Controller)
# 0x10000000, size: 0x100:     UART 0
# 0x10001000, size: 0x1000:    Virtual IO
# 0x80000000: DRAM base (default 128MB, min 16MB)

# kernel DRAM layout, before device tree is probed
# 0x80000000: kernel load + start address
#
# 0x80fdf000: kernel boot stack bottom
#      \......... 128KB of 8 * 16KB per-CPU core boot stacks
#                 Each CPU core has its own boot stack, descending one by one
#                 from the top of the kernel boot stack. Each boot stack is
#                 split in two halves - top 8KB half is normal operation
#                 stack. The lower 8KB is for the interrupt/exception handler.
# 0x80fff000: kernel boot stack top
# 0x80fff000: base of locks and variables page
# 0x81000000: top of kernel boot memory

# the boot ROM drops us here with nothing setup
# this code is assumed to be loaded and running at 0x80000000
# set up a per-CPU core stack and call the main kernel code.
# interrupts and exceptions are disabled within this space.
# we assume we have 16MB or more of DRAM fitted. this means the kernel and
# and its initialization payload is expected to fit within this space.
#
# => a0 = CPU core ID, aka hart ID
#    a1 = pointer to device tree
# <= nothing else for kernel to do
_start:
  # set up a per-CPU core stack, calculated from top of the kernel boot stack
  addi  t0, x0, 14    # get ready to shift hart ID by 14 bits left
  sll   t1, a0, t0    # t1 = (hart id) << 14
  li    sp, KERNEL_BOOT_STACK_TOP
  sub   sp, sp, t1    # subtract per-cpu stack offset from top of stack
  li    t0, KERNEL_BOOT_IRQ_STACK_OFFSET
  sub   t0, sp, t0        # calculate top of exception handler stack
  csrrw x0, mscratch, t0  # store in mscratch

  # set up early exception handling
  call  irq_early_init

  # CPU core 0 is allowed to boot the kernel. All other cores are placed in
  # the waiting room, where the scheduler will feed them work
  bne   a0, x0, wait_for_work

  # if we're still here then we're CPU core 0, so continue booting the system.
  # prepare to jump to the main kernel code

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
