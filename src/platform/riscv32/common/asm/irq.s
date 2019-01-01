# kernel low-level interrupt/exception code for RV32G targets
#
# Note: No support for F/D floating point (yet)!
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

.altmacro

.section .text
.align 4

.global irq_early_init
.global irq_machine_handler

# include kernel constants, such as stack and lock locations
.include "src/platform/riscv32/common/asm/consts.s"

# set up boot interrupt handling on this core so we can catch
# exceptions while the system is initializating
# <= corrupts t0
irq_early_init:
  # point core at default machine-level exception/interrupt handler
  la    t0, irq_machine_handler
  csrrw x0, mtvec, t0

  # delegate usernode syscalls (ecall) to the supervisor level.
  # we'll just handle supervisor-to-usermode calls. there are no
  # hypervisor-to-hypervisor ecalls.
  li    t0, 1 << 8        # bit 8 = usermode ecall (as per mcause)
  csrrw x0, medeleg, t0

  # enable interrupts: set bit 3 in mstatus to enable machine irqs (MIE)
  # since all hardware interrupts are disabled, we're only enabling
  # exceptions at this point.
  li    t0, 1 << 3
  csrrs x0, mstatus, t0
  ret

# macro to generate store instructions to push given 'reg' register
.macro PUSH_REG reg
  sw  x\reg, (\reg * 4)(sp)
.endm

# macro to generate load instructions to pull given 'reg' register
.macro PULL_REG reg
  lw  x\reg, (\reg * 4)(sp)
.endm

.align 4
# Entry point for machine-level handler of interrupts and exceptions
# interrupts are automatically disabled on entry.
# right now, IRQs are non-reentrant. if an IRQ handler is interrupted, the previous one will
# be discarded. do not enable hardware interrupts. any exceptions will be unfortunate.
irq_machine_handler:
  # get exception handler stack from mscratch by swapping it for interruted code's sp
  csrrw  sp, mscratch, sp
  # now: sp = top of IRQ stack. mscratch = interrupted code's sp

  # save space to preserve all 32 GP registers
  addi  sp, sp, -(IRQ_REGISTER_FRAME_SIZE)
  # skip x0 (zero) and x2 (sp), stack all other registers
  PUSH_REG 1
  .set reg, 3
  .rept 29
    PUSH_REG %reg
    .set reg, reg + 1
  .endr

  # right now mscratch is corrupt with the interrupted code's sp.
  # this means kernel functions relying on mscratch will break unless it is restored.
  # calculate original mscratch value into s11, and swap with mscratch
  addi  s11, sp, IRQ_REGISTER_FRAME_SIZE
  csrrw s11, mscratch, s11
  # now: s11 = interrupted code's sp. mscratch = top of IRQ stack

  # gather up the cause, faulting/triggering instruction address, memory address
  # relevant to the exception or interrupt, and interrupted code's stack pointer,
  # and store on the IRQ handler's stack
  addi  sp, sp, -16
  csrrs t0, mcause, x0
  csrrs t1, mepc, x0
  csrrs t2, mtval, x0
  # riscv sets epc to the address of the syscall instruction, if this was a syscall.
  # in which case, we need to advance epc 4 bytes to the next instruction.
  # otherwise, we're going into a loop when we return 
  li    t3, 9           # mcause = 9 for environment call from supervisor-to-hypervisor
  bne   t3, t0, cont    # ... all usermode ecalls are handled at the supervisor level
  addi  t1, t1, 4       # ... and the hypervisor doesn't make ecalls into itself
cont:
  sw    t0, 0(sp)       # mcause
  sw    t1, 4(sp)       # mepc
  sw    t2, 8(sp)       # mtval
  sw    s11, 12(sp)     # interrupted code's sp

  # pass current sp to exception/hw handler as a pointer. this'll allow
  # the higher-level kernel access the context of the IRQ.
  # it musn't corrupt s11, a callee-saved register
  add   a0, sp, x0
  call  kirq_handler

  # swap back mscratch so interrupted code's sp can be restored
  csrrw s11, mscratch, s11
  # now: mscratch = interrupted code's sp. s11 = top of IRQ stack

  # fix up the stack from the cause, epc, etc pushes
  addi  sp, sp, 16

  # then restore all 31 stacked registers, skipping zero (x0) and sp (x2)
  .set reg, 31
  .rept 29
    PULL_REG %reg
    .set reg, reg - 1
  .endr
  PULL_REG 1

  # fix up exception handler sp
  addi  sp, sp, IRQ_REGISTER_FRAME_SIZE

  # swap top of IRQ sp for interrupted code's sp, and return
  csrrw sp, mscratch, sp
  mret
