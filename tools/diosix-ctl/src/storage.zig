// Virtual Disk Provisioning & Management (/var/lib/diosix/disks).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("api.zig");
const common = @import("common.zig");
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

fn listVirtualDisks() void {
    const sys_cfg = common.loadRuntimeSystemConfig();
    const disks_dir = sys_cfg.disksDir();
    common.printStr(
        "Disk Name             Capacity   Format   Attached VM        Path\n",
    );
    common.printStr(
        "---------------------------------------------------------------" ++
            "----------------------------\n",
    );

    _ = linux.mkdir("/var/lib/diosix", 0o755);
    var dir_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const dir_z = common.toPathZ(disks_dir, &dir_z_buf) orelse return;
    _ = linux.mkdir(dir_z.ptr, 0o755);

    const dir_res = linux.open(
        dir_z.ptr,
        .{ .ACCMODE = .RDONLY, .DIRECTORY = true },
        0,
    );
    const dir_signed: isize = @bitCast(dir_res);
    if (dir_signed < 0) return;
    const dir_fd: i32 = @intCast(dir_signed);
    defer _ = linux.close(dir_fd);

    var dents_buf: [4096]u8 = undefined;
    while (true) {
        const nread_res = linux.getdents64(dir_fd, &dents_buf, dents_buf.len);
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

            var fp_buf: [common.MAX_PATH_LEN]u8 = undefined;
            const file_path = std.fmt.bufPrint(
                &fp_buf,
                "{s}/{s}",
                .{ disks_dir, dname },
            ) catch continue;
            var file_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
            const file_z = common.toPathZ(file_path, &file_z_buf) orelse
                continue;

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
                    size_mb_val = @intCast(@divTrunc(end_signed, MIB_BYTES));
                }
                _ = linux.close(file_fd);
            }

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
                ) catch "256 MB";

            const fmt_str = detectDiskFormat(file_z.ptr);
            var att_buf: [64]u8 = undefined;
            const att_str = findAttachedGuest(file_path, &att_buf);

            var line_buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(
                &line_buf,
                "{s:<21} {s:<10} {s:<8} {s:<18} {s}\n",
                .{ dname, size_str, fmt_str, att_str, file_path },
            ) catch continue;
            common.printStr(line);
        }
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
            var err_buf: [160]u8 = undefined;
            const err_msg = std.fmt.bufPrint(
                &err_buf,
                "Error: Unknown option '{s}'. " ++
                    "Usage: {s} disk {s} <name> [--size <size>]\n",
                .{ span, exe_name, subcmd },
            ) catch "Error: Unknown option.\n";
            common.printStr(err_msg);
            return error.InvalidArgs;
        }
    }
    return size_str;
}

