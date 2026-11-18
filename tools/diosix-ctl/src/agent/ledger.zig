// Conserved Token, Micro-USD Cost, Thinking Tier, and Rate Enforcement.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("../api.zig");
const cfg_mod = @import("config.zig");
const common = @import("../common.zig");
pub const store = @import("ledger/store.zig");

const ThinkingLevel = cfg_mod.ThinkingLevel;
pub const ChildQuotaEntry = store.ChildQuotaEntry;
pub const LedgerState = store.LedgerState;
pub const Reservation = store.Reservation;
pub const UsageSummary = store.UsageSummary;
pub const QuotaView = store.QuotaView;
pub const ParsedAmount = store.ParsedAmount;
pub const ChildGrantReq = store.ChildGrantReq;
pub const ManagedLedger = store.ManagedLedger;
pub const nowUnixSec = store.nowUnixSec;
pub const parseTokenAmount = store.parseTokenAmount;
pub const parseUsdToMicros = store.parseUsdToMicros;
pub const resetChildQuota = store.resetChildQuota;
pub const queryQuotaView = store.queryQuotaView;

fn checkAndBumpWindow(
    w_min: *i64,
    w_reqs: *u32,
    w_tok: *u64,
    cur_min: i64,
    rpm: u32,
    tpm: u32,
    res_tok: u64,
) !void {
    if (w_min.* != cur_min) {
        w_min.* = cur_min;
        w_reqs.* = 0;
        w_tok.* = 0;
    }
    if (rpm > 0 and w_reqs.* >= rpm) return error.RateLimited;
    if (tpm > 0 and w_tok.* +| res_tok > tpm) return error.RateLimited;
    w_reqs.* += 1;
    w_tok.* +|= res_tok;
}

pub fn resolveTier(
    requested: ?ThinkingLevel,
    max_allowed: ThinkingLevel,
    default_lvl: ThinkingLevel,
) !ThinkingLevel {
    if (requested) |req| {
        if (@backingInt(req) > @backingInt(max_allowed)) {
            return error.ThinkingTierDenied;
        }
        return req;
    }
    const clamped: u8 = @min(
        @backingInt(default_lvl),
        @backingInt(max_allowed),
    );
    return @fromBackingInt(@intCast(clamped));
}

