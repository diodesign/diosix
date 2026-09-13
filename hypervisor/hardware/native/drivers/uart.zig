// Dynamic Host UART Driver
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub var base_address: ?usize = null;

// 16550 UART Registers and Flags
pub const REG_RBR: usize = 0; // Receiver Buffer Register (read)
pub const REG_THR: usize = 0; // Transmitter Holding Register (write)
pub const REG_LSR: usize = 5; // Line Status Register

pub const LSR_DR: u8 = 0x01;   // Data Ready
pub const LSR_THRE: u8 = 0x20; // Transmitter Holding Register Empty

pub fn init(base: usize) void {
    base_address = base;
}

pub fn putchar(c: u8) void {
    if (base_address) |base| {
        const status_reg = @as(*volatile u8, @ptrFromInt(base + REG_LSR));
        const tx_reg = @as(*volatile u8, @ptrFromInt(base + REG_THR));
        var timeout: usize = 1_000_000;
        while (status_reg.* & LSR_THRE == 0 and timeout > 0) : (timeout -= 1) {
            std.atomic.spinLoopHint();
        }
        if (timeout > 0) {
            tx_reg.* = c;
        }
    }
}

pub fn getchar() i16 {
    if (base_address) |base| {
        const status_reg = @as(*volatile u8, @ptrFromInt(base + REG_LSR));
        const rx_reg = @as(*volatile u8, @ptrFromInt(base + REG_RBR));
        if (status_reg.* & LSR_DR != 0) {
            return @as(i16, rx_reg.*);
        }
    }
    return -1;
}
