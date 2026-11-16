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
    const sys_cfg = common.loadRuntimeSystemConfig();
    const prefix = sys_cfg.subnetPrefix();
    const z_ip = if (ip_str.len > 0)
        allocator.printSentinel("{s}", .{ip_str}, 0) catch return
    else
        allocator.printSentinel("{s}{d}", .{ prefix, cid }, 0) catch return;
    defer allocator.free(z_ip);
    const z_subnet = allocator.printSentinel(
        "{s}0/24",
        .{prefix},
        0,
    ) catch return;
    defer allocator.free(z_subnet);

    const ipt_bin: [*:0]const u8 =
        if (common.fileExistsPath(sysconfig.IPTABLES_BIN))
            sysconfig.IPTABLES_BIN
        else
            sysconfig.IPTABLES_SBIN;

    const del_argv = [_:null]?[*:0]const u8{
        ipt_bin, "-D", "FORWARD",    "-s", z_ip.ptr,
        "!",     "-d", z_subnet.ptr, "-j", "ACCEPT",
        null,
    };
    var tries: usize = 0;
    while (tries < MAX_IPTABLES_FLUSH_TRIES) : (tries += 1) {
        if (common.runSubprocess(&del_argv) != 0) break;
    }
    if ((mode == .wan or mode == .router) and upstream_cid == 0) {
        const ins_argv = [_:null]?[*:0]const u8{
            ipt_bin, "-I", "FORWARD",    "1",  "-s",     z_ip.ptr,
            "!",     "-d", z_subnet.ptr, "-j", "ACCEPT", null,
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
            "{s}{d}",
            .{ prefix, upstream_cid },
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
    ip_str: []const u8,
    mode: NetMode,
    upstream_cid: usize,
) void {
    const sys_cfg = common.loadRuntimeSystemConfig();
    const prefix = sys_cfg.subnetPrefix();
    const raw_buf = allocator.alloc(u8, MAX_MANIFEST_SIZE) catch return;
    defer allocator.free(raw_buf);
    const len = client.getManifest(cid, raw_buf) catch 0;
    const existing = raw_buf[0..len];
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    const gw_cid: usize =
        if (upstream_cid >= CID_FIRST_CHILD) upstream_cid else 1;
    const fallback_ip = if (ip_str.len == 0)
        allocator.print("{s}{d}", .{ prefix, cid }) catch return
    else
        null;
    defer if (fallback_ip) |fip| allocator.free(fip);
    const eff_ip = if (ip_str.len > 0) ip_str else fallback_ip.?;
    const hdr = allocator.print(
        "# diosix-net-mode: {s}\n" ++
            "# diosix-net-ip: {s}\n" ++
            "# diosix-net-gateway: {s}{d}\n" ++
            "# diosix-net-upstream-cid: {d}\n",
        .{ mode.asStr(), eff_ip, prefix, gw_cid, upstream_cid },
    ) catch return;
    defer allocator.free(hdr);
    out.appendSlice(allocator, hdr) catch return;
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        const trimmed = common.trimWhitespace(line);
        if (std.mem.startsWith(u8, trimmed, "# diosix-net-mode:") or
            std.mem.startsWith(u8, trimmed, "# diosix-net-ip:") or
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
    const sys_cfg = common.loadRuntimeSystemConfig();
    const prefix = sys_cfg.subnetPrefix();
    const cmd_str = if (upstream_cid >= CID_FIRST_CHILD)
        allocator.print(
            "IF=eth0; ip link show eth0 >/dev/null 2>&1 || IF=diosix0; " ++
                "ip route add {s}{d} dev $IF 2>/dev/null; " ++
                "ip route replace {s}0/24 via {s}{d} dev $IF; " ++
                "ip route replace default via {s}{d} dev $IF",
            .{
                prefix,
                upstream_cid,
                prefix,
                prefix,
                upstream_cid,
                prefix,
                upstream_cid,
            },
        ) catch return
    else
        allocator.print(
            "IF=eth0; ip link show eth0 >/dev/null 2>&1 || IF=diosix0; " ++
                "ip route replace {s}0/24 dev $IF 2>/dev/null; " ++
                "ip route replace default via {s}1 dev $IF",
            .{ prefix, prefix },
        ) catch return;
    defer allocator.free(cmd_str);
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
    updateManifestNetHeaders(
        allocator,
        client,
        cid,
        ip_str,
        mode,
        upstream_cid,
    );
    ssh.pruneKnownHost(ip_str);
    applyHostFirewall(cid, ip_str, mode, upstream_cid);
}

test "net/firewall: declarations compile cleanly" {
    std.testing.refAllDecls(@This());
}
