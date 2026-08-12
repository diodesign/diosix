// Dynamic Host PLIC Driver
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub var base_address: ?usize = null;

pub fn init(base: usize) void {
    base_address = base;
}

pub fn setPriority(source: u32, priority: u32) void {
    if (base_address) |base| {
        const priority_ptr = @as(*volatile u32, @ptrFromInt(base + source * 4));
        priority_ptr.* = priority;
    }
}

pub fn setThreshold(hartid: usize, threshold: u32) void {
    if (base_address) |base| {
        const threshold_ptr = @as(*volatile u32, @ptrFromInt(base + 0x200000 + hartid * 0x1000));
        threshold_ptr.* = threshold;
    }
}

pub fn claimInterrupt(hartid: usize) u32 {
    if (base_address) |base| {
        const claim_ptr = @as(*volatile u32, @ptrFromInt(base + 0x200004 + hartid * 0x1000));
        return claim_ptr.*;
    }
    return 0;
}

pub fn completeInterrupt(hartid: usize, source: u32) void {
    if (base_address) |base| {
        const claim_ptr = @as(*volatile u32, @ptrFromInt(base + 0x200004 + hartid * 0x1000));
        claim_ptr.* = source;
    }
}
