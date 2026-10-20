// Diosix Remote Image Pulling, Import, and SHA-256 Verification.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const catalog = @import("../catalog.zig");
const common = @import("../common.zig");
const loader = @import("../loader.zig");
const sysconfig = @import("../sysconfig.zig");
const disk = @import("../storage/disk.zig");
const import_mod = @import("import.zig");

pub const cmdImageImport = import_mod.cmdImageImport;

/// `catalog.isValidUrl` caps a URL at `MAX_URL_LEN` bytes; one more holds the
/// NUL terminator, so any validated URL fits.
const URL_Z_BYTES: usize = catalog.MAX_URL_LEN + 1;

pub fn fetchRemoteFile(url: []const u8, dest_z: [*:0]const u8) !void {
    var url_z_buf: [URL_Z_BYTES]u8 = undefined;
    const url_z = common.toPathZ(url, &url_z_buf) orelse
        return error.InvalidUrl;

    if (std.mem.startsWith(u8, url, "file://")) {
        const local_src = url["file://".len..];
        const content = try common.readBinaryFile(
            local_src,
            common.MAX_ELF_FILE_SIZE * 4,
        );
        defer common.unmapBinaryFile(content);
        try common.writeFile(std.mem.span(dest_z), content);
        return;
    }

    const wget_argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
        sysconfig.WGET_BIN,
        "-q",
        "-T",
        "5",
        "-t",
        "1",
        "-O",
        dest_z,
        url_z.ptr,
        null,
    };
    const wget_rc = common.runSubprocess(wget_argv);
    if (wget_rc == 0) return;
    if (wget_rc >= 128) return error.Interrupted;

    const curl_argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
        sysconfig.CURL_BIN,
        "-fsSL",
        "--connect-timeout",
        "5",
        "--max-time",
        "30",
        "-o",
        dest_z,
        url_z.ptr,
        null,
    };
    const curl_rc = common.runSubprocess(curl_argv);
    if (curl_rc == 0) return;
    if (curl_rc >= 128) return error.Interrupted;

    return error.DownloadFailed;
}

pub fn pullRemoteOrStageImage(
    url: []const u8,
    dest_path: []const u8,
    expected_sha256: ?[]const u8,
    allow_unverified: bool,
    quiet: bool,
) !bool {
    if (!catalog.isValidUrl(url)) return error.InvalidUrl;

    if (expected_sha256) |sha| {
        if (!catalog.isValidSha256Hex(sha)) return error.InvalidChecksum;
    } else if (!allow_unverified) {
        return error.MissingExpectedChecksum;
    }

    if (!quiet) {
        common.printFmt("==> Pulling image from {s} ...\n", .{url});
    }

    const allocator = std.heap.page_allocator;
    const tmp_z = try allocator.printSentinel("{s}.part", .{dest_path}, 0);
    defer allocator.free(tmp_z);
    if (tmp_z.len >= common.MAX_PATH_LEN) return error.PathTooLong;
    const tmp_path: []const u8 = tmp_z;

    fetchRemoteFile(url, tmp_z.ptr) catch |err| {
        _ = linux.unlink(tmp_z.ptr);
        return err;
    };

    const content = common.readBinaryFile(
        tmp_path,
        common.MAX_ELF_FILE_SIZE * 4,
    ) catch |err| {
        _ = linux.unlink(tmp_z.ptr);
        return err;
    };
    defer common.unmapBinaryFile(content);

    var sha_verified = false;
    if (expected_sha256) |sha| {
        if (!catalog.verifySha256Hex(content, sha)) {
            _ = linux.unlink(tmp_z.ptr);
            return error.ChecksumMismatch;
        }
        sha_verified = true;
        if (!quiet) {
            common.printFmt(
                "==> Verified SHA-256 checksum ({s}...)\n",
                .{sha[0..16]},
            );
        }
    }

    try common.writeFile(dest_path, content);
    _ = linux.unlink(tmp_z.ptr);
    return sha_verified;
}

