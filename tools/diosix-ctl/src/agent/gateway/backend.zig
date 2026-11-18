// Generic Thinking Gateway Backend Dispatch and Client Helper.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../../api.zig");
const cfg_mod = @import("../config.zig");
const common = @import("../../common.zig");
const ledger = @import("../ledger.zig");
const llm = @import("../llm.zig");
const net_http = @import("../../net/http.zig");
const ssh = @import("../../ssh.zig");

const ThinkingLevel = cfg_mod.ThinkingLevel;

pub const InferBackendResult = struct {
    answer: []u8,
    input_tokens: u64,
    output_tokens: u64,

    pub fn deinit(self: *const InferBackendResult, a: std.mem.Allocator) void {
        a.free(self.answer);
    }
};

pub const InferClientResult = struct {
    answer: []u8,
    thinking_used: ThinkingLevel,
    provider: []u8,
    usage: ledger.UsageSummary,

    pub fn deinit(self: *const InferClientResult, a: std.mem.Allocator) void {
        a.free(self.answer);
        a.free(self.provider);
    }
};

const UsageJson = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    total_tokens: u64 = 0,
    cost_micros_usd: u64 = 0,
    remaining_tokens: u64 = 0,
    remaining_cost_micros_usd: u64 = 0,
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
};

const ParentInferRespJson = struct {
    answer: []const u8 = "",
    thinking_used: []const u8 = "low",
    provider: []const u8 = "parent",
    usage: UsageJson = .{},
};

const OpenAiUsageResp = struct {
    usage: UsageJson = .{},
};

pub fn approxTokens(bytes: usize) u64 {
    return @max(@as(u64, 1), (@as(u64, bytes) + 3) / 4);
}

pub fn buildInferRequestJson(
    allocator: std.mem.Allocator,
    system_prompt: []const u8,
    user_prompt: []const u8,
    lvl: ?ThinkingLevel,
    max_out_tokens: u32,
    format: []const u8,
) ![]u8 {
    const s_e = try common.escapeJsonAlloc(allocator, system_prompt);
    defer allocator.free(s_e);
    const p_e = try common.escapeJsonAlloc(allocator, user_prompt);
    defer allocator.free(p_e);
    const f_e = try common.escapeJsonAlloc(
        allocator,
        if (format.len > 0) format else "text",
    );
    defer allocator.free(f_e);
    const t_str = if (lvl) |l| @tagName(l) else "";
    return allocator.print(
        "{{\"system\":\"{s}\",\"prompt\":\"{s}\",\"thinking\":\"{s}\"," ++
            "\"max_output_tokens\":{d},\"format\":\"{s}\"}}",
        .{ s_e, p_e, t_str, max_out_tokens, f_e },
    );
}

