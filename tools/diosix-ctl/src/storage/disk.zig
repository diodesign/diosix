// Virtual Disk Format Detection, Path Resolution & Provisioning.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const common = @import("../common.zig");
const console = @import("../console.zig");
const loader = @import("../loader.zig");
const sysconfig = @import("../sysconfig.zig");

pub const EXT4_SUPERBLOCK_OFFSET: usize = 1024;
pub const EXT4_MAGIC_OFFSET: usize = EXT4_SUPERBLOCK_OFFSET + 56;
pub const EXT4_SUPER_MAGIC: u16 = 0xef53;
pub const MIB_BYTES: usize = 1024 * 1024;

pub const DIRENT_BUF_BYTES: usize = 4096;
pub const SIZE_STR_BYTES: usize = 24;
pub const ATTACHED_LABEL_BYTES: usize = 160;
pub const EXT4_LABEL_MAX: usize = 16;

const DEFAULT_DISK_LABEL = "diosix-data";
const STAGING_PATH_MAX: usize = 128;

pub fn reportPathTooLong() void {
    common.printStr("Error: Path too long.\n");
}

pub fn joinPathZ(buf: []u8, dir: []const u8, name: []const u8) ?[:0]const u8 {
    return std.mem.printSentinel(buf, "{s}/{s}", .{ dir, name }, 0) catch null;
}

pub fn fileSizeBytes(path_z: [*:0]const u8) u64 {
    const fd_res = linux.open(path_z, .{ .ACCMODE = .RDONLY }, 0);
    const fd_signed: isize = @bitCast(fd_res);
    if (fd_signed < 0) return 0;
    const fd: i32 = @intCast(fd_signed);
    defer _ = linux.close(fd);
    const end_off = linux.lseek(fd, 0, linux.SEEK.END);
    const end_signed: isize = @bitCast(end_off);
    return if (end_signed > 0) @intCast(end_signed) else 0;
}

pub fn formatSizeMb(buf: *[SIZE_STR_BYTES]u8, size_mb: u64) []const u8 {
    return if (size_mb >= 1024)
        std.fmt.bufPrint(buf, "{d} GB", .{size_mb / 1024}) catch unreachable
    else
        std.fmt.bufPrint(buf, "{d} MB", .{size_mb}) catch unreachable;
}

pub fn isSafeNameUnderDir(name: []const u8, dir: []const u8) bool {
    const allocator = std.heap.page_allocator;
    var scratch: [console.STACK_FMT_BYTES]u8 = undefined;
    const prefix = console.formatSpill(
        allocator,
        &scratch,
        "{s}/",
        .{dir},
    ) catch return false;
    defer prefix.deinit(allocator);
    return common.isSafeStoragePath(name, prefix.text);
}

pub fn ext4LabelZ(
    name: []const u8,
    out: *[EXT4_LABEL_MAX + 1]u8,
) [:0]const u8 {
    const src = if (name.len == 0) DEFAULT_DISK_LABEL else name;
    const len = @min(src.len, EXT4_LABEL_MAX);
    @memcpy(out[0..len], src[0..len]);
    out[len] = 0;
    return out[0..len :0];
}

pub fn detectDiskFormat(file_path_z: [*:0]const u8) []const u8 {
    const fd_res = linux.open(
        @ptrCast(file_path_z),
        .{ .ACCMODE = .RDONLY },
        0,
    );
    const fd_signed: isize = @bitCast(fd_res);
    if (fd_signed < 0) return "raw";
    const fd: i32 = @intCast(fd_signed);
    defer _ = linux.close(fd);

    const seek_res = linux.lseek(fd, EXT4_MAGIC_OFFSET, linux.SEEK.SET);
    const seek_signed: isize = @bitCast(seek_res);
    if (seek_signed == EXT4_MAGIC_OFFSET) {
        var magic_buf: [@sizeOf(u16)]u8 = undefined;
        const nread_res = linux.read(fd, &magic_buf, magic_buf.len);
        const nread: isize = @bitCast(nread_res);
        if (nread == magic_buf.len and
            std.mem.readInt(u16, &magic_buf, .little) == EXT4_SUPER_MAGIC)
        {
            return "ext4";
        }
    }
    return "raw";
}

