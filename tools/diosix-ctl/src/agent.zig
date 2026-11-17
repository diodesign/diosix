// Diosix Autonomous Node Agent & Inference Proxy CLI (`dsx agent`).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("api.zig");
const common = @import("common.zig");
const net_http = @import("net/http.zig");
const sysconfig = @import("sysconfig.zig");
pub const config = @import("agent/config.zig");
pub const llm = @import("agent/llm.zig");
pub const proxy = @import("agent/proxy.zig");
pub const loop = @import("agent/loop.zig");

const AgentSubcmd = enum {
    status,
    ask,
    proxy,
    step,
    run,
    help,
    @"--help",
    @"-h",
};

const AgentOption = enum {
    @"--port",
    @"-p",
    @"--interval",
    @"-i",
    @"--daemon",
    @"-d",
    @"--json",
    @"-j",
};

fn failExit() void {
    if (!@import("builtin").is_test) std.process.exit(1);
}

fn printAgentUsage() void {
    const exe = common.getExeName();
    common.printFmt(
        \\Usage:
        \\  {s} agent status [--json]           Show provider and daemon status
        \\  {s} agent ask <prompt> [--json]     Query configured LLM or parent
        \\  {s} agent proxy [--port 8081] [-d]  Serve LLM proxy on diosix0
        \\  {s} agent step [--json]             Run one reconciliation tick
        \\  {s} agent run [--interval S] [-d]   Run continuous agent daemon
        \\
    , .{ exe, exe, exe, exe, exe });
}

fn cmdStatus(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    json_f: bool,
) void {
    const has_p = net_http.isHasParent(client);
    var cfg = config.loadAgentConfig(allocator, has_p);
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
                "\"has_parent\":{},\"proxy_running\":{}," ++
                "\"agent_running\":{},\"proxy_port\":{d}}}\n",
            .{
                @tagName(cfg.resolved_provider),
                m_esc,
                e_esc,
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
        \\  Endpoint          : {s}
        \\  LLM proxy (:{d})  : {s}
        \\  Agent daemon      : {s}
        \\
    , .{
        @tagName(cfg.resolved_provider),
        cfg.model(),
        ep_disp,
        cfg.proxy_port,
        if (proxy_pid != null) "running" else "stopped",
        if (agent_pid != null) "running" else "stopped",
    });
}

fn cmdAsk(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
    json_f: bool,
) void {
    var prompt_opt: ?[]const u8 = null;
    for (args[1..]) |a| {
        const s = std.mem.span(a);
        if (!std.mem.startsWith(u8, s, "-") and prompt_opt == null) {
            prompt_opt = s;
        }
    }
    const prompt = prompt_opt orelse {
        common.printStr("Usage: dsx agent ask <prompt> [--json]\n");
        return failExit();
    };
    const has_p = net_http.isHasParent(client);
    var cfg = config.loadAgentConfig(allocator, has_p);
    defer cfg.deinit();

    const req = llm.buildChatRequestJson(
        allocator,
        cfg.model(),
        prompt,
        cfg.max_tokens,
    ) catch return;
    defer allocator.free(req);

    const raw = llm.invokeRawChatCompletion(
        allocator,
        client,
        &cfg,
        req,
    ) catch |e| {
        common.printApiError("Query agent LLM brain", e);
        return failExit();
    };
    defer allocator.free(raw);

    const answer = llm.extractAssistantContentAlloc(allocator, raw) catch
        return;
    defer allocator.free(answer);

    if (json_f) {
        const a_esc = common.escapeJsonAlloc(allocator, answer) catch return;
        defer allocator.free(a_esc);
        common.printFmt(
            "{{\"provider\":\"{s}\",\"model\":\"{s}\",\"response\":\"{s}\"}}\n",
            .{ @tagName(cfg.resolved_provider), cfg.model(), a_esc },
        );
    } else {
        common.printFmt("{s}\n", .{answer});
    }
}

pub fn cmdAgent(
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
) !void {
    if (args.len == 0) return printAgentUsage();
    const allocator = std.heap.page_allocator;
    const sub = std.meta.stringToEnum(
        AgentSubcmd,
        std.mem.span(args[0]),
    ) orelse return printAgentUsage();

    var port: u16 = sysconfig.DEFAULT_LLM_PROXY_PORT;
    var interval_sec: u32 = 5;
    var daemon = false;
    var json_f = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const s = std.mem.span(args[i]);
        const opt = std.meta.stringToEnum(AgentOption, s) orelse continue;
        switch (opt) {
            .@"--daemon", .@"-d" => daemon = true,
            .@"--json", .@"-j" => json_f = true,
            .@"--port", .@"-p" => if (i + 1 < args.len) {
                i += 1;
                port = std.fmt.parseInt(u16, std.mem.span(args[i]), 10) catch
                    sysconfig.DEFAULT_LLM_PROXY_PORT;
            },
            .@"--interval", .@"-i" => if (i + 1 < args.len) {
                i += 1;
                interval_sec =
                    std.fmt.parseInt(u32, std.mem.span(args[i]), 10) catch 5;
            },
        }
    }

    switch (sub) {
        .status => cmdStatus(allocator, client, json_f),
        .ask => cmdAsk(allocator, client, args, json_f),
        .proxy => proxy.runProxyServer(port, daemon) catch |e| {
            common.printApiError("Start agent LLM proxy", e);
            failExit();
        },
        .step => {
            const rep = loop.runAgentStep(allocator, client);
            if (json_f) {
                common.printFmt(
                    "{{\"proposals_seen\":{d},\"votes_cast\":{d}," ++
                        "\"votes_approved\":{d},\"votes_rejected\":{d}," ++
                        "\"sealed_version\":{d},\"replicas_spawned\":{d}}}\n",
                    .{
                        rep.proposals_seen,
                        rep.votes_cast,
                        rep.votes_approved,
                        rep.votes_rejected,
                        rep.sealed_version,
                        rep.replicas_spawned,
                    },
                );
            } else {
                common.printFmt(
                    "✓ Agent step: proposals={d} votes={d} " ++
                        "(approve={d}, reject={d}) sealed_v={d} " ++
                        "spawned={d}.\n",
                    .{
                        rep.proposals_seen,
                        rep.votes_cast,
                        rep.votes_approved,
                        rep.votes_rejected,
                        rep.sealed_version,
                        rep.replicas_spawned,
                    },
                );
            }
        },
        .run => loop.runAgentDaemon(
            allocator,
            client,
            interval_sec,
            daemon,
        ) catch |e| {
            common.printApiError("Run autonomous agent daemon", e);
            failExit();
        },
        .help, .@"--help", .@"-h" => printAgentUsage(),
    }
}

test "agent: subcommand enum and submodule declarations compile" {
    std.testing.refAllDecls(@This());
    _ = config;
    _ = llm;
    _ = proxy;
    _ = loop;
    try std.testing.expectEqual(
        AgentSubcmd.proxy,
        std.meta.stringToEnum(AgentSubcmd, "proxy").?,
    );
}
