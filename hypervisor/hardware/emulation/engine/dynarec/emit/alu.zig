// RV64 Native ALU, Multiply, CSR & Control-Flow JIT Emitter Helpers.
//
// Emits host RV64 instructions for guest RV32 integer, multiply/divide, and
// performance-counter CSR operations with 1-to-1 register pinning
// (saving/restoring host scratch x5/x6 and context pointer x27/s11).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const rv64 = @import("../../emitters/rv64.zig");
const cache_mod = @import("../cache.zig");
const block_mod = @import("../block.zig");
const branch_mod = @import("branch.zig");
const riscv = @import("interface").riscv;

const TranslationBlock = block_mod.TranslationBlock;
const T0 = block_mod.HOST_REG_T0;
const T1 = block_mod.HOST_REG_T1;
const S11 = block_mod.HOST_REG_S11;
const OFF_T0 = block_mod.VCPU_OFF_T0;
const OFF_T1 = block_mod.VCPU_OFF_T1;
const OFF_S11 = block_mod.VCPU_OFF_S11;

pub const WORD_BITS: u6 = 32;

pub const emitJumpToDispatcher = branch_mod.emitJumpToDispatcher;
pub const emitExit = branch_mod.emitExit;
pub const emitBranch = branch_mod.emitBranch;
pub const emitBranchExit = branch_mod.emitBranchExit;
pub const emitJalrExit = branch_mod.emitJalrExit;

inline fn emit(tb: *TranslationBlock, off: *usize, insn: u32) void {
    rv64.emit(tb.host_code, off, insn);
}

pub fn emitLoadImm32(
    tb: *TranslationBlock,
    off: *usize,
    rd: u5,
    val: u32,
) void {
    if (rd == 0) return;
    const sp = rv64.splitImm32(val);
    if (rd == S11) {
        emit(tb, off, rv64.sd(S11, T0, OFF_T0));
        emit(tb, off, rv64.lui(T0, sp.upper));
        emit(tb, off, rv64.addiw(T0, T0, sp.lower));
        emit(tb, off, rv64.sd(S11, T0, OFF_S11));
        emit(tb, off, rv64.ld(T0, S11, OFF_T0));
    } else {
        emit(tb, off, rv64.lui(rd, sp.upper));
        emit(tb, off, rv64.addiw(rd, rd, sp.lower));
    }
}

pub fn resolveSavedSource(
    tb: *TranslationBlock,
    off: *usize,
    scratch: u5,
    guest_reg: u5,
) u5 {
    if (guest_reg == T0) {
        emit(tb, off, rv64.ld(scratch, S11, OFF_T0));
        return scratch;
    } else if (guest_reg == T1) {
        emit(tb, off, rv64.ld(scratch, S11, OFF_T1));
        return scratch;
    } else if (guest_reg == S11) {
        emit(tb, off, rv64.ld(scratch, S11, OFF_S11));
        return scratch;
    }
    return guest_reg;
}

fn writeBackResultAndRestore(
    tb: *TranslationBlock,
    off: *usize,
    rd: u5,
) void {
    if (rd == S11) {
        emit(tb, off, rv64.sd(S11, T0, OFF_S11));
        emit(tb, off, rv64.ld(T1, S11, OFF_T1));
        emit(tb, off, rv64.ld(T0, S11, OFF_T0));
    } else if (rd == T0) {
        emit(tb, off, rv64.ld(T1, S11, OFF_T1));
    } else if (rd == T1) {
        emit(tb, off, rv64.addiw(T1, T0, 0));
        emit(tb, off, rv64.ld(T0, S11, OFF_T0));
    } else {
        emit(tb, off, rv64.ld(T1, S11, OFF_T1));
        emit(tb, off, rv64.ld(T0, S11, OFF_T0));
    }
}

pub inline fn emitRType(
    tb: *TranslationBlock,
    off: *usize,
    comptime op_fn: fn (u5, u5, u5) u32,
    rd: u5,
    rs1: u5,
    rs2: u5,
) void {
    if (rd == 0) return;
    if (rd != S11 and rs1 != S11 and rs2 != S11) {
        emit(tb, off, op_fn(rd, rs1, rs2));
        return;
    }
    emit(tb, off, rv64.sd(S11, T0, OFF_T0));
    emit(tb, off, rv64.sd(S11, T1, OFF_T1));

    const r1 = resolveSavedSource(tb, off, T0, rs1);
    const r2 = resolveSavedSource(tb, off, T1, rs2);
    const target_reg: u5 = if (rd == S11 or rd == T0 or rd == T1) T0 else rd;
    emit(tb, off, op_fn(target_reg, r1, r2));
    writeBackResultAndRestore(tb, off, rd);
}

