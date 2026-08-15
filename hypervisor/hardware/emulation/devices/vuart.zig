// Virtual 16550 UART Model for Guest Console Output
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const VirtualUart = struct {
    ier: u8 = 0,
    iir: u8 = 1, // No interrupt pending
    fcr: u8 = 0,
    lcr: u8 = 3, // 8n1
    mcr: u8 = 0,
    lsr: u8 = 0x60, // Transmit hold & shift empty
    msr: u8 = 0xb0, // Carrier detect, DSR, CTS
    scr: u8 = 0,
    dll: u8 = 1,
    dlm: u8 = 0,
    guest_id: usize = 0,
    out_fn: ?*const fn (u8) void = null,

    pub fn write(self: *VirtualUart, offset: u8, val: u8) void {
        switch (offset) {
            0 => {
                if ((self.lcr & 0x80) != 0) {
                    self.dll = val;
                } else {
                    if (self.out_fn) |f| f(val);
                }
            },
            1 => {
                if ((self.lcr & 0x80) != 0) {
                    self.dlm = val;
                } else {
                    self.ier = val;
                }
            },
            2 => self.fcr = val,
            3 => self.lcr = val,
            4 => self.mcr = val,
            5 => {}, // LSR is read-only
            6 => {}, // MSR is read-only
            7 => self.scr = val,
            else => {},
        }
    }

    pub fn read(self: *VirtualUart, offset: u8) u8 {
        return switch (offset) {
            0 => if ((self.lcr & 0x80) != 0) self.dll else 0,
            1 => if ((self.lcr & 0x80) != 0) self.dlm else self.ier,
            2 => 0xc1, // 16550A FIFO enabled
            3 => self.lcr,
            4 => self.mcr,
            5 => 0x60, // LSR: THRE | TEMT
            6 => 0xb0, // MSR: DCD | DSR | CTS
            7 => self.scr,
            else => 0,
        };
    }
};
