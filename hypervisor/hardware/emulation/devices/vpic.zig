// Virtual PLIC Interrupt Controller Model for Emulated Guests
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const MAX_CONTEXTS: usize = 8;

pub const VirtualPlic = struct {
    priority: [32]u32 = std.mem.zeroes([32]u32),
    pending: u32 = 0,
    enable: [MAX_CONTEXTS]u32 = std.mem.zeroes([MAX_CONTEXTS]u32),
    threshold: [MAX_CONTEXTS]u32 = std.mem.zeroes([MAX_CONTEXTS]u32),
    claim: [MAX_CONTEXTS]u32 = std.mem.zeroes([MAX_CONTEXTS]u32),

    pub fn read(self: *const VirtualPlic, offset: u32) u32 {
        if (offset < 0x80) return self.priority[@truncate(offset >> 2)];
        if (offset == 0x1000) return self.pending;
        if (offset >= 0x2000 and offset < 0x2000 + (MAX_CONTEXTS * 0x80)) {
            const ctx = (offset - 0x2000) / 0x80;
            return self.enable[ctx];
        }
        if (offset >= 0x200000 and offset < 0x200000 + (MAX_CONTEXTS * 0x1000)) {
            const ctx = (offset - 0x200000) / 0x1000;
            const reg = offset & 0xFFF;
            if (reg == 0) return self.threshold[ctx];
            if (reg == 4) return self.claim[ctx];
        }
        return 0;
    }

    pub fn write(self: *VirtualPlic, offset: u32, val: u32) void {
        if (offset < 0x80) {
            self.priority[@truncate(offset >> 2)] = val;
        } else if (offset >= 0x2000 and offset < 0x2000 + (MAX_CONTEXTS * 0x80)) {
            const ctx = (offset - 0x2000) / 0x80;
            self.enable[ctx] = val;
        } else if (offset >= 0x200000 and offset < 0x200000 + (MAX_CONTEXTS * 0x1000)) {
            const ctx = (offset - 0x200000) / 0x1000;
            const reg = offset & 0xFFF;
            if (reg == 0) {
                self.threshold[ctx] = val;
            } else if (reg == 4) {
                self.claim[ctx] = val;
            }
        }
    }
};
