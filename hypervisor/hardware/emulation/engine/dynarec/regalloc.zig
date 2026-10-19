// Static 1-to-1 Register Pinning Rules for Diosix Dynamic Recompiler.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

/// Static 1-to-1 register mapping rules (RV32 guest GPR -> RV64 host GPR).
pub fn mapGuestGprToHost(guest_reg: u5) u5 {
    return guest_reg; // 1-to-1 direct mapping x0-x31.
}

test "mapGuestGprToHost 1-to-1 mapping" {
    for (0..32) |i| {
        const reg: u5 = @intCast(i);
        try std.testing.expectEqual(reg, mapGuestGprToHost(reg));
    }
    std.testing.refAllDecls(@This());
}
