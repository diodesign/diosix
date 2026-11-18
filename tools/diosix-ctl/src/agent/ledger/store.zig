// Ledger Data Types, JSON Persistence, and Amount Parsers.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("../../api.zig");
const cfg_mod = @import("../config.zig");
const common = @import("../../common.zig");
const net_http = @import("../../net/http.zig");
const sysconfig = @import("../../sysconfig.zig");

const ThinkingLevel = cfg_mod.ThinkingLevel;
const MAX_LEDGER_BYTES: usize = 512 * 1024;
pub const STALE_RESERVE_SEC: i64 = 120;

pub const ChildQuotaEntry = struct {
    cid: usize = 0,
    max_tokens: u64 = 0,
    used_tokens: u64 = 0,
    reserved_tokens: u64 = 0,
    max_cost_micros: u64 = 0,
    used_cost_micros: u64 = 0,
    reserved_cost_micros: u64 = 0,
    max_thinking: []const u8 = "low",
    rpm_limit: u32 = 30,
    tpm_limit: u32 = 60_000,
    window_min: i64 = 0,
    window_reqs: u32 = 0,
    window_tokens: u64 = 0,
    last_reserve_sec: i64 = 0,
};

pub const LedgerState = struct {
    self_max_tokens: u64 = 0,
    self_used_tokens: u64 = 0,
    self_reserved_tokens: u64 = 0,
    self_max_cost_micros: u64 = 0,
    self_used_cost_micros: u64 = 0,
    self_reserved_cost_micros: u64 = 0,
    self_max_thinking: []const u8 = "high",
    rpm_limit: u32 = 60,
    tpm_limit: u32 = 120_000,
    window_min: i64 = 0,
    window_reqs: u32 = 0,
    window_tokens: u64 = 0,
    last_reserve_sec: i64 = 0,
    children: []const ChildQuotaEntry = &.{},
};

pub const Reservation = struct {
    caller_cid: usize,
    thinking: ThinkingLevel,
    reserved_tokens: u64,
    reserved_cost_micros: u64,
    window_min: i64,
};

pub const UsageSummary = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    total_tokens: u64 = 0,
    cost_micros_usd: u64 = 0,
    remaining_tokens: u64 = 0,
    remaining_cost_micros_usd: u64 = 0,
};

pub const QuotaView = struct {
    cid: usize = 0,
    max_tokens: u64 = 0,
    used_tokens: u64 = 0,
    reserved_tokens: u64 = 0,
    delegated_tokens: u64 = 0,
    remaining_tokens: u64 = 0,
    max_cost_micros: u64 = 0,
    used_cost_micros: u64 = 0,
    reserved_cost_micros: u64 = 0,
    delegated_cost_micros: u64 = 0,
    remaining_cost_micros: u64 = 0,
    max_thinking: ThinkingLevel = .low,
    rpm_limit: u32 = 0,
    tpm_limit: u32 = 0,
};

pub const ParsedAmount = struct {
    is_delta: bool = false,
    value: u64 = 0,
};

pub const ChildGrantReq = struct {
    tokens: ?ParsedAmount = null,
    cost_micros: ?ParsedAmount = null,
    max_thinking: ?ThinkingLevel = null,
    rpm_limit: ?u32 = null,
    tpm_limit: ?u32 = null,
};

/// Map a thinking-tier name to a static literal slice, defaulting to "low".
pub fn canonicalThinkingName(str: []const u8) []const u8 {
    const lvl = cfg_mod.parseThinkingLevel(str) orelse .low;
    return @tagName(lvl);
}

pub const ManagedLedger = struct {
    parsed: ?std.json.Parsed(LedgerState) = null,
    state: LedgerState = .{},
    children_list: std.ArrayList(ChildQuotaEntry) = .empty,

    pub fn deinit(self: *ManagedLedger, allocator: std.mem.Allocator) void {
        self.children_list.deinit(allocator);
        if (self.parsed) |p| p.deinit();
    }

    pub fn findChildMut(
        self: *ManagedLedger,
        cid: usize,
    ) ?*ChildQuotaEntry {
        for (self.children_list.items) |*c| {
            if (c.cid == cid) return c;
        }
        return null;
    }

    pub fn findChild(
        self: *const ManagedLedger,
        cid: usize,
    ) ?*const ChildQuotaEntry {
        for (self.children_list.items) |*c| {
            if (c.cid == cid) return c;
        }
        return null;
    }

    pub fn sumOtherChildren(
        self: *const ManagedLedger,
        skip_cid: usize,
    ) struct { tok: u64, cost: u64 } {
        var tok: u64 = 0;
        var cost: u64 = 0;
        for (self.children_list.items) |c| {
            if (c.cid == skip_cid) continue;
            tok +|= c.max_tokens;
            cost +|= c.max_cost_micros;
        }
        return .{ .tok = tok, .cost = cost };
    }

    pub fn recoverStale(self: *ManagedLedger, now_sec: i64) void {
        if (self.state.last_reserve_sec > 0 and
            now_sec - self.state.last_reserve_sec > STALE_RESERVE_SEC)
        {
            self.state.self_reserved_tokens = 0;
            self.state.self_reserved_cost_micros = 0;
        }
        for (self.children_list.items) |*c| {
            if (c.last_reserve_sec > 0 and
                now_sec - c.last_reserve_sec > STALE_RESERVE_SEC)
            {
                c.reserved_tokens = 0;
                c.reserved_cost_micros = 0;
            }
        }
    }
};

