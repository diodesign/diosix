// Virtual Disk Provisioning & Management (/var/lib/diosix/disks).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("api.zig");
const common = @import("common.zig");
const sysconfig = @import("sysconfig.zig");
const image = @import("image.zig");
const snapshot = @import("snapshot.zig");
const disk = @import("storage/disk.zig");

pub const CATALOG_CONFIG_PATH = image.CATALOG_CONFIG_PATH;
pub const EXT4_SUPERBLOCK_OFFSET = disk.EXT4_SUPERBLOCK_OFFSET;
pub const EXT4_MAGIC_OFFSET = disk.EXT4_MAGIC_OFFSET;
pub const EXT4_SUPER_MAGIC = disk.EXT4_SUPER_MAGIC;
pub const MIB_BYTES = disk.MIB_BYTES;

pub const findAttachedGuest = common.findAttachedGuest;
pub const fetchRemoteFile = image.fetchRemoteFile;
pub const pullRemoteOrStageImage = image.pullRemoteOrStageImage;
pub const cmdImage = image.cmdImage;
pub const cmdSnapshot = snapshot.cmdSnapshot;
pub const detectDiskFormat = disk.detectDiskFormat;
pub const resolveDiskPath = disk.resolveDiskPath;
pub const formatAndSeedDisk = disk.formatAndSeedDisk;
pub const provisionVirtualDisk = disk.provisionVirtualDisk;

fn listVirtualDisks(json_mode: bool) void {
    const sys_cfg = common.loadRuntimeSystemConfig();
    const disks_dir = sys_cfg.disksDir();
    _ = linux.mkdir(sysconfig.VAR_LIB_DIOSIX_DIR, 0o755);
    var dir_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const dir_z = common.toPathZ(disks_dir, &dir_z_buf) orelse {
        disk.reportPathTooLong();
        return;
    };
    _ = linux.mkdir(dir_z.ptr, 0o755);

    const allocator = std.heap.page_allocator;
    var json_out: std.ArrayList(u8) = .empty;
    defer json_out.deinit(allocator);
    var first_json = true;

    if (json_mode) {
        json_out.append(allocator, '[') catch return;
    } else {
        common.printStr(
            "Disk Name             Capacity   Format   " ++
                "Attached VM        Path\n",
        );
        common.printStr(
            "---------------------------------------------------------------" ++
                "----------------------------\n",
        );
    }

    const dir_res = linux.open(
        dir_z.ptr,
        .{ .ACCMODE = .RDONLY, .DIRECTORY = true },
        0,
    );
    const dir_signed: isize = @bitCast(dir_res);
    if (dir_signed >= 0) {
        const dir_fd: i32 = @intCast(dir_signed);
        defer _ = linux.close(dir_fd);

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
                if (std.mem.eql(u8, dname, ".") or
                    std.mem.eql(u8, dname, "..")) continue;

                var file_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
                const file_z = disk.joinPathZ(
                    &file_z_buf,
                    disks_dir,
                    dname,
                ) orelse {
                    common.printFmt(
                        "Error: Path too long for '{s}'.\n",
                        .{dname},
                    );
                    continue;
                };
                const file_path: []const u8 = file_z;

                const size_mb = disk.fileSizeBytes(file_z.ptr) / MIB_BYTES;
                const fmt_str = detectDiskFormat(file_z.ptr);
                var att_buf: [disk.ATTACHED_LABEL_BYTES]u8 = undefined;
                const att_str = findAttachedGuest(file_path, &att_buf);

                if (json_mode) {
                    if (!first_json) {
                        json_out.append(allocator, ',') catch continue;
                    }
                    first_json = false;
                    json_out.appendSlice(allocator, "{\"name\":\"") catch
                        continue;
                    common.writeJsonEscaped(&json_out, allocator, dname) catch
                        continue;
                    const sz_part = allocator.print(
                        "\",\"size_mb\":{d},\"format\":\"",
                        .{size_mb},
                    ) catch continue;
                    defer allocator.free(sz_part);
                    json_out.appendSlice(allocator, sz_part) catch continue;
                    common.writeJsonEscaped(&json_out, allocator, fmt_str) catch
                        continue;
                    json_out.appendSlice(
                        allocator,
                        "\",\"attached_vm\":\"",
                    ) catch continue;
                    common.writeJsonEscaped(&json_out, allocator, att_str) catch
                        continue;
                    json_out.appendSlice(allocator, "\",\"path\":\"") catch
                        continue;
                    common.writeJsonEscaped(
                        &json_out,
                        allocator,
                        file_path,
                    ) catch continue;
                    json_out.appendSlice(allocator, "\"}") catch continue;
                } else {
                    var size_buf: [disk.SIZE_STR_BYTES]u8 = undefined;
                    const size_str = disk.formatSizeMb(&size_buf, size_mb);
                    common.printFmt(
                        "{s:<21} {s:<10} {s:<8} {s:<18} {s}\n",
                        .{ dname, size_str, fmt_str, att_str, file_path },
                    );
                }
            }
        }
    }

    if (json_mode) {
        json_out.appendSlice(allocator, "]\n") catch return;
        common.printStr(json_out.items);
    }
}

