// RV64 Control-Flow & Branch Exit JIT Emitter Helpers.
//
// Emits host RV64 branch, jump-and-link-register, and block exit sequences
// for guest RV32 control-flow instructions.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const decoder_rv32 = @import("../../decoders/rv32.zig");
const rv64 = @import("../../emitters/rv64.zig");
const cache_mod = @import("../cache.zig");
const block_mod = @import("../block.zig");
const emit_alu = @import("alu.zig");

const TranslationBlock = block_mod.TranslationBlock;
const T0 = block_mod.HOST_REG_T0;
const T1 = block_mod.HOST_REG_T1;
const S11 = block_mod.HOST_REG_S11;
const OFF_T0 = block_mod.VCPU_OFF_T0;
const OFF_T1 = block_mod.VCPU_OFF_T1;
const OFF_S11 = block_mod.VCPU_OFF_S11;
const OFF_PC = block_mod.VCPU_OFF_PC;

pub const INSN_PLACEHOLDER: u32 = 0;
pub const JALR_CLEAR_LSB_MASK: i12 = -2;

inline fn emit(tb: *TranslationBlock, off: *usize, insn: u32) void {
    rv64.emit(tb.host_code, off, insn);
}

pub fn emitJumpToDispatcher(tb: *TranslationBlock, off: *usize) usize {
    const exit_addr = cache_mod.getExitAddr();
    const patch_off = off.*;
    const src = @intFromPtr(tb.host_code.ptr) + patch_off;
    const rel = @as(isize, @bitCast(exit_addr)) - @as(isize, @bitCast(src));
    const sp = rv64.splitImm32(@truncate(@as(usize, @bitCast(rel))));
    emit(tb, off, rv64.auipc(T0, sp.upper));
    emit(tb, off, rv64.jalr(0, T0, sp.lower));
    return patch_off;
}

pub fn emitExit(
    tb: *TranslationBlock,
    off: *usize,
    target_pc: u32,
) block_mod.ExitBranch {
    const sp = rv64.splitImm32(target_pc);
    emit(tb, off, rv64.sd(S11, T0, OFF_T0));
    emit(tb, off, rv64.lui(T0, sp.upper));
    emit(tb, off, rv64.addiw(T0, T0, sp.lower));
    emit(tb, off, rv64.sw(S11, T0, OFF_PC));
    const patch_off = emitJumpToDispatcher(tb, off);

    return block_mod.ExitBranch{
        .patch_offset = patch_off,
        .target_guest_pc = target_pc,
        .is_direct = true,
    };
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

    if (rs1 == S11 or rs2 == S11) {
        emit(tb, off, rv64.sd(S11, T0, OFF_T0));
        emit(tb, off, rv64.sd(S11, T1, OFF_T1));
        r1 = emit_alu.resolveSavedSource(tb, off, T0, rs1);
        r2 = emit_alu.resolveSavedSource(tb, off, T1, rs2);
    }

    const branch_patch_pos = off.*;
    emit(tb, off, INSN_PLACEHOLDER);
    if (rs1 == S11 or rs2 == S11) {
        emit(tb, off, rv64.ld(T1, S11, OFF_T1));
        emit(tb, off, rv64.ld(T0, S11, OFF_T0));
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
    if (rs1 == S11 or rs2 == S11) {
        emit(tb, off, rv64.ld(T1, S11, OFF_T1));
        emit(tb, off, rv64.ld(T0, S11, OFF_T0));
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
    emit(tb, off, rv64.sd(S11, T0, OFF_T0));
    emit(tb, off, rv64.sd(S11, T1, OFF_T1));

    const r_src: u5 = if (rs1 == T0 or rs1 == T1 or rs1 == S11)
        emit_alu.resolveSavedSource(tb, off, T1, rs1)
    else
        rs1;
    emit(tb, off, rv64.addiw(T1, r_src, imm));
    emit(tb, off, rv64.andi(T1, T1, JALR_CLEAR_LSB_MASK));
    emit(tb, off, rv64.sw(S11, T1, OFF_PC));

    const sp = rv64.splitImm32(current_pc + decoded_len);
    if (rd == T0 or rd == T1 or rd == S11) {
        emit(tb, off, rv64.lui(T1, sp.upper));
        emit(tb, off, rv64.addiw(T1, T1, sp.lower));
        if (rd == T0) {
            emit(tb, off, rv64.sd(S11, T1, OFF_T0));
            emit(tb, off, rv64.ld(T1, S11, OFF_T1));
        } else if (rd == S11) {
            emit(tb, off, rv64.sd(S11, T1, OFF_S11));
            emit(tb, off, rv64.ld(T1, S11, OFF_T1));
        }
    } else if (rd != 0) {
        emit(tb, off, rv64.lui(rd, sp.upper));
        emit(tb, off, rv64.addiw(rd, rd, sp.lower));
        emit(tb, off, rv64.ld(T1, S11, OFF_T1));
    } else {
        emit(tb, off, rv64.ld(T1, S11, OFF_T1));
    }

    _ = emitJumpToDispatcher(tb, off);
}

test "emitExit and emitBranchExit emit valid RV64 control-flow sequences" {
    const cache_inst = try std.testing.allocator.create(cache_mod.Cache);
    defer std.testing.allocator.destroy(cache_inst);
    var raw_pool: [512]u8 align(4096) = undefined;
    cache_inst.initOnPtr(&raw_pool);
    const tb = try cache_inst.allocateBlock(0x8000_0000, 0, false, 256);
    var off: usize = 0;

    emitBranchExit(
        tb,
        &off,
        0x8000_0000,
        4,
        .{ .rs1 = 10, .rs2 = 11, .offset = 8 },
        rv64.beq,
    );
    try std.testing.expect(off > 0);
    try std.testing.expect(tb.exit_branch1 != null);
    try std.testing.expect(tb.exit_branch2 != null);
    std.testing.refAllDecls(@This());
}
