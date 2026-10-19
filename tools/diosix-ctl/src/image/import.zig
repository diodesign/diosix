// Diosix Local Image & ISO Import Handler (dsx image import).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const catalog = @import("../catalog.zig");
const common = @import("../common.zig");

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
        if (is_iso) sys_cfg.isoDir() else sys_cfg.imagesDir();

    _ = linux.mkdir("/var/lib/diosix", 0o755);
    var dir_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    if (common.toPathZ(base_dir, &dir_z_buf)) |dz| {
        _ = linux.mkdir(dz.ptr, 0o755);
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

test "image/import: option enum parses --name flag" {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(
        ImportFlag.@"--name",
        std.meta.stringToEnum(ImportFlag, "--name").?,
    );
}
