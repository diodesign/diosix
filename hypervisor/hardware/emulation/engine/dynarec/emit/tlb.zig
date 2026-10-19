// RV64 Inlined SoftTLB & Atomic Memory JIT Emitter Helpers.
//
// Emits host RV64 instruction sequences for inlined SoftTLB tag lookup,
// page permission verification, and atomic read-modify-write operations.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const rv64 = @import("../../emitters/rv64.zig");
const cache_mod = @import("../cache.zig");
const block_mod = @import("../block.zig");
const emit_alu = @import("alu.zig");

const TranslationBlock = block_mod.TranslationBlock;

inline fn emit(tb: *TranslationBlock, off: *usize, insn: u32) void {
    rv64.emit(tb.host_code, off, insn);
}

/// Compute `guest_reg(rs1) + imm` into host scratch register `dst` (5 or 6).
pub fn emitEffectiveGva(
    tb: *TranslationBlock,
    off: *usize,
    dst: u5,
    rs1: u5,
    imm: i12,
) void {
    if (rs1 == 5) {
        emit(tb, off, rv64.ld(dst, 27, 40));
        emit(tb, off, rv64.addiw(dst, dst, imm));
    } else if (rs1 == 6) {
        emit(tb, off, rv64.ld(dst, 27, 48));
        emit(tb, off, rv64.addiw(dst, dst, imm));
    } else if (rs1 == 27) {
        emit(tb, off, rv64.ld(dst, 27, 216));
        emit(tb, off, rv64.addiw(dst, dst, imm));
    } else if (rs1 == 0) {
        emit(tb, off, rv64.addiw(dst, 0, imm));
    } else {
        emit(tb, off, rv64.addiw(dst, rs1, imm));
    }
}

/// Emit SoftTLB slot address calculation (`t1 = &tlb.entries[slot]`) from page
/// number in `page_reg` (`5` or `6`), using `t0 (5)` as temporary.
fn emitTlbSlotPtr(
    tb: *TranslationBlock,
    off: *usize,
    tlb_addr: usize,
    page_reg: u5,
) void {
    const tlb_u32 = @as(u32, @truncate(tlb_addr));
    const tlb_i32 = @as(i32, @bitCast(tlb_u32));
    const tlb_upper = @as(i20, @truncate((tlb_i32 +% 0x800) >> 12));
    const tlb_lower = @as(i12, @bitCast(@as(u12, @truncate(tlb_addr & 0xfff))));

    emit(tb, off, rv64.slli(6, page_reg, 52));
    emit(tb, off, rv64.srli(6, 6, 48));
    emit(tb, off, rv64.lui(5, tlb_upper));
    emit(tb, off, rv64.addiw(5, 5, tlb_lower));
    emit(tb, off, rv64.slli(5, 5, 32));
    emit(tb, off, rv64.srli(5, 5, 32));
    emit(tb, off, rv64.add(6, 6, 5));
}

/// Emit SoftTLB tag lookup and return the patch position for the miss `bne`.
/// Leaves `t1 (x6)` pointing to `&tlb.entries[slot]` on the hit path.
fn emitSoftTlbTagCheck(
    tb: *TranslationBlock,
    off: *usize,
    tlb_addr: usize,
    rs1: u5,
    imm: i12,
) usize {
    emitEffectiveGva(tb, off, 5, rs1, imm);
    emit(tb, off, rv64.srliw(5, 5, 12));
    emitTlbSlotPtr(tb, off, tlb_addr, 5);
    emit(tb, off, rv64.lw(5, 6, 0));

    emitEffectiveGva(tb, off, 6, rs1, imm);
    emit(tb, off, rv64.srliw(6, 6, 12));

    const bne_patch_pos = off.*;
    emit(tb, off, 0); // Placeholder.

    // Hit path: recompute `&tlb.entries[slot]` in `t1 (x6)`.
    emitTlbSlotPtr(tb, off, tlb_addr, 6);
    return bne_patch_pos;
}

