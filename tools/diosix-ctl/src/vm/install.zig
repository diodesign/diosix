// Diosix Hypervisor Guest Management CLI — Guest OS Installation & Restart.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("../api.zig");
const catalog = @import("../catalog.zig");
const common = @import("../common.zig");
const loader = @import("../loader.zig");
const storage = @import("../storage.zig");
const vm = @import("../vm.zig");
const vm_run = @import("run.zig");

const MAX_PATH_LEN = common.MAX_PATH_LEN;
const MAX_MANIFEST_SIZE = common.MAX_MANIFEST_SIZE;
const CATALOG_CONFIG_PATH = common.CATALOG_CONFIG_PATH;

const printStr = common.printStr;
const parseCid = common.parseCid;
const copyStr = common.copyStr;
const parseMemorySizeMb = common.parseMemorySizeMb;
const readBinaryFile = common.readBinaryFile;
const unmapBinaryFile = common.unmapBinaryFile;
const matchTarget = common.matchTarget;

const InstallGuestOption = enum {
    @"--name",
    @"-n",
    @"--disk",
    @"-d",
    @"--size",
    @"-s",
    @"--vcpus",
    @"--ram",
    @"--offline-stub",
};

pub fn cmdInstallGuest(
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
) !void {
    const exe_name = common.getExeName();
    if (args.len == 0) {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            \\Usage: {s} install-guest <os-name|iso> [--name <vm>]
            \\       [--disk <disk>] [--size <size>] [--vcpus <N>]
            \\       [--ram <size>] [--offline-stub]
            \\Examples:
            \\  {s} install-guest debian-riscv64 --disk debian-root --size 4GiB
            \\  {s} install-guest freebsd-riscv64 --name bsd-db --disk bsd-data
            \\
        , .{ exe_name, exe_name, exe_name }) catch return;
        printStr(msg);
        return;
    }

    var cat_mapped: ?[]const u8 = null;
    defer if (cat_mapped) |m| unmapBinaryFile(m);
    var parsed_entries: [catalog.MAX_CATALOG_ENTRIES]catalog.CatalogEntry =
        undefined;
    var active_catalog: []const catalog.CatalogEntry =
        &catalog.OFFICIAL_CATALOG;
    if (readBinaryFile(CATALOG_CONFIG_PATH, MAX_MANIFEST_SIZE)) |content| {
        cat_mapped = content;
        const count = catalog.parseCatalogToml(content, &parsed_entries);
        if (count > 0) {
            active_catalog = parsed_entries[0..count];
        }
    } else |_| {}

    var target_os: ?[]const u8 = null;
    var vm_name: ?[]const u8 = null;
    var disk_name: ?[]const u8 = null;
    var size_str: ?[]const u8 = null;
    var vcpus_opt: ?usize = null;
    var ram_opt: ?[]const u8 = null;
    var offline_stub = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const span = std.mem.span(args[i]);
        if (std.meta.stringToEnum(InstallGuestOption, span)) |opt| {
            switch (opt) {
                .@"--name", .@"-n" => {
                    if (i + 1 >= args.len) {
                        printStr(
                            "Error: Option '--name' requires a VM name.\n",
                        );
                        return;
                    }
                    i += 1;
                    vm_name = std.mem.span(args[i]);
                },
                .@"--disk", .@"-d" => {
                    if (i + 1 >= args.len) {
                        printStr(
                            "Error: Option '--disk' requires a disk name.\n",
                        );
                        return;
                    }
                    i += 1;
                    disk_name = std.mem.span(args[i]);
                },
                .@"--size", .@"-s" => {
                    if (i + 1 >= args.len) {
                        printStr(
                            "Error: Option '--size' requires a capacity.\n",
                        );
                        return;
                    }
                    i += 1;
                    size_str = std.mem.span(args[i]);
                },
                .@"--vcpus" => {
                    if (i + 1 >= args.len) {
                        printStr(
                            "Error: Option '--vcpus' requires a count.\n",
                        );
                        return;
                    }
                    i += 1;
                    vcpus_opt = std.fmt.parseInt(
                        usize,
                        std.mem.span(args[i]),
                        10,
                    ) catch {
                        printStr(
                            "Error: Invalid numeric value for '--vcpus'.\n",
                        );
                        return;
                    };
                },
                .@"--ram" => {
                    if (i + 1 >= args.len) {
                        printStr(
                            "Error: Option '--ram' requires a size.\n",
                        );
                        return;
                    }
                    i += 1;
                    ram_opt = std.mem.span(args[i]);
                },
                .@"--offline-stub" => offline_stub = true,
            }
        } else if (std.mem.startsWith(u8, span, "-")) {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(
                &err_buf,
                "Error: Unknown option '{s}'. Use '{s} install-guest' " ++
                    "for usage.\n",
                .{ span, exe_name },
            ) catch "Error: Unknown option.\n";
            printStr(err_msg);
            return;
        } else if (target_os == null) {
            target_os = span;
        }
    }

    if (target_os == null) {
        printStr("Error: No OS catalog name or ISO specified.\n");
        return;
    }

    const os_query = target_os.?;
    const matched = catalog.findEntryInSlice(active_catalog, os_query);

    const final_vm_name: []const u8 = if (vm_name) |n|
        n
    else if (matched) |e|
        e.alias
    else blk: {
        const base = if (std.mem.lastIndexOfScalar(u8, os_query, '/')) |s|
            os_query[s + 1 ..]
        else
            os_query;
        break :blk if (std.mem.endsWith(u8, base, ".iso") and base.len > 4)
            base[0 .. base.len - 4]
        else
            base;
    };
    const final_disk_name: []const u8 =
        if (disk_name) |d| d else final_vm_name;
    const disk_mb: usize = if (size_str) |s|
        parseMemorySizeMb(s)
    else if (matched) |e|
        e.default_disk_mb
    else
        4096;
    const final_vcpus: usize = if (vcpus_opt) |v|
        v
    else if (matched) |e|
        e.default_vcpus
    else
        2;
    var ram_mb_buf: [32]u8 = undefined;
    const final_ram_str: []const u8 = if (ram_opt) |r|
        r
    else if (matched) |e|
        (std.fmt.bufPrint(&ram_mb_buf, "{d}M", .{e.default_ram_mb}) catch
            "1024M")
    else
        "1024M";

    var iso_path_buf: [MAX_PATH_LEN]u8 = undefined;
    const iso_filename: []const u8 = if (matched) |e|
        e.filename
    else if (std.mem.endsWith(u8, os_query, ".iso"))
        os_query
    else
        (std.fmt.bufPrint(&iso_path_buf, "{s}.iso", .{os_query}) catch
            os_query);
    var full_iso_buf: [MAX_PATH_LEN]u8 = undefined;
    const full_iso_path = if (std.mem.startsWith(u8, iso_filename, "/"))
        iso_filename
    else
        std.fmt.bufPrint(
            &full_iso_buf,
            "/var/lib/diosix/iso/{s}",
            .{iso_filename},
        ) catch "/var/lib/diosix/iso/installer.iso";

    _ = linux.mkdir("/var/lib/diosix", 0o755);
    _ = linux.mkdir("/var/lib/diosix/iso", 0o755);
    if (readBinaryFile(full_iso_path, 4096)) |existing| {
        unmapBinaryFile(existing);
    } else |_| {
        if (matched) |entry| {
            const verify_sha: ?[]const u8 =
                if (catalog.hasPinnedSha256(entry)) entry.sha256 else null;
            _ = storage.pullRemoteOrStageImage(
                entry.url,
                full_iso_path,
                verify_sha,
                false,
                false,
            ) catch |err| {
                if (err == error.Interrupted) {
                    printStr(
                        "\nAborted guest installation (interrupted).\n",
                    );
                    return;
                }
                if (err == error.ChecksumMismatch) {
                    printStr(
                        "Error: SHA-256 verification failed for ISO!\n",
                    );
                    return;
                }
                if (offline_stub) {
                    var fb_buf: [256]u8 = undefined;
                    const fb_msg = std.fmt.bufPrint(
                        &fb_buf,
                        "==> Staging offline test stub ISO for '{s}' " ++
                            "(--offline-stub)...\n",
                        .{entry.id},
                    ) catch "==> Staging offline test stub ISO...\n";
                    printStr(fb_msg);
                    if (!loader.seedOfflineCatalogFallback(
                        entry,
                        full_iso_path,
                    )) {
                        printStr(
                            "Error: Failed to stage offline test stub ISO.\n",
                        );
                        return;
                    }
                } else {
                    var dl_buf: [384]u8 = undefined;
                    const dl_msg = std.fmt.bufPrint(
                        &dl_buf,
                        "Error: Failed to download installer ISO from " ++
                            "'{s}'. Pull or import the ISO first, or pass " ++
                            "'--offline-stub' for offline testing.\n",
                        .{entry.url},
                    ) catch "Error: Failed to download installer ISO.\n";
                    printStr(dl_msg);
                    return;
                }
            };
        } else {
            var nf_buf: [256]u8 = undefined;
            const nf_msg = std.fmt.bufPrint(
                &nf_buf,
                "Error: Installer ISO '{s}' not found locally and '{s}' " ++
                    "is not a known catalog ID.\n",
                .{ full_iso_path, os_query },
            ) catch "Error: Installer ISO not found.\n";
            printStr(nf_msg);
            return;
        }
    }

    var disk_path_buf: [MAX_PATH_LEN]u8 = undefined;
    const disk_path = storage.provisionVirtualDisk(
        final_disk_name,
        disk_mb,
        &disk_path_buf,
    ) orelse {
        printStr(
            "Error: Failed to provision target virtual disk for install.\n",
        );
        return;
    };

    var vcpu_str_buf: [16]u8 = undefined;
    const vcpu_str = std.fmt.bufPrint(
        &vcpu_str_buf,
        "{d}",
        .{final_vcpus},
    ) catch "2";

    var z_name_buf: [128]u8 = undefined;
    var z_vcpus_buf: [16]u8 = undefined;
    var z_ram_buf: [32]u8 = undefined;
    var z_disk_buf: [MAX_PATH_LEN]u8 = undefined;
    var z_cdrom_buf: [MAX_PATH_LEN]u8 = undefined;

    const z_vm_name = common.toPathZ(final_vm_name, &z_name_buf) orelse return;
    const z_vcpus = common.toPathZ(vcpu_str, &z_vcpus_buf) orelse return;
    const z_ram = common.toPathZ(final_ram_str, &z_ram_buf) orelse return;
    const z_disk = common.toPathZ(disk_path, &z_disk_buf) orelse return;
    const z_cdrom = common.toPathZ(full_iso_path, &z_cdrom_buf) orelse return;

    const run_args = [_][*:0]const u8{
        "guest-shim",
        "--name",
        z_vm_name.ptr,
        "--vcpus",
        z_vcpus.ptr,
        "--ram",
        z_ram.ptr,
        "--disk",
        z_disk.ptr,
        "--cdrom",
        z_cdrom.ptr,
    };
    try vm_run.cmdRun(client, &run_args);
}

