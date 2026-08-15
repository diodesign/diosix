// Virtual CLINT Timer Device Model for Emulated Guest Timing
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

const vcpu_mod = @import("../vcpu.zig");

pub const MAX_HARTS: usize = 4;

pub const VirtualTimer = struct {
    mtime: u64 = 0,
    mtimecmp: [MAX_HARTS]u64 = .{ ~@as(u64, 0), ~@as(u64, 0), ~@as(u64, 0), ~@as(u64, 0) },

    pub fn read(self: *const VirtualTimer, offset: u32) u32 {
        const time = vcpu_mod.VCpu.readGuestTime();
        if (offset >= 0x4000 and offset < 0x4000 + (MAX_HARTS * 8)) {
            const hart = (offset - 0x4000) / 8;
            const is_high = (offset & 4) != 0;
            if (is_high) {
                return @truncate(self.mtimecmp[hart] >> 32);
            } else {
                return @truncate(self.mtimecmp[hart]);
            }
        }
        if (offset == 0xbff8) return @truncate(time);
        if (offset == 0xbffc) return @truncate(time >> 32);
        return 0;
    }

    pub fn write(self: *VirtualTimer, offset: u32, val: u32) void {
        if (offset >= 0x4000 and offset < 0x4000 + (MAX_HARTS * 8)) {
            const hart = (offset - 0x4000) / 8;
            const is_high = (offset & 4) != 0;
            if (is_high) {
                self.mtimecmp[hart] = (self.mtimecmp[hart] & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
            } else {
                self.mtimecmp[hart] = (self.mtimecmp[hart] & 0xFFFFFFFF00000000) | val;
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