/// Emit HPA calculation (`t0 = entry.host_paddr_page + (GVA & 0xFFF)`) on hit.
fn emitSoftTlbHitHpa(
    tb: *TranslationBlock,
    off: *usize,
    rs1: u5,
    imm: i12,
) void {
    emit(tb, off, rv64.ld(6, 6, 8));
    emitEffectiveGva(tb, off, 5, rs1, imm);
    emit(tb, off, rv64.slli(5, 5, 52));
    emit(tb, off, rv64.srli(5, 5, 52));
    emit(tb, off, rv64.add(5, 5, 6));
}

pub fn emitLoadFromT0(
    tb: *TranslationBlock,
    off: *usize,
    op: u3,
    rd: u5,
    dest_if_pinned: u5,
) void {
    if (op == 6) {
        emit(tb, off, rv64.flw(rd, 5, 0));
    } else if (op == 7) {
        emit(tb, off, rv64.fld(rd, 5, 0));
    } else {
        const dest: u5 = if (rd == 5 or rd == 6 or rd == 27)
            dest_if_pinned
        else
            rd;
        const load_insn: u32 = switch (op) {
            0 => rv64.lb(dest, 5, 0),
            1 => rv64.lh(dest, 5, 0),
            2 => rv64.lw(dest, 5, 0),
            4 => rv64.lbu(dest, 5, 0),
            5 => rv64.lhu(dest, 5, 0),
            else => rv64.lw(dest, 5, 0),
        };
        emit(tb, off, load_insn);
    }
}

pub fn emitStoreToT0(
    tb: *TranslationBlock,
    off: *usize,
    op: u3,
    rs2: u5,
    check_r6: bool,
) void {
    if (op == 6) {
        emit(tb, off, rv64.fsw(5, rs2, 0));
    } else if (op == 7) {
        emit(tb, off, rv64.fsd(5, rs2, 0));
    } else {
        var val_reg: u5 = rs2;
        if (rs2 == 5) {
            emit(tb, off, rv64.ld(6, 27, 40));
            val_reg = 6;
        } else if (check_r6 and rs2 == 6) {
            emit(tb, off, rv64.ld(6, 27, 48));
            val_reg = 6;
        } else if (rs2 == 27) {
            emit(tb, off, rv64.ld(6, 27, 216));
            val_reg = 6;
        }
        const store_insn: u32 = switch (op) {
            0 => rv64.sb(5, val_reg, 0),
            1 => rv64.sh(5, val_reg, 0),
            else => rv64.sw(5, val_reg, 0),
        };
        emit(tb, off, store_insn);
    }
}

fn emitSoftTlbSlowExitTail(
    tb: *TranslationBlock,
    off: *usize,
    current_pc: u32,
    bne_patch_pos: usize,
    beqz_patch_pos: usize,
    use_bnez_for_perm: bool,
) void {
    const jal_patch_pos = off.*;
    emit(tb, off, 0); // Placeholder.

    const slow_exit_pos = off.*;
    const bne_rel = @as(
        i13,
        @truncate(@as(isize, @intCast(slow_exit_pos - bne_patch_pos))),
    );
    std.mem.writeInt(
        u32,
        tb.host_code[bne_patch_pos..][0..4],
        rv64.bne(5, 6, bne_rel),
        .little,
    );
    const beqz_rel = @as(
        i13,
        @truncate(@as(isize, @intCast(slow_exit_pos - beqz_patch_pos))),
    );
    const perm_branch = if (use_bnez_for_perm)
        rv64.bne(5, 0, beqz_rel)
    else
        rv64.beq(5, 0, beqz_rel);
    std.mem.writeInt(
        u32,
        tb.host_code[beqz_patch_pos..][0..4],
        perm_branch,
        .little,
    );

    emit(tb, off, rv64.ld(6, 27, 48));
    emit(tb, off, rv64.ld(5, 27, 40));
    _ = emit_alu.emitExit(tb, off, current_pc);

    const cont_pos = off.*;
    const jal_rel = @as(
        i21,
        @truncate(@as(isize, @intCast(cont_pos - jal_patch_pos))),
    );
    std.mem.writeInt(
        u32,
        tb.host_code[jal_patch_pos..][0..4],
        rv64.jal(0, jal_rel),
        .little,
    );
}

