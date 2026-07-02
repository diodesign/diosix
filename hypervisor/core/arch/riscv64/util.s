# Generic utility functions for RV64 targets
#
# Copyright (c) 2024 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT

.section .text
.align 8

.global hw_run_vcore
.global hw_private_variables
.global hw_heap_base
.global hw_heap_size
.global hw_pause
.global hw_pmp_init

# hypervisor constants, such as stack and lock locations
.include "hypervisor/core/arch/riscv64/consts.s"
.include "config.s"


# load all registers from the given context and mret to the guest
# a0 = pointer to ThreadContext [32]usize
# a1 = pointer to MachineState
# a2 = pointer to GuestState
hw_run_vcore:
  ld t0, 0(a1)      # mepc
  csrw mepc, t0
  ld t0, 8(a1)      # mstatus
  csrw mstatus, t0

  # set H-extension CSRs if H-paging is enabled (hgatp != 0)
  ld t1, 24(a1)     # hgatp
  beqz t1, hw_run_vcore_no_h
  ld t0, 16(a1)     # hstatus
  csrw hstatus, t0
  csrw hgatp, t1
  ld t0, 32(a1)     # hvip
  csrw hvip, t0
  ld t0, 40(a1)     # hedeleg
  csrw hedeleg, t0
  ld t0, 48(a1)     # hideleg
  csrw hideleg, t0
  
  # set VS-mode CSRs from a2
  ld t0, 0(a2)      # vsstatus
  csrw vsstatus, t0
  ld t0, 8(a2)      # vsie
  csrw vsie, t0
  ld t0, 16(a2)     # vstvec
  csrw vstvec, t0
  ld t0, 24(a2)     # vsscratch
  csrw vsscratch, t0
  ld t0, 32(a2)     # vsepc
  csrw vsepc, t0
  ld t0, 40(a2)     # vscause
  csrw vscause, t0
  ld t0, 48(a2)     # vstval
  csrw vstval, t0
  ld t0, 56(a2)     # vsatp
  csrw vsatp, t0
  .if LEGACY_CPU == 0
  la t0, riscv_supports_sstc
  lbu t0, 0(t0)
  beqz t0, 1f
  ld t0, 64(a2)     # vstimecmp
  csrw 0x24d, t0
1:
  la t0, riscv_supports_smstateen
  lbu t0, 0(t0)
  beqz t0, 2f
  ld t0, 72(a2)     # vsenvcfg
  csrw 0x10a, t0    # senvcfg
  li t0, 1
  slli t0, t0, 63   # STCE
  ori t0, t0, 240   # Cache block ops
  csrw 0x60a, t0    # henvcfg
2:
  .endif

  # Flush any stale G-stage TLB entries
  hfence.gvma

hw_run_vcore_no_h:
  .if LEGACY_CPU == 0
  la t0, riscv_supports_sstc
  lbu t0, 0(t0)
  beqz t0, 3f
  ld t0, 64(a2)     # vstimecmp field is used for stimecmp in PMP fallback
  csrw 0x14d, t0    # stimecmp
3:
  .endif

  # use a0 as temporary base pointer for GPR restoration
  # load all registers, skipping zero (x0) and sp (x2)
  ld x1, 8(a0)
  # restore gp (x3), tp (x4)
  ld x3, 24(a0)
  ld x4, 32(a0)
  # x5 (t0) - handled later
  # x6 (t1) - handled later
  # x7 (t2) to x9 (s1)
  ld x7, 56(a0)
  ld x8, 64(a0)
  ld x9, 72(a0)
  # restore a1 (x11) to a7 (x17)
  ld x11, 88(a0)
  ld x12, 96(a0)
  ld x13, 104(a0)
  ld x14, 112(a0)
  ld x15, 120(a0)
  ld x16, 128(a0)
  ld x17, 136(a0)
  # restore s2 (x18) to s11 (x27)
  ld x18, 144(a0)
  ld x19, 152(a0)
  ld x20, 160(a0)
  ld x21, 168(a0)
  ld x22, 176(a0)
  ld x23, 184(a0)
  ld x24, 192(a0)
  ld x25, 200(a0)
  ld x26, 208(a0)
  ld x27, 216(a0)
  # restore t3 (x28) to t6 (x31)
  ld x28, 224(a0)
  ld x29, 232(a0)
  ld x30, 240(a0)
  ld x31, 248(a0)

  # restore remaining temporaries and sp
  ld x5, 40(a0)   # t0
  ld x6, 48(a0)   # t1
  ld x2, 16(a0)   # sp
  
  # finally restore a0 (x10) last
  ld x10, 80(a0)
  
  mret

# return pointer to this CPU core's private variables
# <= a0 = pointer to CPU core private variables
hw_private_variables:
  # The physical CPU context is held in tp (thread pointer) for both M-mode and S-mode
  mv a0, tp
  ret

# return base address of this CPU core's heap - right above private vars 
# <= a0 = pointer to heap base (corrupts t0)
hw_heap_base:
  mv a0, tp  # private vars start above CPU xint stack
  li    t0, CPU_PRIVATE_VARS_SIZE
  add   a0, a0, t0
  ret

# return total empty size of this CPU core's heap area
# <= a0 = heap size in bytes
hw_heap_size:
  li  a0, CPU_HEAP_AREA_SIZE
  ret

# signal to the CPU core that we're waiting on a condition to clear
hw_pause:
  wfi
  ret

# Initialize Physical Memory Protection (PMP)
# Set a permissive window for all memory for lower privilege modes.
# Isolated guests are then handled by the H-extension's HGATP (G-stage) paging.
hw_pmp_init:
  # Entry 0: covers entire 64-bit address space
  li t0, -1
  csrw pmpaddr0, t0
  # pmpcfg0: Entry 0 is NAPOT with R, W, and X bits set (0x1f)
  # NAPOT mode = 11 (bit 3-4), R=1, W=1, X=1 (bits 0-2)
  li t0, 0x1f
  csrw pmpcfg0, t0
  ret

.global setjmp
.global sigsetjmp
.global longjmp
.global siglongjmp

setjmp:
sigsetjmp:
  sd ra, 0(a0)
  sd sp, 8(a0)
  sd s0, 16(a0)
  sd s1, 24(a0)
  sd s2, 32(a0)
  sd s3, 40(a0)
  sd s4, 48(a0)
  sd s5, 56(a0)
  sd s6, 64(a0)
  sd s7, 72(a0)
  sd s8, 80(a0)
  sd s9, 88(a0)
  sd s10, 96(a0)
  sd s11, 104(a0)
  li a0, 0
  ret

longjmp:
siglongjmp:
  ld ra, 0(a0)
  ld sp, 8(a0)
  ld s0, 16(a0)
  ld s1, 24(a0)
  ld s2, 32(a0)
  ld s3, 40(a0)
  ld s4, 48(a0)
  ld s5, 56(a0)
  ld s6, 64(a0)
  ld s7, 72(a0)
  ld s8, 80(a0)
  ld s9, 88(a0)
  ld s10, 96(a0)
  ld s11, 104(a0)
  mv a0, a1
  bnez a0, 1f
  li a0, 1
1:
  ret