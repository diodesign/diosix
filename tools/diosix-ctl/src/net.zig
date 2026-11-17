// Diosix Hypervisor Guest Management CLI — Network Security (dsx net).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("api.zig");
const common = @import("common.zig");
const manifest = @import("manifest.zig");
const firewall = @import("net/firewall.zig");

pub const applyHostFirewall = firewall.applyHostFirewall;
pub const updateManifestNetHeaders = firewall.updateManifestNetHeaders;
pub const updateLiveGuestRoute = firewall.updateLiveGuestRoute;
pub const applyVmNetConfig = firewall.applyVmNetConfig;

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

const IsolatedDomain = enum {
    @"vault-domain",
    vault,
};

pub fn inferDomainNetMode(dom: manifest.DomainSpec) NetMode {
    for (dom.provides.items) |offer| {
        if (std.mem.startsWith(u8, offer.service, "net.")) return .router;
    }
    for (dom.routes.items) |route| {
        if (std.mem.startsWith(u8, route.require_pattern, "net.")) return .wan;
    }
    if (std.meta.stringToEnum(IsolatedDomain, dom.name) != null) {
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

const ParentViaAlias = enum {
    parent,
    root,
    @"0",
    @"1",
};

pub fn resolveUpstreamCid(via_str: []const u8) ?usize {
    if (via_str.len == 0 or
        std.meta.stringToEnum(ParentViaAlias, via_str) != null)
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
    name: []u8,
    ip: []u8,

    fn deinit(self: ResolvedGuest, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.ip);
    }
};

fn resolveGuestTarget(
    allocator: std.mem.Allocator,
    target_str: []const u8,
) ?ResolvedGuest {
    const parsed_cid = std.fmt.parseInt(usize, target_str, 10) catch 0;
    if (readBinaryFile(GUEST_REGISTRY_PATH, MAX_MANIFEST_SIZE)) |content| {
        defer unmapBinaryFile(content);
        var iter = common.GuestRegistryIter.init(content);
        while (iter.next()) |entry| {
            if (matchTarget(target_str, parsed_cid, entry.cid, entry.name)) {
                const n = allocator.dupe(u8, entry.name) catch return null;
                errdefer allocator.free(n);
                const sys_cfg = common.loadRuntimeSystemConfig();
                const ip = if (entry.ip.len > 0)
                    allocator.dupe(u8, entry.ip) catch return null
                else
                    allocator.print(
                        "{s}{d}",
                        .{ sys_cfg.subnetPrefix(), entry.cid },
                    ) catch return null;
                return .{ .cid = entry.cid, .name = n, .ip = ip };
            }
        }
    } else |_| {}
    if (parsed_cid >= CID_FIRST_CHILD) {
        const sys_cfg = common.loadRuntimeSystemConfig();
        const n = allocator.dupe(u8, target_str) catch return null;
        errdefer allocator.free(n);
        const ip = allocator.print(
            "{s}{d}",
            .{ sys_cfg.subnetPrefix(), parsed_cid },
        ) catch return null;
        return .{ .cid = parsed_cid, .name = n, .ip = ip };
    }
    return null;
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

const RouteOption = enum {
    @"--via",
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
    const m_buf = allocator.alloc(u8, MAX_MANIFEST_SIZE) catch {
        return printStr("Error: Out of memory reading network status.\n");
    };
    defer allocator.free(m_buf);

    printStr(
        "CID   Name             IP            Mode      " ++
            "Upstream Gateway    WAN Egress\n" ++
            "----------------------------------------------" ++
            "--------------------------------\n",
    );

    const sys_cfg = common.loadRuntimeSystemConfig();
    const prefix = sys_cfg.subnetPrefix();
    var count: usize = 0;
    if (readBinaryFile(GUEST_REGISTRY_PATH, MAX_MANIFEST_SIZE)) |content| {
        defer unmapBinaryFile(content);
        var iter = common.GuestRegistryIter.init(content);
        while (iter.next()) |entry| {
            const m_len = client.getManifest(entry.cid, m_buf) catch 0;
            const pol = extractManifestNetPolicy(m_buf[0..m_len]);
            const via_rtr = pol.upstream_cid >= CID_FIRST_CHILD;
            var gw_owned: ?[]u8 = null;
            defer if (gw_owned) |g| allocator.free(g);
            const gw_str: []const u8 = if (pol.mode == .none)
                "-"
            else if (via_rtr) blk: {
                gw_owned = allocator.print(
                    "CID {d} ({s}{d})",
                    .{ pol.upstream_cid, prefix, pol.upstream_cid },
                ) catch null;
                break :blk gw_owned orelse "router";
            } else blk: {
                gw_owned = allocator.print("parent ({s}1)", .{prefix}) catch
                    null;
                break :blk gw_owned orelse "parent";
            };
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
    const guest = resolveGuestTarget(allocator, target_str) orelse {
        return printFmt("Error: Unknown child VM '{s}'.\n", .{target_str});
    };
    defer guest.deinit(allocator);
    const m_buf = allocator.alloc(u8, MAX_MANIFEST_SIZE) catch return;
    defer allocator.free(m_buf);
    const m_len = client.getManifest(guest.cid, m_buf) catch 0;
    const cur = extractManifestNetPolicy(m_buf[0..m_len]);

    if (sub == .route) {
        var via_str: []const u8 = "";
        var idx: usize = 2;
        while (idx < args.len) : (idx += 1) {
            const s = std.mem.span(args[idx]);
            if (std.meta.stringToEnum(RouteOption, s) != null and
                idx + 1 < args.len)
            {
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
            guest.ip,
            eff_mode,
            up_cid,
        );
        applyHostFirewall(guest.cid, guest.ip, eff_mode, up_cid);
        updateLiveGuestRoute(allocator, guest.ip, up_cid);
        const sys_cfg = common.loadRuntimeSystemConfig();
        const prefix = sys_cfg.subnetPrefix();
        if (up_cid == 0) {
            printFmt(
                "✓ Routed '{s}' (CID {d}) via parent ({s}1).\n",
                .{ guest.name, guest.cid, prefix },
            );
        } else {
            printFmt(
                "✓ Routed '{s}' (CID {d}) via CID {d} ({s}{d}).\n",
                .{ guest.name, guest.cid, up_cid, prefix, up_cid },
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
    updateManifestNetHeaders(
        allocator,
        client,
        guest.cid,
        guest.ip,
        mode,
        up_cid,
    );
    applyHostFirewall(guest.cid, guest.ip, mode, up_cid);
    printFmt(
        "✓ Network policy for '{s}' (CID {d}, {s}) set to '{s}'.\n",
        .{ guest.name, guest.cid, guest.ip, mode.asStr() },
    );
}

test "net: parseNetMode, inferDomainNetMode, and extractManifestNetPolicy" {
    std.testing.refAllDecls(@This());
    _ = firewall;
    _ = @import("net/http.zig");
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
