// Multi-Host Ed25519 Peer Identity, State Serialization & Workload Sharding.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("../api.zig");
const charter_crypto = @import("../charter/crypto.zig");
const common = @import("../common.zig");
const net_http = @import("../net/http.zig");
const passkey = @import("../passkey.zig");
const ssh = @import("../ssh.zig");
const sysconfig = @import("../sysconfig.zig");

const Ed25519 = std.crypto.sign.Ed25519;

pub const PEER_STALE_WINDOW_SEC: i64 = 120;
const MAX_PEERS_FILE_BYTES: usize = 256 * 1024;
const MAX_SWARM_PEERS: usize = 64;

pub const NodeIdentity = struct {
    pubkey: [api.MISSION_PUBKEY_LEN]u8,
    pubkey_hex: [api.MISSION_PUBKEY_LEN * 2]u8,
};

pub const SwarmPeerRecord = struct {
    node_pubkey: []const u8 = "",
    endpoint: []const u8 = "",
    principal_pubkey: []const u8 = "",
    charter_version: u32 = 0,
    charter_sha256: []const u8 = "",
    eligible_stake_pages: u64 = 0,
    approved_stake_pages: u64 = 0,
    rejected_stake_pages: u64 = 0,
    last_seen_ts: i64 = 0,
    signature: []const u8 = "",
};

pub const FleetTally = struct {
    live_hosts: usize = 1,
    eligible_stake_pages: u64 = 0,
    approved_stake_pages: u64 = 0,
    rejected_stake_pages: u64 = 0,
};

pub fn nowUnixSec() i64 {
    var tv: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &tv);
    return @intCast(tv.sec);
}

/// Load the host's persistent Ed25519 node identity, creating it if absent.
pub fn ensureNodeIdentity() !NodeIdentity {
    if (common.readBinaryFile(sysconfig.NODE_PRIVKEY_PATH, 4096)) |priv_raw| {
        defer common.unmapBinaryFile(priv_raw);
        var seed = try charter_crypto.decodeSeedHex(priv_raw);
        defer std.crypto.secureZero(u8, &seed);
        const kp = try Ed25519.KeyPair.generateDeterministic(seed);
        const pk = kp.public_key.toBytes();
        var pk_hex: [api.MISSION_PUBKEY_LEN * 2]u8 = undefined;
        _ = common.bytesToHex(&pk, &pk_hex);
        return .{ .pubkey = pk, .pubkey_hex = pk_hex };
    } else |_| {}

    const pk = try charter_crypto.generatePrincipalKeypair(
        sysconfig.NODE_PRIVKEY_PATH,
        sysconfig.NODE_PUBKEY_PATH,
    );
    var pk_hex: [api.MISSION_PUBKEY_LEN * 2]u8 = undefined;
    _ = common.bytesToHex(&pk, &pk_hex);
    return .{ .pubkey = pk, .pubkey_hex = pk_hex };
}

pub fn signWithNodeKey(msg: []const u8) ![api.MISSION_SIG_LEN * 2]u8 {
    _ = try ensureNodeIdentity();
    const priv_raw = try common.readBinaryFile(
        sysconfig.NODE_PRIVKEY_PATH,
        4096,
    );
    defer common.unmapBinaryFile(priv_raw);
    var seed = try charter_crypto.decodeSeedHex(priv_raw);
    defer std.crypto.secureZero(u8, &seed);
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const sig = try kp.sign(msg, null);
    var out_hex: [api.MISSION_SIG_LEN * 2]u8 = undefined;
    _ = common.bytesToHex(&sig.toBytes(), &out_hex);
    return out_hex;
}

pub fn buildPeerSignPreimage(
    allocator: std.mem.Allocator,
    rec: *const SwarmPeerRecord,
) ![]u8 {
    return allocator.print(
        "diosix-swarm-v1:{s}:{s}:{s}:{d}:{s}:{d}:{d}:{d}:{d}",
        .{
            rec.node_pubkey,
            rec.endpoint,
            rec.principal_pubkey,
            rec.charter_version,
            rec.charter_sha256,
            rec.eligible_stake_pages,
            rec.approved_stake_pages,
            rec.rejected_stake_pages,
            rec.last_seen_ts,
        },
    );
}

