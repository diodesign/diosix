// Diosix Image/ISO Repository Listing and Management.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("api.zig");
const catalog = @import("catalog.zig");
const common = @import("common.zig");
const image_pull = @import("image/pull.zig");

pub const CATALOG_CONFIG_PATH = "/etc/diosix/catalog.toml";
pub const fetchRemoteFile = image_pull.fetchRemoteFile;
pub const pullRemoteOrStageImage = image_pull.pullRemoteOrStageImage;

fn listImagesInDir(
    dir_path: []const u8,
    only_elf: bool,
    active_catalog: []const catalog.CatalogEntry,
) usize {
    var dir_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const dir_z = common.toPathZ(dir_path, &dir_z_buf) orelse return 0;

    const dir_res = linux.open(
        dir_z.ptr,
        .{ .ACCMODE = .RDONLY, .DIRECTORY = true },
        0,
    );
    const dir_signed: isize = @bitCast(dir_res);
    if (dir_signed < 0) return 0;
    const dir_fd: i32 = @intCast(dir_signed);
    defer _ = linux.close(dir_fd);

    var count: usize = 0;
    var dents_buf: [4096]u8 = undefined;
    while (true) {
        const nread_res = linux.getdents64(
            dir_fd,
            &dents_buf,
            dents_buf.len,
        );
        const nread: isize = @bitCast(nread_res);
        if (nread <= 0) break;

        var pos: usize = 0;
        const total: usize = @intCast(nread);
        while (pos < total) {
            const dent: *const common.LinuxDirent64 =
                @ptrCast(@alignCast(&dents_buf[pos]));
            pos += dent.d_reclen;
            const dname_ptr: [*:0]const u8 = @ptrCast(&dent.d_name);
            const dname = std.mem.span(dname_ptr);
            if (std.mem.startsWith(u8, dname, ".")) continue;
            if (only_elf and !std.mem.endsWith(u8, dname, ".elf")) continue;

            var file_path_buf: [common.MAX_PATH_LEN]u8 = undefined;
            const file_path = std.fmt.bufPrint(
                &file_path_buf,
                "{s}/{s}",
                .{ dir_path, dname },
            ) catch continue;
            var file_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
            const file_z = common.toPathZ(file_path, &file_z_buf) orelse
                continue;

            var link_buf: [common.MAX_PATH_LEN]u8 = undefined;
            const link_res = linux.readlink(
                file_z.ptr,
                &link_buf,
                link_buf.len,
            );
            const link_signed: isize = @bitCast(link_res);
            if (link_signed > 0) continue;

            var size_mb_val: usize = 0;
            const file_fd_res = linux.open(
                file_z.ptr,
                .{ .ACCMODE = .RDONLY },
                0,
            );
            const file_fd_signed: isize = @bitCast(file_fd_res);
            if (file_fd_signed >= 0) {
                const file_fd: i32 = @intCast(file_fd_signed);
                const end_off = linux.lseek(file_fd, 0, linux.SEEK.END);
                const end_signed: isize = @bitCast(end_off);
                if (end_signed > 0) {
                    size_mb_val =
                        @intCast(@divTrunc(end_signed, 1024 * 1024));
                }
                _ = linux.close(file_fd);
            }

            const is_iso = !only_elf and
                (std.mem.endsWith(u8, dname, ".iso") or
                    std.mem.eql(u8, dir_path, "/var/lib/diosix/iso"));
            const meta = catalog.inferImageMetadata(
                dname,
                is_iso,
                active_catalog,
            );

            var size_str_buf: [32]u8 = undefined;
            const size_str = if (size_mb_val >= 1024)
                std.fmt.bufPrint(
                    &size_str_buf,
                    "{d} GB",
                    .{size_mb_val / 1024},
                ) catch "1 GB"
            else
                std.fmt.bufPrint(
                    &size_str_buf,
                    "{d} MB",
                    .{size_mb_val},
                ) catch "16 MB";

            var line_buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(
                &line_buf,
                "{s:<28} {s:<9} {s:<16} {s:<8} {s:<10} {s}\n",
                .{
                    dname,
                    meta.tier,
                    meta.os_family,
                    meta.format,
                    size_str,
                    file_path,
                },
            ) catch continue;
            common.printStr(line);
            count += 1;
        }
    }
    return count;
}