pub fn nowUnixSec() i64 {
    var tv: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &tv);
    return @intCast(tv.sec);
}

pub fn parseTokenAmount(str: []const u8) !ParsedAmount {
    var s = common.trimWhitespace(str);
    if (s.len == 0) return error.InvalidAmount;
    var is_delta = false;
    if (s[0] == '+') {
        is_delta = true;
        s = common.trimWhitespace(s[1..]);
    }
    const val = std.fmt.parseInt(u64, s, 10) catch return error.InvalidAmount;
    return .{ .is_delta = is_delta, .value = val };
}

pub fn parseUsdToMicros(str: []const u8) !ParsedAmount {
    var s = common.trimWhitespace(str);
    if (s.len == 0) return error.InvalidAmount;
    var is_delta = false;
    if (s[0] == '+') {
        is_delta = true;
        s = common.trimWhitespace(s[1..]);
    }
    if (s.len == 0) return error.InvalidAmount;
    const dot = std.mem.indexOfScalar(u8, s, '.');
    const whole_s = if (dot) |d| s[0..d] else s;
    const frac_s = if (dot) |d| s[d + 1 ..] else "";
    if (std.mem.indexOfScalar(u8, frac_s, '.') != null or
        (whole_s.len == 0 and frac_s.len == 0) or frac_s.len > 6)
    {
        return error.InvalidAmount;
    }
    const whole: u64 = if (whole_s.len == 0)
        0
    else
        std.fmt.parseInt(u64, whole_s, 10) catch return error.InvalidAmount;
    var frac_micros: u64 = 0;
    var mult: u64 = 100_000;
    for (frac_s) |ch| {
        if (!std.ascii.isDigit(ch)) return error.InvalidAmount;
        frac_micros += @as(u64, ch - '0') * mult;
        mult /= 10;
    }
    const base = std.math.mul(u64, whole, 1_000_000) catch
        return error.InvalidAmount;
    const total = std.math.add(u64, base, frac_micros) catch
        return error.InvalidAmount;
    return .{ .is_delta = is_delta, .value = total };
}

pub fn readManagedLedger(
    allocator: std.mem.Allocator,
    custom_path: ?[]const u8,
) !ManagedLedger {
    var ml = ManagedLedger{};
    errdefer ml.deinit(allocator);
    const raw = blk: {
        if (custom_path) |p| {
            break :blk common.readBinaryFile(p, MAX_LEDGER_BYTES) catch
                return ml;
        }
        break :blk common.readBinaryFile(
            sysconfig.GATEWAY_LEDGER_PATH,
            MAX_LEDGER_BYTES,
        ) catch common.readBinaryFile(
            sysconfig.GATEWAY_LEDGER_RUN_PATH,
            MAX_LEDGER_BYTES,
        ) catch return ml;
    };
    defer common.unmapBinaryFile(raw);
    if (raw.len == 0) return ml;

    const opts = std.json.ParseOptions{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    };
    const parsed = std.json.parseFromSlice(
        LedgerState,
        allocator,
        raw,
        opts,
    ) catch return ml;
    ml.parsed = parsed;
    ml.state = parsed.value;
    ml.state.self_max_thinking =
        canonicalThinkingName(ml.state.self_max_thinking);
    try ml.children_list.appendSlice(allocator, parsed.value.children);
    for (ml.children_list.items) |*c| {
        c.max_thinking = canonicalThinkingName(c.max_thinking);
    }
    return ml;
}

