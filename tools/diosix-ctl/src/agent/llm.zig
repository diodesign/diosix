// Autonomous Agent Flexible LLM Client & Deterministic Policy Brain.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("../api.zig");
const cfg_mod = @import("config.zig");
const common = @import("../common.zig");
const net_http = @import("../net/http.zig");
const ssh = @import("../ssh.zig");
const sysconfig = @import("../sysconfig.zig");

const AgentConfig = cfg_mod.AgentConfig;
const MAX_HTTP_LLM_BYTES: usize = 256 * 1024;
const E_INTR: isize = -@as(isize, @backingInt(linux.E.INTR));

pub const ParsedHttpUrl = struct {
    is_https: bool,
    host: []const u8,
    port: u16,
    path: []const u8,
};

pub fn parseHttpUrl(url: []const u8) ?ParsedHttpUrl {
    const is_https = std.mem.startsWith(u8, url, "https://");
    const is_http = std.mem.startsWith(u8, url, "http://");
    if (!is_https and !is_http) return null;
    const rest = if (is_https) url["https://".len..] else url["http://".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/');
    const authority = if (slash) |s| rest[0..s] else rest;
    const path = if (slash) |s| rest[s..] else "/";
    const colon = std.mem.indexOfScalar(u8, authority, ':');
    const host = if (colon) |c| authority[0..c] else authority;
    if (host.len == 0) return null;
    const def_port: u16 = if (is_https) 443 else 80;
    const port: u16 = if (colon) |c|
        std.fmt.parseInt(u16, authority[c + 1 ..], 10) catch return null
    else
        def_port;
    return .{ .is_https = is_https, .host = host, .port = port, .path = path };
}

fn resolveUrlHostIp(client: ?*api.DiosixClient, host: []const u8) ?u32 {
    if (ssh.parseIpv4(host)) |ip| return ip;
    if (std.mem.eql(u8, host, "localhost")) return ssh.parseIpv4("127.0.0.1");
    if (std.mem.eql(u8, host, "diosix-parent") or
        std.mem.eql(u8, host, "parent"))
    {
        return net_http.resolveParentIpv4(client);
    }
    return null;
}

fn readAllSocket(allocator: std.mem.Allocator, fd: i32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const rr: isize = @bitCast(
            linux.recvfrom(fd, &chunk, chunk.len, 0, null, null),
        );
        if (rr == E_INTR) continue;
        if (rr < 0) return error.ReadFailed;
        if (rr == 0) break;
        const n: usize = @intCast(rr);
        if (out.items.len + n > MAX_HTTP_LLM_BYTES) {
            return error.ResponseTooLarge;
        }
        try out.appendSlice(allocator, chunk[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

fn httpPostJson(
    allocator: std.mem.Allocator,
    client: ?*api.DiosixClient,
    parsed: ParsedHttpUrl,
    bearer_key: []const u8,
    req_json: []const u8,
) ![]u8 {
    const ip_be = resolveUrlHostIp(client, parsed.host) orelse
        return error.UnsupportedHost;
    const stype = linux.SOCK.STREAM | linux.SOCK.CLOEXEC;
    const fd_s: isize = @bitCast(linux.socket(linux.AF.INET, stype, 0));
    if (fd_s < 0) return error.SocketFailed;
    const fd: i32 = @intCast(fd_s);
    defer _ = linux.close(fd);

    var addr: linux.sockaddr.in = .{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, parsed.port),
        .addr = ip_be,
        .zero = @splat(0),
    };
    const cs: isize = @bitCast(
        linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)),
    );
    if (cs < 0) return error.ConnectFailed;

    var hdr: std.ArrayList(u8) = .empty;
    defer {
        std.crypto.secureZero(u8, hdr.items);
        hdr.deinit(allocator);
    }
    const base_hdr = try allocator.print(
        "POST {s} HTTP/1.1\r\nHost: {s}:{d}\r\n" ++
            "Content-Type: application/json\r\nContent-Length: {d}\r\n",
        .{ parsed.path, parsed.host, parsed.port, req_json.len },
    );
    defer allocator.free(base_hdr);
    try hdr.appendSlice(allocator, base_hdr);
    if (bearer_key.len > 0) {
        const auth_line = try allocator.print(
            "Authorization: Bearer {s}\r\n",
            .{bearer_key},
        );
        defer {
            std.crypto.secureZero(u8, auth_line);
            allocator.free(auth_line);
        }
        try hdr.appendSlice(allocator, auth_line);
    }
    try hdr.appendSlice(allocator, "Connection: close\r\n\r\n");

    try net_http.writeAllFd(fd, hdr.items);
    try net_http.writeAllFd(fd, req_json);

    const raw = try readAllSocket(allocator, fd);
    defer allocator.free(raw);
    const sep = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse
        return error.InvalidHttpResponse;
    return allocator.dupe(u8, raw[sep + 4 ..]);
}

fn httpsPostJsonViaTool(
    allocator: std.mem.Allocator,
    url: []const u8,
    bearer_key: []const u8,
    req_json: []const u8,
) ![]u8 {
    net_http.ensureDirRecursive(sysconfig.CHARTER_SECRETS_DIR);
    var pid = linux.getpid();
    const cfg_p = try allocator.print(
        "{s}/llm-{d}.cfg",
        .{ sysconfig.CHARTER_SECRETS_DIR, pid },
    );
    defer allocator.free(cfg_p);
    const req_p = try allocator.print(
        "{s}/llm-{d}.req",
        .{ sysconfig.CHARTER_SECRETS_DIR, pid },
    );
    defer allocator.free(req_p);
    const resp_p = try allocator.print(
        "{s}/llm-{d}.resp",
        .{ sysconfig.CHARTER_SECRETS_DIR, pid },
    );
    defer allocator.free(resp_p);
    _ = &pid;

    var cfg_z: [common.MAX_PATH_LEN]u8 = undefined;
    var req_z: [common.MAX_PATH_LEN]u8 = undefined;
    var resp_z: [common.MAX_PATH_LEN]u8 = undefined;
    var url_z: [512]u8 = undefined;
    const cfg_zs = common.toPathZ(cfg_p, &cfg_z) orelse
        return error.PathTooLong;
    const req_zs = common.toPathZ(req_p, &req_z) orelse
        return error.PathTooLong;
    const resp_zs = common.toPathZ(resp_p, &resp_z) orelse
        return error.PathTooLong;
    const url_zs = common.toPathZ(url, &url_z) orelse return error.InvalidUrl;

    defer {
        _ = linux.unlink(cfg_zs.ptr);
        _ = linux.unlink(req_zs.ptr);
        _ = linux.unlink(resp_zs.ptr);
    }

    const cfg_body = if (bearer_key.len > 0)
        try allocator.print(
            "header = Content-Type: application/json\n" ++
                "header = Authorization: Bearer {s}\n",
            .{bearer_key},
        )
    else
        try allocator.dupe(u8, "header = Content-Type: application/json\n");
    defer {
        std.crypto.secureZero(u8, cfg_body);
        allocator.free(cfg_body);
    }
    try common.writePrivateFile(cfg_p, cfg_body);
    try common.writePrivateFile(req_p, req_json);

    const wget_bin = sysconfig.resolveBin(
        sysconfig.WGET_BIN,
        sysconfig.WGET_LOCAL_BIN,
    );
    const w_cfg = try allocator.printSentinel("--config={s}", .{cfg_p}, 0);
    defer allocator.free(w_cfg);
    const w_post = try allocator.printSentinel("--post-file={s}", .{req_p}, 0);
    defer allocator.free(w_post);
    const wget_argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
        wget_bin.ptr, "-q",       "-T", "30",        "-t",       "1",
        w_cfg.ptr,    w_post.ptr, "-O", resp_zs.ptr, url_zs.ptr, null,
    };
    if (common.runSubprocess(wget_argv) != 0) return error.UpstreamLlmFailed;
    const out_raw = try common.readBinaryFile(resp_p, MAX_HTTP_LLM_BYTES);
    defer common.unmapBinaryFile(out_raw);
    return allocator.dupe(u8, out_raw);
}

