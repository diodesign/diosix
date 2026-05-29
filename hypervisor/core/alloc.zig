// Linked-list-based heap allocator
//
// Not thread safe. It's up to the caller to ensure only one thread uses an instance of the heap allocator at a time.
// This std-compatible allocator is for hypervisor-level components, and not for allocating memory for less-privileged code.
//
// HeapBlock sizes include the alignment padding, header, and payload whether the block is free or in use.
// The payload is the memory the caller can use. Free blocks are merged automatically.
// HeapBlock sizes are also rounded up to the nearest multiple of heap_block_size_multiple bytes to reduce fragmentation.
// The payload area within a block can be resized by the caller. The allocator decides whether to reject the request
// or resize the whole block to accommodate the request. See: resize().
//
// HeapBlock layout in memory in ascending address order, with each --- section aligned at least to the system usize:
// ---------------------------------------------------------------------------------------------------
//   Padding bytes to align the start of the payload area to the required alignment   (padding_size)
// ---------------------------------------------------------------------------------------------------
//   HeapBlock header containing metadata, including sizes and alignment requirement (sizeOf(Block))
// ---------------------------------------------------------------------------------------------------
//   Payload area that the caller can use                                      (payload_active_size)
// -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -
//   Spare bytes in the block from a resize or size roundup         (max_size - payload_active_size)
// ---------------------------------------------------------------------------------------------------
// Total size of the above: max_size
// Each HeapBlock is structured this way so that when the caller passes a pointer to the payload area
// to the allocator, the block header is in a known location relative to the payload pointer,
// and the alignment padding is placed below the header in memory.
//
// Simplicity and safety is the key here.
// If the allocator is holding back performance, we'll revist these design decisions.
//
// Some things to consider for future:
// * separate queues for different block sizes
// * separate queues for different alignment requirements
// * separate queues for different types of memory
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const debug = @import("debug.zig");
const std = @import("std");
const Alignment = std.mem.Alignment;
pub const Allocator = std.mem.Allocator;

pub const HeapAllocError = error{
    not_enough_free_space,
    bad_alignment,
    too_fragmented,
    bad_block_in_list,
};

const HeapBlockState = enum(usize) { free = 0xdeaddead, in_use = 0xc0ffeeee, _ };
const heap_block_size_multiple: usize = 64;

const HeapBlock = struct {
    next: ?*HeapBlock, // null for last block in the list
    state: HeapBlockState,
    max_size: usize,
    payload_active_size: usize,
    padding_size: usize,
    alignment: Alignment,
    owner: ?*anyopaque, // null for created during initialization or if owner is unknown

    fn getPayloadPtr(self: *HeapBlock) [*]u8 {
        const ptr: [*]u8 = @ptrCast(self);
        return ptr + @sizeOf(HeapBlock);
    }
};

