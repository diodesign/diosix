// Dynamic Host PLIC Driver
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub var base_address: ?usize = null;

pub const CONTEXT_BASE_OFFSET: usize = 0x200000;
pub const CONTEXT_STRIDE: usize = 0x1000;
pub const THRESHOLD_OFFSET: usize = 0x0;
pub const CLAIM_OFFSET: usize = 0x4;

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
        const threshold_ptr = @as(*volatile u32, @ptrFromInt(base + CONTEXT_BASE_OFFSET + THRESHOLD_OFFSET + hartid * CONTEXT_STRIDE));
        threshold_ptr.* = threshold;
    }
}

pub fn claimInterrupt(hartid: usize) u32 {
    if (base_address) |base| {
        const claim_ptr = @as(*volatile u32, @ptrFromInt(base + CONTEXT_BASE_OFFSET + CLAIM_OFFSET + hartid * CONTEXT_STRIDE));
        return claim_ptr.*;
    }
    return 0;
}

pub fn completeInterrupt(hartid: usize, source: u32) void {
    if (base_address) |base| {
        const claim_ptr = @as(*volatile u32, @ptrFromInt(base + CONTEXT_BASE_OFFSET + CLAIM_OFFSET + hartid * CONTEXT_STRIDE));
        claim_ptr.* = source;
    }
}
