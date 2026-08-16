// Executable Host JIT Code Buffer Allocator & Block Cache Index
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const block_mod = @import("block.zig");
const TranslationBlock = block_mod.TranslationBlock;
const rv64 = @import("../emitters/rv64.zig");

const builtin = @import("builtin");

pub const MAX_BLOCKS: usize = 16384;
pub const HASH_SIZE: usize = 32768;
pub const JIT_CACHE_SIZE: usize = 8 * 1024 * 1024; // 8MB JIT code buffer pool

pub fn getExitAddr() usize {
    if (comptime builtin.target.cpu.arch.isRISCV()) {
        const ext = struct {
            extern fn hw_dynarec_exit() callconv(.c) void;
        };
        return @intFromPtr(&ext.hw_dynarec_exit);
    } else {
        return 0;
    }
}

pub const Cache = struct {
    code_buffer: []u8,
    code_offset: usize = 0,
    blocks: [MAX_BLOCKS]TranslationBlock = undefined,
    block_count: usize = 0,
    hash_table: [HASH_SIZE]?*TranslationBlock = std.mem.zeroes([HASH_SIZE]?*TranslationBlock),
    layout_epoch: u32 = 1,

    pub fn initOnPtr(self: *Cache, buffer: []u8) void {
        self.code_buffer = buffer;
        self.code_offset = 0;
        self.block_count = 0;
        self.layout_epoch = 1;
        @memset(std.mem.sliceAsBytes(self.hash_table[0..]), 0);
        self.initTrampolines();
    }

    pub fn flush(self: *Cache) void {
        self.code_offset = 0;
        self.block_count = 0;
        self.layout_epoch +%= 1;
        @memset(std.mem.sliceAsBytes(self.hash_table[0..]), 0);
        self.initTrampolines();
    }

    pub fn initTrampolines(self: *Cache) void {
        self.code_offset = 0;
        rv64.fenceI();
    }

    fn hash(guest_pc: u32) usize {
        return (guest_pc ^ (guest_pc >> 12) ^ (guest_pc >> 2)) & (HASH_SIZE - 1);
    }

    pub fn lookup(self: *Cache, guest_pc: u32, satp: u32) ?*TranslationBlock {
        var slot = hash(guest_pc);
        var tries: usize = 0;
        while (tries < 8) : (tries += 1) {
            if (self.hash_table[slot]) |tb| {
                if (tb.layout_epoch == self.layout_epoch and tb.guest_pc == guest_pc and (guest_pc >= 0xC0000000 or tb.satp == satp)) return tb;
                slot = (slot + 1) & (HASH_SIZE - 1);
            } else {
                return null;
            }
        }
        return null;
    }

    pub fn allocateBlock(self: *Cache, guest_pc: u32, satp: u32, max_host_len: usize) !*TranslationBlock {
        if (self.block_count >= MAX_BLOCKS) return error.CacheFull;
        const aligned_offset = (self.code_offset + 7) & ~@as(usize, 7);
        if (aligned_offset + max_host_len > self.code_buffer.len) return error.CodeBufferFull;

        const tb = &self.blocks[self.block_count];
        self.block_count += 1;

        tb.* = .{
            .guest_pc = guest_pc,
            .satp = satp,
            .guest_size = 0,
            .host_code = self.code_buffer[aligned_offset .. aligned_offset + max_host_len],
            .host_len = 0,
            .layout_epoch = self.layout_epoch,
            .is_fast_path = false,
        };

        return tb;
    }

    pub fn commitBlock(self: *Cache, tb: *TranslationBlock, code_bytes: usize) void {
        const aligned = (code_bytes + 7) & ~@as(usize, 7);
        tb.host_code = tb.host_code[0..aligned];
        self.code_offset += aligned;

        var slot = hash(tb.guest_pc);
        var tries: usize = 0;
        while (tries < 8) : (tries += 1) {
            if (self.hash_table[slot]) |existing| {
                if (existing.guest_pc == tb.guest_pc and (tb.guest_pc >= 0xC0000000 or existing.satp == tb.satp)) {
                    self.hash_table[slot] = tb;
                    break;
                }
            } else {
                self.hash_table[slot] = tb;
                break;
            }
            slot = (slot + 1) & (HASH_SIZE - 1);
        }

        rv64.fenceI();
    }

    pub fn cancelBlock(self: *Cache) void {
        if (self.block_count > 0) {
            self.block_count -= 1;
        }
    }

    pub fn chainBlock(self: *Cache, new_tb: *TranslationBlock) void {
        // Forward chaining: patch outgoing forward branches to already compiled targets
        if (new_tb.exit_branch1) |b1| {
            if (b1.target_guest_pc > new_tb.guest_pc) {
                if (self.lookup(b1.target_guest_pc, new_tb.satp)) |target| {
                    new_tb.patchBranch(0, target);
                }
            }
        }
        if (new_tb.exit_branch2) |b2| {
            if (b2.target_guest_pc > new_tb.guest_pc) {
                if (self.lookup(b2.target_guest_pc, new_tb.satp)) |target| {
                    new_tb.patchBranch(1, target);
                }
            }
        }

        // Backward chaining: check if any existing blocks can now jump forward to new_tb
        for (self.blocks[0..self.block_count]) |*tb| {
            if (tb == new_tb) continue;
            if (tb.exit_branch1) |b1| {
                if (b1.target_guest_pc == new_tb.guest_pc and new_tb.guest_pc > tb.guest_pc and (new_tb.guest_pc >= 0xC0000000 or tb.satp == new_tb.satp)) {
                    tb.patchBranch(0, new_tb);
                }
            }
            if (tb.exit_branch2) |b2| {
                if (b2.target_guest_pc == new_tb.guest_pc and new_tb.guest_pc > tb.guest_pc and (new_tb.guest_pc >= 0xC0000000 or tb.satp == new_tb.satp)) {
                    tb.patchBranch(1, new_tb);
                }
            }
        }
    }
};
