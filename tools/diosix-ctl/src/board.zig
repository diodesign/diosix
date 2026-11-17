// Diosix Parent-Level Anti-Collusion Message Board CLI (`dsx board`).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("api.zig");
const common = @import("common.zig");
const net_http = @import("net/http.zig");
const pkg = @import("pkg.zig");
const ssh = @import("ssh.zig");
const sysconfig = @import("sysconfig.zig");
const board_server = @import("board/server.zig");
const board_store = @import("board/store.zig");

pub const store = board_store;
pub const server = board_server;

const MAX_BOARD_HTTP_BYTES: usize = 4 * 1024 * 1024;

const BoardSubcmd = enum {
    post,
    list,
    status,
    policy,
    serve,
    help,
    @"--help",
    @"-h",
};

const BoardOption = enum {
    @"--topic",
    @"-t",
    @"--to",
    @"--since",
    @"--parent",
    @"--local",
    @"--port",
    @"-p",
    @"--daemon",
    @"-d",
    @"--json",
    @"-j",
    @"--allow-topics",
    @"--mute",
    @"--unmute",
};

const BroadcastAlias = enum { all, board, parent, self, @"0" };

fn failExit() void {
    if (!@import("builtin").is_test) std.process.exit(1);
}

fn printBoardUsage() void {
    const exe = common.getExeName();
    common.printFmt(
        \\Usage:
        \\  {s} board post <msg> [--topic T] [--to all|parent|vm|cid]
        \\      [--parent|--local]
        \\  {s} board list [--topic T] [--since seq] [--parent|--local]
        \\  {s} board status [--parent|--local] [--json]
        \\  {s} board policy [--allow-topics *|csv] [--mute vm]
        \\      [--unmute vm]
        \\  {s} board serve [--port P] [--daemon]
        \\
    , .{ exe, exe, exe, exe, exe });
}

fn resolveEndpointIp(client: *api.DiosixClient, use_parent: bool) u32 {
    if (!use_parent) return ssh.parseIpv4("127.0.0.1") orelse 0;
    return net_http.resolveParentIpv4(client);
}

fn resolveBoardTargetCid(target: []const u8) ?usize {
    if (std.meta.stringToEnum(BroadcastAlias, target) != null) return 0;
    return pkg.resolveChildTargetCid(target);
}

const BoardJsonEntry = struct {
    seq: u64,
    ts: i64,
    author_cid: usize,
    target_cid: usize,
    topic: []const u8,
    hash: []const u8,
    body: []const u8,
};

fn cmdPost(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
) void {
    var topic: []const u8 = "general";
    var to_str: ?[]const u8 = null;
    var parent_override: ?bool = null;
    var port: u16 = sysconfig.DEFAULT_BOARD_PORT;
    var json_flag = false;
    var msg_opt: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const s = std.mem.span(args[i]);
        if (std.meta.stringToEnum(BoardOption, s)) |opt| {
            switch (opt) {
                .@"--topic", .@"-t" => if (i + 1 < args.len) {
                    i += 1;
                    topic = std.mem.span(args[i]);
                },
                .@"--to" => if (i + 1 < args.len) {
                    i += 1;
                    to_str = std.mem.span(args[i]);
                },
                .@"--parent" => parent_override = true,
                .@"--local" => parent_override = false,
                .@"--port", .@"-p" => if (i + 1 < args.len) {
                    i += 1;
                    port = std.fmt.parseInt(
                        u16,
                        std.mem.span(args[i]),
                        10,
                    ) catch sysconfig.DEFAULT_BOARD_PORT;
                },
                .@"--json", .@"-j" => json_flag = true,
                else => {},
            }
        } else if (!std.mem.startsWith(u8, s, "-") and msg_opt == null) {
            msg_opt = s;
        }
    }

    const body = msg_opt orelse {
        common.printStr("Usage: dsx board post <message> [options]\n");
        return failExit();
    };
    const target_cid: usize = if (to_str) |ts|
        resolveBoardTargetCid(ts) orelse {
            common.printFmt("Error: Unknown target VM '{s}'.\n", .{ts});
            return failExit();
        }
    else
        0;

    const use_parent: bool = if (parent_override) |p|
        p
    else if (to_str != null and target_cid >= common.CID_FIRST_CHILD)
        false
    else
        net_http.isHasParent(client);

    const t_esc = common.escapeJsonAlloc(allocator, topic) catch return;
    defer allocator.free(t_esc);
    const b_esc = common.escapeJsonAlloc(allocator, body) catch return;
    defer allocator.free(b_esc);
    const req_json = allocator.print(
        "{{\"topic\":\"{s}\",\"target_cid\":{d},\"body\":\"{s}\"}}",
        .{ t_esc, target_cid, b_esc },
    ) catch return;
    defer allocator.free(req_json);

    const ip_be = resolveEndpointIp(client, use_parent);
    const resp = net_http.httpClientRequest(
        allocator,
        ip_be,
        port,
        "POST",
        "/v1/messages",
        "application/json",
        req_json,
        MAX_BOARD_HTTP_BYTES,
    ) catch |err| {
        common.printApiError("Post message to board", err);
        return failExit();
    };
    defer resp.deinit(allocator);

    if (resp.status >= 400) {
        common.printFmt("Error: Board rejected post (HTTP {d}): {s}", .{
            resp.status, resp.body,
        });
        if (resp.body.len == 0 or resp.body[resp.body.len - 1] != '\n') {
            common.printStr("\n");
        }
        return failExit();
    }
    if (json_flag) {
        common.printStr(resp.body);
        return;
    }
    common.printFmt("✓ Posted to board [{s}] (target CID {d}).\n", .{
        topic, target_cid,
    });
}

