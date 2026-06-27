// Architecture-specific emulation handler for 32-bit RISC-V guests.
//
// Handles instruction decoding, exception classification, CSR emulation,
// Sv32 page table translation, and SBI ECALL forwarding.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const emulation = @import("../../emulation.zig");
const vcore = @import("../../vcore.zig");
const pcore = @import("../../pcore.zig");
const guest = @import("../../guest.zig");
const glue = @import("../../unicorn.zig");
const riscv = @import("../riscv64/riscv.zig");
const debug = @import("../../debug.zig");
const sbi = @import("sbi.zig");

pub const ExceptionAction = emulation.ExceptionAction;

// Unicorn register IDs for RISC-V S-mode CSRs (from riscv.h uc_riscv_reg).
pub const UC_REG_SSTATUS: c_int = 133;
pub const UC_REG_SIE: c_int = 136; // Supervisor interrupt enable
pub const UC_REG_STVEC: c_int = 137;
pub const UC_REG_SEPC: c_int = 140;
pub const UC_REG_SCAUSE: c_int = 141;
pub const UC_REG_STVAL: c_int = 142;
pub const UC_REG_SATP: c_int = 146;
pub const UC_REG_SIP: c_int = 143; // Supervisor interrupt pending
pub const UC_REG_PRIV: c_int = 191; // Privilege mode

// Unicorn register IDs for RISC-V M-mode CSRs.
pub const UC_REG_MSTATUS: c_int = 116; // mstatus — use instead of sstatus for SPP writes
pub const UC_REG_MEDELEG: c_int = 118;
pub const UC_REG_MIDELEG: c_int = 119;
pub const UC_REG_MIP: c_int = 131; // Machine interrupt pending

// Unicorn register IDs for unprivileged counters.
// NOTE: These map to CSR_INSTRET/CSR_INSTRETH (not CSR_TIME/CSR_TIMEH)
// due to the csrno_map layout. The rdtime callback handles actual time
// reads, so this mismatch is benign. Fixing to the "correct" IDs breaks
// boot because MCOUNTEREN=0 path (illegal-insn trap → emulateCSR) is
// how the kernel currently gets time values.
pub const UC_REG_TIME: c_int = 45;
pub const UC_REG_TIMEH: c_int = 77;

// NOTE: Maps to CSR_MCOUNTEREN.
// We must use 122. If we trap rdtime in S-mode, emulateCSR will provide the host time.
pub const UC_REG_MCOUNTEREN: c_int = 120;

// ---- RISC-V Instruction Encodings ----

/// ECALL instruction (32-bit encoding): opcode=SYSTEM, funct3=0, imm=0.
const INSN_ECALL: u32 = 0x00000073;

/// WFI instruction (32-bit encoding): SYSTEM with funct7=0x8, rs2=0x5.
const INSN_WFI: u32 = 0x10500073;

/// Compressed EBREAK (C.EBREAK): 16-bit encoding.
const INSN_C_EBREAK: u16 = 0x9002;

/// Compressed NOP (C.NOP): 16-bit encoding.
const INSN_C_NOP: u16 = 0x0001;

// ---- RISC-V Exception Delegation Masks ----

/// Exception delegation mask for medeleg.
/// Delegates all standard exception causes to S-mode, EXCEPT:
///   - Cause 9 (ECALL from S-mode) — must trap to M-mode for SBI handling.
///   - Cause 14 (double-trap / reserved) — must NOT be delegated for security.
/// Critically, causes 12 (insn page fault), 13 (load page fault), and
/// 15 (store page fault) MUST be delegated for guest demand paging.
const MEDELEG_DEFAULT: u64 = 0xBDFF;

/// Interrupt delegation mask for mideleg.
/// Delegates standard S-mode interrupts (SSIP=1, STIP=5, SEIP=9) to S-mode.
const MIDELEG_DEFAULT: u64 = 0x222;

// ---- Sv32 Page Table Constants ----

/// 22-bit physical page number mask for Sv32 page table entries.
const SV32_PPN_MASK: u32 = 0x3FFFFF;

/// Page size in bytes for Sv32 (4 KiB).
const SV32_PAGE_SIZE: u32 = 4096;

/// RV32 Linux kernel virtual address base.
const KERNEL_VA_BASE: u64 = 0xC0000000;

