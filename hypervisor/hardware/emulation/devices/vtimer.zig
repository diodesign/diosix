// Virtual CLINT Timer Device Model for Emulated Guest Timing
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const VirtualTimer = struct {
    mtime: u64 = 0,
    mtimecmp: u64 = ~@as(u64, 0),

    pub fn read(self: *const VirtualTimer, offset: u32) u32 {
        if (offset == 0x4000) return @truncate(self.mtimecmp);
        if (offset == 0x4004) return @truncate(self.mtimecmp >> 32);
        if (offset == 0xbff8) return @truncate(self.mtime);
        if (offset == 0xbffc) return @truncate(self.mtime >> 32);
        return 0;
    }

    pub fn write(self: *VirtualTimer, offset: u32, val: u32) void {
        if (offset == 0x4000) {
            self.mtimecmp = (self.mtimecmp & 0xFFFFFFFF00000000) | val;
        } else if (offset == 0x4004) {
            self.mtimecmp = (self.mtimecmp & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
        }
    }
};
