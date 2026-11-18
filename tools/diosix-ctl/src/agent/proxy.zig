// Recursive Parent Inference Gateway (diosix0:8081 & 127.0.0.1:8081).
//
// Authenticates child VMs via kernel ARP MAC binding and delegates inference,
// quota accounting, and rate limiting to `gateway.zig` and `ledger.zig`.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("../api.zig");
const cfg_mod = @import("config.zig");
const common = @import("../common.zig");
const gateway = @import("gateway.zig");
const net_http = @import("../net/http.zig");
const sysconfig = @import("../sysconfig.zig");

const MAX_LLM_REQ_BYTES: usize = 64 * 1024;

fn handleGetStatus(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    cfd: i32,
    caller_cid: usize,
) void {
    const has_p = net_http.isHasParent(client);
    var cfg = cfg_mod.loadAgentConfig(allocator, has_p);
    defer cfg.deinit();
    const m_esc = common.escapeJsonAlloc(allocator, cfg.model()) catch
        return gateway.writeJsonErr(cfd, 500, "Internal Server Error", "oom");
    defer allocator.free(m_esc);
    const body = allocator.print(
        "{{\"ok\":true,\"caller_cid\":{d},\"provider\":\"{s}\"," ++
            "\"model\":\"{s}\"}}\n",
        .{ caller_cid, @tagName(cfg.resolved_provider), m_esc },
    ) catch
        return gateway.writeJsonErr(cfd, 500, "Internal Server Error", "oom");
    defer allocator.free(body);
    net_http.writeHttpResponse(cfd, 200, "OK", "application/json", body) catch
        {};
}

pub fn handleProxyClient(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    cfd: i32,
    caller_cid: ?usize,
) void {
    const cid = caller_cid orelse {
        return gateway.writeJsonErr(cfd, 403, "Forbidden", "peer_auth_failed");
    };
    const req = net_http.readHttpRequest(
        allocator,
        cfd,
        MAX_LLM_REQ_BYTES,
    ) catch
        return gateway.writeJsonErr(cfd, 400, "Bad Request", "malformed_http");
    defer req.deinit(allocator);

    if (std.mem.eql(u8, req.method, "GET") and
        std.mem.eql(u8, req.path, "/v1/status"))
    {
        return handleGetStatus(allocator, client, cfd, cid);
    }
    if (std.mem.eql(u8, req.method, "GET") and
        std.mem.eql(u8, req.path, "/v1/quota"))
    {
        return gateway.handleQuotaGet(allocator, client, cfd, cid);
    }
    if (std.mem.eql(u8, req.method, "POST") and
        std.mem.eql(u8, req.path, "/v1/infer"))
    {
        return gateway.handleInferPost(allocator, client, cfd, cid, req.body);
    }
    if (std.mem.eql(u8, req.method, "POST") and
        std.mem.eql(u8, req.path, "/v1/chat/completions"))
    {
        return gateway.handleLegacyChatPost(
            allocator,
            client,
            cfd,
            cid,
            req.body,
        );
    }
    gateway.writeJsonErr(cfd, 404, "Not Found", "unknown_endpoint");
}

pub fn runProxyServer(port: u16, daemon: bool) !void {
    if (daemon) {
        if (net_http.isPidFileRunning(sysconfig.LLM_PROXY_PID_PATH) != null) {
            return;
        }
    }
    const listener = try net_http.DownstreamListener.open(port);
    if (daemon) {
        const is_child = try net_http.daemonizeDualServer(
            listener.lo_fd,
            listener.br_fd,
            sysconfig.LLM_PROXY_PID_PATH,
            sysconfig.LLM_PROXY_LOG_PATH,
        );
        if (!is_child) return;
    }
    defer listener.close();

    const allocator = std.heap.page_allocator;
    var client = api.DiosixClient.init();
    defer client.deinit();

    while (true) {
        const acc = listener.accept(35) orelse continue;
        defer _ = linux.close(acc.cfd);
        handleProxyClient(allocator, &client, acc.cfd, acc.caller_cid);
    }
}

test "agent/proxy: exports gateway endpoint constants and handlers" {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(@as(usize, 65536), MAX_LLM_REQ_BYTES);
}
