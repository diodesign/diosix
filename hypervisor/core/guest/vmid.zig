// Hypervisor-internal Guest ID & Hardware VMID Bitmap Allocator.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const atomic = @import("../atomic.zig");
const debug = @import("../debug.zig");
const sbi = @import("interface").sbi;

pub const max_vmids: u16 = 4096;
pub const BITS_PER_WORD: usize = @bitSizeOf(u64);
pub const VMID_BITMAP_WORDS: usize = max_vmids / BITS_PER_WORD;

const GuestManagerState = struct {
    vmid_bitmap: [VMID_BITMAP_WORDS]u64 = blk: {
        var bm: [VMID_BITMAP_WORDS]u64 = @splat(0);
        // VMID 0 is permanently reserved in RISC-V hgatp.
        bm[0] = 1;
        break :blk bm;
    },
    guest_id_next: usize = sbi.CID_SELF,
};

var guest_manager = atomic.LockPayload(GuestManagerState).init(
    "Global guest manager state",
    .{},
);

pub fn allocGuestId() usize {
    const guard = guest_manager.acquire();
    defer guard.release();
    const state = guard.get();
    const next = state.guest_id_next;
    state.guest_id_next =
        std.math.add(usize, next, 1) catch std.math.maxInt(usize);
    return next;
}

pub fn peekLastGuestId() usize {
    const guard = guest_manager.acquire();
    defer guard.release();
    return guard.get().guest_id_next -| 1;
}

pub fn resetGuestManagerForTest() void {
    const guard = guest_manager.acquire();
    defer guard.release();
    const state = guard.get();
    state.guest_id_next = sbi.CID_SELF;
    state.vmid_bitmap = @splat(0);
    state.vmid_bitmap[0] = 1;
}

pub fn isVmidAllocated(id: u16) bool {
    if (id >= max_vmids) return false;
    const guard = guest_manager.acquire();
    defer guard.release();
    const state = guard.get();
    const wi = id / BITS_PER_WORD;
    const bit: u6 = @intCast(id % BITS_PER_WORD);
    return (state.vmid_bitmap[wi] & (@as(u64, 1) << bit)) != 0;
}

pub fn allocVmid() !u16 {
    const guard = guest_manager.acquire();
    defer guard.release();
    const state = guard.get();

    for (&state.vmid_bitmap, 0..) |*word, wi| {
        if (word.* == std.math.maxInt(u64)) continue;
        const free_bit: u6 = @intCast(@ctz(~word.*));
        const vmid: u16 = @intCast(wi * BITS_PER_WORD + free_bit);
        if (vmid >= max_vmids) break;
        word.* |= @as(u64, 1) << free_bit;
        return vmid;
    }
    debug.printf("VMID: All {} VMIDs exhausted\n", .{max_vmids});
    return error.OutOfMemory;
}

pub fn freeVmid(id: u16) void {
    const guard = guest_manager.acquire();
    defer guard.release();
    const state = guard.get();
    if (id == 0 or id >= max_vmids) return;
    const wi = id / BITS_PER_WORD;
    const bit: u6 = @intCast(id % BITS_PER_WORD);
    state.vmid_bitmap[wi] &= ~(@as(u64, 1) << bit);
}

test "guest ID and VMID allocator bitmap invariants" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    resetGuestManagerForTest();
    try testing.expect(isVmidAllocated(0));
    const v1 = try allocVmid();
    try testing.expectEqual(@as(u16, 1), v1);
    try testing.expect(isVmidAllocated(v1));
    freeVmid(v1);
    try testing.expect(!isVmidAllocated(v1));
}
