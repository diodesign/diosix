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

# set up boot interrupt handling on this core so we can catch
# exceptions while the system is initializating
# <= corrupts t0
irq_early_init:
  # point core at default machine-level exception/interrupt handler
  la    t0, irq_machine_handler
  csrrw x0, mtvec, t0

  # enable interrupts: set bit 3 in mstatus to enable machine irqs (MIE)
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

# during interrupts and exceptions, reserve space for 32 registers
.equ  IRQ_REGISTER_FRAME_SIZE,   (32 * 4)

.align 4
# Entry point for machine-level handler of interrupts and exceptions
# interrupts are automatically disabled on entry.
# right now, IRQs are non-reentrant. if an IRQ handler is interrupted, the previous one will
# be discarded. do not enable hardware interrupts. any exceptions will be unfortunate.
irq_machine_handler:
  # get exception handler stack from mscratch by swapping it for current sp
  csrrw  sp, mscratch, sp
  # now: sp = top of IRQ stack. mscratch = prev environment's sp

  # save space to preserve all 32 GP registers
  addi  sp, sp, -(IRQ_REGISTER_FRAME_SIZE)
  # skip x0 (zero), stack all 31 other registers
  .set reg, 1
  .rept 31
    PUSH_REG %reg
    .set reg, reg + 1
  .endr

  # right now mscratch is corrupt with the prev environment's sp.
  # this means kernel functions relying on it will break unless it is restored.
  # calculate original mscratch value into s11, and swap with mscratch
  addi  s11, sp, IRQ_REGISTER_FRAME_SIZE
  csrrw s11, mscratch, s11
  # now: s11 = prev environment's sp. mscratch = top of IRQ stack

  # gather up the cause, faulting instruction address, memory address relevant to the exception or interrupt,
  # and previous environment's stack pointer, and store on the IRQ handler's stack
  addi  sp, sp, -16
  csrrs t0, mcause, x0
  csrrs t1, mepc, x0
  csrrs t2, mtval, x0
  sw    t0, 0(sp)       # mcause
  sw    t1, 4(sp)       # mepc
  sw    t2, 8(sp)       # mtval
  sw    s11, 12(sp)     # prev environment's sp

  # pass current sp to exception/hw handler as a pointer. this'll allow
  # the higher-level kernel access the context of the IRQ.
  # it musn't corrupt s11, a callee-saved register
  add   a0, sp, x0
  call  kirq_handler

  # swap back mscratch so prev environment's sp can be restored
  csrrw s11, mscratch, s11
  # now: mscratch = prev environment's sp. s11 = top of IRQ stack

  # fix up the stack from the cause, epc, etc pushes
  addi  sp, sp, 16
  # then restore all 31 stacked registers, skipping zero (x0)
  .set reg, 31
  .rept 31
    PULL_REG %reg
    .set reg, reg - 1
  .endr

  # fix up exception handler sp
  addi  sp, sp, IRQ_REGISTER_FRAME_SIZE

  # swap top of IRQ sp for prev environment's sp, and return
  csrrw sp, mscratch, sp
  mret