pub fn verifyPeerSignature(
    allocator: std.mem.Allocator,
    rec: *const SwarmPeerRecord,
) bool {
    if (rec.node_pubkey.len != api.MISSION_PUBKEY_LEN * 2) return false;
    if (rec.signature.len != api.MISSION_SIG_LEN * 2) return false;
    var pk_bytes: [api.MISSION_PUBKEY_LEN]u8 = undefined;
    const pk_dec = passkey.hexToBytes(rec.node_pubkey, &pk_bytes) orelse
        return false;
    if (pk_dec.len != api.MISSION_PUBKEY_LEN) return false;
    var sig_bytes: [api.MISSION_SIG_LEN]u8 = undefined;
    const sig_dec = passkey.hexToBytes(rec.signature, &sig_bytes) orelse
        return false;
    if (sig_dec.len != api.MISSION_SIG_LEN) return false;

    const pk = Ed25519.PublicKey.fromBytes(pk_bytes) catch return false;
    const sig = Ed25519.Signature.fromBytes(sig_bytes);
    const pre = buildPeerSignPreimage(allocator, rec) catch return false;
    defer allocator.free(pre);
    sig.verify(pre, pk) catch return false;
    return true;
}

pub fn detectLocalAdvertiseIp(
    peer_ip_be: ?u32,
    out_buf: *[16]u8,
) []const u8 {
    if (common.readBinaryFile(sysconfig.PROC_CMDLINE_PATH, 4096)) |cmd| {
        defer common.unmapBinaryFile(cmd);
        const tag = "diosix.swarm_ip=";
        if (std.mem.indexOf(u8, cmd, tag)) |idx| {
            const after = cmd[idx + tag.len ..];
            const end = std.mem.indexOfAny(u8, after, " \t\r\n/") orelse
                after.len;
            const ip_str = after[0..end];
            if (ssh.parseIpv4(ip_str) != null) {
                const n = @min(ip_str.len, 15);
                @memcpy(out_buf[0..n], ip_str[0..n]);
                return out_buf[0..n];
            }
        }
    } else |_| {}

    if (peer_ip_be) |p_ip| {
        const stype = linux.SOCK.DGRAM | linux.SOCK.CLOEXEC;
        const fd_s: isize = @bitCast(linux.socket(linux.AF.INET, stype, 0));
        if (fd_s >= 0) {
            const fd: i32 = @intCast(fd_s);
            defer _ = linux.close(fd);
            var paddr: linux.sockaddr.in = .{
                .family = linux.AF.INET,
                .port = std.mem.nativeToBig(u16, sysconfig.DEFAULT_SWARM_PORT),
                .addr = p_ip,
                .zero = @splat(0),
            };
            const cr: isize = @bitCast(
                linux.connect(fd, @ptrCast(&paddr), @sizeOf(linux.sockaddr.in)),
            );
            if (cr == 0) {
                var loc: linux.sockaddr.in = undefined;
                var l_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
                const gr: isize = @bitCast(
                    linux.getsockname(fd, @ptrCast(&loc), &l_len),
                );
                if (gr == 0 and loc.addr != 0) {
                    return net_http.formatIpv4(loc.addr, out_buf);
                }
            }
        }
    }
    return "127.0.0.1";
}