pub fn cmdRestart(
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
) !void {
    const exe_name = common.getExeName();
    if (args.len == 0) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "Usage: {s} restart <name|cid>\n",
            .{exe_name},
        ) catch return;
        printStr(msg);
        return;
    }
    const target_str = std.mem.span(args[0]);
    if (std.mem.eql(u8, target_str, "parent") or
        std.mem.eql(u8, target_str, "0"))
    {
        printStr("Error: Cannot restart parent VM (CID 0).\n");
        return;
    }

    const target_cid = parseCid(target_str) catch 0;
    var name_buf: [64]u8 = undefined;
    var ram_buf: [32]u8 = undefined;
    var disk_buf: [MAX_PATH_LEN]u8 = undefined;
    var cdrom_buf: [MAX_PATH_LEN]u8 = undefined;
    var ip_buf: [64]u8 = undefined;
    var saved_name: []const u8 = target_str;
    var saved_vcpus: usize = 1;
    var saved_ram: []const u8 = "256 MB";
    var saved_disk: []const u8 = "";
    var saved_cdrom: []const u8 = "";
    var saved_ip: []const u8 = "";
    var saved_trusted = false;

    if (readBinaryFile(
        "/var/run/diosix/guests.toml",
        MAX_MANIFEST_SIZE,
    )) |content| {
        defer unmapBinaryFile(content);
        var iter = common.GuestRegistryIter.init(content);
        while (iter.next()) |entry| {
            if (matchTarget(target_str, target_cid, entry.cid, entry.name)) {
                saved_name = copyStr(&name_buf, entry.name);
                saved_vcpus = entry.vcpus;
                saved_ram = copyStr(&ram_buf, entry.ram);
                saved_disk = copyStr(&disk_buf, entry.disk);
                saved_cdrom = copyStr(&cdrom_buf, entry.cdrom);
                saved_ip = copyStr(&ip_buf, entry.ip);
                saved_trusted = std.mem.eql(u8, entry.trust, "trusted");
                break;
            }
        }
    } else |_| {}

    const stopped = try vm.cmdStop(client, args);
    if (!stopped) return;
    printStr("Restarting guest VM...\n");

    const img_str: [*:0]const u8 =
        if (saved_disk.len > 0 or saved_cdrom.len > 0)
            "guest-shim"
        else
            "default";

    var vcpu_str_buf: [16]u8 = undefined;
    const vcpu_str = std.fmt.bufPrint(
        &vcpu_str_buf,
        "{d}",
        .{saved_vcpus},
    ) catch "1";

    var z_name_buf: [64]u8 = undefined;
    var z_vcpus_buf: [16]u8 = undefined;
    var z_ram_buf: [32]u8 = undefined;
    var z_disk_buf: [MAX_PATH_LEN]u8 = undefined;
    var z_cdrom_buf: [MAX_PATH_LEN]u8 = undefined;
    var z_ip_buf: [64]u8 = undefined;

    const z_name = common.toPathZ(saved_name, &z_name_buf) orelse return;
    const z_vcpus = common.toPathZ(vcpu_str, &z_vcpus_buf) orelse return;
    const z_ram = common.toPathZ(saved_ram, &z_ram_buf) orelse return;

    var run_args: [16][*:0]const u8 = undefined;
    var argc: usize = 0;
    run_args[argc] = img_str;
    argc += 1;
    run_args[argc] = "--name";
    argc += 1;
    run_args[argc] = z_name.ptr;
    argc += 1;
    run_args[argc] = "--vcpus";
    argc += 1;
    run_args[argc] = z_vcpus.ptr;
    argc += 1;
    run_args[argc] = "--ram";
    argc += 1;
    run_args[argc] = z_ram.ptr;
    argc += 1;
    if (saved_disk.len > 0) {
        if (common.toPathZ(saved_disk, &z_disk_buf)) |z_disk| {
            run_args[argc] = "--disk";
            argc += 1;
            run_args[argc] = z_disk.ptr;
            argc += 1;
        }
    }
    if (saved_cdrom.len > 0) {
        if (common.toPathZ(saved_cdrom, &z_cdrom_buf)) |z_cdrom| {
            run_args[argc] = "--cdrom";
            argc += 1;
            run_args[argc] = z_cdrom.ptr;
            argc += 1;
        }
    }
    if (saved_ip.len > 0) {
        if (common.toPathZ(saved_ip, &z_ip_buf)) |z_ip| {
            run_args[argc] = "--ip";
            argc += 1;
            run_args[argc] = z_ip.ptr;
            argc += 1;
        }
    }
    run_args[argc] = if (saved_trusted) "--trusted" else "--untrusted";
    argc += 1;

    try vm_run.cmdRun(client, run_args[0..argc]);
}

test "vm_install: InstallGuestOption enum parses CLI flags" {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(
        InstallGuestOption.@"--offline-stub",
        std.meta.stringToEnum(InstallGuestOption, "--offline-stub").?,
    );
}
