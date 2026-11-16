// Virtual 16550A UART Model for Guest Console Input & Output
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const UART_REG_RBR_THR_DLL: u8 = 0;
pub const UART_REG_IER_DLM: u8 = 1;
pub const UART_REG_IIR_FCR: u8 = 2;
pub const UART_REG_LCR: u8 = 3;
pub const UART_REG_MCR: u8 = 4;
pub const UART_REG_LSR: u8 = 5;
pub const UART_REG_MSR: u8 = 6;
pub const UART_REG_SCR: u8 = 7;

pub const LCR_DLAB: u8 = 0x80;
pub const LCR_8N1: u8 = 0x03;

pub const IER_RDI: u8 = 0x01;
pub const IER_THRI: u8 = 0x02;

pub const IIR_NO_INT: u8 = 0x01;
pub const IIR_THRI: u8 = 0x02;
pub const IIR_RDI: u8 = 0x04;
pub const IIR_FIFO_BITS: u8 = 0xc0;
pub const IIR_FIFO_ENABLED_16550A: u8 = IIR_FIFO_BITS | IIR_NO_INT;

/// Data ready in receive buffer.
pub const LSR_DR: u8 = 0x01;
/// Transmit holding and shift register empty.
pub const LSR_THRE_TEMT: u8 = 0x60;
/// Carrier detect, Data set ready, Clear to send.
pub const MSR_CARRIER_DSR_CTS: u8 = 0xb0;

pub const VirtualUart = struct {
    ier: u8 = 0,
    fcr: u8 = 0,
    lcr: u8 = LCR_8N1,
    mcr: u8 = 0,
    scr: u8 = 0,
    dll: u8 = 1,
    dlm: u8 = 0,
    thre_ip: bool = false,
    guest_id: usize = 0,
    out_ctx: ?*anyopaque = null,
    out_ctx_fn: ?*const fn (?*anyopaque, u8) void = null,
    out_fn: ?*const fn (u8) void = null,
    in_ctx_fn: ?*const fn (?*anyopaque) ?u8 = null,
    peek_in_ctx_fn: ?*const fn (?*anyopaque) bool = null,

    pub fn hasRxData(self: *const VirtualUart) bool {
        if (self.peek_in_ctx_fn) |f| return f(self.out_ctx);
        return false;
    }

    pub fn hasPendingIrq(self: *const VirtualUart) bool {
        const ier = @atomicLoad(u8, &self.ier, .acquire);
        if ((ier & IER_RDI) != 0 and self.hasRxData()) return true;
        if ((ier & IER_THRI) != 0 and
            @atomicLoad(bool, &self.thre_ip, .acquire))
        {
            return true;
        }
        return false;
    }

    pub fn write(self: *VirtualUart, offset: u8, val: u8) void {
        const lcr = @atomicLoad(u8, &self.lcr, .acquire);
        switch (offset) {
            UART_REG_RBR_THR_DLL => {
                if ((lcr & LCR_DLAB) != 0) {
                    @atomicStore(u8, &self.dll, val, .release);
                } else {
                    if (self.out_ctx_fn) |f| {
                        f(self.out_ctx, val);
                    } else if (self.out_fn) |f| {
                        f(val);
                    }
                    @atomicStore(bool, &self.thre_ip, true, .release);
                }
            },
            UART_REG_IER_DLM => {
                if ((lcr & LCR_DLAB) != 0) {
                    @atomicStore(u8, &self.dlm, val, .release);
                } else {
                    @atomicStore(u8, &self.ier, val, .release);
                    @atomicStore(
                        bool,
                        &self.thre_ip,
                        (val & IER_THRI) != 0,
                        .release,
                    );
                }
            },
            UART_REG_IIR_FCR => @atomicStore(u8, &self.fcr, val, .release),
            UART_REG_LCR => @atomicStore(u8, &self.lcr, val, .release),
            UART_REG_MCR => @atomicStore(u8, &self.mcr, val, .release),
            UART_REG_LSR => {}, // LSR is read-only.
            UART_REG_MSR => {}, // MSR is read-only.
            UART_REG_SCR => @atomicStore(u8, &self.scr, val, .release),
            else => {},
        }
    }

    pub fn read(self: *VirtualUart, offset: u8) u8 {
        const lcr = @atomicLoad(u8, &self.lcr, .acquire);
        return switch (offset) {
            UART_REG_RBR_THR_DLL => if ((lcr & LCR_DLAB) != 0)
                @atomicLoad(u8, &self.dll, .acquire)
            else if (self.in_ctx_fn) |f|
                f(self.out_ctx) orelse 0
            else
                0,
            UART_REG_IER_DLM => if ((lcr & LCR_DLAB) != 0)
                @atomicLoad(u8, &self.dlm, .acquire)
            else
                @atomicLoad(u8, &self.ier, .acquire),
            UART_REG_IIR_FCR => blk: {
                const ier = @atomicLoad(u8, &self.ier, .acquire);
                if ((ier & IER_RDI) != 0 and self.hasRxData()) {
                    break :blk IIR_FIFO_BITS | IIR_RDI;
                }
                if ((ier & IER_THRI) != 0 and
                    @atomicRmw(bool, &self.thre_ip, .Xchg, false, .acq_rel))
                {
                    break :blk IIR_FIFO_BITS | IIR_THRI;
                }
                break :blk IIR_FIFO_ENABLED_16550A;
            },
            UART_REG_LCR => lcr,
            UART_REG_MCR => @atomicLoad(u8, &self.mcr, .acquire),
            UART_REG_LSR => LSR_THRE_TEMT |
                (if (self.hasRxData()) LSR_DR else 0),
            UART_REG_MSR => MSR_CARRIER_DSR_CTS,
            UART_REG_SCR => @atomicLoad(u8, &self.scr, .acquire),
            else => 0,
        };
    }
};