pub const HeapAllocator = struct {
    first: *HeapBlock, // there must be at least one block in the list (either in-use or free)
    free_size: usize,
    inuse_size: usize,

    // initialize the allocator struct for an area of contiguous physical memory
    // base = address of the start of the memory area
    //        address must be field_ptr: *T aligned to the system pointer size
    // size = the size of the memory area in bytes
    //        size must be enough to hold at least one HeapBlock
    // returns an error if the initialization failed
    pub fn init(self: *HeapAllocator, base: usize, size: usize) !void {
        const heap_block_size_multiple_align = Alignment.fromByteUnits(@sizeOf(*anyopaque));
        if (!Alignment.check(heap_block_size_multiple_align, base)) return HeapAllocError.bad_alignment;
        if (size < @sizeOf(HeapBlock)) return HeapAllocError.not_enough_free_space;

        // create a free block from the available memory and make it the first block
        self.first = @ptrFromInt(base);
        self.first.next = null;
        self.first.state = .free;
        self.first.max_size = size;
        self.first.payload_active_size = 0;
        self.first.padding_size = 0;
        self.first.alignment = heap_block_size_multiple_align;
        self.first.owner = null;

        self.free_size = size;
        self.inuse_size = 0;
    }

    // return a std.mem.Allocator interface for this HeapAllocator
    pub fn allocator(self: *HeapAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    // implement the std.mem.Allocator.VTable API
    //
    // See: https://ziglang.org/documentation/master/std/#std.mem.Allocator.VTable
    //
    pub fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *HeapAllocator = @ptrCast(@alignCast(ctx));

        var prev: ?*HeapBlock = null;
        var search: ?*HeapBlock = self.first;
        while (search) |candidate| {
            if (candidate.state == .free) {
                mergeFreeBlocks(candidate);

                if (tryAllocateFromBlock(self, prev, candidate, len, alignment, ret_addr)) |payload_ptr| {
                    return payload_ptr;
                }
            }
            prev = candidate;
            search = candidate.next;
        }

        return null;
    }

    pub fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = ret_addr;
        const block: *HeapBlock = @ptrCast(@alignCast(memory.ptr - @sizeOf(HeapBlock)));

        if (block.state != .in_use) {
            return false;
        }

        // The length of the slice passed to resize must match the active payload size.
        if (memory.len != block.payload_active_size) {
            return false;
        }

        // The alignment passed to resize must match the original alignment.
        if (block.alignment.toByteUnits() != alignment.toByteUnits()) {
            return false;
        }

        // Check if the new size can fit within the existing block's allocated space.
        const required_size = block.padding_size + @sizeOf(HeapBlock) + new_len;
        if (required_size <= block.max_size) {
            // New size fits within the current block. This is a successful in-place resize.
            block.payload_active_size = new_len;
            return true;
        }

        // Cannot resize in-place. Per std.mem.Allocator.resize documentation,
        // we must return false and leave the original allocation untouched.
        return false;
    }

    pub fn remap(
        _: *anyopaque,
        _: []u8,
        _: Alignment,
        _: usize,
        _: usize,
    ) ?[*]u8 {
        return null;
    }

    pub fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        _ = alignment;
        _ = ret_addr;
        const self: *HeapAllocator = @ptrCast(@alignCast(ctx));
        const victim: *HeapBlock = @ptrCast(@alignCast(memory.ptr - @sizeOf(HeapBlock)));

        if (victim.state != .in_use) {
            return;
        }

        // The length of the slice passed to free must match the active payload size.
        if (memory.len != victim.payload_active_size) {
            return;
        }

        victim.state = .free;
        self.inuse_size -= victim.max_size;
        self.free_size += victim.max_size;
        victim.owner = null;
    }

    fn tryAllocateFromBlock(self: *HeapAllocator, prev: ?*HeapBlock, block: *HeapBlock, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        // A block/chunk starts at its header address minus its padding.
        const chunk_start = @intFromPtr(block) - block.padding_size;
        const header_size = @sizeOf(HeapBlock);

        // The payload must start at least header_size after the chunk start.
        const min_payload_ptr = chunk_start + header_size;
        const aligned_payload_ptr = std.mem.alignForward(usize, min_payload_ptr, alignment.toByteUnits());

        // The header must be immediately before the payload for @fieldParentPtr to work.
        const new_header_ptr = aligned_payload_ptr - header_size;
        const padding = new_header_ptr - chunk_start;

        const rounded_up_payload_size = (len + heap_block_size_multiple - 1) & ~(heap_block_size_multiple - 1);
        const required_size = padding + header_size + rounded_up_payload_size;

        if (block.max_size < required_size) {
            return null; // block is too small
        }

        // Check if we should split the block
        const remainder_size = block.max_size - required_size;
        if (remainder_size >= header_size + heap_block_size_multiple) {
            // Create a new free block from the remainder
            const new_free_chunk_start = chunk_start + required_size;
            const new_free_block: *HeapBlock = @ptrFromInt(new_free_chunk_start);
            new_free_block.* = .{
                .next = block.next,
                .state = .free,
                .max_size = remainder_size,
                .payload_active_size = 0,
                .padding_size = 0,
                .alignment = Alignment.fromByteUnits(@sizeOf(usize)),
                .owner = null,
            };

            // Update the current block to be in-use and truncated
            const inuse_block: *HeapBlock = @ptrFromInt(new_header_ptr);
            const old_next = new_free_block;
            inuse_block.* = .{
                .next = old_next,
                .state = .in_use,
                .max_size = required_size,
                .payload_active_size = len,
                .padding_size = padding,
                .alignment = alignment,
                .owner = @as(*anyopaque, @ptrFromInt(ret_addr)),
            };

            // Link the previous block to this new header location
            if (prev) |p| p.next = inuse_block else self.first = inuse_block;

            self.inuse_size += inuse_block.max_size;
            self.free_size -= inuse_block.max_size;
            return inuse_block.getPayloadPtr();
        } else {
            // Use the whole block
            const final_size = block.max_size;
            const inuse_block: *HeapBlock = @ptrFromInt(new_header_ptr);
            const old_next = block.next;
            inuse_block.* = .{
                .next = old_next,
                .state = .in_use,
                .max_size = final_size,
                .payload_active_size = len,
                .padding_size = padding,
                .alignment = alignment,
                .owner = @as(*anyopaque, @ptrFromInt(ret_addr)),
            };

            if (prev) |p| p.next = inuse_block else self.first = inuse_block;

            self.inuse_size += inuse_block.max_size;
            self.free_size -= inuse_block.max_size;
            return inuse_block.getPayloadPtr();
        }
    }

    fn mergeFreeBlocks(block: *HeapBlock) void {
        var current = block;
        while (current.next) |next_block| {
            if (next_block.state != .free) break;

            const current_chunk_start = @intFromPtr(current) - current.padding_size;
            const next_chunk_start = @intFromPtr(next_block) - next_block.padding_size;

            if (current_chunk_start + current.max_size == next_chunk_start) {
                current.max_size += next_block.max_size;
                current.next = next_block.next;
                continue;
            }
            break;
        }
    }
};

