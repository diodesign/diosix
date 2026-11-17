// Diosix Host Installer Disk Partitioning, Formatting, and Payload Seeding.
//
// Executes GPT partitioning (`sfdisk`), FAT32/ext4 filesystem creation
// (`mkfs.vfat`, `mkfs.ext4`), and persistent directory/image seeding for
// `dsx host install`.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const common = @import("../common.zig");
const installer = @import("../installer.zig");
const sysconfig = @import("../sysconfig.zig");

const MAX_MOUNTS_BYTES: usize = 64 * 1024;
const MIB_BYTES: u64 = 1024 * 1024;
const DEFAULT_DATA_PART_MB: usize = 512;

fn makeDirPath(path: []const u8, mode: usize) void {
    var z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    if (common.toPathZ(path, &z_buf)) |z| {
        _ = linux.mkdir(z.ptr, @intCast(mode));
    }
}

/// Checks whether `disk_path` is currently mounted according to `/proc/mounts`.
pub fn isDiskMounted(disk_path: []const u8) bool {
    const content = common.readBinaryFile(
        sysconfig.PROC_MOUNTS_PATH,
        MAX_MOUNTS_BYTES,
    ) catch return false;
    defer common.unmapBinaryFile(content);

    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        if (std.mem.startsWith(u8, line, disk_path)) {
            const rest = line[disk_path.len..];
            if (rest.len == 0 or rest[0] == ' ' or rest[0] == '\t' or
                std.ascii.isDigit(rest[0]) or rest[0] == 'p')
            {
                return true;
            }
        }
    }
    return false;
}

/// Formats the GPT `sfdisk` script for the 3-partition Diosix host layout.
pub fn allocSfdiskScript(
    allocator: std.mem.Allocator,
    plan: installer.InstallPlan,
) ![]u8 {
    return allocator.print(
        "label: gpt\n" ++
            "size={d}M, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, " ++
            "name=\"DIOSIX_BOOT\"\n" ++
            "size={d}M, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, " ++
            "name=\"DIOSIX_STATE\"\n" ++
            "type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, " ++
            "name=\"DIOSIX_DATA\"\n",
        .{ plan.boot_part_mb, plan.state_part_mb },
    );
}

fn runSubprocessWithStdinFile(
    argv: [*:null]const ?[*:0]const u8,
    stdin_path_z: [*:0]const u8,
) u32 {
    const pid_res = linux.fork();
    const pid_signed: isize = @bitCast(pid_res);
    if (pid_signed < 0) return common.SUBPROCESS_WAIT_ERR;
    if (pid_signed == 0) {
        const in_res = linux.open(stdin_path_z, .{ .ACCMODE = .RDONLY }, 0);
        const in_signed: isize = @bitCast(in_res);
        if (in_signed >= 0) {
            _ = linux.dup2(@intCast(in_signed), linux.STDIN_FILENO);
            _ = linux.close(@intCast(in_signed));
        }
        const devnull_res = linux.open(
            sysconfig.DEV_NULL_PATH,
            .{ .ACCMODE = .RDWR },
            0,
        );
        const devnull_signed: isize = @bitCast(devnull_res);
        if (devnull_signed >= 0) {
            _ = linux.dup2(@intCast(devnull_signed), linux.STDOUT_FILENO);
            _ = linux.dup2(@intCast(devnull_signed), linux.STDERR_FILENO);
            _ = linux.close(@intCast(devnull_signed));
        }
        const envp: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
            "PATH=/usr/sbin:/usr/bin:/sbin:/bin:" ++
                "/usr/local/sbin:/usr/local/bin",
            null,
        };
        _ = linux.execve(argv[0].?, argv, envp);
        linux.exit(common.SUBPROCESS_EXEC_ERR);
    }
    const pid: i32 = @intCast(pid_signed);
    var status: i32 = 0;
    while (true) {
        const wait_res = linux.waitpid(pid, &status, 0);
        const wait_signed: isize = @bitCast(wait_res);
        if (wait_signed >= 0) break;
        if (wait_signed == -@as(isize, @backingInt(linux.E.INTR))) continue;
        return common.SUBPROCESS_WAIT_ERR;
    }
    if ((status & common.WAIT_SIGNAL_MASK) == 0) {
        return @intCast(
            (status >> common.WAIT_EXIT_SHIFT) & common.WAIT_EXIT_MASK,
        );
    }
    return common.WAIT_SIGNAL_EXIT_BASE +
        @as(u32, @intCast(status & common.WAIT_SIGNAL_MASK));
}

