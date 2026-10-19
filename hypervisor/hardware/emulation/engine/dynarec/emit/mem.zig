// RV64 Fast-Path Direct RAM Load & Store JIT Emitter Helpers.
//
// Emits host RV64 load and store sequences for direct-mapped guest RAM
// regions with optional dynamic bounds checks and SoftTLB fallback.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const decoder_rv32 = @import("../../decoders/rv32.zig");
const rv64 = @import("../../emitters/rv64.zig");
const cache_mod = @import("../cache.zig");
const block_mod = @import("../block.zig");
const emit_tlb = @import("tlb.zig");

const TranslationBlock = block_mod.TranslationBlock;
const T0 = block_mod.HOST_REG_T0;
const T1 = block_mod.HOST_REG_T1;
const S11 = block_mod.HOST_REG_S11;
const OFF_T0 = block_mod.VCPU_OFF_T0;
const OFF_T1 = block_mod.VCPU_OFF_T1;
const OFF_S11 = block_mod.VCPU_OFF_S11;

pub const MemOp = emit_tlb.MemOp;
pub const INSN_PLACEHOLDER = emit_tlb.INSN_PLACEHOLDER;
pub const WORD_BITS = emit_tlb.WORD_BITS;

pub const emitSoftTlbLoad = emit_tlb.emitSoftTlbLoad;
pub const emitSoftTlbStore = emit_tlb.emitSoftTlbStore;
pub const emitSoftTlbAtomic = emit_tlb.emitSoftTlbAtomic;

inline fn emit(tb: *TranslationBlock, off: *usize, insn: u32) void {
    rv64.emit(tb.host_code, off, insn);
}

pub fn emitLoad(
    eng: anytype,
    tb: *TranslationBlock,
    off: *usize,
    pc: u32,
    op: u3,
    rd: u5,
    rs1: u5,
    offset: i32,
) void {
    const imm = @as(i12, @truncate(offset));
    const tlb_addr = @intFromPtr(&eng.tlb.entries[0]);
    if (eng.tlb.getDirectMappingRegion(pc)) |region| {
        tb.is_fast_path = true;
        if (rs1 == block_mod.GUEST_REG_SP or rs1 == block_mod.GUEST_REG_FP) {
            emitFastLoad(tb, off, op, rd, rs1, imm, region.delta);
        } else {
            emitFastLoadWithFallback(
                tlb_addr,
                tb,
                off,
                pc,
                op,
                rd,
                rs1,
                imm,
                region.vaddr_start,
                region.vaddr_end,
                region.hpa_start,
            );
        }
    } else {
        emitSoftTlbLoad(tlb_addr, tb, off, pc, op, rd, rs1, imm);
    }
}

pub fn emitStore(
    eng: anytype,
    tb: *TranslationBlock,
    off: *usize,
    pc: u32,
    op: u3,
    rs1: u5,
    rs2: u5,
    offset: i32,
) void {
    const imm = @as(i12, @truncate(offset));
    const tlb_addr = @intFromPtr(&eng.tlb.entries[0]);
    if (eng.tlb.getDirectMappingRegion(pc)) |region| {
        tb.is_fast_path = true;
        if (rs1 == block_mod.GUEST_REG_SP or rs1 == block_mod.GUEST_REG_FP) {
            emitFastStore(tb, off, op, rs1, rs2, imm, region.delta);
        } else {
            emitFastStoreWithFallback(
                tlb_addr,
                tb,
                off,
                pc,
                op,
                rs1,
                rs2,
                imm,
                region.vaddr_start,
                region.vaddr_end,
                region.hpa_start,
            );
        }
    } else {
        emitSoftTlbStore(tlb_addr, tb, off, pc, op, rs1, rs2, imm);
    }
}

pub fn emitAmo(
    tlb_addr: usize,
    tb: *TranslationBlock,
    off: *usize,
    pc: u32,
    funct5: u5,
    d: decoder_rv32.AmoType,
) void {
    emitSoftTlbAtomic(
        tlb_addr,
        tb,
        off,
        pc,
        funct5,
        d.aq,
        d.rl,
        d.rd,
        d.rs1,
        d.rs2,
    );
}

