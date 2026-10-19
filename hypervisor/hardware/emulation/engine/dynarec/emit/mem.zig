// RV64 Fast-Path Direct RAM Load & Store JIT Emitter Helpers.
//
// Emits host RV64 load and store sequences for direct-mapped guest RAM
// regions with optional dynamic bounds checks and SoftTLB fallback.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const rv64 = @import("../../emitters/rv64.zig");
const cache_mod = @import("../cache.zig");
const block_mod = @import("../block.zig");
const emit_tlb = @import("tlb.zig");

const TranslationBlock = block_mod.TranslationBlock;

pub const emitSoftTlbLoad = emit_tlb.emitSoftTlbLoad;
pub const emitSoftTlbStore = emit_tlb.emitSoftTlbStore;
pub const emitSoftTlbAtomic = emit_tlb.emitSoftTlbAtomic;

inline fn emit(tb: *TranslationBlock, off: *usize, insn: u32) void {
    rv64.emit(tb.host_code, off, insn);
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
    const needs_t1 = (rs1 == 5 or rs1 == 27 or rd == 5 or rd == 27);

    emit(tb, off, rv64.sd(27, 5, 40));
    if (needs_t1) emit(tb, off, rv64.sd(27, 6, 48));

    const off_i32 = @as(i32, @truncate(total_offset));
    const upper = @as(i20, @truncate((off_i32 +% 0x800) >> 12));
    const off_u32 = @as(u32, @bitCast(off_i32));
    const lower = @as(i12, @bitCast(@as(u12, @truncate(off_u32 & 0xfff))));

    emit(tb, off, rv64.lui(5, upper));
    emit(tb, off, rv64.addiw(5, 5, lower));

    if (rs1 == 5) {
        emit(tb, off, rv64.ld(6, 27, 40));
        emit(tb, off, rv64.add(5, 5, 6));
    } else if (rs1 == 27) {
        emit(tb, off, rv64.ld(6, 27, 216));
        emit(tb, off, rv64.add(5, 5, 6));
    } else if (rs1 != 0) {
        emit(tb, off, rv64.add(5, 5, rs1));
    }

    emit(tb, off, rv64.slli(5, 5, 32));
    emit(tb, off, rv64.srli(5, 5, 32));

    emit_tlb.emitLoadFromT0(tb, off, op, rd, 6);
    if (op != 6 and op != 7) {
        if (rd == 5) {
            emit(tb, off, rv64.addi(5, 6, 0));
            emit(tb, off, rv64.sd(27, 5, 40));
        } else if (rd == 27) {
            emit(tb, off, rv64.sd(27, 6, 216));
        }
    }

    if (needs_t1 and rd != 6) emit(tb, off, rv64.ld(6, 27, 48));
    if (rd != 5) emit(tb, off, rv64.ld(5, 27, 40));
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
    const needs_t1 = (rs1 == 5 or rs1 == 27 or
        (op != 6 and op != 7 and (rs2 == 5 or rs2 == 27)));

    emit(tb, off, rv64.sd(27, 5, 40));
    if (needs_t1) emit(tb, off, rv64.sd(27, 6, 48));

    const off_i32 = @as(i32, @truncate(total_offset));
    const upper = @as(i20, @truncate((off_i32 +% 0x800) >> 12));
    const off_u32 = @as(u32, @bitCast(off_i32));
    const lower = @as(i12, @bitCast(@as(u12, @truncate(off_u32 & 0xfff))));

    emit(tb, off, rv64.lui(5, upper));
    emit(tb, off, rv64.addiw(5, 5, lower));

    if (rs1 == 5) {
        emit(tb, off, rv64.ld(6, 27, 40));
        emit(tb, off, rv64.add(5, 5, 6));
    } else if (rs1 == 27) {
        emit(tb, off, rv64.ld(6, 27, 216));
        emit(tb, off, rv64.add(5, 5, 6));
    } else if (rs1 != 0) {
        emit(tb, off, rv64.add(5, 5, rs1));
    }

    emit(tb, off, rv64.slli(5, 5, 32));
    emit(tb, off, rv64.srli(5, 5, 32));

    emit_tlb.emitStoreToT0(tb, off, op, rs2, false);

    if (needs_t1) emit(tb, off, rv64.ld(6, 27, 48));
    emit(tb, off, rv64.ld(5, 27, 40));
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
    emit_tlb.emitEffectiveGva(tb, off, 5, rs1, imm);

    const vstart_i32 = @as(i32, @bitCast(vaddr_start));
    const vstart_upper = @as(i20, @truncate((vstart_i32 +% 0x800) >> 12));
    const vstart_u12: u12 = @truncate(vaddr_start & 0xfff);
    const vstart_lower: i12 = @bitCast(vstart_u12);
    emit(tb, off, rv64.lui(6, vstart_upper));
    emit(tb, off, rv64.addiw(6, 6, vstart_lower));
    emit(tb, off, rv64.subw(6, 5, 6));

    const size = vaddr_end -% vaddr_start;
    const size_i32 = @as(i32, @bitCast(size));
    const size_upper = @as(i20, @truncate((size_i32 +% 0x800) >> 12));
    const size_u12: u12 = @truncate(size & 0xfff);
    const size_lower: i12 = @bitCast(size_u12);
    emit(tb, off, rv64.lui(5, size_upper));
    emit(tb, off, rv64.addiw(5, 5, size_lower));

    emit(tb, off, rv64.slli(6, 6, 32));
    emit(tb, off, rv64.srli(6, 6, 32));
    emit(tb, off, rv64.slli(5, 5, 32));
    emit(tb, off, rv64.srli(5, 5, 32));

    const bgeu_patch_pos = off.*;
    emit(tb, off, 0); // Placeholder.

    const hpa_i32 = @as(i32, @truncate(@as(isize, @bitCast(hpa_start))));
    const hpa_upper = @as(i20, @truncate((hpa_i32 +% 0x800) >> 12));
    const hpa_u32 = @as(u32, @bitCast(hpa_i32));
    const hpa_lower = @as(i12, @bitCast(@as(u12, @truncate(hpa_u32 & 0xfff))));
    emit(tb, off, rv64.lui(5, hpa_upper));
    emit(tb, off, rv64.addiw(5, 5, hpa_lower));
    emit(tb, off, rv64.slli(5, 5, 32));
    emit(tb, off, rv64.srli(5, 5, 32));
    emit(tb, off, rv64.add(5, 5, 6));
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

    emit(tb, off, rv64.sd(27, 5, 40));
    emit(tb, off, rv64.sd(27, 6, 48));

    const bgeu_patch_pos = emitFastRangeCheckAndHpa(
        tb,
        off,
        rs1,
        imm,
        vaddr_start,
        vaddr_end,
        hpa_start,
    );

    emit_tlb.emitLoadFromT0(tb, off, op, rd, 6);
    if (op != 6 and op != 7) {
        if (rd == 5) {
            emit(tb, off, rv64.addi(5, 6, 0));
            emit(tb, off, rv64.sd(27, 5, 40));
        } else if (rd == 27) {
            emit(tb, off, rv64.sd(27, 6, 216));
        }
    }

    if (rd != 6) emit(tb, off, rv64.ld(6, 27, 48));
    if (rd != 5) emit(tb, off, rv64.ld(5, 27, 40));

    const jal_done_pos = off.*;
    emit(tb, off, 0); // Placeholder.

    const slow_path_target = off.*;
    const bgeu_rel = @as(i32, @intCast(slow_path_target - bgeu_patch_pos));
    std.mem.writeInt(
        u32,
        tb.host_code[bgeu_patch_pos..][0..4],
        rv64.bgeu(6, 5, @as(i13, @truncate(bgeu_rel))),
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
    emit(tb, off, rv64.sd(27, 5, 40));
    emit(tb, off, rv64.sd(27, 6, 48));

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
    emit(tb, off, rv64.ld(6, 27, 48));
    emit(tb, off, rv64.ld(5, 27, 40));

    const jal_done_pos = off.*;
    emit(tb, off, 0); // Placeholder.

    const slow_path_target = off.*;
    const bgeu_rel = @as(i32, @intCast(slow_path_target - bgeu_patch_pos));
    std.mem.writeInt(
        u32,
        tb.host_code[bgeu_patch_pos..][0..4],
        rv64.bgeu(6, 5, @as(i13, @truncate(bgeu_rel))),
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

    emitFastLoad(tb, &off, 2, 10, 2, 8, 0);
    const after_load = off;
    try std.testing.expect(after_load > 0);
    emitFastStore(tb, &off, 2, 2, 10, 8, 0);
    try std.testing.expect(off > after_load);
}
