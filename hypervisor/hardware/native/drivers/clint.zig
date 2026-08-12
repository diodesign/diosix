// Dynamic Host CLINT Driver
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub var base_address: ?usize = null;

pub fn init(base: usize) void {
    base_address = base;
}

pub fn setTimer(hartid: usize, stime: u64) void {
    if (base_address) |base| {
        const mtimecmp_ptr = @as(*volatile u64, @ptrFromInt(base + 0x4000 + 8 * hartid));
        mtimecmp_ptr.* = stime;
    }
}

pub fn sendIpi(hartid: usize) void {
    if (base_address) |base| {
        const msip_ptr = @as(*volatile u32, @ptrFromInt(base + 4 * hartid));
        msip_ptr.* = 1;
    }
}

pub fn clearIpi(hartid: usize) void {
    if (base_address) |base| {
        const msip_ptr = @as(*volatile u32, @ptrFromInt(base + 4 * hartid));
        msip_ptr.* = 0;
    }
}
