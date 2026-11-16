// Guest Rootfs & NoCloud `cloud-init` Provisioning Seeder (`dsx disk seed`).
//
// Seeds a mounted or loop-mountable guest virtual disk with SSH authorized
// keys, `/etc/hostname`, `/etc/network/interfaces`, and NoCloud `cloud-init`
// (`var/lib/cloud/seed/nocloud/{meta-data,user-data,network-config}`) so
// arbitrary Linux/BSD cloud and rootfs images boot ready for `dsx ssh`.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const common = @import("../common.zig");
const sysconfig = @import("../sysconfig.zig");
const disk = @import("disk.zig");

const MAX_PUBKEY_BYTES: usize = 4096;
const STAGING_PATH_MAX: usize = 256;

pub const SeedOptions = struct {
    hostname: []const u8 = "diosix-guest",
    ip: []const u8 = "192.168.10.2",
    gateway: []const u8 = "192.168.10.1",
    pubkey_line: []const u8 = "",
};

fn mkdirRel(mnt_dir: []const u8, rel: []const u8, mode: u32) void {
    var buf: [STAGING_PATH_MAX]u8 = undefined;
    if (disk.joinPathZ(&buf, mnt_dir, rel)) |p| {
        _ = linux.mkdir(p.ptr, mode);
    }
}

fn writeFileRel(
    mnt_dir: []const u8,
    rel: []const u8,
    content: []const u8,
    mode: usize,
) void {
    var buf: [STAGING_PATH_MAX]u8 = undefined;
    const p = disk.joinPathZ(&buf, mnt_dir, rel) orelse return;
    common.writeFileWithMode(p, content, mode) catch {};
}

pub fn formatCloudInitMetaData(
    allocator: std.mem.Allocator,
    opts: SeedOptions,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "instance-id: diosix-{s}\nlocal-hostname: {s}\n",
        .{ opts.hostname, opts.hostname },
    );
}

pub fn formatCloudInitUserData(
    allocator: std.mem.Allocator,
    opts: SeedOptions,
) ![]u8 {
    if (opts.pubkey_line.len > 0) {
        return std.fmt.allocPrint(
            allocator,
            \\#cloud-config
            \\hostname: {s}
            \\disable_root: false
            \\ssh_pwauth: false
            \\users:
            \\  - name: root
            \\    ssh_authorized_keys:
            \\      - {s}
            \\
        ,
            .{ opts.hostname, opts.pubkey_line },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "#cloud-config\nhostname: {s}\ndisable_root: false\n",
        .{opts.hostname},
    );
}

pub fn formatCloudInitNetworkConfig(
    allocator: std.mem.Allocator,
    opts: SeedOptions,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        \\version: 2
        \\ethernets:
        \\  eth0:
        \\    match:
        \\      name: "eth*"
        \\    addresses:
        \\      - {s}/24
        \\    gateway4: {s}
        \\
    ,
        .{ opts.ip, opts.gateway },
    );
}

pub fn formatInterfacesFile(
    allocator: std.mem.Allocator,
    opts: SeedOptions,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        \\auto lo
        \\iface lo inet loopback
        \\
        \\auto eth0
        \\iface eth0 inet static
        \\    address {s}
        \\    netmask 255.255.255.0
        \\    gateway {s}
        \\
    ,
        .{ opts.ip, opts.gateway },
    );
}

pub fn resolveManagementPubkey(
    allocator: std.mem.Allocator,
    custom_path: ?[]const u8,
) ?[]u8 {
    if (custom_path) |cp| {
        if (common.readBinaryFile(cp, MAX_PUBKEY_BYTES)) |raw| {
            defer common.unmapBinaryFile(raw);
            const trimmed = common.trimWhitespace(raw);
            if (trimmed.len > 0) return allocator.dupe(u8, trimmed) catch null;
        } else |_| {}
        return null;
    }

    const sys_cfg = common.loadRuntimeSystemConfig();
    const cfg_pk = allocator.print(
        "{s}/id_management.pub",
        .{sys_cfg.keysDir()},
    ) catch return null;
    defer allocator.free(cfg_pk);

    const candidates = [_][]const u8{
        cfg_pk,
        sysconfig.ETC_MANAGEMENT_PUBKEY_PATH,
    };
    for (candidates) |cand| {
        if (common.readBinaryFile(cand, MAX_PUBKEY_BYTES)) |raw| {
            defer common.unmapBinaryFile(raw);
            const trimmed = common.trimWhitespace(raw);
            if (trimmed.len > 0) return allocator.dupe(u8, trimmed) catch null;
        } else |_| {}
    }
    return null;
}