fn parseSizeArg(
    exe_name: []const u8,
    subcmd: []const u8,
    args: []const [*:0]const u8,
    default_size: ?[]const u8,
) !?[]const u8 {
    const DiskFlag = enum { @"--size", @"-s" };
    var size_str = default_size;
    var idx: usize = 2;
    while (idx < args.len) : (idx += 1) {
        const span = std.mem.span(args[idx]);
        if (std.meta.stringToEnum(DiskFlag, span)) |_| {
            if (idx + 1 >= args.len) {
                common.printStr(
                    "Error: Option '--size' requires a capacity " ++
                        "(e.g. '1GiB', '512M').\n",
                );
                return error.InvalidArgs;
            }
            idx += 1;
            size_str = std.mem.span(args[idx]);
        } else if (std.mem.startsWith(u8, span, "-")) {
            common.printFmt(
                "Error: Unknown option '{s}'. " ++
                    "Usage: {s} disk {s} <name> [--size <size>]\n",
                .{ span, exe_name, subcmd },
            );
            return error.InvalidArgs;
        }
    }
    return size_str;
}

fn diskCreate(exe_name: []const u8, args: []const [*:0]const u8) void {
    if (args.len < 2) {
        common.printStr("Usage: dsx disk create <name> [--size <size>]\n");
        return;
    }
    const disk_name = std.mem.span(args[1]);
    const size_str = (parseSizeArg(
        exe_name,
        "create",
        args,
        "1GiB",
    ) catch return).?;

    const size_mb = common.parseMemorySizeMb(size_str);
    var path_buf: [common.MAX_PATH_LEN]u8 = undefined;
    if (provisionVirtualDisk(disk_name, size_mb, &path_buf)) |path| {
        common.printFmt(
            "✓ Virtual disk '{s}' ({d} MB, ext4) created at {s}.\n",
            .{ disk_name, size_mb, path },
        );
    } else {
        common.printStr("Error: Failed to create virtual disk file.\n");
    }
}

