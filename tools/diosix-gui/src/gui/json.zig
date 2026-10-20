// JSON string escaping for the Diosix GUI semantic state export.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

/// Worst-case growth when escaping one byte: '"' and '\' become two bytes.
const MAX_ESCAPED_BYTES_PER_CHAR: usize = 2;

/// Escape '"' and '\' in an input string for safe JSON emission. Bytes
/// outside printable ASCII (0x20..0x7e) are dropped, as they cannot appear
/// in a valid OSK string. The result is never truncated; the caller owns
/// it and must free it with `allocator`.
pub fn escapeStr(
    allocator: std.mem.Allocator,
    raw: []const u8,
) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(
        allocator,
        raw.len * MAX_ESCAPED_BYTES_PER_CHAR,
    );
    for (raw) |c| {
        if (c == '"' or c == '\\') {
            out.appendAssumeCapacity('\\');
            out.appendAssumeCapacity(c);
        } else if (c >= 0x20 and c <= 0x7e) {
            out.appendAssumeCapacity(c);
        }
    }
    return out.toOwnedSlice(allocator);
}

test "escapeStr escapes quotes and backslashes" {
    const out = try escapeStr(std.testing.allocator, "a\"b\\c");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a\\\"b\\\\c", out);
}

test "escapeStr drops control and non-ascii bytes" {
    const out = try escapeStr(std.testing.allocator, "x\n\x01\xffy");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("xy", out);
}

test "escapeStr never truncates long input" {
    const LONG_INPUT_BYTES: usize = 1000;
    const raw = try std.testing.allocator.alloc(u8, LONG_INPUT_BYTES);
    defer std.testing.allocator.free(raw);
    @memset(raw, '"');
    const out = try escapeStr(std.testing.allocator, raw);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(
        LONG_INPUT_BYTES * MAX_ESCAPED_BYTES_PER_CHAR,
        out.len,
    );
    try std.testing.expectEqualStrings("\\\"\\\"", out[out.len - 4 ..]);
}

test "escapeStr of empty input is empty" {
    const out = try escapeStr(std.testing.allocator, "");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test {
    std.testing.refAllDecls(@This());
}
