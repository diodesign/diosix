// Generic Thinking Gateway Server Handlers (/v1/infer, /v1/quota).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../api.zig");
const cfg_mod = @import("config.zig");
const common = @import("../common.zig");
const ledger = @import("ledger.zig");
const net_http = @import("../net/http.zig");
pub const backend = @import("gateway/backend.zig");

const ThinkingLevel = cfg_mod.ThinkingLevel;
pub const InferBackendResult = backend.InferBackendResult;
pub const InferClientResult = backend.InferClientResult;
pub const buildInferRequestJson = backend.buildInferRequestJson;
pub const invokeTieredBackend = backend.invokeTieredBackend;
pub const formatQuotaViewJsonAlloc = backend.formatQuotaViewJsonAlloc;
pub const queryLocalGatewayOrDirect = backend.queryLocalGatewayOrDirect;

pub fn writeJsonErr(
    cfd: i32,
    status: u16,
    reason: []const u8,
    msg: []const u8,
) void {
    var buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}\n", .{msg}) catch
        "{\"error\":\"proxy_failed\"}\n";
    net_http.writeHttpResponse(
        cfd,
        status,
        reason,
        "application/json",
        body,
    ) catch {};
}

fn mapGatewayErr(cfd: i32, err: anyerror, fallback_status: u16) void {
    switch (err) {
        error.QuotaExceeded => writeJsonErr(
            cfd,
            429,
            "Too Many Requests",
            "quota_exceeded",
        ),
        error.RateLimited => writeJsonErr(
            cfd,
            429,
            "Too Many Requests",
            "rate_limited",
        ),
        error.ThinkingTierDenied => writeJsonErr(
            cfd,
            403,
            "Forbidden",
            "thinking_tier_denied",
        ),
        else => if (fallback_status == 502)
            writeJsonErr(cfd, 502, "Bad Gateway", "upstream_llm_error")
        else
            writeJsonErr(cfd, 500, "Internal Server Error", "gateway_error"),
    }
}

pub fn handleInferPost(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    cfd: i32,
    caller_cid: usize,
    req_body: []const u8,
) void {
    const InferReq = struct {
        system: []const u8 = "",
        prompt: []const u8 = "",
        thinking: []const u8 = "",
        max_output_tokens: u32 = 512,
        format: []const u8 = "text",
    };
    const parsed = std.json.parseFromSlice(
        InferReq,
        allocator,
        req_body,
        .{ .ignore_unknown_fields = true },
    ) catch return writeJsonErr(cfd, 400, "Bad Request", "invalid_json");
    defer parsed.deinit();
    const r = parsed.value;
    if (common.trimWhitespace(r.prompt).len == 0) {
        return writeJsonErr(cfd, 400, "Bad Request", "empty_prompt");
    }
    var req_lvl: ?ThinkingLevel = null;
    if (r.thinking.len > 0) {
        req_lvl = cfg_mod.parseThinkingLevel(r.thinking) orelse
            return writeJsonErr(cfd, 400, "Bad Request", "invalid_thinking");
    }
    const max_out = std.math.clamp(r.max_output_tokens, 1, 4096);
    const est_in = backend.approxTokens(r.system.len + r.prompt.len);

    const has_p = net_http.isHasParent(client);
    var cfg = cfg_mod.loadAgentConfig(allocator, has_p);
    defer cfg.deinit();

    const res = ledger.reserveInference(
        allocator,
        client,
        &cfg,
        has_p,
        caller_cid,
        req_lvl,
        est_in,
        max_out,
        null,
    ) catch |err| return mapGatewayErr(cfd, err, 500);

    const back = invokeTieredBackend(
        allocator,
        client,
        &cfg,
        res.thinking,
        r.system,
        r.prompt,
        max_out,
        r.format,
    ) catch |err| {
        ledger.abortInference(allocator, res, null);
        return mapGatewayErr(cfd, err, 502);
    };
    defer back.deinit(allocator);

    const u = ledger.settleInference(
        allocator,
        &cfg,
        res,
        back.input_tokens,
        back.output_tokens,
        null,
    ) catch
        return writeJsonErr(cfd, 500, "Internal Server Error", "settle_err");

    const ans_esc = common.escapeJsonAlloc(allocator, back.answer) catch
        return writeJsonErr(cfd, 500, "Internal Server Error", "oom");
    defer allocator.free(ans_esc);
    const body = allocator.print(
        "{{\"answer\":\"{s}\",\"thinking_used\":\"{s}\"," ++
            "\"provider\":\"{s}\"," ++
            "\"usage\":{{\"input_tokens\":{d},\"output_tokens\":{d}," ++
            "\"total_tokens\":{d},\"cost_micros_usd\":{d}," ++
            "\"remaining_tokens\":{d},\"remaining_cost_micros_usd\":{d}}}}}\n",
        .{
            ans_esc,
            @tagName(res.thinking),
            @tagName(cfg.resolved_provider),
            u.input_tokens,
            u.output_tokens,
            u.total_tokens,
            u.cost_micros_usd,
            u.remaining_tokens,
            u.remaining_cost_micros_usd,
        },
    ) catch return writeJsonErr(cfd, 500, "Internal Server Error", "oom");
    defer allocator.free(body);
    net_http.writeHttpResponse(cfd, 200, "OK", "application/json", body) catch
        {};
}

