// Linked-list-based heap allocator.
//
// Protected by a per-instance SpinLock. This std-compatible allocator is for
// M-mode hypervisor components, and not for allocating guest memory.
//
// HeapBlock sizes include alignment padding, header, and payload whether the
// block is free or in use. The payload is the memory the caller can use. Free
// blocks are merged automatically. HeapBlock sizes are rounded up to the
// nearest multiple of heap_block_size_multiple bytes to reduce fragmentation.
// The payload area within a block can be resized in place by the caller via
// resize().
//
// HeapBlock layout in memory in ascending address order:
// ---------------------------------------------------------------------------
//   Padding bytes to align the start of the payload area       (padding_size)
// ---------------------------------------------------------------------------
//   HeapBlock header containing metadata and alignment        (sizeOf(Block))
// ---------------------------------------------------------------------------
//   Payload area that the caller can use                (payload_active_size)
// -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -
//   Spare bytes from a resize or size roundup  (max_size - payload_active_size)
// ---------------------------------------------------------------------------
// Total size of the above: max_size.
// Each HeapBlock is structured this way so that when the caller passes a
// pointer to the payload area to the allocator, the block header is in a known
// location immediately preceding the payload pointer, and alignment padding is
// placed below the header in memory.
//
// Simplicity and safety are the key priorities here.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const atomic = @import("atomic.zig");
const std = @import("std");
const Alignment = std.mem.Alignment;
pub const Allocator = std.mem.Allocator;

pub const HeapAllocError = error{
    not_enough_free_space,
    bad_alignment,
};

const HeapBlockState = enum(usize) {
    free = 0xdeaddead,
    in_use = 0xc0ffeeee,
    _,
};
const heap_block_size_multiple: usize = 64;

const HeapBlock = struct {
    next: ?*HeapBlock, // Null for last block in the list.
    state: HeapBlockState,
    max_size: usize,
    payload_active_size: usize,
    padding_size: usize,
    alignment: Alignment,
    owner: ?*anyopaque, // Null if free or created during initialization.

    fn getPayloadPtr(self: *HeapBlock) [*]u8 {
        const ptr: [*]u8 = @ptrCast(self);
        return ptr + @sizeOf(HeapBlock);
    }
};