fn copyFileIfPresentWithMode(
    src_path: []const u8,
    dst_path: []const u8,
    mode: usize,
) void {
    const data = common.readBinaryFile(
        src_path,
        common.MAX_ELF_FILE_SIZE * 2,
    ) catch return;
    defer common.unmapBinaryFile(data);
    common.writeFileWithMode(dst_path, data, mode) catch {};
}

fn copyFileIfPresent(src_path: []const u8, dst_path: []const u8) void {
    copyFileIfPresentWithMode(src_path, dst_path, common.DEFAULT_FILE_MODE);
}

fn seedKeyFiles(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
) !void {
    const KeySeed = struct {
        name: []const u8,
        mode: usize,
    };
    const key_files = [_]KeySeed{
        .{ .name = "authorized_passkeys", .mode = common.PRIVATE_FILE_MODE },
        .{ .name = "id_management", .mode = common.PRIVATE_FILE_MODE },
        .{ .name = "id_management.pub", .mode = common.DEFAULT_FILE_MODE },
        .{
            .name = "dropbear_ed25519_host_key",
            .mode = common.PRIVATE_FILE_MODE,
        },
    };
    for (key_files) |kf| {
        const src = try allocator.print(
            "{s}/{s}",
            .{ sysconfig.DEFAULT_KEYS_DIR, kf.name },
        );
        defer allocator.free(src);
        const dst = try allocator.print(
            "{s}/keys/{s}",
            .{ root_dir, kf.name },
        );
        defer allocator.free(dst);
        if (!std.mem.eql(u8, src, dst)) {
            copyFileIfPresentWithMode(src, dst, kf.mode);
        }
    }
}

fn seedTargetRoot(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    plan: installer.InstallPlan,
    rec_toml: []const u8,
) !void {
    const subdirs = [_][]const u8{
        "boot",
        "boot/slot_a",
        "boot/slot_b",
        "state",
        "charter",
        "images",
        "disks",
        "iso",
        "keys",
    };
    for (subdirs) |sub| {
        const dir_path = try allocator.print("{s}/{s}", .{ root_dir, sub });
        defer allocator.free(dir_path);
        const mode: usize = if (std.mem.eql(u8, sub, "keys")) 0o700 else 0o755;
        makeDirPath(dir_path, mode);
    }

    const receipt_dst = try allocator.print(
        "{s}/install.receipt",
        .{root_dir},
    );
    defer allocator.free(receipt_dst);
    if (rec_toml.len > 0) {
        common.writeFile(receipt_dst, rec_toml) catch {};
    }

    const hostname_dst = try allocator.print(
        "{s}/state/hostname",
        .{root_dir},
    );
    defer allocator.free(hostname_dst);
    common.writeFile(hostname_dst, plan.hostname) catch {};

    const base_elf_dst = try allocator.print(
        "{s}/images/diosix-node.elf",
        .{root_dir},
    );
    defer allocator.free(base_elf_dst);
    if (!std.mem.eql(u8, base_elf_dst, sysconfig.DEFAULT_GUEST_IMAGE_PATH)) {
        copyFileIfPresent(sysconfig.DEFAULT_GUEST_IMAGE_PATH, base_elf_dst);
    }

    const slot_a_elf = try allocator.print(
        "{s}/boot/slot_a/diosix-node.elf",
        .{root_dir},
    );
    defer allocator.free(slot_a_elf);
    copyFileIfPresent(sysconfig.DEFAULT_GUEST_IMAGE_PATH, slot_a_elf);
    try seedKeyFiles(allocator, root_dir);
}