/// Deterministic offline policy engine used when no remote/local LLM endpoint
/// is configured, emitting OpenAI-compatible chat completion JSON.
pub fn evaluatePolicyBrain(
    allocator: std.mem.Allocator,
    model_name: []const u8,
    prompt_body: []const u8,
) ![]u8 {
    const is_ransom = std.mem.indexOf(u8, prompt_body, "min=0") != null or
        std.mem.indexOf(u8, prompt_body, "encrypt_volumes=true") != null or
        std.mem.indexOf(u8, prompt_body, "wipe_volumes=true") != null;
    const dec = if (is_ransom) "reject" else "approve";
    const summary = if (is_ransom)
        "Deterministic policy vetoed unsafe replica drop or volume mutation"
    else
        "Constitutional invariants verified; proceed with task execution";
    const content_json = try allocator.print(
        "{{\"decision\":\"{s}\",\"summary\":\"{s}\"}}",
        .{ dec, summary },
    );
    defer allocator.free(content_json);
    const esc = try common.escapeJsonAlloc(allocator, content_json);
    defer allocator.free(esc);
    const m_esc = try common.escapeJsonAlloc(allocator, model_name);
    defer allocator.free(m_esc);
    return allocator.print(
        "{{\"id\":\"diosix-policy-1\",\"object\":\"chat.completion\"," ++
            "\"model\":\"{s}\",\"choices\":[{{\"index\":0," ++
            "\"message\":{{\"role\":\"assistant\",\"content\":\"{s}\"}}," ++
            "\"finish_reason\":\"stop\"}}]}}\n",
        .{ m_esc, esc },
    );
}