pub fn handleLegacyChatPost(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    cfd: i32,
    caller_cid: usize,
    req_body: []const u8,
) void {
    const Msg = struct { role: []const u8 = "", content: []const u8 = "" };
    const ChatReq = struct {
        messages: []const Msg = &.{},
        max_tokens: u32 = 512,
    };
    const parsed = std.json.parseFromSlice(
        ChatReq,
        allocator,
        req_body,
        .{ .ignore_unknown_fields = true },
    ) catch return writeJsonErr(cfd, 400, "Bad Request", "invalid_json");
    defer parsed.deinit();

    var sys_msg: []const u8 = "";
    var usr_msg: []const u8 = "";
    for (parsed.value.messages) |m| {
        if (std.mem.eql(u8, m.role, "system")) sys_msg = m.content;
        if (std.mem.eql(u8, m.role, "user")) usr_msg = m.content;
    }
    if (common.trimWhitespace(usr_msg).len == 0) {
        return writeJsonErr(cfd, 400, "Bad Request", "empty_prompt");
    }
    const max_out = std.math.clamp(parsed.value.max_tokens, 1, 4096);
    const est_in = backend.approxTokens(sys_msg.len + usr_msg.len);

    const has_p = net_http.isHasParent(client);
    var cfg = cfg_mod.loadAgentConfig(allocator, has_p);
    defer cfg.deinit();

    const res = ledger.reserveInference(
        allocator,
        client,
        &cfg,
        has_p,
        caller_cid,
        .low,
        est_in,
        max_out,
        null,
    ) catch |err| return mapGatewayErr(cfd, err, 500);

    const back = invokeTieredBackend(
        allocator,
        client,
        &cfg,
        res.thinking,
        sys_msg,
        usr_msg,
        max_out,
        "text",
    ) catch |err| {
        ledger.abortInference(allocator, res, null);
        return mapGatewayErr(cfd, err, 502);
    };
    defer back.deinit(allocator);

    _ = ledger.settleInference(
        allocator,
        &cfg,
        res,
        back.input_tokens,
        back.output_tokens,
        null,
    ) catch {};

    const esc = common.escapeJsonAlloc(allocator, back.answer) catch
        return writeJsonErr(cfd, 500, "Internal Server Error", "oom");
    defer allocator.free(esc);
    const resp = allocator.print(
        "{{\"id\":\"diosix-gw-1\",\"object\":\"chat.completion\"," ++
            "\"model\":\"{s}\",\"choices\":[{{\"index\":0," ++
            "\"message\":{{\"role\":\"assistant\",\"content\":\"{s}\"}}," ++
            "\"finish_reason\":\"stop\"}}]," ++
            "\"usage\":{{\"prompt_tokens\":{d}," ++
            "\"completion_tokens\":{d},\"total_tokens\":{d}}}}}\n",
        .{
            cfg.tierSpec(res.thinking).model(),
            esc,
            back.input_tokens,
            back.output_tokens,
            back.input_tokens +| back.output_tokens,
        },
    ) catch return writeJsonErr(cfd, 500, "Internal Server Error", "oom");
    defer allocator.free(resp);
    net_http.writeHttpResponse(cfd, 200, "OK", "application/json", resp) catch
        {};
}

pub fn handleQuotaGet(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    cfd: i32,
    caller_cid: usize,
) void {
    const has_p = net_http.isHasParent(client);
    var cfg = cfg_mod.loadAgentConfig(allocator, has_p);
    defer cfg.deinit();
    const q = ledger.queryQuotaView(
        allocator,
        client,
        &cfg,
        has_p,
        caller_cid,
        null,
    ) catch
        return writeJsonErr(cfd, 500, "Internal Server Error", "quota_err");
    const body = formatQuotaViewJsonAlloc(allocator, q) catch
        return writeJsonErr(cfd, 500, "Internal Server Error", "oom");
    defer allocator.free(body);
    net_http.writeHttpResponse(cfd, 200, "OK", "application/json", body) catch
        {};
}

test "agent/gateway: wires backend and server handlers" {
    _ = backend;
    std.testing.refAllDecls(@This());
}
