// Anti-Collusion Parent Message Board Store and SHA-256 Hash Chain.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const common = @import("../common.zig");
const net_http = @import("../net/http.zig");
const sysconfig = @import("../sysconfig.zig");

pub const SHA256_HEX_LEN: usize = 64;
pub const DEFAULT_MAX_BODY_BYTES: usize = 4096;
const MAX_STORE_FILE_BYTES: usize = 16 * 1024 * 1024;
const MAX_POLICY_FILE_BYTES: usize = 64 * 1024;
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

pub const BoardPolicy = struct {
    max_body_bytes: usize = DEFAULT_MAX_BODY_BYTES,
    allow_all_topics: bool = true,
    allowed_topics: std.ArrayList([]const u8) = .empty,
    muted_cids: std.ArrayList(usize) = .empty,

    pub fn deinit(self: *BoardPolicy, allocator: std.mem.Allocator) void {
        for (self.allowed_topics.items) |t| allocator.free(t);
        self.allowed_topics.deinit(allocator);
        self.muted_cids.deinit(allocator);
    }

    pub fn isTopicAllowed(self: *const BoardPolicy, topic: []const u8) bool {
        if (self.allow_all_topics) return true;
        for (self.allowed_topics.items) |t| {
            if (std.mem.eql(u8, t, topic)) return true;
        }
        return false;
    }

    pub fn isCidMuted(self: *const BoardPolicy, cid: usize) bool {
        for (self.muted_cids.items) |m| {
            if (m == cid) return true;
        }
        return false;
    }

    pub fn muteCid(
        self: *BoardPolicy,
        allocator: std.mem.Allocator,
        cid: usize,
    ) !void {
        if (!self.isCidMuted(cid)) try self.muted_cids.append(allocator, cid);
    }

    pub fn unmuteCid(self: *BoardPolicy, cid: usize) void {
        var i: usize = 0;
        while (i < self.muted_cids.items.len) {
            if (self.muted_cids.items[i] == cid) {
                _ = self.muted_cids.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

pub fn isValidTopic(topic: []const u8) bool {
    if (topic.len == 0 or topic.len > 64) return false;
    if (topic[0] == '.' or topic[0] == '-') return false;
    for (topic) |c| {
        const ok = std.ascii.isAlphanumeric(c) or
            c == '.' or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

const PolicyKey = enum { max_body_bytes, allowed_topics, muted_cids };

pub fn loadPolicy(
    allocator: std.mem.Allocator,
    policy_path: []const u8,
) !BoardPolicy {
    var pol = BoardPolicy{};
    errdefer pol.deinit(allocator);
    const raw = common.readBinaryFile(policy_path, MAX_POLICY_FILE_BYTES) catch
        return pol;
    defer common.unmapBinaryFile(raw);

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |raw_line| {
        const line = common.trimWhitespace(raw_line);
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = common.trimWhitespace(line[0..eq]);
        const v = common.unquoteToml(line[eq + 1 ..]);
        const pk = std.meta.stringToEnum(PolicyKey, k) orelse continue;
        switch (pk) {
            .max_body_bytes => {
                const n = std.fmt.parseInt(usize, v, 10) catch
                    DEFAULT_MAX_BODY_BYTES;
                if (n >= 64 and n <= 65536) pol.max_body_bytes = n;
            },
            .allowed_topics => {
                for (pol.allowed_topics.items) |t| allocator.free(t);
                pol.allowed_topics.clearRetainingCapacity();
                if (std.mem.eql(u8, v, "*")) {
                    pol.allow_all_topics = true;
                } else {
                    pol.allow_all_topics = false;
                    var it = std.mem.splitScalar(u8, v, ',');
                    while (it.next()) |raw_t| {
                        const t = common.trimWhitespace(raw_t);
                        if (isValidTopic(t)) {
                            try pol.allowed_topics.append(
                                allocator,
                                try allocator.dupe(u8, t),
                            );
                        }
                    }
                }
            },
            .muted_cids => {
                pol.muted_cids.clearRetainingCapacity();
                var it = std.mem.splitScalar(u8, v, ',');
                while (it.next()) |raw_c| {
                    const cs = common.trimWhitespace(raw_c);
                    if (cs.len == 0) continue;
                    const c = std.fmt.parseInt(usize, cs, 10) catch continue;
                    try pol.muteCid(allocator, c);
                }
            },
        }
    }
    return pol;
}

pub fn savePolicy(
    allocator: std.mem.Allocator,
    policy_path: []const u8,
    pol: *const BoardPolicy,
) !void {
    net_http.ensureParentDir(policy_path);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const hdr = try allocator.print("max_body_bytes = {d}\n", .{
        pol.max_body_bytes,
    });
    defer allocator.free(hdr);
    try out.appendSlice(allocator, hdr);

    if (pol.allow_all_topics) {
        try out.appendSlice(allocator, "allowed_topics = \"*\"\n");
    } else {
        try out.appendSlice(allocator, "allowed_topics = \"");
        for (pol.allowed_topics.items, 0..) |t, i| {
            if (i > 0) try out.append(allocator, ',');
            try out.appendSlice(allocator, t);
        }
        try out.appendSlice(allocator, "\"\n");
    }
    try out.appendSlice(allocator, "muted_cids = \"");
    for (pol.muted_cids.items, 0..) |c, i| {
        const s = try allocator.print("{s}{d}", .{
            if (i > 0) "," else "",
            c,
        });
        defer allocator.free(s);
        try out.appendSlice(allocator, s);
    }
    try out.appendSlice(allocator, "\"\n");
    try common.writePrivateFile(policy_path, out.items);
}

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
        if (rec.seq != expected_seq or
            rec.prev_hash.len != SHA256_HEX_LEN or
            rec.hash.len != SHA256_HEX_LEN or
            !std.mem.eql(u8, rec.prev_hash, &expected_prev))
        {
            res.chain_valid = false;
            return res;
        }
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

    var st = try loadStore(allocator, store_path);
    defer st.deinit(allocator);
    if (!st.chain_valid) return error.ChainCorrupted;

    const next_seq: u64 = @intCast(st.entries.items.len + 1);
    var tv: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &tv);
    const ts: i64 = @intCast(tv.sec);
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
    var z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const z_path = common.toPathZ(store_path, &z_buf) orelse
        return error.PathTooLong;
    try common.appendFileLine(z_path.ptr, json_line);
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
    std.testing.refAllDecls(@This());
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