pub fn emitFastLoad(
    tb: *TranslationBlock,
    off: *usize,
    op: u3,
    rd: u5,
    rs1: u5,
    imm: i12,
    delta: i64,
) void {
    if (rd == 0) return;

    const total_offset = @as(i64, @intCast(imm)) + delta;
    const needs_t1 = (rs1 == T0 or rs1 == S11 or rd == T0 or rd == S11);

    emit(tb, off, rv64.sd(S11, T0, OFF_T0));
    if (needs_t1) emit(tb, off, rv64.sd(S11, T1, OFF_T1));

    const sp = rv64.splitImm32(@bitCast(@as(i32, @truncate(total_offset))));
    emit(tb, off, rv64.lui(T0, sp.upper));
    emit(tb, off, rv64.addiw(T0, T0, sp.lower));

    if (rs1 == T0) {
        emit(tb, off, rv64.ld(T1, S11, OFF_T0));
        emit(tb, off, rv64.add(T0, T0, T1));
    } else if (rs1 == S11) {
        emit(tb, off, rv64.ld(T1, S11, OFF_S11));
        emit(tb, off, rv64.add(T0, T0, T1));
    } else if (rs1 != 0) {
        emit(tb, off, rv64.add(T0, T0, rs1));
    }

    emit(tb, off, rv64.slli(T0, T0, WORD_BITS));
    emit(tb, off, rv64.srli(T0, T0, WORD_BITS));

    emit_tlb.emitLoadFromT0(tb, off, op, rd, T1);
    if (op != MemOp.FLW and op != MemOp.FLD) {
        if (rd == T0) {
            emit(tb, off, rv64.addi(T0, T1, 0));
            emit(tb, off, rv64.sd(S11, T0, OFF_T0));
        } else if (rd == S11) {
            emit(tb, off, rv64.sd(S11, T1, OFF_S11));
        }
    }

    if (needs_t1 and rd != T1) emit(tb, off, rv64.ld(T1, S11, OFF_T1));
    if (rd != T0) emit(tb, off, rv64.ld(T0, S11, OFF_T0));
}

pub fn emitFastStore(
    tb: *TranslationBlock,
    off: *usize,
    op: u3,
    rs1: u5,
    rs2: u5,
    imm: i12,
    delta: i64,
) void {
    const total_offset = @as(i64, @intCast(imm)) + delta;
    const needs_t1 = (rs1 == T0 or rs1 == S11 or
        (op != MemOp.FSW and op != MemOp.FSD and (rs2 == T0 or rs2 == S11)));

    emit(tb, off, rv64.sd(S11, T0, OFF_T0));
    if (needs_t1) emit(tb, off, rv64.sd(S11, T1, OFF_T1));

    const sp = rv64.splitImm32(@bitCast(@as(i32, @truncate(total_offset))));
    emit(tb, off, rv64.lui(T0, sp.upper));
    emit(tb, off, rv64.addiw(T0, T0, sp.lower));

    if (rs1 == T0) {
        emit(tb, off, rv64.ld(T1, S11, OFF_T0));
        emit(tb, off, rv64.add(T0, T0, T1));
    } else if (rs1 == S11) {
        emit(tb, off, rv64.ld(T1, S11, OFF_S11));
        emit(tb, off, rv64.add(T0, T0, T1));
    } else if (rs1 != 0) {
        emit(tb, off, rv64.add(T0, T0, rs1));
    }

    emit(tb, off, rv64.slli(T0, T0, WORD_BITS));
    emit(tb, off, rv64.srli(T0, T0, WORD_BITS));

    emit_tlb.emitStoreToT0(tb, off, op, rs2, false);

    if (needs_t1) emit(tb, off, rv64.ld(T1, S11, OFF_T1));
    emit(tb, off, rv64.ld(T0, S11, OFF_T0));
}

fn emitFastRangeCheckAndHpa(
    tb: *TranslationBlock,
    off: *usize,
    rs1: u5,
    imm: i12,
    vaddr_start: u32,
    vaddr_end: u32,
    hpa_start: usize,
) usize {
    emit_tlb.emitEffectiveGva(tb, off, T0, rs1, imm);

    const vstart = rv64.splitImm32(vaddr_start);
    emit(tb, off, rv64.lui(T1, vstart.upper));
    emit(tb, off, rv64.addiw(T1, T1, vstart.lower));
    emit(tb, off, rv64.subw(T1, T0, T1));

    const size_sp = rv64.splitImm32(vaddr_end -% vaddr_start);
    emit(tb, off, rv64.lui(T0, size_sp.upper));
    emit(tb, off, rv64.addiw(T0, T0, size_sp.lower));

    emit(tb, off, rv64.slli(T1, T1, WORD_BITS));
    emit(tb, off, rv64.srli(T1, T1, WORD_BITS));
    emit(tb, off, rv64.slli(T0, T0, WORD_BITS));
    emit(tb, off, rv64.srli(T0, T0, WORD_BITS));

    const bgeu_patch_pos = off.*;
    emit(tb, off, INSN_PLACEHOLDER);

    const hpa_sp = rv64.splitImm32(@truncate(hpa_start));
    emit(tb, off, rv64.lui(T0, hpa_sp.upper));
    emit(tb, off, rv64.addiw(T0, T0, hpa_sp.lower));
    emit(tb, off, rv64.slli(T0, T0, WORD_BITS));
    emit(tb, off, rv64.srli(T0, T0, WORD_BITS));
    emit(tb, off, rv64.add(T0, T0, T1));
    return bgeu_patch_pos;
}

