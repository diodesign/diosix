// Device driver framework for the universal hypervisor binary.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const config = @import("config");
const debug = @import("debug.zig");
const riscv = @import("../hardware/native/cpu/riscv64/mod.zig");

const CLINT_MTIMECMP_OFFSET: usize = 0x4000;
const FINISHER_PASS: u32 = 0x5555;
const FINISHER_RESET: u32 = 0x7777;

// Driver interfaces.
pub const ConsoleDriver = struct {
    name: []const u8,
    putchar: *const fn (c: u8) void,
    getchar: *const fn () i16,
};

pub const TimerDriver = struct {
    name: []const u8,
    setTimer: *const fn (stime: u64) void,
};

pub const ResetDriver = struct {
    name: []const u8,
    reset: *const fn () void,
    shutdown: *const fn () void,
};

// Global active drivers.
pub var console: ?ConsoleDriver = null;
pub var timer: ?TimerDriver = null;
pub var reset: ?ResetDriver = null;

// NS16550 UART driver implementation.
fn ns16550_putchar(c: u8) void {
    if (riscv.uart_base) |base| {
        const tx_reg = @as(*volatile u8, @ptrFromInt(base + debug.UART.THR));
        tx_reg.* = c;
    }
}

fn ns16550_getchar() i16 {
    if (riscv.uart_base) |base| {
        const status_reg =
            @as(*volatile u8, @ptrFromInt(base + debug.UART.LSR));
        const rx_reg = @as(*volatile u8, @ptrFromInt(base + debug.UART.RBR));
        if (status_reg.* & debug.UART.LSR_DR != 0) {
            return @as(i16, rx_reg.*);
        }
    }
    return -1;
}

// CLINT timer driver implementation.
fn clint_setTimer(stime: u64) void {
    if (riscv.clint_base) |base| {
        const offset = CLINT_MTIMECMP_OFFSET + 8 * riscv.readMhartid();
        const mtimecmp_ptr = @as(*volatile u64, @ptrFromInt(base + offset));
        mtimecmp_ptr.* = stime;
    }
}

// SiFive test device reset driver implementation.
fn sifive_test_reset() void {
    if (riscv.test_device_base) |base| {
        const finisher = @as(*volatile u32, @ptrFromInt(base));
        finisher.* = FINISHER_RESET;
    }
}

fn sifive_test_shutdown() void {
    if (riscv.test_device_base) |base| {
        const finisher = @as(*volatile u32, @ptrFromInt(base));
        finisher.* = FINISHER_PASS;
    }
}

// Initialize active drivers based on discovered MMIO bases and build config.
pub fn init() void {
    if (config.compile_ns16550 and riscv.uart_base != null) {
        console = .{
            .name = "NS16550 UART",
            .putchar = ns16550_putchar,
            .getchar = ns16550_getchar,
        };
    }

    if (config.compile_clint and riscv.clint_base != null) {
        timer = .{
            .name = "CLINT Timer",
            .setTimer = clint_setTimer,
        };
    }

    if (config.compile_sifive_test and riscv.test_device_base != null) {
        reset = .{
            .name = "SiFive Test Device",
            .reset = sifive_test_reset,
            .shutdown = sifive_test_shutdown,
        };
    }
}

test "drivers init registers active drivers when MMIO bases are present" {
    const saved_uart = riscv.uart_base;
    const saved_clint = riscv.clint_base;
    const saved_test = riscv.test_device_base;
    defer {
        riscv.uart_base = saved_uart;
        riscv.clint_base = saved_clint;
        riscv.test_device_base = saved_test;
        console = null;
        timer = null;
        reset = null;
    }

    riscv.uart_base = 0x10000000;
    riscv.clint_base = 0x02000000;
    riscv.test_device_base = 0x00100000;
    init();

    if (config.compile_ns16550) {
        try std.testing.expect(console != null);
        try std.testing.expectEqualStrings("NS16550 UART", console.?.name);
    }
    if (config.compile_clint) {
        try std.testing.expect(timer != null);
        try std.testing.expectEqualStrings("CLINT Timer", timer.?.name);
    }
    if (config.compile_sifive_test) {
        try std.testing.expect(reset != null);
        try std.testing.expectEqualStrings("SiFive Test Device", reset.?.name);
    }
}
