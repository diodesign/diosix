// Guest Shim Payload Staging Helpers.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const SHIM_HEADER_OFFSET: usize = 0x0010_0000;
pub const SHIM_HEADER_MAGIC: u64 = 0x4d49_4853_5853_4f44; // "DOSXSHIM".
pub const PAGE_ALIGN: usize = 0x1000;

/// Computes the target GPA offset in child RAM for staging a `guest-shim`
/// payload, returning `null` when no payload staging is required.
pub fn computeShimPayloadOffset(
    ram_bytes: usize,
    dtb_offset: usize,
    payload_len: usize,
) !?usize {
    if (payload_len == 0 or
        dtb_offset <= 0x0080_0000 or
        SHIM_HEADER_OFFSET + 24 > ram_bytes)
    {
        return null;
    }
    const payload_offset = @max(
        @as(usize, 0x0040_0000),
        std.mem.alignBackward(usize, dtb_offset / 2, PAGE_ALIGN),
    );
    if (payload_offset >= dtb_offset or
        payload_len > dtb_offset - payload_offset)
    {
        return error.SegmentOutOfBounds;
    }
    return payload_offset;
}

/// Writes the 24-byte `DOSXSHIM` header into the mapped header page.
pub fn writeShimHeader(
    hdr_page: []u8,
    payload_offset: usize,
    payload_len: usize,
) void {
    std.mem.writeInt(u64, hdr_page[0..8], SHIM_HEADER_MAGIC, .little);
    std.mem.writeInt(u64, hdr_page[8..16], payload_offset, .little);
    std.mem.writeInt(u64, hdr_page[16..24], payload_len, .little);
}

test "loader/pe: computeShimPayloadOffset and writeShimHeader" {
    std.testing.refAllDecls(@This());
    var hdr_page: [PAGE_ALIGN]u8 = @splat(0);
    const payload = "test-payload";
    const off = (try computeShimPayloadOffset(
        0x0100_0000,
        0x00c0_0000,
        payload.len,
    )).?;
    writeShimHeader(&hdr_page, off, payload.len);
    const magic = std.mem.readInt(u64, hdr_page[0..8], .little);
    try std.testing.expectEqual(SHIM_HEADER_MAGIC, magic);
}
