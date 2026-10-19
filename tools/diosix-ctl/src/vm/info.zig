// Diosix Hypervisor Guest Management CLI — VM Status & Inspection (dsx info).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../api.zig");
const common = @import("../common.zig");
const host = @import("../host.zig");

const MAX_MANIFEST_SIZE = common.MAX_MANIFEST_SIZE;
const PAGE_SIZE_KB = common.PAGE_SIZE_KB;
const KB_PER_MB = common.KB_PER_MB;

const printStr = common.printStr;
const parseCid = common.parseCid;
const printApiError = common.printApiError;
const sanitizeJsonStr = common.sanitizeJsonStr;
const readBinaryFile = common.readBinaryFile;
const unmapBinaryFile = common.unmapBinaryFile;
const matchTarget = common.matchTarget;

const InfoOption = enum {
    @"--host",
    @"-h",
    @"--json",
    @"-j",
};

const TargetAlias = common.TargetAlias;

pub fn formatGuestDetail(
    buf: []u8,
    cid: usize,
    name: []const u8,
    vcpus: usize,
    ram: []const u8,
    ip: []const u8,
    trust: []const u8,
    status: []const u8,
    disk: []const u8,
    cdrom: []const u8,
    json_mode: bool,
) []const u8 {
    if (json_mode) {
        var name_s: [128]u8 = undefined;
        var ram_s: [64]u8 = undefined;
        var ip_s: [64]u8 = undefined;
        var trust_s: [32]u8 = undefined;
        var status_s: [32]u8 = undefined;
        var disk_s: [256]u8 = undefined;
        var cdrom_s: [256]u8 = undefined;
        const jfmt =
            "{{\"name\":\"{s}\",\"cid\":{d},\"status\":\"{s}\"," ++
            "\"hardware_trust\":\"{s}\",\"ram\":\"{s}\",\"vcpus\":{d}," ++
            "\"disk\":\"{s}\",\"cdrom\":\"{s}\",\"ip\":\"{s}\"}}\n";
        return std.fmt.bufPrint(buf, jfmt, .{
            sanitizeJsonStr(&name_s, name),
            cid,
            sanitizeJsonStr(&status_s, status),
            sanitizeJsonStr(&trust_s, trust),
            sanitizeJsonStr(&ram_s, ram),
            vcpus,
            sanitizeJsonStr(&disk_s, if (disk.len > 0) disk else "none"),
            sanitizeJsonStr(&cdrom_s, if (cdrom.len > 0) cdrom else "none"),
            sanitizeJsonStr(&ip_s, if (ip.len > 0) ip else "none"),
        }) catch "";
    }
    return std.fmt.bufPrint(buf,
        \\Name           : {s}
        \\Context ID     : {d}
        \\Status         : {s}
        \\Hardware trust : {s}
        \\RAM allocation : {s}
        \\Virtual CPUs   : {d}
        \\Storage disk   : {s}
        \\CD-ROM media   : {s}
        \\IP / Endpoint  : {s}
        \\
    , .{
        name,
        cid,
        status,
        trust,
        ram,
        vcpus,
        if (disk.len > 0) disk else "none",
        if (cdrom.len > 0) cdrom else "none",
        if (ip.len > 0) ip else "none",
    }) catch "";
}

fn printGuestDetail(
    cid: usize,
    name: []const u8,
    vcpus: usize,
    ram: []const u8,
    ip: []const u8,
    trust: []const u8,
    status: []const u8,
    disk: []const u8,
    cdrom: []const u8,
    json_mode: bool,
) void {
    var buf: [1024]u8 = undefined;
    const out = formatGuestDetail(
        &buf,
        cid,
        name,
        vcpus,
        ram,
        ip,
        trust,
        status,
        disk,
        cdrom,
        json_mode,
    );
    if (out.len > 0) printStr(out);
}

