// Debug output for the hypervisor
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const Writer = std.Io.Writer;
const atomic = @import("atomic.zig");
const pcore = @import("pcore.zig");
const riscv = @import("../hardware/native/cpu/riscv64/mod.zig");
const drivers = @import("drivers.zig");

// Circular queue size for console text streams
const queue_size = 4096;

// Generic circular queue (allocation-free & interrupt-safe)
pub fn GenericQueue(comptime T: type, comptime size: usize) type {
    return struct {
        buf: [size]T = undefined,
        head: usize = 0,
        tail: usize = 0,

        pub fn push(self: *@This(), val: T) bool {
            const next = (self.tail + 1) % size;
            if (next == self.head) return false; // Full
            self.buf[self.tail] = val;
            self.tail = next;
            return true;
        }

        pub fn pop(self: *@This()) ?T {
            if (self.head == self.tail) return null; // Empty
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
    // Single shared output queue for hypervisor console output
    output_queue: GenericQueue(u8, queue_size) = .{},

    // Shared input queue for console keyboard input
    stdin_queue: GenericQueue(u8, 256) = .{},
};

// Global thread-safe debug console state
var global_console_state = atomic.LockPayload(ConsoleState).init("Debug console state", .{});

// Reentrant lock tracking (per-hart to prevent cross-core interference)
const MAX_CPUS = 128;
var console_lock_owner: usize = 0;
var console_lock_recursion = std.mem.zeroes([MAX_CPUS]usize);
var console_lock_saved_mstatus = std.mem.zeroes([MAX_CPUS]usize);

// Top-level crash bypass flag to guarantee panic messages get printed immediately
pub var panic_mode: bool = false;

pub const UART = struct {
    // 16550 UART Register Offsets
    pub const RBR = 0; // Receiver Buffer Register (read)
    pub const THR = 0; // Transmitter Holding Register (write)
    pub const LSR = 5; // Line Status Register

    // LSR Bitmasks
    pub const LSR_DR = 0x01; // Data Ready
    pub const LSR_THRE = 0x20; // Transmitter Holding Register Empty
};

pub fn hw_putchar(c: u8) void {
    if (builtin.is_test) return;
    if (drivers.console) |drv| {
        drv.putchar(c);
    } else {
        const uart = riscv.uart_base orelse 0x10000000;
        const tx_reg = @as(*volatile u8, @ptrFromInt(uart + UART.THR));
        tx_reg.* = c;
    }
}

pub fn hw_getchar() i16 {
    if (builtin.is_test) return -1;
    if (drivers.console) |drv| {
        return drv.getchar();
    } else {
        const uart = riscv.uart_base orelse 0x10000000;
        const status_reg = @as(*volatile u8, @ptrFromInt(uart + UART.LSR));
        const rx_reg = @as(*volatile u8, @ptrFromInt(uart + UART.RBR));
        if (status_reg.* & UART.LSR_DR != 0) {
            return @as(i16, rx_reg.*);
        }
    }
    return -1;
}

fn acquireConsole() *ConsoleState {
    const hart_id = riscv.readMhartid();
    const self_id = hart_id + 1; // 1-indexed so 0 represents unowned
    const cpu_idx = if (hart_id < MAX_CPUS) hart_id else 0;

    if (@atomicLoad(usize, &console_lock_owner, .seq_cst) == self_id) {
        console_lock_recursion[cpu_idx] += 1;
    } else {
        const prev_ms = global_console_state.lock.lock();
        @atomicStore(usize, &console_lock_owner, self_id, .seq_cst);
        console_lock_saved_mstatus[cpu_idx] = prev_ms;
        console_lock_recursion[cpu_idx] = 1;
    }
    return &global_console_state.data;
}

fn releaseConsole() void {
    const hart_id = riscv.readMhartid();
    const self_id = hart_id + 1;
    const cpu_idx = if (hart_id < MAX_CPUS) hart_id else 0;

    if (@atomicLoad(usize, &console_lock_owner, .seq_cst) == self_id) {
        console_lock_recursion[cpu_idx] -= 1;
        if (console_lock_recursion[cpu_idx] == 0) {
            const saved_ms = console_lock_saved_mstatus[cpu_idx];
            @atomicStore(usize, &console_lock_owner, 0, .seq_cst);
            global_console_state.lock.unlock(saved_ms);
        }
    }
}

// Drains characters from output queue to the physical console
fn drainQueuesInternal(state: *ConsoleState) void {
    while (state.output_queue.pop()) |c| {
        hw_putchar(c);
    }
}

// Releases our spinlocks immediately when a crash is caught, enabling diagnostic prints.
pub fn releaseLocksForCrash() void {
    panic_mode = true;
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

fn basicDrain(_: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
    var total: usize = 0;

    if (panic_mode) {
        for (data) |buf| {
            for (buf) |c| hw_putchar(c);
            total += buf.len;
        }
        if (data.len > 0 and splat > 0) {
            const last = data[data.len - 1];
            var i: usize = 0;
            while (i < splat - 1) : (i += 1) {
                for (last) |c| hw_putchar(c);
                total += last.len;
            }
        }
        return total;
    }

    const state = acquireConsole();
    defer releaseConsole();

    for (data) |buf| {
        for (buf) |c| {
            _ = state.output_queue.push(c);
        }
        total += buf.len;
    }
    if (data.len > 0 and splat > 0) {
        const last = data[data.len - 1];
        var i: usize = 0;
        while (i < splat - 1) : (i += 1) {
            for (last) |c| {
                _ = state.output_queue.push(c);
            }
            total += last.len;
        }
    }
    drainQueuesInternal(state);
    return total;
}

pub fn printf(comptime format: []const u8, args: anytype) void {
    if (panic_mode) {
        basic_writer.print(format, args) catch {};
        return;
    }
    _ = acquireConsole();
    defer releaseConsole();
    basic_writer.print(format, args) catch {};
}

pub fn putchar(c: u8) void {
    if (panic_mode) {
        hw_putchar(c);
        return;
    }
    const state = acquireConsole();
    defer releaseConsole();
    _ = state.output_queue.push(c);
    drainQueuesInternal(state);
}

pub fn write(s: []const u8) void {
    if (panic_mode) {
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
    if (panic_mode) {
        return hw_getchar();
    }
    const state = acquireConsole();
    defer releaseConsole();

    if (state.stdin_queue.pop()) |c| {
        return c;
    }

    return hw_getchar();
}

// ----------------------- unit tests ---------------------

test "debug console circular queue" {
    const testing = std.testing;
    var q = GenericQueue(u8, 16){};
    try testing.expect(q.isEmpty());
    try testing.expect(q.pop() == null);

    try testing.expect(q.push('A'));
    try testing.expect(!q.isEmpty());
    try testing.expect(q.pop() == 'A');
    try testing.expect(q.isEmpty());
}
