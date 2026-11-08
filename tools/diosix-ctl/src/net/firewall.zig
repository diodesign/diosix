// Diosix Host Firewall (`iptables`), Routing Table, and Manifest Net Sync.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../api.zig");
const common = @import("../common.zig");
const net = @import("../net.zig");
const ssh = @import("../ssh.zig");
const sysconfig = @import("../sysconfig.zig");

const CID_FIRST_CHILD = common.CID_FIRST_CHILD;
const MAX_MANIFEST_SIZE = common.MAX_MANIFEST_SIZE;
const NetMode = net.NetMode;

const MAX_IPTABLES_FLUSH_TRIES: usize = 4;

pub fn applyHostFirewall(
    cid: usize,
    ip_str: []const u8,
    mode: NetMode,
    upstream_cid: usize,
) void {
    if (@import("builtin").is_test) return;
    const allocator = std.heap.page_allocator;
    const z_ip = if (ip_str.len > 0)
        allocator.printSentinel("{s}", .{ip_str}, 0) catch return
    else
        allocator.printSentinel("10.0.3.{d}", .{cid}, 0) catch return;
    defer allocator.free(z_ip);

    const ipt_bin: [*:0]const u8 =
        if (common.fileExistsPath(sysconfig.IPTABLES_BIN))
            sysconfig.IPTABLES_BIN
        else
            sysconfig.IPTABLES_SBIN;

    const del_argv = [_:null]?[*:0]const u8{
        ipt_bin,  "-D",                          "FORWARD",
        "-s",     z_ip.ptr,                      "!",
        "-d",     sysconfig.DEFAULT_SUBNET_CIDR, "-j",
        "ACCEPT", null,
    };
    var tries: usize = 0;
    while (tries < MAX_IPTABLES_FLUSH_TRIES) : (tries += 1) {
        if (common.runSubprocess(&del_argv) != 0) break;
    }
    if ((mode == .wan or mode == .router) and upstream_cid == 0) {
        const ins_argv = [_:null]?[*:0]const u8{
            ipt_bin, "-I",     "FORWARD",
            "1",     "-s",     z_ip.ptr,
            "!",     "-d",     sysconfig.DEFAULT_SUBNET_CIDR,
            "-j",    "ACCEPT", null,
        };
        _ = common.runSubprocess(&ins_argv);
    }
    const ip_bin: [*:0]const u8 =
        if (common.fileExistsPath(sysconfig.IP_BIN))
            sysconfig.IP_BIN
        else
            sysconfig.IP_FALLBACK_BIN;
    const rt_del = [_:null]?[*:0]const u8{
        ip_bin, "route", "del", z_ip.ptr, "dev", "diosix0", null,
    };
    _ = common.runSubprocess(&rt_del);
    if (mode != .none and upstream_cid >= CID_FIRST_CHILD) {
        const z_gw = allocator.printSentinel(
            "10.0.3.{d}",
            .{upstream_cid},
            0,
        ) catch return;
        defer allocator.free(z_gw);
        const rt_add = [_:null]?[*:0]const u8{
            ip_bin,   "route", "replace", z_ip.ptr, "via",
            z_gw.ptr, "dev",   "diosix0", null,
        };
        _ = common.runSubprocess(&rt_add);
    }
}

pub fn updateManifestNetHeaders(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    cid: usize,
    mode: NetMode,
    upstream_cid: usize,
) void {
    const raw_buf = allocator.alloc(u8, MAX_MANIFEST_SIZE) catch return;
    defer allocator.free(raw_buf);
    const len = client.getManifest(cid, raw_buf) catch 0;
    const existing = raw_buf[0..len];
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    const gw_cid: usize =
        if (upstream_cid >= CID_FIRST_CHILD) upstream_cid else 1;
    const hdr = allocator.print(
        "# diosix-net-mode: {s}\n" ++
            "# diosix-net-gateway: 10.0.3.{d}\n" ++
            "# diosix-net-upstream-cid: {d}\n",
        .{ mode.asStr(), gw_cid, upstream_cid },
    ) catch return;
    defer allocator.free(hdr);
    out.appendSlice(allocator, hdr) catch return;
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        const trimmed = common.trimWhitespace(line);
        if (std.mem.startsWith(u8, trimmed, "# diosix-net-mode:") or
            std.mem.startsWith(u8, trimmed, "# diosix-net-gateway:") or
            std.mem.startsWith(u8, trimmed, "# diosix-net-upstream-cid:"))
        {
            continue;
        }
        if (line.len == 0 and out.items.len == hdr.len) continue;
        out.appendSlice(allocator, line) catch return;
        out.append(allocator, '\n') catch return;
    }
    _ = client.setManifest(cid, out.items) catch {};
}

pub fn updateLiveGuestRoute(
    allocator: std.mem.Allocator,
    ip_str: []const u8,
    upstream_cid: usize,
) void {
    if (@import("builtin").is_test or ip_str.len == 0) return;
    var owned_cmd: ?[]u8 = null;
    defer if (owned_cmd) |c| allocator.free(c);
    const cmd_str: []const u8 = if (upstream_cid >= CID_FIRST_CHILD) blk: {
        owned_cmd = allocator.print(
            "ip route add 10.0.3.{d} dev diosix0 2>/dev/null; " ++
                "ip route replace 10.0.3.0/24 via 10.0.3.{d} dev diosix0; " ++
                "ip route replace default via 10.0.3.{d} dev diosix0",
            .{ upstream_cid, upstream_cid, upstream_cid },
        ) catch return;
        break :blk owned_cmd.?;
    } else "ip route replace 10.0.3.0/24 dev diosix0 2>/dev/null; " ++
        "ip route replace default via 10.0.3.1 dev diosix0";
    ssh.execSsh(ssh.findPrivateKey(), "root", ip_str, cmd_str) catch {};
}

pub fn applyVmNetConfig(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    cid: usize,
    ip_str: []const u8,
    mode: NetMode,
    upstream_cid: usize,
) void {
    const flags: u64 = if (mode == .none) api.NetPolicyFlags.ISOLATED else 0;
    _ = client.setNetPolicy(cid, flags, upstream_cid) catch {};
    updateManifestNetHeaders(allocator, client, cid, mode, upstream_cid);
    ssh.pruneKnownHost(ip_str);
    applyHostFirewall(cid, ip_str, mode, upstream_cid);
}

test "net/firewall: declarations compile cleanly" {
    std.testing.refAllDecls(@This());
}
