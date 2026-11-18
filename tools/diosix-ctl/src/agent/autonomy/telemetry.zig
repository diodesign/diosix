// Closed-Loop Node Telemetry, Completed Task Cursors, and Child Alert Poll.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../../api.zig");
const cfg_mod = @import("../config.zig");
const common = @import("../../common.zig");
const ledger = @import("../ledger.zig");
const net_http = @import("../../net/http.zig");
const registry = @import("../../registry.zig");
const ssh = @import("../../ssh.zig");
const sysconfig = @import("../../sysconfig.zig");

const MAX_DONE_BYTES: usize = 64 * 1024;
const MAX_BOARD_LIST_BYTES: usize = 512 * 1024;
const MAX_OBS_BYTES: usize = 2048;

pub const BoardEntryJson = struct {
    seq: u64 = 0,
    author_cid: usize = 0,
    target_cid: usize = 0,
    topic: []const u8 = "",
    body: []const u8 = "",
};

pub fn hasCompletedSeq(seq: u64, custom_path: ?[]const u8) bool {
    const p = custom_path orelse sysconfig.AGENT_DONE_TASKS_PATH;
    const raw = common.readBinaryFile(p, MAX_DONE_BYTES) catch return false;
    defer common.unmapBinaryFile(raw);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |raw_l| {
        const line = common.trimWhitespace(raw_l);
        if (line.len == 0) continue;
        const parsed = std.fmt.parseInt(u64, line, 10) catch continue;
        if (parsed == seq) return true;
    }
    return false;
}

pub fn recordCompletedSeq(
    allocator: std.mem.Allocator,
    seq: u64,
    custom_path: ?[]const u8,
) void {
    const p = custom_path orelse sysconfig.AGENT_DONE_TASKS_PATH;
    if (hasCompletedSeq(seq, p)) return;
    net_http.ensureParentDir(p);
    const old = common.readBinaryFile(p, MAX_DONE_BYTES) catch null;
    defer if (old) |o| common.unmapBinaryFile(o);
    const prev = if (old) |o|
        (if (o.len > MAX_DONE_BYTES / 2)
            o[o.len - MAX_DONE_BYTES / 2 ..]
        else
            o)
    else
        "";
    const next = allocator.print("{s}{d}\n", .{ prev, seq }) catch return;
    defer allocator.free(next);
    common.writeFile(p, next) catch {};
}

pub fn readLastSeq(custom_path: ?[]const u8) u64 {
    const p = custom_path orelse sysconfig.AGENT_ALERT_SEQ_PATH;
    const raw = common.readBinaryFile(p, 128) catch return 0;
    defer common.unmapBinaryFile(raw);
    return std.fmt.parseInt(u64, common.trimWhitespace(raw), 10) catch 0;
}

pub fn writeLastSeq(
    allocator: std.mem.Allocator,
    seq: u64,
    custom_path: ?[]const u8,
) void {
    const p = custom_path orelse sysconfig.AGENT_ALERT_SEQ_PATH;
    net_http.ensureParentDir(p);
    const body = allocator.print("{d}\n", .{seq}) catch return;
    defer allocator.free(body);
    common.writeFile(p, body) catch {};
}

/// Formats a bounded runtime observation summary (children and quota headroom)
/// to ground closed-loop LLM planning and repair requests.
pub fn collectNodeObservationAlloc(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "obs: children=[");

    if (common.readBinaryFile(
        sysconfig.GUEST_REGISTRY_PATH,
        common.MAX_MANIFEST_SIZE,
    )) |raw| {
        defer common.unmapBinaryFile(raw);
        var iter = registry.GuestRegistryIter.init(raw);
        var first = true;
        while (iter.next()) |e| {
            if (e.cid < common.CID_FIRST_CHILD) continue;
            const live = if (client.getInfo(e.cid)) |_| true else |_| false;
            const st: []const u8 = if (live) "live" else e.status;
            const item = try allocator.print(
                "{s}{s}(cid={d},ip={s},st={s})",
                .{ if (first) "" else ",", e.name, e.cid, e.ip, st },
            );
            defer allocator.free(item);
            if (out.items.len + item.len + 128 > MAX_OBS_BYTES) break;
            try out.appendSlice(allocator, item);
            first = false;
        }
    } else |_| {}

    const has_p = net_http.isHasParent(client);
    var cfg = cfg_mod.loadAgentConfig(allocator, has_p);
    defer cfg.deinit();
    const q = ledger.queryQuotaView(
        allocator,
        client,
        &cfg,
        has_p,
        common.CID_PARENT,
        null,
    ) catch ledger.QuotaView{};
    const tail = try allocator.print(
        "]; rem_tok={d},rem_uusd={d}",
        .{ q.remaining_tokens, q.remaining_cost_micros },
    );
    defer allocator.free(tail);
    if (out.items.len + tail.len <= MAX_OBS_BYTES) {
        try out.appendSlice(allocator, tail);
    }
    return out.toOwnedSlice(allocator);
}

pub fn fetchUnreadChildAlertsAlloc(
    allocator: std.mem.Allocator,
    since_seq: u64,
) !std.json.Parsed([]const BoardEntryJson) {
    const lo = ssh.parseIpv4("127.0.0.1") orelse return error.InvalidAddress;
    const req_path = try allocator.print(
        "/v1/messages?topic=alert&since={d}",
        .{since_seq},
    );
    defer allocator.free(req_path);
    const resp = try net_http.httpClientRequest(
        allocator,
        lo,
        sysconfig.DEFAULT_BOARD_PORT,
        "GET",
        req_path,
        null,
        "",
        MAX_BOARD_LIST_BYTES,
    );
    defer resp.deinit(allocator);
    if (resp.status >= 400) return error.BoardRejected;
    return std.json.parseFromSlice(
        []const BoardEntryJson,
        allocator,
        resp.body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
}

test "agent/autonomy/telemetry: seq cursor and observation formatting" {
    std.testing.refAllDecls(@This());
    const t = std.testing;
    const linux = std.os.linux;
    const seq_p = ".zig-cache/test-alert-seq.txt";
    var pz: [common.MAX_PATH_LEN]u8 = undefined;
    const pzs = common.toPathZ(seq_p, &pz).?;
    _ = linux.unlink(pzs.ptr);
    defer _ = linux.unlink(pzs.ptr);

    try t.expectEqual(@as(u64, 0), readLastSeq(seq_p));
    writeLastSeq(t.allocator, 42, seq_p);
    try t.expectEqual(@as(u64, 42), readLastSeq(seq_p));

    var client = api.DiosixClient{ .dev_fd = null, .open_err = null };
    const obs = try collectNodeObservationAlloc(t.allocator, &client);
    defer t.allocator.free(obs);
    try t.expect(std.mem.startsWith(u8, obs, "obs: children=["));
}
