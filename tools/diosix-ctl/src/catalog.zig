// Diosix Remote Guest OS & Autonomic Steward VM Catalog.
//
// Manages discovery, URL/filename sanitization, and SHA-256 integrity
// verification for remote S/U-mode Guest OS installer images (Linux, FreeBSD,
// OpenBSD, NetBSD) and the on-demand Tier-1 Autonomic Steward VM appliance.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const common = @import("common.zig");
const sysconfig = @import("sysconfig.zig");

pub const SHA256_HEX_LEN: usize = 64;
pub const MAX_URL_LEN: usize = 1024;
pub const MAX_IMAGE_NAME_LEN: usize = 128;

pub const CatalogEntry = struct {
    id: []const u8,
    alias: []const u8,
    title: []const u8,
    tier: []const u8, // "steward" (Tier 1) or "leaf" (Tier 2).
    os_family: []const u8,
    format: []const u8, // "elf" or "iso9660".
    arch: []const u8,
    default_vcpus: usize,
    default_ram_mb: usize,
    default_disk_mb: usize,
    filename: []const u8,
    url: []const u8,
    sha256: []const u8,
};

pub const DEFAULT_CATALOG_CONFIG_PATH = sysconfig.DEFAULT_CATALOG_CONFIG_PATH;
pub const MAX_CATALOG_ENTRIES: usize = 32;

