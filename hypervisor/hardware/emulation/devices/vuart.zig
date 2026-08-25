// Virtual 16550 UART Model for Guest Console Output
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const UART_REG_RBR_THR_DLL: u8 = 0;
pub const UART_REG_IER_DLM: u8     = 1;
pub const UART_REG_IIR_FCR: u8     = 2;
pub const UART_REG_LCR: u8         = 3;
pub const UART_REG_MCR: u8         = 4;
pub const UART_REG_LSR: u8         = 5;
pub const UART_REG_MSR: u8         = 6;
pub const UART_REG_SCR: u8         = 7;

pub const LCR_DLAB: u8                 = 0x80;
pub const LCR_8N1: u8                  = 0x03;
pub const IIR_NO_INT: u8               = 0x01;
pub const IIR_FIFO_ENABLED_16550A: u8  = 0xc1;
pub const LSR_THRE_TEMT: u8            = 0x60; // Transmit holding and shift register empty
pub const MSR_CARRIER_DSR_CTS: u8      = 0xb0; // Carrier detect, Data set ready, Clear to send

pub const VirtualUart = struct {
    ier: u8 = 0,
    iir: u8 = IIR_NO_INT,
    fcr: u8 = 0,
    lcr: u8 = LCR_8N1,
    mcr: u8 = 0,
    lsr: u8 = LSR_THRE_TEMT,
    msr: u8 = MSR_CARRIER_DSR_CTS,
    scr: u8 = 0,
    dll: u8 = 1,
    dlm: u8 = 0,
    guest_id: usize = 0,
    out_fn: ?*const fn (u8) void = null,

    pub fn write(self: *VirtualUart, offset: u8, val: u8) void {
        switch (offset) {
            UART_REG_RBR_THR_DLL => {
                if ((self.lcr & LCR_DLAB) != 0) {
                    self.dll = val;
                } else {
                    if (self.out_fn) |f| f(val);
                }
            },
            UART_REG_IER_DLM => {
                if ((self.lcr & LCR_DLAB) != 0) {
                    self.dlm = val;
                } else {
                    self.ier = val;
                }
            },
            UART_REG_IIR_FCR => self.fcr = val,
            UART_REG_LCR     => self.lcr = val,
            UART_REG_MCR     => self.mcr = val,
            UART_REG_LSR     => {}, // LSR is read-only
            UART_REG_MSR     => {}, // MSR is read-only
            UART_REG_SCR     => self.scr = val,
            else => {},
        }
    }

    pub fn read(self: *VirtualUart, offset: u8) u8 {
        return switch (offset) {
            UART_REG_RBR_THR_DLL => if ((self.lcr & LCR_DLAB) != 0) self.dll else 0,
            UART_REG_IER_DLM     => if ((self.lcr & LCR_DLAB) != 0) self.dlm else self.ier,
            UART_REG_IIR_FCR     => IIR_FIFO_ENABLED_16550A,
            UART_REG_LCR         => self.lcr,
            UART_REG_MCR         => self.mcr,
            UART_REG_LSR         => LSR_THRE_TEMT,
            UART_REG_MSR         => MSR_CARRIER_DSR_CTS,
            UART_REG_SCR         => self.scr,
            else => 0,
        };
    }
};

test "16550 UART read write and DLAB latching" {
    const testing = std.testing;

    const TestHelper = struct {
        fn out(byte: u8) void {
            _ = byte;
        }
    };

    var uart = VirtualUart{
        .out_fn = TestHelper.out,
    };


    // Test default status values
    try testing.expectEqual(LSR_THRE_TEMT, uart.read(UART_REG_LSR));
    try testing.expectEqual(MSR_CARRIER_DSR_CTS, uart.read(UART_REG_MSR));
    try testing.expectEqual(IIR_FIFO_ENABLED_16550A, uart.read(UART_REG_IIR_FCR));
    try testing.expectEqual(LCR_8N1, uart.read(UART_REG_LCR));

    // Test normal IER write/read when DLAB is 0
    uart.write(UART_REG_IER_DLM, 0x05);
    try testing.expectEqual(@as(u8, 0x05), uart.read(UART_REG_IER_DLM));

    // Test Scratch register
    uart.write(UART_REG_SCR, 0xA5);
    try testing.expectEqual(@as(u8, 0xA5), uart.read(UART_REG_SCR));

    // Enable DLAB (bit 7 in LCR)
    uart.write(UART_REG_LCR, LCR_8N1 | LCR_DLAB);
    try testing.expectEqual(@as(u8, LCR_8N1 | LCR_DLAB), uart.read(UART_REG_LCR));

    // Write DLL & DLM divisor latches
    uart.write(UART_REG_RBR_THR_DLL, 0x12);
    uart.write(UART_REG_IER_DLM, 0x34);
    try testing.expectEqual(@as(u8, 0x12), uart.read(UART_REG_RBR_THR_DLL));
    try testing.expectEqual(@as(u8, 0x34), uart.read(UART_REG_IER_DLM));

    // Disable DLAB
    uart.write(UART_REG_LCR, LCR_8N1);
    try testing.expectEqual(@as(u8, 0x05), uart.read(UART_REG_IER_DLM)); // Original IER restored
    try testing.expectEqual(@as(u8, 0x00), uart.read(UART_REG_RBR_THR_DLL)); // RBR empty
}



