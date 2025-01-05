// Deliberately simple linked-listed-based heap allocator
//
// Not thread safe. It's up to the caller to ensure only one thread uses this allocator at a time.
//
// Block sizes include the header and payload. The payload is the memory the caller can use.
// Block sizes are also rounded up to the nearest multiple of BlockSizeMultiple to reduce fragmentation.
// Free blocks are merged automatically. All allocations are aligned to the system's pointer size.
//
// Simplicity and safety is the key here. Given the nature of the hypervisor's job,
// it's not expected to perform a lot of allocations in a time-critical manner.
// If the allocator is holding back performance, we'll revist these design decisions.
//
// Copyright (c) 2024, 2025 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

pub const AllocError = error{ NotEnoughFreeSpace, TooFragmented, BadBlockInList, BadBlock };

const BlockSizeMultiple: usize = 64;

// pick some magic numbers that stand out in a hex dump
const BlockState = enum(usize) { Free = 0xdeaddead, InUse = 0xc0ffeeee, _ };

const Block = struct {
    next: ?*Block,
    size: usize,
    state: BlockState,
    // the block's payload follows immediately after this header
    // starting on a usize byte boundary

    // return a pointer to the block's payload, using T to define the pointer type
    pub fn payload(self: *Block, comptime T: type) T {
        const p: *usize = @ptrFromInt(@intFromPtr(self) + @sizeOf(Block));
        return @as(T, @ptrCast(p));
    }
};

pub const Allocator = struct {
    // there must be at least one block in the list (either in-use or free)
    first: *Block,

    total_size: usize,
    free_size: usize,
    inuse_size: usize,

    // initialize the allocator for an area of contiguous memory
    // base = address of the start of the memory area
    // size = the size of the memory area in bytes
    // returns the initialized allocator as a value
    pub fn init(base: usize, size: usize) Allocator {
        const first_block: *Block = @ptrFromInt(base);
        first_block.next = null;
        first_block.size = size;
        first_block.state = BlockState.Free;

        return Allocator{
            .first = first_block,
            .total_size = size,
            .free_size = size,
            .inuse_size = 0,
        };
    }

    // allocate a block of memory
    // T = type of pointer to return, pointing to requesting block
    // size = the size of the block in bytes
    // returns a pointer to the block's payload, or error if the allocation failed
    pub fn create(self: *Allocator, comptime T: type, size: usize) !T {
        // don't forget to include the header in the requested size
        const full_size = (size + @sizeOf(Block));

        // round up the requested size to the nearest multiple of BlockSizeMultiple
        // so that we can avoid fragmentation. The hypervisor is mainly allocating
        // for a small set of structures, not dynamically allocating a diverse range of blocks.
        const rounded_up_size: usize = (full_size + BlockSizeMultiple - 1) & ~(BlockSizeMultiple - 1);

        // determine first if we even have enough capacity in the pool
        if (self.free_size < rounded_up_size) return AllocError.NotEnoughFreeSpace;

        // search for either a free block large enough that can hold this allocation,
        // or any free blocks to merge togther to hopefully hold the request
        var search: ?*Block = self.first;
        while (search) |candidate| {
            switch (candidate.state) {
                // skip blocks that are in-use
                .InUse => search = candidate.next,

                .Free => {
                    // if the candidate free block is the exact size requested
                    // then just flip it to in-use and return its payload pointer
                    if (candidate.size == rounded_up_size) {
                        candidate.state = BlockState.InUse;

                        // update accounting
                        self.inuse_size += rounded_up_size;
                        self.free_size -= rounded_up_size;

                        return candidate.payload(T);
                    }

                    // if the free block is large enough to accoommodate this requested allocation,
                    // then use the end of the free block to create a new in-use block for the request
                    if (candidate.size > rounded_up_size) {
                        candidate.size -= rounded_up_size;
                        const new_block: *Block = @ptrFromInt(@intFromPtr(candidate) + candidate.size);
                        new_block.size = rounded_up_size;
                        new_block.state = BlockState.InUse;

                        // insert the in-use block between the free block and the next in the chain
                        new_block.next = candidate.next;
                        candidate.next = new_block;

                        // update accounting
                        self.inuse_size += rounded_up_size;
                        self.free_size -= rounded_up_size;

                        return new_block.payload(T);
                    }

                    // rather than defer merging, proactively merge now
                    var merge: ?*Block = candidate.next;
                    while (merge) |victim| {
                        switch (victim.state) {
                            // we can't merge in-use blocks, so stop the merge attempt here
                            .InUse => break,

                            // check if two free blocks are next to each other in memory,
                            // and if so, absorb the second into the first
                            .Free => {
                                if ((@intFromPtr(candidate) + candidate.size) == @intFromPtr(victim)) {
                                    candidate.size += victim.size;
                                    candidate.next = victim.next;
                                }
                            },

                            // detect a broken linked list
                            else => return AllocError.BadBlockInList,
                        }

                        // look for more adjacent blocks to absorb
                        merge = victim.next;
                    }

                    // if the candidate is now large enough to fit the requested block, then repeat
                    // the above allocation process. if not, move on to the next candidate
                    if (candidate.size < rounded_up_size) {
                        search = candidate.next;
                    }
                },

                // detect a broken linked list
                else => return AllocError.BadBlockInList,
            }
        }

        // at this point, the heap has enough free space but is too fragmented
        return AllocError.TooFragmented;
    }

    // free the given block, as identified from its payload address
    // returns an error if something went wrong
    pub fn destroy(self: *Allocator, payload: *anyopaque) !void {
        const victim_base: usize = @intFromPtr(payload);
        const victim: *Block = @ptrFromInt(victim_base - @sizeOf(Block));

        // make sure this victim heap block is legit, or error out to the caller
        if (victim.state != BlockState.InUse) {
            return AllocError.BadBlock;
        }

        // flip it to free and update accounting
        victim.state = BlockState.Free;
        self.inuse_size -= victim.size;
        self.free_size += victim.size;
    }
};