/// Applies `plan` to `plan.target_disk`, partitioning and formatting unmounted
/// block devices or image files and seeding the A/B boot slots, state
/// directory, and base guest image.
pub fn applyInstallPlan(
    allocator: std.mem.Allocator,
    plan: installer.InstallPlan,
    rec_toml: []const u8,
) !void {
    if (builtin.is_test) return;

    makeDirPath(sysconfig.VAR_LIB_DIOSIX_DIR, 0o755);
    if (rec_toml.len > 0) {
        try common.writeFile(installer.INSTALL_RECEIPT_PATH, rec_toml);
    }

    var target_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const target_z = common.toPathZ(plan.target_disk, &target_z_buf) orelse
        return error.PathTooLong;

    // If targeting a regular file path under /tmp/ or /var/lib/diosix/ that
    // does not yet exist, allocate the backing disk file first.
    if (!std.mem.startsWith(u8, plan.target_disk, sysconfig.DEV_DIR_PREFIX) and
        !common.fileExistsPath(target_z.ptr))
    {
        const fd_res = linux.open(
            target_z.ptr,
            .{ .ACCMODE = .RDWR, .CREAT = true },
            common.DEFAULT_FILE_MODE,
        );
        const fd_signed: isize = @bitCast(fd_res);
        if (fd_signed >= 0) {
            const fd: i32 = @intCast(fd_signed);
            defer _ = linux.close(fd);
            const total_mb = plan.boot_part_mb +
                plan.state_part_mb +
                DEFAULT_DATA_PART_MB;
            const total_bytes: u64 = @as(u64, total_mb) * MIB_BYTES;
            _ = linux.ftruncate(fd, @intCast(total_bytes));
        }
    }

    // Partition and format if the target exists and is not currently mounted.
    if (common.fileExistsPath(target_z.ptr) and
        !isDiskMounted(plan.target_disk))
    {
        const sfdisk_bin = sysconfig.resolveBin(
            sysconfig.SFDISK_BIN,
            sysconfig.SFDISK_LOCAL_BIN,
        );
        if (common.fileExistsPath(sfdisk_bin.ptr)) {
            makeDirPath(sysconfig.RUN_DIOSIX_DIR, 0o755);
            const pid_val: u32 = @bitCast(linux.getpid());
            const script_path_z = try allocator.printSentinel(
                "{s}/sfdisk.{d}.in",
                .{ sysconfig.RUN_DIOSIX_DIR, pid_val },
                0,
            );
            defer allocator.free(script_path_z);
            const script = try allocSfdiskScript(allocator, plan);
            defer allocator.free(script);
            if (common.writeFile(script_path_z, script)) |_| {
                defer _ = linux.unlink(script_path_z.ptr);
                const sfdisk_argv: [*:null]const ?[*:0]const u8 =
                    &[_:null]?[*:0]const u8{
                        sfdisk_bin.ptr,
                        "--quiet",
                        "--force",
                        target_z.ptr,
                        null,
                    };
                _ = runSubprocessWithStdinFile(sfdisk_argv, script_path_z.ptr);
            } else |_| {}
        }

        const p_sep: []const u8 =
            if (std.mem.indexOf(u8, plan.target_disk, "nvme") != null or
            std.mem.indexOf(u8, plan.target_disk, "mmcblk") != null)
                "p"
            else
                "";
        const part1_z = try allocator.printSentinel(
            "{s}{s}1",
            .{ plan.target_disk, p_sep },
            0,
        );
        defer allocator.free(part1_z);
        const part2_z = try allocator.printSentinel(
            "{s}{s}2",
            .{ plan.target_disk, p_sep },
            0,
        );
        defer allocator.free(part2_z);
        const part3_z = try allocator.printSentinel(
            "{s}{s}3",
            .{ plan.target_disk, p_sep },
            0,
        );
        defer allocator.free(part3_z);

        const mkfs_vfat_bin = sysconfig.resolveBin(
            sysconfig.MKFS_VFAT_BIN,
            sysconfig.MKFS_VFAT_LOCAL_BIN,
        );
        if (common.fileExistsPath(mkfs_vfat_bin.ptr) and
            common.fileExistsPath(part1_z.ptr))
        {
            const vfat_argv: [*:null]const ?[*:0]const u8 =
                &[_:null]?[*:0]const u8{
                    mkfs_vfat_bin.ptr,
                    "-n",
                    "DIOSIX_BOOT",
                    part1_z.ptr,
                    null,
                };
            _ = common.runSubprocess(vfat_argv);
        }
        const mkfs_ext4_bin = sysconfig.resolveBin(
            sysconfig.MKFS_EXT4_BIN,
            sysconfig.MKFS_EXT4_LOCAL_BIN,
        );
        if (common.fileExistsPath(mkfs_ext4_bin.ptr) and
            common.fileExistsPath(part2_z.ptr))
        {
            const state_argv: [*:null]const ?[*:0]const u8 =
                &[_:null]?[*:0]const u8{
                    mkfs_ext4_bin.ptr,
                    "-F",
                    "-q",
                    "-L",
                    "DIOSIX_STATE",
                    part2_z.ptr,
                    null,
                };
            _ = common.runSubprocess(state_argv);
        }
        if (common.fileExistsPath(mkfs_ext4_bin.ptr)) {
            const data_dev = if (common.fileExistsPath(part3_z.ptr))
                part3_z.ptr
            else
                target_z.ptr;
            const data_argv: [*:null]const ?[*:0]const u8 =
                &[_:null]?[*:0]const u8{
                    mkfs_ext4_bin.ptr,
                    "-F",
                    "-q",
                    "-L",
                    "DIOSIX_DATA",
                    data_dev,
                    null,
                };
            _ = common.runSubprocess(data_argv);

            makeDirPath(sysconfig.RUN_DIOSIX_DIR, 0o755);
            const pid_val: u32 = @bitCast(linux.getpid());
            const mnt_z = try allocator.printSentinel(
                "{s}.inst.{d}",
                .{ sysconfig.DISK_STAGING_PREFIX, pid_val },
                0,
            );
            defer allocator.free(mnt_z);
            _ = linux.mkdir(mnt_z.ptr, 0o700);
            defer _ = linux.rmdir(mnt_z.ptr);

            const mount_argv: [*:null]const ?[*:0]const u8 =
                &[_:null]?[*:0]const u8{
                    sysconfig.MOUNT_BIN,
                    data_dev,
                    mnt_z.ptr,
                    null,
                };
            if (common.runSubprocess(mount_argv) == 0) {
                defer {
                    const umount_argv: [*:null]const ?[*:0]const u8 =
                        &[_:null]?[*:0]const u8{
                            sysconfig.UMOUNT_BIN,
                            mnt_z.ptr,
                            null,
                        };
                    _ = common.runSubprocess(umount_argv);
                }
                try seedTargetRoot(allocator, mnt_z, plan, rec_toml);
                return;
            }
        }
    }

    // Seed the active /var/lib/diosix hierarchy directly when the target disk
    // is already mounted as the system data partition.
    try seedTargetRoot(
        allocator,
        sysconfig.VAR_LIB_DIOSIX_DIR,
        plan,
        rec_toml,
    );
}

test "installer/apply: allocSfdiskScript formats 3-partition GPT layout" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    const plan = installer.InstallPlan{
        .boot_part_mb = 256,
        .state_part_mb = 512,
    };
    const script = try allocSfdiskScript(testing.allocator, plan);
    defer testing.allocator.free(script);
    try testing.expect(std.mem.indexOf(u8, script, "label: gpt") != null);
    try testing.expect(std.mem.indexOf(u8, script, "size=256M") != null);
    try testing.expect(std.mem.indexOf(u8, script, "size=512M") != null);
    try testing.expect(std.mem.indexOf(u8, script, "DIOSIX_DATA") != null);
}
