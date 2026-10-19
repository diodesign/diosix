// Dynamic Host PLIC Driver.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");

pub var base_address: ?usize = null;

pub const CONTEXT_BASE_OFFSET: usize = 0x200000;
pub const CONTEXT_STRIDE: usize = 0x1000;
pub const THRESHOLD_OFFSET: usize = 0x0;
pub const CLAIM_OFFSET: usize = 0x4;

pub fn init(base: usize) void {
    base_address = base;
}

pub fn setPriority(source: u32, priority: u32) void {
    if (builtin.is_test) return;
    if (base_address) |base| {
        const priority_ptr = @as(*volatile u32, @ptrFromInt(base + source * 4));
        priority_ptr.* = priority;
    }
}

pub fn setThreshold(hartid: usize, threshold: u32) void {
    if (builtin.is_test) return;
    if (base_address) |base| {
        const addr = base + CONTEXT_BASE_OFFSET +
            THRESHOLD_OFFSET + hartid * CONTEXT_STRIDE;
        const threshold_ptr = @as(*volatile u32, @ptrFromInt(addr));
        threshold_ptr.* = threshold;
    }
}

pub fn claimInterrupt(hartid: usize) u32 {
    if (builtin.is_test) return 0;
    if (base_address) |base| {
        const addr = base + CONTEXT_BASE_OFFSET +
            CLAIM_OFFSET + hartid * CONTEXT_STRIDE;
        const claim_ptr = @as(*volatile u32, @ptrFromInt(addr));
        return claim_ptr.*;
    }
    return 0;
}

pub fn completeInterrupt(hartid: usize, source: u32) void {
    if (builtin.is_test) return;
    if (base_address) |base| {
        const addr = base + CONTEXT_BASE_OFFSET +
            CLAIM_OFFSET + hartid * CONTEXT_STRIDE;
        const claim_ptr = @as(*volatile u32, @ptrFromInt(addr));
        claim_ptr.* = source;
    }
}

test "plic driver init and test-safe access" {
    init(0x0c000000);
    try std.testing.expectEqual(@as(?usize, 0x0c000000), base_address);
    setPriority(1, 1);
    setThreshold(0, 0);
    try std.testing.expectEqual(@as(u32, 0), claimInterrupt(0));
    completeInterrupt(0, 1);
}
