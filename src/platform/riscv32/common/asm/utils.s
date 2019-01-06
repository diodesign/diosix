# kernel low-level utility code for RV32G targets
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

.section .text
.align 4

.global platform_cpu_private_variables
.global platform_cpu_heap_base
.global platform_cpu_heap_size
.global platform_save_supervisor_state
.global platform_load_supervisor_state
.global platform_set_supervisor_return

# include kernel constants, such as stack and lock locations
.include "src/platform/riscv32/common/asm/consts.s"

# return pointer to this CPU's private variables
# <= a0 = pointer to kernel's CPU structure
platform_cpu_private_variables:
  # get base of private variables from top of IRQ stack, held in mscratch
  csrrs a0, mscratch, x0
  ret

# return base address of this CPU's heap - right above private vars 
# <= a0 = pointer to heap base (corrupts t0)
platform_cpu_heap_base:
  csrrs a0, mscratch, x0  # private vars start above CPU IRQ stack
  li    t0, KERNEL_CPU_PRIVATE_VARS_SIZE
  add   a0, a0, t0
  ret

# return total empty size of this CPU's heap area
# <= a0 = heap size in bytes
platform_cpu_heap_size:
  li  a0, KERNEL_CPU_HEAP_AREA_SIZE
  ret

# save contents of supervisor CSRs into memory, and registers stacked
# at the top of the IRQ stack 
# => a0 = pointer to SupervisorState structure to hold registers
platform_save_supervisor_state:
  # preserve all CSRs
  csrrs t0, sstatus, x0
  csrrs t1, stvec, x0
  csrrs t2, sip, x0
  csrrs t3, sie, x0
  csrrs t4, scounteren, x0
  csrrs t5, sscratch, x0
  csrrs t6, sepc, x0
  sw    t0, 0(a0)
  sw    t1, 4(a0)
  sw    t2, 8(a0)
  sw    t3, 12(a0)
  sw    t4, 16(a0)
  sw    t5, 20(a0)
  sw    t6, 24(a0)

  csrrs t0, scause, x0
  csrrs t1, stval, x0
  csrrs t2, satp, x0
  csrrs t3, mepc, x0    # preserve pc of interrupted code 
  move  t4, s11         # preserve sp of interrupted code (stashed in s11)
  sw    t0, 28(a0)
  sw    t1, 32(a0)
  sw    t2, 36(a0)
  sw    t3, 40(a0)
  sw    t4, 44(a0)

  # copy registers from the IRQ stack
  addi  t0, a0, 48
  csrrs t1, mscratch, x0
  addi  t1, t1, -(IRQ_REGISTER_FRAME_SIZE)
  # t0 = base of register save block, t1 = base of IRQ saved registers
  # skip over x0
  addi  t1, t1, 4
  # stack remaining 31 registers
  li    t2, 31

from_stack_copy_loop:
  lw    t3, (t1)
  sw    t3, (t0)
  addi  t0, t0, 4
  addi  t1, t1, 4
  addi  t2, t2, -1
  bnez  t2, from_stack_copy_loop

  ret

# load saved supervisor CSRs and general-purpose registers from memory
# to the IRQ stack so when we return to the supervisor, the new context
# becomes active 
# => a0 = pointer to SupervisorState structure to load registers
platform_load_supervisor_state:
  # restore all CSRs
  lw    t0, 0(a0)
  lw    t1, 4(a0)
  lw    t2, 8(a0)
  lw    t3, 12(a0)
  lw    t4, 16(a0)
  lw    t5, 20(a0)
  lw    t6, 24(a0)
  csrrw x0, sstatus, t0
  csrrw x0, stvec, t1
  csrrw x0, sip, t2
  csrrw x0, sie, t3
  csrrw x0, scounteren, t4
  csrrw x0, sscratch, t5
  csrrw x0, sepc, t6

  lw    t0, 28(a0)
  lw    t1, 32(a0)
  lw    t2, 36(a0)
  lw    t3, 40(a0)
  lw    t4, 44(a0)
  csrrw x0, scause, t0
  csrrw x0, stval, t1
  csrrw x0, satp, t2
  csrrw x0, mepc, t3      # restore pc of next thread to run
  move  s11, t4           # restore sp of next thread (stashed in s11)

  # copy registers to the IRQ stack
  addi  t0, a0, 48
  csrrs t1, mscratch, x0
  addi  t1, t1, -(IRQ_REGISTER_FRAME_SIZE)
  # t0 = base of register save block, t1 = base of IRQ saved registers
  # skip over x0
  addi  t1, t1, 4
  # copy remaining 31 registers
  li    t2, 31

to_stack_copy_loop:
  lw    t3, (t0)
  sw    t3, (t1)
  addi  t0, t0, 4
  addi  t1, t1, 4
  addi  t2, t2, -1
  bnez  t2, to_stack_copy_loop

  ret

# set the machine-level flags necessary to return to supervisor mode
# rather than machine mode. context for the supervisor mode is loaded
# elsewhere
platform_set_supervisor_return:
  # set 'previous' privilege level to supervisor by clearing bit 12
  # and setting bit 11 in mstatus, defining MPP[12:11] as b01 = 1 for supervisor
  li    t0, 1 << 12
  csrrc x0, mstatus, t0
  li    t0, 1 << 11
  csrrs x0, mstatus, t0
  ret
