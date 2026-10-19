// RV64 Native ALU, Multiply, CSR & Control-Flow JIT Emitter Helpers.
//
// Emits host RV64 instructions for guest RV32 integer, multiply/divide,
// performance-counter CSR, and branch/jump operations with 1-to-1 register
// pinning (saving/restoring host scratch x5/x6 and context pointer x27/s11).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const decoder_rv32 = @import("../../decoders/rv32.zig");
const rv64 = @import("../../emitters/rv64.zig");
const cache_mod = @import("../cache.zig");
const block_mod = @import("../block.zig");
const riscv = @import("interface").riscv;

const TranslationBlock = block_mod.TranslationBlock;

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
    const val_offset = val +% 0x800;
    const upper = @as(i20, @truncate(@as(i32, @bitCast(val_offset >> 12))));
    const lower = @as(i12, @truncate(@as(i32, @bitCast(val & 0xfff))));
    if (rd == 27) {
        emit(tb, off, rv64.sd(27, 5, 40));
        emit(tb, off, rv64.lui(5, upper));
        emit(tb, off, rv64.addiw(5, 5, lower));
        emit(tb, off, rv64.sd(27, 5, 216));
        emit(tb, off, rv64.ld(5, 27, 40));
    } else {
        emit(tb, off, rv64.lui(rd, upper));
        emit(tb, off, rv64.addiw(rd, rd, lower));
    }
}

fn emitJumpToDispatcher(tb: *TranslationBlock, off: *usize) usize {
    const exit_addr = cache_mod.getExitAddr();
    const patch_off = off.*;
    const src = @intFromPtr(tb.host_code.ptr) + patch_off;
    const rel = @as(isize, @bitCast(exit_addr)) - @as(isize, @bitCast(src));
    const j_upper = @as(i20, @truncate((rel + 0x800) >> 12));
    const rel_u12: u12 = @truncate(@as(usize, @bitCast(rel)) & 0xfff);
    const j_lower: i12 = @bitCast(rel_u12);
    emit(tb, off, rv64.auipc(5, j_upper));
    emit(tb, off, rv64.jalr(0, 5, j_lower));
    return patch_off;
}

pub fn emitExit(
    tb: *TranslationBlock,
    off: *usize,
    target_pc: u32,
) block_mod.ExitBranch {
    const pc_i32 = @as(i32, @bitCast(target_pc));
    const upper = @as(i20, @truncate((pc_i32 +% 0x800) >> 12));
    const lower = @as(i12, @bitCast(@as(u12, @truncate(target_pc & 0xfff))));

    emit(tb, off, rv64.sd(27, 5, 40));
    emit(tb, off, rv64.lui(5, upper));
    emit(tb, off, rv64.addiw(5, 5, lower));
    emit(tb, off, rv64.sw(27, 5, 256));
    const patch_off = emitJumpToDispatcher(tb, off);

    return block_mod.ExitBranch{
        .patch_offset = patch_off,
        .target_guest_pc = target_pc,
        .is_direct = true,
    };
}

fn resolveSavedSource(
    tb: *TranslationBlock,
    off: *usize,
    scratch: u5,
    guest_reg: u5,
) u5 {
    if (guest_reg == 5) {
        emit(tb, off, rv64.ld(scratch, 27, 40));
        return scratch;
    } else if (guest_reg == 6) {
        emit(tb, off, rv64.ld(scratch, 27, 48));
        return scratch;
    } else if (guest_reg == 27) {
        emit(tb, off, rv64.ld(scratch, 27, 216));
        return scratch;
    }
    return guest_reg;
}

