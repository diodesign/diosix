// Debug output for the hypervisor.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const Writer = std.Io.Writer;
const atomic = @import("atomic.zig");
const riscv = @import("../hardware/native/cpu/riscv64/mod.zig");
const drivers = @import("drivers.zig");

// Circular queue sizes and fallback UART address for console text streams.
pub const OUTPUT_QUEUE_SIZE: usize = 4096;
pub const STDIN_QUEUE_SIZE: usize = 256;
pub const DEFAULT_UART_BASE: usize = 0x10000000;

// Generic circular queue (allocation-free & interrupt-safe).
pub fn GenericQueue(comptime T: type, comptime size: usize) type {
    return struct {
        buf: [size]T = undefined,
        head: usize = 0,
        tail: usize = 0,

        pub fn push(self: *@This(), val: T) bool {
            const next = (self.tail + 1) % size;
            if (next == self.head) return false; // Full.
            self.buf[self.tail] = val;
            self.tail = next;
            return true;
        }

        pub fn pop(self: *@This()) ?T {
            if (self.head == self.tail) return null; // Empty.
            const val = self.buf[self.head];
            self.head = (self.head + 1) % size;
            return val;
        }

        pub fn isEmpty(self: *const @This()) bool {
            return self.head == self.tail;
        }
    };
}

const ConsoleState = struct {
    // Single shared output queue for hypervisor console output.
    output_queue: GenericQueue(u8, OUTPUT_QUEUE_SIZE) = .{},

    // Shared input queue for console keyboard input.
    stdin_queue: GenericQueue(u8, STDIN_QUEUE_SIZE) = .{},
};

// Global thread-safe debug console state.
var global_console_state =
    atomic.LockPayload(ConsoleState).init("Debug console state", .{});

// Reentrant lock tracking for active owner.
var console_lock_owner: usize = 0;
var console_lock_recursion: usize = 0;
var console_lock_saved_mstatus: usize = 0;

// Top-level crash bypass flag so panic messages print immediately.
pub var panic_mode: bool = false;

pub const UART = struct {
    // 16550 UART Register Offsets.
    pub const RBR = 0; // Receiver Buffer Register (read).
    pub const THR = 0; // Transmitter Holding Register (write).
    pub const LSR = 5; // Line Status Register.

    // LSR Bitmasks.
    pub const LSR_DR = 0x01; // Data Ready.
    pub const LSR_THRE = 0x20; // Transmitter Holding Register Empty.
};

const UART_MAX_TX_SPINS: usize = 100_000;
const SIFIVE_UART_TXDATA: usize = 0x00;
const SIFIVE_UART_RXDATA: usize = 0x04;
const SIFIVE_UART_FULL_MASK: u32 = 0x8000_0000;

fn mmioReadU8Reg(base: usize, off: usize, shift: u3, width: u8) u8 {
    const addr = base + (off << shift);
    if (width == 4) {
        return @truncate(@as(*const volatile u32, @ptrFromInt(addr)).*);
    }
    return @as(*const volatile u8, @ptrFromInt(addr)).*;
}

fn mmioWriteU8Reg(
    base: usize,
    off: usize,
    shift: u3,
    width: u8,
    val: u8,
) void {
    const addr = base + (off << shift);
    if (width == 4) {
        @as(*volatile u32, @ptrFromInt(addr)).* = val;
    } else {
        @as(*volatile u8, @ptrFromInt(addr)).* = val;
    }
}

fn uartTxReady(base: usize, shift: u3, width: u8) bool {
    const lsr = mmioReadU8Reg(base, UART.LSR, shift, width);
    return (lsr & UART.LSR_THRE) != 0;
}

pub fn uartPutchar(base: usize, c: u8) void {
    if (riscv.uart_is_sifive) {
        const tx = @as(*volatile u32, @ptrFromInt(base + SIFIVE_UART_TXDATA));
        var spins: usize = 0;
        while ((tx.* & SIFIVE_UART_FULL_MASK) != 0 and
            spins < UART_MAX_TX_SPINS) : (spins += 1)
        {}
        tx.* = c;
        return;
    }
    const shift = riscv.uart_reg_shift;
    const width = riscv.uart_reg_io_width;
    var spins: usize = 0;
    while (spins < UART_MAX_TX_SPINS) : (spins += 1) {
        if (uartTxReady(base, shift, width)) break;
    }
    mmioWriteU8Reg(base, UART.THR, shift, width, c);
}

