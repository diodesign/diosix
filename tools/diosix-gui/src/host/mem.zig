// Human-readable memory size formatting for Diosix GUI host telemetry.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const label = @import("../label.zig");

pub const KIB: u64 = 1024;
pub const MIB: u64 = KIB * 1024;
pub const GIB: u64 = MIB * 1024;

// Decimal digits in the largest u64 (18446744073709551615).
pub const U64_MAX_DIGITS: usize =
    @as(usize, std.math.log10_int(@as(u64, std.math.maxInt(u64)))) + 1;

// Whole-GB digits in the largest possible value (u64 max / GIB). GB is the
// largest unit, so no scaled value has more integer digits than this.
const MAX_GB_DIGITS: usize =
    @as(usize, std.math.log10_int(@as(u64, std.math.maxInt(u64)) / GIB)) + 1;

// Longest string formatMemorySize can produce: the widest scaled form is
// "{d:.1} GB" (MAX_GB_DIGITS digits plus ".0 GB"). The plain "{d} bytes" form
// only applies below one KiB ("1023 bytes", shorter). A caller buffer of this
// size therefore never truncates.
pub const MEM_SIZE_STR_BYTES: usize = MAX_GB_DIGITS + ".0 GB".len;

const Unit = struct {
    size: u64,
    name: []const u8,
};

// Largest first: the first unit not exceeding the value is used.
const UNITS = [_]Unit{
    .{ .size = GIB, .name = "GB" },
    .{ .size = MIB, .name = "MB" },
    .{ .size = KIB, .name = "KB" },
};

// Format byte sizes into human-readable strings (bytes, KB, MB, GB).
// A buffer smaller than MEM_SIZE_STR_BYTES yields a truncated prefix.
pub fn formatMemorySize(buffer: []u8, bytes: u64) []const u8 {
    for (UNITS) |unit| {
        if (bytes < unit.size) continue;
        if (bytes % unit.size == 0) {
            return label.fmtLabel(
                buffer,
                "{d} {s}",
                .{ bytes / unit.size, unit.name },
            );
        }
        const val = @as(f64, @floatFromInt(bytes)) /
            @as(f64, @floatFromInt(unit.size));
        return label.fmtLabel(buffer, "{d:.1} {s}", .{ val, unit.name });
    }
    return label.fmtLabel(buffer, "{d} bytes", .{bytes});
}

test "formatMemorySize scales to the largest fitting unit" {
    var buf: [MEM_SIZE_STR_BYTES]u8 = undefined;
    const t = std.testing;
    try t.expectEqualStrings("0 bytes", formatMemorySize(&buf, 0));
    try t.expectEqualStrings("1023 bytes", formatMemorySize(&buf, KIB - 1));
    try t.expectEqualStrings("1 KB", formatMemorySize(&buf, KIB));
    try t.expectEqualStrings("1.5 KB", formatMemorySize(&buf, KIB + KIB / 2));
    try t.expectEqualStrings("256 KB", formatMemorySize(&buf, 256 * KIB));
    try t.expectEqualStrings("16 MB", formatMemorySize(&buf, 16 * MIB));
    try t.expectEqualStrings("15.8 MB", formatMemorySize(&buf, 16580608));
    try t.expectEqualStrings("2 GB", formatMemorySize(&buf, 2 * GIB));
    try t.expectEqualStrings("1.5 GB", formatMemorySize(&buf, GIB + GIB / 2));
}

test "formatMemorySize never truncates at MEM_SIZE_STR_BYTES" {
    var buf: [MEM_SIZE_STR_BYTES]u8 = undefined;
    const out = formatMemorySize(&buf, std.math.maxInt(u64));
    try std.testing.expectEqualStrings("17179869184.0 GB", out);
    try std.testing.expectEqual(MEM_SIZE_STR_BYTES, out.len);
}

test "formatMemorySize truncates instead of returning a placeholder" {
    var buf: [4]u8 = undefined;
    const out = formatMemorySize(&buf, 16 * MIB);
    try std.testing.expectEqualStrings("16 M", out);
    var tiny: [0]u8 = undefined;
    try std.testing.expectEqualStrings("", formatMemorySize(&tiny, 1));
}

test {
    _ = label;
    std.testing.refAllDecls(@This());
}
