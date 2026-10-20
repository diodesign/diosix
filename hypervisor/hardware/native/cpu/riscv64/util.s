# Generic utility functions for RV64 targets.
#
# Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
# SPDX-License-Identifier: MIT

.section .text
.align 8

.global hw_run_vcore
.global hw_private_variables
.global hw_heap_base
.global hw_heap_size
.global hw_pause
.global hw_pmp_init
.global hw_dynarec_run_block
.global hw_dynarec_exit

# Hypervisor constants, such as stack and lock locations.
.include "consts.s"
.include "config.s"

# Load all registers from the given context and mret to the guest.
# a0 = pointer to ThreadContext [32]u64
# a1 = pointer to MachineState
# a2 = pointer to GuestState
hw_run_vcore:
  ld t0, MS_MEPC_OFFSET(a1)
  csrw mepc, t0
  ld t0, MS_MSTATUS_OFFSET(a1)
  li t1, (MSTATUS_VS_DIRTY | MSTATUS_FS_DIRTY | MSTATUS_TW)
  or t0, t0, t1
  csrw mstatus, t0

  # Set H-extension CSRs if H-paging is enabled (hgatp != 0).
  ld t1, MS_HGATP_OFFSET(a1)
  beqz t1, hw_run_vcore_no_h
  ld t0, MS_HSTATUS_OFFSET(a1)
  csrw hstatus, t0
  csrw hgatp, t1
  ld t0, MS_HVIP_OFFSET(a1)
  csrw hvip, t0
  ld t0, MS_HEDELEG_OFFSET(a1)
  csrw hedeleg, t0
  ld t0, MS_HIDELEG_OFFSET(a1)
  csrw hideleg, t0

  # Set VS-mode CSRs from a2.
  ld t0, GS_VSSTATUS_OFFSET(a2)
  csrw vsstatus, t0
  ld t0, GS_VSIE_OFFSET(a2)
  csrw vsie, t0
  ld t0, GS_VSTVEC_OFFSET(a2)
  csrw vstvec, t0
  ld t0, GS_VSSCRATCH_OFFSET(a2)
  csrw vsscratch, t0
  ld t0, GS_VSEPC_OFFSET(a2)
  csrw vsepc, t0
  ld t0, GS_VSCAUSE_OFFSET(a2)
  csrw vscause, t0
  ld t0, GS_VSTVAL_OFFSET(a2)
  csrw vstval, t0
  ld t0, GS_VSATP_OFFSET(a2)
  csrw vsatp, t0
  .if LEGACY_CPU == 0
  li t0, HENVCFG_CBO_MASK # Cache block ops (CBZE, CBCFE, CBIE)
  la t1, riscv_supports_sstc
  lbu t1, 0(t1)
  beqz t1, 1f
  li t1, 1
  slli t1, t1, HENVCFG_STCE_BIT # STCE
  or t0, t0, t1
1:
  csrw CSR_HENVCFG, t0
  la t0, riscv_supports_sstc
  lbu t0, 0(t0)
  beqz t0, 2f
  ld t0, GS_VSTIMECMP_OFFSET(a2)
  csrw CSR_VSTIMECMP, t0
2:
  la t0, riscv_supports_smstateen
  lbu t0, 0(t0)
  beqz t0, 3f
  ld t0, GS_VSENVCFG_OFFSET(a2)
  csrw CSR_SENVCFG, t0
3:
  .endif

  # Flush any stale G-stage TLB entries and jump to GPR restore.
  hfence.gvma
  j hw_run_vcore_load_gprs

hw_run_vcore_no_h:
  # Set physical S-mode CSRs from a2 (PMP fallback mode).
  ld t0, GS_VSSTATUS_OFFSET(a2)
  csrw sstatus, t0
  ld t0, GS_VSIE_OFFSET(a2)
  csrw sie, t0
  ld t0, GS_VSTVEC_OFFSET(a2)
  csrw stvec, t0
  ld t0, GS_VSSCRATCH_OFFSET(a2)
  csrw sscratch, t0
  ld t0, GS_VSEPC_OFFSET(a2)
  csrw sepc, t0
  ld t0, GS_VSCAUSE_OFFSET(a2)
  csrw scause, t0
  ld t0, GS_VSTVAL_OFFSET(a2)
  csrw stval, t0
  ld t0, GS_VSATP_OFFSET(a2)
  csrw satp, t0
  .if LEGACY_CPU == 0
  la t0, riscv_supports_sstc
  lbu t0, 0(t0)
  beqz t0, 4f
  ld t0, GS_VSTIMECMP_OFFSET(a2)
  csrw CSR_STIMECMP, t0