pub const OFFICIAL_CATALOG = [_]CatalogEntry{
    .{
        .id = "diosix-base-linux",
        .alias = "diosix-linux",
        .title = "Diosix Base Linux",
        .tier = "leaf",
        .os_family = "linux",
        .format = "elf",
        .arch = "riscv64",
        .default_vcpus = 2,
        .default_ram_mb = 512,
        .default_disk_mb = 1024,
        .filename = "diosix-base-linux.elf",
        .url = "file://" ++ sysconfig.DEFAULT_GUEST_IMAGE_PATH,
        .sha256 = "23481c66ee9d3cdc46b972c35d9ac29c" ++
            "428124ea7e51d1deb5904587bc86c5a3",
    },
    .{
        .id = "linux-cli",
        .alias = "cli",
        .title = "Diosix Linux CLI",
        .tier = "leaf",
        .os_family = "linux",
        .format = "elf",
        .arch = "riscv64",
        .default_vcpus = 2,
        .default_ram_mb = 256,
        .default_disk_mb = 1024,
        .filename = "linux-cli.elf",
        .url = "file://" ++ sysconfig.DEFAULT_CLI_IMAGE_PATH,
        .sha256 = "1def75165762557dfbd46b86183839c1" ++
            "62f312c9688e5545ae3ef585903ddccd",
    },
    .{
        .id = "linux-desktop",
        .alias = "desktop",
        .title = "Diosix Linux Desktop (Weston)",
        .tier = "leaf",
        .os_family = "linux",
        .format = "elf",
        .arch = "riscv64",
        .default_vcpus = 2,
        .default_ram_mb = 512,
        .default_disk_mb = 1024,
        .filename = "linux-desktop.elf",
        .url = "file://" ++ sysconfig.DEFAULT_DESKTOP_IMAGE_PATH,
        .sha256 = "6a461802451bb2183fee369d783326c9" ++
            "d6740863ee5118c300470068822b2e57",
    },
    .{
        .id = "steward",
        .alias = "steward-riscv64",
        .title = "Diosix tier-1 autonomic steward VM (whisper collective node)",
        .tier = "steward",
        .os_family = "diosix",
        .format = "elf",
        .arch = "riscv64",
        .default_vcpus = 2,
        .default_ram_mb = 512,
        .default_disk_mb = 1024,
        .filename = "steward.elf",
        .url = "file://" ++ sysconfig.DEFAULT_GUEST_IMAGE_PATH,
        .sha256 = "23481c66ee9d3cdc46b972c35d9ac29c" ++
            "428124ea7e51d1deb5904587bc86c5a3",
    },
    .{
        .id = "debian-riscv64",
        .alias = "debian",
        .title = "Debian 13 (Trixie) RISC-V 64-bit netinst installer",
        .tier = "leaf",
        .os_family = "linux",
        .format = "iso9660",
        .arch = "riscv64",
        .default_vcpus = 2,
        .default_ram_mb = 1024,
        .default_disk_mb = 4096,
        .filename = "debian-13.7.0-riscv64-netinst.iso",
        .url = "https://cdimage.debian.org/debian-cd/current/riscv64/" ++
            "iso-cd/debian-13.7.0-riscv64-netinst.iso",
        .sha256 = "162b1236c64a902052493d8b3ab41e2b" ++
            "36c52975d967eedac4a2e2b2c0158c35",
    },
    .{
        .id = "alpine-riscv64",
        .alias = "alpine",
        .title = "Alpine Linux 3.24 standard RISC-V 64-bit installer",
        .tier = "leaf",
        .os_family = "linux",
        .format = "iso9660",
        .arch = "riscv64",
        .default_vcpus = 1,
        .default_ram_mb = 512,
        .default_disk_mb = 2048,
        .filename = "alpine-standard-3.24.3-riscv64.iso",
        .url = "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/" ++
            "riscv64/alpine-standard-3.24.3-riscv64.iso",
        .sha256 = "0a98ca04017494e1a19f206d4934f743" ++
            "b13be863aa0ec155ec47b7ab06930025",
    },
    .{
        .id = "freebsd-riscv64",
        .alias = "freebsd",
        .title = "FreeBSD 14.5-RELEASE RISC-V 64-bit disc1 installer",
        .tier = "leaf",
        .os_family = "freebsd",
        .format = "iso9660",
        .arch = "riscv64",
        .default_vcpus = 2,
        .default_ram_mb = 1024,
        .default_disk_mb = 4096,
        .filename = "FreeBSD-14.5-RELEASE-riscv64-disc1.iso",
        .url = "https://download.freebsd.org/releases/riscv/riscv64/" ++
            "ISO-IMAGES/14.5/FreeBSD-14.5-RELEASE-riscv-riscv64-disc1.iso",
        .sha256 = "17e8b3d3435238853f39f9587f3b6bd7" ++
            "90c4f21b8e241d5f324e972e974d7a58",
    },
    .{
        .id = "openbsd-riscv64",
        .alias = "openbsd",
        .title = "OpenBSD 7.9 RISC-V 64-bit official installer",
        .tier = "leaf",
        .os_family = "openbsd",
        .format = "iso9660",
        .arch = "riscv64",
        .default_vcpus = 2,
        .default_ram_mb = 1024,
        .default_disk_mb = 4096,
        .filename = "install79-riscv64.iso",
        .url = "https://cdn.openbsd.org/pub/OpenBSD/7.9/riscv64/install79.img",
        .sha256 = "3bfa301468f6ec8087cf35cdf8760390" ++
            "a5eb7c2f83faceee8d97328adb4e025d",
    },
    .{
        .id = "netbsd-riscv64",
        .alias = "netbsd",
        .title = "NetBSD 10 RISC-V 64-bit UEFI bootloader",
        .tier = "leaf",
        .os_family = "netbsd",
        .format = "iso9660",
        .arch = "riscv64",
        .default_vcpus = 2,
        .default_ram_mb = 1024,
        .default_disk_mb = 4096,
        .filename = "NetBSD-10-bootriscv64.efi",
        .url = "https://nycdn.netbsd.org/pub/NetBSD-daily/HEAD/latest/" ++
            "riscv-riscv64/installation/misc/bootriscv64.efi",
        .sha256 = "ff6e1ee13b7594c8b8feeef2121c45f1" ++
            "697373942d96b6c926ca4cfdff610f39",
    },
};

const trimAscii = common.trimAscii;
const stripQuotes = common.unquoteToml;

