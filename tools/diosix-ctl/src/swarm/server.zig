// Multi-Host Ed25519-Authenticated Swarm Fleet HTTP Server (TCP 8486).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("../api.zig");
const charter = @import("../charter.zig");
const charter_crypto = @import("../charter/crypto.zig");
const charter_ops = @import("../charter/ops.zig");
const common = @import("../common.zig");
const net_http = @import("../net/http.zig");
const protocol = @import("protocol.zig");
const ssh = @import("../ssh.zig");
const sysconfig = @import("../sysconfig.zig");

const MAX_SWARM_REQ_BYTES: usize = 128 * 1024;
const E_INTR: isize = -@as(isize, @backingInt(linux.E.INTR));

pub const JoinResponse = struct {
    peer: protocol.SwarmPeerRecord,
    active_toml: []const u8 = "",
};

const ProposeBody = struct {
    toml: []const u8,
};

fn writeJsonErr(
    cfd: i32,
    status: u16,
    reason: []const u8,
    msg: []const u8,
) void {
    var buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}\n", .{msg}) catch
        "{\"error\":\"swarm_error\"}\n";
    net_http.writeHttpResponse(
        cfd,
        status,
        reason,
        "application/json",
        body,
    ) catch {};
}

fn checkPrincipalMatches(
    client: *api.DiosixClient,
    peer: *const protocol.SwarmPeerRecord,
) bool {
    const m = client.getMission(null) catch return true;
    if (m.is_sealed == 0 or m.has_pubkey == 0) return true;
    if (peer.principal_pubkey.len == 0) return true;
    var pk_hex: [api.MISSION_PUBKEY_LEN * 2]u8 = undefined;
    _ = common.bytesToHex(&m.principal_pubkey, &pk_hex);
    return std.mem.eql(u8, &pk_hex, peer.principal_pubkey);
}

fn handleGetStatusOrTally(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    cfd: i32,
    port: u16,
    peer_ip_be: u32,
    include_tally: bool,
) void {
    const rec_json = protocol.buildSignedSelfRecordJson(
        allocator,
        client,
        port,
        peer_ip_be,
    ) catch return writeJsonErr(cfd, 500, "Internal Server Error", "sign_fail");
    defer allocator.free(rec_json);

    if (!include_tally) {
        net_http.writeHttpResponse(
            cfd,
            200,
            "OK",
            "application/json",
            rec_json,
        ) catch {};
        return;
    }

    const id = protocol.ensureNodeIdentity() catch
        return writeJsonErr(cfd, 500, "Internal Server Error", "id_fail");
    const tally = protocol.aggregateFleetTally(
        allocator,
        client,
        &id.pubkey_hex,
        null,
    );
    const body = allocator.print(
        "{{\"self\":{s},\"live_hosts\":{d}," ++
            "\"eligible_stake_pages\":{d},\"approved_stake_pages\":{d}," ++
            "\"rejected_stake_pages\":{d}}}\n",
        .{
            rec_json,
            tally.live_hosts,
            tally.eligible_stake_pages,
            tally.approved_stake_pages,
            tally.rejected_stake_pages,
        },
    ) catch return writeJsonErr(cfd, 500, "Internal Server Error", "oom");
    defer allocator.free(body);
    net_http.writeHttpResponse(cfd, 200, "OK", "application/json", body) catch
        {};
}

fn handlePostJoin(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    cfd: i32,
    port: u16,
    peer_ip_be: u32,
    req_body: []const u8,
) void {
    const parsed = std.json.parseFromSlice(
        protocol.SwarmPeerRecord,
        allocator,
        req_body,
        .{ .ignore_unknown_fields = true },
    ) catch return writeJsonErr(cfd, 400, "Bad Request", "invalid_json");
    defer parsed.deinit();

    const peer = parsed.value;
    if (!protocol.verifyPeerSignature(allocator, &peer)) {
        return writeJsonErr(cfd, 403, "Forbidden", "invalid_peer_signature");
    }
    if (!checkPrincipalMatches(client, &peer)) {
        return writeJsonErr(cfd, 403, "Forbidden", "principal_mismatch");
    }

    var saved = peer;
    saved.last_seen_ts = protocol.nowUnixSec();
    protocol.upsertPeerRecord(allocator, saved) catch
        return writeJsonErr(cfd, 500, "Internal Server Error", "save_fail");

    const self_json = protocol.buildSignedSelfRecordJson(
        allocator,
        client,
        port,
        peer_ip_be,
    ) catch return writeJsonErr(cfd, 500, "Internal Server Error", "sign_fail");
    defer allocator.free(self_json);

    var toml_esc: []u8 = allocator.dupe(u8, "") catch
        return writeJsonErr(cfd, 500, "Internal Server Error", "oom");
    defer allocator.free(toml_esc);
    if (common.readBinaryFile(
        sysconfig.ACTIVE_CHARTER_STATE_PATH,
        common.MAX_MANIFEST_SIZE,
    )) |raw| {
        defer common.unmapBinaryFile(raw);
        if (common.escapeJsonAlloc(allocator, raw)) |esc| {
            allocator.free(toml_esc);
            toml_esc = esc;
        } else |_| {}
    } else |_| {}

    const resp = allocator.print(
        "{{\"peer\":{s},\"active_toml\":\"{s}\"}}\n",
        .{ self_json, toml_esc },
    ) catch return writeJsonErr(cfd, 500, "Internal Server Error", "oom");
    defer allocator.free(resp);
    net_http.writeHttpResponse(cfd, 200, "OK", "application/json", resp) catch
        {};
}

