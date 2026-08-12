// Executable Host JIT Code Buffer Allocator & Block Cache Index
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const block_mod = @import("block.zig");
const TranslationBlock = block_mod.TranslationBlock;
const rv64 = @import("../emitters/rv64.zig");

pub const MAX_BLOCKS: usize = 4096;
pub const JIT_CACHE_SIZE: usize = 2 * 1024 * 1024; // 2MB JIT code buffer pool

pub const Cache = struct {
    code_buffer: []u8,
    code_offset: usize = 0,
    blocks: [MAX_BLOCKS]TranslationBlock = undefined,
    block_count: usize = 0,
    hash_table: [MAX_BLOCKS]?*TranslationBlock = std.mem.zeroes([MAX_BLOCKS]?*TranslationBlock),

    pub fn init(buffer: []u8) Cache {
        return Cache{
            .code_buffer = buffer,
            .code_offset = 0,
            .block_count = 0,
        };
    }

    fn hash(guest_pc: u32) usize {
        return (guest_pc ^ (guest_pc >> 12)) & (MAX_BLOCKS - 1);
    }

    pub fn lookup(self: *Cache, guest_pc: u32) ?*TranslationBlock {
        const slot = hash(guest_pc);
        if (self.hash_table[slot]) |tb| {
            if (tb.guest_pc == guest_pc) return tb;
        }
        return null;
    }

    pub fn allocateBlock(self: *Cache, guest_pc: u32, max_host_len: usize) !*TranslationBlock {
        if (self.block_count >= MAX_BLOCKS) return error.CacheFull;
        const aligned_offset = (self.code_offset + 7) & ~@as(usize, 7);
        if (aligned_offset + max_host_len > self.code_buffer.len) return error.CodeBufferFull;

        const tb = &self.blocks[self.block_count];
        self.block_count += 1;

        tb.* = .{
            .guest_pc = guest_pc,
            .guest_size = 0,
            .host_code = self.code_buffer[aligned_offset .. aligned_offset + max_host_len],
            .host_len = 0,
        };

        const slot = hash(guest_pc);
        self.hash_table[slot] = tb;

        return tb;
    }

    pub fn commitBlock(self: *Cache, code_bytes: usize) void {
        const aligned = (code_bytes + 7) & ~@as(usize, 7);
        self.code_offset += aligned;
        rv64.fenceI();
    }

    pub fn clear(self: *Cache) void {
        self.code_offset = 0;
        self.block_count = 0;
        @memset(std.mem.sliceAsBytes(self.hash_table[0..]), 0);
        rv64.fenceI();
    }
};
