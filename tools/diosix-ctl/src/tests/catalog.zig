// Unit Tests for Diosix Remote Guest OS & Autonomic Steward VM Catalog.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const testing = std.testing;
const catalog = @import("../catalog.zig");

const SHA256_HEX_LEN = catalog.SHA256_HEX_LEN;
const CatalogEntry = catalog.CatalogEntry;
const OFFICIAL_CATALOG = catalog.OFFICIAL_CATALOG;
const TEST_PARSED_CAP: usize = 4;
const TEST_TABLE_BUF_LEN: usize = 2048;
const TEST_JSON_BUF_LEN: usize = 4096;
const findEntry = catalog.findEntry;
const findEntryInSlice = catalog.findEntryInSlice;
const isValidImageName = catalog.isValidImageName;
const isValidUrl = catalog.isValidUrl;
const computeSha256Hex = catalog.computeSha256Hex;
const verifySha256Hex = catalog.verifySha256Hex;
const hasPinnedSha256 = catalog.hasPinnedSha256;
const parseCatalogToml = catalog.parseCatalogToml;
const inferImageMetadata = catalog.inferImageMetadata;
const formatCatalogTable = catalog.formatCatalogTable;
const formatCatalogJson = catalog.formatCatalogJson;

test "findEntry resolves Steward and S/U-mode Guest OS catalog entries" {
    const steward = findEntry("steward").?;
    try testing.expectEqualStrings("steward", steward.tier);
    try testing.expectEqualStrings("elf", steward.format);
    try testing.expectEqualStrings("steward.elf", steward.filename);

    const debian = findEntry("debian").?;
    try testing.expectEqualStrings("debian-riscv64", debian.id);
    try testing.expectEqualStrings("leaf", debian.tier);
    try testing.expectEqualStrings("iso9660", debian.format);

    const freebsd = findEntry("freebsd-riscv64").?;
    try testing.expectEqualStrings("freebsd", freebsd.os_family);

    try testing.expect(findEntry("nonexistent-os") == null);
}

test "isValidImageName and isValidUrl security sanitization" {
    try testing.expect(isValidImageName("steward.elf"));
    try testing.expect(isValidImageName("debian-12-riscv64.iso"));
    try testing.expect(!isValidImageName(""));
    try testing.expect(!isValidImageName("../etc/passwd"));
    try testing.expect(!isValidImageName("/etc/shadow"));
    try testing.expect(!isValidImageName("-rf"));
    try testing.expect(!isValidImageName("bad;rm -rf /"));

    try testing.expect(
        isValidUrl("https://images.diosix.org/26.2/riscv64/steward.elf"),
    );
    try testing.expect(isValidUrl("http://mirror.example.org/freebsd.iso"));
    try testing.expect(!isValidUrl("ftp://mirror.example.org/file.iso"));
    try testing.expect(!isValidUrl("https://example.org/bad\"url"));
    try testing.expect(!isValidUrl("https://example.org/bad;id"));
    try testing.expect(!isValidUrl("https://example.org/bad url"));
}

test "computeSha256Hex, verifySha256Hex, and hasPinnedSha256" {
    var hex: [SHA256_HEX_LEN]u8 = undefined;
    const empty_sha = computeSha256Hex("", &hex);
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        empty_sha,
    );
    try testing.expect(verifySha256Hex(
        "",
        "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855",
    ));
    try testing.expect(!verifySha256Hex("tampered", empty_sha));
    try testing.expect(!verifySha256Hex("", "not-a-valid-sha256"));

    for (OFFICIAL_CATALOG) |entry| {
        try testing.expect(hasPinnedSha256(entry));
        try testing.expect(isValidUrl(entry.url));
        try testing.expect(isValidImageName(entry.filename));
    }
}

test "parseCatalogToml and inferImageMetadata align image types" {
    const sample_toml =
        \\# Custom repository config
        \\[[image]]
        \\id = "custom-bsd"
        \\alias = "cbsd"
        \\title = "Custom BSD RISC-V 64-bit installer"
        \\tier = "leaf"
        \\os_family = "freebsd"
        \\format = "iso9660"
        \\arch = "riscv64"
        \\default_vcpus = 4
        \\default_ram_mb = 2048
        \\default_disk_mb = 8192
        \\filename = "custom-bsd-riscv64.iso"
        \\url = "https://mirror.example.org/custom-bsd-riscv64.iso"
        \\
    ++ "sha256 = \"0123456789abcdef0123456789abcdef" ++
        "0123456789abcdef0123456789abcdef\"\n";
    var parsed: [TEST_PARSED_CAP]CatalogEntry = undefined;
    const count = parseCatalogToml(sample_toml, &parsed);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqualStrings("custom-bsd", parsed[0].id);
    try testing.expectEqual(@as(usize, 4), parsed[0].default_vcpus);
    try testing.expect(findEntryInSlice(parsed[0..count], "cbsd") != null);

    const meta1 = inferImageMetadata(
        "diosix-base-linux.elf",
        false,
        &OFFICIAL_CATALOG,
    );
    try testing.expectEqualStrings("leaf", meta1.tier);
    try testing.expectEqualStrings("linux", meta1.os_family);
    try testing.expectEqualStrings("elf", meta1.format);

    const meta2 = inferImageMetadata("steward.elf", false, &OFFICIAL_CATALOG);
    try testing.expectEqualStrings("steward", meta2.tier);
    try testing.expectEqualStrings("diosix", meta2.os_family);
    try testing.expectEqualStrings("elf", meta2.format);
}

test "formatCatalogTable and formatCatalogJson follow sentence-case style" {
    var table_buf: [TEST_TABLE_BUF_LEN]u8 = undefined;
    const tbl = formatCatalogTable(&table_buf);
    try testing.expect(std.mem.indexOf(u8, tbl, "OS family") != null);
    try testing.expect(std.mem.indexOf(u8, tbl, "Default spec") != null);
    try testing.expect(std.mem.indexOf(u8, tbl, "steward") != null);
    try testing.expect(std.mem.indexOf(u8, tbl, "debian-riscv64") != null);
    try testing.expect(std.mem.indexOf(u8, tbl, "freebsd-riscv64") != null);

    var json_buf: [TEST_JSON_BUF_LEN]u8 = undefined;
    const js = formatCatalogJson(&json_buf);
    try testing.expect(std.mem.startsWith(u8, js, "{\"catalog\":["));
    try testing.expect(
        std.mem.indexOf(u8, js, "\"id\":\"steward\"") != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, js, "\"tier\":\"steward\"") != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, js, "\"id\":\"openbsd-riscv64\"") != null,
    );
    testing.refAllDecls(@This());
}
