// Debug output for the hypervisor
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const Writer = std.Io.Writer;
const atomic = @import("atomic.zig");
const pcore = @import("pcore.zig");
const riscv = @import("arch/riscv64/riscv.zig");
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

const QueueEntry = struct {
    source_id: ?usize,
    char: u8,
};

const ConsoleState = struct {
    // Single shared output queue for Hypervisor and all Guest VMs (infinitely scaling)
    output_queue: GenericQueue(QueueEntry, queue_size) = .{},

    // Single shared input queue for console keyboard input
    stdin_queue: GenericQueue(u8, 256) = .{},

    // Hardware console state
    line_start: bool = true,
    active_drain_source: ?usize = null,
    active_drain_source_valid: bool = false,

    // Dynamic selected reader guest ID
    selected_reader_guest_id: ?usize = null,
};

// Global thread-safe debug console state
var global_console_state = atomic.LockPayload(ConsoleState).init("Debug console state", .{});

// Reentrant lock tracking
var console_lock_owner: usize = 0;
var console_lock_recursion: usize = 0;
var console_lock_saved_mstatus: usize = 0;

// Top-level crash bypass flag to guarantee panic messages get printed immediately
pub var panic_mode: bool = false;
// Allow designated reader guest to read from the console (compat with guest.zig)
pub var last_reader_guest_id: ?usize = null;

pub const UART = struct {
    // 16550 UART Register Offsets
    pub const RBR = 0; // Receiver Buffer Register (read)
    pub const THR = 0; // Transmitter Holding Register (write)
    pub const LSR = 5; // Line Status Register

    // LSR Bitmasks
    pub const LSR_DR = 0x01;   // Data Ready
    pub const LSR_THRE = 0x20; // Transmitter Holding Register Empty
};