pub fn emitSoftTlbLoad(
    tlb_addr: usize,
    tb: *TranslationBlock,
    off: *usize,
    current_pc: u32,
    op: u3,
    rd: u5,
    rs1: u5,
    imm: i12,
) void {
    if (rd == 0) return;
    emit(tb, off, rv64.sd(27, 5, 40));
    emit(tb, off, rv64.sd(27, 6, 48));
    emitSoftTlbLoadBody(tlb_addr, tb, off, current_pc, op, rd, rs1, imm);
}

pub fn emitSoftTlbLoadBody(
    tlb_addr: usize,
    tb: *TranslationBlock,
    off: *usize,
    current_pc: u32,
    op: u3,
    rd: u5,
    rs1: u5,
    imm: i12,
) void {
    if (rd == 0) return;

    const bne_patch_pos = emitSoftTlbTagCheck(tb, off, tlb_addr, rs1, imm);

    // Permission check: flags (offset 4) must have Read bit (1 << 1 = 2).
    emit(tb, off, rv64.lbu(5, 6, 4));
    emit(tb, off, rv64.andi(5, 5, 2));
    const beqz_patch_pos = off.*;
    emit(tb, off, 0); // Placeholder.

    emitSoftTlbHitHpa(tb, off, rs1, imm);
    emitLoadFromT0(tb, off, op, rd, 6);

    if (op == 6 or op == 7) {
        emit(tb, off, rv64.ld(6, 27, 48));
        emit(tb, off, rv64.ld(5, 27, 40));
    } else if (rd == 5) {
        emit(tb, off, rv64.sd(27, 6, 40));
        emit(tb, off, rv64.ld(6, 27, 48));
        emit(tb, off, rv64.ld(5, 27, 40));
    } else if (rd == 6) {
        emit(tb, off, rv64.ld(5, 27, 40));
    } else if (rd == 27) {
        emit(tb, off, rv64.sd(27, 6, 216));
        emit(tb, off, rv64.ld(6, 27, 48));
        emit(tb, off, rv64.ld(5, 27, 40));
    } else {
        emit(tb, off, rv64.ld(6, 27, 48));
        emit(tb, off, rv64.ld(5, 27, 40));
    }

    emitSoftTlbSlowExitTail(
        tb,
        off,
        current_pc,
        bne_patch_pos,
        beqz_patch_pos,
        false,
    );
}

pub fn emitSoftTlbStore(
    tlb_addr: usize,
    tb: *TranslationBlock,
    off: *usize,
    current_pc: u32,
    op: u3,
    rs1: u5,
    rs2: u5,
    imm: i12,
) void {
    emit(tb, off, rv64.sd(27, 5, 40));
    emit(tb, off, rv64.sd(27, 6, 48));
    emitSoftTlbStoreBody(tlb_addr, tb, off, current_pc, op, rs1, rs2, imm);
}

pub fn emitSoftTlbStoreBody(
    tlb_addr: usize,
    tb: *TranslationBlock,
    off: *usize,
    current_pc: u32,
    op: u3,
    rs1: u5,
    rs2: u5,
    imm: i12,
) void {
    const bne_patch_pos = emitSoftTlbTagCheck(tb, off, tlb_addr, rs1, imm);

    // Permission check: flags (offset 4) must have Write bit (1 << 2 = 4).
    emit(tb, off, rv64.lbu(5, 6, 4));
    emit(tb, off, rv64.andi(5, 5, 4));
    const beqz_patch_pos = off.*;
    emit(tb, off, 0); // Placeholder.

    emitSoftTlbHitHpa(tb, off, rs1, imm);
    emitStoreToT0(tb, off, op, rs2, true);

    emit(tb, off, rv64.ld(6, 27, 48));
    emit(tb, off, rv64.ld(5, 27, 40));

    emitSoftTlbSlowExitTail(
        tb,
        off,
        current_pc,
        bne_patch_pos,
        beqz_patch_pos,
        false,
    );
}

