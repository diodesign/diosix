// Diosix Local Image & ISO Import Handler (dsx image import).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const catalog = @import("../catalog.zig");
const common = @import("../common.zig");
const sysconfig = @import("../sysconfig.zig");
const disk = @import("../storage/disk.zig");

const ImportFlag = enum { @"--name", @"-n" };

pub fn cmdImageImport(
    exe_name: []const u8,
    args: []const [*:0]const u8,
) !void {
    const sys_cfg = common.loadRuntimeSystemConfig();
    if (args.len < 2) {
        common.printStr("Usage: dsx image import <file> [--name <name>]\n");
        return;
    }
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
            common.printFmt(
                "Error: Unknown option '{s}'. " ++
                    "Usage: {s} image import <file> [--name <name>]\n",
                .{ span, exe_name },
            );
            return;
        }
    }

    const is_iso = std.mem.endsWith(u8, src_file, ".iso") or
        (custom_name != null and std.mem.endsWith(u8, custom_name.?, ".iso"));
    const base_dir: []const u8 =
        if (is_iso) sys_cfg.isoDir() else sys_cfg.imagesDir();

    _ = linux.mkdir(sysconfig.VAR_LIB_DIOSIX_DIR, 0o755);
    {
        var dir_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
        if (common.toPathZ(base_dir, &dir_z_buf)) |dz| {
            _ = linux.mkdir(dz.ptr, 0o755);
        }
    }

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

    common.printFmt(
        "✓ Image '{s}' successfully imported into {s}.\n",
        .{ filename, dest_path },
    );
}

pub fn cmdImageVerify(
    images_dir: []const u8,
    iso_dir: []const u8,
    args: []const [*:0]const u8,
    active_catalog: []const catalog.CatalogEntry,
    json_flag: bool,
) !void {
    if (args.len < 2) {
        common.printStr(
            "Usage: dsx image verify <name> [--sha256 <hex>] [--json]\n",
        );
        return;
    }
    const img_name = std.mem.span(args[1]);
    if (!common.isSafeIdentifier(img_name) or
        !catalog.isValidImageName(img_name))
    {
        common.printStr("Error: Invalid image name.\n");
        return;
    }
    var expected_sha: ?[]const u8 = null;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const span = std.mem.span(args[i]);
        if (std.mem.eql(u8, span, "--sha256") and i + 1 < args.len) {
            i += 1;
            expected_sha = std.mem.span(args[i]);
        }
    }
    if (expected_sha == null) {
        if (catalog.findEntryInSlice(active_catalog, img_name)) |entry| {
            if (catalog.hasPinnedSha256(entry)) expected_sha = entry.sha256;
        }
    }

    const allocator = std.heap.page_allocator;
    const is_iso = std.mem.endsWith(u8, img_name, ".iso");
    const base_dir = if (is_iso) iso_dir else images_dir;
    const path = try allocator.print("{s}/{s}", .{ base_dir, img_name });
    defer allocator.free(path);
    const content = common.readBinaryFile(
        path,
        common.MAX_ELF_FILE_SIZE * 4,
    ) catch {
        common.printFmt("Error: Image '{s}' not found.\n", .{img_name});
        return;
    };
    defer common.unmapBinaryFile(content);

    var sha_hex: [catalog.SHA256_HEX_LEN]u8 = @splat('0');
    _ = catalog.computeSha256Hex(content, &sha_hex);
    const verified = if (expected_sha) |sha|
        catalog.verifySha256Hex(content, sha)
    else
        true;

    if (json_flag) {
        const safe_name = try common.escapeJsonAlloc(allocator, img_name);
        defer allocator.free(safe_name);
        common.printFmt(
            "{{\"image\":\"{s}\",\"sha256\":\"{s}\",\"verified\":{s}}}\n",
            .{ safe_name, &sha_hex, if (verified) "true" else "false" },
        );
    } else if (verified) {
        common.printFmt(
            "✓ Image '{s}' SHA-256: {s}\n",
            .{ img_name, &sha_hex },
        );
    } else {
        common.printFmt(
            "Error: Image '{s}' SHA-256 mismatch ({s}).\n",
            .{ img_name, &sha_hex },
        );
    }
}

test "image/import: option enum parses --name flag" {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(
        ImportFlag.@"--name",
        std.meta.stringToEnum(ImportFlag, "--name").?,
    );
}
