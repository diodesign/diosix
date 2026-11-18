// Shared Peer-CID Authentication, HTTP/1.1 Transport, and Daemon Helpers.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("../api.zig");
const common = @import("../common.zig");
const ssh = @import("../ssh.zig");
pub const peer = @import("http/peer.zig");

const MAX_HEADER_BYTES: usize = 16 * 1024;
const IO_CHUNK_BYTES: usize = 8192;
const CLIENT_TIMEOUT_SEC: i64 = 35;
const E_INTR: isize = -@as(isize, @backingInt(linux.E.INTR));

pub const setSocketTimeouts = peer.setSocketTimeouts;
pub const formatIpv4 = peer.formatIpv4;
pub const parseArpChildCid = peer.parseArpChildCid;
pub const isArpPeerOnDev = peer.isArpPeerOnDev;
pub const resolvePeerChildCid = peer.resolvePeerChildCid;
pub const isPeerFromDiosixBridge = peer.isPeerFromDiosixBridge;
pub const parseHostsIpv4 = peer.parseHostsIpv4;
pub const resolveParentIpv4 = peer.resolveParentIpv4;
pub const isHasParent = peer.isHasParent;
pub const ensureDirRecursive = peer.ensureDirRecursive;
pub const ensureParentDir = peer.ensureParentDir;
pub const bindAndListenTcp = peer.bindAndListenTcp;
pub const DownstreamListener = peer.DownstreamListener;
pub const isPidFileRunning = peer.isPidFileRunning;
pub const daemonizeDualServer = peer.daemonizeServer;

pub fn daemonizeServer(
    listen_fd: i32,
    pid_path: []const u8,
    log_path: []const u8,
) !bool {
    return peer.daemonizeServer(listen_fd, -1, pid_path, log_path);
}

pub const HttpRequest = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    body: []const u8,
    raw_buf: []u8,

    pub fn deinit(self: *const HttpRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.raw_buf);
    }
};

fn parseHeaderContentLength(headers: []const u8) !?usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = common.trimWhitespace(line[0..colon]);
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            const val = common.trimWhitespace(line[colon + 1 ..]);
            const parsed = std.fmt.parseInt(usize, val, 10) catch
                return error.InvalidHttpHeader;
            return parsed;
        }
    }
    return null;
}

pub fn parseHttpRequestBuffer(
    raw_buf: []u8,
    hdr_end: usize,
    content_len: usize,
) !HttpRequest {
    const hdr_bytes = raw_buf[0..hdr_end];
    const line_end = std.mem.indexOf(u8, hdr_bytes, "\r\n") orelse
        hdr_bytes.len;
    var parts = std.mem.tokenizeScalar(u8, hdr_bytes[0..line_end], ' ');
    const method = parts.next() orelse return error.InvalidHttpRequest;
    const target = parts.next() orelse return error.InvalidHttpRequest;
    const qmark = std.mem.indexOfScalar(u8, target, '?');
    const path = if (qmark) |qi| target[0..qi] else target;
    const query = if (qmark) |qi| target[qi + 1 ..] else "";
    const body_start = hdr_end + 4;
    if (raw_buf.len < body_start + content_len) return error.TruncatedHttpBody;
    return .{
        .method = method,
        .path = path,
        .query = query,
        .body = raw_buf[body_start .. body_start + content_len],
        .raw_buf = raw_buf,
    };
}

const HttpRawFrame = struct {
    buf: []u8,
    hdr_end: usize,
    content_len_opt: ?usize,
};

fn readHttpFrame(
    allocator: std.mem.Allocator,
    fd: i32,
    max_body: usize,
    default_zero_cl: bool,
) !HttpRawFrame {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var chunk: [IO_CHUNK_BYTES]u8 = undefined;
    var hdr_end_opt: ?usize = null;
    var cl_opt: ?usize = null;
    const cap = std.math.add(usize, max_body, MAX_HEADER_BYTES) catch
        std.math.maxInt(usize);

    while (true) {
        if (hdr_end_opt) |hend| {
            if (cl_opt) |cl| {
                const need = std.math.add(usize, hend + 4, cl) catch
                    return error.BodyTooLarge;
                if (buf.items.len >= need) break;
            }
        } else if (buf.items.len > MAX_HEADER_BYTES) {
            return error.HeadersTooLarge;
        }
        const rs: isize = @bitCast(
            linux.recvfrom(fd, &chunk, chunk.len, 0, null, null),
        );
        if (rs == E_INTR) continue;
        if (rs < 0) return error.ReadFailed;
        if (rs == 0) break;
        const rlen: usize = @intCast(rs);
        if (buf.items.len + rlen > cap) return error.ResponseTooLarge;
        try buf.appendSlice(allocator, chunk[0..rlen]);
        if (hdr_end_opt == null) {
            if (std.mem.indexOf(u8, buf.items, "\r\n\r\n")) |hend| {
                hdr_end_opt = hend;
                if (try parseHeaderContentLength(buf.items[0..hend])) |cl| {
                    if (cl > max_body) return error.BodyTooLarge;
                    cl_opt = cl;
                } else if (default_zero_cl) {
                    cl_opt = 0;
                }
            }
        }
    }
    const hend = hdr_end_opt orelse return error.InvalidHttpRequest;
    return .{
        .buf = try buf.toOwnedSlice(allocator),
        .hdr_end = hend,
        .content_len_opt = cl_opt,
    };
}

pub fn readHttpRequest(
    allocator: std.mem.Allocator,
    fd: i32,
    max_body: usize,
) !HttpRequest {
    const f = try readHttpFrame(allocator, fd, max_body, true);
    errdefer allocator.free(f.buf);
    return parseHttpRequestBuffer(f.buf, f.hdr_end, f.content_len_opt orelse 0);
}

