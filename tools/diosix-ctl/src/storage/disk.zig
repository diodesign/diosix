// Virtual Disk Format Detection, Path Resolution & Provisioning.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const common = @import("../common.zig");
const loader = @import("../loader.zig");

pub const EXT4_SUPERBLOCK_OFFSET: usize = 1024;
pub const EXT4_MAGIC_OFFSET: usize = EXT4_SUPERBLOCK_OFFSET + 56;
pub const EXT4_SUPER_MAGIC: u16 = 0xef53;
pub const MIB_BYTES: usize = 1024 * 1024;

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
        var magic_buf: [2]u8 = undefined;
        const nread_res = linux.read(fd, &magic_buf, 2);
        const nread: isize = @bitCast(nread_res);
        if (nread == 2 and
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
    var prefix_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const allowed_prefix = std.fmt.bufPrint(
        &prefix_buf,
        "{s}/",
        .{disks_dir},
    ) catch "/var/lib/diosix/disks/";
    if (!common.isSafeStoragePath(disk_name, allowed_prefix)) {
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
    var label_buf: [64]u8 = undefined;
    const label_slice = std.fmt.bufPrint(
        &label_buf,
        "{s}",
        .{disk_label},
    ) catch "diosix-data";
    var label_z_buf: [64]u8 = undefined;
    const label_z = common.toPathZ(label_slice, &label_z_buf) orelse return;

    const mkfs_argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
        "/usr/sbin/mkfs.ext4", "-F",        "-q", "-L",
        label_z.ptr,           disk_path_z, null,
    };
    if (common.runSubprocess(mkfs_argv) != 0) return;

    const mnt_dir: [:0]const u8 = "/tmp/diosix_staging";
    _ = linux.mkdir(mnt_dir.ptr, 0o755);

    const mount_argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
        "/bin/mount", "-o", "loop", disk_path_z, mnt_dir.ptr, null,
    };
    if (common.runSubprocess(mount_argv) == 0) {
        _ = linux.mkdir("/tmp/diosix_staging/images", 0o755);
        _ = linux.mkdir("/tmp/diosix_staging/disks", 0o755);
        _ = linux.mkdir("/tmp/diosix_staging/keys", 0o700);

        var img_src_buf: [common.MAX_PATH_LEN]u8 = undefined;
        const cfg_img = std.fmt.bufPrint(
            &img_src_buf,
            "{s}/linux-guest.elf",
            .{sys_cfg.imagesDir()},
        ) catch "/var/lib/diosix/images/linux-guest.elf";

        const copy_sources = [_][]const u8{
            cfg_img,
            loader.DEFAULT_GUEST_IMAGE_PATH,
        };
        for (copy_sources) |src| {
            var src_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
            const src_z = common.toPathZ(src, &src_z_buf) orelse continue;

            const dst1 = "/tmp/diosix_staging/images/default.elf";
            const dst2 = "/tmp/diosix_staging/images/linux-guest.elf";
            const cp_argv: [*:null]const ?[*:0]const u8 =
                &[_:null]?[*:0]const u8{
                    "/bin/cp", "-L", src_z.ptr, dst1, null,
                };
            if (common.runSubprocess(cp_argv) == 0) {
                const cp2_argv: [*:null]const ?[*:0]const u8 =
                    &[_:null]?[*:0]const u8{
                        "/bin/cp", "-L", src_z.ptr, dst2, null,
                    };
                _ = common.runSubprocess(cp2_argv);
                break;
            }
        }

        const umount_argv: [*:null]const ?[*:0]const u8 =
            &[_:null]?[*:0]const u8{ "/bin/umount", mnt_dir.ptr, null };
        _ = common.runSubprocess(umount_argv);
    }
}

pub fn provisionVirtualDisk(
    name: []const u8,
    size_mb: usize,
    out_path_buf: []u8,
) ?[]const u8 {
    const sys_cfg = common.loadRuntimeSystemConfig();
    _ = linux.mkdir("/var/lib/diosix", 0o755);
    var dir_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    if (common.toPathZ(sys_cfg.disksDir(), &dir_z_buf)) |dz| {
        _ = linux.mkdir(dz.ptr, 0o755);
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
