// Anti-Collusion Parent Message Board Store and SHA-256 Hash Chain.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const common = @import("../common.zig");
const net_http = @import("../net/http.zig");
pub const policy = @import("store/policy.zig");

pub const SHA256_HEX_LEN = policy.SHA256_HEX_LEN;
pub const DEFAULT_MAX_BODY_BYTES = policy.DEFAULT_MAX_BODY_BYTES;
pub const BoardPolicy = policy.BoardPolicy;
pub const isValidTopic = policy.isValidTopic;
pub const loadPolicy = policy.loadPolicy;
pub const savePolicy = policy.savePolicy;

const MAX_STORE_FILE_BYTES: usize = 16 * 1024 * 1024;
const MAX_BOARD_ENTRIES: usize = 512;
const COMPACT_KEEP_ENTRIES: usize = 384;
const GENESIS_HASH: [SHA256_HEX_LEN]u8 = @splat('0');

pub const BoardEntry = struct {
    seq: u64,
    ts: i64,
    author_cid: usize,
    target_cid: usize,
    topic: []const u8,
    prev_hash: [SHA256_HEX_LEN]u8,
    hash: [SHA256_HEX_LEN]u8,
    body: []const u8,
};

pub const PostReceipt = struct {
    seq: u64,
    ts: i64,
    author_cid: usize,
    target_cid: usize,
    hash: [SHA256_HEX_LEN]u8,
};

pub const StoreResult = struct {
    entries: std.ArrayList(BoardEntry) = .empty,
    chain_valid: bool = true,
    head_hash: [SHA256_HEX_LEN]u8 = GENESIS_HASH,

    pub fn deinit(self: *StoreResult, allocator: std.mem.Allocator) void {
        for (self.entries.items) |e| {
            allocator.free(e.topic);
            allocator.free(e.body);
        }
        self.entries.deinit(allocator);
    }
};

fn computeEntryHash(
    allocator: std.mem.Allocator,
    seq: u64,
    ts: i64,
    author_cid: usize,
    target_cid: usize,
    topic: []const u8,
    prev_hash: *const [SHA256_HEX_LEN]u8,
    body: []const u8,
    out_hash: *[SHA256_HEX_LEN]u8,
) !void {
    const canon = try allocator.print(
        "{d}:{d}:{d}:{d}:{s}:{s}:{s}",
        .{ seq, ts, author_cid, target_cid, topic, prev_hash.*, body },
    );
    defer allocator.free(canon);
    _ = common.sha256Hex(canon, out_hash);
}

const JsonEntry = struct {
    seq: u64,
    ts: i64,
    author_cid: usize,
    target_cid: usize,
    topic: []const u8,
    prev_hash: []const u8,
    hash: []const u8,
    body: []const u8,
};

pub fn loadStore(
    allocator: std.mem.Allocator,
    store_path: []const u8,
) !StoreResult {
    var res = StoreResult{};
    errdefer res.deinit(allocator);
    const raw = common.readBinaryFile(store_path, MAX_STORE_FILE_BYTES) catch
        return res;
    defer common.unmapBinaryFile(raw);

    var expected_seq: u64 = 1;
    var expected_prev = GENESIS_HASH;
    var is_first = true;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |raw_line| {
        const line = common.trimWhitespace(raw_line);
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(
            JsonEntry,
            allocator,
            line,
            .{ .ignore_unknown_fields = true },
        ) catch {
            res.chain_valid = false;
            return res;
        };
        defer parsed.deinit();
        const rec = parsed.value;
        if (rec.prev_hash.len != SHA256_HEX_LEN or
            rec.hash.len != SHA256_HEX_LEN)
        {
            res.chain_valid = false;
            return res;
        }
        if (is_first and rec.seq > 1) {
            expected_seq = rec.seq;
            @memcpy(&expected_prev, rec.prev_hash[0..SHA256_HEX_LEN]);
        } else if (rec.seq != expected_seq or
            !std.mem.eql(u8, rec.prev_hash, &expected_prev))
        {
            res.chain_valid = false;
            return res;
        }
        is_first = false;
        var calc: [SHA256_HEX_LEN]u8 = undefined;
        try computeEntryHash(
            allocator,
            rec.seq,
            rec.ts,
            rec.author_cid,
            rec.target_cid,
            rec.topic,
            &expected_prev,
            rec.body,
            &calc,
        );
        if (!std.mem.eql(u8, rec.hash, &calc)) {
            res.chain_valid = false;
            return res;
        }
        const dup_topic = try allocator.dupe(u8, rec.topic);
        errdefer allocator.free(dup_topic);
        const dup_body = try allocator.dupe(u8, rec.body);
        errdefer allocator.free(dup_body);
        try res.entries.append(allocator, .{
            .seq = rec.seq,
            .ts = rec.ts,
            .author_cid = rec.author_cid,
            .target_cid = rec.target_cid,
            .topic = dup_topic,
            .prev_hash = expected_prev,
            .hash = calc,
            .body = dup_body,
        });
        expected_prev = calc;
        expected_seq += 1;
    }
    res.head_hash = expected_prev;
    return res;
}