fn handlePostPropose(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    cfd: i32,
    req_body: []const u8,
) void {
    const p_req = std.json.parseFromSlice(
        ProposeBody,
        allocator,
        req_body,
        .{ .ignore_unknown_fields = true },
    ) catch return writeJsonErr(cfd, 400, "Bad Request", "invalid_json");
    defer p_req.deinit();

    const parsed = charter.parseCharterToml(p_req.value.toml) catch
        return writeJsonErr(cfd, 400, "Bad Request", "invalid_charter_toml");

    var sig_ok = false;
    if (client.getMission(null)) |m| {
        if (m.is_sealed != 0 and m.has_pubkey != 0) {
            sig_ok = charter_crypto.verifyCharterSignature(
                &parsed,
                m.principal_pubkey,
            );
        } else {
            sig_ok = !parsed.hasPrincipalPubkey() or
                charter_crypto.verifyCharterSignature(&parsed, null);
        }
    } else |_| {
        sig_ok = !parsed.hasPrincipalPubkey() or
            charter_crypto.verifyCharterSignature(&parsed, null);
    }
    if (!sig_ok) {
        return writeJsonErr(cfd, 403, "Forbidden", "invalid_charter_sig");
    }

    charter_ops.savePendingCharterFile(p_req.value.toml);
    const lo = ssh.parseIpv4("127.0.0.1") orelse 0;
    charter_ops.postProposalToBoard(
        allocator,
        lo,
        sysconfig.DEFAULT_BOARD_PORT,
        p_req.value.toml,
        &parsed,
    ) catch {};

    const chk = charter_ops.evaluateProposalAgainstState(client, &parsed);
    const r_esc = common.escapeJsonAlloc(allocator, chk.reason) catch
        return writeJsonErr(cfd, 500, "Internal Server Error", "oom");
    defer allocator.free(r_esc);
    const resp = allocator.print(
        "{{\"accepted\":{},\"version\":{d},\"sha256\":\"{s}\"," ++
            "\"reason\":\"{s}\"}}\n",
        .{ chk.allowed, parsed.version, &parsed.sha256_hex, r_esc },
    ) catch return writeJsonErr(cfd, 500, "Internal Server Error", "oom");
    defer allocator.free(resp);
    net_http.writeHttpResponse(
        cfd,
        if (chk.allowed) 200 else 422,
        if (chk.allowed) "OK" else "Unprocessable Content",
        "application/json",
        resp,
    ) catch {};
}

pub fn handleSwarmClient(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    cfd: i32,
    port: u16,
    peer_ip_be: u32,
) void {
    net_http.setSocketTimeouts(cfd, 10);
    // Child VMs on diosix0 must never access host fleet governance.
    if (net_http.isPeerFromDiosixBridge(peer_ip_be)) {
        return writeJsonErr(cfd, 403, "Forbidden", "child_vm_denied");
    }

    const req = net_http.readHttpRequest(
        allocator,
        cfd,
        MAX_SWARM_REQ_BYTES,
    ) catch return writeJsonErr(cfd, 400, "Bad Request", "malformed_http");
    defer req.deinit(allocator);

    if (std.mem.eql(u8, req.method, "GET") and
        std.mem.eql(u8, req.path, "/v1/swarm/status"))
    {
        return handleGetStatusOrTally(
            allocator,
            client,
            cfd,
            port,
            peer_ip_be,
            false,
        );
    }
    if (std.mem.eql(u8, req.method, "GET") and
        std.mem.eql(u8, req.path, "/v1/swarm/tally"))
    {
        return handleGetStatusOrTally(
            allocator,
            client,
            cfd,
            port,
            peer_ip_be,
            true,
        );
    }
    if (std.mem.eql(u8, req.method, "POST") and
        std.mem.eql(u8, req.path, "/v1/swarm/join"))
    {
        return handlePostJoin(
            allocator,
            client,
            cfd,
            port,
            peer_ip_be,
            req.body,
        );
    }
    if (std.mem.eql(u8, req.method, "POST") and
        std.mem.eql(u8, req.path, "/v1/swarm/propose"))
    {
        return handlePostPropose(allocator, client, cfd, req.body);
    }
    writeJsonErr(cfd, 404, "Not Found", "unknown_endpoint");
}

