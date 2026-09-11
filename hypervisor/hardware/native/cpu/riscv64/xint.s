# Handle exceptions and interrupts (xint) on Qemu-compatible systems
#
# Copyright (c) 2024, 2026 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT

.altmacro

# hypervisor constants, such as stack and lock locations
.include "hypervisor/hardware/native/cpu/riscv64/consts.s"

.section .text
.align 8

.global hw_xint_init

# set up xint handling on this CPU core
# also enable hardware interrupts as well as execptions.
# NB: assumes mscratch is already set to the top of the xint stack. see _start for pre-setup.
# <= corrupts t0
hw_xint_init:
    # point this CPU core at default machine-level xint handler (see below)
    la      t0, xint_machine_entry_handler
    csrw    mtvec, t0
    csrw    stvec, t0
  
    # delegate most supervisor-level exceptions to the supervisor-level guest,
    # so that the guest can deal with its exception direct. for a given exception,
    # bit = 1 to delegate, 0 = pass to the machine-level hypervisor.
    li      t0, MEDELEG_DELEGATED
    csrw    medeleg, t0
  
    # Delegate virtual supervisor interrupts to VS-mode (VSSIP, VSTIP, VSEIP).
    # Physical interrupts (SSIP, STIP, SEIP) remain in M-mode.
    li      t0, MIDELEG_DELEGATED
    csrw    mideleg, t0

    ret


# macro to generate store instructions to push given 'reg' register
.macro PUSH_REG reg
  sd  x\reg, (\reg * 8)(sp)
.endm

# macro to generate load instructions to pull given 'reg' register
.macro PULL_REG reg
  ld  x\reg, (\reg * 8)(sp)
.endm

.align 8
# Entry point for machine-level handler of interrupts and exceptions (xint)
# interrupts are automatically disabled on entry.
# right now, xint are non-reentrant. if a xint handler is interrupted, the previous one will
# be discarded. do not enable hardware interrupts. any exceptions will be unfortunate.
xint_machine_entry_handler:
    # get xint stack from mscratch by swapping it for interrupted code's sp
    csrrw   sp, mscratch, sp
    # now: sp = top of xint stack. mscratch = interrupted code's sp

     # reserve space to preserve all 32 general-purpose CPU registers
    addi    sp, sp, -(XINT_REGISTER_FRAME_SIZE)
    # skip x0 (zero) and x2 (sp), stack all other registers
    PUSH_REG 1
    .set reg, 3
    .rept 29
      PUSH_REG %reg
      .set reg, reg + 1
    .endr

    # stack the interrupted code's sp as x2 (sp) in register block
    csrr    t0, mscratch
    sd      t0, (2 * 8)(sp)

    # right now mscratch is corrupt with the interrupted code's sp.
    # this means hypervisor functions relying on mscratch will break, so restore it.
    addi    t0, sp, XINT_REGISTER_FRAME_SIZE
    csrw    mscratch, t0

    # Ensure tp points to this CPU's host CpuContext
    mv      tp, t0

    # pass current sp to exception/hw handler as a pointer in a0. this'll allow
    # the higher-level hypervisor access and modify any of the stacked registers
    mv      a0, sp
    call    xint_handler

    # restore all stacked registers, skipping zero (x0) and sp (x2)
    .set reg, 31
    .rept 29
      PULL_REG %reg
      .set reg, reg - 1
    .endr
    PULL_REG 1

    # finally, restore the interrupted code's sp and return
    PULL_REG 2
    mret