/// Set up initial RISC-V register state for a new emulated vcore.
pub fn initRegisters(uc: ?*anyopaque, entry: usize, dtb: usize, vcore_id: usize) void {
    var pc_val: u64 = entry;
    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_PC), &pc_val);

    var a0_val: u64 = vcore_id;
    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X10), &a0_val);

    var a1_val: u64 = dtb;
    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X11), &a1_val);

    // IMPORTANT: Write all M-mode CSRs BEFORE dropping to S-mode.
    // RISC-V CSR numbers encode the minimum privilege level in bits 9:8.
    // riscv_csrrw checks env->priv against this, so writing M-mode CSRs
    // (0x3xx) from S-mode silently fails.

    // Delegate standard exception causes to S-mode except ECALL from S-mode.
    // Causes 14+ (reserved / double-trap) are NOT delegated for security.
    var deleg_val: u64 = MEDELEG_DEFAULT;
    _ = glue.uc_reg_write(uc, UC_REG_MEDELEG, &deleg_val);
    // Delegate S-mode interrupts (SSIP, STIP, SEIP) to S-mode.
    var int_deleg_val: u64 = MIDELEG_DEFAULT;
    _ = glue.uc_reg_write(uc, UC_REG_MIDELEG, &int_deleg_val);

    // Set mstatus: MPP=1 (S-mode), MPIE=1, TW=1 (Trap WFI)
    var mstatus_val: u64 = 0;
    _ = glue.uc_reg_read(uc, UC_REG_MSTATUS, &mstatus_val);
    const MSTATUS_MPP_S_MODE: u64 = 1 << 11;
    const MSTATUS_MPIE: u64 = 1 << 7;
    const MSTATUS_TW: u64 = 1 << 21;
    mstatus_val |= MSTATUS_MPP_S_MODE | MSTATUS_MPIE | MSTATUS_TW;
    _ = glue.uc_reg_write(uc, UC_REG_MSTATUS, &mstatus_val);

    // Enable S-mode access to time/cycle/instret CSRs via mcounteren.
    // Bit 0 (CY) = cycle, bit 1 (TM) = time, bit 2 (IR) = instret.
    var mcounteren_val: u64 = 0x7;
    _ = glue.uc_reg_write(uc, UC_REG_MCOUNTEREN, &mcounteren_val);

    // Pre-load the TIME CSR so Unicorn can execute rdtime natively.
    // If this succeeds, rdtime won't trap and we avoid the stop/restart overhead.
    var time_val: u64 = glue.readSModeTime();
    _ = glue.uc_reg_write(uc, UC_REG_TIME, &time_val);

    // NOW drop to S-mode. All M-mode CSR writes above must precede this.
    var priv_val: u32 = 1;
    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_PRIV), &priv_val);
}

/// Read the program counter from Unicorn.
pub fn readPC(uc: ?*anyopaque) u64 {
    var pc: u64 = 0;
    _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_PC), &pc);
    return pc;
}

/// Write the program counter to Unicorn.
pub fn writePC(uc: ?*anyopaque, pc: u64) void {
    var val: u64 = pc;
    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_PC), &val);
}