pub fn runSwarmServer(port: u16, daemon: bool) !void {
    if (daemon) {
        if (net_http.isPidFileRunning(sysconfig.SWARM_PID_PATH) != null) return;
    }
    _ = try protocol.ensureNodeIdentity();
    const listen_fd = try net_http.bindAndListenTcp(port);
    if (daemon) {
        const is_child = try net_http.daemonizeServer(
            listen_fd,
            sysconfig.SWARM_PID_PATH,
            sysconfig.SWARM_LOG_PATH,
        );
        if (!is_child) return;
    }
    defer _ = linux.close(listen_fd);

    const allocator = std.heap.page_allocator;
    var client = api.DiosixClient.init();
    defer client.deinit();

    while (true) {
        var peer: linux.sockaddr.in = undefined;
        var plen: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        const acc_s: isize = @bitCast(
            linux.accept4(
                listen_fd,
                @ptrCast(&peer),
                &plen,
                linux.SOCK.CLOEXEC,
            ),
        );
        if (acc_s == E_INTR) continue;
        if (acc_s < 0) continue;
        const cfd: i32 = @intCast(acc_s);
        defer _ = linux.close(cfd);

        handleSwarmClient(allocator, &client, cfd, port, peer.addr);
    }
}

pub fn joinPeerEndpoint(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    target: []const u8,
) !JoinResponse {
    var host_part = target;
    var port: u16 = sysconfig.DEFAULT_SWARM_PORT;
    if (std.mem.lastIndexOfScalar(u8, target, ':')) |colon| {
        host_part = target[0..colon];
        port = std.fmt.parseInt(u16, target[colon + 1 ..], 10) catch
            sysconfig.DEFAULT_SWARM_PORT;
    }
    const peer_ip = ssh.parseIpv4(host_part) orelse return error.InvalidPeerIp;
    const self_json = try protocol.buildSignedSelfRecordJson(
        allocator,
        client,
        sysconfig.DEFAULT_SWARM_PORT,
        peer_ip,
    );
    defer allocator.free(self_json);

    const resp = try net_http.httpClientRequest(
        allocator,
        peer_ip,
        port,
        "POST",
        "/v1/swarm/join",
        "application/json",
        self_json,
        MAX_SWARM_REQ_BYTES,
    );
    defer resp.deinit(allocator);
    if (resp.status >= 400) return error.JoinRejected;

    const parsed = try std.json.parseFromSlice(
        JoinResponse,
        allocator,
        resp.body,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const p_rec = parsed.value.peer;
    if (!protocol.verifyPeerSignature(allocator, &p_rec)) {
        return error.InvalidPeerSignature;
    }
    if (!checkPrincipalMatches(client, &p_rec)) {
        return error.PrincipalMismatch;
    }

    var saved = p_rec;
    saved.last_seen_ts = protocol.nowUnixSec();
    try protocol.upsertPeerRecord(allocator, saved);

    // Adopt remote host's sealed Charter v1 cleanly if local M-mode unsealed.
    if (parsed.value.active_toml.len > 0) {
        const cur_m = client.getMission(null) catch
            std.mem.zeroes(api.MissionArgs);
        if (cur_m.is_sealed == 0) {
            if (charter.parseCharterToml(parsed.value.active_toml)) |rem_c| {
                if (rem_c.hasPrincipalPubkey() and
                    charter_crypto.verifyCharterSignature(&rem_c, null))
                {
                    if (rem_c.toMissionArgs(true)) |ma| {
                        _ = client.sealMission(&ma) catch {};
                        charter_ops.saveActiveCharterFile(
                            parsed.value.active_toml,
                        );
                    } else |_| {}
                }
            } else |_| {}
        }
    }

    return .{
        .peer = .{
            .node_pubkey = try allocator.dupe(u8, p_rec.node_pubkey),
            .endpoint = try allocator.dupe(u8, p_rec.endpoint),
            .principal_pubkey = try allocator.dupe(u8, p_rec.principal_pubkey),
            .charter_version = p_rec.charter_version,
            .charter_sha256 = try allocator.dupe(u8, p_rec.charter_sha256),
            .eligible_stake_pages = p_rec.eligible_stake_pages,
            .approved_stake_pages = p_rec.approved_stake_pages,
            .rejected_stake_pages = p_rec.rejected_stake_pages,
            .last_seen_ts = saved.last_seen_ts,
            .signature = try allocator.dupe(u8, p_rec.signature),
        },
        .active_toml = try allocator.dupe(u8, parsed.value.active_toml),
    };
}

test "swarm/server: constants and ProposeBody JSON parsing" {
    std.testing.refAllDecls(@This());
    const t = std.testing;
    const p = try std.json.parseFromSlice(
        ProposeBody,
        t.allocator,
        "{\"toml\":\"[charter]\\nid=\\\"a\\\"\"}",
        .{},
    );
    defer p.deinit();
    try t.expect(std.mem.indexOf(u8, p.value.toml, "[charter]") != null);
}
