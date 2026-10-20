// Diosix Catalog Table/JSON Formatting & SHA-256 Digest Helpers.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const catalog = @import("../catalog.zig");
const common = @import("../common.zig");
const CatalogEntry = catalog.CatalogEntry;

/// Longest decimal rendering of a usize (2^64 - 1 has 20 digits).
const MAX_USIZE_DIGITS: usize = 20;

/// Room for the "<vcpus>c/<ram>M/<disk>G" spec: three numbers of at most
/// `MAX_USIZE_DIGITS` digits plus the "c/", "M/" and "G" separators.
pub const SPEC_BYTES: usize = 3 * MAX_USIZE_DIGITS + 5;

const TABLE_HEADER =
    "Catalog ID         Tier      OS family  Format   " ++
    "Default spec        Description\n" ++
    "---------------------------------------------------" ++
    "-----------------------------------------------------------\n";

/// Computes the lowercase 64-character SHA-256 hex digest of `data`.
pub fn computeSha256Hex(
    data: []const u8,
    out_hex: *[catalog.SHA256_HEX_LEN]u8,
) []const u8 {
    return common.sha256Hex(data, out_hex);
}

/// Renders the default "<vcpus>c/<ram>M/<disk>G" spec column for `e`.
pub fn formatSpec(buf: *[SPEC_BYTES]u8, e: CatalogEntry) []const u8 {
    // SPEC_BYTES covers three maximal usize values, so this cannot fail.
    return std.fmt.bufPrint(buf, "{d}c/{d}M/{d}G", .{
        e.default_vcpus,
        e.default_ram_mb,
        e.default_disk_mb / 1024,
    }) catch unreachable;
}

/// Writes `entries` as a human-readable table following the Diosix
/// sentence-case style guide. Nothing is truncated: a failure comes only from
/// the writer itself.
pub fn writeCatalogTable(
    w: *std.Io.Writer,
    entries: []const CatalogEntry,
) std.Io.Writer.Error!void {
    try w.writeAll(TABLE_HEADER);
    for (entries) |e| {
        var spec_buf: [SPEC_BYTES]u8 = undefined;
        const spec = formatSpec(&spec_buf, e);
        try w.print(
            "{s:<18} {s:<9} {s:<10} {s:<8} {s:<19} {s}\n",
            .{ e.id, e.tier, e.os_family, e.format, spec, e.title },
        );
    }
}

/// Writes `entries` as deterministic JSON for Operator Agents. Nothing is
/// truncated: a failure comes only from the writer itself.
pub fn writeCatalogJson(
    w: *std.Io.Writer,
    entries: []const CatalogEntry,
) std.Io.Writer.Error!void {
    try w.writeAll("{\"catalog\":[");
    for (entries, 0..) |e, idx| {
        const sep: []const u8 = if (idx > 0) "," else "";
        const item_fmt =
            "{s}{{\"id\":\"{s}\",\"alias\":\"{s}\",\"tier\":\"{s}\"," ++
            "\"os_family\":\"{s}\",\"format\":\"{s}\",\"arch\":\"{s}\"," ++
            "\"vcpus\":{d},\"ram_mb\":{d},\"disk_mb\":{d}," ++
            "\"filename\":\"{s}\",\"url\":\"{s}\",\"sha256\":\"{s}\"}}";
        try w.print(item_fmt, .{
            sep,              e.id,              e.alias,    e.tier,
            e.os_family,      e.format,          e.arch,     e.default_vcpus,
            e.default_ram_mb, e.default_disk_mb, e.filename, e.url,
            e.sha256,
        });
    }
    try w.writeAll("]}\n");
}

/// Formats the official Guest OS & Steward catalog as a human-readable table
/// into the caller-supplied `buf`. Output that does not fit `buf` is cut off;
/// use `writeCatalogTable` where the complete table is required.
pub fn formatCatalogTable(buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    writeCatalogTable(&w, &catalog.OFFICIAL_CATALOG) catch {};
    return w.buffered();
}

/// Formats the official Guest OS & Steward catalog as deterministic JSON into
/// the caller-supplied `buf`. Output that does not fit `buf` is cut off; use
/// `writeCatalogJson` where the complete document is required.
pub fn formatCatalogJson(buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    writeCatalogJson(&w, &catalog.OFFICIAL_CATALOG) catch {};
    return w.buffered();
}

test "catalog/format: formats catalog table and JSON" {
    std.testing.refAllDecls(@This());
    const allocator = std.testing.allocator;

    var table_aw: std.Io.Writer.Allocating = .init(allocator);
    defer table_aw.deinit();
    try writeCatalogTable(&table_aw.writer, &catalog.OFFICIAL_CATALOG);
    const table = table_aw.written();
    try std.testing.expect(std.mem.startsWith(u8, table, "Catalog ID"));
    for (catalog.OFFICIAL_CATALOG) |e| {
        try std.testing.expect(std.mem.indexOf(u8, table, e.id) != null);
    }

    var json_aw: std.Io.Writer.Allocating = .init(allocator);
    defer json_aw.deinit();
    try writeCatalogJson(&json_aw.writer, &catalog.OFFICIAL_CATALOG);
    const json = json_aw.written();
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"catalog\":["));
    try std.testing.expect(std.mem.endsWith(u8, json, "]}\n"));
    for (catalog.OFFICIAL_CATALOG) |e| {
        try std.testing.expect(std.mem.indexOf(u8, json, e.sha256) != null);
    }
}

const TEST_CATALOG_BUF_BYTES: usize = 8192;

test "catalog/format: fixed-buffer wrappers match the writers" {
    const allocator = std.testing.allocator;
    var buf: [TEST_CATALOG_BUF_BYTES]u8 = undefined;

    var table_aw: std.Io.Writer.Allocating = .init(allocator);
    defer table_aw.deinit();
    try writeCatalogTable(&table_aw.writer, &catalog.OFFICIAL_CATALOG);
    const table = formatCatalogTable(&buf);
    try std.testing.expectEqualStrings(table_aw.written(), table);

    var json_aw: std.Io.Writer.Allocating = .init(allocator);
    defer json_aw.deinit();
    try writeCatalogJson(&json_aw.writer, &catalog.OFFICIAL_CATALOG);
    const json = formatCatalogJson(&buf);
    try std.testing.expectEqualStrings(json_aw.written(), json);

    var tiny: [16]u8 = undefined;
    try std.testing.expect(formatCatalogJson(&tiny).len <= tiny.len);
}

test "catalog/format: formatSpec fits maximal values" {
    var buf: [SPEC_BYTES]u8 = undefined;
    var e = catalog.OFFICIAL_CATALOG[0];
    try std.testing.expectEqualStrings("2c/512M/1G", formatSpec(&buf, e));
    e.default_vcpus = std.math.maxInt(usize);
    e.default_ram_mb = std.math.maxInt(usize);
    e.default_disk_mb = std.math.maxInt(usize);
    try std.testing.expect(formatSpec(&buf, e).len <= SPEC_BYTES);
}