pub fn resolveDiskPath(disk_name: []const u8, out_buf: []u8) ?[]const u8 {
    const sys_cfg = common.loadRuntimeSystemConfig();
    const disks_dir = sys_cfg.disksDir();
    if (!isSafeNameUnderDir(disk_name, disks_dir)) {
        return null;
    }
    if (std.mem.startsWith(u8, disk_name, "/")) return disk_name;
    const has_ext = std.mem.endsWith(u8, disk_name, ".img") or
        std.mem.endsWith(u8, disk_name, ".raw");
    const ext = if (has_ext) "" else ".img";
    return std.fmt.bufPrint(
        out_buf,
        "{s}/{s}{s}",
        .{ disks_dir, disk_name, ext },
    ) catch null;
}

pub fn formatAndSeedDisk(
    disk_path_z: [*:0]const u8,
    disk_label: []const u8,
) void {
    const sys_cfg = common.loadRuntimeSystemConfig();
    var label_buf: [EXT4_LABEL_MAX + 1]u8 = undefined;
    const label_z = ext4LabelZ(disk_label, &label_buf);

    const allocator = std.heap.page_allocator;
    const cfg_img = allocator.print(
        "{s}/Image",
        .{sys_cfg.imagesDir()},
    ) catch {
        common.printStr("Error: Out of memory staging the disk image.\n");
        return;
    };
    defer allocator.free(cfg_img);

    const mkfs_argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
        sysconfig.MKFS_EXT4_BIN, "-F",        "-q", "-L",
        label_z.ptr,             disk_path_z, null,
    };
    if (common.runSubprocess(mkfs_argv) != 0) return;

    _ = linux.mkdir(sysconfig.RUN_DIOSIX_DIR, 0o755);
    const pid_val: u32 = @bitCast(linux.getpid());
    var mnt_buf: [STAGING_PATH_MAX]u8 = undefined;
    const mnt_dir = std.mem.printSentinel(
        &mnt_buf,
        "{s}.{d}",
        .{ sysconfig.DISK_STAGING_PREFIX, pid_val },
        0,
    ) catch return;
    _ = linux.mkdir(mnt_dir.ptr, 0o700);
    defer _ = linux.rmdir(mnt_dir.ptr);

    const mount_argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
        sysconfig.MOUNT_BIN, "-o", "loop", disk_path_z, mnt_dir.ptr, null,
    };
    if (common.runSubprocess(mount_argv) == 0) {
        var sub_buf: [STAGING_PATH_MAX]u8 = undefined;
        if (joinPathZ(&sub_buf, mnt_dir, "images")) |p| {
            _ = linux.mkdir(p.ptr, 0o755);
        }
        if (joinPathZ(&sub_buf, mnt_dir, "disks")) |p| {
            _ = linux.mkdir(p.ptr, 0o755);
        }
        if (joinPathZ(&sub_buf, mnt_dir, "keys")) |p| {
            _ = linux.mkdir(p.ptr, 0o700);
        }

        var dst1_buf: [STAGING_PATH_MAX]u8 = undefined;
        var dst2_buf: [STAGING_PATH_MAX]u8 = undefined;
        const dst1 = joinPathZ(&dst1_buf, mnt_dir, "images/default.bin");
        const dst2 = joinPathZ(&dst2_buf, mnt_dir, "images/Image");

        const copy_sources = [_][]const u8{
            cfg_img,
            loader.DEFAULT_GUEST_IMAGE_PATH,
        };
        if (dst1 != null and dst2 != null) {
            for (copy_sources) |src| {
                var src_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
                const src_z = common.toPathZ(src, &src_z_buf) orelse {
                    reportPathTooLong();
                    continue;
                };

                const cp_argv: [*:null]const ?[*:0]const u8 =
                    &[_:null]?[*:0]const u8{
                        sysconfig.CP_BIN, "-L", src_z.ptr, dst1.?.ptr, null,
                    };
                if (common.runSubprocess(cp_argv) == 0) {
                    const cp2_argv: [*:null]const ?[*:0]const u8 =
                        &[_:null]?[*:0]const u8{
                            sysconfig.CP_BIN, "-L", src_z.ptr, dst2.?.ptr, null,
                        };
                    _ = common.runSubprocess(cp2_argv);
                    break;
                }
            }
        }

        const umount_argv: [*:null]const ?[*:0]const u8 =
            &[_:null]?[*:0]const u8{ sysconfig.UMOUNT_BIN, mnt_dir.ptr, null };
        _ = common.runSubprocess(umount_argv);
    }
}

