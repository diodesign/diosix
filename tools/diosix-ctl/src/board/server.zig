// Parent-Moderated Anti-Collusion Message Board HTTP Server.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const common = @import("../common.zig");
const net_http = @import("../net/http.zig");
const sysconfig = @import("../sysconfig.zig");
const store = @import("store.zig");

const MAX_POST_REQ_BYTES: usize = 64 * 1024;
const E_INTR: isize = -@as(isize, @backingInt(linux.E.INTR));

const PostPayload = struct {
    topic: []const u8 = "general",
    target_cid: usize = 0,
    body: []const u8,
};

pub fn extractQueryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

fn writeJsonErr(
    cfd: i32,
    status: u16,
    reason: []const u8,
    msg: []const u8,
) void {
    var buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}\n", .{msg}) catch
        "{\"error\":\"request_failed\"}\n";
    net_http.writeHttpResponse(
        cfd,
        status,
        reason,
        "application/json",
        body,
    ) catch {};
}

fn handleGetStatus(
    allocator: std.mem.Allocator,
    cfd: i32,
    caller_cid: usize,
    store_path: []const u8,
) void {
    var st = store.loadStore(allocator, store_path) catch {
        return writeJsonErr(cfd, 500, "Internal Server Error", "load_failed");
    };
    defer st.deinit(allocator);
    const body = allocator.print(
        "{{\"ok\":true,\"caller_cid\":{d},\"message_count\":{d}," ++
            "\"chain_valid\":{},\"head_hash\":\"{s}\"}}\n",
        .{ caller_cid, st.entries.items.len, st.chain_valid, st.head_hash },
    ) catch return writeJsonErr(cfd, 500, "Internal Server Error", "oom");
    defer allocator.free(body);
    net_http.writeHttpResponse(cfd, 200, "OK", "application/json", body) catch
        {};
}

fn handleGetMessages(
    allocator: std.mem.Allocator,
    cfd: i32,
    caller_cid: usize,
    query: []const u8,
    store_path: []const u8,
) void {
    const topic_q = extractQueryParam(query, "topic");
    if (topic_q) |t| {
        if (t.len > 0 and !store.isValidTopic(t)) {
            return writeJsonErr(cfd, 400, "Bad Request", "invalid_topic");
        }
    }
    const since_seq: u64 = if (extractQueryParam(query, "since")) |s|
        std.fmt.parseInt(u64, s, 10) catch 0
    else
        0;

    var st = store.loadStore(allocator, store_path) catch {
        return writeJsonErr(cfd, 500, "Internal Server Error", "load_failed");
    };
    defer st.deinit(allocator);
    const json_arr = store.formatVisibleJson(
        allocator,
        st.entries.items,
        caller_cid,
        topic_q,
        since_seq,
    ) catch return writeJsonErr(cfd, 500, "Internal Server Error", "oom");
    defer allocator.free(json_arr);
    net_http.writeHttpResponse(
        cfd,
        200,
        "OK",
        "application/json",
        json_arr,
    ) catch {};
}

fn handlePostMessage(
    allocator: std.mem.Allocator,
    cfd: i32,
    caller_cid: usize,
    req_body: []const u8,
    policy_path: []const u8,
    store_path: []const u8,
) void {
    const parsed = std.json.parseFromSlice(
        PostPayload,
        allocator,
        req_body,
        .{ .ignore_unknown_fields = true },
    ) catch return writeJsonErr(cfd, 400, "Bad Request", "invalid_json");
    defer parsed.deinit();

    const p = parsed.value;
    const rcpt = store.appendPost(
        allocator,
        policy_path,
        store_path,
        caller_cid,
        p.target_cid,
        p.topic,
        p.body,
    ) catch |err| {
        switch (err) {
            error.LateralMessagingDenied => writeJsonErr(
                cfd,
                403,
                "Forbidden",
                "lateral_messaging_denied",
            ),
            error.SenderMuted => writeJsonErr(
                cfd,
                403,
                "Forbidden",
                "sender_muted",
            ),
            error.TopicNotAllowed => writeJsonErr(
                cfd,
                403,
                "Forbidden",
                "topic_not_allowed",
            ),
            error.InvalidTopic => writeJsonErr(
                cfd,
                400,
                "Bad Request",
                "invalid_topic",
            ),
            error.EmptyBody => writeJsonErr(
                cfd,
                400,
                "Bad Request",
                "empty_body",
            ),
            error.BodyTooLarge => writeJsonErr(
                cfd,
                400,
                "Bad Request",
                "body_too_large",
            ),
            else => writeJsonErr(
                cfd,
                500,
                "Internal Server Error",
                "append_failed",
            ),
        }
        common.printFmt("[board] cid={d} target={d} POST rejected ({s})\n", .{
            caller_cid, p.target_cid, @errorName(err),
        });
        return;
    };

    const t_esc = common.escapeJsonAlloc(
        allocator,
        if (p.topic.len == 0) "general" else p.topic,
    ) catch return writeJsonErr(cfd, 500, "Internal Server Error", "oom");
    defer allocator.free(t_esc);
    const resp = allocator.print(
        "{{\"seq\":{d},\"ts\":{d},\"author_cid\":{d}," ++
            "\"target_cid\":{d},\"topic\":\"{s}\",\"hash\":\"{s}\"}}\n",
        .{
            rcpt.seq,
            rcpt.ts,
            rcpt.author_cid,
            rcpt.target_cid,
            t_esc,
            rcpt.hash,
        },
    ) catch return writeJsonErr(cfd, 500, "Internal Server Error", "oom");
    defer allocator.free(resp);
    net_http.writeHttpResponse(
        cfd,
        201,
        "Created",
        "application/json",
        resp,
    ) catch {};
}