/// Parses `/etc/diosix/catalog.toml` into `out_entries`.
pub fn parseCatalogToml(
    content: []const u8,
    out_entries: []CatalogEntry,
) usize {
    var count: usize = 0;
    var cur: ?CatalogEntry = null;

    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |raw_line| {
        const comment_idx = std.mem.indexOfScalar(u8, raw_line, '#') orelse
            raw_line.len;
        const line = trimAscii(raw_line[0..comment_idx]);
        if (line.len == 0) continue;

        if (std.mem.eql(u8, line, "[[image]]")) {
            if (cur) |c| {
                if (c.id.len > 0 and c.filename.len > 0 and
                    c.url.len > 0 and count < out_entries.len)
                {
                    out_entries[count] = c;
                    count += 1;
                }
            }
            cur = CatalogEntry{
                .id = "",
                .alias = "",
                .title = "",
                .tier = "leaf",
                .os_family = "linux",
                .format = "iso9660",
                .arch = "riscv64",
                .default_vcpus = 2,
                .default_ram_mb = 1024,
                .default_disk_mb = 4096,
                .filename = "",
                .url = "",
                .sha256 = "",
            };
            continue;
        }

        if (cur == null) continue;
        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = trimAscii(line[0..eq_idx]);
        const val = stripQuotes(line[eq_idx + 1 ..]);

        const ImageKey = enum {
            id,
            alias,
            title,
            description,
            tier,
            os_family,
            format,
            arch,
            default_vcpus,
            default_ram_mb,
            default_disk_mb,
            filename,
            url,
            sha256,
        };
        if (std.meta.stringToEnum(ImageKey, key)) |k| switch (k) {
            .id => cur.?.id = val,
            .alias => cur.?.alias = val,
            .title, .description => cur.?.title = val,
            .tier => cur.?.tier = val,
            .os_family => cur.?.os_family = val,
            .format => cur.?.format = val,
            .arch => cur.?.arch = val,
            .default_vcpus => {
                cur.?.default_vcpus = std.fmt.parseInt(usize, val, 10) catch 2;
            },
            .default_ram_mb => {
                cur.?.default_ram_mb =
                    std.fmt.parseInt(usize, val, 10) catch 1024;
            },
            .default_disk_mb => {
                cur.?.default_disk_mb =
                    std.fmt.parseInt(usize, val, 10) catch 4096;
            },
            .filename => cur.?.filename = val,
            .url => cur.?.url = val,
            .sha256 => cur.?.sha256 = val,
        };
    }

    if (cur) |c| {
        if (c.id.len > 0 and c.filename.len > 0 and
            c.url.len > 0 and count < out_entries.len)
        {
            out_entries[count] = c;
            count += 1;
        }
    }
    return count;
}

/// Finds a catalog entry in `entries` by ID, short alias, or filename.
pub fn findEntryInSlice(
    entries: []const CatalogEntry,
    query: []const u8,
) ?CatalogEntry {
    if (query.len == 0) return null;
    for (entries) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.id, query) or
            (entry.alias.len > 0 and
                std.ascii.eqlIgnoreCase(entry.alias, query)) or
            std.ascii.eqlIgnoreCase(entry.filename, query))
        {
            return entry;
        }
    }
    return null;
}

/// Finds an official catalog entry by ID, short alias, or filename.
pub fn findEntry(query: []const u8) ?CatalogEntry {
    return findEntryInSlice(&OFFICIAL_CATALOG, query);
}

pub const ImageMetadata = struct {
    tier: []const u8,
    os_family: []const u8,
    format: []const u8,
};

/// Infers `tier`, `os_family`, and `format` for a local repository image or ISO
/// so `dsx image list` columns align directly with `dsx image catalog`.
pub fn inferImageMetadata(
    filename: []const u8,
    is_iso_dir: bool,
    entries: []const CatalogEntry,
) ImageMetadata {
    if (findEntryInSlice(entries, filename)) |entry| {
        return .{
            .tier = entry.tier,
            .os_family = entry.os_family,
            .format = entry.format,
        };
    }

    const is_iso = std.mem.endsWith(u8, filename, ".iso") or is_iso_dir;
    const fmt: []const u8 = if (is_iso) "iso9660" else "elf";

    const ImageMetadataEntry = struct {
        id: []const u8,
        tier: []const u8,
        os_family: []const u8,
    };
    const table = [_]ImageMetadataEntry{
        .{ .id = "steward", .tier = "steward", .os_family = "diosix" },
        .{ .id = "shim", .tier = "shim", .os_family = "diosix" },
        .{ .id = "freebsd", .tier = "leaf", .os_family = "freebsd" },
        .{ .id = "FreeBSD", .tier = "leaf", .os_family = "freebsd" },
        .{ .id = "openbsd", .tier = "leaf", .os_family = "openbsd" },
        .{ .id = "install7", .tier = "leaf", .os_family = "openbsd" },
        .{ .id = "netbsd", .tier = "leaf", .os_family = "netbsd" },
        .{ .id = "NetBSD", .tier = "leaf", .os_family = "netbsd" },
        .{ .id = "debian", .tier = "leaf", .os_family = "linux" },
        .{ .id = "alpine", .tier = "leaf", .os_family = "linux" },
        .{ .id = "linux", .tier = "leaf", .os_family = "linux" },
        .{ .id = "vmlinux", .tier = "leaf", .os_family = "linux" },
    };
    for (table) |item| {
        if (std.mem.indexOf(u8, filename, item.id) != null) {
            return .{
                .tier = item.tier,
                .os_family = item.os_family,
                .format = fmt,
            };
        }
    }

    const os_family: []const u8 = if (is_iso) "generic" else "linux";
    return .{ .tier = "leaf", .os_family = os_family, .format = fmt };
}