pub fn buildSignedSelfRecordJson(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    port: u16,
    peer_ip_be: ?u32,
) ![]u8 {
    const id = try ensureNodeIdentity();
    var ip_buf: [16]u8 = undefined;
    const adv_ip = detectLocalAdvertiseIp(peer_ip_be, &ip_buf);
    const ep = try allocator.print("{s}:{d}", .{ adv_ip, port });
    defer allocator.free(ep);

    var m_args = std.mem.zeroes(api.MissionArgs);
    if (client.getMission(null)) |mi| {
        m_args = mi;
    } else |_| {}
    var pk_hex: [api.MISSION_PUBKEY_LEN * 2]u8 = undefined;
    const p_pk_slice: []const u8 = if (m_args.has_pubkey != 0) blk: {
        _ = common.bytesToHex(&m_args.principal_pubkey, &pk_hex);
        break :blk &pk_hex;
    } else "";
    var h_hex: [64]u8 = @splat('0');
    _ = common.bytesToHex(&m_args.charter_hash, &h_hex);

    var rec = SwarmPeerRecord{
        .node_pubkey = &id.pubkey_hex,
        .endpoint = ep,
        .principal_pubkey = p_pk_slice,
        .charter_version = if (m_args.is_sealed != 0) m_args.version else 0,
        .charter_sha256 = &h_hex,
        .eligible_stake_pages = m_args.eligible_stake_pages,
        .approved_stake_pages = m_args.approved_stake_pages,
        .rejected_stake_pages = m_args.rejected_stake_pages,
        .last_seen_ts = nowUnixSec(),
    };
    const pre = try buildPeerSignPreimage(allocator, &rec);
    defer allocator.free(pre);
    const sig_hex = try signWithNodeKey(pre);
    const ep_esc = try common.escapeJsonAlloc(allocator, ep);
    defer allocator.free(ep_esc);
    return allocator.print(
        "{{\"node_pubkey\":\"{s}\",\"endpoint\":\"{s}\"," ++
            "\"principal_pubkey\":\"{s}\",\"charter_version\":{d}," ++
            "\"charter_sha256\":\"{s}\",\"eligible_stake_pages\":{d}," ++
            "\"approved_stake_pages\":{d},\"rejected_stake_pages\":{d}," ++
            "\"last_seen_ts\":{d},\"signature\":\"{s}\"}}",
        .{
            rec.node_pubkey,
            ep_esc,
            rec.principal_pubkey,
            rec.charter_version,
            rec.charter_sha256,
            rec.eligible_stake_pages,
            rec.approved_stake_pages,
            rec.rejected_stake_pages,
            rec.last_seen_ts,
            &sig_hex,
        },
    );
}

pub fn loadPeersAlloc(
    allocator: std.mem.Allocator,
) !std.json.Parsed([]const SwarmPeerRecord) {
    const opts = std.json.ParseOptions{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    };
    const T = []const SwarmPeerRecord;
    const raw = common.readBinaryFile(
        sysconfig.SWARM_PEERS_PATH,
        MAX_PEERS_FILE_BYTES,
    ) catch return std.json.parseFromSlice(T, allocator, "[]", opts);
    defer common.unmapBinaryFile(raw);
    return std.json.parseFromSlice(
        T,
        allocator,
        raw,
        opts,
    ) catch std.json.parseFromSlice(T, allocator, "[]", opts);
}

