// Device Driver Framework for Universal Binary
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const config = @import("config");
const riscv = @import("arch/riscv64/riscv.zig");

// Driver interfaces
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

// Global active drivers
pub var console: ?ConsoleDriver = null;
pub var timer: ?TimerDriver = null;
pub var reset: ?ResetDriver = null;

// Console Driver Implementations

// NS16550 UART Driver
fn ns16550_putchar(c: u8) void {
    if (riscv.uart_base) |base| {
        const status_reg = @as(*volatile u8, @ptrFromInt(base + 5)); // LSR register offset 5
        const tx_reg = @as(*volatile u8, @ptrFromInt(base + 0)); // THR register offset 0
        while (status_reg.* & 0x20 == 0) {} // LSR_THRE is 0x20
        tx_reg.* = c;
    }
}

fn ns16550_getchar() i16 {
    if (riscv.uart_base) |base| {
        const status_reg = @as(*volatile u8, @ptrFromInt(base + 5)); // LSR register offset 5
        const rx_reg = @as(*volatile u8, @ptrFromInt(base + 0)); // RBR register offset 0
        if (status_reg.* & 0x01 != 0) { // LSR_DR is 0x01
            return @as(i16, rx_reg.*);
        }
    }
    return -1;
}

// Timer Driver Implementations

// CLINT Timer Driver
fn clint_setTimer(stime: u64) void {
    if (riscv.clint_base) |base| {
        const mtimecmp_ptr = @as(*volatile u64, @ptrFromInt(base + 0x4000 + 8 * riscv.readMhartid()));
        mtimecmp_ptr.* = stime;
    }
}

// Reset Driver Implementations

// SiFive Test Driver
fn sifive_test_reset() void {
    if (riscv.test_device_base) |base| {
        const finisher = @as(*volatile u32, @ptrFromInt(base));
        finisher.* = 0x7777; // FINISHER_RESET
    }
}

fn sifive_test_shutdown() void {
    if (riscv.test_device_base) |base| {
        const finisher = @as(*volatile u32, @ptrFromInt(base));
        finisher.* = 0x5555; // FINISHER_PASS exits QEMU
    }
}

// Initialization function
pub fn init() void {
    // 1. Console Driver Initialization
    if (config.compile_ns16550 and riscv.uart_base != null) {
        console = .{
            .name = "NS16550 UART",
            .putchar = ns16550_putchar,
            .getchar = ns16550_getchar,
        };
    }

    // 2. Timer Driver Initialization
    if (config.compile_clint and riscv.clint_base != null) {
        timer = .{
            .name = "CLINT Timer",
            .setTimer = clint_setTimer,
        };
    }

    // 3. Reset Driver Initialization
    if (config.compile_sifive_test and riscv.test_device_base != null) {
        reset = .{
            .name = "SiFive Test Device",
            .reset = sifive_test_reset,
            .shutdown = sifive_test_shutdown,
        };
    }
}
