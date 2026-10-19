// Diosix Hypervisor Guest Management CLI — Guest VM Restart (dsx restart).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../api.zig");
const common = @import("../common.zig");
const vm = @import("../vm.zig");
const vm_run = @import("run.zig");

const MAX_PATH_LEN = common.MAX_PATH_LEN;
const MAX_MANIFEST_SIZE = common.MAX_MANIFEST_SIZE;
const GUEST_REGISTRY_PATH = common.GUEST_REGISTRY_PATH;
const TargetAlias = common.TargetAlias;

const printStr = common.printStr;
const parseCid = common.parseCid;
const copyStr = common.copyStr;
const readBinaryFile = common.readBinaryFile;
const unmapBinaryFile = common.unmapBinaryFile;
const matchTarget = common.matchTarget;

pub fn cmdRestart(
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
) !void {
    const exe_name = common.getExeName();
    const sys_cfg = common.loadRuntimeSystemConfig();
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
    if (std.meta.stringToEnum(TargetAlias, target_str)) |alias| {
        if (alias == .parent or alias == .@"0") {
            printStr("Error: Cannot restart parent VM (CID 0).\n");
            return;
        }
    }

    const target_cid = parseCid(target_str) catch 0;
    var name_buf: [64]u8 = undefined;
    var ram_buf: [32]u8 = undefined;
    var disk_buf: [MAX_PATH_LEN]u8 = undefined;
    var cdrom_buf: [MAX_PATH_LEN]u8 = undefined;
    var ip_buf: [64]u8 = undefined;
    var saved_name: []const u8 = target_str;
    var saved_vcpus: usize = sys_cfg.default_vcpus;
    var saved_ram: []const u8 = sys_cfg.defaultRam();
    var saved_disk: []const u8 = "";
    var saved_cdrom: []const u8 = "";
    var saved_ip: []const u8 = "";
    var saved_trusted = false;

    if (readBinaryFile(
        GUEST_REGISTRY_PATH,
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

test "vm/restart: TargetAlias enum matches parent and 0" {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(
        TargetAlias.parent,
        std.meta.stringToEnum(TargetAlias, "parent").?,
    );
}
