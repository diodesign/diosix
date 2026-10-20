// Shared CLI Output, String Formatting, and JSON Escaping Utilities.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const console = @import("../console.zig");

pub const printStr = console.printStr;
pub const printFmt = console.printFmt;

pub const JsonFlag = enum {
    @"--json",
    @"-j",
};

pub fn isJsonFlag(arg: []const u8) bool {
    return std.meta.stringToEnum(JsonFlag, arg) != null;
}

var stored_exe_name: []const u8 = "dsx";

pub fn setExeName(argv0: [*:0]const u8) void {
    const span = std.mem.span(argv0);
    const base = if (std.mem.lastIndexOfScalar(u8, span, '/')) |idx|
        span[idx + 1 ..]
    else
        span;
    if (base.len > 0) stored_exe_name = base;
}

pub fn getExeName() []const u8 {
    return stored_exe_name;
}

pub fn printApiError(action: []const u8, err: anyerror) void {
    switch (err) {
        error.PermissionDenied => printStr(
            "Error: Permission denied. Only the root user is allowed " ++
                "to communicate with the hypervisor.\n",
        ),
        error.DeviceNotFound => printStr(
            "Error: /dev/diosix not found. Ensure the diosix kernel " ++
                "driver is enabled.\n",
        ),
        error.FileNotFound => printFmt(
            "Error: {s} failed: file not found.\n",
            .{action},
        ),
        error.PathTooLong => printFmt(
            "Error: {s} failed: file path exceeds maximum length.\n",
            .{action},
        ),
        error.OutOfMemory => printFmt(
            "Error: {s} failed: out of memory.\n",
            .{action},
        ),
        else => printFmt(
            "Error: {s} failed ({s}).\n",
            .{ action, @errorName(err) },
        ),
    }
}

/// Sanitize a string for safe inclusion inside a JSON string literal.
pub fn sanitizeJsonStr(buf: []u8, raw: []const u8) []const u8 {
    var out_len: usize = 0;
    for (raw) |ch| {
        if (out_len >= buf.len) break;
        if (ch < 0x20 or ch >= 0x7f or ch == '"' or ch == '\\') continue;
        buf[out_len] = ch;
        out_len += 1;
    }
    return buf[0..out_len];
}

/// Appends `raw` to `out` with RFC 8259 JSON string escaping (without
/// surrounding double quotes).
pub fn writeJsonEscaped(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    raw: []const u8,
) !void {
    const hex_chars = "0123456789abcdef";
    for (raw) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x08 => try out.appendSlice(allocator, "\\b"),
            0x0c => try out.appendSlice(allocator, "\\f"),
            else => {
                if (ch < 0x20 or ch == 0x7f) {
                    const seq = [6]u8{
                        '\\',
                        'u',
                        '0',
                        '0',
                        hex_chars[ch >> 4],
                        hex_chars[ch & 0x0f],
                    };
                    try out.appendSlice(allocator, &seq);
                } else {
                    try out.append(allocator, ch);
                }
            },
        }
    }
}

/// Allocates and returns a JSON-escaped copy of `raw`.
pub fn escapeJsonAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try writeJsonEscaped(&out, allocator, raw);
    return out.toOwnedSlice(allocator);
}

pub fn trimAscii(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

pub fn trimWhitespace(s: []const u8) []const u8 {
    return trimAscii(s);
}

pub fn unquoteToml(raw: []const u8) []const u8 {
    var s = trimAscii(raw);
    if (std.mem.indexOfScalar(u8, s, '#')) |c_idx| {
        if (s.len == 0 or (s[0] != '"' and s[0] != '\'')) {
            s = trimAscii(s[0..c_idx]);
        } else if (std.mem.indexOfScalarPos(u8, s, 1, s[0])) |close_q| {
            if (c_idx > close_q) s = trimAscii(s[0..c_idx]);
        }
    }
    if (s.len >= 2 and
        ((s[0] == '"' and s[s.len - 1] == '"') or
            (s[0] == '\'' and s[s.len - 1] == '\'')))
    {
        return s[1 .. s.len - 1];
    }
    return s;
}

pub fn copyStr(buf: []u8, src: []const u8) []const u8 {
    const copy_len = @min(buf.len, src.len);
    @memcpy(buf[0..copy_len], src[0..copy_len]);
    return buf[0..copy_len];
}

pub fn setFixedBuf(dest: []u8, len_out: *usize, src: []const u8) void {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    len_out.* = n;
}

pub fn bytesToHex(bytes: []const u8, out: []u8) []const u8 {
    const hex_chars = "0123456789abcdef";
    const n = @min(bytes.len, out.len / 2);
    for (bytes[0..n], 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return out[0 .. n * 2];
}

pub fn sha256Hex(
    data: []const u8,
    out: *[std.crypto.hash.sha2.Sha256.digest_length * 2]u8,
) []const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return bytesToHex(&digest, out);
}

pub fn toPathZ(path: []const u8, buf: []u8) ?[:0]const u8 {
    if (path.len == 0 or path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

test "common/output: writeJsonEscaped escapes quotes, slashes, and control" {
    std.testing.refAllDecls(@This());
    const alloc = std.testing.allocator;
    const escaped = try escapeJsonAlloc(alloc, "a\"b\\c\nd\x01");
    defer alloc.free(escaped);
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\nd\\u0001", escaped);
}
