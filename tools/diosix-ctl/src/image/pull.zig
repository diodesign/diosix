// Diosix Remote Image Pulling, Import, and SHA-256 Verification.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const catalog = @import("../catalog.zig");
const common = @import("../common.zig");
const loader = @import("../loader.zig");

pub fn fetchRemoteFile(url: []const u8, dest_z: [*:0]const u8) !void {
    var url_z_buf: [catalog.MAX_URL_LEN + 16]u8 = undefined;
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
        "/usr/bin/wget",
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
        "/usr/bin/curl",
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
        var prog_buf: [384]u8 = undefined;
        const prog_msg = std.fmt.bufPrint(
            &prog_buf,
            "==> Pulling image from {s} ...\n",
            .{url},
        ) catch "==> Pulling remote image...\n";
        common.printStr(prog_msg);
    }

    var tmp_path_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(
        &tmp_path_buf,
        "{s}.part",
        .{dest_path},
    ) catch return error.PathTooLong;
    var tmp_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const tmp_z = common.toPathZ(tmp_path, &tmp_z_buf) orelse
        return error.PathTooLong;

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
            var v_buf: [160]u8 = undefined;
            const v_msg = std.fmt.bufPrint(
                &v_buf,
                "==> Verified SHA-256 checksum ({s}...)\n",
                .{sha[0..16]},
            ) catch "==> Verified SHA-256 checksum.\n";
            common.printStr(v_msg);
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
            var err_buf: [192]u8 = undefined;
            const err_msg = std.fmt.bufPrint(
                &err_buf,
                "Error: Unknown option '{s}'. Usage: {s} image pull " ++
                    "<id|url> [--name <name>] [--sha256 <hex>]\n",
                .{ span, exe_name },
            ) catch "Error: Unknown option.\n";
            common.printStr(err_msg);
            return;
        }
    }

    const matched_entry = catalog.findEntryInSlice(active_catalog, target);
    const resolved_url: []const u8 =
        if (matched_entry) |e| e.url else target;
    if (matched_entry == null and !catalog.isValidUrl(resolved_url)) {
        var err_buf: [256]u8 = undefined;
        const err_msg = std.fmt.bufPrint(
            &err_buf,
            "Error: '{s}' is not a known catalog ID and is not a valid " ++
                "URL. Use '{s} image catalog' to list official images.\n",
            .{ target, exe_name },
        ) catch "Error: Invalid catalog ID or URL.\n";
        common.printStr(err_msg);
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
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(
                &err_buf,
                "Error: Catalog entry '{s}' has no valid pinned SHA-256 " ++
                    "digest in /etc/diosix/catalog.toml " ++
                    "(pass '--sha256 <hex>' or '--allow-unverified').\n",
                .{e.id},
            ) catch "Error: Missing pinned SHA-256 digest.\n";
            common.printStr(err_msg);
        } else {
            common.printStr(
                "Error: Pulling a custom URL requires '--sha256 <hex>' " ++
                    "(or pass '--allow-unverified').\n",
            );
        }
        return;
    }

    const is_iso = std.mem.endsWith(u8, filename, ".iso") or
        (matched_entry != null and
            std.mem.eql(u8, matched_entry.?.format, "iso9660"));
    const base_dir: []const u8 =
        if (is_iso) "/var/lib/diosix/iso" else "/var/lib/diosix/images";

    _ = linux.mkdir("/var/lib/diosix", 0o755);
    _ = if (is_iso)
        linux.mkdir("/var/lib/diosix/iso", 0o755)
    else
        linux.mkdir("/var/lib/diosix/images", 0o755);

    var dest_path_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const dest_path = std.fmt.bufPrint(
        &dest_path_buf,
        "{s}/{s}",
        .{ base_dir, filename },
    ) catch return;

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
                    var fb_buf: [256]u8 = undefined;
                    const fb_msg = std.fmt.bufPrint(
                        &fb_buf,
                        "==> Staging offline test stub for '{s}' " ++
                            "(--offline-stub)...\n",
                        .{entry.id},
                    ) catch "==> Staging offline test stub...\n";
                    common.printStr(fb_msg);
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
            var dl_buf: [384]u8 = undefined;
            const dl_msg = std.fmt.bufPrint(
                &dl_buf,
                "Error: Failed to download '{s}'. Verify connectivity " ++
                    "and mirror URL in /etc/diosix/catalog.toml " ++
                    "(or pass '--offline-stub' for offline testing).\n",
                .{resolved_url},
            ) catch "Error: Failed to download image from remote mirror.\n";
            common.printStr(dl_msg);
            return;
        }
    }

    var sha_hex: [catalog.SHA256_HEX_LEN]u8 = @splat('0');
    if (common.readBinaryFile(
        dest_path,
        common.MAX_ELF_FILE_SIZE * 4,
    )) |stored| {
        defer common.unmapBinaryFile(stored);
        _ = catalog.computeSha256Hex(stored, &sha_hex);
    } else |_| {}

    if (json_flag) {
        var jbuf: [512]u8 = undefined;
        const jout = std.fmt.bufPrint(
            &jbuf,
            "{{\"status\":\"ok\",\"image\":\"{s}\",\"path\":\"{s}\"," ++
                "\"sha256\":\"{s}\",\"sha256_verified\":{s}," ++
                "\"offline_seed\":{s}}}\n",
            .{
                filename,
                dest_path,
                &sha_hex,
                if (sha_verified) "true" else "false",
                if (used_offline_seed) "true" else "false",
            },
        ) catch return;
        common.printStr(jout);
    } else {
        var out_buf: [384]u8 = undefined;
        const suffix = if (sha_verified)
            ", verified"
        else if (used_offline_seed)
            ", offline stub"
        else
            ", unverified";
        const out_msg = std.fmt.bufPrint(
            &out_buf,
            "✓ Pulled '{s}' -> {s} (SHA-256: {s}...{s})\n",
            .{ filename, dest_path, sha_hex[0..16], suffix },
        ) catch return;
        common.printStr(out_msg);
    }
}