pub fn hw_putchar(c: u8) void {
    if (builtin.is_test) return;
    if (drivers.console) |drv| {
        drv.putchar(c);
    } else {
        const uart = riscv.uart_base orelse 0x10000000;
        const status_reg = @as(*volatile u8, @ptrFromInt(uart + UART.LSR));
        const tx_reg = @as(*volatile u8, @ptrFromInt(uart + UART.THR));
        while (status_reg.* & UART.LSR_THRE == 0) {}
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
    const pcpu = pcore.this();
    const self_ptr = @intFromPtr(pcpu);
    if (@atomicLoad(usize, &console_lock_owner, .seq_cst) == self_ptr) {
        console_lock_recursion += 1;
    } else {
        const prev_ms = global_console_state.lock.lock();
        @atomicStore(usize, &console_lock_owner, self_ptr, .seq_cst);
        console_lock_saved_mstatus = prev_ms;
        console_lock_recursion = 1;
    }
    return &global_console_state.data;
}

fn releaseConsole() void {
    const pcpu = pcore.this();
    const self_ptr = @intFromPtr(pcpu);
    if (@atomicLoad(usize, &console_lock_owner, .seq_cst) == self_ptr) {
        console_lock_recursion -= 1;
        if (console_lock_recursion == 0) {
            const saved_ms = console_lock_saved_mstatus;
            @atomicStore(usize, &console_lock_owner, 0, .seq_cst);
            global_console_state.lock.unlock(saved_ms);
        }
    }
}

fn getColorCode(source_id: ?usize) []const u8 {
    if (source_id) |id| {
        const colors = [_][]const u8{
            "\x1b[1;32m", // Bold Green (Root VM)
            "\x1b[1;31m", // Bold Red
            "\x1b[1;33m", // Bold Yellow
            "\x1b[1;34m", // Bold Blue
            "\x1b[1;35m", // Bold Magenta
            "\x1b[1;36m", // Bold Cyan
        };
        return colors[id % colors.len];
    } else {
        return "\x1b[1;37m"; // Bold White for Hypervisor
    }
}

fn hwWriteStr(s: []const u8) void {
    for (s) |c| {
        hw_putchar(c);
    }
}

fn hwWriteDecimal(val: usize) void {
    if (val == 0) {
        hw_putchar('0');
        return;
    }
    var temp = val;
    var buf: [20]u8 = undefined;
    var i: usize = 0;
    while (temp > 0) {
        buf[i] = @intCast('0' + (temp % 10));
        temp /= 10;
        i += 1;
    }
    while (i > 0) {
        i -= 1;
        hw_putchar(buf[i]);
    }
}

// Drains characters from the single shared output queue to the UART
fn drainQueuesInternal(state: *ConsoleState) void {
    const gdb_stub = @import("gdb_stub.zig");
    if (gdb_stub.stub.gdb_connected) {
        while (state.output_queue.pop()) |_| {}
        return;
    }

    while (state.output_queue.pop()) |entry| {
        const source_id = entry.source_id;
        const c = entry.char;

        if (!state.active_drain_source_valid or state.active_drain_source != source_id) {
            hwWriteStr(getColorCode(source_id));
            state.active_drain_source = source_id;
            state.active_drain_source_valid = true;
        }

        hw_putchar(c);

        if (c == '\n') {
            hwWriteStr("\x1b[0m");
            state.active_drain_source_valid = false;
        }
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
            _ = state.output_queue.push(.{ .source_id = null, .char = c });
        }
        total += buf.len;
    }
    if (data.len > 0 and splat > 0) {
        const last = data[data.len - 1];
        var i: usize = 0;
        while (i < splat - 1) : (i += 1) {
            for (last) |c| {
                _ = state.output_queue.push(.{ .source_id = null, .char = c });
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
    _ = state.output_queue.push(.{ .source_id = null, .char = c });
    drainQueuesInternal(state);
}

pub fn putcharFromGuest(source_id: usize, c: u8) void {
    if (panic_mode) {
        hw_putchar(c);
        return;
    }
    const state = acquireConsole();
    defer releaseConsole();
    _ = state.output_queue.push(.{ .source_id = source_id, .char = c });
    drainQueuesInternal(state);
}

pub fn writeFromGuest(source_id: usize, s: []const u8) void {
    if (panic_mode) {
        for (s) |c| hw_putchar(c);
        return;
    }
    const state = acquireConsole();
    defer releaseConsole();
    for (s) |c| {
        _ = state.output_queue.push(.{ .source_id = source_id, .char = c });
    }
    drainQueuesInternal(state);
}

pub fn getchar(source_id: usize) i16 {
    if (panic_mode) {
        return hw_getchar();
    }
    const state = acquireConsole();
    defer releaseConsole();

    if (state.selected_reader_guest_id == null) {
        state.selected_reader_guest_id = last_reader_guest_id;
    }

    if (state.selected_reader_guest_id == null) {
        state.selected_reader_guest_id = source_id;
    }

    if (state.selected_reader_guest_id.? != source_id) {
        return -1;
    }

    if (state.stdin_queue.pop()) |c| {
        return c;
    }

    return hw_getchar();
}

pub fn sendInputToGuest(guest_id: usize, c: u8) void {
    if (panic_mode) return;
    const state = acquireConsole();
    defer releaseConsole();

    if (state.selected_reader_guest_id == null) {
        state.selected_reader_guest_id = last_reader_guest_id;
    }

    if (state.selected_reader_guest_id == null) {
        state.selected_reader_guest_id = guest_id;
    }

    if (state.selected_reader_guest_id.? == guest_id) {
        _ = state.stdin_queue.push(c);
    }
}

pub fn destroyGuestState(guest_id: usize) void {
    if (panic_mode) return;
    const state = acquireConsole();
    defer releaseConsole();

    if (state.selected_reader_guest_id) |reader_id| {
        if (reader_id == guest_id) {
            state.selected_reader_guest_id = null;
        }
    }
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

test "debug console colors and mapping" {
    const testing = std.testing;
    try testing.expectEqualStrings("\x1b[1;37m", getColorCode(null));
    try testing.expectEqualStrings("\x1b[1;32m", getColorCode(0));
    try testing.expectEqualStrings("\x1b[1;31m", getColorCode(1));
}
