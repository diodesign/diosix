// Diosix Image/ISO Repository Listing and Management.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("api.zig");
const catalog = @import("catalog.zig");
const common = @import("common.zig");
const sysconfig = @import("sysconfig.zig");
const disk = @import("storage/disk.zig");
const image_pull = @import("image/pull.zig");
const image_import = @import("image/import.zig");

pub const CATALOG_CONFIG_PATH = sysconfig.DEFAULT_CATALOG_CONFIG_PATH;
pub const fetchRemoteFile = image_pull.fetchRemoteFile;
pub const pullRemoteOrStageImage = image_pull.pullRemoteOrStageImage;
pub const cmdImageImport = image_import.cmdImageImport;
pub const cmdImageVerify = image_import.cmdImageVerify;

const SYMLINK_PROBE_BYTES: usize = 1;

fn makeDir(path: []const u8) void {
    var z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    if (common.toPathZ(path, &z_buf)) |z| {
        _ = linux.mkdir(z.ptr, 0o755);
    }
}

fn listImagesInDir(
    dir_path: []const u8,
    iso_dir: []const u8,
    only_elf: bool,
    active_catalog: []const catalog.CatalogEntry,
    json_out: ?*std.ArrayList(u8),
    first_json: *bool,
) usize {
    var dir_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const dir_z = common.toPathZ(dir_path, &dir_z_buf) orelse {
        disk.reportPathTooLong();
        return 0;
    };

    const dir_res = linux.open(
        dir_z.ptr,
        .{ .ACCMODE = .RDONLY, .DIRECTORY = true },
        0,
    );
    const dir_signed: isize = @bitCast(dir_res);
    if (dir_signed < 0) return 0;
    const dir_fd: i32 = @intCast(dir_signed);
    defer _ = linux.close(dir_fd);

    const allocator = std.heap.page_allocator;
    var count: usize = 0;
    var dents_buf: [disk.DIRENT_BUF_BYTES]u8 = undefined;
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

            var file_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
            const file_z = disk.joinPathZ(
                &file_z_buf,
                dir_path,
                dname,
            ) orelse {
                common.printFmt("Error: Path too long for '{s}'.\n", .{dname});
                continue;
            };
            const file_path: []const u8 = file_z;

            var link_probe: [SYMLINK_PROBE_BYTES]u8 = undefined;
            const link_res = linux.readlink(
                file_z.ptr,
                &link_probe,
                link_probe.len,
            );
            const link_signed: isize = @bitCast(link_res);
            if (link_signed > 0) continue;

            const size_mb = disk.fileSizeBytes(file_z.ptr) / disk.MIB_BYTES;
            const is_iso = !only_elf and
                (std.mem.endsWith(u8, dname, ".iso") or
                    std.mem.eql(u8, dir_path, iso_dir));
            const meta = catalog.inferImageMetadata(
                dname,
                is_iso,
                active_catalog,
            );

            if (json_out) |out| {
                if (!first_json.*) {
                    out.append(allocator, ',') catch continue;
                }
                first_json.* = false;
                out.appendSlice(allocator, "{\"name\":\"") catch continue;
                common.writeJsonEscaped(out, allocator, dname) catch continue;
                out.appendSlice(allocator, "\",\"tier\":\"") catch continue;
                common.writeJsonEscaped(out, allocator, meta.tier) catch
                    continue;
                out.appendSlice(allocator, "\",\"os_family\":\"") catch
                    continue;
                common.writeJsonEscaped(out, allocator, meta.os_family) catch
                    continue;
                out.appendSlice(allocator, "\",\"format\":\"") catch continue;
                common.writeJsonEscaped(out, allocator, meta.format) catch
                    continue;
                const sz_part = allocator.print(
                    "\",\"size_mb\":{d},\"path\":\"",
                    .{size_mb},
                ) catch continue;
                defer allocator.free(sz_part);
                out.appendSlice(allocator, sz_part) catch continue;
                common.writeJsonEscaped(out, allocator, file_path) catch
                    continue;
                out.appendSlice(allocator, "\"}") catch continue;
            } else {
                var size_buf: [disk.SIZE_STR_BYTES]u8 = undefined;
                const size_str = disk.formatSizeMb(&size_buf, size_mb);
                common.printFmt(
                    "{s:<28} {s:<9} {s:<16} {s:<8} {s:<10} {s}\n",
                    .{
                        dname,
                        meta.tier,
                        meta.os_family,
                        meta.format,
                        size_str,
                        file_path,
                    },
                );
            }
            count += 1;
        }
    }
    return count;
}

fn printCatalog(
    active_catalog: []const catalog.CatalogEntry,
    json_flag: bool,
) !void {
    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer aw.deinit();
    if (json_flag) {
        try catalog.writeCatalogJson(&aw.writer, active_catalog);
    } else {
        try catalog.writeCatalogTable(&aw.writer, active_catalog);
    }
    common.printStr(aw.written());
}