pub fn cmdImage(client: *api.DiosixClient, args: []const [*:0]const u8) !void {
    const exe_name = common.getExeName();
    _ = client;
    if (args.len == 0) {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            \\Usage:
            \\  {s} image list [--remote] [--json]       List images/ISOs
            \\  {s} image catalog [--json]               List official catalog
            \\  {s} image pull <id|url> [options]        Pull & verify SHA-256
            \\      [--name <name>] [--sha256 <hex>]
            \\      [--allow-unverified] [--offline-stub] [--json]
            \\  {s} image import <file> [--name <name>]  Import local image
            \\  {s} image delete <name>                  Delete repository image
            \\
        , .{ exe_name, exe_name, exe_name, exe_name, exe_name }) catch return;
        common.printStr(msg);
        return;
    }

    var cat_mapped: ?[]const u8 = null;
    defer if (cat_mapped) |m| common.unmapBinaryFile(m);
    var parsed_entries: [catalog.MAX_CATALOG_ENTRIES]catalog.CatalogEntry =
        undefined;
    var active_catalog: []const catalog.CatalogEntry =
        &catalog.OFFICIAL_CATALOG;
    if (common.readBinaryFile(
        CATALOG_CONFIG_PATH,
        common.MAX_MANIFEST_SIZE,
    )) |content| {
        cat_mapped = content;
        const count = catalog.parseCatalogToml(content, &parsed_entries);
        if (count > 0) {
            active_catalog = parsed_entries[0..count];
        }
    } else |_| {}

    const ImageSubcmd = enum {
        catalog,
        list,
        ls,
        pull,
        fetch,
        import,
        add,
        delete,
        rm,
    };
    const subcmd = std.mem.span(args[0]);
    const parsed_subcmd = std.meta.stringToEnum(ImageSubcmd, subcmd) orelse {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "Unknown image subcommand '{s}'. Use '{s} image' for usage.\n",
            .{ subcmd, exe_name },
        ) catch return;
        common.printStr(msg);
        return;
    };

    const CommonImgFlag = enum { @"--remote", @"-r", @"--json", @"-j" };
    var remote_flag = false;
    var json_flag = false;
    for (args[1..]) |arg| {
        const span = std.mem.span(arg);
        if (std.meta.stringToEnum(CommonImgFlag, span)) |f| {
            switch (f) {
                .@"--remote", .@"-r" => remote_flag = true,
                .@"--json", .@"-j" => json_flag = true,
            }
        }
    }

    const is_list = parsed_subcmd == .list or parsed_subcmd == .ls;
    if (parsed_subcmd == .catalog or (is_list and remote_flag)) {
        var cat_buf: [4096]u8 = undefined;
        const out = if (json_flag)
            catalog.formatCatalogJsonFromSlice(&cat_buf, active_catalog)
        else
            catalog.formatCatalogTableFromSlice(&cat_buf, active_catalog);
        common.printStr(out);
        return;
    }

    switch (parsed_subcmd) {
        .catalog => unreachable,
        .list, .ls => {
            common.printStr(
                "Image / ISO name             Tier      OS family        " ++
                    "Format   Size       Path\n",
            );
            common.printStr(
                "--------------------------------------------------------" ++
                    "---------------------------------------\n",
            );

            _ = linux.mkdir("/var/lib/diosix", 0o755);
            _ = linux.mkdir("/var/lib/diosix/images", 0o755);
            _ = linux.mkdir("/var/lib/diosix/iso", 0o755);

            var total_found: usize = 0;
            total_found += listImagesInDir(
                "/var/lib/diosix/images",
                false,
                active_catalog,
            );
            total_found += listImagesInDir(
                "/var/lib/diosix/iso",
                false,
                active_catalog,
            );
            if (total_found == 0) {
                _ = listImagesInDir("/boot", true, active_catalog);
            }
        },
        .pull, .fetch => {
            try image_pull.cmdImagePull(
                exe_name,
                args,
                active_catalog,
                json_flag,
            );
        },
        .import, .add => {
            try image_pull.cmdImageImport(exe_name, args);
        },
        .delete, .rm => {
            if (args.len < 2) {
                common.printStr("Usage: dsx image delete <name>\n");
                return;
            }
            const img_name = std.mem.span(args[1]);
            const is_abs = std.mem.startsWith(u8, img_name, "/var/lib/diosix/");
            if ((is_abs and std.mem.indexOf(u8, img_name, "..") != null) or
                (!is_abs and !catalog.isValidImageName(img_name)))
            {
                common.printStr("Error: Invalid image name.\n");
                return;
            }
            var path_buf: [common.MAX_PATH_LEN]u8 = undefined;
            const path = if (is_abs)
                img_name
            else if (std.mem.endsWith(u8, img_name, ".iso"))
                std.fmt.bufPrint(
                    &path_buf,
                    "/var/lib/diosix/iso/{s}",
                    .{img_name},
                ) catch "/var/lib/diosix/iso/image.iso"
            else if (std.mem.endsWith(u8, img_name, ".elf"))
                std.fmt.bufPrint(
                    &path_buf,
                    "/var/lib/diosix/images/{s}",
                    .{img_name},
                ) catch "/var/lib/diosix/images/image.elf"
            else
                std.fmt.bufPrint(
                    &path_buf,
                    "/var/lib/diosix/images/{s}.elf",
                    .{img_name},
                ) catch "/var/lib/diosix/images/image.elf";

            var z_buf: [common.MAX_PATH_LEN]u8 = undefined;
            const z_path = common.toPathZ(path, &z_buf) orelse return;
            const un_res = linux.unlink(z_path.ptr);
            const un_signed: isize = @bitCast(un_res);
            if (un_signed < 0) {
                var err_buf: [128]u8 = undefined;
                const err_msg = std.fmt.bufPrint(
                    &err_buf,
                    "Error: Image '{s}' not found.\n",
                    .{img_name},
                ) catch "Error: Image not found.\n";
                common.printStr(err_msg);
                return;
            }
            var out_buf: [256]u8 = undefined;
            const out_msg = std.fmt.bufPrint(
                &out_buf,
                "✓ Image '{s}' deleted.\n",
                .{img_name},
            ) catch return;
            common.printStr(out_msg);
        },
    }
}

test "image: declarations and image_pull re-exports compile cleanly" {
    std.testing.refAllDecls(@This());
    _ = image_pull;
}
