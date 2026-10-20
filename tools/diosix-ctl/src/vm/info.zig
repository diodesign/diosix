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

const OOM_MSG = "Error: Out of memory formatting output.\n";
const BUF_TOO_SMALL_MSG = "Error: Output buffer too small.\n";

const GUEST_JSON_FMT =
    "{{\"name\":\"{s}\",\"cid\":{d},\"status\":\"{s}\"," ++
    "\"hardware_trust\":\"{s}\",\"ram\":\"{s}\",\"vcpus\":{d}," ++
    "\"disk\":\"{s}\",\"cdrom\":\"{s}\",\"ip\":\"{s}\"}}\n";

const GUEST_TEXT_FMT =
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
;

const SELF_JSON_FMT =
    "{{\"assigned_cid\":{d},\"architecture\":\"{s}\"," ++
    "\"root_vm\":{s},\"hardware_trust\":{s},\"ram_mb\":{d}," ++
    "\"ram_pages\":{d},\"vcpus\":{d},\"child_vms\":{d}}}\n";

const SELF_TEXT_FMT =
    \\Assigned CID   : {d}
    \\Architecture   : {s}
    \\Root VM        : {s}
    \\Hardware trust : {s}
    \\RAM allocation : {d} MB ({d} pages)
    \\Virtual CPUs   : {d}
    \\Child VMs      : {d}
    \\
;

/// Sanitizes several strings into one heap block sized up front, so JSON
/// fields are never truncated. Sanitizing only ever drops characters, so a
/// block as large as the sum of the raw strings always suffices.
const JsonScratch = struct {
    block: []u8,
    used: usize = 0,

    fn init(allocator: std.mem.Allocator, capacity: usize) !JsonScratch {
        return .{ .block = try allocator.alloc(u8, capacity) };
    }

    fn deinit(self: JsonScratch, allocator: std.mem.Allocator) void {
        allocator.free(self.block);
    }

    fn clean(self: *JsonScratch, raw: []const u8) []const u8 {
        std.debug.assert(raw.len <= self.block.len - self.used);
        const dest = self.block[self.used..][0..raw.len];
        const out = sanitizeJsonStr(dest, raw);
        self.used += out.len;
        return out;
    }
};

/// Copies `text` into `buf` when it fits; otherwise writes a visible error
/// message instead of silently truncating or returning nothing.
fn fitOrReport(buf: []u8, text: []const u8) []const u8 {
    if (text.len <= buf.len) {
        @memcpy(buf[0..text.len], text);
        return buf[0..text.len];
    }
    return common.copyStr(buf, BUF_TOO_SMALL_MSG);
}

/// Formats guest details into a heap string owned by the caller.
fn allocGuestDetail(
    allocator: std.mem.Allocator,
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
) ![]u8 {
    const disk_s = if (disk.len > 0) disk else "none";
    const cdrom_s = if (cdrom.len > 0) cdrom else "none";
    const ip_s = if (ip.len > 0) ip else "none";
    if (json_mode) {
        var scratch = try JsonScratch.init(
            allocator,
            name.len + status.len + trust.len + ram.len +
                disk_s.len + cdrom_s.len + ip_s.len,
        );
        defer scratch.deinit(allocator);
        return allocator.print(GUEST_JSON_FMT, .{
            scratch.clean(name),
            cid,
            scratch.clean(status),
            scratch.clean(trust),
            scratch.clean(ram),
            vcpus,
            scratch.clean(disk_s),
            scratch.clean(cdrom_s),
            scratch.clean(ip_s),
        });
    }
    return allocator.print(GUEST_TEXT_FMT, .{
        name, cid, status, trust, ram, vcpus, disk_s, cdrom_s, ip_s,
    });
}

/// Fixed-buffer entry point kept for existing callers; when `buf` is too
/// small (or memory is exhausted) it returns a visible error message.
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
    const allocator = std.heap.page_allocator;
    const text = allocGuestDetail(
        allocator,
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
    ) catch return common.copyStr(buf, OOM_MSG);
    defer allocator.free(text);
    return fitOrReport(buf, text);
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
    const allocator = std.heap.page_allocator;
    const out = allocGuestDetail(
        allocator,
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
    ) catch {
        printStr(OOM_MSG);
        return;
    };
    defer allocator.free(out);
    printStr(out);
}

/// Formats this VM's own info into a heap string owned by the caller.
fn allocSelfInfo(
    allocator: std.mem.Allocator,
    info: api.GuestInfo,
    json_mode: bool,
) ![]u8 {
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
        return allocator.print(SELF_JSON_FMT, .{
            assigned_cid,
            arch_name,
            if (is_root) "true" else "false",
            if (is_trusted) "true" else "false",
            ram_mb,
            self_ram_pages,
            vcpus,
            info.child_count,
        });
    }

    return allocator.print(SELF_TEXT_FMT, .{
        assigned_cid,
        arch_name,
        if (is_root) "yes" else "no",
        if (is_trusted) "yes" else "no",
        ram_mb,
        self_ram_pages,
        vcpus,
        info.child_count,
    });
}

/// Fixed-buffer entry point kept for existing callers; when `buf` is too
/// small (or memory is exhausted) it returns a visible error message.
pub fn formatSelfInfo(
    buf: []u8,
    info: api.GuestInfo,
    json_mode: bool,
) []const u8 {
    const allocator = std.heap.page_allocator;
    const text = allocSelfInfo(allocator, info, json_mode) catch {
        return common.copyStr(buf, OOM_MSG);
    };
    defer allocator.free(text);
    return fitOrReport(buf, text);
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

        const allocator = std.heap.page_allocator;
        const out = allocSelfInfo(allocator, info, json_mode) catch {
            printStr(OOM_MSG);
            return;
        };
        defer allocator.free(out);
        printStr(out);
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
                const allocator = std.heap.page_allocator;
                const ram_str = allocator.print("{d} MB", .{ram_mb}) catch {
                    printStr(OOM_MSG);
                    return;
                };
                defer allocator.free(ram_str);
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

/// Roomy enough for any self-info output in the tests below.
const TEST_BUF_BYTES: usize = 512;

test "vm_info: formatSelfInfo handles zero and unknown target_arch safely" {
    std.testing.refAllDecls(@This());
    var buf: [TEST_BUF_BYTES]u8 = undefined;
    const info = std.mem.zeroes(api.GuestInfo);
    const out = formatSelfInfo(&buf, info, true);
    try std.testing.expect(
        std.mem.indexOf(u8, out, "\"architecture\":\"riscv64\"") != null,
    );
}

test "vm_info: fitOrReport reports instead of truncating silently" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("abc", fitOrReport(&buf, "abc"));
    const out = fitOrReport(&buf, "far too long for the buffer");
    try std.testing.expect(out.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, BUF_TOO_SMALL_MSG, out));
}

test "vm_info: JSON guest detail is never truncated" {
    const long_name: [300]u8 = @splat('n');
    const out = try allocGuestDetail(
        std.testing.allocator,
        2,
        &long_name,
        1,
        "64 MB",
        "",
        "trusted",
        "running",
        "",
        "",
        true,
    );
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, &long_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ip\":\"none\"") != null);
}
