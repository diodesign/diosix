// RV64 Inlined SoftTLB & Atomic Memory JIT Emitter Helpers.
//
// Emits host RV64 instruction sequences for inlined SoftTLB tag lookup,
// page permission verification, and atomic read-modify-write operations.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const rv64 = @import("../../emitters/rv64.zig");
const softtlb_mod = @import("../../../softtlb.zig");
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
const TLB_OFF_VADDR = block_mod.TLB_OFF_VADDR;
const TLB_OFF_FLAGS = block_mod.TLB_OFF_FLAGS;
const TLB_OFF_HPA = block_mod.TLB_OFF_HPA;
const PTE = softtlb_mod.PTE;
const AmoFunct5 = rv64.AmoFunct5;

pub const INSN_PLACEHOLDER: u32 = 0;
pub const WORD_BITS: u6 = 32;
pub const PAGE_OFFSET_CLEAR_SHIFT: u6 = 64 - softtlb_mod.PAGE_SHIFT;
pub const TLB_ENTRY_SIZE_SHIFT: u6 = 4;
pub const TLB_SLOT_OFFSET_SHIFT: u6 =
    PAGE_OFFSET_CLEAR_SHIFT - TLB_ENTRY_SIZE_SHIFT;

comptime {
    std.debug.assert(
        @sizeOf(softtlb_mod.SoftTlbEntry) == (1 << TLB_ENTRY_SIZE_SHIFT),
    );
}

pub const MemOp = struct {
    pub const LB: u3 = 0;
    pub const LH: u3 = 1;
    pub const LW: u3 = 2;
    pub const LBU: u3 = 4;
    pub const LHU: u3 = 5;
    pub const FLW: u3 = 6;
    pub const FLD: u3 = 7;

    pub const SB: u3 = 0;
    pub const SH: u3 = 1;
    pub const SW: u3 = 2;
    pub const FSW: u3 = 6;
    pub const FSD: u3 = 7;
};

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
    if (rs1 == T0) {
        emit(tb, off, rv64.ld(dst, S11, OFF_T0));
        emit(tb, off, rv64.addiw(dst, dst, imm));
    } else if (rs1 == T1) {
        emit(tb, off, rv64.ld(dst, S11, OFF_T1));
        emit(tb, off, rv64.addiw(dst, dst, imm));
    } else if (rs1 == S11) {
        emit(tb, off, rv64.ld(dst, S11, OFF_S11));
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
    const sp = rv64.splitImm32(@truncate(tlb_addr));

    emit(tb, off, rv64.slli(T1, page_reg, PAGE_OFFSET_CLEAR_SHIFT));
    emit(tb, off, rv64.srli(T1, T1, TLB_SLOT_OFFSET_SHIFT));
    emit(tb, off, rv64.lui(T0, sp.upper));
    emit(tb, off, rv64.addiw(T0, T0, sp.lower));
    emit(tb, off, rv64.slli(T0, T0, WORD_BITS));
    emit(tb, off, rv64.srli(T0, T0, WORD_BITS));
    emit(tb, off, rv64.add(T1, T1, T0));
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
    emitEffectiveGva(tb, off, T0, rs1, imm);
    emit(tb, off, rv64.srliw(T0, T0, softtlb_mod.PAGE_SHIFT));
    emitTlbSlotPtr(tb, off, tlb_addr, T0);
    emit(tb, off, rv64.lw(T0, T1, TLB_OFF_VADDR));

    emitEffectiveGva(tb, off, T1, rs1, imm);
    emit(tb, off, rv64.srliw(T1, T1, softtlb_mod.PAGE_SHIFT));

    const bne_patch_pos = off.*;
    emit(tb, off, INSN_PLACEHOLDER);

    // Hit path: recompute `&tlb.entries[slot]` in `t1 (x6)`.
    emitTlbSlotPtr(tb, off, tlb_addr, T1);
    return bne_patch_pos;
}