pub fn handleBoardClient(
    allocator: std.mem.Allocator,
    cfd: i32,
    caller_cid: ?usize,
    policy_path: []const u8,
    store_path: []const u8,
) void {
    const cid = caller_cid orelse {
        return writeJsonErr(cfd, 403, "Forbidden", "peer_auth_failed");
    };
    const req = net_http.readHttpRequest(
        allocator,
        cfd,
        MAX_POST_REQ_BYTES,
    ) catch return writeJsonErr(cfd, 400, "Bad Request", "malformed_http");
    defer req.deinit(allocator);

    if (std.mem.eql(u8, req.method, "GET") and
        std.mem.eql(u8, req.path, "/v1/status"))
    {
        return handleGetStatus(allocator, cfd, cid, store_path);
    }
    if (std.mem.eql(u8, req.method, "GET") and
        std.mem.eql(u8, req.path, "/v1/messages"))
    {
        return handleGetMessages(allocator, cfd, cid, req.query, store_path);
    }
    if (std.mem.eql(u8, req.method, "POST") and
        std.mem.eql(u8, req.path, "/v1/messages"))
    {
        return handlePostMessage(
            allocator,
            cfd,
            cid,
            req.body,
            policy_path,
            store_path,
        );
    }
    writeJsonErr(cfd, 404, "Not Found", "unknown_endpoint");
}

pub fn runServer(port: u16, daemon: bool) !void {
    if (daemon) {
        if (net_http.isPidFileRunning(sysconfig.BOARD_PID_PATH) != null) return;
    }
    const listen_fd = try net_http.bindAndListenTcp(port);
    if (daemon) {
        const is_child = try net_http.daemonizeServer(
            listen_fd,
            sysconfig.BOARD_PID_PATH,
            sysconfig.BOARD_LOG_PATH,
        );
        if (!is_child) return;
    }
    defer _ = linux.close(listen_fd);

    const allocator = std.heap.page_allocator;
    while (true) {
        var peer: linux.sockaddr.in = undefined;
        var plen: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        const acc_s: isize = @bitCast(
            linux.accept4(
                listen_fd,
                @ptrCast(&peer),
                &plen,
                linux.SOCK.CLOEXEC,
            ),
        );
        if (acc_s == E_INTR) continue;
        if (acc_s < 0) continue;
        const cfd: i32 = @intCast(acc_s);
        defer _ = linux.close(cfd);

        const cid = net_http.resolvePeerChildCid(peer.addr);
        handleBoardClient(
            allocator,
            cfd,
            cid,
            sysconfig.BOARD_POLICY_PATH,
            sysconfig.BOARD_STORE_PATH,
        );
    }
}

test "board/server: query parser extracts topic and since cleanly" {
    std.testing.refAllDecls(@This());
    const t = std.testing;
    try t.expectEqualStrings(
        "ops",
        extractQueryParam("topic=ops&since=7", "topic").?,
    );
    try t.expectEqualStrings(
        "7",
        extractQueryParam("topic=ops&since=7", "since").?,
    );
    try t.expect(extractQueryParam("topic=ops", "since") == null);
}
