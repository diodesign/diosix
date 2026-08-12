// Virtual 16550 UART Model for Guest Console Output
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const VirtualUart = struct {
    tx_fifo: [128]u8 = undefined,
    tx_count: usize = 0,
    guest_id: usize = 0,

    pub fn write(self: *VirtualUart, offset: u8, val: u8) void {
        if (offset == 0) { // THR register
            if (self.tx_count < self.tx_fifo.len) {
                self.tx_fifo[self.tx_count] = val;
                self.tx_count += 1;
            }
        }
    }

    pub fn read(self: *VirtualUart, offset: u8) u8 {
        _ = self;
        if (offset == 5) return 0x60; // LSR: Transmitter empty & holding register empty
        return 0;
    }
};