pub fn cmdImageImport(
    exe_name: []const u8,
    args: []const [*:0]const u8,
) !void {
    if (args.len < 2) {
        common.printStr("Usage: dsx image import <file> [--name <name>]\n");
        return;
    }
    const ImportFlag = enum { @"--name", @"-n" };
    const src_file = std.mem.span(args[1]);
    var custom_name: ?[]const u8 = null;
    var idx: usize = 2;
    while (idx < args.len) : (idx += 1) {
        const span = std.mem.span(args[idx]);
        if (std.meta.stringToEnum(ImportFlag, span)) |_| {
            if (idx + 1 >= args.len) {
                common.printStr(
                    "Error: Option '--name' requires a filename.\n",
                );
                return;
            }
            idx += 1;
            custom_name = std.mem.span(args[idx]);
        } else if (std.mem.startsWith(u8, span, "-")) {
            var err_buf: [160]u8 = undefined;
            const err_msg = std.fmt.bufPrint(
                &err_buf,
                "Error: Unknown option '{s}'. " ++
                    "Usage: {s} image import <file> [--name <name>]\n",
                .{ span, exe_name },
            ) catch "Error: Unknown option.\n";
            common.printStr(err_msg);
            return;
        }
    }

    const is_iso = std.mem.endsWith(u8, src_file, ".iso") or
        (custom_name != null and std.mem.endsWith(u8, custom_name.?, ".iso"));
    const base_dir: []const u8 =
        if (is_iso) "/var/lib/diosix/iso" else "/var/lib/diosix/images";

    _ = linux.mkdir("/var/lib/diosix", 0o755);
    _ = if (is_iso)
        linux.mkdir("/var/lib/diosix/iso", 0o755)
    else
        linux.mkdir("/var/lib/diosix/images", 0o755);

    const filename: []const u8 = if (custom_name) |cname| cname else blk: {
        if (std.mem.lastIndexOfScalar(u8, src_file, '/')) |slash| {
            break :blk src_file[slash + 1 ..];
        }
        break :blk src_file;
    };

    if (!catalog.isValidImageName(filename)) {
        common.printStr(
            "Error: Invalid destination image filename " ++
                "(must not contain path separators or '..').\n",
        );
        return;
    }

    var dest_path_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const dest_path = std.fmt.bufPrint(
        &dest_path_buf,
        "{s}/{s}",
        .{ base_dir, filename },
    ) catch return;

    if (common.readBinaryFile(
        src_file,
        common.MAX_ELF_FILE_SIZE * 4,
    )) |content| {
        defer common.unmapBinaryFile(content);
        _ = common.writeFile(dest_path, content) catch {
            common.printStr("Error: Failed to write image to repository.\n");
            return;
        };
    } else |_| {
        common.printStr("Error: Could not read source image file.\n");
        return;
    }

    var out_buf: [256]u8 = undefined;
    const out_msg = std.fmt.bufPrint(
        &out_buf,
        "✓ Image '{s}' successfully imported into {s}.\n",
        .{ filename, dest_path },
    ) catch return;
    common.printStr(out_msg);
}

test "image_pull: pullRemoteOrStageImage rejects invalid URLs and checksums" {
    std.testing.refAllDecls(@This());
    try std.testing.expectError(
        error.InvalidUrl,
        pullRemoteOrStageImage("ftp://bad", "/tmp/out", null, true, true),
    );
    try std.testing.expectError(
        error.MissingExpectedChecksum,
        pullRemoteOrStageImage("https://ok/a.elf", "/tmp/o", null, false, true),
    );
}