/// Seeds a mounted guest rootfs directory (`mnt_dir`) with SSH authorized
/// keys, `/etc/hostname`, `/etc/network/interfaces`, and NoCloud `cloud-init`
/// configuration files.
pub fn seedMountedRootfs(
    allocator: std.mem.Allocator,
    mnt_dir: []const u8,
    opts: SeedOptions,
) void {
    mkdirRel(mnt_dir, "etc", 0o755);
    mkdirRel(mnt_dir, "etc/network", 0o755);
    mkdirRel(mnt_dir, "root", 0o700);
    mkdirRel(mnt_dir, "root/.ssh", 0o700);
    mkdirRel(mnt_dir, "var", 0o755);
    mkdirRel(mnt_dir, "var/lib", 0o755);
    mkdirRel(mnt_dir, "var/lib/cloud", 0o755);
    mkdirRel(mnt_dir, "var/lib/cloud/seed", 0o755);
    mkdirRel(mnt_dir, "var/lib/cloud/seed/nocloud", 0o755);

    if (allocator.print("{s}\n", .{opts.hostname})) |hn| {
        defer allocator.free(hn);
        writeFileRel(mnt_dir, "etc/hostname", hn, 0o644);
    } else |_| {}

    if (formatInterfacesFile(allocator, opts)) |ifaces| {
        defer allocator.free(ifaces);
        writeFileRel(mnt_dir, "etc/network/interfaces", ifaces, 0o644);
    } else |_| {}

    if (opts.pubkey_line.len > 0) {
        if (allocator.print("{s}\n", .{opts.pubkey_line})) |ak| {
            defer allocator.free(ak);
            writeFileRel(mnt_dir, "root/.ssh/authorized_keys", ak, 0o600);
        } else |_| {}
    }

    if (formatCloudInitMetaData(allocator, opts)) |md| {
        defer allocator.free(md);
        writeFileRel(
            mnt_dir,
            "var/lib/cloud/seed/nocloud/meta-data",
            md,
            0o644,
        );
    } else |_| {}

    if (formatCloudInitUserData(allocator, opts)) |ud| {
        defer allocator.free(ud);
        writeFileRel(
            mnt_dir,
            "var/lib/cloud/seed/nocloud/user-data",
            ud,
            0o600,
        );
    } else |_| {}

    if (formatCloudInitNetworkConfig(allocator, opts)) |nc| {
        defer allocator.free(nc);
        writeFileRel(
            mnt_dir,
            "var/lib/cloud/seed/nocloud/network-config",
            nc,
            0o644,
        );
    } else |_| {}
}

/// Mounts `disk_path_z` via loop device, seeds rootfs & NoCloud `cloud-init`
/// metadata, and unmounts cleanly.
pub fn seedDiskImage(
    allocator: std.mem.Allocator,
    disk_path_z: [*:0]const u8,
    opts: SeedOptions,
) bool {
    _ = linux.mkdir(sysconfig.RUN_DIOSIX_DIR, 0o755);
    const pid_val: u32 = @bitCast(linux.getpid());
    var mnt_buf: [STAGING_PATH_MAX]u8 = undefined;
    const mnt_dir = std.mem.printSentinel(
        &mnt_buf,
        "{s}.seed.{d}",
        .{ sysconfig.DISK_STAGING_PREFIX, pid_val },
        0,
    ) catch return false;
    _ = linux.mkdir(mnt_dir.ptr, 0o700);
    defer _ = linux.rmdir(mnt_dir.ptr);

    const mount_argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
        sysconfig.MOUNT_BIN, "-o", "loop", disk_path_z, mnt_dir.ptr, null,
    };
    if (common.runSubprocess(mount_argv) != 0) return false;
    defer {
        const umount_argv: [*:null]const ?[*:0]const u8 =
            &[_:null]?[*:0]const u8{ sysconfig.UMOUNT_BIN, mnt_dir.ptr, null };
        _ = common.runSubprocess(umount_argv);
    }

    seedMountedRootfs(allocator, mnt_dir, opts);
    return true;
}