pub fn emitSoftTlbAtomic(
    tlb_addr: usize,
    tb: *TranslationBlock,
    off: *usize,
    current_pc: u32,
    funct5: u5,
    aq: u1,
    rl: u1,
    rd: u5,
    rs1: u5,
    rs2: u5,
) void {
    emit(tb, off, rv64.sd(27, 5, 40));
    emit(tb, off, rv64.sd(27, 6, 48));

    const bne_patch_pos = emitSoftTlbTagCheck(tb, off, tlb_addr, rs1, 0);

    // Permission check: lr_w -> Read (2), sc_w -> Write (4), amo -> R+W (6).
    const req_mask: i12 = if (funct5 == 0x02)
        2
    else if (funct5 == 0x03)
        4
    else
        6;
    emit(tb, off, rv64.lbu(5, 6, 4));
    emit(tb, off, rv64.andi(5, 5, req_mask));
    if (req_mask == 6) emit(tb, off, rv64.addiw(5, 5, -6));
    const beqz_patch_pos = off.*;
    emit(tb, off, 0); // Placeholder.

    emitSoftTlbHitHpa(tb, off, rs1, 0);

    const src_reg: u5 = if (funct5 == 0x02) 0 else if (rs2 == 5) blk: {
        emit(tb, off, rv64.ld(6, 27, 40));
        break :blk 6;
    } else if (rs2 == 6) blk: {
        emit(tb, off, rv64.ld(6, 27, 48));
        break :blk 6;
    } else if (rs2 == 27) blk: {
        emit(tb, off, rv64.ld(6, 27, 216));
        break :blk 6;
    } else rs2;

    const dest_reg: u5 = if (rd == 5 or rd == 6 or rd == 27 or rd == 0)
        6
    else
        rd;
    emit(tb, off, rv64.encodeA(funct5, aq, rl, dest_reg, 5, src_reg));

    if (rd == 5) {
        emit(tb, off, rv64.sd(27, 6, 40));
        emit(tb, off, rv64.ld(6, 27, 48));
        emit(tb, off, rv64.ld(5, 27, 40));
    } else if (rd == 6) {
        emit(tb, off, rv64.ld(5, 27, 40));
    } else if (rd == 27) {
        emit(tb, off, rv64.sd(27, 6, 216));
        emit(tb, off, rv64.ld(6, 27, 48));
        emit(tb, off, rv64.ld(5, 27, 40));
    } else {
        emit(tb, off, rv64.ld(6, 27, 48));
        emit(tb, off, rv64.ld(5, 27, 40));
    }

    emitSoftTlbSlowExitTail(
        tb,
        off,
        current_pc,
        bne_patch_pos,
        beqz_patch_pos,
        req_mask == 6,
    );
}

test "emit_tlb SoftTLB atomic rs1=6 reload" {
    const cache_inst = try std.testing.allocator.create(cache_mod.Cache);
    defer std.testing.allocator.destroy(cache_inst);
    var raw_pool: [1024]u8 align(4096) = undefined;
    cache_inst.initOnPtr(&raw_pool);
    const tb = try cache_inst.allocateBlock(0x8000_0000, 0, false, 512);
    var off: usize = 0;

    emitSoftTlbAtomic(
        0x8000_0000,
        tb,
        &off,
        0x8000_0000,
        0x00,
        0,
        0,
        10,
        6,
        12,
    );
    const insn3 = std.mem.readInt(u32, tb.host_code[12..16], .little);
    try std.testing.expectEqual(rv64.addiw(5, 5, 0), insn3);
}
