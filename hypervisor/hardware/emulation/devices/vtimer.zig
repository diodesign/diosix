// Virtual CLINT Timer Device Model for Emulated Guest Timing
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const vcpu_mod = @import("../vcpu.zig");

pub const STATIC_HARTS: usize = 32;
pub const DYNAMIC_HASH_BUCKETS: usize = 32;
pub const MAX_SYSTEM_HARTS: usize = 4096;
pub const MAX_HARTS: usize = MAX_SYSTEM_HARTS;

pub const CLINT_MTIMECMP_BASE: u32 = 0x4000;
pub const CLINT_MTIME_LOW: u32 = 0xbff8;
pub const CLINT_MTIME_HIGH: u32 = 0xbffc;

pub const BYTES_PER_MTIMECMP: u32 = 8;
pub const HIGH_WORD_SHIFT: u6 = 32;
pub const LOW_WORD_MASK: u64 = 0x00000000FFFFFFFF;
pub const HIGH_WORD_MASK: u64 = 0xFFFFFFFF00000000;

pub const HartTimerNode = struct {
    hart: usize,
    mtimecmp: u64 = ~@as(u64, 0),
    next: ?*HartTimerNode = null,
};

pub const VirtualTimer = struct {
    mtime: u64 = 0,
    // Column 1: Static fast-path for harts 0..31 (wait-free, O(1), zero allocation)
    static_mtimecmp: [STATIC_HARTS]u64 = @splat(~@as(u64, 0)),
    // Column 2: Dynamic hash buckets for harts >= 32 (keyed by hart % 32)
    dynamic_buckets: [DYNAMIC_HASH_BUCKETS]?*HartTimerNode = @splat(null),
    // Dynamic node pool for standalone execution and up to 128 dynamic harts (160 total harts)
    dynamic_pool: [128]HartTimerNode = @splat(.{ .hart = 0, .mtimecmp = ~@as(u64, 0), .next = null }),
    pool_count: usize = 0,
    lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn getMtimecmp(self: *VirtualTimer, hart: usize) u64 {
        if (hart < STATIC_HARTS) {
            return self.static_mtimecmp[hart];
        }
        while (self.lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer self.lock.store(false, .release);

        const bucket = hart % DYNAMIC_HASH_BUCKETS;
        var curr = self.dynamic_buckets[bucket];
        while (curr) |node| {
            if (node.hart == hart) return node.mtimecmp;
            curr = node.next;
        }
        return ~@as(u64, 0);
    }

    pub fn getMtimecmpConst(self: *const VirtualTimer, hart: usize) u64 {
        if (hart < STATIC_HARTS) {
            return self.static_mtimecmp[hart];
        }
        const bucket = hart % DYNAMIC_HASH_BUCKETS;
        var curr = self.dynamic_buckets[bucket];
        while (curr) |node| {
            if (node.hart == hart) return node.mtimecmp;
            curr = node.next;
        }
        return ~@as(u64, 0);
    }

    pub fn setMtimecmp(self: *VirtualTimer, hart: usize, val: u64) void {
        if (hart < STATIC_HARTS) {
            self.static_mtimecmp[hart] = val;
            return;
        }
        while (self.lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer self.lock.store(false, .release);

        const bucket = hart % DYNAMIC_HASH_BUCKETS;
        var curr = self.dynamic_buckets[bucket];
        while (curr) |node| {
            if (node.hart == hart) {
                node.mtimecmp = val;
                return;
            }
            curr = node.next;
        }
        // Allocate node from embedded pool
        if (self.pool_count < self.dynamic_pool.len) {
            const node = &self.dynamic_pool[self.pool_count];
            self.pool_count += 1;
            node.* = .{
                .hart = hart,
                .mtimecmp = val,
                .next = self.dynamic_buckets[bucket],
            };
            self.dynamic_buckets[bucket] = node;
        }
    }

    pub fn read(self: *VirtualTimer, offset: u32) u32 {
        if ((offset % 4) != 0) return 0;
        const time = vcpu_mod.VCpu.readGuestTime();
        if (offset >= CLINT_MTIMECMP_BASE and offset < CLINT_MTIME_LOW) {
            const hart = (offset - CLINT_MTIMECMP_BASE) / BYTES_PER_MTIMECMP;
            const is_high = (offset & @sizeOf(u32)) != 0;
            const cmp = self.getMtimecmp(hart);
            if (is_high) {
                return @truncate(cmp >> HIGH_WORD_SHIFT);
            } else {
                return @truncate(cmp);
            }
        }
        if (offset == CLINT_MTIME_LOW) return @truncate(time);
        if (offset == CLINT_MTIME_HIGH) return @truncate(time >> HIGH_WORD_SHIFT);
        return 0;
    }

    pub fn write(self: *VirtualTimer, offset: u32, val: u32) void {
        if ((offset % 4) != 0) return;
        if (offset >= CLINT_MTIMECMP_BASE and offset < CLINT_MTIME_LOW) {
            const hart = (offset - CLINT_MTIMECMP_BASE) / BYTES_PER_MTIMECMP;
            const is_high = (offset & @sizeOf(u32)) != 0;
            const cur = self.getMtimecmp(hart);
            const new_val = if (is_high)
                (cur & LOW_WORD_MASK) | (@as(u64, val) << HIGH_WORD_SHIFT)
            else
                (cur & HIGH_WORD_MASK) | val;
            self.setMtimecmp(hart, new_val);
        }
    }

    pub fn getEarliestDeadline(self: *VirtualTimer) u64 {
        var min: u64 = ~@as(u64, 0);
        for (self.static_mtimecmp) |deadline| {
            if (deadline < min) min = deadline;
        }
        while (self.lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer self.lock.store(false, .release);

        for (self.dynamic_buckets) |head| {
            var curr = head;
            while (curr) |node| {
                if (node.mtimecmp < min) min = node.mtimecmp;
                curr = node.next;
            }
        }
        return min;
    }

    pub fn reset(self: *VirtualTimer) void {
        while (self.lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer self.lock.store(false, .release);

        self.mtime = 0;
        self.static_mtimecmp = @splat(~@as(u64, 0));
        self.dynamic_buckets = @splat(null);
        self.dynamic_pool = @splat(.{ .hart = 0, .mtimecmp = ~@as(u64, 0), .next = null });
        self.pool_count = 0;
    }
};

test "CLINT virtual timer mtimecmp read write and earliest deadline" {
    const testing = std.testing;

    var timer = VirtualTimer{};

    // Initial state: all deadlines are max u64
    try testing.expectEqual(~@as(u64, 0), timer.getEarliestDeadline());

    // Write Hart 0 mtimecmp low word (offset 0x4000) and high word (offset 0x4004)
    timer.write(CLINT_MTIMECMP_BASE, 0x12345678);
    timer.write(CLINT_MTIMECMP_BASE + 4, 0x0000ABCD);

    try testing.expectEqual(@as(u32, 0x12345678), timer.read(CLINT_MTIMECMP_BASE));
    try testing.expectEqual(@as(u32, 0x0000ABCD), timer.read(CLINT_MTIMECMP_BASE + 4));
    try testing.expectEqual(@as(u64, 0x0000ABCD12345678), timer.getMtimecmp(0));

    // Write Hart 1 mtimecmp (offset 0x4008, 0x400C)
    timer.write(CLINT_MTIMECMP_BASE + 8, 0x00000100);
    timer.write(CLINT_MTIMECMP_BASE + 12, 0x00000000);

    // Earliest deadline should now be Hart 1 (0x100 < 0x0000ABCD12345678)
    try testing.expectEqual(@as(u64, 0x100), timer.getEarliestDeadline());

    // Test Hart 15 (high static hart ID)
    const hart15_base = CLINT_MTIMECMP_BASE + 15 * BYTES_PER_MTIMECMP;
    timer.write(hart15_base, 0x00000050);
    timer.write(hart15_base + 4, 0x00000000);
    try testing.expectEqual(@as(u32, 0x00000050), timer.read(hart15_base));
    try testing.expectEqual(@as(u32, 0x00000000), timer.read(hart15_base + 4));
    try testing.expectEqual(@as(u64, 0x50), timer.getMtimecmp(15));
    try testing.expectEqual(@as(u64, 0x50), timer.getEarliestDeadline());

    // Test Dynamic Hart 32 (Column 2 hash bucket)
    const hart32_base = CLINT_MTIMECMP_BASE + 32 * BYTES_PER_MTIMECMP;
    timer.write(hart32_base, 0x00000030);
    timer.write(hart32_base + 4, 0x00000000);
    try testing.expectEqual(@as(u32, 0x00000030), timer.read(hart32_base));
    try testing.expectEqual(@as(u32, 0x00000000), timer.read(hart32_base + 4));
    try testing.expectEqual(@as(u64, 0x30), timer.getMtimecmp(32));
    try testing.expectEqual(@as(u64, 0x30), timer.getEarliestDeadline());

    // Test Dynamic Hart 64 (Collides with 32 in bucket 0)
    const hart64_base = CLINT_MTIMECMP_BASE + 64 * BYTES_PER_MTIMECMP;
    timer.write(hart64_base, 0x00000010);
    timer.write(hart64_base + 4, 0x00000000);
    try testing.expectEqual(@as(u32, 0x00000010), timer.read(hart64_base));
    try testing.expectEqual(@as(u64, 0x10), timer.getMtimecmp(64));
    // Now earliest deadline should be Hart 64
    try testing.expectEqual(@as(u64, 0x10), timer.getEarliestDeadline());

    // Test rejection of unaligned register access
    try testing.expectEqual(@as(u32, 0), timer.read(CLINT_MTIMECMP_BASE + 1));
    timer.write(CLINT_MTIMECMP_BASE + 1, 0x99999999);
    try testing.expectEqual(@as(u32, 0x12345678), timer.read(CLINT_MTIMECMP_BASE)); // Clobber prevented
}