pub fn uartGetchar(base: usize) i16 {
    if (riscv.uart_is_sifive) {
        const rx =
            @as(*const volatile u32, @ptrFromInt(base + SIFIVE_UART_RXDATA));
        const val: u32 = rx.*;
        if ((val & SIFIVE_UART_FULL_MASK) == 0) {
            return @intCast(val & 0xff);
        }
        return -1;
    }
    const shift = riscv.uart_reg_shift;
    const width = riscv.uart_reg_io_width;
    if ((mmioReadU8Reg(base, UART.LSR, shift, width) & UART.LSR_DR) != 0) {
        return @as(i16, mmioReadU8Reg(base, UART.RBR, shift, width));
    }
    return -1;
}

pub fn hw_putchar(c: u8) void {
    if (builtin.is_test) return;
    if (drivers.console) |drv| {
        drv.putchar(c);
    } else {
        const uart = riscv.uart_base orelse DEFAULT_UART_BASE;
        uartPutchar(uart, c);
    }
}

pub fn hw_getchar() i16 {
    if (builtin.is_test) return -1;
    if (drivers.console) |drv| {
        return drv.getchar();
    } else {
        const uart = riscv.uart_base orelse DEFAULT_UART_BASE;
        return uartGetchar(uart);
    }
}

fn acquireConsole() *ConsoleState {
    const hart_id = riscv.readMhartid();
    const self_id = hart_id + 1; // 1-indexed so 0 represents unowned.

    if (@atomicLoad(usize, &console_lock_owner, .seq_cst) == self_id) {
        console_lock_recursion += 1;
    } else {
        const prev_ms = global_console_state.lock.lock();
        @atomicStore(usize, &console_lock_owner, self_id, .seq_cst);
        console_lock_saved_mstatus = prev_ms;
        console_lock_recursion = 1;
    }
    return &global_console_state.data;
}

fn releaseConsole() void {
    const hart_id = riscv.readMhartid();
    const self_id = hart_id + 1;

    if (@atomicLoad(usize, &console_lock_owner, .seq_cst) == self_id) {
        console_lock_recursion -= 1;
        if (console_lock_recursion == 0) {
            const saved_ms = console_lock_saved_mstatus;
            @atomicStore(usize, &console_lock_owner, 0, .seq_cst);
            global_console_state.lock.unlock(saved_ms);
        }
    }
}

// Drains characters from output queue to the physical console.
fn drainQueuesInternal(state: *ConsoleState) void {
    while (state.output_queue.pop()) |c| {
        hw_putchar(c);
    }
}

// Releases our spinlocks immediately when a crash is caught.
pub fn releaseLocksForCrash() void {
    @atomicStore(bool, &panic_mode, true, .release);
    console_lock_recursion = 0;
    @atomicStore(usize, &console_lock_owner, 0, .release);
    global_console_state.lock.spinlock.lock_value.store(0, .release);
}

const basic_writer_vtable = Writer.VTable{
    .drain = basicDrain,
    .flush = Writer.noopFlush,
};

var basic_writer = Writer{
    .vtable = &basic_writer_vtable,
    .buffer = &.{},
};

fn emitSlices(
    state: ?*ConsoleState,
    data: []const []const u8,
    splat: usize,
) usize {
    var total: usize = 0;
    for (data) |buf| {
        for (buf) |c| {
            if (state) |s| _ = s.output_queue.push(c) else hw_putchar(c);
        }
        total += buf.len;
    }
    if (data.len > 0 and splat > 0) {
        const last = data[data.len - 1];
        for (0..splat - 1) |_| {
            for (last) |c| {
                if (state) |s| _ = s.output_queue.push(c) else hw_putchar(c);
            }
            total += last.len;
        }
    }
    return total;
}

