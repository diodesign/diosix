// Bounded UI label formatting for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

// Capacity of Icon.text_buf, the true limit of any displayed label. Icon
// keeps at most TEXT_CAP - 1 bytes of text because it stores a trailing NUL.
pub const TEXT_CAP: usize = 256;

// Size of every stack scratch buffer that holds a label before it is copied
// into an Icon. Icon.setText cannot keep more than TEXT_CAP - 1 bytes, so a
// larger scratch buffer could never be displayed and a smaller one would
// truncate text that the Icon could have shown.
pub const LABEL_BUF_BYTES: usize = TEXT_CAP;

// Format a label into buf. When the result does not fit, deliberately return
// the longest prefix that does fit instead of an empty or placeholder string.
// The returned slice aliases buf and is empty only if buf or the output is.
pub fn fmtLabel(
    buf: []u8,
    comptime fmt: []const u8,
    args: anytype,
) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    // WriteFailed means buf is full: keep whatever was written so far.
    w.print(fmt, args) catch {};
    return w.buffered();
}

test "fmtLabel formats text that fits" {
    var buf: [LABEL_BUF_BYTES]u8 = undefined;
    try std.testing.expectEqualStrings(
        "4 x RV64GC",
        fmtLabel(&buf, "{d} x {s}", .{ 4, "RV64GC" }),
    );
    try std.testing.expectEqualStrings("", fmtLabel(&buf, "", .{}));
}

test "fmtLabel fills the buffer exactly without truncating" {
    var buf: [5]u8 = undefined;
    try std.testing.expectEqualStrings(
        "abcde",
        fmtLabel(&buf, "{s}", .{"abcde"}),
    );
}

test "fmtLabel truncates to the longest prefix on overflow" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings(
        "diosix 2",
        fmtLabel(&buf, "diosix {d}.{d}", .{ 26, 1 }),
    );
    try std.testing.expectEqualStrings(
        "abcdefgh",
        fmtLabel(&buf, "{s}", .{"abcdefghijklmnop"}),
    );
    // A number that straddles the end keeps its leading digits.
    try std.testing.expectEqualStrings(
        "ab123456",
        fmtLabel(&buf, "ab{d}", .{@as(u64, 123456789)}),
    );
}

test "fmtLabel truncates a label longer than LABEL_BUF_BYTES" {
    var buf: [LABEL_BUF_BYTES]u8 = undefined;
    var long: [LABEL_BUF_BYTES * 2]u8 = undefined;
    @memset(&long, 'x');
    const out = fmtLabel(&buf, "{s}", .{&long});
    try std.testing.expectEqual(LABEL_BUF_BYTES, out.len);
    try std.testing.expectEqualStrings(long[0..LABEL_BUF_BYTES], out);
}

test "fmtLabel with a zero-length buffer returns an empty label" {
    var buf: [0]u8 = undefined;
    try std.testing.expectEqualStrings("", fmtLabel(&buf, "{d}", .{42}));
}

test {
    std.testing.refAllDecls(@This());
}