/// Handle an invalid instruction intercepted by UC_HOOK_INSN_INVALID.
/// Checks if the instruction is rdtime/rdtimeh/rdcycle/rdinstret, reads
/// the real host timer, writes it to the destination register, and
/// Returns .emulated if handled (resume emulation), .wfi if WFI, or .unhandled
/// to let Unicorn raise UC_ERR_INSN_INVALID.
pub fn handleInvalidInsn(uc: ?*anyopaque) ExceptionAction {
    // Unicorn's cpu_exec loop adds +4 to env->pc before calling UC_HOOK_INTR.
    // We must subtract 4 to get the original faulting PC.
    const pc = readPC(uc) - 4;

    // Read the instruction at PC. Try flat addressing first,
    // fall back to Sv32 page table walk if flat read fails.
    var insn: u32 = 0;
    var ok = glue.uc_mem_read(uc, pc, @as([*]u8, @ptrCast(&insn)), 4) == .UC_ERR_OK;
    if (!ok) {
        if (translateVA(uc, pc)) |phys| {
            ok = glue.uc_mem_read(uc, phys, @as([*]u8, @ptrCast(&insn)), 4) == .UC_ERR_OK;
        }
    }
    if (!ok) return .unhandled;

    // Check for compressed (16-bit) instructions: bits[1:0] != 0b11.
    const is_compressed = (insn & 0x3) != 0x3;
    if (is_compressed) {
        const c_insn: u16 = @truncate(insn & 0xFFFF);

        // C.EBREAK: deliver breakpoint exception to guest.
        if (c_insn == INSN_C_EBREAK) {
            // Deliver exception cause 3 (breakpoint) to stvec.
            var stvec: u64 = 0;
            _ = glue.uc_reg_read(uc, UC_REG_STVEC, &stvec);
            var sepc_val: u64 = pc;
            _ = glue.uc_reg_write(uc, UC_REG_SEPC, &sepc_val);
            var scause_val: u64 = 3; // breakpoint
            _ = glue.uc_reg_write(uc, UC_REG_SCAUSE, &scause_val);
            var stval_val: u64 = pc;
            _ = glue.uc_reg_write(uc, UC_REG_STVAL, &stval_val);
            
            // Update sstatus: SPP=priv, SPIE=SIE, SIE=0, priv=1
            var sstatus: u64 = 0;
            _ = glue.uc_reg_read(uc, UC_REG_SSTATUS, &sstatus);
            var priv: u32 = 0;
            _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_PRIV), &priv);
            
            const SSTATUS_SIE: u64 = 1 << 1;
            const SSTATUS_SPIE: u64 = 1 << 5;
            const SSTATUS_SPP: u64 = 1 << 8;
            
            if ((sstatus & SSTATUS_SIE) != 0) {
                sstatus |= SSTATUS_SPIE;
            } else {
                sstatus &= ~SSTATUS_SPIE;
            }
            sstatus &= ~SSTATUS_SIE;
            
            if (priv == 1) { // S-mode
                sstatus |= SSTATUS_SPP;
            } else { // U-mode
                sstatus &= ~SSTATUS_SPP;
            }
            
            _ = glue.uc_reg_write(uc, UC_REG_SSTATUS, &sstatus);
            
            var m_priv: u32 = 1; // PRV_S
            _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_PRIV), &m_priv);

            const stvec_base = stvec & ~@as(u64, 0x3);
            writePC(uc, stvec_base);
            return .emulated;
        }

        // C.NOP: advance PC past the 2-byte instruction.
        if (c_insn == INSN_C_NOP) {
            writePC(uc, pc + 2);
            return .emulated;
        }

        const S_c = struct {
            var log_count: u32 = 0;
        };
        if (S_c.log_count < 10) {
            S_c.log_count += 1;
            debug.printf("Unhandled compressed instruction 0x{x} at PC=0x{x}\n", .{ c_insn, pc });
        }
        return .unhandled;
    }

    const opcode = insn & 0x7F;
    const funct3 = (insn >> 12) & 0x7;

    // SYSTEM instructions (opcode 0x73).
    if (opcode == 0x73) {
        if (funct3 != 0) {
            // CSR access instruction.
            const csr = insn >> 20;
            const rd: u5 = @truncate((insn >> 7) & 0x1F);

            switch (csr) {
                0xC01, 0xC00, 0xC02 => {
                    // time / cycle / instret (lower 32 bits).
                    if (rd != 0) {
                        var val: u64 = glue.readSModeTime();
                        _ = glue.uc_reg_write(uc, @as(c_int, @intCast(1 + @as(u32, rd))), &val);
                    }
                },
                0xC81, 0xC80, 0xC82 => {
                    // timeh / cycleh / instreth (upper 32 bits for RV32).
                    if (rd != 0) {
                        var val: u64 = glue.readSModeTime() >> 32;
                        _ = glue.uc_reg_write(uc, @as(c_int, @intCast(1 + @as(u32, rd))), &val);
                    }
                },
                else => {
                    const S = struct {
                        var log_count: u32 = 0;
                    };
                    if (S.log_count < 10) {
                        S.log_count += 1;
                        debug.printf("Unhandled CSR 0x{x} at PC=0x{x} insn=0x{x}\n", .{ csr, pc, insn });
                    }
                    return .unhandled;
                },
            }
            writePC(uc, pc + 4);
            return .emulated;
        }

        // funct3 == 0: ECALL, EBREAK, SFENCE.VMA, WFI, etc.
        const funct7 = insn >> 25;

        // SFENCE.VMA: funct7 = 0x09
        // Flush Unicorn's internal TLB and TB cache to ensure the guest's
        // page table updates take effect. Without this, QEMU keeps using
        // stale TLB entries after the kernel calls setup_vm_final().
        if (funct7 == 0x09) {
            _ = glue.uc_ctl(uc, @as(c_uint, glue.UC_CTL_FLUSH_TLB));
            _ = glue.uc_ctl(uc, @as(c_uint, glue.UC_CTL_FLUSH_TB));
            writePC(uc, pc + 4);
            return .emulated;
        }

        // Handle WFI here since MSTATUS_TW causes it to raise ILLEGAL_INST (2).
        if (insn == INSN_WFI) {
            return .wfi;
        }

        return .unhandled;
    }

    // MISC-MEM instructions (opcode 0x0F): FENCE, FENCE.I
    if (opcode == 0x0F) {
        // FENCE.I: funct3 = 1
        // FENCE:   funct3 = 0
        // Both can be safely emulated as NOP.
        writePC(uc, pc + 4);
        return .emulated;
    }

    // AMO instructions (opcode 0x2F): Unicorn may not support all atomics.
    if (opcode == 0x2F) {
        // Log but don't handle yet — would need full emulation.
        const S2 = struct {
            var log_count: u32 = 0;
        };
        if (S2.log_count < 5) {
            S2.log_count += 1;
            debug.printf("Unhandled AMO instruction 0x{x} at PC=0x{x}\n", .{ insn, pc });
        }
        return .unhandled;
    }

    // Unknown instruction.
    const S3 = struct {
        var log_count: u32 = 0;
    };
    if (S3.log_count < 10) {
        S3.log_count += 1;
        debug.printf("Unhandled invalid instruction 0x{x} at PC=0x{x} (opcode=0x{x})\n", .{ insn, pc, opcode });
    }
    return .unhandled;
}

