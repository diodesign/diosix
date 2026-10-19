// Dynamic Host CLINT Driver.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");

pub var base_address: ?usize = null;

pub const MTIMECMP_BASE_OFFSET: usize = 0x4000;
pub const MSIP_BASE_OFFSET: usize = 0x0000;

pub fn init(base: usize) void {
    base_address = base;
}

pub fn setTimer(hartid: usize, stime: u64) void {
    if (builtin.is_test) return;
    if (base_address) |base| {
        const addr = base + MTIMECMP_BASE_OFFSET + 8 * hartid;
        const mtimecmp_ptr = @as(*volatile u64, @ptrFromInt(addr));
        mtimecmp_ptr.* = stime;
    }
}

pub fn sendIpi(hartid: usize) void {
    if (builtin.is_test) return;
    if (base_address) |base| {
        const addr = base + MSIP_BASE_OFFSET + 4 * hartid;
        const msip_ptr = @as(*volatile u32, @ptrFromInt(addr));
        msip_ptr.* = 1;
    }
}

pub fn clearIpi(hartid: usize) void {
    if (builtin.is_test) return;
    if (base_address) |base| {
        const addr = base + MSIP_BASE_OFFSET + 4 * hartid;
        const msip_ptr = @as(*volatile u32, @ptrFromInt(addr));
        msip_ptr.* = 0;
    }
}

test "clint driver init and test-safe access" {
    init(0x02000000);
    try std.testing.expectEqual(@as(?usize, 0x02000000), base_address);
    setTimer(0, 1000);
    sendIpi(0);
    clearIpi(0);
}