pub fn writeAllFd(fd: i32, data: []const u8) !void {
    var sent: usize = 0;
    while (sent < data.len) {
        const rc = linux.sendto(
            fd,
            data.ptr + sent,
            data.len - sent,
            linux.MSG.NOSIGNAL,
            null,
            0,
        );
        const s_rc: isize = @bitCast(rc);
        if (s_rc == E_INTR) continue;
        if (s_rc <= 0) return error.WriteFailed;
        sent += @intCast(s_rc);
    }
}

pub fn writeHttpResponse(
    fd: i32,
    status: u16,
    reason: []const u8,
    content_type: []const u8,
    body: []const u8,
) !void {
    var hdr_buf: [512]u8 = undefined;
    const hdr = std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\n" ++
            "Content-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, reason, content_type, body.len },
    ) catch return error.HeadersTooLarge;
    try writeAllFd(fd, hdr);
    if (body.len > 0) try writeAllFd(fd, body);
}

pub const HttpResponse = struct {
    status: u16,
    body: []u8,

    pub fn deinit(
        self: *const HttpResponse,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.body);
    }
};

pub fn httpClientRequest(
    allocator: std.mem.Allocator,
    ip_be: u32,
    port: u16,
    method: []const u8,
    path: []const u8,
    content_type: ?[]const u8,
    req_body: []const u8,
    max_resp: usize,
) !HttpResponse {
    const stype = linux.SOCK.STREAM | linux.SOCK.CLOEXEC;
    const fd_s: isize = @bitCast(linux.socket(linux.AF.INET, stype, 0));
    if (fd_s < 0) return error.SocketFailed;
    const fd: i32 = @intCast(fd_s);
    defer _ = linux.close(fd);
    setSocketTimeouts(fd, CLIENT_TIMEOUT_SEC);
    var addr: linux.sockaddr.in = .{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = ip_be,
        .zero = @splat(0),
    };
    const cs: isize = @bitCast(
        linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)),
    );
    if (cs < 0) return error.ConnectFailed;

    var host_buf: [16]u8 = undefined;
    const host_ip = formatIpv4(ip_be, &host_buf);
    const ct = content_type orelse "application/octet-stream";
    const req_hdr = if (req_body.len > 0)
        try allocator.print(
            "{s} {s} HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: {s}\r\n" ++
                "Content-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ method, path, host_ip, port, ct, req_body.len },
        )
    else
        try allocator.print(
            "{s} {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n",
            .{ method, path, host_ip, port },
        );
    defer allocator.free(req_hdr);
    try writeAllFd(fd, req_hdr);
    if (req_body.len > 0) try writeAllFd(fd, req_body);

    const frame = readHttpFrame(allocator, fd, max_resp, false) catch |e| {
        return if (e == error.InvalidHttpRequest)
            error.InvalidHttpResponse
        else
            e;
    };
    defer allocator.free(frame.buf);
    const le = std.mem.indexOf(u8, frame.buf[0..frame.hdr_end], "\r\n") orelse
        frame.hdr_end;
    var tok = std.mem.tokenizeScalar(u8, frame.buf[0..le], ' ');
    _ = tok.next() orelse return error.InvalidHttpResponse;
    const st_str = tok.next() orelse return error.InvalidHttpResponse;
    const st = std.fmt.parseInt(u16, st_str, 10) catch
        return error.InvalidHttpResponse;
    const raw_body = frame.buf[frame.hdr_end + 4 ..];
    const end_idx: usize = if (frame.content_len_opt) |cl|
        @min(raw_body.len, cl)
    else
        raw_body.len;
    return .{
        .status = st,
        .body = try allocator.dupe(u8, raw_body[0..end_idx]),
    };
}

test "net/http: ARP MAC-to-CID, /etc/hosts, and HTTP framing" {
    _ = peer;
    std.testing.refAllDecls(@This());
    const t = std.testing;
    const arp =
        \\IP address HW type Flags HW address Mask Device
        \\10.0.2.2 0x1 0x2 52:54:00:12:35:02 * eth0
        \\10.0.3.2 0x1 0x6 02:00:00:00:00:02 * diosix0
        \\10.0.3.3 0x1 0x0 02:00:00:00:00:03 * diosix0
        \\10.0.3.99 0x1 0x2 02:00:00:00:01:02 * diosix0
    ;
    try t.expectEqual(@as(?usize, 2), parseArpChildCid(arp, "10.0.3.2"));
    try t.expectEqual(@as(?usize, null), parseArpChildCid(arp, "10.0.3.3"));
    try t.expectEqual(@as(?usize, null), parseArpChildCid(arp, "10.0.2.2"));
    try t.expectEqual(@as(?usize, 258), parseArpChildCid(arp, "10.0.3.99"));
    const hosts =
        \\127.0.0.1 localhost
        \\# comment 10.9.9.9 diosix-parent
        \\10.0.4.1 diosix-parent parent
    ;
    try t.expectEqual(
        ssh.parseIpv4("10.0.4.1"),
        parseHostsIpv4(hosts, "diosix-parent"),
    );
    const req_s = "GET /v1/messages?topic=ops&since=4 HTTP/1.1\r\n" ++
        "Content-Length: 2\r\n\r\nhi";
    const hend = std.mem.indexOf(u8, req_s, "\r\n\r\n").?;
    const raw = try t.allocator.dupe(u8, req_s);
    const parsed = try parseHttpRequestBuffer(raw, hend, 2);
    defer parsed.deinit(t.allocator);
    try t.expectEqualStrings("GET", parsed.method);
    try t.expectEqualStrings("/v1/messages", parsed.path);
    try t.expectEqualStrings("topic=ops&since=4", parsed.query);
    try t.expectEqualStrings("hi", parsed.body);
}
