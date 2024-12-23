// KISS linked-listed-based heap allocator
//
// Not thread safe. It's up to the caller to ensure only one thread uses this allocator at a time.
//
// Block sizes include the header and payload. The payload is the memory the caller can use.
// Block sizes are also rounded up to the nearest multiple of BlockSizeMultiple to reduce fragmentation.
// Searching for free blocks starts from the head each time.
//
// Simplicity and safety is the key here. This allocator is not designed for speed or efficiency.
// The linked-list runs forward only, from head to tail. We're not expecting a lot of allocations per second.
// If the allocator is holding back performance, we'll revist these design decisions.
//
// Copyright (c) 2024 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const debug = @import("debug.zig");

pub const AllocError = error{ NotEnoughFreeSpace, TooFragmented, BadBlockInList, BadBlock };

const BlockSizeMultiple: usize = 64;

// pick some magic numbers that stand out in a hex dump
const BlockState = enum(usize) { Free = 0xdeaddead, InUse = 0xc0ffeeee, _ };

const Block = struct {
    next: ?*Block,
    size: usize,
    state: BlockState,
    // the block's payload follows immediately after this header

    // return a pointer to the block's payload
    pub fn payload(self: *Block) *anyopaque {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(Block));
    }
};

pub const Allocator = struct {
    // there must be at least one block in the list (either in-use or free)
    head: *Block,
    tail: *Block,

    total_size: usize,
    free_size: usize,
    inuse_size: usize,

    // initialize the allocator for an area of contiguous memory
    // base = address of the start of the memory area
    // size = the size of the memory area in bytes
    // returns the initialized allocator
    pub fn init(base: usize, size: usize) Allocator {
        const first_block: *Block = @ptrFromInt(base);
        first_block.next = null;
        first_block.size = size;
        first_block.state = BlockState.Free;

        return Allocator{
            .head = first_block,
            .tail = first_block,
            .total_size = size,
            .free_size = size,
            .inuse_size = 0,
        };
    }

    // for debug purposes
    fn print_heap(self: *Allocator) void {
        debug.printf("{x} free, head {x} -> ", .{ self.free_size, @intFromPtr(self.head) });

        var search: ?*Block = self.head;
        while (search) |b| {
            debug.printf("[ header {x} payload {x} state {} size {x} next {x}] -> ", .{ @intFromPtr(b), @intFromPtr(b.*.payload()), b.*.state, b.*.size, @intFromPtr(b.*.next) });

            search = b.*.next;
        }

        debug.printf("<- tail {x}", .{@intFromPtr(self.tail)});
        debug.printf("\n\n", .{});
    }

    // allocate a block of memory
    // size = the size of the block in bytes
    // returns a pointer to the block's payload, or error if the allocation failed
    pub fn create(self: *Allocator, size: usize) AllocError!*anyopaque {
        // don't forget to include the header in the requested size
        const full_size = (size + @sizeOf(Block));

        // round up the requested size to the nearest multiple of BlockSizeMultiple
        // so that we can avoid fragmentation. The hypervisor is mainly allocating
        // for a small set of structures, not dynamically allocating a diverse range of blocks.
        const rounded_up_size: usize = (full_size + BlockSizeMultiple - 1) & ~(BlockSizeMultiple - 1);

        // determine first if we even have enough capacity in the pool
        if (self.free_size < rounded_up_size) {
            return AllocError.NotEnoughFreeSpace;
        }

        // search from the head for a free block large enough to hold the requested block
        var search: ?*Block = self.head;
        while (search) |candidate| {
            // integrity check the list
            switch (candidate.*.state) {
                .Free => {},
                .InUse => {},
                else => return AllocError.BadBlockInList,
            }

            // if the candidate is the exact size desired then just flip it to in-use and return its payload pointer
            if ((candidate.*.state == BlockState.Free) and (candidate.*.size == rounded_up_size)) {
                candidate.*.state = BlockState.InUse;

                // update accounting
                self.inuse_size += rounded_up_size;
                self.free_size -= rounded_up_size;

                return candidate.payload();
            }

            if ((candidate.*.state == BlockState.Free) and (candidate.*.size > rounded_up_size)) {
                // cut the end off the candidate block to accommodate the new in-use block
                // and add the in-use block to the tail of the list
                candidate.*.size -= rounded_up_size;
                const inuse_block_base: usize = @intFromPtr(candidate) + candidate.*.size;
                const inuse_block: *Block = @ptrFromInt(inuse_block_base);
                inuse_block.*.size = rounded_up_size;
                inuse_block.*.state = BlockState.InUse;
                inuse_block.*.next = null;

                // update the tail of the list to insert the new in-use block at the end
                const last_block = self.tail;
                last_block.*.next = inuse_block;
                self.tail = inuse_block;

                // update accounting
                self.inuse_size += rounded_up_size;
                self.free_size -= rounded_up_size;

                return inuse_block.payload();
            }

            // try the next block
            search = candidate.*.next;
        }

        return AllocError.TooFragmented;
    }

    // free the given block, as identified from its payload address
    // returns an error if something went wrong
    pub fn destroy(self: *Allocator, payload: *anyopaque) AllocError!void {
        const block_base: usize = @intFromPtr(payload);
        const block: *Block = @ptrFromInt(block_base - @sizeOf(Block));

        // make sure this block is legit
        if (block.*.state != BlockState.InUse) {
            return AllocError.BadBlock;
        }

        // flip it to free and update accounting
        block.*.state = BlockState.Free;
        self.inuse_size -= block.*.size;
        self.free_size += block.*.size;
    }
};