pub fn cmdDisk(client: *api.DiosixClient, args: []const [*:0]const u8) !void {
    const exe_name = common.getExeName();
    _ = client;
    if (args.len == 0) {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            \\Usage:
            \\  {s} disk create <name> [--size <size>]  Create virtual disk
            \\  {s} disk list                           List virtual disks
            \\  {s} disk info <name>                    Show disk details
            \\  {s} disk delete <name>                  Delete virtual disk
            \\  {s} disk resize <name> --size <size>    Resize virtual disk
            \\
        , .{ exe_name, exe_name, exe_name, exe_name, exe_name }) catch return;
        common.printStr(msg);
        return;
    }

    const DiskSubcmd = enum { create, add, list, ls, info, delete, rm, resize };
    const subcmd = std.mem.span(args[0]);
    const parsed_subcmd = std.meta.stringToEnum(DiskSubcmd, subcmd) orelse {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "Unknown disk subcommand '{s}'. Use '{s} disk' for usage.\n",
            .{ subcmd, exe_name },
        ) catch return;
        common.printStr(msg);
        return;
    };

    switch (parsed_subcmd) {
        .create, .add => {
            if (args.len < 2) {
                common.printStr(
                    "Usage: dsx disk create <name> [--size <size>]\n",
                );
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
                var out_buf: [256]u8 = undefined;
                const out_msg = std.fmt.bufPrint(
                    &out_buf,
                    "✓ Virtual disk '{s}' ({d} MB, ext4) created at {s}.\n",
                    .{ disk_name, size_mb, path },
                ) catch return;
                common.printStr(out_msg);
            } else {
                common.printStr("Error: Failed to create virtual disk file.\n");
            }
        },
        .list, .ls => listVirtualDisks(),
        .info => {
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
            const file_z = common.toPathZ(path, &file_z_buf) orelse return;

            const fd_res = linux.open(file_z.ptr, .{ .ACCMODE = .RDONLY }, 0);
            const fd_signed: isize = @bitCast(fd_res);
            if (fd_signed < 0) {
                var err_buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(
                    &err_buf,
                    "Error: Virtual disk '{s}' not found.\n",
                    .{disk_name},
                ) catch "Error: Disk not found.\n";
                common.printStr(msg);
                return;
            }
            const file_fd: i32 = @intCast(fd_signed);
            const end_off = linux.lseek(file_fd, 0, linux.SEEK.END);
            _ = linux.close(file_fd);
            const end_signed: isize = @bitCast(end_off);
            const size_bytes: u64 =
                if (end_signed > 0) @intCast(end_signed) else 0;
            const size_mb_val = size_bytes / (MIB_BYTES);

            const fmt_str = detectDiskFormat(file_z.ptr);
            var att_buf: [64]u8 = undefined;
            const att_str = findAttachedGuest(path, &att_buf);

            var out_buf: [512]u8 = undefined;
            const info_msg = std.fmt.bufPrint(&out_buf,
                \\Disk Name      : {s}
                \\Path           : {s}
                \\Capacity       : {d} MB ({d} bytes)
                \\Format         : {s}
                \\Attached VM    : {s}
                \\
            , .{
                disk_name, path, size_mb_val, size_bytes, fmt_str, att_str,
            }) catch return;
            common.printStr(info_msg);
        },
        .delete, .rm => {
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
            const z_path = common.toPathZ(path, &z_buf) orelse return;

            var att_buf: [64]u8 = undefined;
            const att_str = findAttachedGuest(path, &att_buf);
            if (!std.mem.eql(u8, att_str, "-")) {
                var err_buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(
                    &err_buf,
                    "Error: Cannot delete virtual disk '{s}': currently " ++
                        "attached to running VM '{s}'. Stop the VM first.\n",
                    .{ disk_name, att_str },
                ) catch "Error: Disk in use.\n";
                common.printStr(msg);
                return;
            }

            if (@as(isize, @bitCast(linux.unlink(z_path.ptr))) < 0) {
                var err_buf: [128]u8 = undefined;
                const fmt = "Error: Virtual disk '{s}' not found.\n";
                const msg = std.fmt.bufPrint(&err_buf, fmt, .{disk_name}) catch
                    "Error: Disk not found.\n";
                common.printStr(msg);
                return;
            }
            var out_buf: [256]u8 = undefined;
            const out_fmt = "✓ Virtual disk '{s}' deleted.\n";
            const out_msg =
                std.fmt.bufPrint(&out_buf, out_fmt, .{disk_name}) catch return;
            common.printStr(out_msg);
        },
        .resize => {
            if (args.len < 2) {
                common.printStr(
                    "Usage: dsx disk resize <name> --size <size>\n",
                );
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
            const z_path = common.toPathZ(path, &z_buf) orelse return;

            const fd_res = linux.open(z_path.ptr, .{ .ACCMODE = .RDWR }, 0);
            const fd_signed: isize = @bitCast(fd_res);
            if (fd_signed < 0) {
                common.printStr("Error: Virtual disk not found.\n");
                return;
            }
            const fd: i32 = @intCast(fd_signed);
            defer _ = linux.close(fd);

            _ = linux.ftruncate(fd, @intCast(size_bytes));
            var out_buf: [256]u8 = undefined;
            const r_fmt = "✓ Virtual disk '{s}' resized to {d} MB ({s}).\n";
            const r_args = .{ disk_name, size_mb, size_str };
            const out_msg =
                std.fmt.bufPrint(&out_buf, r_fmt, r_args) catch return;
            common.printStr(out_msg);
        },
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