pub fn reserveInference(
    allocator: std.mem.Allocator,
    client: ?*api.DiosixClient,
    cfg: *const cfg_mod.AgentConfig,
    has_parent: bool,
    caller_cid: usize,
    req_thinking: ?ThinkingLevel,
    est_in_tok: u64,
    max_out_tok: u32,
    custom_path: ?[]const u8,
) !Reservation {
    var ml = try store.readManagedLedger(allocator, custom_path);
    defer ml.deinit(allocator);
    try store.syncNodeCeiling(allocator, &ml, client, cfg, has_parent);

    const now_sec = nowUnixSec();
    const cur_min = @divFloor(now_sec, 60);
    ml.recoverStale(now_sec);

    const res_tok = est_in_tok +| @as(u64, max_out_tok);
    const node_max_lvl =
        cfg_mod.parseThinkingLevel(ml.state.self_max_thinking) orelse .low;

    if (caller_cid == common.CID_PARENT) {
        const eff_lvl = try resolveTier(
            req_thinking,
            node_max_lvl,
            cfg.default_thinking,
        );
        const res_cost = cfg.computeCostMicros(
            eff_lvl,
            est_in_tok,
            max_out_tok,
        );
        const kids = ml.sumOtherChildren(0);
        const used_tok = ml.state.self_used_tokens +|
            ml.state.self_reserved_tokens +| kids.tok;
        const used_cost = ml.state.self_used_cost_micros +|
            ml.state.self_reserved_cost_micros +| kids.cost;
        if (ml.state.self_max_tokens == 0 or
            used_tok +| res_tok > ml.state.self_max_tokens or
            ml.state.self_max_cost_micros == 0 or
            used_cost +| res_cost > ml.state.self_max_cost_micros)
        {
            return error.QuotaExceeded;
        }
        try checkAndBumpWindow(
            &ml.state.window_min,
            &ml.state.window_reqs,
            &ml.state.window_tokens,
            cur_min,
            ml.state.rpm_limit,
            ml.state.tpm_limit,
            res_tok,
        );
        ml.state.self_reserved_tokens +|= res_tok;
        ml.state.self_reserved_cost_micros +|= res_cost;
        ml.state.last_reserve_sec = now_sec;
        try store.writeManagedLedger(allocator, &ml, custom_path);
        return .{
            .caller_cid = caller_cid,
            .thinking = eff_lvl,
            .reserved_tokens = res_tok,
            .reserved_cost_micros = res_cost,
            .window_min = cur_min,
        };
    }

    const c = ml.findChildMut(caller_cid) orelse return error.QuotaExceeded;
    if (c.max_tokens == 0 or c.max_cost_micros == 0) return error.QuotaExceeded;

    const c_max_lvl = cfg_mod.parseThinkingLevel(c.max_thinking) orelse .low;
    const bound_lvl: ThinkingLevel = @fromBackingInt(@intCast(
        @min(@backingInt(c_max_lvl), @backingInt(node_max_lvl)),
    ));
    const eff_lvl = try resolveTier(
        req_thinking,
        bound_lvl,
        cfg.default_thinking,
    );
    const res_cost = cfg.computeCostMicros(eff_lvl, est_in_tok, max_out_tok);
    if (c.used_tokens +| c.reserved_tokens +| res_tok > c.max_tokens or
        c.used_cost_micros +| c.reserved_cost_micros +| res_cost >
            c.max_cost_micros)
    {
        return error.QuotaExceeded;
    }
    try checkAndBumpWindow(
        &c.window_min,
        &c.window_reqs,
        &c.window_tokens,
        cur_min,
        c.rpm_limit,
        c.tpm_limit,
        res_tok,
    );
    try checkAndBumpWindow(
        &ml.state.window_min,
        &ml.state.window_reqs,
        &ml.state.window_tokens,
        cur_min,
        ml.state.rpm_limit,
        ml.state.tpm_limit,
        res_tok,
    );
    c.reserved_tokens +|= res_tok;
    c.reserved_cost_micros +|= res_cost;
    c.last_reserve_sec = now_sec;
    try store.writeManagedLedger(allocator, &ml, custom_path);
    return .{
        .caller_cid = caller_cid,
        .thinking = eff_lvl,
        .reserved_tokens = res_tok,
        .reserved_cost_micros = res_cost,
        .window_min = cur_min,
    };
}

pub fn settleInference(
    allocator: std.mem.Allocator,
    cfg: *const cfg_mod.AgentConfig,
    res: Reservation,
    actual_in_tok: u64,
    actual_out_tok: u64,
    custom_path: ?[]const u8,
) !UsageSummary {
    var ml = try store.readManagedLedger(allocator, custom_path);
    defer ml.deinit(allocator);

    const actual_tok = actual_in_tok +| actual_out_tok;
    const actual_cost = cfg.computeCostMicros(
        res.thinking,
        actual_in_tok,
        actual_out_tok,
    );

    if (res.caller_cid == common.CID_PARENT) {
        ml.state.self_reserved_tokens -|= res.reserved_tokens;
        ml.state.self_reserved_cost_micros -|= res.reserved_cost_micros;
        ml.state.self_used_tokens +|= actual_tok;
        ml.state.self_used_cost_micros +|= actual_cost;
        if (ml.state.window_min == res.window_min and
            res.reserved_tokens > actual_tok)
        {
            ml.state.window_tokens -|= (res.reserved_tokens - actual_tok);
        }
        try store.writeManagedLedger(allocator, &ml, custom_path);
        const kids = ml.sumOtherChildren(0);
        return .{
            .input_tokens = actual_in_tok,
            .output_tokens = actual_out_tok,
            .total_tokens = actual_tok,
            .cost_micros_usd = actual_cost,
            .remaining_tokens = ml.state.self_max_tokens -|
                (ml.state.self_used_tokens +| ml.state.self_reserved_tokens +|
                    kids.tok),
            .remaining_cost_micros_usd = ml.state.self_max_cost_micros -|
                (ml.state.self_used_cost_micros +|
                    ml.state.self_reserved_cost_micros +| kids.cost),
        };
    }

    const c = ml.findChildMut(res.caller_cid) orelse
        return error.ChildNotFound;
    c.reserved_tokens -|= res.reserved_tokens;
    c.reserved_cost_micros -|= res.reserved_cost_micros;
    c.used_tokens +|= actual_tok;
    c.used_cost_micros +|= actual_cost;
    if (c.window_min == res.window_min and res.reserved_tokens > actual_tok) {
        c.window_tokens -|= (res.reserved_tokens - actual_tok);
    }
    if (ml.state.window_min == res.window_min and
        res.reserved_tokens > actual_tok)
    {
        ml.state.window_tokens -|= (res.reserved_tokens - actual_tok);
    }
    try store.writeManagedLedger(allocator, &ml, custom_path);
    return .{
        .input_tokens = actual_in_tok,
        .output_tokens = actual_out_tok,
        .total_tokens = actual_tok,
        .cost_micros_usd = actual_cost,
        .remaining_tokens = c.max_tokens -|
            (c.used_tokens +| c.reserved_tokens),
        .remaining_cost_micros_usd = c.max_cost_micros -|
            (c.used_cost_micros +| c.reserved_cost_micros),
    };
}