/// Emit HPA calculation (`t0 = entry.host_paddr_page + (GVA & 0xfff)`) on hit.
fn emitSoftTlbHitHpa(
    tb: *TranslationBlock,
    off: *usize,
    rs1: u5,
    imm: i12,
) void {
    emit(tb, off, rv64.ld(T1, T1, TLB_OFF_HPA));
    emitEffectiveGva(tb, off, T0, rs1, imm);
    emit(tb, off, rv64.slli(T0, T0, PAGE_OFFSET_CLEAR_SHIFT));
    emit(tb, off, rv64.srli(T0, T0, PAGE_OFFSET_CLEAR_SHIFT));
    emit(tb, off, rv64.add(T0, T0, T1));
}

pub fn emitLoadFromT0(
    tb: *TranslationBlock,
    off: *usize,
    op: u3,
    rd: u5,
    dest_if_pinned: u5,
) void {
    if (op == MemOp.FLW) {
        emit(tb, off, rv64.flw(rd, T0, 0));
    } else if (op == MemOp.FLD) {
        emit(tb, off, rv64.fld(rd, T0, 0));
    } else {
        const dest: u5 = if (rd == T0 or rd == T1 or rd == S11)
            dest_if_pinned
        else
            rd;
        const load_insn: u32 = switch (op) {
            MemOp.LB => rv64.lb(dest, T0, 0),
            MemOp.LH => rv64.lh(dest, T0, 0),
            MemOp.LW => rv64.lw(dest, T0, 0),
            MemOp.LBU => rv64.lbu(dest, T0, 0),
            MemOp.LHU => rv64.lhu(dest, T0, 0),
            else => rv64.lw(dest, T0, 0),
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
    if (op == MemOp.FSW) {
        emit(tb, off, rv64.fsw(T0, rs2, 0));
    } else if (op == MemOp.FSD) {
        emit(tb, off, rv64.fsd(T0, rs2, 0));
    } else {
        var val_reg: u5 = rs2;
        if (rs2 == T0) {
            emit(tb, off, rv64.ld(T1, S11, OFF_T0));
            val_reg = T1;
        } else if (check_r6 and rs2 == T1) {
            emit(tb, off, rv64.ld(T1, S11, OFF_T1));
            val_reg = T1;
        } else if (rs2 == S11) {
            emit(tb, off, rv64.ld(T1, S11, OFF_S11));
            val_reg = T1;
        }
        const store_insn: u32 = switch (op) {
            MemOp.SB => rv64.sb(T0, val_reg, 0),
            MemOp.SH => rv64.sh(T0, val_reg, 0),
            else => rv64.sw(T0, val_reg, 0),
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
    emit(tb, off, INSN_PLACEHOLDER);

    const slow_exit_pos = off.*;
    const bne_rel = @as(
        i13,
        @truncate(@as(isize, @intCast(slow_exit_pos - bne_patch_pos))),
    );
    std.mem.writeInt(
        u32,
        tb.host_code[bne_patch_pos..][0..4],
        rv64.bne(T0, T1, bne_rel),
        .little,
    );
    const beqz_rel = @as(
        i13,
        @truncate(@as(isize, @intCast(slow_exit_pos - beqz_patch_pos))),
    );
    const perm_branch = if (use_bnez_for_perm)
        rv64.bne(T0, 0, beqz_rel)
    else
        rv64.beq(T0, 0, beqz_rel);
    std.mem.writeInt(
        u32,
        tb.host_code[beqz_patch_pos..][0..4],
        perm_branch,
        .little,
    );

    emit(tb, off, rv64.ld(T1, S11, OFF_T1));
    emit(tb, off, rv64.ld(T0, S11, OFF_T0));
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

fn restoreAfterLoadOrAtomic(
    tb: *TranslationBlock,
    off: *usize,
    rd: u5,
    is_fp: bool,
) void {
    if (is_fp) {
        emit(tb, off, rv64.ld(T1, S11, OFF_T1));
        emit(tb, off, rv64.ld(T0, S11, OFF_T0));
    } else if (rd == T0) {
        emit(tb, off, rv64.sd(S11, T1, OFF_T0));
        emit(tb, off, rv64.ld(T1, S11, OFF_T1));
        emit(tb, off, rv64.ld(T0, S11, OFF_T0));
    } else if (rd == T1) {
        emit(tb, off, rv64.ld(T0, S11, OFF_T0));
    } else if (rd == S11) {
        emit(tb, off, rv64.sd(S11, T1, OFF_S11));
        emit(tb, off, rv64.ld(T1, S11, OFF_T1));
        emit(tb, off, rv64.ld(T0, S11, OFF_T0));
    } else {
        emit(tb, off, rv64.ld(T1, S11, OFF_T1));
        emit(tb, off, rv64.ld(T0, S11, OFF_T0));
    }
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
    emit(tb, off, rv64.sd(S11, T0, OFF_T0));
    emit(tb, off, rv64.sd(S11, T1, OFF_T1));
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

    // Permission check: flags must have Read bit (PTE.R).
    emit(tb, off, rv64.lbu(T0, T1, TLB_OFF_FLAGS));
    emit(tb, off, rv64.andi(T0, T0, PTE.R));
    const beqz_patch_pos = off.*;
    emit(tb, off, INSN_PLACEHOLDER);

    emitSoftTlbHitHpa(tb, off, rs1, imm);
    emitLoadFromT0(tb, off, op, rd, T1);
    restoreAfterLoadOrAtomic(tb, off, rd, op == MemOp.FLW or op == MemOp.FLD);

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
    emit(tb, off, rv64.sd(S11, T0, OFF_T0));
    emit(tb, off, rv64.sd(S11, T1, OFF_T1));
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

    // Permission check: flags must have Write bit (PTE.W).
    emit(tb, off, rv64.lbu(T0, T1, TLB_OFF_FLAGS));
    emit(tb, off, rv64.andi(T0, T0, PTE.W));
    const beqz_patch_pos = off.*;
    emit(tb, off, INSN_PLACEHOLDER);

    emitSoftTlbHitHpa(tb, off, rs1, imm);
    emitStoreToT0(tb, off, op, rs2, true);

    emit(tb, off, rv64.ld(T1, S11, OFF_T1));
    emit(tb, off, rv64.ld(T0, S11, OFF_T0));

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
    emit(tb, off, rv64.sd(S11, T0, OFF_T0));
    emit(tb, off, rv64.sd(S11, T1, OFF_T1));

    const bne_patch_pos = emitSoftTlbTagCheck(tb, off, tlb_addr, rs1, 0);

    // Permission check: lr_w -> Read (PTE.R), sc_w -> Write (PTE.W),
    // amo -> R+W (PTE.R | PTE.W).
    const rw_mask: i12 = PTE.R | PTE.W;
    const req_mask: i12 = if (funct5 == AmoFunct5.LR)
        PTE.R
    else if (funct5 == AmoFunct5.SC)
        PTE.W
    else
        rw_mask;
    emit(tb, off, rv64.lbu(T0, T1, TLB_OFF_FLAGS));
    emit(tb, off, rv64.andi(T0, T0, req_mask));
    if (req_mask == rw_mask) emit(tb, off, rv64.addiw(T0, T0, -rw_mask));
    const beqz_patch_pos = off.*;
    emit(tb, off, INSN_PLACEHOLDER);

    emitSoftTlbHitHpa(tb, off, rs1, 0);

    const src_reg: u5 = if (funct5 == AmoFunct5.LR) 0 else if (rs2 == T0) blk: {
        emit(tb, off, rv64.ld(T1, S11, OFF_T0));
        break :blk T1;
    } else if (rs2 == T1) blk: {
        emit(tb, off, rv64.ld(T1, S11, OFF_T1));
        break :blk T1;
    } else if (rs2 == S11) blk: {
        emit(tb, off, rv64.ld(T1, S11, OFF_S11));
        break :blk T1;
    } else rs2;

    const dest_reg: u5 = if (rd == T0 or rd == T1 or rd == S11 or rd == 0)
        T1
    else
        rd;
    emit(tb, off, rv64.encodeA(funct5, aq, rl, dest_reg, T0, src_reg));
    restoreAfterLoadOrAtomic(tb, off, rd, false);

    emitSoftTlbSlowExitTail(
        tb,
        off,
        current_pc,
        bne_patch_pos,
        beqz_patch_pos,
        req_mask == rw_mask,
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
        AmoFunct5.ADD,
        0,
        0,
        10,
        6,
        12,
    );
    const insn3 = std.mem.readInt(u32, tb.host_code[12..16], .little);
    try std.testing.expectEqual(rv64.addiw(5, 5, 0), insn3);
    std.testing.refAllDecls(@This());
}
