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

pub inline fn memOpBytes(op: u3) u32 {
    return switch (op) {
        MemOp.LB, MemOp.LBU => 1,
        MemOp.LH, MemOp.LHU => 2,
        MemOp.LW, MemOp.FLW => 4,
        MemOp.FLD => 8,
        else => 4,
    };
}

inline fn emit(tb: *TranslationBlock, off: *usize, insn: u32) void {
    rv64.emit(tb.host_code, off, insn);
}

inline fn patchInsn(tb: *TranslationBlock, pos: usize, insn: u32) void {
    std.mem.writeInt(u32, tb.host_code[pos..][0..4], insn, .little);
}

inline fn rel13(target: usize, pos: usize) i13 {
    return @truncate(@as(isize, @intCast(target - pos)));
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
    } else if (rs1 == T1) {
        emit(tb, off, rv64.ld(dst, S11, OFF_T1));
    } else if (rs1 == S11) {
        emit(tb, off, rv64.ld(dst, S11, OFF_S11));
    } else {
        emit(tb, off, rv64.addiw(dst, rs1, imm));
        return;
    }
    emit(tb, off, rv64.addiw(dst, dst, imm));
}

/// Emit SoftTLB slot address calculation (`t1 = &tlb.entries[slot]`) from page
/// number in `page_reg` (`5` or `6`), using `t0 (5)` as temporary.
fn emitTlbSlotPtr(
    tb: *TranslationBlock,
    off: *usize,
    tlb_addr: usize,
    page_reg: u5,
) void {
    _ = tlb_addr;
    emit(tb, off, rv64.slli(T0, page_reg, PAGE_OFFSET_CLEAR_SHIFT));
    emit(tb, off, rv64.srli(T0, T0, TLB_SLOT_OFFSET_SHIFT));
    emit(tb, off, rv64.ld(T1, S11, block_mod.OFF_TLB_PTR));
    emit(tb, off, rv64.add(T1, T1, T0));
}

const TagCheckPatches = struct {
    align_bne_pos: ?usize = null,
    tag_bne_pos: usize,
};

/// Emit SoftTLB alignment and tag lookup, returning patch positions for the
/// miss/misaligned branches. Leaves `t1 (x6)` pointing to `&tlb.entries[slot]`
/// on the hit path.
fn emitTagCheck(
    tb: *TranslationBlock,
    off: *usize,
    tlb_addr: usize,
    rs1: u5,
    imm: i12,
    access_bytes: u32,
) TagCheckPatches {
    emitEffectiveGva(tb, off, T0, rs1, imm);
    var align_bne_pos: ?usize = null;
    if (access_bytes > 1) {
        emit(tb, off, rv64.andi(T1, T0, @intCast(access_bytes - 1)));
        align_bne_pos = off.*;
        emit(tb, off, INSN_PLACEHOLDER);
    }
    emit(tb, off, rv64.srliw(T0, T0, softtlb_mod.PAGE_SHIFT));
    emitTlbSlotPtr(tb, off, tlb_addr, T0);
    emit(tb, off, rv64.lw(T0, T1, TLB_OFF_VADDR));

    emitEffectiveGva(tb, off, T1, rs1, imm);
    emit(tb, off, rv64.srliw(T1, T1, softtlb_mod.PAGE_SHIFT));

    const bne_patch_pos = off.*;
    emit(tb, off, INSN_PLACEHOLDER);

    // Hit path: recompute `&tlb.entries[slot]` in `t1 (x6)`.
    emitTlbSlotPtr(tb, off, tlb_addr, T1);
    return .{ .align_bne_pos = align_bne_pos, .tag_bne_pos = bne_patch_pos };
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

fn resolvePinnedRs2ToT1(
    tb: *TranslationBlock,
    off: *usize,
    rs2: u5,
    check_r6: bool,
) u5 {
    if (rs2 == T0) {
        emit(tb, off, rv64.ld(T1, S11, OFF_T0));
        return T1;
    } else if (check_r6 and rs2 == T1) {
        emit(tb, off, rv64.ld(T1, S11, OFF_T1));
        return T1;
    } else if (rs2 == S11) {
        emit(tb, off, rv64.ld(T1, S11, OFF_S11));
        return T1;
    }
    return rs2;
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
        const val_reg = resolvePinnedRs2ToT1(tb, off, rs2, check_r6);
        const store_insn: u32 = switch (op) {
            MemOp.SB => rv64.sb(T0, val_reg, 0),
            MemOp.SH => rv64.sh(T0, val_reg, 0),
            else => rv64.sw(T0, val_reg, 0),
        };
        emit(tb, off, store_insn);
    }
}