pub fn invokeTieredBackend(
    allocator: std.mem.Allocator,
    client: ?*api.DiosixClient,
    cfg: *const cfg_mod.AgentConfig,
    lvl: ThinkingLevel,
    system_prompt: []const u8,
    user_prompt: []const u8,
    max_out_tokens: u32,
    format: []const u8,
) !InferBackendResult {
    const in_est = approxTokens(system_prompt.len + user_prompt.len);
    if (cfg.resolved_provider == .policy) {
        const raw = try llm.evaluatePolicyBrain(
            allocator,
            cfg.tierSpec(lvl).model(),
            user_prompt,
        );
        defer allocator.free(raw);
        const ans = try llm.extractAssistantContentAlloc(allocator, raw);
        return .{
            .answer = ans,
            .input_tokens = in_est,
            .output_tokens = approxTokens(ans.len),
        };
    }

    if (cfg.resolved_provider == .parent) {
        const req_j = try buildInferRequestJson(
            allocator,
            system_prompt,
            user_prompt,
            lvl,
            max_out_tokens,
            format,
        );
        defer allocator.free(req_j);
        var url_p = llm.parseHttpUrl(cfg.endpoint()) orelse
            llm.parseHttpUrl(cfg_mod.DEFAULT_PARENT_INFER_URL).?;
        if (std.mem.endsWith(u8, url_p.path, "/chat/completions")) {
            url_p.path = "/v1/infer";
        }
        const raw = try llm.httpPostJson(allocator, client, url_p, "", req_j);
        defer allocator.free(raw);
        const p = std.json.parseFromSlice(
            ParentInferRespJson,
            allocator,
            raw,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        ) catch return error.UpstreamLlmFailed;
        defer p.deinit();
        const ans = try allocator.dupe(u8, p.value.answer);
        const in_t = if (p.value.usage.input_tokens > 0)
            p.value.usage.input_tokens
        else
            in_est;
        const out_t = if (p.value.usage.output_tokens > 0)
            p.value.usage.output_tokens
        else
            approxTokens(ans.len);
        return .{ .answer = ans, .input_tokens = in_t, .output_tokens = out_t };
    }

    const req_j = try llm.buildChatRequestJsonWithSystem(
        allocator,
        cfg.tierSpec(lvl).model(),
        system_prompt,
        user_prompt,
        max_out_tokens,
    );
    defer allocator.free(req_j);
    const url = cfg.endpoint();
    const raw = blk: {
        const parsed = llm.parseHttpUrl(url) orelse
            break :blk try llm.evaluatePolicyBrain(
                allocator,
                cfg.tierSpec(lvl).model(),
                user_prompt,
            );
        if (!parsed.is_https and
            llm.resolveUrlHostIp(client, parsed.host) != null)
        {
            break :blk try llm.httpPostJson(
                allocator,
                client,
                parsed,
                cfg.apiKey(),
                req_j,
            );
        }
        break :blk try llm.httpsPostJsonViaTool(
            allocator,
            url,
            cfg.apiKey(),
            req_j,
        );
    };
    defer allocator.free(raw);
    const ans = try llm.extractAssistantContentAlloc(allocator, raw);
    var in_t = in_est;
    var out_t = approxTokens(ans.len);
    if (std.json.parseFromSlice(
        OpenAiUsageResp,
        allocator,
        raw,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    )) |up| {
        defer up.deinit();
        if (up.value.usage.prompt_tokens > 0) {
            in_t = up.value.usage.prompt_tokens;
        }
        if (up.value.usage.completion_tokens > 0) {
            out_t = up.value.usage.completion_tokens;
        }
    } else |_| {}
    return .{ .answer = ans, .input_tokens = in_t, .output_tokens = out_t };
}

pub fn formatQuotaViewJsonAlloc(
    allocator: std.mem.Allocator,
    q: ledger.QuotaView,
) ![]u8 {
    return allocator.print(
        "{{\"cid\":{d},\"max_tokens\":{d},\"used_tokens\":{d}," ++
            "\"reserved_tokens\":{d},\"delegated_tokens\":{d}," ++
            "\"remaining_tokens\":{d},\"max_cost_micros\":{d}," ++
            "\"used_cost_micros\":{d},\"reserved_cost_micros\":{d}," ++
            "\"delegated_cost_micros\":{d},\"remaining_cost_micros\":{d}," ++
            "\"max_thinking\":\"{s}\",\"rpm_limit\":{d},\"tpm_limit\":{d}}}\n",
        .{
            q.cid,
            q.max_tokens,
            q.used_tokens,
            q.reserved_tokens,
            q.delegated_tokens,
            q.remaining_tokens,
            q.max_cost_micros,
            q.used_cost_micros,
            q.reserved_cost_micros,
            q.delegated_cost_micros,
            q.remaining_cost_micros,
            @tagName(q.max_thinking),
            q.rpm_limit,
            q.tpm_limit,
        },
    );
}

