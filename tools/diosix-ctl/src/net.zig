// Diosix Hypervisor Guest Management CLI — Network Security (dsx net).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("api.zig");
const common = @import("common.zig");
const manifest = @import("manifest.zig");

const CID_FIRST_CHILD = common.CID_FIRST_CHILD;
const MAX_MANIFEST_SIZE = common.MAX_MANIFEST_SIZE;
const GUEST_REGISTRY_PATH = common.GUEST_REGISTRY_PATH;
const printStr = common.printStr;
const printFmt = common.printFmt;
const printApiError = common.printApiError;
const readBinaryFile = common.readBinaryFile;
const unmapBinaryFile = common.unmapBinaryFile;
const matchTarget = common.matchTarget;

pub const NetMode = enum {
    none,
    local,
    wan,
    router,

    pub fn asStr(self: NetMode) []const u8 {
        return switch (self) {
            .none => "none",
            .local => "local",
            .wan => "wan",
            .router => "router",
        };
    }
};

const NetModeAlias = enum {
    none,
    isolated,
    airgap,
    off,
    local,
    host,
    internal,
    wan,
    internet,
    external,
    router,
    gateway,
    filter,
};

pub fn parseNetMode(str: []const u8) ?NetMode {
    const alias = std.meta.stringToEnum(NetModeAlias, str) orelse return null;
    return switch (alias) {
        .none, .isolated, .airgap, .off => .none,
        .local, .host, .internal => .local,
        .wan, .internet, .external => .wan,
        .router, .gateway, .filter => .router,
    };
}

pub fn inferDomainNetMode(dom: manifest.DomainSpec) NetMode {
    for (dom.provides.items) |offer| {
        if (std.mem.startsWith(u8, offer.service, "net.")) return .router;
    }
    for (dom.routes.items) |route| {
        if (std.mem.startsWith(u8, route.require_pattern, "net.")) return .wan;
    }
    if (std.mem.eql(u8, dom.name, "vault-domain") or
        std.mem.eql(u8, dom.name, "vault"))
    {
        return .none;
    }
    return .local;
}

pub const NetPolicyState = struct {
    mode: NetMode = .local,
    upstream_cid: usize = 0,
};

pub fn extractManifestNetPolicy(content: []const u8) NetPolicyState {
    var state = NetPolicyState{};
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = common.trimWhitespace(raw_line);
        if (std.mem.startsWith(u8, line, "# diosix-net-mode:")) {
            const val = common.trimWhitespace(line["# diosix-net-mode:".len..]);
            if (parseNetMode(val)) |m| state.mode = m;
        } else if (std.mem.startsWith(u8, line, "# diosix-net-upstream-cid:")) {
            const val = common.trimWhitespace(
                line["# diosix-net-upstream-cid:".len..],
            );
            state.upstream_cid = std.fmt.parseInt(usize, val, 10) catch 0;
        }
    }
    return state;
}

pub fn resolveUpstreamCid(via_str: []const u8) ?usize {
    if (via_str.len == 0 or
        std.mem.eql(u8, via_str, "parent") or
        std.mem.eql(u8, via_str, "root") or
        std.mem.eql(u8, via_str, "0") or
        std.mem.eql(u8, via_str, "1"))
    {
        return 0;
    }
    const parsed_cid = std.fmt.parseInt(usize, via_str, 10) catch 0;
    if (readBinaryFile(GUEST_REGISTRY_PATH, MAX_MANIFEST_SIZE)) |content| {
        defer unmapBinaryFile(content);
        var iter = common.GuestRegistryIter.init(content);
        while (iter.next()) |entry| {
            if (matchTarget(via_str, parsed_cid, entry.cid, entry.name)) {
                return entry.cid;
            }
        }
    } else |_| {}
    if (parsed_cid >= CID_FIRST_CHILD) return parsed_cid;
    return null;
}

const ResolvedGuest = struct {
    cid: usize,
    name: []const u8,
    ip: []const u8,
};