fn basicDrain(
    _: *Writer,
    data: []const []const u8,
    splat: usize,
) Writer.Error!usize {
    if (@atomicLoad(bool, &panic_mode, .acquire)) {
        return emitSlices(null, data, splat);
    }

    const state = acquireConsole();
    defer releaseConsole();
    const total = emitSlices(state, data, splat);
    drainQueuesInternal(state);
    return total;
}

pub fn printf(comptime format: []const u8, args: anytype) void {
    if (@atomicLoad(bool, &panic_mode, .acquire)) {
        basic_writer.print(format, args) catch {};
        return;
    }
    _ = acquireConsole();
    defer releaseConsole();
    basic_writer.print(format, args) catch {};
}

pub fn putchar(c: u8) void {
    if (@atomicLoad(bool, &panic_mode, .acquire)) {
        hw_putchar(c);
        return;
    }
    const state = acquireConsole();
    defer releaseConsole();
    _ = state.output_queue.push(c);
    drainQueuesInternal(state);
}

pub fn write(s: []const u8) void {
    if (@atomicLoad(bool, &panic_mode, .acquire)) {
        for (s) |c| hw_putchar(c);
        return;
    }
    const state = acquireConsole();
    defer releaseConsole();
    for (s) |c| {
        _ = state.output_queue.push(c);
    }
    drainQueuesInternal(state);
}

pub fn getchar() i16 {
    if (@atomicLoad(bool, &panic_mode, .acquire)) {
        return hw_getchar();
    }
    const state = acquireConsole();
    defer releaseConsole();

    if (state.stdin_queue.pop()) |c| {
        return c;
    }

    return hw_getchar();
}

test "debug console circular queue push, pop, capacity, and wrap-around" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    var q = GenericQueue(u8, 4){};
    try testing.expect(q.isEmpty());
    try testing.expect(q.pop() == null);

    // Queue of size 4 holds 3 elements before full (head == next tail).
    try testing.expect(q.push('A'));
    try testing.expect(q.push('B'));
    try testing.expect(q.push('C'));
    try testing.expect(!q.push('D'));

    try testing.expectEqual(@as(?u8, 'A'), q.pop());
    try testing.expect(q.push('D')); // Wrap-around slot.

    try testing.expectEqual(@as(?u8, 'B'), q.pop());
    try testing.expectEqual(@as(?u8, 'C'), q.pop());
    try testing.expectEqual(@as(?u8, 'D'), q.pop());
    try testing.expect(q.isEmpty());

    const saved_sh = riscv.uart_reg_shift;
    const saved_w = riscv.uart_reg_io_width;
    const saved_sf = riscv.uart_is_sifive;
    defer {
        riscv.uart_reg_shift = saved_sh;
        riscv.uart_reg_io_width = saved_w;
        riscv.uart_is_sifive = saved_sf;
    }

    var dw_regs: [8]u32 align(64) = @splat(0);
    dw_regs[UART.LSR] = UART.LSR_THRE | UART.LSR_DR;
    riscv.uart_is_sifive = false;
    riscv.uart_reg_shift = 2;
    riscv.uart_reg_io_width = 4;
    uartPutchar(@intFromPtr(&dw_regs), 'Z');
    try testing.expectEqual(@as(u32, 'Z'), dw_regs[0]);
    try testing.expectEqual(@as(i16, 'Z'), uartGetchar(@intFromPtr(&dw_regs)));

    var sf_regs: [4]u32 align(64) = @splat(0);
    riscv.uart_is_sifive = true;
    uartPutchar(@intFromPtr(&sf_regs), 'Q');
    try testing.expectEqual(@as(u32, 'Q'), sf_regs[0]);
    sf_regs[1] = 'R';
    try testing.expectEqual(@as(i16, 'R'), uartGetchar(@intFromPtr(&sf_regs)));
    sf_regs[1] = SIFIVE_UART_FULL_MASK;
    try testing.expectEqual(@as(i16, -1), uartGetchar(@intFromPtr(&sf_regs)));
}
