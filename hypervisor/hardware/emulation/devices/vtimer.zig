// Virtual CLINT Timer Device Model for Emulated Guest Timing
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const vcpu_mod = @import("../vcpu.zig");

pub const MAX_HARTS: usize = 4;

pub const CLINT_MTIMECMP_BASE: u32 = 0x4000;
pub const CLINT_MTIME_LOW: u32 = 0xbff8;
pub const CLINT_MTIME_HIGH: u32 = 0xbffc;

pub const BYTES_PER_MTIMECMP: u32 = 8;
pub const HIGH_WORD_SHIFT: u6 = 32;
pub const LOW_WORD_MASK: u64 = 0x00000000FFFFFFFF;
pub const HIGH_WORD_MASK: u64 = 0xFFFFFFFF00000000;

pub const VirtualTimer = struct {
    mtime: u64 = 0,
    mtimecmp: [MAX_HARTS]u64 = .{ ~@as(u64, 0), ~@as(u64, 0), ~@as(u64, 0), ~@as(u64, 0) },

    pub fn read(self: *const VirtualTimer, offset: u32) u32 {
        const time = vcpu_mod.VCpu.readGuestTime();
        if (offset >= CLINT_MTIMECMP_BASE and offset < CLINT_MTIMECMP_BASE + (MAX_HARTS * BYTES_PER_MTIMECMP)) {
            const hart = (offset - CLINT_MTIMECMP_BASE) / BYTES_PER_MTIMECMP;
            const is_high = (offset & @sizeOf(u32)) != 0;
            if (is_high) {
                return @truncate(self.mtimecmp[hart] >> HIGH_WORD_SHIFT);
            } else {
                return @truncate(self.mtimecmp[hart]);
            }
        }
        if (offset == CLINT_MTIME_LOW) return @truncate(time);
        if (offset == CLINT_MTIME_HIGH) return @truncate(time >> HIGH_WORD_SHIFT);
        return 0;
    }

    pub fn write(self: *VirtualTimer, offset: u32, val: u32) void {
        if (offset >= CLINT_MTIMECMP_BASE and offset < CLINT_MTIMECMP_BASE + (MAX_HARTS * BYTES_PER_MTIMECMP)) {
            const hart = (offset - CLINT_MTIMECMP_BASE) / BYTES_PER_MTIMECMP;
            const is_high = (offset & @sizeOf(u32)) != 0;
            if (is_high) {
                self.mtimecmp[hart] = (self.mtimecmp[hart] & LOW_WORD_MASK) | (@as(u64, val) << HIGH_WORD_SHIFT);
            } else {
                self.mtimecmp[hart] = (self.mtimecmp[hart] & HIGH_WORD_MASK) | val;
            }
        }
    }

    pub fn getEarliestDeadline(self: *const VirtualTimer) u64 {
        var min: u64 = ~@as(u64, 0);
        for (self.mtimecmp) |deadline| {
            if (deadline < min) min = deadline;
        }
        return min;
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
    try testing.expectEqual(@as(u64, 0x0000ABCD12345678), timer.mtimecmp[0]);

    // Write Hart 1 mtimecmp (offset 0x4008, 0x400C)
    timer.write(CLINT_MTIMECMP_BASE + 8, 0x00000100);
    timer.write(CLINT_MTIMECMP_BASE + 12, 0x00000000);

    // Earliest deadline should now be Hart 1 (0x100 < 0x0000ABCD12345678)
    try testing.expectEqual(@as(u64, 0x100), timer.getEarliestDeadline());
}
