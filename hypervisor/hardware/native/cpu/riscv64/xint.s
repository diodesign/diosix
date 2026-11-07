# Handle exceptions and interrupts (xint) on QEMU-compatible systems.
#
# Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT

.altmacro

# Hypervisor constants, such as stack and lock locations.
.include "consts.s"

.section .text
.align 8

.global hw_xint_init

# Set up xint handling on this CPU core and configure trap delegation.
# NB: assumes mscratch is already set to the top of the xint stack (see _start).
# <= corrupts t0
hw_xint_init:
    # Point this CPU core at the machine-level xint handler.
    la      t0, xint_machine_entry_handler
    csrw    mtvec, t0
    csrw    stvec, t0

    # Delegate most supervisor-level exceptions to the supervisor-level guest,
    # so that the guest can deal with its exceptions directly. For a given
    # exception: bit = 1 to delegate, 0 = pass to the machine-level hypervisor.
    li      t0, MEDELEG_DELEGATED
    csrw    medeleg, t0

    # Delegate virtual supervisor interrupts to VS-mode (VSSIP, VSTIP, VSEIP).
    # Physical interrupts (SSIP, STIP, SEIP) remain in M-mode.
    li      t0, MIDELEG_DELEGATED
    csrw    mideleg, t0

    ret


# Macro to generate store instructions to push given 'reg' register.
.macro PUSH_REG reg
  sd  x\reg, (\reg * 8)(sp)
.endm

# Macro to generate load instructions to pull given 'reg' register.
.macro PULL_REG reg
  ld  x\reg, (\reg * 8)(sp)
.endm

.align 8
# Entry point for machine-level handler of interrupts and exceptions (xint).
# Interrupts are automatically disabled on entry.
# Supports nested synchronous M-mode traps (such as safe CSR/HLV probing)
# by preserving the active M-mode stack pointer when mstatus.MPP == M-mode.
xint_machine_entry_handler:
    # Swap sp with mscratch (mscratch holds top of xint stack == &CpuContext).
    csrrw   sp, mscratch, sp

    # Stash t0 and t1 in reserved scratch slots in CPU_PRIVATE_VARS.
    sd      t0, CPU_SCRATCH_T0_OFFSET(sp)
    sd      t1, CPU_SCRATCH_T1_OFFSET(sp)
    mv      t1, sp

    # If the trap originated in M-mode (mstatus.MPP == 3), keep using the
    # interrupted M-mode stack pointer (in mscratch) so we do not clobber
    # the outer guest trap frame on the xint stack.
    csrr    t0, mstatus
    srli    t0, t0, MSTATUS_MPP_SHIFT
    andi    t0, t0, MSTATUS_MPP_MASK_BITS
    addi    t0, t0, -MSTATUS_MPP_MACHINE
    bnez    t0, 1f
    csrr    sp, mscratch
1:
    # Reserve space to preserve all 32 general-purpose CPU registers.
    addi    sp, sp, -(XINT_REGISTER_FRAME_SIZE)
    # Skip x0 (zero) and x2 (sp), stack all other registers.
    PUSH_REG 1
    .set reg, 3
    .rept 29
      PUSH_REG %reg
      .set reg, reg + 1
    .endr

    # Write the true pre-trap t0 (x5) and t1 (x6) into the register frame.
    ld      t0, CPU_SCRATCH_T0_OFFSET(t1)
    sd      t0, (5 * 8)(sp)
    ld      t0, CPU_SCRATCH_T1_OFFSET(t1)
    sd      t0, (6 * 8)(sp)

    # Stack the interrupted code's sp as x2 (sp) in register block.
    csrr    t0, mscratch
    sd      t0, (2 * 8)(sp)

    # Restore mscratch and tp to top of xint stack (&CpuContext, in t1).
    csrw    mscratch, t1
    mv      tp, t1

    # Pass current sp to exception/hw handler as a pointer in a0 so higher-level
    # hypervisor code can read and modify any of the stacked registers.
    mv      a0, sp
    call    xint_handler

    # Restore all stacked registers, skipping zero (x0) and sp (x2).
    .set reg, 31
    .rept 29
      PULL_REG %reg
      .set reg, reg - 1
    .endr
    PULL_REG 1

    # Finally, restore the interrupted code's sp and return.
    PULL_REG 2
    mret