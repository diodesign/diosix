// Console Output Helpers: Formatted Printing That Never Truncates or Fails
// Silently.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;

/// Stack scratch space tried first when formatting a message. Messages that
/// do not fit spill to the heap instead of being truncated or dropped.
pub const STACK_FMT_BYTES: usize = 512;

const OOM_MESSAGE = "Error: Out of memory while formatting output.\n";

/// A formatted message that lives either in caller scratch space or on the
/// heap. Call `deinit` with the same allocator to release any heap copy.
pub const Formatted = struct {
    text: []const u8,
    on_heap: bool,

    pub fn deinit(self: Formatted, allocator: std.mem.Allocator) void {
        if (self.on_heap) allocator.free(@constCast(self.text));
    }
};

/// Formats into `scratch` when the result fits, otherwise into a heap
/// allocation from `allocator`. The result is never truncated.
pub fn formatSpill(
    allocator: std.mem.Allocator,
    scratch: []u8,
    comptime fmt: []const u8,
    args: anytype,
) !Formatted {
    if (std.fmt.bufPrint(scratch, fmt, args)) |text| {
        return .{ .text = text, .on_heap = false };
    } else |err| switch (err) {
        error.NoSpaceLeft => {},
    }
    const text = try allocator.print(fmt, args);
    return .{ .text = text, .on_heap = true };
}

/// Writes all of `str` to `fd`, retrying on short writes and `EINTR`.
pub fn writeAll(fd: i32, str: []const u8) void {
    var written: usize = 0;
    while (written < str.len) {
        const rc = linux.write(fd, str.ptr + written, str.len - written);
        const signed: isize = @bitCast(rc);
        if (signed == -@as(isize, @backingInt(linux.E.INTR))) continue;
        if (signed <= 0) return;
        written += @intCast(signed);
    }
}

pub fn printStr(str: []const u8) void {
    writeAll(linux.STDOUT_FILENO, str);
}

/// Formats and prints a message to standard output. Output longer than
/// `STACK_FMT_BYTES` spills to the heap; it is never truncated or dropped.
pub fn printFmt(comptime fmt: []const u8, args: anytype) void {
    const allocator = std.heap.page_allocator;
    var scratch: [STACK_FMT_BYTES]u8 = undefined;
    const msg = formatSpill(allocator, &scratch, fmt, args) catch {
        printStr(OOM_MESSAGE);
        return;
    };
    defer msg.deinit(allocator);
    printStr(msg.text);
}

test "formatSpill keeps short messages in scratch space" {
    var scratch: [STACK_FMT_BYTES]u8 = undefined;
    const msg = try formatSpill(
        std.testing.allocator,
        &scratch,
        "VM '{s}' saved",
        .{"web"},
    );
    defer msg.deinit(std.testing.allocator);
    try std.testing.expect(!msg.on_heap);
    try std.testing.expectEqualStrings("VM 'web' saved", msg.text);
}

test "formatSpill spills long messages to the heap without truncation" {
    var scratch: [16]u8 = undefined;
    const long: [100]u8 = @splat('x');
    const msg = try formatSpill(
        std.testing.allocator,
        &scratch,
        "[{s}]",
        .{&long},
    );
    defer msg.deinit(std.testing.allocator);
    try std.testing.expect(msg.on_heap);
    try std.testing.expectEqual(@as(usize, 102), msg.text.len);
    try std.testing.expectEqualStrings("[" ++ long ++ "]", msg.text);
}

test {
    std.testing.refAllDecls(@This());
}
