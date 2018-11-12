# kernel low-level interrupt/exception code for RV32G targets
#
# Note: No support for F/D floating point (yet)!
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

.altmacro

.section .text

.global irq_early_init

# set up boot interrupt handling on this core so we can catch
# exceptions while the system is initializating
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
irq_machine_handler:
  # get exception handler stack from mscratch by swapping it for current sp
  csrrw sp, mscratch, sp

  # save space to preserve all 32 GP registers
  addi  sp, sp, -(IRQ_REGISTER_FRAME_SIZE)

  # skip x0 (zero), stack all 31 other registers
  .set reg, 1
  .rept 31
    PUSH_REG %reg
    .set reg, reg + 1
  .endr

  # gather up the cause, faulting instruction address, memory address relevant to the exception or interrupt,
  # and previous environment's stack pointer, and store on the IRQ handler's stack
  addi   sp, sp, -16
  csrrs t0, mcause, x0      #
  csrrs t1, mepc, x0        # just read from these special registers
  csrrs t2, mtval, x0       # don't modify their contents, esp mscratch
  csrrs t3, mscratch, x0    #
  sw    t0, 0(sp)
  sw    t1, 4(sp)
  sw    t2, 8(sp)
  sw    t3, 12(sp)

  # pass current sp to exception/hw handler as a pointer. this'll allow
  # the higher-level kernel access the context of the IRQ
  add   a0, sp, x0
  call  kirq_handler

  # fix up the stack from the cause, epc, etc pushes
  # then restore all 31 stacked registers, skipping zero (x0)
  addi  sp, sp, 16
  .set reg, 31
  .rept 31
    PULL_REG %reg
    .set reg, reg - 1
  .endr

  # fix up exception handler sp
  addi  sp, sp, IRQ_REGISTER_FRAME_SIZE

  # swap exception sp for original sp, and return
  csrrw sp, mscratch, sp
  mret
