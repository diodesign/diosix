# kernel low-level interrupt/exception code for RV32G targets
#
# (c) Chris Williams, 2018.
# See LICENSE for usage and copying.

.section .text
.global irq_machine_handler

.align 4
# Entry point for machine-level handler of interrupts and exceptions
# interrupts are automatically disabled
irq_machine_handler:
  j irq_machine_handler
  mret
