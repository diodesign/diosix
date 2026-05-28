// Debug output for the hypervisor
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const Writer = std.Io.Writer;
const atomic = @import("atomic.zig");
const pcore = @import("pcore.zig");
const riscv = @import("riscv.zig");

const basic_writer_vtable = Writer.VTable{
    .drain = basicDrain,
    .flush = Writer.noopFlush,
};

var basic_writer = Writer{
    .vtable = &basic_writer_vtable,
    .buffer = &.{}, // unbuffered
};

var basic_writer_lock = atomic.NamedSpinLock.init("Global basic debug writer lock");
var current_owner: usize = 0; // Stores @intFromPtr(pcpu) of the owner
var line_start: bool = true;
pub var last_reader_guest_id: ?usize = null;

pub extern fn hw_putchar(c: u8) void;
extern fn hw_getchar() i16;

fn basicDrain(_: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
    var total: usize = 0;
    for (data) |buf| {
        for (buf) |c| writeCharInternal(c);
        total += buf.len;
    }
    // handle splat for the last buffer
    if (data.len > 0 and splat > 0) {
        const last = data[data.len - 1];
        var i: usize = 0;
        while (i < splat - 1) : (i += 1) {
            for (last) |c| writeCharInternal(c);
            total += last.len;
        }
    }
    return total;
}

fn writeCharInternal(c: u8) void {
    hw_putchar(c);
    line_start = (c == '\n');
}

fn writePrefix(source_id: ?usize) void {
    if (line_start or (source_id != null and last_reader_guest_id != source_id)) {
        if (!line_start) {
            hw_putchar('\n');
            line_start = true;
        }
        if (source_id) |id| {
            // Write "[VM {id}] "
            hw_putchar('[');
            hw_putchar('V');
            hw_putchar('M');
            hw_putchar(' ');

            // Simplistic decimal print for ID
            if (id == 0) {
                hw_putchar('0');
            } else {
                var val = id;
                var buf: [20]u8 = undefined;
                var i: usize = 0;
                while (val > 0) {
                    buf[i] = @intCast('0' + (val % 10));
                    val /= 10;
                    i += 1;
                }
                while (i > 0) {
                    i -= 1;
                    hw_putchar(buf[i]);
                }
            }
            hw_putchar(']');
            hw_putchar(' ');
        } else {
            // Hypervisor prefix
            hw_putchar('[');
            hw_putchar('H');
            hw_putchar('V');
            hw_putchar(']');
            hw_putchar(' ');
        }
        line_start = false;
    }
}

pub fn printf(comptime format: []const u8, args: anytype) void {
    const pcpu = pcore.this();
    const lock_already_held = (current_owner == @intFromPtr(pcpu));

    if (!lock_already_held) {
        basic_writer_lock.lock();
        current_owner = @intFromPtr(pcpu);
    }
    defer {
        if (!lock_already_held) {
            current_owner = 0;
            basic_writer_lock.unlock();
        }
    }

    writePrefix(null);
    basic_writer.print(format, args) catch {};
}

pub fn putchar(c: u8) void {
    const pcpu = pcore.this();
    const lock_already_held = (current_owner == @intFromPtr(pcpu));

    if (!lock_already_held) {
        basic_writer_lock.lock();
        current_owner = @intFromPtr(pcpu);
    }
    defer {
        if (!lock_already_held) {
            current_owner = 0;
            basic_writer_lock.unlock();
        }
    }

    writePrefix(null);
    writeCharInternal(c);
}

pub fn putcharFromGuest(source_id: usize, c: u8) void {
    const pcpu = pcore.this();
    const lock_already_held = (current_owner == @intFromPtr(pcpu));

    if (!lock_already_held) {
        basic_writer_lock.lock();
        current_owner = @intFromPtr(pcpu);
    }
    defer {
        if (!lock_already_held) {
            current_owner = 0;
            basic_writer_lock.unlock();
        }
    }

    writePrefix(source_id);
    writeCharInternal(c);
}

pub fn getchar(source_id: usize) i16 {
    // Only allow the designated reader guest to read from the hardware console.
    // Others receive -1 (no data).
    if (last_reader_guest_id == null or last_reader_guest_id.? != source_id) return -1;

    const pcpu = pcore.this();
    const lock_already_held = (current_owner == @intFromPtr(pcpu));

    if (!lock_already_held) {
        basic_writer_lock.lock();
        current_owner = @intFromPtr(pcpu);
    }
    defer {
        if (!lock_already_held) {
            current_owner = 0;
            basic_writer_lock.unlock();
        }
    }

    return hw_getchar();
}
