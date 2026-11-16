// Freestanding Gzip Decompression Helper for Compressed Guest Kernels.
//
// Decompresses gzip-wrapped kernel images (`vmlinuz`, `vmlinuz-lts`,
// `Image.gz`) directly into a caller-supplied slice without heap allocation.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const GZIP_MAGIC_0: u8 = 0x1f;
pub const GZIP_MAGIC_1: u8 = 0x8b;
pub const GZIP_METHOD_DEFLATE: u8 = 0x08;
pub const GZIP_MIN_STREAM_BYTES: usize = 18;

pub const GzipError = error{
    InvalidGzipStream,
    DestinationOutOfBounds,
};

pub fn isGzipArchive(data: []const u8) bool {
    return data.len >= GZIP_MIN_STREAM_BYTES and
        data[0] == GZIP_MAGIC_0 and
        data[1] == GZIP_MAGIC_1 and
        data[2] == GZIP_METHOD_DEFLATE;
}

pub fn decompressIntoSlice(
    compressed: []const u8,
    out_buf: []u8,
) GzipError![]u8 {
    if (!isGzipArchive(compressed)) return error.InvalidGzipStream;
    if (out_buf.len == 0) return error.DestinationOutOfBounds;

    var in_reader: std.Io.Reader = .fixed(compressed);
    var out_writer: std.Io.Writer = .fixed(out_buf);
    var decomp: std.compress.flate.Decompress = .init(
        &in_reader,
        .gzip,
        &.{},
    );
    const written = decomp.reader.streamRemaining(&out_writer) catch |err| {
        return switch (err) {
            error.WriteFailed => error.DestinationOutOfBounds,
            else => error.InvalidGzipStream,
        };
    };
    return out_buf[0..written];
}

test "gzip: isGzipArchive and decompressIntoSlice round-trip" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;

    // Pre-encoded gzip stream containing "DIOSIX_VMLINUZ_TEST".
    const gz_sample = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x73, 0xf1, 0xf4, 0x0f, 0xf6, 0x8c,
        0x88, 0x0f, 0xf3, 0xf5, 0xf1, 0xf4, 0x0b, 0x8d,
        0x8a, 0x0f, 0x71, 0x0d, 0x0e, 0x01, 0x00, 0x9b,
        0x2e, 0x0f, 0xc3, 0x13, 0x00, 0x00, 0x00,
    };
    try testing.expect(isGzipArchive(&gz_sample));
    try testing.expect(!isGzipArchive("not-gzip"));

    var out: [64]u8 = @splat(0);
    const plain = try decompressIntoSlice(&gz_sample, &out);
    try testing.expectEqualStrings("DIOSIX_VMLINUZ_TEST", plain);

    var tiny: [8]u8 = @splat(0);
    try testing.expectError(
        error.DestinationOutOfBounds,
        decompressIntoSlice(&gz_sample, &tiny),
    );
}
