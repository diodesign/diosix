// Diosix Hypervisor Guest Management CLI — Heap Copies of Borrowed Strings.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

/// Printed when a heap allocation for command output or arguments fails.
pub const OOM_MSG = "Error: Out of memory.\n";

/// Owns heap copies of strings whose source goes away before the command
/// finishes (for example fields of an unmapped registry or manifest file).
/// Copies are never truncated and are NUL-terminated so they can also be
/// handed to `argv`-style APIs. Call `deinit` to free every copy at once.
pub const OwnedStrings = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) OwnedStrings {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *OwnedStrings) void {
        for (self.list.items) |buf| self.allocator.free(buf);
        self.list.deinit(self.allocator);
    }

    /// Copies `str` and returns the NUL-terminated copy, owned by `self`.
    pub fn dupe(self: *OwnedStrings, str: []const u8) ![:0]const u8 {
        const buf = try self.allocator.alloc(u8, str.len + 1);
        errdefer self.allocator.free(buf);
        @memcpy(buf[0..str.len], str);
        buf[str.len] = 0;
        try self.list.append(self.allocator, buf);
        return buf[0..str.len :0];
    }

    /// Formats a NUL-terminated string owned by `self`.
    pub fn print(
        self: *OwnedStrings,
        comptime fmt: []const u8,
        args: anytype,
    ) ![:0]const u8 {
        const text = try self.allocator.print(fmt, args);
        defer self.allocator.free(text);
        return self.dupe(text);
    }
};

test "owned: OwnedStrings keeps long NUL-terminated copies" {
    std.testing.refAllDecls(@This());
    var owned = OwnedStrings.init(std.testing.allocator);
    defer owned.deinit();

    const long: [5000]u8 = @splat('p');
    const a = try owned.dupe("alpha");
    const b = try owned.dupe(&long);
    try std.testing.expectEqualStrings("alpha", a);
    try std.testing.expectEqual(@as(u8, 0), a[a.len]);
    try std.testing.expectEqual(@as(usize, long.len), b.len);
    try std.testing.expectEqualStrings(&long, b);
    try std.testing.expectEqual(@as(u8, 0), b[b.len]);
}

test "owned: OwnedStrings.print formats owned strings" {
    var owned = OwnedStrings.init(std.testing.allocator);
    defer owned.deinit();

    const text = try owned.print("{d}M", .{@as(usize, 512)});
    try std.testing.expectEqualStrings("512M", text);
    try std.testing.expectEqual(@as(u8, 0), text[text.len]);
}