fn writeCompactedStore(
    allocator: std.mem.Allocator,
    store_path: []const u8,
    keep_entries: []const BoardEntry,
    new_line: []const u8,
) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (keep_entries) |e| {
        const t_e = try common.escapeJsonAlloc(allocator, e.topic);
        defer allocator.free(t_e);
        const b_e = try common.escapeJsonAlloc(allocator, e.body);
        defer allocator.free(b_e);
        const ln = try allocator.print(
            "{{\"seq\":{d},\"ts\":{d},\"author_cid\":{d}," ++
                "\"target_cid\":{d},\"topic\":\"{s}\"," ++
                "\"prev_hash\":\"{s}\",\"hash\":\"{s}\",\"body\":\"{s}\"}}\n",
            .{
                e.seq,  e.ts, e.author_cid, e.target_cid, t_e, e.prev_hash,
                e.hash, b_e,
            },
        );
        defer allocator.free(ln);
        try out.appendSlice(allocator, ln);
    }
    try out.appendSlice(allocator, new_line);
    try out.append(allocator, '\n');
    try common.writePrivateFile(store_path, out.items);
}

pub fn appendPost(
    allocator: std.mem.Allocator,
    policy_path: []const u8,
    store_path: []const u8,
    author_cid: usize,
    target_cid: usize,
    raw_topic: []const u8,
    body: []const u8,
) !PostReceipt {
    // Anti-collusion invariant: child VMs cannot address other children.
    if (author_cid >= common.CID_FIRST_CHILD and target_cid != 0) {
        return error.LateralMessagingDenied;
    }
    const topic = if (raw_topic.len == 0) "general" else raw_topic;
    if (!isValidTopic(topic)) return error.InvalidTopic;
    if (body.len == 0) return error.EmptyBody;

    var pol = try loadPolicy(allocator, policy_path);
    defer pol.deinit(allocator);
    if (pol.isCidMuted(author_cid)) return error.SenderMuted;
    if (!pol.isTopicAllowed(topic)) return error.TopicNotAllowed;
    if (body.len > pol.max_body_bytes) return error.BodyTooLarge;

    var tv: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &tv);
    const ts: i64 = @intCast(tv.sec);
    if (!policy.checkCidRateLimit(author_cid, ts)) return error.RateLimited;

    var st = try loadStore(allocator, store_path);
    defer st.deinit(allocator);
    if (!st.chain_valid) return error.ChainCorrupted;

    const next_seq: u64 = if (st.entries.items.len > 0)
        st.entries.items[st.entries.items.len - 1].seq + 1
    else
        1;
    var new_hash: [SHA256_HEX_LEN]u8 = undefined;
    try computeEntryHash(
        allocator,
        next_seq,
        ts,
        author_cid,
        target_cid,
        topic,
        &st.head_hash,
        body,
        &new_hash,
    );

    const t_esc = try common.escapeJsonAlloc(allocator, topic);
    defer allocator.free(t_esc);
    const b_esc = try common.escapeJsonAlloc(allocator, body);
    defer allocator.free(b_esc);
    const json_line = try allocator.print(
        "{{\"seq\":{d},\"ts\":{d},\"author_cid\":{d}," ++
            "\"target_cid\":{d},\"topic\":\"{s}\"," ++
            "\"prev_hash\":\"{s}\",\"hash\":\"{s}\",\"body\":\"{s}\"}}",
        .{
            next_seq, ts,    author_cid, target_cid, t_esc, st.head_hash,
            new_hash, b_esc,
        },
    );
    defer allocator.free(json_line);

    net_http.ensureParentDir(store_path);
    if (st.entries.items.len >= MAX_BOARD_ENTRIES) {
        const drop = st.entries.items.len - (COMPACT_KEEP_ENTRIES - 1);
        try writeCompactedStore(
            allocator,
            store_path,
            st.entries.items[drop..],
            json_line,
        );
    } else {
        var z_buf: [common.MAX_PATH_LEN]u8 = undefined;
        const z_path = common.toPathZ(store_path, &z_buf) orelse
            return error.PathTooLong;
        try common.appendFileLine(z_path.ptr, json_line);
    }
    return .{
        .seq = next_seq,
        .ts = ts,
        .author_cid = author_cid,
        .target_cid = target_cid,
        .hash = new_hash,
    };
}