/// Extends a virtual disk image to `new_size_bytes` (refusing to shrink) and
/// resizes its ext4 filesystem in place when formatted as ext4.
pub fn resizeVirtualDisk(
    z_path: [*:0]const u8,
    new_size_bytes: u64,
) !void {
    const fd_res = linux.open(z_path, .{ .ACCMODE = .RDWR }, 0);
    const fd_signed: isize = @bitCast(fd_res);
    if (fd_signed < 0) return error.FileNotFound;
    const fd: i32 = @intCast(fd_signed);

    const end_off = linux.lseek(fd, 0, linux.SEEK.END);
    const end_signed: isize = @bitCast(end_off);
    const cur_size: u64 = if (end_signed > 0) @intCast(end_signed) else 0;
    if (new_size_bytes < cur_size) {
        _ = linux.close(fd);
        return error.CannotShrinkDisk;
    }

    const trunc_rc = linux.ftruncate(fd, @intCast(new_size_bytes));
    _ = linux.close(fd);
    if (@as(isize, @bitCast(trunc_rc)) < 0) return error.ResizeFailed;

    if (std.mem.eql(u8, detectDiskFormat(z_path), "ext4")) {
        const resize_argv: [*:null]const ?[*:0]const u8 =
            &[_:null]?[*:0]const u8{
                sysconfig.RESIZE2FS_BIN,
                "-f",
                z_path,
                null,
            };
        _ = common.runSubprocess(resize_argv);
    }
}

pub fn provisionVirtualDisk(
    name: []const u8,
    size_mb: usize,
    out_path_buf: []u8,
) ?[]const u8 {
    const sys_cfg = common.loadRuntimeSystemConfig();
    _ = linux.mkdir(sysconfig.VAR_LIB_DIOSIX_DIR, 0o755);
    {
        var dir_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
        if (common.toPathZ(sys_cfg.disksDir(), &dir_z_buf)) |dz| {
            _ = linux.mkdir(dz.ptr, 0o755);
        }
    }

    const path = resolveDiskPath(name, out_path_buf) orelse return null;
    var z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const z_path = common.toPathZ(path, &z_buf) orelse return null;

    const fd_res = linux.open(
        z_path.ptr,
        .{ .ACCMODE = .RDWR, .CREAT = true },
        common.DEFAULT_FILE_MODE,
    );
    const fd_signed: isize = @bitCast(fd_res);
    if (fd_signed < 0) return null;
    const fd: i32 = @intCast(fd_signed);
    defer _ = linux.close(fd);

    const size_bytes: u64 = @as(u64, size_mb) * MIB_BYTES;
    _ = linux.ftruncate(fd, @intCast(size_bytes));

    formatAndSeedDisk(z_path.ptr, name);
    return path;
}

test "storage/disk: resolveDiskPath validates names and rejects traversal" {
    std.testing.refAllDecls(@This());
    var buf: [common.MAX_PATH_LEN]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/var/lib/diosix/disks/data.img",
        resolveDiskPath("data", &buf).?,
    );
    try std.testing.expect(resolveDiskPath("../etc/shadow", &buf) == null);
}

test "storage/disk: formatSizeMb switches to GB at 1024 MB" {
    var buf: [SIZE_STR_BYTES]u8 = undefined;
    try std.testing.expectEqualStrings("0 MB", formatSizeMb(&buf, 0));
    try std.testing.expectEqualStrings("1023 MB", formatSizeMb(&buf, 1023));
    try std.testing.expectEqualStrings("1 GB", formatSizeMb(&buf, 1024));
    try std.testing.expectEqualStrings("3 GB", formatSizeMb(&buf, 3500));
}

test "storage/disk: isSafeNameUnderDir enforces the store prefix" {
    const dir = "/var/lib/diosix/disks";
    try std.testing.expect(isSafeNameUnderDir("data", dir));
    try std.testing.expect(isSafeNameUnderDir("/var/lib/diosix/disks/a", dir));
    try std.testing.expect(
        !isSafeNameUnderDir("/var/lib/diosix/disks-x/a", dir),
    );
    try std.testing.expect(isSafeNameUnderDir("/tmp/a.img", dir));
    try std.testing.expect(!isSafeNameUnderDir("/etc/passwd", dir));
    try std.testing.expect(!isSafeNameUnderDir("../x", dir));
}
