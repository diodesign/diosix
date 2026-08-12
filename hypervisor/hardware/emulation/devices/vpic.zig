// Virtual PLIC Interrupt Controller Model for Emulated Guests
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const VirtualPlic = struct {
    priority: [32]u32 = std.mem.zeroes([32]u32),
    pending: u32 = 0,
    enable: u32 = 0,
    threshold: u32 = 0,
    claim: u32 = 0,

    pub fn read(self: *const VirtualPlic, offset: u32) u32 {
        if (offset < 0x80) return self.priority[@truncate(offset >> 2)];
        if (offset == 0x1000) return self.pending;
        if (offset == 0x2000) return self.enable;
        if (offset == 0x200000) return self.threshold;
        if (offset == 0x200004) return self.claim;
        return 0;
    }

    pub fn write(self: *VirtualPlic, offset: u32, val: u32) void {
        if (offset < 0x80) {
            self.priority[@truncate(offset >> 2)] = val;
        } else if (offset == 0x2000) {
            self.enable = val;
        } else if (offset == 0x200000) {
            self.threshold = val;
        } else if (offset == 0x200004) {
            self.claim = val;
        }
    }
};
