// High-level exception and interrupt (xint) handling on RISC-V
//
// Copyright (c) 2024 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const main = @import("main.zig");
const debug = @import("debug.zig");
const riscv = @import("riscv.zig");

extern fn hw_xint_init() void;

// initialize hardware-dependent xint handling
pub fn init() void {
    hw_xint_init();
}

// our centralized high-level entry point for handling xints
pub export fn xint_handler(context: *riscv.ThreadContext) void {
    const mcause = riscv.read_mcause();
    const mepc = riscv.read_mepc();
    const mtval = riscv.read_mtval();

    debug.printf("\n\nxint_handler: unhandled exception or interrupt (context = 0x{x}, cause = 0x{x}, epc = 0x{x}, trap value = 0x{x})\n\n", .{ context, mcause, mepc, mtval });
    while (true) {}
}
