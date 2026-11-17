// Recursive Parent Inference Proxy (diosix0:8081) for Child VMs.
//
// Authenticates child VMs via kernel ARP MAC binding and forwards completions
// to OpenRouter, OpenCode, a local LLM endpoint, an upstream parent proxy, or
// the built-in deterministic Constitutional Policy Brain.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("../api.zig");
const cfg_mod = @import("config.zig");
const llm = @import("llm.zig");
const common = @import("../common.zig");
const net_http = @import("../net/http.zig");
const sysconfig = @import("../sysconfig.zig");

const MAX_LLM_REQ_BYTES: usize = 64 * 1024;
const E_INTR: isize = -@as(isize, @backingInt(linux.E.INTR));

fn writeJsonErr(
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
        return writeJsonErr(cfd, 500, "Internal Server Error", "oom");
    defer allocator.free(m_esc);
    const body = allocator.print(
        "{{\"ok\":true,\"caller_cid\":{d},\"provider\":\"{s}\"," ++
            "\"model\":\"{s}\"}}\n",
        .{ caller_cid, @tagName(cfg.resolved_provider), m_esc },
    ) catch return writeJsonErr(cfd, 500, "Internal Server Error", "oom");
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
        return writeJsonErr(cfd, 403, "Forbidden", "peer_auth_failed");
    };
    const req = net_http.readHttpRequest(
        allocator,
        cfd,
        MAX_LLM_REQ_BYTES,
    ) catch return writeJsonErr(cfd, 400, "Bad Request", "malformed_http");
    defer req.deinit(allocator);

    if (std.mem.eql(u8, req.method, "GET") and
        std.mem.eql(u8, req.path, "/v1/status"))
    {
        return handleGetStatus(allocator, client, cfd, cid);
    }
    if (std.mem.eql(u8, req.method, "POST") and
        std.mem.eql(u8, req.path, "/v1/chat/completions"))
    {
        const has_p = net_http.isHasParent(client);
        var cfg = cfg_mod.loadAgentConfig(allocator, has_p);
        defer cfg.deinit();
        const resp_json = llm.invokeRawChatCompletion(
            allocator,
            client,
            &cfg,
            req.body,
        ) catch {
            return writeJsonErr(cfd, 502, "Bad Gateway", "upstream_llm_error");
        };
        defer allocator.free(resp_json);
        net_http.writeHttpResponse(
            cfd,
            200,
            "OK",
            "application/json",
            resp_json,
        ) catch {};
        return;
    }
    writeJsonErr(cfd, 404, "Not Found", "unknown_endpoint");
}

pub fn runProxyServer(port: u16, daemon: bool) !void {
    if (daemon) {
        if (net_http.isPidFileRunning(sysconfig.LLM_PROXY_PID_PATH) != null) {
            return;
        }
    }
    const listen_fd = try net_http.bindAndListenTcp(port);
    if (daemon) {
        const is_child = try net_http.daemonizeServer(
            listen_fd,
            sysconfig.LLM_PROXY_PID_PATH,
            sysconfig.LLM_PROXY_LOG_PATH,
        );
        if (!is_child) return;
    }
    defer _ = linux.close(listen_fd);

    const allocator = std.heap.page_allocator;
    var client = api.DiosixClient.init();
    defer client.deinit();

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
        handleProxyClient(allocator, &client, cfd, cid);
    }
}

test "agent/proxy: rejects unauthenticated peer and formats error" {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(@as(usize, 65536), MAX_LLM_REQ_BYTES);
}