pub fn abortInference(
    allocator: std.mem.Allocator,
    res: Reservation,
    custom_path: ?[]const u8,
) void {
    var ml = store.readManagedLedger(allocator, custom_path) catch return;
    defer ml.deinit(allocator);
    if (res.caller_cid == common.CID_PARENT) {
        ml.state.self_reserved_tokens -|= res.reserved_tokens;
        ml.state.self_reserved_cost_micros -|= res.reserved_cost_micros;
    } else if (ml.findChildMut(res.caller_cid)) |c| {
        c.reserved_tokens -|= res.reserved_tokens;
        c.reserved_cost_micros -|= res.reserved_cost_micros;
    }
    store.writeManagedLedger(allocator, &ml, custom_path) catch {};
}

pub fn grantChildQuota(
    allocator: std.mem.Allocator,
    client: ?*api.DiosixClient,
    cfg: *const cfg_mod.AgentConfig,
    has_parent: bool,
    target_cid: usize,
    req: ChildGrantReq,
    custom_path: ?[]const u8,
) !ChildQuotaEntry {
    if (target_cid < common.CID_FIRST_CHILD) return error.InvalidChildCid;
    var ml = try store.readManagedLedger(allocator, custom_path);
    defer ml.deinit(allocator);
    try store.syncNodeCeiling(allocator, &ml, client, cfg, has_parent);

    const node_lvl =
        cfg_mod.parseThinkingLevel(ml.state.self_max_thinking) orelse .low;
    if (req.max_thinking) |mt| {
        if (@backingInt(mt) > @backingInt(node_lvl)) {
            return error.ThinkingTierDenied;
        }
    }

    const other = ml.sumOtherChildren(target_cid);
    const avail_tok = ml.state.self_max_tokens -|
        (ml.state.self_used_tokens +| ml.state.self_reserved_tokens +|
            other.tok);
    const avail_cost = ml.state.self_max_cost_micros -|
        (ml.state.self_used_cost_micros +|
            ml.state.self_reserved_cost_micros +| other.cost);

    const entry: *ChildQuotaEntry = if (ml.findChildMut(target_cid)) |ex|
        ex
    else blk: {
        try ml.children_list.append(allocator, .{ .cid = target_cid });
        break :blk &ml.children_list.items[ml.children_list.items.len - 1];
    };

    const new_tok = if (req.tokens) |t|
        (if (t.is_delta) entry.max_tokens +| t.value else t.value)
    else
        entry.max_tokens;
    const new_cost = if (req.cost_micros) |c|
        (if (c.is_delta) entry.max_cost_micros +| c.value else c.value)
    else
        entry.max_cost_micros;

    if (new_tok > avail_tok or new_cost > avail_cost) {
        return error.QuotaExceeded;
    }
    if (new_tok < entry.used_tokens +| entry.reserved_tokens or
        new_cost < entry.used_cost_micros +| entry.reserved_cost_micros)
    {
        return error.QuotaBelowUsed;
    }

    entry.max_tokens = new_tok;
    entry.max_cost_micros = new_cost;
    if (req.max_thinking) |mt| {
        entry.max_thinking = @tagName(mt);
    } else {
        const cur_lvl =
            cfg_mod.parseThinkingLevel(entry.max_thinking) orelse .low;
        const eff: ThinkingLevel = if (@backingInt(cur_lvl) >
            @backingInt(node_lvl))
            node_lvl
        else
            cur_lvl;
        entry.max_thinking = @tagName(eff);
    }
    if (req.rpm_limit) |r| {
        entry.rpm_limit = if (ml.state.rpm_limit > 0)
            @min(r, ml.state.rpm_limit)
        else
            r;
    }
    if (req.tpm_limit) |t| {
        entry.tpm_limit = if (ml.state.tpm_limit > 0)
            @min(t, ml.state.tpm_limit)
        else
            t;
    }

    try store.writeManagedLedger(allocator, &ml, custom_path);
    return entry.*;
}

