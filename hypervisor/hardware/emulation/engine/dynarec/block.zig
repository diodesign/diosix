// Translation Block Representation for Diosix Dynamic Recompiler.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const rv64 = @import("../emitters/rv64.zig");
const vcpu_mod = @import("../../vcpu.zig");
const softtlb_mod = @import("../../softtlb.zig");

pub const REG_ZERO: u5 = 0;
pub const GUEST_REG_SP: u5 = 2;
pub const GUEST_REG_FP: u5 = 8;
pub const HOST_REG_T0: u5 = 5;
pub const HOST_REG_T1: u5 = 6;
pub const HOST_REG_S11: u5 = 27;

pub const VCPU_OFF_T0: i12 = @as(i12, HOST_REG_T0) * @sizeOf(u64);
pub const VCPU_OFF_T1: i12 = @as(i12, HOST_REG_T1) * @sizeOf(u64);
pub const VCPU_OFF_S11: i12 = @as(i12, HOST_REG_S11) * @sizeOf(u64);
pub const VCPU_OFF_PC: i12 = @offsetOf(vcpu_mod.VCpu, "pc");
pub const OFF_TLB_PTR: i12 = @offsetOf(vcpu_mod.VCpu, "tlb_entries_ptr");
pub const VCPU_OFF_TLB_PTR: i12 = OFF_TLB_PTR;

pub const TLB_OFF_VADDR: i12 =
    @offsetOf(softtlb_mod.SoftTlbEntry, "guest_vaddr_page");
pub const TLB_OFF_FLAGS: i12 =
    @offsetOf(softtlb_mod.SoftTlbEntry, "flags");
pub const TLB_OFF_HPA: i12 =
    @offsetOf(softtlb_mod.SoftTlbEntry, "host_paddr_page");

pub const AUIPC_MIN_OFFSET: isize = -0x8000_0000;
pub const AUIPC_MAX_OFFSET: isize = 0x7fff_ffff;
pub const WORD_BITS: u6 = 32;
pub const ALIGN64_MASK: usize = @alignOf(u64) - 1;
pub const ALIGN32_MASK: usize = @alignOf(u32) - 1;

pub const ExitBranch = struct {
    patch_offset: usize,
    target_guest_pc: u32,
    is_direct: bool = true,
};

pub const TranslationBlock = struct {
    guest_pc: u32,
    satp: u32 = 0,
    priv: u8 = 0,
    is_global: bool = false,
    guest_size: u32,
    host_code: []u8,
    host_len: usize,
    layout_epoch: u32 = 0,
    is_fast_path: bool = false,
    exit_branch1: ?ExitBranch = null,
    exit_branch2: ?ExitBranch = null,
    chained_block1: ?*TranslationBlock = null,
    chained_block2: ?*TranslationBlock = null,

    pub fn patchBranch(
        self: *TranslationBlock,
        branch_idx: u8,
        target_tb: *TranslationBlock,
    ) void {
        const branch = if (branch_idx == 0)
            self.exit_branch1
        else
            self.exit_branch2;
        if (branch) |b| {
            if (!b.is_direct) return;
            // Prevent closed native loops across basic blocks so that backward
            // branches exit to the Engine dispatcher to promptly service
            // interrupts, timer ticks, and IPIs.
            if (b.target_guest_pc <= self.guest_pc) return;
            if (b.patch_offset + @sizeOf(u64) > self.host_code.len) return;
            const src_host_addr = @intFromPtr(self.host_code.ptr) +
                b.patch_offset;
            const target_host_addr = @intFromPtr(target_tb.host_code.ptr);
            const rel_offset = @as(isize, @bitCast(target_host_addr)) -
                @as(isize, @bitCast(src_host_addr));

            // AUIPC + JALR has +/-2GB reach: [-0x8000_0000, 0x7fff_ffff].
            if (rel_offset < AUIPC_MIN_OFFSET or
                rel_offset > AUIPC_MAX_OFFSET) return;

            const sp = rv64.splitImm32(
                @truncate(@as(usize, @bitCast(rel_offset))),
            );
            const auipc_insn = rv64.auipc(HOST_REG_T0, sp.upper);
            const jalr_insn = rv64.jalr(REG_ZERO, HOST_REG_T0, sp.lower);

            if ((src_host_addr & ALIGN64_MASK) == 0) {
                const insns_64 = @as(u64, auipc_insn) |
                    (@as(u64, jalr_insn) << WORD_BITS);
                const ptr_64: *align(8) u64 = @ptrCast(
                    @alignCast(&self.host_code[b.patch_offset]),
                );
                @atomicStore(u64, ptr_64, insns_64, .release);
            } else if ((src_host_addr & ALIGN32_MASK) == 0) {
                const ptr_lo: *align(4) u32 = @ptrCast(
                    @alignCast(&self.host_code[b.patch_offset]),
                );
                const ptr_hi: *align(4) u32 = @ptrCast(
                    @alignCast(&self.host_code[b.patch_offset + 4]),
                );
                @atomicStore(u32, ptr_lo, auipc_insn, .release);
                @atomicStore(u32, ptr_hi, jalr_insn, .release);
            } else {
                std.mem.writeInt(
                    u32,
                    self.host_code[b.patch_offset..][0..4],
                    auipc_insn,
                    .little,
                );
                std.mem.writeInt(
                    u32,
                    self.host_code[b.patch_offset + 4 ..][0..4],
                    jalr_insn,
                    .little,
                );
            }
            rv64.fenceI();
            if (branch_idx == 0) {
                self.chained_block1 = target_tb;
            } else {
                self.chained_block2 = target_tb;
            }
        }
    }
};

test "TranslationBlock forward vs backward patchBranch" {
    var buf1: [16]u8 align(8) = @splat(0);
    var buf2: [16]u8 align(8) = @splat(0);

    var tb1 = TranslationBlock{
        .guest_pc = 0x8000_0000,
        .guest_size = 4,
        .host_code = &buf1,
        .host_len = 8,
        .exit_branch1 = .{ .patch_offset = 0, .target_guest_pc = 0x8000_0004 },
        .exit_branch2 = .{ .patch_offset = 8, .target_guest_pc = 0x8000_0000 },
    };
    var tb2 = TranslationBlock{
        .guest_pc = 0x8000_0004,
        .guest_size = 4,
        .host_code = &buf2,
        .host_len = 8,
    };

    // Forward branch should patch and set chained_block1.
    tb1.patchBranch(0, &tb2);
    const exp_tb2: ?*TranslationBlock = &tb2;
    try std.testing.expectEqual(exp_tb2, tb1.chained_block1);

    // Self/backward branch should not patch.
    tb1.patchBranch(1, &tb1);
    const exp_null: ?*TranslationBlock = null;
    try std.testing.expectEqual(exp_null, tb1.chained_block2);
    std.testing.refAllDecls(@This());
}