test "16550 UART read write, DLAB latching, RX ring, and interrupts" {
    const testing = std.testing;

    const RxMock = struct {
        buf: [8]u8 = @splat(0),
        len: usize = 0,
        idx: usize = 0,

        fn out(_: ?*anyopaque, _: u8) void {}

        fn pop(ctx: ?*anyopaque) ?u8 {
            const m: *@This() = @ptrCast(@alignCast(ctx.?));
            if (m.idx >= m.len) return null;
            const b = m.buf[m.idx];
            m.idx += 1;
            return b;
        }

        fn peek(ctx: ?*anyopaque) bool {
            const m: *@This() = @ptrCast(@alignCast(ctx.?));
            return m.idx < m.len;
        }
    };

    var rx_mock = RxMock{};
    var uart = VirtualUart{
        .out_ctx = &rx_mock,
        .out_ctx_fn = RxMock.out,
        .in_ctx_fn = RxMock.pop,
        .peek_in_ctx_fn = RxMock.peek,
    };

    // Test default status values.
    try testing.expectEqual(LSR_THRE_TEMT, uart.read(UART_REG_LSR));
    try testing.expectEqual(MSR_CARRIER_DSR_CTS, uart.read(UART_REG_MSR));
    try testing.expectEqual(
        IIR_FIFO_ENABLED_16550A,
        uart.read(UART_REG_IIR_FCR),
    );
    try testing.expectEqual(LCR_8N1, uart.read(UART_REG_LCR));
    try testing.expect(!uart.hasPendingIrq());

    // Enabling IER_THRI raises THRE interrupt once until IIR is read.
    uart.write(UART_REG_IER_DLM, IER_RDI | IER_THRI);
    try testing.expect(uart.hasPendingIrq());
    try testing.expectEqual(
        @as(u8, IIR_FIFO_BITS | IIR_THRI),
        uart.read(UART_REG_IIR_FCR),
    );
    try testing.expect(!uart.hasPendingIrq());
    try testing.expectEqual(
        IIR_FIFO_ENABLED_16550A,
        uart.read(UART_REG_IIR_FCR),
    );

    // Queuing RX bytes sets LSR_DR and raises higher-priority IIR_RDI.
    rx_mock.buf[0] = 'A';
    rx_mock.buf[1] = '\n';
    rx_mock.len = 2;
    try testing.expect(uart.hasPendingIrq());
    try testing.expectEqual(
        @as(u8, LSR_THRE_TEMT | LSR_DR),
        uart.read(UART_REG_LSR),
    );
    try testing.expectEqual(
        @as(u8, IIR_FIFO_BITS | IIR_RDI),
        uart.read(UART_REG_IIR_FCR),
    );
    try testing.expectEqual(@as(u8, 'A'), uart.read(UART_REG_RBR_THR_DLL));
    try testing.expectEqual(@as(u8, '\n'), uart.read(UART_REG_RBR_THR_DLL));
    try testing.expect(!uart.hasPendingIrq());
    try testing.expectEqual(LSR_THRE_TEMT, uart.read(UART_REG_LSR));

    // Test Scratch register and DLAB divisor latches.
    uart.write(UART_REG_IER_DLM, 0x05);
    uart.write(UART_REG_SCR, 0xa5);
    try testing.expectEqual(@as(u8, 0xa5), uart.read(UART_REG_SCR));

    uart.write(UART_REG_LCR, LCR_8N1 | LCR_DLAB);
    uart.write(UART_REG_RBR_THR_DLL, 0x12);
    uart.write(UART_REG_IER_DLM, 0x34);
    try testing.expectEqual(@as(u8, 0x12), uart.read(UART_REG_RBR_THR_DLL));
    try testing.expectEqual(@as(u8, 0x34), uart.read(UART_REG_IER_DLM));

    uart.write(UART_REG_LCR, LCR_8N1);
    try testing.expectEqual(@as(u8, 0x05), uart.read(UART_REG_IER_DLM));
    try testing.expectEqual(@as(u8, 0x00), uart.read(UART_REG_RBR_THR_DLL));
    testing.refAllDecls(@This());
}