fn cmdList(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
) void {
    var topic_opt: ?[]const u8 = null;
    var since_seq: u64 = 0;
    var parent_override: ?bool = null;
    var port: u16 = sysconfig.DEFAULT_BOARD_PORT;
    var json_flag = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const s = std.mem.span(args[i]);
        const opt = std.meta.stringToEnum(BoardOption, s) orelse continue;
        switch (opt) {
            .@"--topic", .@"-t" => if (i + 1 < args.len) {
                i += 1;
                topic_opt = std.mem.span(args[i]);
            },
            .@"--since" => if (i + 1 < args.len) {
                i += 1;
                since_seq = std.fmt.parseInt(
                    u64,
                    std.mem.span(args[i]),
                    10,
                ) catch 0;
            },
            .@"--parent" => parent_override = true,
            .@"--local" => parent_override = false,
            .@"--port", .@"-p" => if (i + 1 < args.len) {
                i += 1;
                port = std.fmt.parseInt(
                    u16,
                    std.mem.span(args[i]),
                    10,
                ) catch sysconfig.DEFAULT_BOARD_PORT;
            },
            .@"--json", .@"-j" => json_flag = true,
            else => {},
        }
    }

    if (topic_opt) |t| {
        if (!board_store.isValidTopic(t)) {
            common.printFmt("Error: Invalid topic '{s}'.\n", .{t});
            return failExit();
        }
    }
    const use_parent = parent_override orelse net_http.isHasParent(client);
    const path = if (topic_opt) |t|
        allocator.print("/v1/messages?topic={s}&since={d}", .{
            t, since_seq,
        }) catch return
    else
        allocator.print("/v1/messages?since={d}", .{since_seq}) catch return;
    defer allocator.free(path);

    const ip_be = resolveEndpointIp(client, use_parent);
    const resp = net_http.httpClientRequest(
        allocator,
        ip_be,
        port,
        "GET",
        path,
        null,
        "",
        MAX_BOARD_HTTP_BYTES,
    ) catch |err| {
        common.printApiError("Query message board", err);
        return failExit();
    };
    defer resp.deinit(allocator);
    if (resp.status >= 400) {
        common.printFmt("Error: Board returned HTTP {d}.\n", .{resp.status});
        return failExit();
    }
    if (json_flag) {
        common.printStr(resp.body);
        common.printStr("\n");
        return;
    }

    const parsed = std.json.parseFromSlice(
        []const BoardJsonEntry,
        allocator,
        resp.body,
        .{ .ignore_unknown_fields = true },
    ) catch {
        common.printStr(resp.body);
        return;
    };
    defer parsed.deinit();

    if (parsed.value.len == 0) {
        common.printStr("No board messages visible.\n");
        return;
    }
    for (parsed.value) |m| {
        const tgt_lbl = if (m.target_cid == 0) "all" else "cid";
        if (m.target_cid == 0) {
            common.printFmt("#{d} [{s}] cid {d} -> {s}: {s}\n", .{
                m.seq, m.topic, m.author_cid, tgt_lbl, m.body,
            });
        } else {
            common.printFmt("#{d} [{s}] cid {d} -> cid {d}: {s}\n", .{
                m.seq, m.topic, m.author_cid, m.target_cid, m.body,
            });
        }
    }
}

