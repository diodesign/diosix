// Diosix Hypervisor Guest Management CLI — Guest OS Installation.
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
const sysconfig = @import("../sysconfig.zig");
const vm_run = @import("run.zig");
const restart = @import("restart.zig");
const owned = @import("owned.zig");

pub const cmdRestart = restart.cmdRestart;

const MAX_PATH_LEN = common.MAX_PATH_LEN;
const MAX_MANIFEST_SIZE = common.MAX_MANIFEST_SIZE;
const OwnedStrings = owned.OwnedStrings;
const OOM_MSG = owned.OOM_MSG;

/// Reading just the first page of the installer ISO is enough to prove that
/// it already exists locally; the full image is read later by `cmdRun`.
const ISO_EXISTS_PROBE_BYTES: usize = 4096;

/// Arguments handed to `cmdRun`: "guest-shim" plus five option/value pairs
/// (--name, --vcpus, --ram, --disk, --cdrom).
const INSTALL_RUN_ARGC: usize = 11;

const printStr = common.printStr;
const parseMemorySizeMb = common.parseMemorySizeMb;
const readBinaryFile = common.readBinaryFile;
const unmapBinaryFile = common.unmapBinaryFile;

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
    const sys_cfg = common.loadRuntimeSystemConfig();
    const allocator = std.heap.page_allocator;
    if (args.len == 0) {
        common.printFmt(
            \\Usage: {s} install-guest <os-name|iso> [--name <vm>]
            \\       [--disk <disk>] [--size <size>] [--vcpus <N>]
            \\       [--ram <size>] [--offline-stub]
            \\Examples:
            \\  {s} install-guest debian-riscv64 --disk debian-root --size 4GiB
            \\  {s} install-guest freebsd-riscv64 --name bsd-db --disk bsd-data
            \\
        , .{ exe_name, exe_name, exe_name });
        return;
    }

    var cat_mapped: ?[]const u8 = null;
    defer if (cat_mapped) |m| unmapBinaryFile(m);
    var parsed_entries: [catalog.MAX_CATALOG_ENTRIES]catalog.CatalogEntry =
        undefined;
    var active_catalog: []const catalog.CatalogEntry =
        &catalog.OFFICIAL_CATALOG;
    if (readBinaryFile(
        sys_cfg.catalogConfigPath(),
        MAX_MANIFEST_SIZE,
    )) |content| {
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
            common.printFmt(
                "Error: Unknown option '{s}'. Use '{s} install-guest' " ++
                    "for usage.\n",
                .{ span, exe_name },
            );
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
        sys_cfg.install_default_disk_mb;
    const final_vcpus: usize = if (vcpus_opt) |v|
        v
    else if (matched) |e|
        e.default_vcpus
    else
        2;
    var strings = OwnedStrings.init(allocator);
    defer strings.deinit();
    var final_ram_str: []const u8 = "1024M";
    if (ram_opt) |r| {
        final_ram_str = r;
    } else if (matched) |e| {
        final_ram_str = strings.print("{d}M", .{e.default_ram_mb}) catch {
            printStr(OOM_MSG);
            return;
        };
    }

    const iso_dir = sys_cfg.isoDir();
    const iso_filename: []const u8 = if (matched) |e| e.filename else os_query;
    const needs_iso_ext = matched == null and
        !std.mem.endsWith(u8, os_query, ".iso");
    const iso_is_abs = std.mem.startsWith(u8, iso_filename, "/");
    const full_iso_path = strings.print("{s}{s}{s}{s}", .{
        if (iso_is_abs) "" else iso_dir,
        if (iso_is_abs) "" else "/",
        iso_filename,
        if (needs_iso_ext) ".iso" else "",
    }) catch {
        printStr(OOM_MSG);
        return;
    };

    _ = linux.mkdir(sysconfig.VAR_LIB_DIOSIX_DIR, 0o755);
    const iso_dir_z = strings.dupe(iso_dir) catch {
        printStr(OOM_MSG);
        return;
    };
    _ = linux.mkdir(iso_dir_z.ptr, 0o755);
    if (readBinaryFile(full_iso_path, ISO_EXISTS_PROBE_BYTES)) |existing| {
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
                    common.printFmt(
                        "==> Staging offline test stub ISO for '{s}' " ++
                            "(--offline-stub)...\n",
                        .{entry.id},
                    );
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
                    common.printFmt(
                        "Error: Failed to download installer ISO from " ++
                            "'{s}'. Pull or import the ISO first, or pass " ++
                            "'--offline-stub' for offline testing.\n",
                        .{entry.url},
                    );
                    return;
                }
            };
        } else {
            common.printFmt(
                "Error: Installer ISO '{s}' not found locally and '{s}' " ++
                    "is not a known catalog ID.\n",
                .{ full_iso_path, os_query },
            );
            return;
        }
    }

    // Backing storage the storage layer provisions the disk path into.
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

    const run_args = buildRunArgs(
        &strings,
        final_vm_name,
        final_vcpus,
        final_ram_str,
        disk_path,
        full_iso_path,
    ) catch {
        printStr(OOM_MSG);
        return;
    };
    try vm_run.cmdRun(client, &run_args);
}

/// Builds the guest-shim argument vector for the install run; every string
/// is a NUL-terminated copy owned by `strings`.
fn buildRunArgs(
    strings: *OwnedStrings,
    vm_name: []const u8,
    vcpus: usize,
    ram: []const u8,
    disk: []const u8,
    cdrom: []const u8,
) ![INSTALL_RUN_ARGC][*:0]const u8 {
    return .{
        "guest-shim",
        "--name",
        (try strings.dupe(vm_name)).ptr,
        "--vcpus",
        (try strings.print("{d}", .{vcpus})).ptr,
        "--ram",
        (try strings.dupe(ram)).ptr,
        "--disk",
        (try strings.dupe(disk)).ptr,
        "--cdrom",
        (try strings.dupe(cdrom)).ptr,
    };
}

test "vm_install: buildRunArgs copies long values without truncation" {
    var strings = OwnedStrings.init(std.testing.allocator);
    defer strings.deinit();

    const long_name: [MAX_PATH_LEN]u8 = @splat('n');
    const args = try buildRunArgs(
        &strings,
        &long_name,
        4,
        "1024M",
        "/disks/a.img",
        "/iso/a.iso",
    );
    try std.testing.expectEqualStrings(&long_name, std.mem.span(args[2]));
    try std.testing.expectEqualStrings("4", std.mem.span(args[4]));
    try std.testing.expectEqualStrings("/iso/a.iso", std.mem.span(args[10]));
}

test "vm_install: InstallGuestOption enum parses CLI flags" {
    std.testing.refAllDecls(@This());
    _ = restart;
    try std.testing.expectEqual(
        InstallGuestOption.@"--offline-stub",
        std.meta.stringToEnum(InstallGuestOption, "--offline-stub").?,
    );
}
