// diosix high-level exception and interrupt (xint) handling
//
// Copyright (c) 2024 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const debug = @import("debug.zig");

extern fn hw_xint_init() void;

// initialize hardware-dependent xint handling
pub fn init() void {
    hw_xint_init();

    debug.printf("xint: initialized\n", .{});
}

// our centralized high-level entry point for handling xints
pub export fn xint_handler() void {
    debug.printf("xint_handler: unhandled exception or interrupt\n", .{});
    while (true) {}
}