pub fn upsertPeerRecord(
    allocator: std.mem.Allocator,
    new_rec: SwarmPeerRecord,
) !void {
    const parsed = try loadPeersAlloc(allocator);
    defer parsed.deinit();

    var list: std.ArrayList(SwarmPeerRecord) = .empty;
    defer list.deinit(allocator);
    var replaced = false;
    for (parsed.value) |old| {
        if (std.mem.eql(u8, old.node_pubkey, new_rec.node_pubkey)) {
            if (!replaced) {
                try list.append(allocator, new_rec);
                replaced = true;
            }
        } else if (list.items.len < MAX_SWARM_PEERS) {
            try list.append(allocator, old);
        }
    }
    if (!replaced and list.items.len < MAX_SWARM_PEERS) {
        try list.append(allocator, new_rec);
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.append(allocator, '[');
    for (list.items, 0..) |r, idx| {
        if (idx > 0) try out.append(allocator, ',');
        const ep_e = try common.escapeJsonAlloc(allocator, r.endpoint);
        defer allocator.free(ep_e);
        const item = try allocator.print(
            "{{\"node_pubkey\":\"{s}\",\"endpoint\":\"{s}\"," ++
                "\"principal_pubkey\":\"{s}\",\"charter_version\":{d}," ++
                "\"charter_sha256\":\"{s}\",\"eligible_stake_pages\":{d}," ++
                "\"approved_stake_pages\":{d},\"rejected_stake_pages\":{d}," ++
                "\"last_seen_ts\":{d},\"signature\":\"{s}\"}}",
            .{
                r.node_pubkey,
                ep_e,
                r.principal_pubkey,
                r.charter_version,
                r.charter_sha256,
                r.eligible_stake_pages,
                r.approved_stake_pages,
                r.rejected_stake_pages,
                r.last_seen_ts,
                r.signature,
            },
        );
        defer allocator.free(item);
        try out.appendSlice(allocator, item);
    }
    try out.append(allocator, ']');
    net_http.ensureParentDir(sysconfig.SWARM_PEERS_PATH);
    try common.writeFile(sysconfig.SWARM_PEERS_PATH, out.items);
}

/// Deterministically compute this host's shard count of `total_target` across
/// active fleet peers sorted lexicographically by node Ed25519 public key.
pub fn computeLocalUnitTarget(
    allocator: std.mem.Allocator,
    self_pubkey_hex: []const u8,
    total_target: u16,
    now_ts: i64,
) u16 {
    const parsed = loadPeersAlloc(allocator) catch return total_target;
    defer parsed.deinit();

    var rank: usize = 0;
    var hosts: usize = 1;
    for (parsed.value) |p| {
        if (std.mem.eql(u8, p.node_pubkey, self_pubkey_hex)) continue;
        if (now_ts - p.last_seen_ts > PEER_STALE_WINDOW_SEC) continue;
        hosts += 1;
        if (std.mem.order(u8, p.node_pubkey, self_pubkey_hex) == .lt) {
            rank += 1;
        }
    }
    const base = total_target / @as(u16, @intCast(hosts));
    const rem = total_target % @as(u16, @intCast(hosts));
    return base + @as(u16, @intFromBool(rank < rem));
}

pub fn aggregateFleetTally(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    self_pubkey_hex: []const u8,
    proposal_hash: ?[32]u8,
) FleetTally {
    var tally = FleetTally{};
    if (client.getMission(proposal_hash)) |m| {
        tally.eligible_stake_pages +|= m.eligible_stake_pages;
        tally.approved_stake_pages +|= m.approved_stake_pages;
        tally.rejected_stake_pages +|= m.rejected_stake_pages;
    } else |_| {}

    const parsed = loadPeersAlloc(allocator) catch return tally;
    defer parsed.deinit();
    const now = nowUnixSec();
    for (parsed.value) |p| {
        if (std.mem.eql(u8, p.node_pubkey, self_pubkey_hex)) continue;
        if (now - p.last_seen_ts > PEER_STALE_WINDOW_SEC) continue;
        tally.live_hosts += 1;
        tally.eligible_stake_pages +|= p.eligible_stake_pages;
        tally.approved_stake_pages +|= p.approved_stake_pages;
        tally.rejected_stake_pages +|= p.rejected_stake_pages;
    }
    return tally;
}

test "swarm/protocol: signs peer record and shards workload deterministically" {
    std.testing.refAllDecls(@This());
    const t = std.testing;
    const seed: [Ed25519.KeyPair.seed_length]u8 = @splat(0x21);
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    var pk_hex: [64]u8 = undefined;
    _ = common.bytesToHex(&kp.public_key.toBytes(), &pk_hex);
    var rec = SwarmPeerRecord{
        .node_pubkey = &pk_hex,
        .endpoint = "10.0.2.11:8486",
        .charter_version = 1,
        .charter_sha256 = "aa",
        .eligible_stake_pages = 64,
        .approved_stake_pages = 64,
        .last_seen_ts = 1000,
    };
    const pre = try buildPeerSignPreimage(t.allocator, &rec);
    defer t.allocator.free(pre);
    const sig = try kp.sign(pre, null);
    var sig_hex: [128]u8 = undefined;
    _ = common.bytesToHex(&sig.toBytes(), &sig_hex);
    rec.signature = &sig_hex;
    try t.expect(verifyPeerSignature(t.allocator, &rec));
    rec.endpoint = "10.0.2.99:8486";
    try t.expect(!verifyPeerSignature(t.allocator, &rec));

    // Verify `.allocate = .alloc_always` outlives freed backing JSON buffers.
    const duped = try t.allocator.dupe(
        u8,
        "[{\"node_pubkey\":\"abcd\",\"endpoint\":\"10.0.2.12:8486\"}]",
    );
    const parsed_ep = try std.json.parseFromSlice(
        []const SwarmPeerRecord,
        t.allocator,
        duped,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    t.allocator.free(duped);
    defer parsed_ep.deinit();
    try t.expectEqualStrings("abcd", parsed_ep.value[0].node_pubkey);
}
