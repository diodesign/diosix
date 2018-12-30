# kernel common low-level entry points for RV32G platforms (Qemu Virt, SiFive U34)
#
# Assumes we're loaded and entered at 0x80000000
# with a0 = CPU/Hart ID number, a1 -> device tree
#
# Works with SMP and UMP. Assumes non-NUMA memory layout
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

# _start *must* be the first routine in this file
.section .entry
.align 4

.global _start

# include kernel constants, such as global variable and lock locations
# check this file for static kernel data layout
.include "src/platform/riscv32/common/asm/consts.s"

# hardware physical memory map
# 0x00000000, size: 0x100:     Debug ROM/data
# 0x00001000, size: 0x11000:   Boot ROM
# 0x00100000, size: 0x1000:    Hardware test area
# 0x02000000, size: 0x10000:   CLINT (Core Local Interruptor)
# 0x0c000000, size: 0x4000000: PLIC (Platform Level Interrupt Controller)
# 0x80000000: DRAM base (default 128MB, max 2GB) <-- kernel + entered loaded here
#
# see consts.s for top page of global variables locations and other memory layout decisions

# the boot ROM drops each core simultenously here with nothing setup
# this code is assumed to be loaded and running at 0x80000000
# interrupts and exceptions are disabled.
#
# => a0 = CPU core ID, aka hart ID
#    a1 = pointer to device tree
# <= never returns
_start:
  # each core should grab a slab of memory starting from the end of the kernel.
  # in order to scale to many cores, not waste too much memory, and to cope with non-linear
  # CPU ID / hart ID, each core will take memory using an atomic counter in the first word
  # of available RAM. thus, memory is allocated on a first come, first served basis.
  # this counter is temporarily and should be forgotten about once in kmain()
  la        t1, __kernel_end
  li        t2, 1
  amoadd.w  t3, t2, (t1)
  # t3 = counter just before we incremented it
  # preserve t3 in a0
  add       a0, t3, x0
  
  # use t3 this as a multiplier from the end of the kernel, using shifts to keep things easy
  slli      t3, t3, KERNEL_CPU_SLAB_SHIFT
  add       t3, t3, t1
  # t3 = base of this CPU's private memory slab

  # write the top of the exception / interrupt stack to mscratch
  li        t1, KERNEL_CPU_STACK_BASE
  li        t2, KERNEL_CPU_STACK_SIZE
  add       t4, t2, t1
  add       t4, t4, t3
  # t4 = top of the stack, t2 = stack size, t1 = stack base from slab base
  csrrw     x0, mscratch, t4

  # use the lower half of the exception stack to bring up the hypervisor
  # set the boot stack pointer to halfway down the IRQ stack
  srli      t1, t2, 1
  sub       sp, t4, t1

  # set up early exception/interrupt handling (corrupts t0)
  call      irq_early_init

# call kentry with runtime-assigned CPU ID number in a0 and devicetree in a1
enter_kernel:
  la        t0, kentry
  jalr      ra, t0, 0

# fall through to loop rather than crash into random instructions/data
# wait for interrupts to come in and service them
infinite_loop:
  wfi
  j         infinite_loop

is_boot_cpu:
  # set a0 to true to indicate this is the boot CPU
  li        a0, 1
  j         enter_kernel