/// Handle a clean stop (UC_ERR_OK). Check if the instruction at `pc`
/// is an ECALL and if so, forward it to the SBI layer.
/// Returns true if an ECALL was handled and PC was advanced.
pub fn handleCleanStop(uc: ?*anyopaque, vc: *vcore.VirtualCore, sub_idx: usize, pc: u64) bool {
    var insn: u32 = 0;
    if (glue.uc_mem_read(uc, pc, @as([*]u8, @ptrCast(&insn)), 4) != .UC_ERR_OK) {
        // Try Sv32 translation if flat read fails
        if (translateVA(uc, pc)) |phys| {
            if (glue.uc_mem_read(uc, phys, @as([*]u8, @ptrCast(&insn)), 4) != .UC_ERR_OK) return false;
        } else return false;
    }



    if (insn == INSN_WFI) {
        // the WFI instruction itself. We must manually advance it so it
        // doesn't loop infinitely.
        writePC(uc, pc + 4);

        // Block the sub-vcore, waiting for interrupts
        var mip: u64 = 0;
        _ = glue.uc_reg_read(uc, UC_REG_MIP, &mip);

        const sub = &vc.exec_path.emulated.sub_vcores[sub_idx];

        var timer_pending = false;
        if (sub.timer_scheduled) {
            if (glue.readSModeTime() >= sub.timer_target) {
                timer_pending = true;
            }
        }

        if (mip == 0 and !timer_pending and !sub.pending_ipi) {
            @atomicStore(bool, &sub.wfi_blocked, true, .release);
            debug.printf("handleCleanStop: Blocking sub-vcore {} of guest {}: mip=0, timer_pending=false\n", .{sub_idx, vc.id});
        } else {
            debug.printf("handleCleanStop: sub-vcore {} of guest {} WFI acts as NOP (mip=0x{x}, timer_pending={})\n", .{ sub_idx, vc.id, mip, timer_pending });
        }

        // Always return true to yield the physical core and prevent emulation.run
        // from overwriting the advanced PC with the old PC.
        return true;
    }

    if (insn != INSN_ECALL) return false; // Not ECALL

    var a7: u32 = 0;
    var a6: u32 = 0;
    var a0: u32 = 0;
    var a1: u32 = 0;
    var a2: u32 = 0;
    _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X17), &a7);
    _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X16), &a6);
    _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X10), &a0);
    _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X11), &a1);
    _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X12), &a2);

    var mock_context = std.mem.zeroes(riscv.ThreadContext);
    mock_context[@intFromEnum(riscv.Register.a7)] = a7;
    mock_context[@intFromEnum(riscv.Register.a6)] = a6;
    mock_context[@intFromEnum(riscv.Register.a0)] = a0;
    mock_context[@intFromEnum(riscv.Register.a1)] = a1;
    mock_context[@intFromEnum(riscv.Register.a2)] = a2;

    sbi.handle(vc, sub_idx, &mock_context);

    const res_a0 = @as(u32, @truncate(mock_context[@intFromEnum(riscv.Register.a0)]));
    const res_a1 = @as(u32, @truncate(mock_context[@intFromEnum(riscv.Register.a1)]));
    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X10), &res_a0);
    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X11), &res_a1);

    var next_pc: u64 = pc + 4;
    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_PC), &next_pc);
    return true;
}