pub fn writeManagedLedger(
    allocator: std.mem.Allocator,
    ml: *const ManagedLedger,
    custom_path: ?[]const u8,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const mt_esc = try common.escapeJsonAlloc(
        allocator,
        ml.state.self_max_thinking,
    );
    defer allocator.free(mt_esc);
    const hdr = try allocator.print(
        "{{\"self_max_tokens\":{d},\"self_used_tokens\":{d}," ++
            "\"self_reserved_tokens\":{d},\"self_max_cost_micros\":{d}," ++
            "\"self_used_cost_micros\":{d}," ++
            "\"self_reserved_cost_micros\":{d}," ++
            "\"self_max_thinking\":\"{s}\",\"rpm_limit\":{d}," ++
            "\"tpm_limit\":{d},\"window_min\":{d},\"window_reqs\":{d}," ++
            "\"window_tokens\":{d},\"last_reserve_sec\":{d},\"children\":[",
        .{
            ml.state.self_max_tokens,
            ml.state.self_used_tokens,
            ml.state.self_reserved_tokens,
            ml.state.self_max_cost_micros,
            ml.state.self_used_cost_micros,
            ml.state.self_reserved_cost_micros,
            mt_esc,
            ml.state.rpm_limit,
            ml.state.tpm_limit,
            ml.state.window_min,
            ml.state.window_reqs,
            ml.state.window_tokens,
            ml.state.last_reserve_sec,
        },
    );
    defer allocator.free(hdr);
    try buf.appendSlice(allocator, hdr);

    for (ml.children_list.items, 0..) |c, idx| {
        if (idx > 0) try buf.append(allocator, ',');
        const ct_esc = try common.escapeJsonAlloc(allocator, c.max_thinking);
        defer allocator.free(ct_esc);
        const item = try allocator.print(
            "{{\"cid\":{d},\"max_tokens\":{d},\"used_tokens\":{d}," ++
                "\"reserved_tokens\":{d},\"max_cost_micros\":{d}," ++
                "\"used_cost_micros\":{d},\"reserved_cost_micros\":{d}," ++
                "\"max_thinking\":\"{s}\",\"rpm_limit\":{d}," ++
                "\"tpm_limit\":{d},\"window_min\":{d},\"window_reqs\":{d}," ++
                "\"window_tokens\":{d},\"last_reserve_sec\":{d}}}",
            .{
                c.cid,
                c.max_tokens,
                c.used_tokens,
                c.reserved_tokens,
                c.max_cost_micros,
                c.used_cost_micros,
                c.reserved_cost_micros,
                ct_esc,
                c.rpm_limit,
                c.tpm_limit,
                c.window_min,
                c.window_reqs,
                c.window_tokens,
                c.last_reserve_sec,
            },
        );
        defer allocator.free(item);
        try buf.appendSlice(allocator, item);
    }
    try buf.appendSlice(allocator, "]}\n");

    if (custom_path) |p| {
        net_http.ensureParentDir(p);
        try common.writePrivateFile(p, buf.items);
        return;
    }
    net_http.ensureParentDir(sysconfig.GATEWAY_LEDGER_PATH);
    common.writePrivateFile(sysconfig.GATEWAY_LEDGER_PATH, buf.items) catch {
        net_http.ensureParentDir(sysconfig.GATEWAY_LEDGER_RUN_PATH);
        try common.writePrivateFile(
            sysconfig.GATEWAY_LEDGER_RUN_PATH,
            buf.items,
        );
    };
}

fn parseManifestDirective(line: []const u8, pfx: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, pfx)) return null;
    return common.trimWhitespace(line[pfx.len..]);
}

