// Multi-Host Autonomous Fleet Collaboration CLI (`dsx swarm`).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("api.zig");
const charter = @import("charter.zig");
const charter_ops = @import("charter/ops.zig");
const common = @import("common.zig");
const net_http = @import("net/http.zig");
const ssh = @import("ssh.zig");
const sysconfig = @import("sysconfig.zig");
pub const protocol = @import("swarm/protocol.zig");
pub const server = @import("swarm/server.zig");

const SwarmSubcmd = enum {
    status,
    serve,
    join,
    propose,
    sync,
    help,
    @"--help",
    @"-h",
};

const SwarmOption = enum {
    @"--port",
    @"-p",
    @"--daemon",
    @"-d",
    @"--file",
    @"-f",
    @"--json",
    @"-j",
};

fn failExit() void {
    if (!@import("builtin").is_test) std.process.exit(1);
}

fn printSwarmUsage() void {
    const exe = common.getExeName();
    common.printFmt(
        \\Usage:
        \\  {s} swarm status [--json]             Show node identity and peers
        \\  {s} swarm serve [--port P] [--daemon]  Start multi-host fleet server
        \\  {s} swarm join <ip[:port]> [--json]    Join a peer host in the fleet
        \\  {s} swarm propose --file <toml> [-j]   Broadcast Charter proposal
        \\  {s} swarm sync [--json]                Refresh status with all peers
        \\
    , .{ exe, exe, exe, exe, exe });
}

fn freeJoinResponse(alloc: std.mem.Allocator, r: server.JoinResponse) void {
    alloc.free(r.peer.node_pubkey);
    alloc.free(r.peer.endpoint);
    alloc.free(r.peer.principal_pubkey);
    alloc.free(r.peer.charter_sha256);
    alloc.free(r.peer.signature);
    alloc.free(r.active_toml);
}

fn cmdStatus(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    json_f: bool,
) void {
    const id = protocol.ensureNodeIdentity() catch |e| {
        common.printApiError("Initialize node Ed25519 identity", e);
        return failExit();
    };
    const peers_parsed = protocol.loadPeersAlloc(allocator) catch return;
    defer peers_parsed.deinit();
    const tally = protocol.aggregateFleetTally(
        allocator,
        client,
        &id.pubkey_hex,
        null,
    );
    const pid = net_http.isPidFileRunning(sysconfig.SWARM_PID_PATH);
    var ip_buf: [16]u8 = undefined;
    const adv_ip = protocol.detectLocalAdvertiseIp(null, &ip_buf);

    if (json_f) {
        common.printFmt(
            "{{\"node_pubkey\":\"{s}\",\"endpoint\":\"{s}:{d}\"," ++
                "\"daemon_running\":{},\"live_hosts\":{d}," ++
                "\"eligible_stake_pages\":{d},\"approved_stake_pages\":{d}," ++
                "\"rejected_stake_pages\":{d},\"peer_count\":{d}}}\n",
            .{
                &id.pubkey_hex,
                adv_ip,
                sysconfig.DEFAULT_SWARM_PORT,
                pid != null,
                tally.live_hosts,
                tally.eligible_stake_pages,
                tally.approved_stake_pages,
                tally.rejected_stake_pages,
                peers_parsed.value.len,
            },
        );
        return;
    }

    common.printFmt(
        \\=== Diosix Swarm Fleet Status ===
        \\  Node Ed25519 pubkey : {s}
        \\  Advertise endpoint  : {s}:{d}
        \\  Swarm daemon        : {s}
        \\  Live fleet hosts    : {d} (peers tracked: {d})
        \\  Fleet quota stake   : {d}/{d} approved ({d} rejected)
        \\
    , .{
        &id.pubkey_hex,
        adv_ip,
        sysconfig.DEFAULT_SWARM_PORT,
        if (pid != null) "running" else "stopped",
        tally.live_hosts,
        peers_parsed.value.len,
        tally.approved_stake_pages,
        tally.eligible_stake_pages,
        tally.rejected_stake_pages,
    });
    for (peers_parsed.value) |p| {
        common.printFmt(
            "  peer {s} ({s}) charter v{d} stake {d}/{d}\n",
            .{
                p.endpoint,
                p.node_pubkey[0..@min(p.node_pubkey.len, 12)],
                p.charter_version,
                p.approved_stake_pages,
                p.eligible_stake_pages,
            },
        );
    }
}

fn cmdJoin(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
    json_f: bool,
) void {
    var target_opt: ?[]const u8 = null;
    for (args[1..]) |a| {
        const s = std.mem.span(a);
        if (!std.mem.startsWith(u8, s, "-") and target_opt == null) {
            target_opt = s;
        }
    }
    const target = target_opt orelse {
        common.printStr("Usage: dsx swarm join <ip[:port]> [--json]\n");
        return failExit();
    };
    const res = server.joinPeerEndpoint(allocator, client, target) catch |e| {
        common.printApiError("Join swarm peer", e);
        return failExit();
    };
    defer freeJoinResponse(allocator, res);
    if (json_f) {
        common.printFmt(
            "{{\"status\":\"joined\",\"peer_endpoint\":\"{s}\"," ++
                "\"peer_pubkey\":\"{s}\",\"adopted_charter\":{}}}\n",
            .{
                res.peer.endpoint,
                res.peer.node_pubkey,
                res.active_toml.len > 0,
            },
        );
    } else {
        common.printFmt("✓ Joined swarm peer {s} (key: {s}...).\n", .{
            res.peer.endpoint,
            res.peer.node_pubkey[0..@min(res.peer.node_pubkey.len, 16)],
        });
    }
}