pub fn formatSelfInfo(
    buf: []u8,
    info: api.GuestInfo,
    json_mode: bool,
) []const u8 {
    const target_arch =
        std.enums.fromInt(api.TargetArch, info.target_arch) orelse .riscv64;
    const arch_name = switch (target_arch) {
        .riscv64 => "riscv64",
        .riscv32 => "riscv32",
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
    };

    const is_root = info.is_root != 0;
    const is_trusted = info.is_trusted != 0;
    const assigned_cid = if (info.assigned_cid > 0) info.assigned_cid else 1;
    const default_vcpus: usize = if (is_root) 4 else 1;
    const vcpus = if (info.vcpus > 0) info.vcpus else default_vcpus;
    const default_ram_mb: usize = 256;
    const ram_mb = if (info.self_ram_pages > 0)
        (info.self_ram_pages * PAGE_SIZE_KB) / KB_PER_MB
    else
        default_ram_mb;
    const self_ram_pages = if (info.self_ram_pages > 0)
        info.self_ram_pages
    else
        (ram_mb * 1024 / 4);

    if (json_mode) {
        const jfmt =
            "{{\"assigned_cid\":{d},\"architecture\":\"{s}\"," ++
            "\"root_vm\":{s},\"hardware_trust\":{s},\"ram_mb\":{d}," ++
            "\"ram_pages\":{d},\"vcpus\":{d},\"child_vms\":{d}}}\n";
        return std.fmt.bufPrint(buf, jfmt, .{
            assigned_cid,
            arch_name,
            if (is_root) "true" else "false",
            if (is_trusted) "true" else "false",
            ram_mb,
            self_ram_pages,
            vcpus,
            info.child_count,
        }) catch "";
    }

    return std.fmt.bufPrint(buf,
        \\Assigned CID   : {d}
        \\Architecture   : {s}
        \\Root VM        : {s}
        \\Hardware trust : {s}
        \\RAM allocation : {d} MB ({d} pages)
        \\Virtual CPUs   : {d}
        \\Child VMs      : {d}
        \\
    , .{
        assigned_cid,
        arch_name,
        if (is_root) "yes" else "no",
        if (is_trusted) "yes" else "no",
        ram_mb,
        self_ram_pages,
        vcpus,
        info.child_count,
    }) catch "";
}

pub fn cmdInfo(client: *api.DiosixClient, args: []const [*:0]const u8) !void {
    var target_str: ?[]const u8 = null;
    var host_mode = false;
    var json_mode = false;

    for (args) |arg| {
        const span = std.mem.span(arg);
        if (std.meta.stringToEnum(InfoOption, span)) |opt| {
            switch (opt) {
                .@"--host", .@"-h" => host_mode = true,
                .@"--json", .@"-j" => json_mode = true,
            }
        } else if (!std.mem.startsWith(u8, span, "-")) {
            target_str = span;
        }
    }

    if (host_mode) {
        try host.cmdHostInfo(client, json_mode);
        return;
    }

    const alias_opt = if (target_str) |t|
        std.meta.stringToEnum(TargetAlias, t)
    else
        TargetAlias.self;
    if (alias_opt != null and (alias_opt.? == .self or alias_opt.? == .root)) {
        const info = client.getInfo(1) catch |err| {
            printApiError("Query VM info", err);
            return;
        };

        var buf: [512]u8 = undefined;
        const out = formatSelfInfo(&buf, info, json_mode);
        if (out.len > 0) printStr(out);
    } else {
        const t_str = target_str.?;
        if (alias_opt != null and
            (alias_opt.? == .parent or alias_opt.? == .@"0"))
        {
            printStr(
                "Error: Cannot query parent VM (CID 0). Inspection is " ++
                    "restricted to self or direct children.\n",
            );
            return;
        }
        const target_cid = parseCid(t_str) catch 0;
        var found = false;

        if (readBinaryFile(
            common.GUEST_REGISTRY_PATH,
            MAX_MANIFEST_SIZE,
        )) |content| {
            defer unmapBinaryFile(content);
            var iter = common.GuestRegistryIter.init(content);
            while (iter.next()) |entry| {
                if (matchTarget(t_str, target_cid, entry.cid, entry.name)) {
                    found = true;
                    printGuestDetail(
                        entry.cid,
                        entry.name,
                        entry.vcpus,
                        entry.ram,
                        entry.ip,
                        entry.trust,
                        entry.status,
                        entry.disk,
                        entry.cdrom,
                        json_mode,
                    );
                    break;
                }
            }
        } else |_| {}

        if (!found and target_cid >= 2) {
            if (client.getInfo(target_cid)) |info| {
                found = true;
                const is_trusted_str =
                    if (info.is_trusted != 0) "trusted" else "untrusted";
                const ram_mb = if (info.self_ram_pages > 0)
                    (info.self_ram_pages * PAGE_SIZE_KB) / KB_PER_MB
                else
                    256;
                var ram_buf: [32]u8 = undefined;
                const ram_str = std.fmt.bufPrint(
                    &ram_buf,
                    "{d} MB",
                    .{ram_mb},
                ) catch "256 MB";
                printGuestDetail(
                    info.guest_id,
                    t_str,
                    info.vcpus,
                    ram_str,
                    "",
                    is_trusted_str,
                    "running",
                    "",
                    "",
                    json_mode,
                );
            } else |_| {}
        }

        if (!found) {
            printStr("Error: Guest VM not found.\n");
        }
    }
}

test "vm_info: formatSelfInfo handles zero and unknown target_arch safely" {
    std.testing.refAllDecls(@This());
    var buf: [512]u8 = undefined;
    const info = std.mem.zeroes(api.GuestInfo);
    const out = formatSelfInfo(&buf, info, true);
    try std.testing.expect(
        std.mem.indexOf(u8, out, "\"architecture\":\"riscv64\"") != null,
    );
}