/// Validates that an image filename contains only safe `[A-Za-z0-9._-]`
/// characters and rejects path traversal (`..`), slashes, or leading hyphens.
pub fn isValidImageName(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_IMAGE_NAME_LEN) return false;
    if (name[0] == '.' or name[0] == '-') return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;

    for (name) |ch| {
        const ok = std.ascii.isAlphanumeric(ch) or
            ch == '.' or ch == '_' or ch == '-';
        if (!ok) return false;
    }
    return true;
}

/// Validates that a remote URL uses an explicit `https://`, `http://`, or
/// `file://` scheme and contains no whitespace, control characters, or shell
/// metacharacters.
pub fn isValidUrl(url: []const u8) bool {
    if (url.len < 8 or url.len > MAX_URL_LEN) return false;
    const valid_scheme = std.mem.startsWith(u8, url, "https://") or
        std.mem.startsWith(u8, url, "http://") or
        std.mem.startsWith(u8, url, "file://");
    if (!valid_scheme) return false;

    for (url) |ch| {
        if (ch <= 0x20 or ch >= 0x7f) return false;
        switch (ch) {
            '"', '\'', '`', '$', ';', '|', '&', '<', '>', '\\' => return false,
            else => {},
        }
    }
    return true;
}

/// Validates that a string is a 64-character hexadecimal SHA-256 digest.
pub fn isValidSha256Hex(hex: []const u8) bool {
    if (hex.len != SHA256_HEX_LEN) return false;
    for (hex) |ch| {
        if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

/// Returns true if the catalog entry has a valid, non-zero 64-character hex
/// SHA-256 digest pinned.
pub fn hasPinnedSha256(entry: CatalogEntry) bool {
    if (!isValidSha256Hex(entry.sha256)) return false;
    for (entry.sha256) |ch| {
        if (ch != '0') return true;
    }
    return false;
}

const format = @import("catalog/format.zig");

pub const computeSha256Hex = format.computeSha256Hex;
pub const writeCatalogTable = format.writeCatalogTable;
pub const formatCatalogTable = format.formatCatalogTable;
pub const writeCatalogJson = format.writeCatalogJson;
pub const formatCatalogJson = format.formatCatalogJson;

/// Verifies `data` against an expected 64-character hexadecimal SHA-256 digest.
pub fn verifySha256Hex(data: []const u8, expected_hex: []const u8) bool {
    if (!isValidSha256Hex(expected_hex)) return false;
    // A SHA-256 digest is always exactly 64 lowercase hex characters.
    var computed: [SHA256_HEX_LEN]u8 = undefined;
    _ = computeSha256Hex(data, &computed);
    return std.ascii.eqlIgnoreCase(&computed, expected_hex);
}

/// Extracts a safe basename from a URL or path, validating it with
/// `isValidImageName`.
pub fn extractSafeFilename(url_or_path: []const u8) ?[]const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, url_or_path, '/')) |slash|
        url_or_path[slash + 1 ..]
    else
        url_or_path;
    if (!isValidImageName(base)) return null;
    return base;
}

test "catalog: findEntry and filename/URL validation" {
    std.testing.refAllDecls(@This());
    _ = format;
    _ = @import("tests/catalog.zig");
    try std.testing.expect(findEntry("steward") != null);
    try std.testing.expect(isValidImageName("debian-12.iso"));
    try std.testing.expect(!isValidImageName("../bad.iso"));
}