test "heap allocator basic alloc and free" {
    const testing = std.testing;

    var heap_memory: [1024]u8 align(64) = undefined;
    var heap = HeapAllocator{
        .first = undefined,
        .free_size = 0,
        .inuse_size = 0,
    };
    try heap.init(@intFromPtr(&heap_memory), heap_memory.len);

    const allocator = heap.allocator();

    const mem1 = try allocator.alloc(u8, 100);
    try testing.expect(mem1.len == 100);
    try testing.expect(heap.inuse_size > 0);

    const mem2 = try allocator.alloc(u8, 200);
    try testing.expect(mem2.len == 200);

    allocator.free(@as([]u8, mem1));
    allocator.free(@as([]u8, mem2));
    try testing.expectEqual(@as(usize, 0), heap.inuse_size);
    try testing.expectEqual(heap_memory.len, heap.free_size);
}

test "heap allocator alignment" {
    const testing = std.testing;

    var heap_memory: [2048]u8 align(64) = undefined;
    var heap = HeapAllocator{
        .first = undefined,
        .free_size = 0,
        .inuse_size = 0,
    };
    try heap.init(@intFromPtr(&heap_memory), heap_memory.len);
    const allocator = heap.allocator();

    const mem_align_16 = try allocator.create(u128);
    defer allocator.destroy(mem_align_16);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(mem_align_16) % @alignOf(u128));

    const mem_align_64 = try allocator.alignedAlloc(u8, Alignment.fromByteUnits(64), 100);
    defer allocator.free(@as([]u8, mem_align_64));
    try testing.expectEqual(@as(usize, 0), @intFromPtr(mem_align_64.ptr) % 64);
}

test "heap allocator resize" {
    const testing = std.testing;

    var heap_memory: [1024]u8 align(64) = undefined;
    var heap = HeapAllocator{
        .first = undefined,
        .free_size = 0,
        .inuse_size = 0,
    };
    try heap.init(@intFromPtr(&heap_memory), heap_memory.len);
    const allocator = heap.allocator();

    const mem = try allocator.alloc(u8, 50);
    try testing.expect(mem.len == 50);

    var success = allocator.resize(@as([]u8, mem), 25);
    try testing.expect(success);
    const mem_shrunk = mem[0..25];

    success = allocator.resize(@as([]u8, mem_shrunk), 60);
    try testing.expect(success);
    const mem_grown = mem.ptr[0..60]; // use original mem which now has 60 active bytes

    success = allocator.resize(@as([]u8, mem_grown), 2048);
    try testing.expect(!success);
    try testing.expect(mem_grown.len == 60);

    allocator.free(@as([]u8, mem_grown));
}

test "heap allocator fragmentation and merging" {
    const testing = std.testing;

    var heap_memory: [2048]u8 align(64) = undefined;
    var heap = HeapAllocator{
        .first = undefined,
        .free_size = 0,
        .inuse_size = 0,
    };
    try heap.init(@intFromPtr(&heap_memory), heap_memory.len);
    const allocator = heap.allocator();

    const mem1 = try allocator.alloc(u8, 100);
    const mem2 = try allocator.alloc(u8, 100);
    const mem3 = try allocator.alloc(u8, 100);

    const block1: *HeapBlock = @ptrCast(@alignCast(mem1.ptr - @sizeOf(HeapBlock)));
    const block2: *HeapBlock = @ptrCast(@alignCast(mem2.ptr - @sizeOf(HeapBlock)));

    const chunk1_start = @intFromPtr(block1) - block1.padding_size;
    const chunk2_start = @intFromPtr(block2) - block2.padding_size;

    try testing.expect(chunk1_start + block1.max_size == chunk2_start);

    allocator.free(@as([]u8, mem2));
    try testing.expect(block2.state == .free);

    allocator.free(@as([]u8, mem1));
    try testing.expect(block1.state == .free);
    try testing.expect(block1.max_size > 100);

    allocator.free(@as([]u8, mem3));
    try testing.expectEqual(heap_memory.len, heap.free_size);
}

test "heap allocator out of memory" {
    const testing = std.testing;

    var heap_memory: [512]u8 align(64) = undefined;
    var heap = HeapAllocator{
        .first = undefined,
        .free_size = 0,
        .inuse_size = 0,
    };
    try heap.init(@intFromPtr(&heap_memory), heap_memory.len);
    const allocator = heap.allocator();

    const mem1 = try allocator.alloc(u8, 400);
    defer allocator.free(@as([]u8, mem1));

    const mem2 = allocator.alloc(u8, 200);
    try testing.expectError(error.OutOfMemory, mem2);

    allocator.free(@as([]u8, mem1));
    const mem3 = allocator.alloc(u8, heap_memory.len);
    try testing.expectError(error.OutOfMemory, mem3);
}