fn resolveGuestTarget(
    target_str: []const u8,
    name_buf: *[64]u8,
    ip_buf: *[32]u8,
) ?ResolvedGuest {
    const parsed_cid = std.fmt.parseInt(usize, target_str, 10) catch 0;
    if (readBinaryFile(GUEST_REGISTRY_PATH, MAX_MANIFEST_SIZE)) |content| {
        defer unmapBinaryFile(content);
        var iter = common.GuestRegistryIter.init(content);
        while (iter.next()) |entry| {
            if (matchTarget(target_str, parsed_cid, entry.cid, entry.name)) {
                const n = common.copyStr(name_buf, entry.name);
                const ip = if (entry.ip.len > 0)
                    common.copyStr(ip_buf, entry.ip)
                else
                    std.fmt.bufPrint(
                        ip_buf,
                        "10.0.3.{d}",
                        .{entry.cid},
                    ) catch "10.0.3.2";
                return .{ .cid = entry.cid, .name = n, .ip = ip };
            }
        }
    } else |_| {}
    if (parsed_cid >= CID_FIRST_CHILD) {
        const n = common.copyStr(name_buf, target_str);
        const ip = std.fmt.bufPrint(
            ip_buf,
            "10.0.3.{d}",
            .{parsed_cid},
        ) catch "10.0.3.2";
        return .{ .cid = parsed_cid, .name = n, .ip = ip };
    }
    return null;
}

pub fn applyHostFirewall(
    cid: usize,
    ip_str: []const u8,
    mode: NetMode,
    upstream_cid: usize,
) void {
    if (@import("builtin").is_test) return;
    var ip_buf: [32]u8 = undefined;
    const eff_ip = if (ip_str.len > 0)
        ip_str
    else
        std.fmt.bufPrint(&ip_buf, "10.0.3.{d}", .{cid}) catch return;
    var z_ip_buf: [64]u8 = undefined;
    const z_ip = common.toPathZ(eff_ip, &z_ip_buf) orelse return;

    const ipt_bin: [*:0]const u8 =
        if (common.fileExistsPath("/usr/sbin/iptables"))
            "/usr/sbin/iptables"
        else
            "/sbin/iptables";

    const del_argv = [_:null]?[*:0]const u8{
        ipt_bin, "-D",          "FORWARD", "-s",     z_ip.ptr, "!",
        "-d",    "10.0.3.0/24", "-j",      "ACCEPT", null,
    };
    var tries: usize = 0;
    while (tries < 4) : (tries += 1) {
        if (common.runSubprocess(&del_argv) != 0) break;
    }
    if ((mode == .wan or mode == .router) and upstream_cid == 0) {
        const ins_argv = [_:null]?[*:0]const u8{
            ipt_bin, "-I", "FORWARD",     "1",  "-s",     z_ip.ptr,
            "!",     "-d", "10.0.3.0/24", "-j", "ACCEPT", null,
        };
        _ = common.runSubprocess(&ins_argv);
    }
}