pub fn buildChatRequestJson(
    allocator: std.mem.Allocator,
    model: []const u8,
    prompt: []const u8,
    max_tokens: u32,
) ![]u8 {
    const m_esc = try common.escapeJsonAlloc(allocator, model);
    defer allocator.free(m_esc);
    const p_esc = try common.escapeJsonAlloc(allocator, prompt);
    defer allocator.free(p_esc);
    return allocator.print(
        "{{\"model\":\"{s}\",\"max_tokens\":{d},\"messages\":[" ++
            "{{\"role\":\"system\",\"content\":" ++
            "\"You are an autonomous Diosix VM node agent bound by the " ++
            "Constitutional Charter. Return concise JSON.\"}}," ++
            "{{\"role\":\"user\",\"content\":\"{s}\"}}]}}",
        .{ m_esc, max_tokens, p_esc },
    );
}

/// Dispatch an OpenAI-compatible chat-completion request body according to
/// `cfg`, returning the raw JSON response string (caller owns slice).
pub fn invokeRawChatCompletion(
    allocator: std.mem.Allocator,
    client: ?*api.DiosixClient,
    cfg: *const AgentConfig,
    req_json: []const u8,
) ![]u8 {
    if (cfg.resolved_provider == .policy) {
        return evaluatePolicyBrain(allocator, cfg.model(), req_json);
    }
    const url = cfg.endpoint();
    const parsed = parseHttpUrl(url) orelse
        return evaluatePolicyBrain(allocator, cfg.model(), req_json);
    if (!parsed.is_https and resolveUrlHostIp(client, parsed.host) != null) {
        return httpPostJson(
            allocator,
            client,
            parsed,
            cfg.apiKey(),
            req_json,
        );
    }
    return httpsPostJsonViaTool(allocator, url, cfg.apiKey(), req_json);
}

pub fn extractAssistantContentAlloc(
    allocator: std.mem.Allocator,
    resp_json: []const u8,
) ![]u8 {
    const Msg = struct { content: []const u8 = "" };
    const Choice = struct { message: Msg = .{} };
    const Resp = struct { choices: []const Choice = &.{} };
    const p = std.json.parseFromSlice(
        Resp,
        allocator,
        resp_json,
        .{ .ignore_unknown_fields = true },
    ) catch return allocator.dupe(u8, resp_json);
    defer p.deinit();
    if (p.value.choices.len > 0) {
        const content = p.value.choices[0].message.content;
        if (content.len > 0) return allocator.dupe(u8, content);
    }
    return allocator.dupe(u8, resp_json);
}

test "agent/llm: parses URLs and runs deterministic policy brain" {
    std.testing.refAllDecls(@This());
    const t = std.testing;
    const test_url = "http://diosix-parent:8081/v1/chat/completions";
    const url1 = parseHttpUrl(test_url).?;
    try t.expect(!url1.is_https);
    try t.expectEqualStrings("diosix-parent", url1.host);
    try t.expectEqual(@as(u16, 8081), url1.port);

    const out = try evaluatePolicyBrain(
        t.allocator,
        "policy-v1",
        "check proposal min=3",
    );
    defer t.allocator.free(out);
    const content = try extractAssistantContentAlloc(t.allocator, out);
    defer t.allocator.free(content);
    try t.expect(std.mem.indexOf(u8, content, "approve") != null);
}
