// Parent Message Board Policy Parsing, Persistence & Per-CID Rate Limiter.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const common = @import("../../common.zig");
const net_http = @import("../../net/http.zig");

pub const SHA256_HEX_LEN: usize = 64;
pub const DEFAULT_MAX_BODY_BYTES: usize = 16384;
const MAX_POLICY_FILE_BYTES: usize = 64 * 1024;
const RATE_WINDOW_SEC: i64 = 60;
const RATE_MAX_POSTS_PER_MIN: u32 = 60;
const MAX_RATE_SLOTS: usize = 64;

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

const RateSlot = struct {
    cid: usize = 0,
    win_start: i64 = 0,
    count: u32 = 0,
};

var rate_slots: [MAX_RATE_SLOTS]RateSlot = @splat(.{});
var rate_next: usize = 0;

pub fn resetRateLimiterForTest() void {
    rate_slots = @splat(.{});
    rate_next = 0;
}

pub fn checkCidRateLimit(cid: usize, now_ts: i64) bool {
    if (cid < common.CID_FIRST_CHILD) return true;
    const win = @divFloor(now_ts, RATE_WINDOW_SEC);
    for (&rate_slots) |*sl| {
        if (sl.cid == cid) {
            if (sl.win_start != win) {
                sl.win_start = win;
                sl.count = 0;
            }
            if (sl.count >= RATE_MAX_POSTS_PER_MIN) return false;
            sl.count += 1;
            return true;
        }
    }
    rate_slots[rate_next] = .{ .cid = cid, .win_start = win, .count = 1 };
    rate_next = (rate_next + 1) % MAX_RATE_SLOTS;
    return true;
}

test "board/store/policy: topic validation and sliding rate limit" {
    std.testing.refAllDecls(@This());
    const t = std.testing;
    resetRateLimiterForTest();
    try t.expect(isValidTopic("ops.1"));
    try t.expect(!isValidTopic("../bad"));
    var i: usize = 0;
    while (i < RATE_MAX_POSTS_PER_MIN) : (i += 1) {
        try t.expect(checkCidRateLimit(2, 120));
    }
    try t.expect(!checkCidRateLimit(2, 125));
    try t.expect(checkCidRateLimit(2, 180));
}
