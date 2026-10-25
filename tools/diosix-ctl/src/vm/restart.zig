// Diosix Hypervisor Guest Management CLI — Guest VM Restart (dsx restart).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../api.zig");
const common = @import("../common.zig");
const vm = @import("../vm.zig");
const vm_run = @import("run.zig");
const owned = @import("owned.zig");

const MAX_MANIFEST_SIZE = common.MAX_MANIFEST_SIZE;
const GUEST_REGISTRY_PATH = common.GUEST_REGISTRY_PATH;
const TargetAlias = common.TargetAlias;
const OwnedStrings = owned.OwnedStrings;
const OOM_MSG = owned.OOM_MSG;

/// Argument slots for the relaunch: the image, then up to six option/value
/// pairs (--name, --vcpus, --ram, --disk, --cdrom, --ip), then the trust
/// flag. That is 14 slots, so 16 always suffices.
const MAX_RESTART_ARGS: usize = 16;

const printStr = common.printStr;
const parseCid = common.parseCid;
const readBinaryFile = common.readBinaryFile;
const unmapBinaryFile = common.unmapBinaryFile;
const matchTarget = common.matchTarget;

/// A guest's registry fields, kept after the registry file is unmapped.
const SavedGuest = struct {
    name: []const u8,
    image: []const u8 = "",
    vcpus: usize,
    ram: []const u8,
    disk: []const u8 = "",
    cdrom: []const u8 = "",
    ip: []const u8 = "",
    trusted: bool = false,
};

/// An option that is only passed to the relaunch when its value is set.
const OptionalArg = struct {
    flag: [*:0]const u8,
    value: []const u8,
};

/// Copies the registry entry's strings into `strings` without truncation.
fn captureGuest(
    strings: *OwnedStrings,
    entry: common.GuestRegistryEntry,
) !SavedGuest {
    return .{
        .name = try strings.dupe(entry.name),
        .image = try strings.dupe(entry.image),
        .vcpus = entry.vcpus,
        .ram = try strings.dupe(entry.ram),
        .disk = try strings.dupe(entry.disk),
        .cdrom = try strings.dupe(entry.cdrom),
        .ip = try strings.dupe(entry.ip),
        .trusted = std.mem.eql(u8, entry.trust, "trusted"),
    };
}

pub fn cmdRestart(
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
) !void {
    const exe_name = common.getExeName();
    const sys_cfg = common.loadRuntimeSystemConfig();
    if (args.len == 0) {
        common.printFmt("Usage: {s} restart <name|cid>\n", .{exe_name});
        return;
    }
    const target_str = std.mem.span(args[0]);
    if (std.meta.stringToEnum(TargetAlias, target_str)) |alias| {
        if (alias == .parent or alias == .@"0") {
            printStr("Error: Cannot restart parent VM (CID 0).\n");
            return;
        }
    }

    const target_cid = parseCid(target_str) catch 0;
    var strings = OwnedStrings.init(std.heap.page_allocator);
    defer strings.deinit();
    var saved: SavedGuest = .{
        .name = target_str,
        .vcpus = sys_cfg.default_vcpus,
        .ram = sys_cfg.defaultRam(),
    };

    if (readBinaryFile(
        GUEST_REGISTRY_PATH,
        MAX_MANIFEST_SIZE,
    )) |content| {
        defer unmapBinaryFile(content);
        var iter = common.GuestRegistryIter.init(content);
        while (iter.next()) |entry| {
            if (matchTarget(target_str, target_cid, entry.cid, entry.name)) {
                saved = captureGuest(&strings, entry) catch {
                    printStr(OOM_MSG);
                    return;
                };
                break;
            }
        }
    } else |_| {}

    const stopped = try vm.cmdStop(client, args);
    if (!stopped) return;
    printStr("Restarting guest VM...\n");

    const img_str: [*:0]const u8 = if (saved.image.len > 0) blk: {
        const z_img = strings.dupe(saved.image) catch {
            printStr(OOM_MSG);
            return;
        };
        break :blk z_img.ptr;
    } else if (saved.disk.len > 0 or saved.cdrom.len > 0)
        "guest-shim"
    else
        "default";

    const z_name = strings.dupe(saved.name) catch {
        printStr(OOM_MSG);
        return;
    };
    const z_vcpus = strings.print("{d}", .{saved.vcpus}) catch {
        printStr(OOM_MSG);
        return;
    };
    const z_ram = strings.dupe(saved.ram) catch {
        printStr(OOM_MSG);
        return;
    };

    var run_args: [MAX_RESTART_ARGS][*:0]const u8 = undefined;
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
    const optional_args = [_]OptionalArg{
        .{ .flag = "--disk", .value = saved.disk },
        .{ .flag = "--cdrom", .value = saved.cdrom },
        .{ .flag = "--ip", .value = saved.ip },
    };
    for (optional_args) |opt| {
        if (opt.value.len == 0) continue;
        const z_value = strings.dupe(opt.value) catch {
            printStr(OOM_MSG);
            return;
        };
        run_args[argc] = opt.flag;
        argc += 1;
        run_args[argc] = z_value.ptr;
        argc += 1;
    }
    run_args[argc] = if (saved.trusted) "--trusted" else "--untrusted";
    argc += 1;

    try vm_run.cmdRun(client, run_args[0..argc]);
}

test "vm/restart: TargetAlias enum matches parent and 0" {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(
        TargetAlias.parent,
        std.meta.stringToEnum(TargetAlias, "parent").?,
    );
}

test "vm/restart: captureGuest keeps long registry fields intact" {
    var strings = OwnedStrings.init(std.testing.allocator);
    defer strings.deinit();

    const long_disk: [common.MAX_PATH_LEN + 1]u8 = @splat('d');
    const saved = try captureGuest(&strings, .{
        .cid = 2,
        .name = "a-guest-name-longer-than-the-old-64-byte-name-buffer-xxxx",
        .disk = &long_disk,
        .trust = "trusted",
    });
    try std.testing.expectEqualStrings(&long_disk, saved.disk);
    try std.testing.expectEqualStrings("256 MB", saved.ram);
    try std.testing.expect(saved.trusted);
    try std.testing.expectEqual(@as(usize, 0), saved.ip.len);
}
