// Diosix Remote Guest OS & Autonomic Steward VM Catalog.
//
// Manages discovery, URL/filename sanitization, and SHA-256 integrity
// verification for remote S/U-mode Guest OS installer images (Linux, FreeBSD,
// OpenBSD, NetBSD) and the on-demand Tier-1 Autonomic Steward VM appliance.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

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

pub const DEFAULT_CATALOG_CONFIG_PATH = "/etc/diosix/catalog.toml";
pub const MAX_CATALOG_ENTRIES: usize = 32;

pub const OFFICIAL_CATALOG = [_]CatalogEntry{
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
        .url = "https://images.diosix.org/26.2/riscv64/steward.elf",
        .sha256 = "e3b0c44298fc1c149afbf4c8996fb924" ++
            "27ae41e4649b934ca495991b7852b855",
    },
    .{
        .id = "debian-riscv64",
        .alias = "debian",
        .title = "Debian 12 (Bookworm) RISC-V 64-bit netinst installer",
        .tier = "leaf",
        .os_family = "linux",
        .format = "iso9660",
        .arch = "riscv64",
        .default_vcpus = 2,
        .default_ram_mb = 1024,
        .default_disk_mb = 4096,
        .filename = "debian-12-riscv64-netinst.iso",
        .url = "https://images.diosix.org/catalog/riscv64/" ++
            "debian-12-riscv64-netinst.iso",
        .sha256 = "0123456789abcdef0123456789abcdef" ++
            "0123456789abcdef0123456789abcdef",
    },
    .{
        .id = "alpine-riscv64",
        .alias = "alpine",
        .title = "Alpine Linux 3.21 standard RISC-V 64-bit installer",
        .tier = "leaf",
        .os_family = "linux",
        .format = "iso9660",
        .arch = "riscv64",
        .default_vcpus = 1,
        .default_ram_mb = 512,
        .default_disk_mb = 2048,
        .filename = "alpine-standard-3.21-riscv64.iso",
        .url = "https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/" ++
            "riscv64/alpine-standard-3.21.0-riscv64.iso",
        .sha256 = "1123456789abcdef0123456789abcdef" ++
            "0123456789abcdef0123456789abcdef",
    },
    .{
        .id = "freebsd-riscv64",
        .alias = "freebsd",
        .title = "FreeBSD 14.2-RELEASE RISC-V 64-bit disc1 installer",
        .tier = "leaf",
        .os_family = "freebsd",
        .format = "iso9660",
        .arch = "riscv64",
        .default_vcpus = 2,
        .default_ram_mb = 1024,
        .default_disk_mb = 4096,
        .filename = "FreeBSD-14.2-RELEASE-riscv64-disc1.iso",
        .url = "https://download.freebsd.org/releases/riscv/riscv64/" ++
            "ISO-IMAGES/14.2/FreeBSD-14.2-RELEASE-riscv-riscv64-disc1.iso",
        .sha256 = "2123456789abcdef0123456789abcdef" ++
            "0123456789abcdef0123456789abcdef",
    },
    .{
        .id = "openbsd-riscv64",
        .alias = "openbsd",
        .title = "OpenBSD 7.6 RISC-V 64-bit official installer",
        .tier = "leaf",
        .os_family = "openbsd",
        .format = "iso9660",
        .arch = "riscv64",
        .default_vcpus = 2,
        .default_ram_mb = 1024,
        .default_disk_mb = 4096,
        .filename = "install76-riscv64.iso",
        .url = "https://cdn.openbsd.org/pub/OpenBSD/7.6/riscv64/install76.iso",
        .sha256 = "3123456789abcdef0123456789abcdef" ++
            "0123456789abcdef0123456789abcdef",
    },
    .{
        .id = "netbsd-riscv64",
        .alias = "netbsd",
        .title = "NetBSD 10.1 RISC-V 64-bit official installer",
        .tier = "leaf",
        .os_family = "netbsd",
        .format = "iso9660",
        .arch = "riscv64",
        .default_vcpus = 2,
        .default_ram_mb = 1024,
        .default_disk_mb = 4096,
        .filename = "NetBSD-10.1-riscv64.iso",
        .url = "https://cdn.netbsd.org/pub/NetBSD/NetBSD-10.1/images/" ++
            "NetBSD-10.1-riscv64.iso",
        .sha256 = "4123456789abcdef0123456789abcdef" ++
            "0123456789abcdef0123456789abcdef",
    },
};

fn trimAscii(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn stripQuotes(s: []const u8) []const u8 {
    const t = trimAscii(s);
    if (t.len >= 2 and
        ((t[0] == '"' and t[t.len - 1] == '"') or
            (t[0] == '\'' and t[t.len - 1] == '\'')))
    {
        return t[1 .. t.len - 1];
    }
    return t;
}

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

    if (std.mem.startsWith(u8, filename, "steward")) {
        return .{ .tier = "steward", .os_family = "diosix", .format = fmt };
    }
    if (std.mem.indexOf(u8, filename, "shim") != null) {
        return .{ .tier = "shim", .os_family = "diosix", .format = fmt };
    }

    var os_family: []const u8 = if (is_iso) "generic" else "linux";
    if (std.mem.indexOf(u8, filename, "freebsd") != null or
        std.mem.indexOf(u8, filename, "FreeBSD") != null)
    {
        os_family = "freebsd";
    } else if (std.mem.indexOf(u8, filename, "openbsd") != null or
        std.mem.indexOf(u8, filename, "install7") != null)
    {
        os_family = "openbsd";
    } else if (std.mem.indexOf(u8, filename, "netbsd") != null or
        std.mem.indexOf(u8, filename, "NetBSD") != null)
    {
        os_family = "netbsd";
    } else if (std.mem.indexOf(u8, filename, "debian") != null or
        std.mem.indexOf(u8, filename, "alpine") != null or
        std.mem.indexOf(u8, filename, "linux") != null or
        std.mem.indexOf(u8, filename, "vmlinux") != null)
    {
        os_family = "linux";
    } else if (std.mem.indexOf(u8, filename, "micro-guest") != null) {
        os_family = "diosix";
    }

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

/// Computes the lowercase 64-character SHA-256 hex digest of `data`.
pub fn computeSha256Hex(
    data: []const u8,
    out_hex: *[SHA256_HEX_LEN]u8,
) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out_hex[i * 2] = hex_chars[b >> 4];
        out_hex[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return out_hex[0..SHA256_HEX_LEN];
}

/// Verifies `data` against an expected 64-character hexadecimal SHA-256 digest.
pub fn verifySha256Hex(data: []const u8, expected_hex: []const u8) bool {
    if (!isValidSha256Hex(expected_hex)) return false;
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
    return formatCatalogTableFromSlice(buf, &OFFICIAL_CATALOG);
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
    return formatCatalogJsonFromSlice(buf, &OFFICIAL_CATALOG);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("tests/catalog.zig");
}