pub fn emitFastLoadWithFallback(
    tlb_addr: usize,
    tb: *TranslationBlock,
    off: *usize,
    current_pc: u32,
    op: u3,
    rd: u5,
    rs1: u5,
    imm: i12,
    vaddr_start: u32,
    vaddr_end: u32,
    hpa_start: usize,
) void {
    if (rd == 0) return;

    emit(tb, off, rv64.sd(S11, T0, OFF_T0));
    emit(tb, off, rv64.sd(S11, T1, OFF_T1));

    const bgeu_patch_pos = emitFastRangeCheckAndHpa(
        tb,
        off,
        rs1,
        imm,
        vaddr_start,
        vaddr_end,
        hpa_start,
    );

    emit_tlb.emitLoadFromT0(tb, off, op, rd, T1);
    if (op != MemOp.FLW and op != MemOp.FLD) {
        if (rd == T0) {
            emit(tb, off, rv64.addi(T0, T1, 0));
            emit(tb, off, rv64.sd(S11, T0, OFF_T0));
        } else if (rd == S11) {
            emit(tb, off, rv64.sd(S11, T1, OFF_S11));
        }
    }

    if (rd != T1) emit(tb, off, rv64.ld(T1, S11, OFF_T1));
    if (rd != T0) emit(tb, off, rv64.ld(T0, S11, OFF_T0));

    const jal_done_pos = off.*;
    emit(tb, off, INSN_PLACEHOLDER);

    const slow_path_target = off.*;
    const bgeu_rel = @as(i32, @intCast(slow_path_target - bgeu_patch_pos));
    std.mem.writeInt(
        u32,
        tb.host_code[bgeu_patch_pos..][0..4],
        rv64.bgeu(T1, T0, @as(i13, @truncate(bgeu_rel))),
        .little,
    );

    emit_tlb.emitSoftTlbLoadBody(
        tlb_addr,
        tb,
        off,
        current_pc,
        op,
        rd,
        rs1,
        imm,
    );

    const done_target = off.*;
    const jal_rel = @as(i32, @intCast(done_target - jal_done_pos));
    std.mem.writeInt(
        u32,
        tb.host_code[jal_done_pos..][0..4],
        rv64.jal(0, @as(i21, @truncate(jal_rel))),
        .little,
    );
}

pub fn emitFastStoreWithFallback(
    tlb_addr: usize,
    tb: *TranslationBlock,
    off: *usize,
    current_pc: u32,
    op: u3,
    rs1: u5,
    rs2: u5,
    imm: i12,
    vaddr_start: u32,
    vaddr_end: u32,
    hpa_start: usize,
) void {
    emit(tb, off, rv64.sd(S11, T0, OFF_T0));
    emit(tb, off, rv64.sd(S11, T1, OFF_T1));

    const bgeu_patch_pos = emitFastRangeCheckAndHpa(
        tb,
        off,
        rs1,
        imm,
        vaddr_start,
        vaddr_end,
        hpa_start,
    );

    emit_tlb.emitStoreToT0(tb, off, op, rs2, true);
    emit(tb, off, rv64.ld(T1, S11, OFF_T1));
    emit(tb, off, rv64.ld(T0, S11, OFF_T0));

    const jal_done_pos = off.*;
    emit(tb, off, INSN_PLACEHOLDER);

    const slow_path_target = off.*;
    const bgeu_rel = @as(i32, @intCast(slow_path_target - bgeu_patch_pos));
    std.mem.writeInt(
        u32,
        tb.host_code[bgeu_patch_pos..][0..4],
        rv64.bgeu(T1, T0, @as(i13, @truncate(bgeu_rel))),
        .little,
    );

    emit_tlb.emitSoftTlbStoreBody(
        tlb_addr,
        tb,
        off,
        current_pc,
        op,
        rs1,
        rs2,
        imm,
    );

    const done_target = off.*;
    const jal_rel = @as(i32, @intCast(done_target - jal_done_pos));
    std.mem.writeInt(
        u32,
        tb.host_code[jal_done_pos..][0..4],
        rv64.jal(0, @as(i21, @truncate(jal_rel))),
        .little,
    );
}

test "emitFastLoad and emitFastStore emit valid sequences" {
    const cache_inst = try std.testing.allocator.create(cache_mod.Cache);
    defer std.testing.allocator.destroy(cache_inst);
    var raw_pool: [512]u8 align(4096) = undefined;
    cache_inst.initOnPtr(&raw_pool);
    const tb = try cache_inst.allocateBlock(0x8000_0000, 0, false, 256);
    var off: usize = 0;

    emitFastLoad(tb, &off, MemOp.LW, 10, 2, 8, 0);
    const after_load = off;
    try std.testing.expect(after_load > 0);
    emitFastStore(tb, &off, MemOp.SW, 2, 10, 8, 0);
    try std.testing.expect(off > after_load);
    std.testing.refAllDecls(@This());
}