4:
  la t0, riscv_supports_smstateen
  lbu t0, 0(t0)
  beqz t0, 5f
  ld t0, GS_VSENVCFG_OFFSET(a2)
  csrw CSR_SENVCFG, t0
5:
  .endif

hw_run_vcore_load_gprs:
  # Use a0 as temporary base pointer for GPR restoration.
  # Load all registers, skipping zero (x0) and sp (x2).
  ld x1, 8(a0)
  # Restore gp (x3), tp (x4).
  ld x3, 24(a0)
  ld x4, 32(a0)
  # x5 (t0) and x6 (t1) are restored after main block.
  # Restore t2 (x7) to s1 (x9).
  ld x7, 56(a0)
  ld x8, 64(a0)
  ld x9, 72(a0)
  # Restore a1 (x11) to a7 (x17).
  ld x11, 88(a0)
  ld x12, 96(a0)
  ld x13, 104(a0)
  ld x14, 112(a0)
  ld x15, 120(a0)
  ld x16, 128(a0)
  ld x17, 136(a0)
  # Restore s2 (x18) to s11 (x27).
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
  # Restore t3 (x28) to t6 (x31).
  ld x28, 224(a0)
  ld x29, 232(a0)
  ld x30, 240(a0)
  ld x31, 248(a0)

  # Restore remaining temporaries and sp.
  ld x5, 40(a0)   # t0
  ld x6, 48(a0)   # t1
  ld x2, 16(a0)   # sp

  # Finally restore a0 (x10) last.
  ld x10, 80(a0)

  mret

# Return pointer to this CPU core's private variables.
# <= a0 = pointer to CPU core private variables
hw_private_variables:
  # The physical CPU context is held in tp (thread pointer) in M-mode/S-mode.
  mv a0, tp
  ret

# Return base address of this CPU core's heap - right above private vars.
# <= a0 = pointer to heap base (corrupts t0)
hw_heap_base:
  mv a0, tp  # private vars start above CPU xint stack
  li t0, CPU_PRIVATE_VARS_SIZE
  add a0, a0, t0
  ret

# Return total empty size of this CPU core's heap area.
# <= a0 = heap size in bytes
hw_heap_size:
  li a0, CPU_HEAP_AREA_SIZE
  ret

# Signal to the CPU core that we're waiting on a condition to clear.
hw_pause:
  wfi
  ret

# Initialize Physical Memory Protection (PMP).
# Set a permissive window for all memory for lower privilege modes.
# Isolated guests are then handled by the H-extension's HGATP (G-stage) paging.
hw_pmp_init:
  # Entry 0: covers entire 64-bit address space.
  li t0, -1
  csrw pmpaddr0, t0
  # pmpcfg0: Entry 0 is NAPOT with R, W, and X bits set.
  li t0, PMP_RWX_NAPOT
  csrw pmpcfg0, t0
  ret

# Execute JIT translated code block in Supervisor (S) Mode.
# a0 = pointer to guest regs: [32]u64
# a1 = host code function pointer
# returns a0 = branch exit code / target pc
.section .text
.globl hw_dynarec_run_block
.type hw_dynarec_run_block, @function
hw_dynarec_run_block:
  # 1. Save host callee-saved registers on S-mode host stack.
  addi sp, sp, -(DYNAREC_FRAME_SIZE)
  sd ra, 0(sp)
  sd s0, 8(sp)
  sd s1, 16(sp)
  sd s2, 24(sp)
  sd s3, 32(sp)
  sd s4, 40(sp)
  sd s5, 48(sp)
  sd s6, 56(sp)
  sd s7, 64(sp)
  sd s8, 72(sp)
  sd s9, 80(sp)
  sd s10, 88(sp)
  sd s11, 96(sp)
  sd tp, 104(sp)
  sd gp, 112(sp)

  # 2. Save S-mode host stack pointer in vcpu.host_sp.
  sd sp, VCPU_HOST_SP_OFFSET(a0)

  # 3. Dedicated context base pointer in s11 (x27).
  mv s11, a0

  # 4. Move target block entry pointer to t0.
  mv t0, a1

  # 5. Load guest registers from s11 (regs pointer).
  ld x1, 8(s11)
  ld x2, 16(s11)
  ld x3, 24(s11)
  ld x4, 32(s11)
  # x5 (t0) holds target block entry address; guest t0 is loaded at block entry.
  ld x6, 48(s11)
  ld x7, 56(s11)
  ld x8, 64(s11)
  ld x9, 72(s11)
  ld x10, 80(s11)
  ld x11, 88(s11)
  ld x12, 96(s11)
  ld x13, 104(s11)
  ld x14, 112(s11)
  ld x15, 120(s11)
  ld x16, 128(s11)
  ld x17, 136(s11)
  ld x18, 144(s11)
  ld x19, 152(s11)
  ld x20, 160(s11)
  ld x21, 168(s11)
  ld x22, 176(s11)
  ld x23, 184(s11)
  ld x24, 192(s11)
  ld x25, 200(s11)
  ld x26, 208(s11)
  # guest x27 (s11) is already in 216(s11).
  ld x28, 224(s11)
  ld x29, 232(s11)
  ld x30, 240(s11)
  ld x31, 248(s11)

  # 6. Jump to translated block in S-mode.
  jr t0

