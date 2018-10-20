# kernel low-level entry point for the Qemu Virt (RV32) platform
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

# _start *must* be the first routine in this file
.section .entry
.global _start

# include page zero locations
.include "src/platform/riscv32/qemu32_virt/asm/page_zero.s"

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
#             0 = boot CPU spin lock (32b)
#             4 = debug spin lock (32b)
#
# 0x80001000: kernel load + start address
#
# 0x80fe0000: kernel boot stack bottom
#      \......... 128KB of 8 * 16KB per-CPU core boot stacks
#                 Each CPU core has its own boot stack, descending one by one
#                 from the top of the kernel boot stack.
# 0x81000000: kernel boot stack top (16MB mark)

.equ KERNEL_BOOT_STACK_TOP,   0x81000000

# the boot ROM drops us here with nothing setup
# this code is assumed to be loaded and running at 0x80001000
# set up a per-CPU core stack and call the main kernel code.
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

  # CPU core 0 is allowed to boot the kernel. All other cores are placed in
  # the waiting room, where the scheduler will feed them work
  bne   a0, x0, wait_for_work

  # if we're still here then we're CPU core 0, so continue booting the system
  # prepare to jump to the main kernel code
  la    t0, kmain

enter_kernel:
  jalr  ra, t0, 0

infinite_loop:
  j     infinite_loop   # fall through to loop rather than crash

# prepare to jump to the kernel's waiting room for CPU cores
wait_for_work:
  la    t0, kwait
  j     enter_kernel