pub fn updateManifestNetHeaders(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    cid: usize,
    mode: NetMode,
    upstream_cid: usize,
) void {
    const raw_buf = allocator.alloc(u8, 65536) catch return;
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

fn updateLiveGuestRoute(ip_str: []const u8, upstream_cid: usize) void {
    if (@import("builtin").is_test or ip_str.len == 0) return;
    const gw_cid: usize =
        if (upstream_cid >= CID_FIRST_CHILD) upstream_cid else 1;
    var t_raw: [64]u8 = undefined;
    var t_z: [64]u8 = undefined;
    const t_s = std.fmt.bufPrint(&t_raw, "root@{s}", .{ip_str}) catch return;
    const z_target = common.toPathZ(t_s, &t_z) orelse return;
    var c_raw: [160]u8 = undefined;
    var c_z: [160]u8 = undefined;
    const c_s = std.fmt.bufPrint(
        &c_raw,
        "ip route del default 2>/dev/null; " ++
            "ip route add default via 10.0.3.{d} dev diosix0 2>/dev/null",
        .{gw_cid},
    ) catch return;
    const z_cmd = common.toPathZ(c_s, &c_z) orelse return;
    const ssh_bin: [*:0]const u8 = if (common.fileExistsPath("/usr/bin/ssh"))
        "/usr/bin/ssh"
    else
        "/bin/ssh";
    const mgt_key: [*:0]const u8 = "/var/lib/diosix/keys/id_management";
    const argv = [_:null]?[*:0]const u8{
        ssh_bin,
        "-i",
        mgt_key,
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "ConnectTimeout=1",
        z_target.ptr,
        z_cmd.ptr,
        null,
    };
    _ = common.runSubprocess(&argv);
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
    applyHostFirewall(cid, ip_str, mode, upstream_cid);
}

const NetSubcmd = enum {
    status,
    list,
    grant,
    allow,
    revoke,
    deny,
    isolate,
    route,
    help,
    @"--help",
    @"-h",
};

fn printNetUsage() void {
    const exe = common.getExeName();
    printFmt(
        \\Usage:
        \\  {s} net status                         Show VM network policies
        \\  {s} net grant <vm|cid> [wan|router]    Grant WAN or router role
        \\  {s} net revoke <vm|cid>                Revoke WAN (local-only)
        \\  {s} net isolate <vm|cid>               Air-gap VM in M-mode
        \\  {s} net route <vm|cid> --via <vm|root> Route VM via router VM
        \\
    , .{ exe, exe, exe, exe, exe });
}

fn cmdNetStatus(client: *api.DiosixClient) void {
    const allocator = std.heap.page_allocator;
    const m_buf = allocator.alloc(u8, 65536) catch {
        return printStr("Error: Out of memory reading network status.\n");
    };
    defer allocator.free(m_buf);

    printStr(
        "CID   Name             IP            Mode      " ++
            "Upstream Gateway    WAN Egress\n" ++
            "----------------------------------------------" ++
            "--------------------------------\n",
    );

    var count: usize = 0;
    if (readBinaryFile(GUEST_REGISTRY_PATH, MAX_MANIFEST_SIZE)) |content| {
        defer unmapBinaryFile(content);
        var iter = common.GuestRegistryIter.init(content);
        while (iter.next()) |entry| {
            const m_len = client.getManifest(entry.cid, m_buf) catch 0;
            const pol = extractManifestNetPolicy(m_buf[0..m_len]);
            var gw_buf: [32]u8 = undefined;
            const via_rtr = pol.upstream_cid >= CID_FIRST_CHILD;
            const gw_str: []const u8 = if (pol.mode == .none)
                "-"
            else if (via_rtr)
                std.fmt.bufPrint(
                    &gw_buf,
                    "CID {d} (10.0.3.{d})",
                    .{ pol.upstream_cid, pol.upstream_cid },
                ) catch "router"
            else
                "root (10.0.3.1)";
            const wan_str: []const u8 = switch (pol.mode) {
                .none => "denied (air-gap)",
                .local => if (via_rtr) "via router" else "denied (local)",
                .wan => if (via_rtr) "via router" else "allowed (NAT)",
                .router => "allowed (router)",
            };
            printFmt(
                "{d:<5} {s:<16} {s:<13} {s:<9} {s:<19} {s}\n",
                .{
                    entry.cid,        entry.name, entry.ip,
                    pol.mode.asStr(), gw_str,     wan_str,
                },
            );
            count += 1;
        }
    } else |_| {}
    if (count == 0) printStr("No child VMs running.\n");
}

pub fn cmdNet(client: *api.DiosixClient, args: []const [*:0]const u8) !void {
    const allocator = std.heap.page_allocator;
    if (args.len == 0) return cmdNetStatus(client);
    const sub_raw = std.mem.span(args[0]);
    const sub = std.meta.stringToEnum(NetSubcmd, sub_raw) orelse {
        printFmt("Error: Unknown net subcommand '{s}'.\n", .{sub_raw});
        return printNetUsage();
    };
    if (sub == .status or sub == .list) return cmdNetStatus(client);
    if (sub == .help or sub == .@"--help" or sub == .@"-h") {
        return printNetUsage();
    }
    if (args.len < 2 or (sub == .route and args.len < 3)) {
        return printNetUsage();
    }
    const target_str = std.mem.span(args[1]);
    var n_buf: [64]u8 = undefined;
    var ip_buf: [32]u8 = undefined;
    const guest = resolveGuestTarget(target_str, &n_buf, &ip_buf) orelse {
        return printFmt("Error: Unknown child VM '{s}'.\n", .{target_str});
    };
    const m_buf = allocator.alloc(u8, 65536) catch return;
    defer allocator.free(m_buf);
    const m_len = client.getManifest(guest.cid, m_buf) catch 0;
    const cur = extractManifestNetPolicy(m_buf[0..m_len]);

    if (sub == .route) {
        var via_str: []const u8 = "";
        var idx: usize = 2;
        while (idx < args.len) : (idx += 1) {
            const s = std.mem.span(args[idx]);
            if (std.mem.eql(u8, s, "--via") and idx + 1 < args.len) {
                idx += 1;
                via_str = std.mem.span(args[idx]);
            } else if (!std.mem.startsWith(u8, s, "-")) {
                via_str = s;
            }
        }
        const up_cid = resolveUpstreamCid(via_str) orelse {
            return printFmt("Error: Unknown router VM '{s}'.\n", .{via_str});
        };
        if (up_cid == guest.cid) {
            return printStr("Error: Cannot route a VM through itself.\n");
        }
        const eff_mode: NetMode = if (cur.mode == .none) .local else cur.mode;
        client.setNetPolicy(guest.cid, 0, up_cid) catch |e| {
            return printApiError("Configure VM upstream route", e);
        };
        updateManifestNetHeaders(
            allocator,
            client,
            guest.cid,
            eff_mode,
            up_cid,
        );
        applyHostFirewall(guest.cid, guest.ip, eff_mode, up_cid);
        updateLiveGuestRoute(guest.ip, up_cid);
        if (up_cid == 0) {
            printFmt(
                "✓ Routed '{s}' (CID {d}) via parent (10.0.3.1).\n",
                .{ guest.name, guest.cid },
            );
        } else {
            printFmt(
                "✓ Routed '{s}' (CID {d}) via CID {d} (10.0.3.{d}).\n",
                .{ guest.name, guest.cid, up_cid, up_cid },
            );
        }
        return;
    }
    const mode: NetMode = if (sub == .isolate)
        .none
    else if (sub == .revoke or sub == .deny)
        .local
    else blk: {
        const m_str = if (args.len >= 3) std.mem.span(args[2]) else "wan";
        break :blk parseNetMode(m_str) orelse {
            return printFmt("Error: Invalid mode '{s}'.\n", .{m_str});
        };
    };
    const up_cid: usize =
        if (sub == .grant or sub == .allow) cur.upstream_cid else 0;
    const flags: u64 = if (mode == .none) api.NetPolicyFlags.ISOLATED else 0;
    client.setNetPolicy(guest.cid, flags, up_cid) catch |e| {
        return printApiError("Set VM network policy", e);
    };
    updateManifestNetHeaders(allocator, client, guest.cid, mode, up_cid);
    applyHostFirewall(guest.cid, guest.ip, mode, up_cid);
    printFmt(
        "✓ Network policy for '{s}' (CID {d}, {s}) set to '{s}'.\n",
        .{ guest.name, guest.cid, guest.ip, mode.asStr() },
    );
}

test "net: parseNetMode, inferDomainNetMode, and extractManifestNetPolicy" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;

    try testing.expectEqual(NetMode.none, parseNetMode("none").?);
    try testing.expectEqual(NetMode.none, parseNetMode("isolated").?);
    try testing.expectEqual(NetMode.local, parseNetMode("local").?);
    try testing.expectEqual(NetMode.wan, parseNetMode("wan").?);
    try testing.expectEqual(NetMode.router, parseNetMode("router").?);
    try testing.expect(parseNetMode("unknown") == null);

    var vault_dom = manifest.DomainSpec.init("vault-domain");
    defer vault_dom.deinit(testing.allocator);
    try testing.expectEqual(NetMode.none, inferDomainNetMode(vault_dom));

    var cfg_dom = manifest.DomainSpec.init("config-domain");
    defer cfg_dom.deinit(testing.allocator);
    try testing.expectEqual(NetMode.local, inferDomainNetMode(cfg_dom));

    const sample_manifest =
        \\# diosix-net-mode: wan
        \\# diosix-net-gateway: 10.0.3.2
        \\# diosix-net-upstream-cid: 2
        \\[vm]
        \\name = "app"
    ;
    const pol = extractManifestNetPolicy(sample_manifest);
    try testing.expectEqual(NetMode.wan, pol.mode);
    try testing.expectEqual(@as(usize, 2), pol.upstream_cid);
}
