// Translation Block Representation for Diosix Dynamic Recompiler.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const rv64 = @import("../emitters/rv64.zig");

pub const ExitBranch = struct {
    patch_offset: usize,
    target_guest_pc: u32,
    is_direct: bool = true,
};

pub const TranslationBlock = struct {
    guest_pc: u32,
    satp: u32 = 0,
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
            if (b.patch_offset + 8 > self.host_code.len) return;
            const src_host_addr = @intFromPtr(self.host_code.ptr) +
                b.patch_offset;
            const target_host_addr = @intFromPtr(target_tb.host_code.ptr);
            const rel_offset = @as(isize, @bitCast(target_host_addr)) -
                @as(isize, @bitCast(src_host_addr));

            // AUIPC + JALR has +/-2GB reach: [-0x8000_0000, 0x7FFF_FFFF].
            if (rel_offset < -0x8000_0000 or rel_offset > 0x7fff_ffff) return;

            const j_upper = @as(i20, @truncate((rel_offset + 0x800) >> 12));
            const rel_u = @as(usize, @bitCast(rel_offset));
            const rel_u12: u12 = @truncate(rel_u & 0xfff);
            const j_lower: i12 = @bitCast(rel_u12);
            const auipc_insn = rv64.auipc(5, j_upper);
            const jalr_insn = rv64.jalr(0, 5, j_lower);

            if ((src_host_addr & 7) == 0) {
                const insns_64 = @as(u64, auipc_insn) |
                    (@as(u64, jalr_insn) << 32);
                const ptr_64: *align(8) u64 = @ptrCast(
                    @alignCast(&self.host_code[b.patch_offset]),
                );
                @atomicStore(u64, ptr_64, insns_64, .release);
            } else if ((src_host_addr & 3) == 0) {
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
}
