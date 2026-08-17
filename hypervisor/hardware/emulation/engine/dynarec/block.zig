// Translation Block Representation for Diosix Dynamic Recompiler
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

    pub fn patchBranch(self: *TranslationBlock, branch_idx: u8, target_tb: *TranslationBlock) void {
        const branch = if (branch_idx == 0) self.exit_branch1 else self.exit_branch2;
        if (branch) |b| {
            if (!b.is_direct) return;
            // Prevent closed native loops across basic blocks so that backward branches
            // exit to the Engine dispatcher to promptly service interrupts, timer ticks, and IPIs.
            if (b.target_guest_pc <= self.guest_pc) return;
            if (b.patch_offset + 8 > self.host_code.len) return;
            const src_host_addr = @intFromPtr(self.host_code.ptr) + b.patch_offset;
            const target_host_addr = @intFromPtr(target_tb.host_code.ptr);
            const rel_offset = @as(isize, @bitCast(target_host_addr)) - @as(isize, @bitCast(src_host_addr));

            const j_upper = @as(i20, @truncate((rel_offset + 0x800) >> 12));
            const j_lower = @as(i12, @bitCast(@as(u12, @truncate(@as(usize, @bitCast(rel_offset)) & 0xFFF))));
            const auipc_insn = rv64.auipc(5, j_upper);
            const jalr_insn = rv64.jalr(0, 5, j_lower);
            std.mem.writeInt(u32, self.host_code[b.patch_offset..][0..4], auipc_insn, .little);
            std.mem.writeInt(u32, self.host_code[b.patch_offset + 4..][0..4], jalr_insn, .little);
            rv64.fenceI();
            if (branch_idx == 0) self.chained_block1 = target_tb else self.chained_block2 = target_tb;
        }
    }
};