test "agent/ledger: conservation, zero default, reserve and settle" {
    _ = store;
    std.testing.refAllDecls(@This());
    const t = std.testing;
    const alloc = t.allocator;

    const path = ".zig-cache/test-gw-ledger.json";
    var pz: [common.MAX_PATH_LEN]u8 = undefined;
    const pzs = common.toPathZ(path, &pz).?;
    _ = linux.unlink(pzs.ptr);
    defer _ = linux.unlink(pzs.ptr);

    var cfg = cfg_mod.AgentConfig.initDefaults();
    defer cfg.deinit();
    cfg.root_token_budget = 5000;
    cfg.root_cost_budget_micros = 100_000;

    try t.expectError(error.QuotaExceeded, reserveInference(
        alloc,
        null,
        &cfg,
        false,
        2,
        .low,
        10,
        100,
        path,
    ));
    const granted = try grantChildQuota(alloc, null, &cfg, false, 2, .{
        .tokens = .{ .value = 4096 },
        .cost_micros = .{ .value = 50_000 },
        .max_thinking = .low,
    }, path);
    try t.expectEqualStrings("low", granted.max_thinking);
    const granted2 = try grantChildQuota(alloc, null, &cfg, false, 2, .{
        .tokens = .{ .is_delta = true, .value = 0 },
    }, path);
    try t.expectEqualStrings("low", granted2.max_thinking);
    try t.expectError(error.QuotaExceeded, grantChildQuota(
        alloc,
        null,
        &cfg,
        false,
        3,
        .{ .tokens = .{ .value = 1000 }, .cost_micros = .{ .value = 10_000 } },
        path,
    ));
    try t.expectError(error.ThinkingTierDenied, reserveInference(
        alloc,
        null,
        &cfg,
        false,
        2,
        .high,
        10,
        100,
        path,
    ));
    const res = try reserveInference(
        alloc,
        null,
        &cfg,
        false,
        2,
        .low,
        10,
        100,
        path,
    );
    const sum = try settleInference(alloc, &cfg, res, 12, 20, path);
    try t.expectEqual(@as(u64, 32), sum.total_tokens);
    try t.expect(sum.cost_micros_usd > 0);
    try t.expectEqual(@as(u64, 4064), sum.remaining_tokens);

    const res2 = try reserveInference(
        alloc,
        null,
        &cfg,
        false,
        2,
        null,
        10,
        50,
        path,
    );
    abortInference(alloc, res2, path);
    const view = try queryQuotaView(alloc, null, &cfg, false, 2, path);
    try t.expectEqual(@as(u64, 0), view.reserved_tokens);
    try t.expectEqual(@as(u64, 32), view.used_tokens);
}
