// Diosix Autonomous Node Agent & Inference Gateway CLI (`dsx agent`).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("api.zig");
const common = @import("common.zig");
const sysconfig = @import("sysconfig.zig");
pub const config = @import("agent/config.zig");
pub const llm = @import("agent/llm.zig");
pub const ledger = @import("agent/ledger.zig");
pub const gateway = @import("agent/gateway.zig");
pub const proxy = @import("agent/proxy.zig");
pub const loop = @import("agent/loop.zig");
pub const admin = @import("agent/admin.zig");
pub const autonomy = @import("agent/autonomy.zig");

const AgentSubcmd = enum {
    status,
    ask,
    @"set-key",
    quota,
    grant,
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

fn printAgentUsage() void {
    const exe = common.getExeName();
    common.printFmt(
        \\Usage:
        \\  {s} agent status [--json]            Show provider & daemon state
        \\  {s} agent ask <prompt> [--thinking T] Query thinking gateway
        \\  {s} agent set-key --provider P [--key] Set root API credentials
        \\  {s} agent quota [<vm|cid|self>]       Show conserved LLM quota
        \\  {s} agent grant <vm|cid> [opts]       Grant token/USD child budget
        \\  {s} agent proxy [--port 8081] [-d]    Serve :8081 thinking gateway
        \\  {s} agent step [--json]               Run one autonomous step
        \\  {s} agent run [--interval S] [-d]     Run continuous agent daemon
        \\
    , .{ exe, exe, exe, exe, exe, exe, exe, exe });
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
        .status => admin.cmdStatus(allocator, client, json_f),
        .ask => admin.cmdAsk(allocator, client, args, json_f),
        .@"set-key" => admin.cmdSetKey(allocator, client, args, json_f),
        .quota => admin.cmdQuota(allocator, client, args, json_f),
        .grant => admin.cmdGrant(allocator, client, args, json_f),
        .proxy => proxy.runProxyServer(port, daemon) catch |e| {
            common.printApiError("Start agent LLM proxy", e);
            admin.failExit();
        },
        .step => {
            const rep = loop.runAgentStep(allocator, client);
            if (json_f) {
                common.printFmt(
                    "{{\"proposals_seen\":{d},\"votes_cast\":{d}," ++
                        "\"votes_approved\":{d},\"votes_rejected\":{d}," ++
                        "\"sealed_version\":{d},\"replicas_spawned\":{d}," ++
                        "\"tasks_completed\":{d}}}\n",
                    .{
                        rep.proposals_seen,
                        rep.votes_cast,
                        rep.votes_approved,
                        rep.votes_rejected,
                        rep.sealed_version,
                        rep.replicas_spawned,
                        rep.tasks_completed,
                    },
                );
            } else {
                common.printFmt(
                    "✓ Agent step: proposals={d} votes={d} " ++
                        "(approve={d}, reject={d}) sealed_v={d} " ++
                        "spawned={d} tasks={d}.\n",
                    .{
                        rep.proposals_seen,
                        rep.votes_cast,
                        rep.votes_approved,
                        rep.votes_rejected,
                        rep.sealed_version,
                        rep.replicas_spawned,
                        rep.tasks_completed,
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
            admin.failExit();
        },
        .help, .@"--help", .@"-h" => printAgentUsage(),
    }
}

test "agent: subcommand enum and submodule declarations compile" {
    std.testing.refAllDecls(@This());
    _ = config;
    _ = llm;
    _ = ledger;
    _ = gateway;
    _ = proxy;
    _ = loop;
    _ = admin;
    _ = autonomy;
    try std.testing.expectEqual(
        AgentSubcmd.grant,
        std.meta.stringToEnum(AgentSubcmd, "grant").?,
    );
}