fn postProposeToEndpoint(
    allocator: std.mem.Allocator,
    ep: []const u8,
    req_json: []const u8,
) bool {
    var host_part = ep;
    var port: u16 = sysconfig.DEFAULT_SWARM_PORT;
    if (std.mem.lastIndexOfScalar(u8, ep, ':')) |colon| {
        host_part = ep[0..colon];
        port = std.fmt.parseInt(u16, ep[colon + 1 ..], 10) catch
            sysconfig.DEFAULT_SWARM_PORT;
    }
    const ip = ssh.parseIpv4(host_part) orelse return false;
    const resp = net_http.httpClientRequest(
        allocator,
        ip,
        port,
        "POST",
        "/v1/swarm/propose",
        "application/json",
        req_json,
        32 * 1024,
    ) catch return false;
    defer resp.deinit(allocator);
    return resp.status < 400;
}

fn cmdPropose(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
    json_f: bool,
) void {
    var file_path: []const u8 = sysconfig.DEFAULT_CHARTER_CONFIG_PATH;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const s = std.mem.span(args[i]);
        const opt = std.meta.stringToEnum(SwarmOption, s) orelse continue;
        if ((opt == .@"--file" or opt == .@"-f") and i + 1 < args.len) {
            i += 1;
            file_path = std.mem.span(args[i]);
        }
    }
    const content = common.readBinaryFile(
        file_path,
        common.MAX_MANIFEST_SIZE,
    ) catch |e| {
        common.printApiError("Read Charter proposal", e);
        return failExit();
    };
    defer common.unmapBinaryFile(content);
    const parsed = charter.parseCharterToml(content) catch {
        common.printStr("Error: Invalid Charter TOML.\n");
        return failExit();
    };

    charter_ops.savePendingCharterFile(content);
    const lo = ssh.parseIpv4("127.0.0.1") orelse 0;
    charter_ops.postProposalToBoard(
        allocator,
        lo,
        sysconfig.DEFAULT_BOARD_PORT,
        content,
        &parsed,
    ) catch {};

    const chk = charter_ops.evaluateProposalAgainstState(client, &parsed);
    const t_esc = common.escapeJsonAlloc(allocator, content) catch return;
    defer allocator.free(t_esc);
    const req_json = allocator.print("{{\"toml\":\"{s}\"}}", .{t_esc}) catch
        return;
    defer allocator.free(req_json);

    const peers_parsed = protocol.loadPeersAlloc(allocator) catch return;
    defer peers_parsed.deinit();
    var sent: usize = 0;
    var accepted: usize = @intFromBool(chk.allowed);
    for (peers_parsed.value) |p| {
        sent += 1;
        if (postProposeToEndpoint(allocator, p.endpoint, req_json)) {
            accepted += 1;
        }
    }
    if (json_f) {
        common.printFmt(
            "{{\"version\":{d},\"local_allowed\":{},\"peers_notified\":{d}," ++
                "\"hosts_accepting\":{d},\"reason\":\"{s}\"}}\n",
            .{ parsed.version, chk.allowed, sent, accepted, chk.reason },
        );
    } else {
        const m = if (chk.allowed) "✓" else "!";
        common.printFmt(
            "{s} Disseminated v{d} locally + {d} peer(s) ({s}).\n",
            .{ m, parsed.version, sent, chk.reason },
        );
    }
}

fn cmdSync(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    json_f: bool,
) void {
    const peers_parsed = protocol.loadPeersAlloc(allocator) catch return;
    defer peers_parsed.deinit();
    var synced: usize = 0;
    for (peers_parsed.value) |p| {
        if (server.joinPeerEndpoint(allocator, client, p.endpoint)) |r| {
            freeJoinResponse(allocator, r);
            synced += 1;
        } else |_| {}
    }
    if (json_f) {
        common.printFmt("{{\"synced_peers\":{d}}}\n", .{synced});
    } else {
        common.printFmt("✓ Synced state with {d} swarm peer(s).\n", .{synced});
    }
}

pub fn cmdSwarm(
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
) !void {
    if (args.len == 0) return printSwarmUsage();
    const allocator = std.heap.page_allocator;
    const sub = std.meta.stringToEnum(
        SwarmSubcmd,
        std.mem.span(args[0]),
    ) orelse return printSwarmUsage();

    var port: u16 = sysconfig.DEFAULT_SWARM_PORT;
    var daemon = false;
    var json_f = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const s = std.mem.span(args[i]);
        const opt = std.meta.stringToEnum(SwarmOption, s) orelse continue;
        switch (opt) {
            .@"--daemon", .@"-d" => daemon = true,
            .@"--json", .@"-j" => json_f = true,
            .@"--port", .@"-p" => if (i + 1 < args.len) {
                i += 1;
                port = std.fmt.parseInt(u16, std.mem.span(args[i]), 10) catch
                    sysconfig.DEFAULT_SWARM_PORT;
            },
            else => {},
        }
    }

    switch (sub) {
        .status => cmdStatus(allocator, client, json_f),
        .serve => server.runSwarmServer(port, daemon) catch |e| {
            common.printApiError("Start swarm server", e);
            failExit();
        },
        .join => cmdJoin(allocator, client, args, json_f),
        .propose => cmdPropose(allocator, client, args, json_f),
        .sync => cmdSync(allocator, client, json_f),
        .help, .@"--help", .@"-h" => printSwarmUsage(),
    }
}

test "swarm: subcommand enum and submodule declarations compile" {
    std.testing.refAllDecls(@This());
    _ = protocol;
    _ = server;
    try std.testing.expectEqual(
        SwarmSubcmd.propose,
        std.meta.stringToEnum(SwarmSubcmd, "propose").?,
    );
}
