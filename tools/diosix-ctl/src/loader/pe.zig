// Guest Offline Catalog Fallback & Shim Payload Staging Helpers.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const catalog = @import("../catalog.zig");
const common = @import("../common.zig");
const sysconfig = @import("../sysconfig.zig");

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

/// Copies a pre-built guest ELF or ISO9660 image from `/var/lib/diosix` or
/// `/boot` when offline catalog seeding is requested.
pub fn seedOfflineCatalogFallback(
    entry: catalog.CatalogEntry,
    dest_path: []const u8,
) bool {
    const FormatType = enum { elf, iso9660 };
    const fmt = std.meta.stringToEnum(FormatType, entry.format) orelse
        return false;
    const elf_paths = [_][]const u8{
        sysconfig.DEFAULT_GUEST_IMAGE_PATH,
        sysconfig.FALLBACK_GUEST_IMAGE_PATH,
    };
    const iso_paths = [_][]const u8{sysconfig.FALLBACK_GUEST_ISO_PATH};
    const candidates: []const []const u8 = switch (fmt) {
        .elf => &elf_paths,
        .iso9660 => &iso_paths,
    };
    for (candidates) |cand| {
        if (common.readBinaryFile(cand, common.MAX_ELF_FILE_SIZE)) |data| {
            defer common.unmapBinaryFile(data);
            if (common.writeFile(dest_path, data)) |_| {
                return true;
            } else |_| {}
        } else |_| {}
    }
    return false;
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