/// Handle a UC_ERR_EXCEPTION by decoding the faulting instruction,
/// synthesizing scause/stval/sepc, and delivering the trap via stvec.
/// Returns the action taken.
pub fn handleException(uc: ?*anyopaque, new_pc: u64) ExceptionAction {
    var stvec: u64 = 0;
    _ = glue.uc_reg_read(uc, UC_REG_STVEC, &stvec);
    if (stvec == 0) return .unhandled;

    var scause: u64 = 12; // Default: instruction page fault
    var stval: u64 = new_pc;

    // Read the faulting instruction. uc_mem_read uses flat addressing,
    // so if the guest has enabled MMU, fall back to Sv32 page table walk.
    var insn: u32 = 0;
    var insn_read_ok = glue.uc_mem_read(uc, new_pc, @as([*]u8, @ptrCast(&insn)), 4) == .UC_ERR_OK;
    if (!insn_read_ok) {
        if (translateVA(uc, new_pc)) |phys_addr| {
            insn_read_ok = glue.uc_mem_read(uc, phys_addr, @as([*]u8, @ptrCast(&insn)), 4) == .UC_ERR_OK;
        }
    }

    if (insn_read_ok) {
        if (insn & 0x3 == 0x3) {
            // 32-bit instruction
            const opcode = insn & 0x7F;
            const funct3 = (insn >> 12) & 0x7;

            if (opcode == 0x73 and funct3 != 0) {
                // CSR instruction — emulate time/cycle/instret.
                const action = emulateCSR(uc, insn, new_pc);
                if (action != null) return action.?;

                // Unknown CSR: illegal instruction
                scause = 2;
                stval = insn;
            } else if (opcode == 0x03 or opcode == 0x07) {
                scause = 13; // Load fault
                stval = inferLoadAddress(uc, insn);
            } else if (opcode == 0x23 or opcode == 0x27) {
                scause = 15; // Store fault
                stval = inferStoreAddress(uc, insn);
            } else if (opcode == 0x2F) {
                scause = 15; // Atomic: store fault
                stval = inferLoadAddress(uc, insn);
            } else if (opcode == 0x73 and funct3 == 0) {
                const action = emulateSystem(uc, insn, new_pc);
                if (action != null) return action.?;

                scause = 2; // Illegal instruction
                stval = insn;
            }
        } else {
            // 16-bit compressed instruction
            classifyCompressedFault(&scause, @truncate(insn));
        }
    }
    // else: can't read instruction at PC → instruction page fault (12)

    // Deliver the trap to the guest's S-mode handler.
    _ = glue.uc_reg_write(uc, UC_REG_SCAUSE, &scause);
    _ = glue.uc_reg_write(uc, UC_REG_STVAL, &stval);
    var sepc_val: u64 = new_pc;
    _ = glue.uc_reg_write(uc, UC_REG_SEPC, &sepc_val);

    // Update mstatus for trap entry (same as deliverInterrupt):
    // save SIE → SPIE, set SPP = 1 (S-mode), clear SIE.
    // CRITICAL: Must write to MSTATUS, not SSTATUS. QEMU's write_sstatus()
    // masks out SPP (bit 8), silently dropping our SPP=1 write. Writing to
    // mstatus directly ensures SPP is actually set, so sret returns to
    // S-mode instead of U-mode.
    var mstatus: u64 = 0;
    _ = glue.uc_reg_read(uc, UC_REG_MSTATUS, &mstatus);

    const SSTATUS_SIE_BIT: u64 = 1 << 1;
    const SSTATUS_SPIE: u64 = 1 << 5;
    const SSTATUS_SPP: u64 = 1 << 8;

    // Save SIE to SPIE
    if (mstatus & SSTATUS_SIE_BIT != 0) {
        mstatus |= SSTATUS_SPIE;
    } else {
        mstatus &= ~SSTATUS_SPIE;
    }
    // Set SPP = 1 (trapping from S-mode)
    mstatus |= SSTATUS_SPP;
    // Clear SIE (disable interrupts in handler)
    mstatus &= ~SSTATUS_SIE_BIT;

    _ = glue.uc_reg_write(uc, UC_REG_MSTATUS, &mstatus);

    const stvec_base = stvec & ~@as(u64, 0x3);
    writePC(uc, stvec_base);

    // Flush Unicorn TLB/TB caches — Unicorn's TCG doesn't respond to
    // guest-issued sfence.vma, so we must flush manually after any trap
    // that may result in page table modifications.
    _ = glue.uc_ctl(uc, @as(c_uint, glue.UC_CTL_FLUSH_TLB));
    _ = glue.uc_ctl(uc, @as(c_uint, glue.UC_CTL_FLUSH_TB));

    return .delivered;
}