pub fn cmdDiskSeed(exe_name: []const u8, args: []const [*:0]const u8) void {
    if (args.len < 2) {
        common.printFmt(
            "Usage: {s} disk seed <name> [--hostname <name>] " ++
                "[--ip <ip>] [--pubkey <file>]\n",
            .{exe_name},
        );
        return;
    }
    const disk_name = std.mem.span(args[1]);
    var hostname: []const u8 = disk_name;
    var ip_str: []const u8 = "192.168.10.2";
    var pubkey_file: ?[]const u8 = null;

    const SeedFlag = enum {
        @"--hostname",
        @"-h",
        @"--ip",
        @"--pubkey",
        @"-k",
    };

    var idx: usize = 2;
    while (idx < args.len) : (idx += 1) {
        const span = std.mem.span(args[idx]);
        if (std.meta.stringToEnum(SeedFlag, span)) |fl| {
            if (idx + 1 >= args.len) {
                common.printFmt(
                    "Error: Option '{s}' requires a value.\n",
                    .{span},
                );
                return;
            }
            idx += 1;
            const val = std.mem.span(args[idx]);
            switch (fl) {
                .@"--hostname", .@"-h" => hostname = val,
                .@"--ip" => ip_str = val,
                .@"--pubkey", .@"-k" => pubkey_file = val,
            }
        } else if (std.mem.startsWith(u8, span, "-")) {
            common.printFmt("Error: Unknown option '{s}'.\n", .{span});
            return;
        }
    }

    var path_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const path = disk.resolveDiskPath(disk_name, &path_buf) orelse {
        common.printStr("Error: Invalid disk name or path.\n");
        return;
    };
    var z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const z_path = common.toPathZ(path, &z_buf) orelse {
        disk.reportPathTooLong();
        return;
    };

    const allocator = std.heap.page_allocator;
    const pk_owned = resolveManagementPubkey(allocator, pubkey_file);
    defer if (pk_owned) |pk| allocator.free(pk);

    const opts = SeedOptions{
        .hostname = hostname,
        .ip = ip_str,
        .pubkey_line = pk_owned orelse "",
    };
    if (seedDiskImage(allocator, z_path.ptr, opts)) {
        common.printFmt(
            "✓ Virtual disk '{s}' seeded (hostname: {s}, IP: {s}, " ++
                "NoCloud + SSH key provisioned).\n",
            .{ disk_name, hostname, ip_str },
        );
    } else {
        common.printFmt(
            "Error: Failed to mount or seed virtual disk '{s}'.\n",
            .{disk_name},
        );
    }
}

test "storage/seed: formats NoCloud cloud-init and network config" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    const alloc = testing.allocator;

    const opts = SeedOptions{
        .hostname = "ubuntu-vm",
        .ip = "192.168.10.5",
        .pubkey_line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest root@diosix",
    };

    const md = try formatCloudInitMetaData(alloc, opts);
    defer alloc.free(md);
    try testing.expect(
        std.mem.indexOf(u8, md, "local-hostname: ubuntu-vm") != null,
    );

    const ud = try formatCloudInitUserData(alloc, opts);
    defer alloc.free(ud);
    try testing.expect(std.mem.indexOf(u8, ud, "#cloud-config") != null);
    try testing.expect(
        std.mem.indexOf(u8, ud, "ssh_authorized_keys:") != null,
    );

    const nc = try formatCloudInitNetworkConfig(alloc, opts);
    defer alloc.free(nc);
    try testing.expect(std.mem.indexOf(u8, nc, "192.168.10.5/24") != null);
}