fn resolveSingleSource5(
    tb: *TranslationBlock,
    off: *usize,
    rs1: u5,
) u5 {
    if (rs1 == T0) {
        emit(tb, off, rv64.ld(T0, S11, OFF_T0));
        return T0;
    } else if (rs1 == S11) {
        emit(tb, off, rv64.ld(T0, S11, OFF_S11));
        return T0;
    }
    return rs1;
}

fn writeBackSingle5(
    tb: *TranslationBlock,
    off: *usize,
    rd: u5,
) void {
    if (rd == S11) {
        emit(tb, off, rv64.sd(S11, T0, OFF_S11));
        emit(tb, off, rv64.ld(T0, S11, OFF_T0));
    } else if (rd != T0) {
        emit(tb, off, rv64.ld(T0, S11, OFF_T0));
    }
}

pub inline fn emitIType(
    tb: *TranslationBlock,
    off: *usize,
    comptime op_fn: fn (u5, u5, i12) u32,
    rd: u5,
    rs1: u5,
    imm: i12,
) void {
    if (rd == 0) return;
    if (rd != S11 and rs1 != S11) {
        emit(tb, off, op_fn(rd, rs1, imm));
        return;
    }
    emit(tb, off, rv64.sd(S11, T0, OFF_T0));
    const r1 = resolveSingleSource5(tb, off, rs1);
    const target_reg: u5 = if (rd == S11 or rd == T0) T0 else rd;
    emit(tb, off, op_fn(target_reg, r1, imm));
    writeBackSingle5(tb, off, rd);
}

pub inline fn emitShiftI(
    tb: *TranslationBlock,
    off: *usize,
    comptime op_fn: fn (u5, u5, u5) u32,
    rd: u5,
    rs1: u5,
    shamt: u5,
) void {
    if (rd == 0) return;
    if (rd != S11 and rs1 != S11) {
        emit(tb, off, op_fn(rd, rs1, shamt));
        return;
    }
    emit(tb, off, rv64.sd(S11, T0, OFF_T0));
    const r1 = resolveSingleSource5(tb, off, rs1);
    const target_reg: u5 = if (rd == S11 or rd == T0) T0 else rd;
    emit(tb, off, op_fn(target_reg, r1, shamt));
    writeBackSingle5(tb, off, rd);
}

pub inline fn emitBitwiseR(
    tb: *TranslationBlock,
    off: *usize,
    comptime op_fn: fn (u5, u5, u5) u32,
    rd: u5,
    rs1: u5,
    rs2: u5,
) void {
    if (rd == 0) return;
    if (rd != S11 and rs1 != S11 and rs2 != S11) {
        emit(tb, off, op_fn(rd, rs1, rs2));
        emit(tb, off, rv64.addiw(rd, rd, 0));
        return;
    }
    emit(tb, off, rv64.sd(S11, T0, OFF_T0));
    emit(tb, off, rv64.sd(S11, T1, OFF_T1));

    const r1 = resolveSavedSource(tb, off, T0, rs1);
    const r2 = resolveSavedSource(tb, off, T1, rs2);
    const target_reg: u5 = if (rd == S11 or rd == T0 or rd == T1) T0 else rd;
    emit(tb, off, op_fn(target_reg, r1, r2));
    emit(tb, off, rv64.addiw(target_reg, target_reg, 0));
    writeBackResultAndRestore(tb, off, rd);
}

pub inline fn emitBitwiseI(
    tb: *TranslationBlock,
    off: *usize,
    comptime op_fn: fn (u5, u5, i12) u32,
    rd: u5,
    rs1: u5,
    imm: i12,
) void {
    if (rd == 0) return;
    if (rd != S11 and rs1 != S11) {
        emit(tb, off, op_fn(rd, rs1, imm));
        emit(tb, off, rv64.addiw(rd, rd, 0));
        return;
    }
    emit(tb, off, rv64.sd(S11, T0, OFF_T0));
    const r1 = resolveSingleSource5(tb, off, rs1);
    const target_reg: u5 = if (rd == S11 or rd == T0) T0 else rd;
    emit(tb, off, op_fn(target_reg, r1, imm));
    emit(tb, off, rv64.addiw(target_reg, target_reg, 0));
    writeBackSingle5(tb, off, rd);
}

pub fn emitMulh(
    tb: *TranslationBlock,
    off: *usize,
    rd: u5,
    rs1: u5,
    rs2: u5,
) void {
    if (rd == 0) return;
    emit(tb, off, rv64.sd(S11, T0, OFF_T0));
    emit(tb, off, rv64.sd(S11, T1, OFF_T1));
    const r1 = resolveSavedSource(tb, off, T0, rs1);
    emit(tb, off, rv64.addiw(T0, r1, 0));
    const r2 = resolveSavedSource(tb, off, T1, rs2);
    emit(tb, off, rv64.addiw(T1, r2, 0));
    finishMulHigh(tb, off, rd);
}

