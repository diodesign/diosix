// Dynamic Host CLINT Driver.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const riscv = @import("../cpu/riscv64/mod.zig");

pub var base_address: ?usize = null;

pub const DEFAULT_BASE: usize = 0x02000000;
pub const MTIMECMP_BASE_OFFSET: usize = 0x4000;
pub const MTIMECMP_BASE: usize = MTIMECMP_BASE_OFFSET;
pub const MTIME_OFFSET: usize = 0xbff8;
pub const MSIP_BASE_OFFSET: usize = 0x0000;

pub fn init(base: usize) void {
    base_address = base;
}

pub fn msip(hart: usize) ?*volatile u32 {
    const base = base_address orelse riscv.clint_base orelse return null;
    const offset = std.math.mul(usize, @sizeOf(u32), hart) catch return null;
    const addr = std.math.add(usize, base, offset) catch return null;
    return @ptrFromInt(addr);
}

pub fn setTimer(hartid: usize, stime: u64) void {
    if (builtin.is_test) return;
    const base = base_address orelse riscv.clint_base orelse DEFAULT_BASE;
    const hart_off = std.math.mul(usize, @sizeOf(u64), hartid) catch return;
    const mtimecmp_base = std.math.add(
        usize,
        base,
        MTIMECMP_BASE_OFFSET,
    ) catch return;
    const addr = std.math.add(usize, mtimecmp_base, hart_off) catch return;
    const mtimecmp_ptr = @as(*volatile u64, @ptrFromInt(addr));
    mtimecmp_ptr.* = stime;
}

pub fn sendIpi(hartid: usize) void {
    if (builtin.is_test) return;
    if (msip(hartid)) |msip_ptr| {
        msip_ptr.* = 1;
    }
}

pub fn clearIpi(hartid: usize) void {
    if (builtin.is_test) return;
    if (msip(hartid)) |msip_ptr| {
        msip_ptr.* = 0;
    }
}

test "clint driver init and test-safe access" {
    std.testing.refAllDecls(@This());
    init(0x02000000);
    defer base_address = null;
    try std.testing.expectEqual(@as(?usize, 0x02000000), base_address);
    try std.testing.expect(msip(0) != null);
    setTimer(0, 1000);
    sendIpi(0);
    clearIpi(0);
}