pub fn cmdImagePull(
    exe_name: []const u8,
    args: []const [*:0]const u8,
    active_catalog: []const catalog.CatalogEntry,
    initial_json: bool,
) !void {
    if (args.len < 2) {
        common.printStr(
            "Usage: dsx image pull <catalog-id|url> [--name <name>] " ++
                "[--sha256 <hex>] [--allow-unverified] [--offline-stub] " ++
                "[--json]\n",
        );
        return;
    }
    const PullFlag = enum {
        @"--name",
        @"-n",
        @"--sha256",
        @"--allow-unverified",
        @"--offline-stub",
        @"--json",
        @"-j",
    };
    const target = std.mem.span(args[1]);
    var custom_name: ?[]const u8 = null;
    var custom_sha256: ?[]const u8 = null;
    var allow_unverified = false;
    var offline_stub = false;
    var json_flag = initial_json;
    var idx: usize = 2;
    while (idx < args.len) : (idx += 1) {
        const span = std.mem.span(args[idx]);
        if (std.meta.stringToEnum(PullFlag, span)) |pf| {
            switch (pf) {
                .@"--name", .@"-n" => {
                    if (idx + 1 >= args.len) {
                        common.printStr(
                            "Error: Option '--name' requires a filename.\n",
                        );
                        return;
                    }
                    idx += 1;
                    custom_name = std.mem.span(args[idx]);
                },
                .@"--sha256" => {
                    if (idx + 1 >= args.len) {
                        common.printStr(
                            "Error: Option '--sha256' requires a " ++
                                "64-character hex digest.\n",
                        );
                        return;
                    }
                    idx += 1;
                    custom_sha256 = std.mem.span(args[idx]);
                    if (!catalog.isValidSha256Hex(custom_sha256.?)) {
                        common.printStr(
                            "Error: Invalid SHA-256 digest " ++
                                "(expected 64 hexadecimal characters).\n",
                        );
                        return;
                    }
                },
                .@"--allow-unverified" => allow_unverified = true,
                .@"--offline-stub" => offline_stub = true,
                .@"--json", .@"-j" => json_flag = true,
            }
        } else if (std.mem.startsWith(u8, span, "-")) {
            common.printFmt(
                "Error: Unknown option '{s}'. Usage: {s} image pull " ++
                    "<id|url> [--name <name>] [--sha256 <hex>]\n",
                .{ span, exe_name },
            );
            return;
        }
    }

    const matched_entry = catalog.findEntryInSlice(active_catalog, target);
    const resolved_url: []const u8 =
        if (matched_entry) |e| e.url else target;
    if (matched_entry == null and !catalog.isValidUrl(resolved_url)) {
        common.printFmt(
            "Error: '{s}' is not a known catalog ID and is not a valid " ++
                "URL. Use '{s} image catalog' to list official images.\n",
            .{ target, exe_name },
        );
        return;
    }

    const filename: []const u8 = if (custom_name) |cname|
        cname
    else if (matched_entry) |e|
        e.filename
    else
        (catalog.extractSafeFilename(resolved_url) orelse "");
    if (!catalog.isValidImageName(filename)) {
        common.printStr("Error: Invalid or unsafe destination filename.\n");
        return;
    }

    const verify_sha: ?[]const u8 = if (custom_sha256) |s|
        s
    else if (matched_entry) |e|
        (if (catalog.hasPinnedSha256(e)) e.sha256 else null)
    else
        null;

    if (verify_sha == null and !allow_unverified) {
        if (matched_entry) |e| {
            common.printFmt(
                "Error: Catalog entry '{s}' has no valid pinned SHA-256 " ++
                    "digest in /etc/diosix/catalog.toml " ++
                    "(pass '--sha256 <hex>' or '--allow-unverified').\n",
                .{e.id},
            );
        } else {
            common.printStr(
                "Error: Pulling a custom URL requires '--sha256 <hex>' " ++
                    "(or pass '--allow-unverified').\n",
            );
        }
        return;
    }

    const sys_cfg = common.loadRuntimeSystemConfig();
    const is_iso = std.mem.endsWith(u8, filename, ".iso") or
        (matched_entry != null and
            std.mem.eql(u8, matched_entry.?.format, "iso9660"));
    const base_dir: []const u8 =
        if (is_iso) sys_cfg.isoDir() else sys_cfg.imagesDir();

    _ = linux.mkdir(sysconfig.VAR_LIB_DIOSIX_DIR, 0o755);
    {
        var dir_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
        if (common.toPathZ(base_dir, &dir_z_buf)) |dz| {
            _ = linux.mkdir(dz.ptr, 0o755);
        }
    }

    const allocator = std.heap.page_allocator;
    const dest_path = try allocator.print(
        "{s}/{s}",
        .{ base_dir, filename },
    );
    defer allocator.free(dest_path);
    if (dest_path.len >= common.MAX_PATH_LEN) {
        disk.reportPathTooLong();
        return;
    }

    var used_offline_seed = false;
    var sha_verified = false;
    if (pullRemoteOrStageImage(
        resolved_url,
        dest_path,
        verify_sha,
        allow_unverified,
        json_flag,
    )) |verified| {
        sha_verified = verified;
    } else |err| {
        if (err == error.Interrupted) {
            common.printStr("\nAborted image pull (interrupted by signal).\n");
            return;
        }
        if (err == error.ChecksumMismatch) {
            common.printStr(
                "Error: SHA-256 checksum verification failed!\n",
            );
            return;
        }
        if (offline_stub) {
            if (matched_entry) |entry| {
                if (!json_flag) {
                    common.printFmt(
                        "==> Staging offline test stub for '{s}' " ++
                            "(--offline-stub)...\n",
                        .{entry.id},
                    );
                }
                if (loader.seedOfflineCatalogFallback(entry, dest_path)) {
                    used_offline_seed = true;
                } else {
                    common.printStr(
                        "Error: Failed to stage offline test stub.\n",
                    );
                    return;
                }
            } else {
                common.printStr(
                    "Error: '--offline-stub' is only supported for " ++
                        "catalog entries.\n",
                );
                return;
            }
        } else {
            common.printFmt(
                "Error: Failed to download '{s}'. Verify connectivity " ++
                    "and mirror URL in /etc/diosix/catalog.toml " ++
                    "(or pass '--offline-stub' for offline testing).\n",
                .{resolved_url},
            );
            return;
        }
    }

    // A SHA-256 digest is always exactly 64 lowercase hex characters.
    var sha_hex: [catalog.SHA256_HEX_LEN]u8 = @splat('0');
    if (common.readBinaryFile(
        dest_path,
        common.MAX_ELF_FILE_SIZE * 4,
    )) |stored| {
        defer common.unmapBinaryFile(stored);
        _ = catalog.computeSha256Hex(stored, &sha_hex);
    } else |_| {}

    if (json_flag) {
        const safe_name = try common.escapeJsonAlloc(allocator, filename);
        defer allocator.free(safe_name);
        const safe_path = try common.escapeJsonAlloc(allocator, dest_path);
        defer allocator.free(safe_path);
        common.printFmt(
            "{{\"status\":\"ok\",\"image\":\"{s}\",\"path\":\"{s}\"," ++
                "\"sha256\":\"{s}\",\"sha256_verified\":{s}," ++
                "\"offline_seed\":{s}}}\n",
            .{
                safe_name,
                safe_path,
                &sha_hex,
                if (sha_verified) "true" else "false",
                if (used_offline_seed) "true" else "false",
            },
        );
    } else {
        const suffix = if (sha_verified)
            ", verified"
        else if (used_offline_seed)
            ", offline stub"
        else
            ", unverified";
        common.printFmt(
            "✓ Pulled '{s}' -> {s} (SHA-256: {s}...{s})\n",
            .{ filename, dest_path, sha_hex[0..16], suffix },
        );
    }
}

test "image_pull: pullRemoteOrStageImage rejects invalid URLs and checksums" {
    std.testing.refAllDecls(@This());
    _ = import_mod;
    try std.testing.expectError(
        error.InvalidUrl,
        pullRemoteOrStageImage("ftp://bad", "/tmp/out", null, true, true),
    );
    try std.testing.expectError(
        error.MissingExpectedChecksum,
        pullRemoteOrStageImage("https://ok/a.elf", "/tmp/o", null, false, true),
    );
}