fn diskInfo(args: []const [*:0]const u8) void {
    if (args.len < 2) {
        common.printStr("Usage: dsx disk info <name>\n");
        return;
    }
    const disk_name = std.mem.span(args[1]);
    var path_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const path = resolveDiskPath(disk_name, &path_buf) orelse {
        common.printStr("Error: Invalid disk name or path.\n");
        return;
    };
    var file_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const file_z = common.toPathZ(path, &file_z_buf) orelse {
        disk.reportPathTooLong();
        return;
    };

    const fd_res = linux.open(file_z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    const fd_signed: isize = @bitCast(fd_res);
    if (fd_signed < 0) {
        common.printFmt(
            "Error: Virtual disk '{s}' not found.\n",
            .{disk_name},
        );
        return;
    }
    const file_fd: i32 = @intCast(fd_signed);
    const end_off = linux.lseek(file_fd, 0, linux.SEEK.END);
    _ = linux.close(file_fd);
    const end_signed: isize = @bitCast(end_off);
    const size_bytes: u64 = if (end_signed > 0) @intCast(end_signed) else 0;
    const size_mb_val = size_bytes / MIB_BYTES;

    const fmt_str = detectDiskFormat(file_z.ptr);
    var att_buf: [disk.ATTACHED_LABEL_BYTES]u8 = undefined;
    const att_str = findAttachedGuest(path, &att_buf);

    common.printFmt(
        \\Disk Name      : {s}
        \\Path           : {s}
        \\Capacity       : {d} MB ({d} bytes)
        \\Format         : {s}
        \\Attached VM    : {s}
        \\
    , .{ disk_name, path, size_mb_val, size_bytes, fmt_str, att_str });
}

fn diskDelete(args: []const [*:0]const u8) void {
    if (args.len < 2) {
        common.printStr("Usage: dsx disk delete <name>\n");
        return;
    }
    const disk_name = std.mem.span(args[1]);
    var path_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const path = resolveDiskPath(disk_name, &path_buf) orelse {
        common.printStr("Error: Invalid disk name or path.\n");
        return;
    };
    var z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const z_path = common.toPathZ(path, &z_buf) orelse {
        disk.reportPathTooLong();
        return;
    };

    var att_buf: [disk.ATTACHED_LABEL_BYTES]u8 = undefined;
    const att_str = findAttachedGuest(path, &att_buf);
    if (!std.mem.eql(u8, att_str, "-")) {
        common.printFmt(
            "Error: Cannot delete virtual disk '{s}': currently " ++
                "attached to running VM '{s}'. Stop the VM first.\n",
            .{ disk_name, att_str },
        );
        return;
    }

    if (@as(isize, @bitCast(linux.unlink(z_path.ptr))) < 0) {
        common.printFmt(
            "Error: Virtual disk '{s}' not found.\n",
            .{disk_name},
        );
        return;
    }
    common.printFmt("✓ Virtual disk '{s}' deleted.\n", .{disk_name});
}

fn diskResize(exe_name: []const u8, args: []const [*:0]const u8) void {
    if (args.len < 2) {
        common.printStr("Usage: dsx disk resize <name> --size <size>\n");
        return;
    }
    const disk_name = std.mem.span(args[1]);
    const size_str = (parseSizeArg(exe_name, "resize", args, null) catch
        return) orelse {
        common.printStr(
            "Error: Option '--size <size>' is required for resize.\n",
        );
        return;
    };
    const size_mb = common.parseMemorySizeMb(size_str);
    const size_bytes: u64 = @as(u64, size_mb) * MIB_BYTES;

    var path_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const path = resolveDiskPath(disk_name, &path_buf) orelse {
        common.printStr("Error: Invalid disk name or path.\n");
        return;
    };
    var z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const z_path = common.toPathZ(path, &z_buf) orelse {
        disk.reportPathTooLong();
        return;
    };

    disk.resizeVirtualDisk(z_path.ptr, size_bytes) catch |err| {
        switch (err) {
            error.FileNotFound => common.printStr(
                "Error: Virtual disk not found.\n",
            ),
            error.CannotShrinkDisk => common.printStr(
                "Error: Shrinking virtual disks is not supported.\n",
            ),
            else => common.printStr("Error: Failed to resize virtual disk.\n"),
        }
        return;
    };

    common.printFmt(
        "✓ Virtual disk '{s}' resized to {d} MB ({s}).\n",
        .{ disk_name, size_mb, size_str },
    );
}

pub fn cmdDisk(client: *api.DiosixClient, args: []const [*:0]const u8) !void {
    const exe_name = common.getExeName();
    _ = client;
    if (args.len == 0) {
        common.printFmt(
            \\Usage:
            \\  {s} disk create <name> [--size <size>]  Create virtual disk
            \\  {s} disk list [--json]                  List virtual disks
            \\  {s} disk info <name>                    Show disk details
            \\  {s} disk delete <name>                  Delete virtual disk
            \\  {s} disk resize <name> --size <size>    Resize virtual disk
            \\
        , .{ exe_name, exe_name, exe_name, exe_name, exe_name });
        return;
    }

    const DiskSubcmd = enum { create, add, list, ls, info, delete, rm, resize };
    const subcmd = std.mem.span(args[0]);
    const parsed_subcmd = std.meta.stringToEnum(DiskSubcmd, subcmd) orelse {
        common.printFmt(
            "Unknown disk subcommand '{s}'. Use '{s} disk' for usage.\n",
            .{ subcmd, exe_name },
        );
        return;
    };

    var json_mode = false;
    for (args[1..]) |arg| {
        if (common.isJsonFlag(std.mem.span(arg))) json_mode = true;
    }

    switch (parsed_subcmd) {
        .create, .add => diskCreate(exe_name, args),
        .list, .ls => listVirtualDisks(json_mode),
        .info => diskInfo(args),
        .delete, .rm => diskDelete(args),
        .resize => diskResize(exe_name, args),
    }
}

test "storage: resolveDiskPath validates names and rejects traversal" {
    std.testing.refAllDecls(@This());
    _ = image;
    _ = snapshot;
    _ = disk;
    var buf: [common.MAX_PATH_LEN]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/var/lib/diosix/disks/data.img",
        resolveDiskPath("data", &buf).?,
    );
    try std.testing.expect(resolveDiskPath("../etc/shadow", &buf) == null);
}
