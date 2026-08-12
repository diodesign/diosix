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
    guest_size: u32,
    host_code: []u8,
    host_len: usize,
    exit_branch1: ?ExitBranch = null,
    exit_branch2: ?ExitBranch = null,
    chained_block1: ?*TranslationBlock = null,
    chained_block2: ?*TranslationBlock = null,

    pub fn patchBranch(self: *TranslationBlock, branch_idx: u8, target_tb: *TranslationBlock) void {
        const branch = if (branch_idx == 0) self.exit_branch1 else self.exit_branch2;
        if (branch) |b| {
            if (!b.is_direct) return;
            const src_host_addr = @intFromPtr(self.host_code.ptr) + b.patch_offset;
            const target_host_addr = @intFromPtr(target_tb.host_code.ptr);
            const rel_offset = @as(isize, @bitCast(target_host_addr)) - @as(isize, @bitCast(src_host_addr));

            if (rel_offset >= -1048576 and rel_offset <= 1048575) {
                const jal_insn = rv64.jal(0, @as(i21, @truncate(rel_offset)));
                std.mem.writeInt(u32, self.host_code[b.patch_offset..][0..4], jal_insn, .little);
                rv64.fenceI();
                if (branch_idx == 0) self.chained_block1 = target_tb else self.chained_block2 = target_tb;
            }
        }
    }
};
