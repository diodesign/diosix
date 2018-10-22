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

# during interrupts and exceptions, stack 31 of 32 registers (skip x0)
.equ  IRQ_REGISTER_FRAME_SIZE,   (31 * 4)

.align 4
# Entry point for machine-level handler of interrupts and exceptions
# interrupts are automatically disabled on entry.
irq_machine_handler:
  # get exception handler stack from mscratch by swapping it for current sp
  csrrw sp, mscratch, sp

  # preserve all 32 registers bar two: x0 (zero) and x2 (sp)
  # in the IRQ handler stack. Pointless stacking zero,
  # and x2 is held mscratch
  addi  sp, sp, -(IRQ_REGISTER_FRAME_SIZE)

  # skip x0 (zero), save x1, skip and x2 (sp) as it's in mscratch right now,
  # then stack the remaining 29 registers (x3 to x31)
  PUSH_REG 1
  .set reg, 3
  .rept 29
    PUSH_REG %reg
    .set reg, reg + 1
  .endr

  # time to call the platform's higher-level IRQ handler. gather up
  # the cause and location in memory of the exception or interrupt
  addi  a0, sp, IRQ_REGISTER_FRAME_SIZE
  csrrs a1, mcause, x0
  csrrs a2, mepc, x0

  # if the top bit is set then a1 (mcause) is negative and this means
  # we're dealing with a hardware interrupt
  blt   a1, x0, handle_hardware_interrupt
  # if not, this is an exception
  call  kernel_exception_handler

irq_machine_handler_outro:
  # restore stacked 29 registers (x31 to x3) then x1
  .set reg, 31
  .rept 29
    PULL_REG %reg
    .set reg, reg - 1
  .endr
  PULL_REG 1

  # fix up exception handler sp
  addi  sp, sp, IRQ_REGISTER_FRAME_SIZE

  # swap exception sp for original sp, and return
  csrrw sp, mscratch, sp
  mret

handle_hardware_interrupt:
  # get rid of the top bit in a1
  sll   a1, a1, 1
  srl   a1, a1, 1
  call  kernel_interrupt_handler
  j     irq_machine_handler_outro