fn imageList(
    images_dir: []const u8,
    iso_dir: []const u8,
    active_catalog: []const catalog.CatalogEntry,
    json_flag: bool,
) void {
    _ = linux.mkdir(sysconfig.VAR_LIB_DIOSIX_DIR, 0o755);
    makeDir(images_dir);
    makeDir(iso_dir);

    var first_json = true;
    if (json_flag) {
        const allocator = std.heap.page_allocator;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        out.append(allocator, '[') catch return;
        _ = listImagesInDir(
            images_dir,
            iso_dir,
            false,
            active_catalog,
            &out,
            &first_json,
        );
        _ = listImagesInDir(
            iso_dir,
            iso_dir,
            false,
            active_catalog,
            &out,
            &first_json,
        );
        out.appendSlice(allocator, "]\n") catch return;
        common.printStr(out.items);
        return;
    }

    common.printStr(
        "Image / ISO name             Tier      OS family        " ++
            "Format   Size       Path\n",
    );
    common.printStr(
        "--------------------------------------------------------" ++
            "---------------------------------------\n",
    );
    _ = listImagesInDir(
        images_dir,
        iso_dir,
        false,
        active_catalog,
        null,
        &first_json,
    );
    _ = listImagesInDir(
        iso_dir,
        iso_dir,
        false,
        active_catalog,
        null,
        &first_json,
    );
}

fn imageDelete(
    images_dir: []const u8,
    iso_dir: []const u8,
    args: []const [*:0]const u8,
) !void {
    if (args.len < 2) {
        common.printStr("Usage: dsx image delete <name>\n");
        return;
    }
    const img_name = std.mem.span(args[1]);
    if (!common.isSafeIdentifier(img_name) or
        !catalog.isValidImageName(img_name))
    {
        common.printStr("Error: Invalid image name.\n");
        return;
    }

    const allocator = std.heap.page_allocator;
    const is_iso = std.mem.endsWith(u8, img_name, ".iso");
    const has_ext = is_iso or
        std.mem.endsWith(u8, img_name, ".elf") or
        std.mem.endsWith(u8, img_name, ".bin");
    const base_dir = if (is_iso) iso_dir else images_dir;
    const exts = if (has_ext)
        &[_][]const u8{""}
    else
        &[_][]const u8{ "", ".elf", ".bin" };

    for (exts) |ext| {
        const path = try allocator.print("{s}/{s}{s}", .{
            base_dir,
            img_name,
            ext,
        });
        defer allocator.free(path);
        var z_buf: [common.MAX_PATH_LEN]u8 = undefined;
        const z_path = common.toPathZ(path, &z_buf) orelse {
            disk.reportPathTooLong();
            return;
        };
        const un_res = linux.unlink(z_path.ptr);
        const un_signed: isize = @bitCast(un_res);
        if (un_signed == 0) {
            common.printFmt("✓ Image '{s}' deleted.\n", .{img_name});
            return;
        }
    }
    common.printFmt("Error: Image '{s}' not found.\n", .{img_name});
}

pub fn cmdImage(client: *api.DiosixClient, args: []const [*:0]const u8) !void {
    const exe_name = common.getExeName();
    const sys_cfg = common.loadRuntimeSystemConfig();
    const images_dir = sys_cfg.imagesDir();
    const iso_dir = sys_cfg.isoDir();
    _ = client;
    if (args.len == 0) {
        common.printFmt(
            \\Usage:
            \\  {s} image list [--remote] [--json]       List images/ISOs
            \\  {s} image catalog [--json]               List official catalog
            \\  {s} image pull <id|url> [options]        Pull & verify SHA-256
            \\      [--name <name>] [--sha256 <hex>]
            \\      [--allow-unverified] [--offline-stub] [--json]
            \\  {s} image import <file> [--name <name>]  Import local image
            \\  {s} image verify <name> [--sha256 <hex>] Verify image SHA-256
            \\  {s} image delete <name>                  Delete repository image
            \\
        , .{ exe_name, exe_name, exe_name, exe_name, exe_name, exe_name });
        return;
    }

    var cat_mapped: ?[]const u8 = null;
    defer if (cat_mapped) |m| common.unmapBinaryFile(m);
    var parsed_entries: [catalog.MAX_CATALOG_ENTRIES]catalog.CatalogEntry =
        undefined;
    var active_catalog: []const catalog.CatalogEntry =
        &catalog.OFFICIAL_CATALOG;
    if (common.readBinaryFile(
        sys_cfg.catalogConfigPath(),
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
        verify,
        delete,
        rm,
    };
    const subcmd = std.mem.span(args[0]);
    const parsed_subcmd = std.meta.stringToEnum(ImageSubcmd, subcmd) orelse {
        common.printFmt(
            "Unknown image subcommand '{s}'. Use '{s} image' for usage.\n",
            .{ subcmd, exe_name },
        );
        return;
    };

    const RemoteFlag = enum { @"--remote", @"-r" };
    var remote_flag = false;
    var json_flag = false;
    for (args[1..]) |arg| {
        const span = std.mem.span(arg);
        if (common.isJsonFlag(span)) {
            json_flag = true;
        } else if (std.meta.stringToEnum(RemoteFlag, span) != null) {
            remote_flag = true;
        }
    }

    const is_list = parsed_subcmd == .list or parsed_subcmd == .ls;
    if (parsed_subcmd == .catalog or (is_list and remote_flag)) {
        try printCatalog(active_catalog, json_flag);
        return;
    }

    switch (parsed_subcmd) {
        .catalog => unreachable,
        .list, .ls => imageList(images_dir, iso_dir, active_catalog, json_flag),
        .pull, .fetch => {
            try image_pull.cmdImagePull(
                exe_name,
                args,
                active_catalog,
                json_flag,
            );
        },
        .import, .add => {
            try image_import.cmdImageImport(exe_name, args);
        },
        .verify => {
            try cmdImageVerify(
                images_dir,
                iso_dir,
                args,
                active_catalog,
                json_flag,
            );
        },
        .delete, .rm => try imageDelete(images_dir, iso_dir, args),
    }
}

test "image: declarations and image_pull re-exports compile cleanly" {
    std.testing.refAllDecls(@This());
    _ = image_pull;
    _ = image_import;
}