pub fn syncNodeCeiling(
    allocator: std.mem.Allocator,
    ml: *ManagedLedger,
    client: ?*api.DiosixClient,
    cfg: *const cfg_mod.AgentConfig,
    has_parent: bool,
) !void {
    if (!has_parent) {
        if (ml.state.self_max_tokens == 0 and cfg.root_token_budget > 0) {
            ml.state.self_max_tokens = cfg.root_token_budget;
        }
        if (ml.state.self_max_cost_micros == 0 and
            cfg.root_cost_budget_micros > 0)
        {
            ml.state.self_max_cost_micros = cfg.root_cost_budget_micros;
        }
        if (ml.state.rpm_limit == 0) ml.state.rpm_limit = cfg.requests_per_min;
        if (ml.state.tpm_limit == 0) ml.state.tpm_limit = cfg.tokens_per_min;
        return;
    }

    const cl = client orelse return;
    const mbuf = allocator.alloc(u8, common.MAX_MANIFEST_SIZE) catch return;
    defer allocator.free(mbuf);
    const mlen = cl.getManifest(common.CID_SELF, mbuf) catch return;
    var lines = std.mem.splitScalar(u8, mbuf[0..mlen], '\n');
    while (lines.next()) |raw| {
        const line = common.trimWhitespace(raw);
        if (parseManifestDirective(line, "# diosix-llm-max-tokens:")) |v| {
            ml.state.self_max_tokens = std.fmt.parseInt(u64, v, 10) catch
                ml.state.self_max_tokens;
        } else if (parseManifestDirective(
            line,
            "# diosix-llm-max-cost-micros:",
        )) |v| {
            ml.state.self_max_cost_micros = std.fmt.parseInt(u64, v, 10) catch
                ml.state.self_max_cost_micros;
        } else if (parseManifestDirective(
            line,
            "# diosix-llm-max-thinking:",
        )) |v| {
            if (cfg_mod.parseThinkingLevel(v) != null) {
                ml.state.self_max_thinking = canonicalThinkingName(v);
            }
        } else if (parseManifestDirective(line, "# diosix-llm-rpm:")) |v| {
            ml.state.rpm_limit = std.fmt.parseInt(u32, v, 10) catch
                ml.state.rpm_limit;
        } else if (parseManifestDirective(line, "# diosix-llm-tpm:")) |v| {
            ml.state.tpm_limit = std.fmt.parseInt(u32, v, 10) catch
                ml.state.tpm_limit;
        }
    }
}

pub fn resetChildQuota(
    allocator: std.mem.Allocator,
    target_cid: usize,
    custom_path: ?[]const u8,
) void {
    if (target_cid < common.CID_FIRST_CHILD) return;
    var ml = readManagedLedger(allocator, custom_path) catch return;
    defer ml.deinit(allocator);
    if (ml.findChildMut(target_cid)) |c| {
        c.* = .{ .cid = target_cid };
        writeManagedLedger(allocator, &ml, custom_path) catch {};
    }
}

pub fn queryQuotaView(
    allocator: std.mem.Allocator,
    client: ?*api.DiosixClient,
    cfg: *const cfg_mod.AgentConfig,
    has_parent: bool,
    cid: usize,
    custom_path: ?[]const u8,
) !QuotaView {
    var ml = try readManagedLedger(allocator, custom_path);
    defer ml.deinit(allocator);
    try syncNodeCeiling(allocator, &ml, client, cfg, has_parent);

    if (cid == common.CID_PARENT or cid == common.CID_SELF) {
        const kids = ml.sumOtherChildren(0);
        return .{
            .cid = 0,
            .max_tokens = ml.state.self_max_tokens,
            .used_tokens = ml.state.self_used_tokens,
            .reserved_tokens = ml.state.self_reserved_tokens,
            .delegated_tokens = kids.tok,
            .remaining_tokens = ml.state.self_max_tokens -|
                (ml.state.self_used_tokens +| ml.state.self_reserved_tokens +|
                    kids.tok),
            .max_cost_micros = ml.state.self_max_cost_micros,
            .used_cost_micros = ml.state.self_used_cost_micros,
            .reserved_cost_micros = ml.state.self_reserved_cost_micros,
            .delegated_cost_micros = kids.cost,
            .remaining_cost_micros = ml.state.self_max_cost_micros -|
                (ml.state.self_used_cost_micros +|
                    ml.state.self_reserved_cost_micros +| kids.cost),
            .max_thinking = cfg_mod.parseThinkingLevel(
                ml.state.self_max_thinking,
            ) orelse .low,
            .rpm_limit = ml.state.rpm_limit,
            .tpm_limit = ml.state.tpm_limit,
        };
    }

    const c = ml.findChild(cid) orelse return .{ .cid = cid };
    return .{
        .cid = cid,
        .max_tokens = c.max_tokens,
        .used_tokens = c.used_tokens,
        .reserved_tokens = c.reserved_tokens,
        .remaining_tokens = c.max_tokens -|
            (c.used_tokens +| c.reserved_tokens),
        .max_cost_micros = c.max_cost_micros,
        .used_cost_micros = c.used_cost_micros,
        .reserved_cost_micros = c.reserved_cost_micros,
        .remaining_cost_micros = c.max_cost_micros -|
            (c.used_cost_micros +| c.reserved_cost_micros),
        .max_thinking = cfg_mod.parseThinkingLevel(c.max_thinking) orelse .low,
        .rpm_limit = c.rpm_limit,
        .tpm_limit = c.tpm_limit,
    };
}

test "agent/ledger/store: USD parsing" {
    std.testing.refAllDecls(@This());
    const usd1 = try parseUsdToMicros("1.25");
    try std.testing.expect(!usd1.is_delta);
    try std.testing.expectEqual(@as(u64, 1_250_000), usd1.value);
}
