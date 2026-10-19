// Diosix Catalog Table/JSON Formatting & SHA-256 Digest Helpers.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const catalog = @import("../catalog.zig");
const common = @import("../common.zig");
const CatalogEntry = catalog.CatalogEntry;

/// Computes the lowercase 64-character SHA-256 hex digest of `data`.
pub fn computeSha256Hex(
    data: []const u8,
    out_hex: *[catalog.SHA256_HEX_LEN]u8,
) []const u8 {
    return common.sha256Hex(data, out_hex);
}

/// Formats `entries` as a human-readable table following the Diosix
/// sentence-case style guide.
pub fn formatCatalogTableFromSlice(
    buf: []u8,
    entries: []const CatalogEntry,
) []const u8 {
    var pos: usize = 0;
    const header =
        "Catalog ID         Tier      OS family  Format   " ++
        "Default spec        Description\n" ++
        "---------------------------------------------------" ++
        "-----------------------------------------------------------\n";
    if (header.len > buf.len) return "";
    @memcpy(buf[0..header.len], header);
    pos += header.len;

    for (entries) |e| {
        var spec_buf: [32]u8 = undefined;
        const spec = std.fmt.bufPrint(&spec_buf, "{d}c/{d}M/{d}G", .{
            e.default_vcpus,
            e.default_ram_mb,
            e.default_disk_mb / 1024,
        }) catch "1c/512M/1G";

        const line = std.fmt.bufPrint(
            buf[pos..],
            "{s:<18} {s:<9} {s:<10} {s:<8} {s:<19} {s}\n",
            .{ e.id, e.tier, e.os_family, e.format, spec, e.title },
        ) catch break;
        pos += line.len;
    }
    return buf[0..pos];
}

/// Formats the official Guest OS & Steward catalog as a human-readable table.
pub fn formatCatalogTable(buf: []u8) []const u8 {
    return formatCatalogTableFromSlice(buf, &catalog.OFFICIAL_CATALOG);
}

/// Formats `entries` as deterministic JSON for Operator Agents.
pub fn formatCatalogJsonFromSlice(
    buf: []u8,
    entries: []const CatalogEntry,
) []const u8 {
    var pos: usize = 0;
    const prefix = "{\"catalog\":[";
    if (prefix.len > buf.len) return "";
    @memcpy(buf[0..prefix.len], prefix);
    pos += prefix.len;
    for (entries, 0..) |e, idx| {
        const sep: []const u8 = if (idx > 0) "," else "";
        const item_fmt =
            "{s}{{\"id\":\"{s}\",\"alias\":\"{s}\",\"tier\":\"{s}\"," ++
            "\"os_family\":\"{s}\",\"format\":\"{s}\",\"arch\":\"{s}\"," ++
            "\"vcpus\":{d},\"ram_mb\":{d},\"disk_mb\":{d}," ++
            "\"filename\":\"{s}\",\"url\":\"{s}\",\"sha256\":\"{s}\"}}";
        const item = std.fmt.bufPrint(buf[pos..], item_fmt, .{
            sep,              e.id,              e.alias,    e.tier,
            e.os_family,      e.format,          e.arch,     e.default_vcpus,
            e.default_ram_mb, e.default_disk_mb, e.filename, e.url,
            e.sha256,
        }) catch break;
        pos += item.len;
    }
    const suffix = "]}\n";
    if (pos + suffix.len <= buf.len) {
        @memcpy(buf[pos .. pos + suffix.len], suffix);
        pos += suffix.len;
    }
    return buf[0..pos];
}

/// Formats the official Guest OS & Steward catalog as deterministic JSON.
pub fn formatCatalogJson(buf: []u8) []const u8 {
    return formatCatalogJsonFromSlice(buf, &catalog.OFFICIAL_CATALOG);
}

test "catalog/format: formats catalog table and JSON" {
    std.testing.refAllDecls(@This());
    var buf: [4096]u8 = undefined;
    const tbl = formatCatalogTable(&buf);
    try std.testing.expect(std.mem.indexOf(u8, tbl, "steward") != null);
    const json = formatCatalogJson(&buf);
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"catalog\":["));
}
