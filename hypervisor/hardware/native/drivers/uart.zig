// Dynamic Host UART Driver
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub var base_address: ?usize = null;

pub fn init(base: usize) void {
    base_address = base;
}

pub fn putchar(c: u8) void {
    if (base_address) |base| {
        const status_reg = @as(*volatile u8, @ptrFromInt(base + 5)); // LSR register offset 5
        const tx_reg = @as(*volatile u8, @ptrFromInt(base + 0)); // THR register offset 0
        while (status_reg.* & 0x20 == 0) {} // LSR_THRE is 0x20
        tx_reg.* = c;
    }
}

pub fn getchar() i16 {
    if (base_address) |base| {
        const status_reg = @as(*volatile u8, @ptrFromInt(base + 5)); // LSR register offset 5
        const rx_reg = @as(*volatile u8, @ptrFromInt(base + 0)); // RBR register offset 0
        if (status_reg.* & 0x01 != 0) { // LSR_DR is 0x01
            return @as(i16, rx_reg.*);
        }
    }
    return -1;
}
