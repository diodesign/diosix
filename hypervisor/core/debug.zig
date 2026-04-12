// Debug output for the hypervisor
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const Writer = std.Io.Writer;
const atomic = @import("atomic.zig");

const basic_writer_vtable = Writer.VTable{
    .drain = basicDrain,
    .flush = Writer.noopFlush,
};

var basic_writer = Writer{
    .vtable = &basic_writer_vtable,
    .buffer = &.{}, // unbuffered
};

var basic_writer_lock = atomic.NamedSpinLock.init("Global basic debug writer lock");

extern fn hw_putchar(c: u8) void;
extern fn hw_getchar() i16;

fn basicDrain(_: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
    var total: usize = 0;
    for (data) |buf| {
        for (buf) |c| hw_putchar(c);
        total += buf.len;
    }
    // handle splat for the last buffer
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

// standard printf calling convention. will block until it is able to exclusively output the text
pub fn printf(comptime format: []const u8, args: anytype) void {
    basic_writer_lock.lock();
    defer basic_writer_lock.unlock();

    basic_writer.print(format, args) catch {};
}

pub fn putchar(c: u8) void {
    basic_writer_lock.lock();
    defer basic_writer_lock.unlock();
    hw_putchar(c);
}

pub fn getchar() i16 {
    // Potentially multiple cores could be polling for input, so lock it.
    // In practice, usually only the console capsule or root VM handles input.
    basic_writer_lock.lock();
    defer basic_writer_lock.unlock();
    return hw_getchar();
}