fn emitZeroExtendGuestReg(
    tb: *TranslationBlock,
    off: *usize,
    dst: u5,
    src_reg: u5,
) void {
    if (src_reg == 0) {
        emit(tb, off, rv64.addiw(dst, 0, 0));
        return;
    }
    const r = resolveSavedSource(tb, off, dst, src_reg);
    emit(tb, off, rv64.slli(dst, r, WORD_BITS));
    emit(tb, off, rv64.srli(dst, dst, WORD_BITS));
}

fn finishMulHigh(tb: *TranslationBlock, off: *usize, rd: u5) void {
    emit(tb, off, rv64.mul(T0, T0, T1));
    emit(tb, off, rv64.srai(T0, T0, WORD_BITS));

    if (rd == T0) {
        emit(tb, off, rv64.sd(S11, T0, OFF_T0));
        emit(tb, off, rv64.ld(T1, S11, OFF_T1));
        emit(tb, off, rv64.ld(T0, S11, OFF_T0));
    } else if (rd == T1 or rd == S11) {
        writeBackResultAndRestore(tb, off, rd);
    } else {
        emit(tb, off, rv64.addiw(rd, T0, 0));
        emit(tb, off, rv64.ld(T1, S11, OFF_T1));
        emit(tb, off, rv64.ld(T0, S11, OFF_T0));
    }
}

pub fn emitMulhu(
    tb: *TranslationBlock,
    off: *usize,
    rd: u5,
    rs1: u5,
    rs2: u5,
) void {
    if (rd == 0) return;
    emit(tb, off, rv64.sd(S11, T0, OFF_T0));
    emit(tb, off, rv64.sd(S11, T1, OFF_T1));
    emitZeroExtendGuestReg(tb, off, T0, rs1);
    emitZeroExtendGuestReg(tb, off, T1, rs2);
    finishMulHigh(tb, off, rd);
}

pub fn emitMulhsu(
    tb: *TranslationBlock,
    off: *usize,
    rd: u5,
    rs1: u5,
    rs2: u5,
) void {
    if (rd == 0) return;
    emit(tb, off, rv64.sd(S11, T0, OFF_T0));
    emit(tb, off, rv64.sd(S11, T1, OFF_T1));
    const r1 = resolveSavedSource(tb, off, T0, rs1);
    emit(tb, off, rv64.addiw(T0, r1, 0));
    emitZeroExtendGuestReg(tb, off, T1, rs2);
    finishMulHigh(tb, off, rd);
}

pub const CounterCsrMapping = struct { host_csr: u12, is_high: bool };

pub inline fn mapPerformanceCounterCsr(csr: u12) ?CounterCsrMapping {
    const C = riscv.CSR;
    return switch (csr) {
        C.CYCLE => .{ .host_csr = C.CYCLE, .is_high = false },
        C.TIME => .{ .host_csr = C.TIME, .is_high = false },
        C.INSTRET => .{ .host_csr = C.INSTRET, .is_high = false },
        C.CYCLEH => .{ .host_csr = C.CYCLE, .is_high = true },
        C.TIMEH => .{ .host_csr = C.TIME, .is_high = true },
        C.INSTRETH => .{ .host_csr = C.INSTRET, .is_high = true },
        else => null,
    };
}

pub inline fn emitCsrRead(
    tb: *TranslationBlock,
    off: *usize,
    rd: u5,
    host_csr: u12,
    is_high: bool,
) void {
    if (rd == 0) return;
    if (rd == S11) {
        emit(tb, off, rv64.sd(S11, T0, OFF_T0));
        emit(tb, off, rv64.csrrs(T0, host_csr, 0));
        if (is_high) emit(tb, off, rv64.srli(T0, T0, WORD_BITS));
        emit(tb, off, rv64.addiw(T0, T0, 0));
        emit(tb, off, rv64.sd(S11, T0, OFF_S11));
        emit(tb, off, rv64.ld(T0, S11, OFF_T0));
    } else {
        emit(tb, off, rv64.csrrs(rd, host_csr, 0));
        if (is_high) emit(tb, off, rv64.srli(rd, rd, WORD_BITS));
        emit(tb, off, rv64.addiw(rd, rd, 0));
    }
}

test "emitLoadImm32 and emitRType emit valid RV64 instructions" {
    _ = branch_mod;
    const cache_inst = try std.testing.allocator.create(cache_mod.Cache);
    defer std.testing.allocator.destroy(cache_inst);
    var raw_pool: [256]u8 align(4096) = undefined;
    cache_inst.initOnPtr(&raw_pool);
    const tb = try cache_inst.allocateBlock(0x8000_0000, 0, false, 64);
    var off: usize = 0;

    emitLoadImm32(tb, &off, 10, 0x8000_1234);
    emitRType(tb, &off, rv64.addw, 10, 10, 11);
    try std.testing.expectEqual(@as(usize, 12), off);
    std.testing.refAllDecls(@This());
}