fn emitSlowExitTail(
    tb: *TranslationBlock,
    off: *usize,
    current_pc: u32,
    patches: TagCheckPatches,
    beqz_patch_pos: usize,
    use_bnez_for_perm: bool,
) void {
    const jal_patch_pos = off.*;
    emit(tb, off, INSN_PLACEHOLDER);

    const slow_exit_pos = off.*;
    if (patches.align_bne_pos) |align_pos| {
        const rel = rel13(slow_exit_pos, align_pos);
        patchInsn(tb, align_pos, rv64.bne(T1, 0, rel));
    }
    const bne_rel = rel13(slow_exit_pos, patches.tag_bne_pos);
    patchInsn(tb, patches.tag_bne_pos, rv64.bne(T0, T1, bne_rel));

    const beqz_rel = rel13(slow_exit_pos, beqz_patch_pos);
    const perm_branch = if (use_bnez_for_perm)
        rv64.bne(T0, 0, beqz_rel)
    else
        rv64.beq(T0, 0, beqz_rel);
    patchInsn(tb, beqz_patch_pos, perm_branch);

    emit(tb, off, rv64.ld(T1, S11, OFF_T1));
    emit(tb, off, rv64.ld(T0, S11, OFF_T0));
    _ = emit_alu.emitExit(tb, off, current_pc);

    const jal_rel: i21 = @truncate(@as(isize, @intCast(off.* - jal_patch_pos)));
    patchInsn(tb, jal_patch_pos, rv64.jal(0, jal_rel));
}

fn restoreAfterLoadOrAtomic(
    tb: *TranslationBlock,
    off: *usize,
    rd: u5,
    is_fp: bool,
) void {
    if (!is_fp and rd == T1) {
        emit(tb, off, rv64.ld(T0, S11, OFF_T0));
        return;
    }
    if (!is_fp and rd == T0) {
        emit(tb, off, rv64.sd(S11, T1, OFF_T0));
    } else if (!is_fp and rd == S11) {
        emit(tb, off, rv64.sd(S11, T1, OFF_S11));
    }
    emit(tb, off, rv64.ld(T1, S11, OFF_T1));
    emit(tb, off, rv64.ld(T0, S11, OFF_T0));
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
    if (rd == 0 and op != MemOp.FLW and op != MemOp.FLD) return;
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
    if (rd == 0 and op != MemOp.FLW and op != MemOp.FLD) return;
    const len = memOpBytes(op);
    const patches = emitTagCheck(tb, off, tlb_addr, rs1, imm, len);

    emit(tb, off, rv64.lbu(T0, T1, TLB_OFF_FLAGS));
    emit(tb, off, rv64.andi(T0, T0, PTE.R));
    const beqz_patch_pos = off.*;
    emit(tb, off, INSN_PLACEHOLDER);

    emitSoftTlbHitHpa(tb, off, rs1, imm);
    emitLoadFromT0(tb, off, op, rd, T1);
    restoreAfterLoadOrAtomic(tb, off, rd, op == MemOp.FLW or op == MemOp.FLD);
    emitSlowExitTail(tb, off, current_pc, patches, beqz_patch_pos, false);
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
    const len = memOpBytes(op);
    const patches = emitTagCheck(tb, off, tlb_addr, rs1, imm, len);

    emit(tb, off, rv64.lbu(T0, T1, TLB_OFF_FLAGS));
    emit(tb, off, rv64.andi(T0, T0, PTE.W));
    const beqz_patch_pos = off.*;
    emit(tb, off, INSN_PLACEHOLDER);

    emitSoftTlbHitHpa(tb, off, rs1, imm);
    emitStoreToT0(tb, off, op, rs2, true);
    emit(tb, off, rv64.ld(T1, S11, OFF_T1));
    emit(tb, off, rv64.ld(T0, S11, OFF_T0));
    emitSlowExitTail(tb, off, current_pc, patches, beqz_patch_pos, false);
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

    const patches = emitTagCheck(tb, off, tlb_addr, rs1, 0, @sizeOf(u32));

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

    const src_reg: u5 = if (funct5 == AmoFunct5.LR)
        0
    else
        resolvePinnedRs2ToT1(tb, off, rs2, true);
    const dest_reg: u5 = if (rd == T0 or rd == T1 or rd == S11 or rd == 0)
        T1
    else
        rd;
    emit(tb, off, rv64.encodeA(funct5, aq, rl, dest_reg, T0, src_reg));
    restoreAfterLoadOrAtomic(tb, off, rd, false);
    const is_rw = req_mask == rw_mask;
    emitSlowExitTail(tb, off, current_pc, patches, beqz_patch_pos, is_rw);
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