// --- Internal helpers ---

/// Map a RISC-V CSR number to the corresponding Unicorn register ID.
/// Returns null if the CSR is not mapped.
fn csrToUcReg(csr: u32) ?c_int {
    return switch (csr) {
        // S-mode CSRs
        0x100 => UC_REG_SSTATUS, // sstatus
        0x104 => @as(c_int, 136), // sie
        0x105 => UC_REG_STVEC, // stvec
        0x106 => @as(c_int, 138), // scounteren
        0x140 => @as(c_int, 139), // sscratch
        0x141 => UC_REG_SEPC, // sepc
        0x142 => UC_REG_SCAUSE, // scause
        0x143 => UC_REG_STVAL, // stval
        0x144 => @as(c_int, 143), // sip
        0x180 => UC_REG_SATP, // satp

        // M-mode CSRs (read-only ID registers)
        0xF11 => @as(c_int, 148), // mvendorid
        0xF12 => @as(c_int, 149), // marchid
        0xF13 => @as(c_int, 150), // mimpid
        // 0xF14 intercepted above

        // M-mode CSRs (delegation and counters)
        0x302 => UC_REG_MEDELEG, // medeleg
        0x303 => UC_REG_MIDELEG, // mideleg
        0x306 => UC_REG_MCOUNTEREN, // mcounteren

        // Unprivileged counter CSRs (lower 32 bits)
        0xC00 => UC_REG_TIME, // cycle (alias time)
        0xC01 => UC_REG_TIME, // time
        0xC02 => UC_REG_TIME, // instret (alias time)
        // Upper 32 bits for RV32
        0xC80 => UC_REG_TIMEH, // cycleh
        0xC81 => UC_REG_TIMEH, // timeh
        0xC82 => UC_REG_TIMEH, // instreth

        else => null,
    };
}

/// Emulate CSR instructions (funct3 != 0 in SYSTEM opcode group).
/// Handles CSRRW/CSRRS/CSRRC and their immediate variants by
/// reading/writing CSRs through the Unicorn API, bypassing QEMU's
/// TCG runtime privilege checks which incorrectly reject valid
/// S-mode CSR accesses.
fn emulateCSR(uc: ?*anyopaque, insn: u32, pc: u64) ?ExceptionAction {
    const csr = insn >> 20;
    const rd: u5 = @truncate((insn >> 7) & 0x1F);
    const rs1_or_imm: u5 = @truncate((insn >> 15) & 0x1F);
    const funct3 = (insn >> 12) & 0x7;

    switch (csr) {
        0xC01, 0xC00, 0xC02 => {
            if (rd != 0) {
                var val: u64 = 0;
                if (pcore.this().active_vcore) |opaque_vc| {
                    const vc: *vcore.VirtualCore = @ptrCast(@alignCast(opaque_vc));
                    val = vc.exec_path.emulated.virtual_time;
                } else {
                    val = glue.readSModeTime();
                }
                _ = glue.uc_reg_write(uc, @as(c_int, @intCast(1 + @as(u32, rd))), &val);
            }
            writePC(uc, pc + 4);
            return .emulated;
        },
        0xC81, 0xC80, 0xC82 => {
            if (rd != 0) {
                var val: u64 = 0;
                if (pcore.this().active_vcore) |opaque_vc| {
                    const vc: *vcore.VirtualCore = @ptrCast(@alignCast(opaque_vc));
                    val = vc.exec_path.emulated.virtual_time >> 32;
                } else {
                    val = glue.readSModeTime() >> 32;
                }
                _ = glue.uc_reg_write(uc, @as(c_int, @intCast(1 + @as(u32, rd))), &val);
            }
            writePC(uc, pc + 4);
            return .emulated;
        },
        0xF14 => { // mhartid
            if (rd != 0) {
                var val: u64 = 0;
                if (pcore.this().active_vcore) |opaque_vc| {
                    const vc: *vcore.VirtualCore = @ptrCast(@alignCast(opaque_vc));
                    val = vc.exec_path.emulated.active_sub_vcore;
                }
                _ = glue.uc_reg_write(uc, @as(c_int, @intCast(1 + @as(u32, rd))), &val);
            }
            writePC(uc, pc + 4);
            return .emulated;
        },
        0xF11, 0xF12, 0xF13 => { // mvendorid, marchid, mimpid
            if (rd != 0) {
                var val: u64 = 0;
                _ = glue.uc_reg_write(uc, @as(c_int, @intCast(1 + @as(u32, rd))), &val);
            }
            writePC(uc, pc + 4);
            return .emulated;
        },
        else => {},
    }

    // Map the CSR number to a Unicorn register ID.
    const uc_reg = csrToUcReg(csr) orelse return null;

    // Read the current CSR value.
    var old_val: u64 = 0;
    _ = glue.uc_reg_read(uc, uc_reg, &old_val);

    // Compute rs1 value: register content for CSRRW/CSRRS/CSRRC,
    // zero-extended immediate for CSRRWI/CSRRSI/CSRRCI.
    var rs1_val: u64 = 0;
    if (funct3 <= 3) {
        // CSRRW (1), CSRRS (2), CSRRC (3): read register rs1
        if (rs1_or_imm != 0) {
            _ = glue.uc_reg_read(uc, @as(c_int, @intCast(1 + @as(u32, rs1_or_imm))), &rs1_val);
        }
    } else {
        // CSRRWI (5), CSRRSI (6), CSRRCI (7): use immediate
        rs1_val = @as(u64, rs1_or_imm);
    }

    // Write the destination register (rd) with the OLD CSR value.
    if (rd != 0) {
        _ = glue.uc_reg_write(uc, @as(c_int, @intCast(1 + @as(u32, rd))), &old_val);
    }

    // Compute and write the new CSR value based on the operation.
    const effective_funct3 = if (funct3 >= 5) funct3 - 4 else funct3;
    var new_val: u64 = old_val;
    switch (effective_funct3) {
        1 => { // CSRRW / CSRRWI: replace
            new_val = rs1_val;
        },
        2 => { // CSRRS / CSRRSI: set bits
            if (rs1_or_imm != 0) {
                new_val = old_val | rs1_val;
            }
        },
        3 => { // CSRRC / CSRRCI: clear bits
            if (rs1_or_imm != 0) {
                new_val = old_val & ~rs1_val;
            }
        },
        else => {},
    }

    // Write the new value back to the CSR (only if modified).
    if (new_val != old_val) {
        _ = glue.uc_reg_write(uc, uc_reg, &new_val);
    }

    writePC(uc, pc + 4);
    return .emulated;
}