pub fn isEntryVisibleToCaller(
    e: BoardEntry,
    caller_cid: usize,
    topic_filter: ?[]const u8,
    since_seq: u64,
) bool {
    if (e.seq <= since_seq) return false;
    if (topic_filter) |tf| {
        if (tf.len > 0 and !std.mem.eql(u8, e.topic, tf)) return false;
    }
    if (caller_cid >= common.CID_FIRST_CHILD) {
        return e.target_cid == 0 or
            e.target_cid == caller_cid or
            e.author_cid == caller_cid;
    }
    return true;
}

pub fn formatVisibleJson(
    allocator: std.mem.Allocator,
    entries: []const BoardEntry,
    caller_cid: usize,
    topic_filter: ?[]const u8,
    since_seq: u64,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    var first = true;
    for (entries) |e| {
        if (!isEntryVisibleToCaller(e, caller_cid, topic_filter, since_seq)) {
            continue;
        }
        if (!first) try out.append(allocator, ',');
        first = false;
        const t_esc = try common.escapeJsonAlloc(allocator, e.topic);
        defer allocator.free(t_esc);
        const b_esc = try common.escapeJsonAlloc(allocator, e.body);
        defer allocator.free(b_esc);
        const item = try allocator.print(
            "{{\"seq\":{d},\"ts\":{d},\"author_cid\":{d}," ++
                "\"target_cid\":{d},\"topic\":\"{s}\"," ++
                "\"prev_hash\":\"{s}\",\"hash\":\"{s}\",\"body\":\"{s}\"}}",
            .{
                e.seq,  e.ts,  e.author_cid, e.target_cid, t_esc, e.prev_hash,
                e.hash, b_esc,
            },
        );
        defer allocator.free(item);
        try out.appendSlice(allocator, item);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

test "board/store: hash chain, lateral denial, and visibility isolation" {
    _ = policy;
    std.testing.refAllDecls(@This());
    policy.resetRateLimiterForTest();
    const t = std.testing;
    const alloc = t.allocator;
    const p_path = ".zig-cache/test-board-policy.toml";
    const s_path = ".zig-cache/test-board-store.jsonl";
    var pz: [common.MAX_PATH_LEN]u8 = undefined;
    var sz: [common.MAX_PATH_LEN]u8 = undefined;
    const pz_s = common.toPathZ(p_path, &pz).?;
    const sz_s = common.toPathZ(s_path, &sz).?;
    _ = linux.unlink(pz_s.ptr);
    _ = linux.unlink(sz_s.ptr);
    defer {
        _ = linux.unlink(pz_s.ptr);
        _ = linux.unlink(sz_s.ptr);
    }

    // Child-to-child DM is unconditionally blocked.
    try t.expectError(
        error.LateralMessagingDenied,
        appendPost(alloc, p_path, s_path, 2, 3, "ops", "collude"),
    );
    try t.expectError(
        error.LateralMessagingDenied,
        appendPost(alloc, p_path, s_path, 2, 2, "ops", "loopback"),
    );

    const r1 = try appendPost(alloc, p_path, s_path, 2, 0, "ops", "ready");
    try t.expectEqual(@as(u64, 1), r1.seq);
    const r2 = try appendPost(alloc, p_path, s_path, 0, 2, "cmd", "secret-2");
    try t.expectEqual(@as(u64, 2), r2.seq);

    var st = try loadStore(alloc, s_path);
    defer st.deinit(alloc);
    try t.expect(st.chain_valid);
    try t.expectEqual(@as(usize, 2), st.entries.items.len);
    try t.expectEqualStrings(&r1.hash, &st.entries.items[1].prev_hash);

    const vis2 = try formatVisibleJson(alloc, st.entries.items, 2, null, 0);
    defer alloc.free(vis2);
    try t.expect(std.mem.indexOf(u8, vis2, "secret-2") != null);

    const vis3 = try formatVisibleJson(alloc, st.entries.items, 3, null, 0);
    defer alloc.free(vis3);
    try t.expect(std.mem.indexOf(u8, vis3, "ready") != null);
    try t.expect(std.mem.indexOf(u8, vis3, "secret-2") == null);

    var pol = BoardPolicy{};
    defer pol.deinit(alloc);
    pol.allow_all_topics = false;
    try pol.allowed_topics.append(alloc, try alloc.dupe(u8, "ops"));
    try pol.muteCid(alloc, 4);
    try savePolicy(alloc, p_path, &pol);

    try t.expectError(
        error.SenderMuted,
        appendPost(alloc, p_path, s_path, 4, 0, "ops", "hi"),
    );
    try t.expectError(
        error.TopicNotAllowed,
        appendPost(alloc, p_path, s_path, 2, 0, "chat", "hi"),
    );
}