pub const HeapAllocator = struct {
    first: *HeapBlock, // Always at least one block in list (in-use or free).
    free_size: usize,
    inuse_size: usize,
    lock: atomic.SpinLock = atomic.SpinLock.init(),

    // Initialize the allocator struct for a contiguous physical memory area.
    // base: start address (must be aligned to system pointer size).
    // size: size in bytes (must hold at least one HeapBlock).
    pub fn init(self: *HeapAllocator, base: usize, size: usize) !void {
        self.lock = atomic.SpinLock.init();
        const ptr_align = Alignment.fromByteUnits(@sizeOf(*anyopaque));
        if (!Alignment.check(ptr_align, base)) {
            return HeapAllocError.bad_alignment;
        }
        if (size < @sizeOf(HeapBlock)) {
            return HeapAllocError.not_enough_free_space;
        }

        // Create an initial free block spanning the entire memory area.
        self.first = @ptrFromInt(base);
        self.first.* = .{
            .next = null,
            .state = .free,
            .max_size = size,
            .payload_active_size = 0,
            .padding_size = 0,
            .alignment = ptr_align,
            .owner = null,
        };

        self.free_size = size;
        self.inuse_size = 0;
    }

    // Return a std.mem.Allocator interface for this HeapAllocator.
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

    // Implement the std.mem.Allocator.VTable API.
    pub fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *HeapAllocator = @ptrCast(@alignCast(ctx));
        const prev_flags = self.lock.lock();
        defer self.lock.unlock(prev_flags);

        var prev: ?*HeapBlock = null;
        var search: ?*HeapBlock = self.first;
        while (search) |candidate| {
            if (candidate.state == .free) {
                mergeFreeBlocks(candidate);

                if (tryAllocateFromBlock(
                    self,
                    prev,
                    candidate,
                    len,
                    alignment,
                    ret_addr,
                )) |payload_ptr| {
                    return payload_ptr;
                }
            }
            prev = candidate;
            search = candidate.next;
        }

        return null;
    }

    pub fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *HeapAllocator = @ptrCast(@alignCast(ctx));
        const prev_flags = self.lock.lock();
        defer self.lock.unlock(prev_flags);
        _ = ret_addr;
        const header_addr = @intFromPtr(memory.ptr) - @sizeOf(HeapBlock);
        const block: *HeapBlock = @ptrFromInt(header_addr);

        if (block.state != .in_use) return false;
        if (memory.len != block.payload_active_size) return false;
        if (block.alignment.toByteUnits() != alignment.toByteUnits()) {
            return false;
        }

        // Check if the new size fits within the existing block's space.
        const overhead = block.padding_size + @sizeOf(HeapBlock);
        const required_size =
            std.math.add(usize, overhead, new_len) catch return false;
        if (required_size <= block.max_size) {
            block.payload_active_size = new_len;
            return true;
        }

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

    pub fn free(
        ctx: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        ret_addr: usize,
    ) void {
        _ = alignment;
        _ = ret_addr;
        const self: *HeapAllocator = @ptrCast(@alignCast(ctx));
        const prev_flags = self.lock.lock();
        defer self.lock.unlock(prev_flags);
        const header_addr = @intFromPtr(memory.ptr) - @sizeOf(HeapBlock);
        const victim: *HeapBlock = @ptrFromInt(header_addr);

        if (victim.state != .in_use) return;
        if (memory.len != victim.payload_active_size) return;

        victim.state = .free;
        self.inuse_size -= victim.max_size;
        self.free_size += victim.max_size;
        victim.owner = null;
    }

    fn tryAllocateFromBlock(
        self: *HeapAllocator,
        prev: ?*HeapBlock,
        block: *HeapBlock,
        len: usize,
        alignment: Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        if (len > block.max_size) return null;

        // Read original block fields upfront in case new_header_ptr aliases.
        const old_next = block.next;
        const old_max_size = block.max_size;
        const chunk_start = @intFromPtr(block) - block.padding_size;
        const header_size = @sizeOf(HeapBlock);

        // The payload must start at least header_size after chunk_start.
        const min_payload_ptr = chunk_start + header_size;
        const align_bytes = alignment.toByteUnits();
        const aligned_payload_ptr =
            std.mem.alignForward(usize, min_payload_ptr, align_bytes);

        // The header sits immediately before the aligned payload.
        const new_header_ptr = aligned_payload_ptr - header_size;
        const padding = new_header_ptr - chunk_start;

        const rounded_payload =
            std.mem.alignForward(usize, len, heap_block_size_multiple);
        const required_size = std.math.add(
            usize,
            padding + header_size,
            rounded_payload,
        ) catch return null;

        if (old_max_size < required_size) return null;

        const remainder_size = old_max_size - required_size;
        const can_split =
            remainder_size >= header_size + heap_block_size_multiple;
        const next_block: ?*HeapBlock = if (can_split) blk: {
            const new_free_start = chunk_start + required_size;
            const new_free: *HeapBlock = @ptrFromInt(new_free_start);
            new_free.* = .{
                .next = old_next,
                .state = .free,
                .max_size = remainder_size,
                .payload_active_size = 0,
                .padding_size = 0,
                .alignment = Alignment.fromByteUnits(@sizeOf(usize)),
                .owner = null,
            };
            break :blk new_free;
        } else old_next;

        const final_size = if (can_split) required_size else old_max_size;
        const inuse_block: *HeapBlock = @ptrFromInt(new_header_ptr);
        inuse_block.* = .{
            .next = next_block,
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

    fn mergeFreeBlocks(block: *HeapBlock) void {
        var current = block;
        while (current.next) |next_block| {
            if (next_block.state != .free) break;

            const cur_start = @intFromPtr(current) - current.padding_size;
            const next_start =
                @intFromPtr(next_block) - next_block.padding_size;

            if (cur_start + current.max_size == next_start) {
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
    try testing.expectEqual(
        @as(usize, 0),
        @intFromPtr(mem_align_16) % @alignOf(u128),
    );

    const align_64 = comptime Alignment.fromByteUnits(64);
    const mem_align_64 = try allocator.alignedAlloc(u8, align_64, 100);
    defer allocator.free(@as([]u8, mem_align_64));
    try testing.expectEqual(@as(usize, 0), @intFromPtr(mem_align_64.ptr) % 64);
}

test "heap allocator resize and overflow protection" {
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
    const mem_grown = mem.ptr[0..60];

    success = allocator.resize(@as([]u8, mem_grown), 2048);
    try testing.expect(!success);
    try testing.expect(mem_grown.len == 60);

    // Overflowing resize length must return false without panicking.
    success = allocator.resize(@as([]u8, mem_grown), std.math.maxInt(usize));
    try testing.expect(!success);

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

    const block1: *HeapBlock =
        @ptrCast(@alignCast(mem1.ptr - @sizeOf(HeapBlock)));
    const block2: *HeapBlock =
        @ptrCast(@alignCast(mem2.ptr - @sizeOf(HeapBlock)));

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
