// debugging routines, mostly output to a suitable channel
//
// Copyright (c) 2024 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const writer = std.io.Writer;
const fmt = std.fmt;

const atomic = @import("atomic.zig");

const basic_writer = writer(void, error{}, basic_print){ .context = {} };
var basic_writer_lock = atomic.NamedSpinLock.init("Global basic debug writer lock");

extern fn hw_putchar(c: u8) void;

fn basic_print(_: void, string: []const u8) error{}!usize {
    for (string) |c| {
        hw_putchar(c);
    }

    return string.len;
}

pub fn printf(comptime format: []const u8, args: anytype) void {
    basic_writer_lock.lock();
    defer basic_writer_lock.unlock();

    fmt.format(basic_writer, format, args) catch unreachable;
}