.globl hw_dynarec_exit
.type hw_dynarec_exit, @function
hw_dynarec_exit:
  # On entry from S-mode JIT block exit:
  # s11 (x27) holds &vcpu.regs (context pointer)
  # All registers x1..x4, x6..x26, x28..x31 hold guest registers!
  # guest t0 (x5) was already saved to 40(s11) before exit jump
  # target_pc is already saved in vcpu.pc (VCPU_PC_OFFSET)

  # 1. Store all guest registers to regs_ptr (s11).
  sd x1, 8(s11)       # guest ra (x1)
  sd x2, 16(s11)      # guest sp (x2)
  sd x3, 24(s11)      # guest gp (x3)
  sd x4, 32(s11)      # guest tp (x4)
  # x5 (t0) already in 40(s11).
  sd x6, 48(s11)      # guest t1 (x6)
  sd x7, 56(s11)      # guest t2 (x7)
  sd x8, 64(s11)      # guest s0/fp (x8)
  sd x9, 72(s11)      # guest s1 (x9)
  sd x10, 80(s11)     # guest a0 (x10)
  sd x11, 88(s11)     # guest a1 (x11)
  sd x12, 96(s11)     # guest a2 (x12)
  sd x13, 104(s11)    # guest a3 (x13)
  sd x14, 112(s11)    # guest a4 (x14)
  sd x15, 120(s11)    # guest a5 (x15)
  sd x16, 128(s11)    # guest a6 (x16)
  sd x17, 136(s11)    # guest a7 (x17)
  sd x18, 144(s11)    # guest s2 (x18)
  sd x19, 152(s11)    # guest s3 (x19)
  sd x20, 160(s11)    # guest s4 (x20)
  sd x21, 168(s11)    # guest s5 (x21)
  sd x22, 176(s11)    # guest s6 (x22)
  sd x23, 184(s11)    # guest s7 (x23)
  sd x24, 192(s11)    # guest s8 (x24)
  sd x25, 200(s11)    # guest s9 (x25)
  sd x26, 208(s11)    # guest s10 (x26)
  # guest x27 (s11) is already at 216(s11).
  sd x28, 224(s11)    # guest t3 (x28)
  sd x29, 232(s11)    # guest t4 (x29)
  sd x30, 240(s11)    # guest t5 (x30)
  sd x31, 248(s11)    # guest t6 (x31)

  # 2. Read target_pc from vcpu.pc.
  lwu t1, VCPU_PC_OFFSET(s11)

  # 3. Restore host stack pointer from vcpu.host_sp.
  ld sp, VCPU_HOST_SP_OFFSET(s11)

  # 4. Restore host callee-saved registers from S-mode host stack.
  ld ra, 0(sp)
  ld s0, 8(sp)
  ld s1, 16(sp)
  ld s2, 24(sp)
  ld s3, 32(sp)
  ld s4, 40(sp)
  ld s5, 48(sp)
  ld s6, 56(sp)
  ld s7, 64(sp)
  ld s8, 72(sp)
  ld s9, 80(sp)
  ld s10, 88(sp)
  ld s11, 96(sp)
  ld tp, 104(sp)
  ld gp, 112(sp)
  addi sp, sp, DYNAREC_FRAME_SIZE

  # 5. Return target_pc in a0 for C ABI.
  mv a0, t1

  ret