fn writeBackResultAndRestore(
    tb: *TranslationBlock,
    off: *usize,
    rd: u5,
) void {
    if (rd == 27) {
        emit(tb, off, rv64.sd(27, 5, 216));
        emit(tb, off, rv64.ld(6, 27, 48));
        emit(tb, off, rv64.ld(5, 27, 40));
    } else if (rd == 5) {
        emit(tb, off, rv64.ld(6, 27, 48));
    } else if (rd == 6) {
        emit(tb, off, rv64.addiw(6, 5, 0));
        emit(tb, off, rv64.ld(5, 27, 40));
    } else {
        emit(tb, off, rv64.ld(6, 27, 48));
        emit(tb, off, rv64.ld(5, 27, 40));
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
    if (rd != 27 and rs1 != 27 and rs2 != 27) {
        emit(tb, off, op_fn(rd, rs1, rs2));
        return;
    }
    emit(tb, off, rv64.sd(27, 5, 40));
    emit(tb, off, rv64.sd(27, 6, 48));

    const r1 = resolveSavedSource(tb, off, 5, rs1);
    const r2 = resolveSavedSource(tb, off, 6, rs2);
    const target_reg: u5 = if (rd == 27 or rd == 5 or rd == 6) 5 else rd;
    emit(tb, off, op_fn(target_reg, r1, r2));
    writeBackResultAndRestore(tb, off, rd);
}

fn resolveSingleSource5(
    tb: *TranslationBlock,
    off: *usize,
    rs1: u5,
) u5 {
    if (rs1 == 5) {
        emit(tb, off, rv64.ld(5, 27, 40));
        return 5;
    } else if (rs1 == 27) {
        emit(tb, off, rv64.ld(5, 27, 216));
        return 5;
    }
    return rs1;
}

fn writeBackSingle5(
    tb: *TranslationBlock,
    off: *usize,
    rd: u5,
) void {
    if (rd == 27) {
        emit(tb, off, rv64.sd(27, 5, 216));
        emit(tb, off, rv64.ld(5, 27, 40));
    } else if (rd != 5) {
        emit(tb, off, rv64.ld(5, 27, 40));
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
    if (rd != 27 and rs1 != 27) {
        emit(tb, off, op_fn(rd, rs1, imm));
        return;
    }
    emit(tb, off, rv64.sd(27, 5, 40));
    const r1 = resolveSingleSource5(tb, off, rs1);
    const target_reg: u5 = if (rd == 27 or rd == 5) 5 else rd;
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
    if (rd != 27 and rs1 != 27) {
        emit(tb, off, op_fn(rd, rs1, shamt));
        return;
    }
    emit(tb, off, rv64.sd(27, 5, 40));
    const r1 = resolveSingleSource5(tb, off, rs1);
    const target_reg: u5 = if (rd == 27 or rd == 5) 5 else rd;
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
    if (rd != 27 and rs1 != 27 and rs2 != 27) {
        emit(tb, off, op_fn(rd, rs1, rs2));
        emit(tb, off, rv64.addiw(rd, rd, 0));
        return;
    }
    emit(tb, off, rv64.sd(27, 5, 40));
    emit(tb, off, rv64.sd(27, 6, 48));

    const r1 = resolveSavedSource(tb, off, 5, rs1);
    const r2 = resolveSavedSource(tb, off, 6, rs2);
    const target_reg: u5 = if (rd == 27 or rd == 5 or rd == 6) 5 else rd;
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
    if (rd != 27 and rs1 != 27) {
        emit(tb, off, op_fn(rd, rs1, imm));
        emit(tb, off, rv64.addiw(rd, rd, 0));
        return;
    }
    emit(tb, off, rv64.sd(27, 5, 40));
    const r1 = resolveSingleSource5(tb, off, rs1);
    const target_reg: u5 = if (rd == 27 or rd == 5) 5 else rd;
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
    emit(tb, off, rv64.mul(rd, rs1, rs2));
    emit(tb, off, rv64.srai(rd, rd, 32));
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
    emit(tb, off, rv64.slli(dst, r, 32));
    emit(tb, off, rv64.srli(dst, dst, 32));
}

fn finishMulHigh(tb: *TranslationBlock, off: *usize, rd: u5) void {
    emit(tb, off, rv64.mul(5, 5, 6));
    emit(tb, off, rv64.srai(5, 5, 32));

    if (rd == 5) {
        emit(tb, off, rv64.sd(27, 5, 40));
        emit(tb, off, rv64.ld(6, 27, 48));
        emit(tb, off, rv64.ld(5, 27, 40));
    } else if (rd == 6 or rd == 27) {
        writeBackResultAndRestore(tb, off, rd);
    } else {
        emit(tb, off, rv64.addiw(rd, 5, 0));
        emit(tb, off, rv64.ld(6, 27, 48));
        emit(tb, off, rv64.ld(5, 27, 40));
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
    emit(tb, off, rv64.sd(27, 5, 40));
    emit(tb, off, rv64.sd(27, 6, 48));
    emitZeroExtendGuestReg(tb, off, 5, rs1);
    emitZeroExtendGuestReg(tb, off, 6, rs2);
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
    emit(tb, off, rv64.sd(27, 5, 40));
    emit(tb, off, rv64.sd(27, 6, 48));
    const r1 = resolveSavedSource(tb, off, 5, rs1);
    emit(tb, off, rv64.addiw(5, r1, 0));
    emitZeroExtendGuestReg(tb, off, 6, rs2);
    finishMulHigh(tb, off, rd);
}

pub const CounterCsrMapping = struct { host_csr: u32, is_high: bool };

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
    host_csr: u32,
    is_high: bool,
) void {
    if (rd == 0) return;
    if (rd == 27) {
        emit(tb, off, rv64.sd(27, 5, 40));
        emit(tb, off, (host_csr << 20) | (5 << 7) | 0x2073);
        if (is_high) emit(tb, off, rv64.srli(5, 5, 32));
        emit(tb, off, rv64.addiw(5, 5, 0));
        emit(tb, off, rv64.sd(27, 5, 216));
        emit(tb, off, rv64.ld(5, 27, 40));
    } else {
        emit(tb, off, (host_csr << 20) | (@as(u32, rd) << 7) | 0x2073);
        if (is_high) emit(tb, off, rv64.srli(rd, rd, 32));
        emit(tb, off, rv64.addiw(rd, rd, 0));
    }
}

pub inline fn emitBranch(
    tb: *TranslationBlock,
    off: *usize,
    current_pc: u32,
    offset: i32,
    decoded_len: u32,
    rs1: u5,
    rs2: u5,
    comptime branch_fn: fn (u5, u5, i13) u32,
) struct { exit1: block_mod.ExitBranch, exit2: block_mod.ExitBranch } {
    const target = current_pc +% @as(u32, @bitCast(offset));
    const fallthrough = current_pc + decoded_len;

    var r1: u5 = rs1;
    var r2: u5 = rs2;

    if (rs1 == 27 or rs2 == 27) {
        emit(tb, off, rv64.sd(27, 5, 40));
        emit(tb, off, rv64.sd(27, 6, 48));
        r1 = resolveSavedSource(tb, off, 5, rs1);
        r2 = resolveSavedSource(tb, off, 6, rs2);
    }

    const branch_patch_pos = off.*;
    emit(tb, off, 0); // Placeholder.
    if (rs1 == 27 or rs2 == 27) {
        emit(tb, off, rv64.ld(6, 27, 48));
        emit(tb, off, rv64.ld(5, 27, 40));
    }
    const exit2 = emitExit(tb, off, fallthrough);
    const target_pos = off.*;
    const branch_rel = @as(
        i13,
        @truncate(@as(isize, @intCast(target_pos - branch_patch_pos))),
    );
    std.mem.writeInt(
        u32,
        tb.host_code[branch_patch_pos..][0..4],
        branch_fn(r1, r2, branch_rel),
        .little,
    );
    if (rs1 == 27 or rs2 == 27) {
        emit(tb, off, rv64.ld(6, 27, 48));
        emit(tb, off, rv64.ld(5, 27, 40));
    }
    const exit1 = emitExit(tb, off, target);
    return .{ .exit1 = exit1, .exit2 = exit2 };
}

pub fn emitBranchExit(
    tb: *TranslationBlock,
    off: *usize,
    pc: u32,
    len: u32,
    d: decoder_rv32.BType,
    comptime branch_fn: fn (u5, u5, i13) u32,
) void {
    const exits = emitBranch(
        tb,
        off,
        pc,
        d.offset,
        len,
        d.rs1,
        d.rs2,
        branch_fn,
    );
    tb.exit_branch1 = exits.exit1;
    tb.exit_branch2 = exits.exit2;
}

pub fn emitJalrExit(
    tb: *TranslationBlock,
    off: *usize,
    current_pc: u32,
    decoded_len: u32,
    rd: u5,
    rs1: u5,
    offset: i32,
) void {
    const imm = @as(i12, @truncate(offset));
    emit(tb, off, rv64.sd(27, 5, 40));
    emit(tb, off, rv64.sd(27, 6, 48));

    const r_src: u5 = if (rs1 == 5 or rs1 == 6 or rs1 == 27)
        resolveSavedSource(tb, off, 6, rs1)
    else
        rs1;
    emit(tb, off, rv64.addiw(6, r_src, imm));
    emit(tb, off, rv64.andi(6, 6, -2));
    emit(tb, off, rv64.sw(27, 6, 256));

    const link_pc = current_pc + decoded_len;
    const link_offset = link_pc +% 0x800;
    const l_upper = @as(i20, @truncate(@as(i32, @bitCast(link_offset >> 12))));
    const l_lower = @as(i12, @truncate(@as(i32, @bitCast(link_pc & 0xfff))));

    if (rd == 5 or rd == 6 or rd == 27) {
        emit(tb, off, rv64.lui(6, l_upper));
        emit(tb, off, rv64.addiw(6, 6, l_lower));
        if (rd == 5) {
            emit(tb, off, rv64.sd(27, 6, 40));
            emit(tb, off, rv64.ld(6, 27, 48));
        } else if (rd == 27) {
            emit(tb, off, rv64.sd(27, 6, 216));
            emit(tb, off, rv64.ld(6, 27, 48));
        }
    } else if (rd != 0) {
        emit(tb, off, rv64.lui(rd, l_upper));
        emit(tb, off, rv64.addiw(rd, rd, l_lower));
        emit(tb, off, rv64.ld(6, 27, 48));
    } else {
        emit(tb, off, rv64.ld(6, 27, 48));
    }

    _ = emitJumpToDispatcher(tb, off);
}

test "emitLoadImm32 and emitRType emit valid RV64 instructions" {
    const cache_inst = try std.testing.allocator.create(cache_mod.Cache);
    defer std.testing.allocator.destroy(cache_inst);
    var raw_pool: [256]u8 align(4096) = undefined;
    cache_inst.initOnPtr(&raw_pool);
    const tb = try cache_inst.allocateBlock(0x8000_0000, 0, false, 64);
    var off: usize = 0;

    emitLoadImm32(tb, &off, 10, 0x8000_1234);
    emitRType(tb, &off, rv64.addw, 10, 10, 11);
    try std.testing.expectEqual(@as(usize, 12), off);
}