/// Emulate SYSTEM instructions with funct3=0 (ECALL/EBREAK/xRET/SFENCE/WFI).
/// Returns .emulated if handled, null otherwise.
fn emulateSystem(uc: ?*anyopaque, insn: u32, pc: u64) ?ExceptionAction {
    if (insn == INSN_WFI) {
        return .wfi;
    }

    const funct7 = insn >> 25;
    if (funct7 == 0x09) {
        // SFENCE.VMA: flush Unicorn's TLB and TB, skip instruction.
        _ = glue.uc_ctl(uc, @as(c_uint, glue.UC_CTL_FLUSH_TLB));
        _ = glue.uc_ctl(uc, @as(c_uint, glue.UC_CTL_FLUSH_TB));
        writePC(uc, pc + 4);
        return .emulated;
    }
    return null;
}

/// Classify a 16-bit compressed instruction fault into scause.
fn classifyCompressedFault(scause: *u64, c_insn: u16) void {
    const quadrant = c_insn & 0x3;
    const c_funct3 = (c_insn >> 13) & 0x7;
    if (quadrant == 0x0 and c_funct3 == 0x2) {
        scause.* = 13; // C.LW
    } else if (quadrant == 0x0 and c_funct3 == 0x6) {
        scause.* = 15; // C.SW
    } else if (quadrant == 0x2 and c_funct3 == 0x2) {
        scause.* = 13; // C.LWSP
    } else if (quadrant == 0x2 and c_funct3 == 0x6) {
        scause.* = 15; // C.SWSP
    }
}

