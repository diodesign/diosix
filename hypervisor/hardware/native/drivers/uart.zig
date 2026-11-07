// Dynamic Host UART Driver.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");

pub const UartKind = enum {
    ns16550,
    sifive,
};

pub var base_address: ?usize = null;
pub var reg_shift: u3 = 0;
pub var reg_io_width: u8 = 1;
pub var uart_kind: UartKind = .ns16550;

// 16550 UART Registers and Flags.
pub const REG_RBR: usize = 0; // Receiver Buffer Register (read)
pub const REG_THR: usize = 0; // Transmitter Holding Register (write)
pub const REG_LSR: usize = 5; // Line Status Register

pub const LSR_DR: u8 = 0x01; // Data Ready
pub const LSR_THRE: u8 = 0x20; // Transmitter Holding Register Empty

// SiFive UART0 Registers and Flags (FU540 / FU740).
pub const SIFIVE_REG_TXDATA: usize = 0x00;
pub const SIFIVE_REG_RXDATA: usize = 0x04;
pub const SIFIVE_TX_FULL: u32 = 0x8000_0000;
pub const SIFIVE_RX_EMPTY: u32 = 0x8000_0000;

pub fn init(base: usize) void {
    initConfig(base, 0, 1, .ns16550);
}

pub fn initConfig(
    base: usize,
    shift: u3,
    io_width: u8,
    kind: UartKind,
) void {
    base_address = base;
    reg_shift = shift;
    reg_io_width = if (io_width == 4) 4 else 1;
    uart_kind = kind;
}

inline fn readReg8(base: usize, reg_idx: usize) u8 {
    const addr = base + (reg_idx << reg_shift);
    if (reg_io_width == 4) {
        const ptr = @as(*volatile u32, @ptrFromInt(addr));
        return @truncate(ptr.*);
    }
    const ptr = @as(*volatile u8, @ptrFromInt(addr));
    return ptr.*;
}

inline fn writeReg8(base: usize, reg_idx: usize, val: u8) void {
    const addr = base + (reg_idx << reg_shift);
    if (reg_io_width == 4) {
        const ptr = @as(*volatile u32, @ptrFromInt(addr));
        ptr.* = val;
        return;
    }
    const ptr = @as(*volatile u8, @ptrFromInt(addr));
    ptr.* = val;
}

pub fn putchar(c: u8) void {
    if (builtin.is_test) return;
    if (base_address) |base| {
        var timeout: usize = 1_000_000;
        switch (uart_kind) {
            .ns16550 => {
                while ((readReg8(base, REG_LSR) & LSR_THRE) == 0 and
                    timeout > 0)
                {
                    timeout -= 1;
                    std.atomic.spinLoopHint();
                }
                if (timeout > 0) {
                    writeReg8(base, REG_THR, c);
                }
            },
            .sifive => {
                const tx_reg = @as(
                    *volatile u32,
                    @ptrFromInt(base + SIFIVE_REG_TXDATA),
                );
                while ((tx_reg.* & SIFIVE_TX_FULL) != 0 and timeout > 0) {
                    timeout -= 1;
                    std.atomic.spinLoopHint();
                }
                if (timeout > 0) {
                    tx_reg.* = c;
                }
            },
        }
    }
}

pub fn getchar() i16 {
    if (builtin.is_test) return -1;
    if (base_address) |base| {
        switch (uart_kind) {
            .ns16550 => {
                if ((readReg8(base, REG_LSR) & LSR_DR) != 0) {
                    return @as(i16, readReg8(base, REG_RBR));
                }
            },
            .sifive => {
                const rx_reg = @as(
                    *volatile u32,
                    @ptrFromInt(base + SIFIVE_REG_RXDATA),
                );
                const val = rx_reg.*;
                if ((val & SIFIVE_RX_EMPTY) == 0) {
                    return @as(i16, @intCast(val & 0xff));
                }
            },
        }
    }
    return -1;
}

test "uart driver init and test-safe access" {
    std.testing.refAllDecls(@This());
    init(0x10000000);
    defer init(0x10000000);
    defer base_address = null;
    try std.testing.expectEqual(@as(?usize, 0x10000000), base_address);
    try std.testing.expectEqual(@as(u3, 0), reg_shift);
    try std.testing.expectEqual(@as(u8, 1), reg_io_width);
    try std.testing.expectEqual(UartKind.ns16550, uart_kind);
    initConfig(0x10000000, 2, 4, .sifive);
    try std.testing.expectEqual(@as(u3, 2), reg_shift);
    try std.testing.expectEqual(@as(u8, 4), reg_io_width);
    try std.testing.expectEqual(UartKind.sifive, uart_kind);
    putchar('A');
    try std.testing.expectEqual(@as(i16, -1), getchar());
}