fn cmdStatus(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    args: []const [*:0]const u8,
) void {
    var parent_override: ?bool = null;
    var port: u16 = sysconfig.DEFAULT_BOARD_PORT;
    var json_flag = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const s = std.mem.span(args[i]);
        const opt = std.meta.stringToEnum(BoardOption, s) orelse continue;
        switch (opt) {
            .@"--parent" => parent_override = true,
            .@"--local" => parent_override = false,
            .@"--port", .@"-p" => if (i + 1 < args.len) {
                i += 1;
                port = std.fmt.parseInt(
                    u16,
                    std.mem.span(args[i]),
                    10,
                ) catch sysconfig.DEFAULT_BOARD_PORT;
            },
            .@"--json", .@"-j" => json_flag = true,
            else => {},
        }
    }

    const use_parent = parent_override orelse net_http.isHasParent(client);
    const ip_be = resolveEndpointIp(client, use_parent);
    const resp = net_http.httpClientRequest(
        allocator,
        ip_be,
        port,
        "GET",
        "/v1/status",
        null,
        "",
        MAX_BOARD_HTTP_BYTES,
    ) catch |err| {
        common.printApiError("Query board status", err);
        return failExit();
    };
    defer resp.deinit(allocator);
    if (resp.status >= 400) {
        common.printFmt("Error: Board returned HTTP {d}.\n", .{resp.status});
        return failExit();
    }
    if (json_flag) {
        common.printStr(resp.body);
        return;
    }
    const local_pid = net_http.isPidFileRunning(sysconfig.BOARD_PID_PATH);
    common.printFmt("Local board daemon: {s}\nBoard response    : {s}", .{
        if (local_pid != null) "running" else "stopped",
        resp.body,
    });
}

fn cmdPolicy(allocator: std.mem.Allocator, args: []const [*:0]const u8) void {
    var pol = board_store.loadPolicy(
        allocator,
        sysconfig.BOARD_POLICY_PATH,
    ) catch return;
    defer pol.deinit(allocator);
    var changed = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const s = std.mem.span(args[i]);
        const opt = std.meta.stringToEnum(BoardOption, s) orelse continue;
        switch (opt) {
            .@"--allow-topics" => if (i + 1 < args.len) {
                i += 1;
                const val = std.mem.span(args[i]);
                for (pol.allowed_topics.items) |t| allocator.free(t);
                pol.allowed_topics.clearRetainingCapacity();
                if (std.mem.eql(u8, val, "*")) {
                    pol.allow_all_topics = true;
                } else {
                    pol.allow_all_topics = false;
                    var it = std.mem.splitScalar(u8, val, ',');
                    while (it.next()) |raw_t| {
                        const t = common.trimWhitespace(raw_t);
                        if (board_store.isValidTopic(t)) {
                            const dt = allocator.dupe(u8, t) catch return;
                            pol.allowed_topics.append(allocator, dt) catch
                                return;
                        }
                    }
                }
                changed = true;
            },
            .@"--mute" => if (i + 1 < args.len) {
                i += 1;
                if (pkg.resolveChildTargetCid(std.mem.span(args[i]))) |c| {
                    pol.muteCid(allocator, c) catch return;
                    changed = true;
                }
            },
            .@"--unmute" => if (i + 1 < args.len) {
                i += 1;
                if (pkg.resolveChildTargetCid(std.mem.span(args[i]))) |c| {
                    pol.unmuteCid(c);
                    changed = true;
                }
            },
            else => {},
        }
    }
    if (changed) {
        board_store.savePolicy(
            allocator,
            sysconfig.BOARD_POLICY_PATH,
            &pol,
        ) catch return;
        common.printStr("✓ Updated local board policy.\n");
        return;
    }
    common.printFmt("max_body_bytes = {d}\nallow_all_topics = {}\n", .{
        pol.max_body_bytes, pol.allow_all_topics,
    });
}

pub fn cmdBoard(client: *api.DiosixClient, args: []const [*:0]const u8) !void {
    if (args.len == 0) return printBoardUsage();
    const allocator = std.heap.page_allocator;
    const sub = std.meta.stringToEnum(
        BoardSubcmd,
        std.mem.span(args[0]),
    ) orelse return printBoardUsage();

    var port: u16 = sysconfig.DEFAULT_BOARD_PORT;
    var daemon = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const s = std.mem.span(args[i]);
        const opt = std.meta.stringToEnum(BoardOption, s) orelse continue;
        switch (opt) {
            .@"--daemon", .@"-d" => daemon = true,
            .@"--port", .@"-p" => if (i + 1 < args.len) {
                i += 1;
                port = std.fmt.parseInt(
                    u16,
                    std.mem.span(args[i]),
                    10,
                ) catch sysconfig.DEFAULT_BOARD_PORT;
            },
            else => {},
        }
    }

    switch (sub) {
        .post => cmdPost(allocator, client, args),
        .list => cmdList(allocator, client, args),
        .status => cmdStatus(allocator, client, args),
        .policy => cmdPolicy(allocator, args),
        .serve => board_server.runServer(port, daemon) catch |err| {
            common.printApiError("Start message board server", err);
            failExit();
        },
        .help, .@"--help", .@"-h" => printBoardUsage(),
    }
}

test "board: submodule declarations compile cleanly" {
    std.testing.refAllDecls(@This());
    _ = store;
    _ = server;
}
