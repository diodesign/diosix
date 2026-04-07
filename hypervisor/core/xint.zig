// High-level exception and interrupt (xint) handling on RISC-V
//
// Copyright (c) 2024, 2025, 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const main = @import("main.zig");
const builtin = @import("builtin");
const debug = @import("debug.zig");
const riscv = @import("riscv.zig");

extern fn hw_xint_init() void;

// initialize hardware-dependent xint handling
pub fn init() void {
    hw_xint_init();
}

// our centralized high-level entry point for handling xints
pub export fn xint_handler(context: *riscv.ThreadContext) void {
    if (builtin.is_test) return;
    const mcause = riscv.readMcause();
    const mepc = riscv.readMepc();
    const mtval = riscv.readMtval();

    debug.printf("Unhandled xint\n", .{});
    debug.printf("context = 0x{x}, cause = 0x{x}, epc = 0x{x}, trap value = 0x{x})\n\n", .{ @intFromPtr(context), mcause, mepc, mtval });
    debug.printf("Halting\n", .{});
    while (true) {}
}