/// Walk an Sv32 page table to translate a virtual address to physical.
/// Returns the physical address or null if translation fails.
pub fn translateVA(uc: ?*anyopaque, vaddr: u64) ?u64 {
    var satp: u64 = 0;
    _ = glue.uc_reg_read(uc, UC_REG_SATP, &satp);

    // Sv32 satp: bit 31 = MODE (1=Sv32), bits 21:0 = PPN
    if (satp & (1 << 31) == 0) return null; // MMU disabled

    const root_ppn: u32 = @truncate(satp & SV32_PPN_MASK);
    const va: u32 = @truncate(vaddr);
    const vpn1: u32 = (va >> 22) & 0x3FF;
    const vpn0: u32 = (va >> 12) & 0x3FF;
    const page_offset: u32 = va & 0xFFF;

    // Level 1: read PTE from root page table
    const l1_addr: u64 = (@as(u64, root_ppn) << 12) + (@as(u64, vpn1) * 4);
    var l1_pte: u32 = 0;
    if (glue.uc_mem_read(uc, l1_addr, @as([*]u8, @ptrCast(&l1_pte)), 4) != .UC_ERR_OK) return null;

    if (l1_pte & 0x1 == 0) return null; // Not valid
    if (l1_pte & 0xE != 0) {
        // Superpage (4MB): PPN[1] from PTE, VPN[0] from VA
        const ppn1: u32 = (l1_pte >> 20) & 0xFFF;
        return (@as(u64, ppn1) << 22) | (@as(u64, vpn0) << 12) | @as(u64, page_offset);
    }

    // Level 0: second-level page table
    const l0_ppn: u32 = (l1_pte >> 10) & SV32_PPN_MASK;
    const l0_addr: u64 = (@as(u64, l0_ppn) << 12) + (@as(u64, vpn0) * 4);
    var l0_pte: u32 = 0;
    if (glue.uc_mem_read(uc, l0_addr, @as([*]u8, @ptrCast(&l0_pte)), 4) != .UC_ERR_OK) return null;

    if (l0_pte & 0x1 == 0) return null;
    if (l0_pte & 0xE == 0) return null; // Pointer PTE at leaf level

    const phys_ppn: u32 = (l0_pte >> 10) & SV32_PPN_MASK;
    return (@as(u64, phys_ppn) << 12) | @as(u64, page_offset);
}

/// Read a RISC-V general purpose register (x0-x31) from Unicorn.
fn readGPR(uc: ?*anyopaque, reg_num: u5) u64 {
    if (reg_num == 0) return 0;
    var val: u64 = 0;
    _ = glue.uc_reg_read(uc, @as(c_int, @intCast(1 + @as(u32, reg_num))), &val);
    return val;
}

/// Compute the target address of an I-type load instruction.
fn inferLoadAddress(uc: ?*anyopaque, insn: u32) u64 {
    const rs1: u5 = @truncate((insn >> 15) & 0x1F);
    const imm_raw: u32 = insn >> 20;
    const imm: i32 = @bitCast(if (imm_raw & 0x800 != 0) imm_raw | 0xFFFFF000 else imm_raw);
    const base: i64 = @bitCast(readGPR(uc, rs1));
    return @bitCast(base +% @as(i64, imm));
}

/// Compute the target address of an S-type store instruction.
fn inferStoreAddress(uc: ?*anyopaque, insn: u32) u64 {
    const rs1: u5 = @truncate((insn >> 15) & 0x1F);
    const imm_lo: u32 = (insn >> 7) & 0x1F;
    const imm_hi: u32 = (insn >> 25) & 0x7F;
    const imm_raw: u32 = (imm_hi << 5) | imm_lo;
    const imm: i32 = @bitCast(if (imm_raw & 0x800 != 0) imm_raw | 0xFFFFF000 else imm_raw);
    const base: i64 = @bitCast(readGPR(uc, rs1));
    return @bitCast(base +% @as(i64, imm));
}

/// Deliver an interrupt to the guest S-mode trap handler.
/// Replicates what RISC-V hardware does on interrupt:
///   1. sepc = current PC (return address after handler)
///   2. scause = cause | (1 << 31) for interrupt bit
///   3. stval = 0
///   4. sstatus: SPIE = SIE, SPP = 1 (S-mode), SIE = 0
///   5. PC = stvec base
pub fn deliverInterrupt(uc: ?*anyopaque, current_pc: u64, cause: u64) void {
    _ = current_pc; // env->pc is read directly by do_interrupt
    // Use QEMU's native riscv_cpu_do_interrupt for proper interrupt delivery.
    // This correctly handles mstatus SPIE/SPP/SIE manipulation, privilege
    // mode transitions, and delegation checking — all using direct env->
    // field access that bypasses the CSR privilege check in riscv_csrrw
    // (which would deny S-mode access to M-mode CSRs like mstatus).
    glue.diosix_uc_inject_interrupt(uc, @intCast(cause));

    // Flush Unicorn TLB/TB caches — matching handleException. Without this,
    // QEMU may reuse a stale TB from the interrupted context, causing the
    // trap handler's instructions (e.g. csrrw sscratch) to execute with
    // the wrong CSR state.
    _ = glue.uc_ctl(uc, @as(c_uint, glue.UC_CTL_FLUSH_TLB));
    _ = glue.uc_ctl(uc, @as(c_uint, glue.UC_CTL_FLUSH_TB));
}
