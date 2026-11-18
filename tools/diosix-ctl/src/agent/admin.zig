// Agent Administrative & Client Subcommands (`status`, `ask`, & Re-exports).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../api.zig");
const cfg_mod = @import("config.zig");
const common = @import("../common.zig");
const gateway = @import("gateway.zig");
const net_http = @import("../net/http.zig");
const sysconfig = @import("../sysconfig.zig");
pub const quota = @import("admin/quota.zig");

pub const failExit = quota.failExit;
pub const cmdSetKey = quota.cmdSetKey;
pub const cmdQuota = quota.cmdQuota;
pub const cmdGrant = quota.cmdGrant;
pub const updateManifestLlmDirectives = quota.updateManifestLlmDirectives;

const AskOption = enum {
    @"--thinking",
    @"-t",
    @"--max-tokens",
    @"-m",
    @"--format",
    @"-f",
    @"--json",
    @"-j",
};

pub fn cmdStatus(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    json_f: bool,
) void {
    const has_p = net_http.isHasParent(client);
    var cfg = cfg_mod.loadAgentConfig(allocator, has_p);
    defer cfg.deinit();
    const proxy_pid = net_http.isPidFileRunning(sysconfig.LLM_PROXY_PID_PATH);
    const agent_pid = net_http.isPidFileRunning(sysconfig.AGENT_PID_PATH);
    const m_esc = common.escapeJsonAlloc(allocator, cfg.model()) catch return;
    defer allocator.free(m_esc);
    const e_esc = common.escapeJsonAlloc(allocator, cfg.endpoint()) catch
        return;
    defer allocator.free(e_esc);

    if (json_f) {
        common.printFmt(
            "{{\"provider\":\"{s}\",\"model\":\"{s}\",\"endpoint\":\"{s}\"," ++
                "\"default_thinking\":\"{s}\",\"has_parent\":{}," ++
                "\"proxy_running\":{},\"agent_running\":{}," ++
                "\"proxy_port\":{d}}}\n",
            .{
                @tagName(cfg.resolved_provider),
                m_esc,
                e_esc,
                @tagName(cfg.default_thinking),
                has_p,
                proxy_pid != null,
                agent_pid != null,
                cfg.proxy_port,
            },
        );
        return;
    }

    const ep_disp = if (cfg.endpoint().len > 0)
        cfg.endpoint()
    else
        "(deterministic policy)";
    common.printFmt(
        \\=== Diosix Autonomous Node Agent ===
        \\  Resolved provider : {s}
        \\  Model             : {s}
        \\  Default thinking  : {s}
        \\  Endpoint          : {s}
        \\  LLM proxy (:{d})  : {s}
        \\  Agent daemon      : {s}
        \\
    , .{
        @tagName(cfg.resolved_provider),
        cfg.model(),
        @tagName(cfg.default_thinking),
        ep_disp,
        cfg.proxy_port,
        if (proxy_pid != null) "running" else "stopped",
        if (agent_pid != null) "running" else "stopped",
    });
}

pub fn cmdAsk(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
    json_f: bool,
) void {
    var prompt_opt: ?[]const u8 = null;
    var req_thinking: ?cfg_mod.ThinkingLevel = null;
    var max_out: u32 = 512;
    var format: []const u8 = "text";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const s = std.mem.span(args[i]);
        if (std.meta.stringToEnum(AskOption, s)) |opt| {
            switch (opt) {
                .@"--thinking", .@"-t" => {
                    const v = quota.takeArg(args, &i) orelse {
                        common.printStr("Error: '--thinking' needs value.\n");
                        return failExit();
                    };
                    req_thinking = cfg_mod.parseThinkingLevel(v) orelse {
                        common.printStr("Error: Invalid thinking tier.\n");
                        return failExit();
                    };
                },
                .@"--max-tokens", .@"-m" => {
                    const v = quota.takeArg(args, &i) orelse
                        return failExit();
                    max_out = std.fmt.parseInt(u32, v, 10) catch 512;
                },
                .@"--format", .@"-f" => {
                    format = quota.takeArg(args, &i) orelse "text";
                },
                .@"--json", .@"-j" => {},
            }
        } else if (!std.mem.startsWith(u8, s, "-") and prompt_opt == null) {
            prompt_opt = s;
        }
    }
    const prompt = prompt_opt orelse {
        common.printStr(
            "Usage: dsx agent ask <prompt> [--thinking T] [--max-tokens N] " ++
                "[--json]\n",
        );
        return failExit();
    };

    const res = gateway.queryLocalGatewayOrDirect(
        allocator,
        client,
        "",
        prompt,
        req_thinking,
        max_out,
        format,
    ) catch |e| {
        common.printApiError("Query agent thinking gateway", e);
        return failExit();
    };
    defer res.deinit(allocator);

    if (json_f) {
        const a_esc = common.escapeJsonAlloc(
            allocator,
            res.answer,
        ) catch return;
        defer allocator.free(a_esc);
        const p_esc = common.escapeJsonAlloc(allocator, res.provider) catch
            return;
        defer allocator.free(p_esc);
        common.printFmt(
            "{{\"provider\":\"{s}\",\"thinking\":\"{s}\"," ++
                "\"response\":\"{s}\",\"usage\":{{\"input_tokens\":{d}," ++
                "\"output_tokens\":{d},\"total_tokens\":{d}," ++
                "\"cost_micros_usd\":{d},\"remaining_tokens\":{d}," ++
                "\"remaining_cost_micros_usd\":{d}}}}}\n",
            .{
                p_esc,
                @tagName(res.thinking_used),
                a_esc,
                res.usage.input_tokens,
                res.usage.output_tokens,
                res.usage.total_tokens,
                res.usage.cost_micros_usd,
                res.usage.remaining_tokens,
                res.usage.remaining_cost_micros_usd,
            },
        );
    } else {
        common.printFmt("{s}\n", .{res.answer});
    }
}

test "agent/admin: AskOption enum and quota re-exports compile" {
    _ = quota;
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(
        AskOption.@"--thinking",
        std.meta.stringToEnum(AskOption, "--thinking").?,
    );
}