pub fn queryLocalGatewayOrDirect(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    system_prompt: []const u8,
    user_prompt: []const u8,
    req_thinking: ?ThinkingLevel,
    max_out_tokens: u32,
    format: []const u8,
) !InferClientResult {
    const has_p = net_http.isHasParent(client);
    var cfg = cfg_mod.loadAgentConfig(allocator, has_p);
    defer cfg.deinit();
    const eff_max_out = std.math.clamp(max_out_tokens, 1, 4096);
    const fallback_lvl = req_thinking orelse cfg.default_thinking;

    const req_j = try buildInferRequestJson(
        allocator,
        system_prompt,
        user_prompt,
        req_thinking,
        eff_max_out,
        format,
    );
    defer allocator.free(req_j);

    const lo_ip = ssh.parseIpv4("127.0.0.1") orelse 0;
    if (net_http.httpClientRequest(
        allocator,
        lo_ip,
        cfg.proxy_port,
        "POST",
        "/v1/infer",
        "application/json",
        req_j,
        256 * 1024,
    )) |resp| {
        defer resp.deinit(allocator);
        if (resp.status == 429) {
            if (std.mem.indexOf(u8, resp.body, "rate_limited") != null) {
                return error.RateLimited;
            }
            return error.QuotaExceeded;
        }
        if (resp.status == 403) return error.ThinkingTierDenied;
        if (resp.status >= 400) return error.UpstreamLlmFailed;
        const p = try std.json.parseFromSlice(
            ParentInferRespJson,
            allocator,
            resp.body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
        defer p.deinit();
        const ans = try allocator.dupe(u8, p.value.answer);
        errdefer allocator.free(ans);
        const prov = try allocator.dupe(u8, p.value.provider);
        errdefer allocator.free(prov);
        const rem_c = p.value.usage.remaining_cost_micros_usd;
        return .{
            .answer = ans,
            .thinking_used = cfg_mod.parseThinkingLevel(
                p.value.thinking_used,
            ) orelse fallback_lvl,
            .provider = prov,
            .usage = .{
                .input_tokens = p.value.usage.input_tokens,
                .output_tokens = p.value.usage.output_tokens,
                .total_tokens = p.value.usage.total_tokens,
                .cost_micros_usd = p.value.usage.cost_micros_usd,
                .remaining_tokens = p.value.usage.remaining_tokens,
                .remaining_cost_micros_usd = rem_c,
            },
        };
    } else |err| {
        if (err != error.ConnectFailed) return err;
    }

    const est_in = approxTokens(system_prompt.len + user_prompt.len);
    const res = try ledger.reserveInference(
        allocator,
        client,
        &cfg,
        has_p,
        common.CID_PARENT,
        req_thinking,
        est_in,
        eff_max_out,
        null,
    );
    const back = invokeTieredBackend(
        allocator,
        client,
        &cfg,
        res.thinking,
        system_prompt,
        user_prompt,
        eff_max_out,
        format,
    ) catch |err| {
        ledger.abortInference(allocator, res, null);
        return err;
    };
    errdefer back.deinit(allocator);
    const u = try ledger.settleInference(
        allocator,
        &cfg,
        res,
        back.input_tokens,
        back.output_tokens,
        null,
    );
    const prov = try allocator.dupe(u8, @tagName(cfg.resolved_provider));
    return .{
        .answer = back.answer,
        .thinking_used = res.thinking,
        .provider = prov,
        .usage = u,
    };
}

test "agent/gateway/backend: request and quota formatting" {
    std.testing.refAllDecls(@This());
    const t = std.testing;
    const rj = try buildInferRequestJson(
        t.allocator,
        "sys",
        "hello",
        .medium,
        256,
        "json",
    );
    defer t.allocator.free(rj);
    try t.expect(std.mem.indexOf(u8, rj, "\"thinking\":\"medium\"") != null);
    const qj = try formatQuotaViewJsonAlloc(t.allocator, .{ .cid = 2 });
    defer t.allocator.free(qj);
    try t.expect(std.mem.indexOf(u8, qj, "\"cid\":2") != null);
}
