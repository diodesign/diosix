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

/// Stages a guest-shim payload (e.g. an ISO9660 or raw kernel image) into the
/// upper half of child RAM and writes the `DOSXSHIM` header at offset 1 MiB.
pub fn stageShimPayload(
    child_ram: []u8,
    shim_payload: []const u8,
    dtb_offset: usize,
) !void {
    if (shim_payload.len == 0 or
        dtb_offset <= 0x0080_0000 or
        SHIM_HEADER_OFFSET + 24 > child_ram.len)
    {
        return;
    }

    const payload_offset = @max(
        @as(usize, 0x0040_0000),
        std.mem.alignBackward(usize, dtb_offset / 2, PAGE_ALIGN),
    );
    if (payload_offset >= dtb_offset) return error.SegmentOutOfBounds;
    const max_stage = dtb_offset - payload_offset;
    if (shim_payload.len > max_stage) return error.SegmentOutOfBounds;
    const copy_len = shim_payload.len;
    @memcpy(
        child_ram[payload_offset .. payload_offset + copy_len],
        shim_payload[0..copy_len],
    );
    const hdr = child_ram[SHIM_HEADER_OFFSET .. SHIM_HEADER_OFFSET + 24];
    std.mem.writeInt(u64, hdr[0..8], SHIM_HEADER_MAGIC, .little);
    std.mem.writeInt(u64, hdr[8..16], payload_offset, .little);
    std.mem.writeInt(u64, hdr[16..24], copy_len, .little);
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

test "loader/pe: stageShimPayload writes DOSXSHIM header when space permits" {
    std.testing.refAllDecls(@This());
    var ram: [0x0100_0000]u8 = @splat(0);
    const payload = "test-payload";
    try stageShimPayload(&ram, payload, 0x00c0_0000);
    const magic = std.mem.readInt(
        u64,
        ram[SHIM_HEADER_OFFSET..][0..8],
        .little,
    );
    try std.testing.expectEqual(SHIM_HEADER_MAGIC, magic);
}
