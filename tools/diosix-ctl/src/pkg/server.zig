// Recursive Attenuating Alpine APK HTTP Proxy Server.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("../api.zig");
const common = @import("../common.zig");
const image = @import("../image.zig");
const net_http = @import("../net/http.zig");
const sysconfig = @import("../sysconfig.zig");
const index = @import("index.zig");
const policy = @import("policy.zig");

const MAX_HTTP_REQ_BODY: usize = 4096;
const MAX_APK_ARTIFACT_BYTES: usize = 64 * 1024 * 1024;
const E_INTR: isize = -@as(isize, @backingInt(linux.E.INTR));

pub const RepoPath = struct {
    branch: []const u8,
    repo: []const u8,
    arch: []const u8,
    file: []const u8,
};

pub fn parseRepoPath(url_path: []const u8) ?RepoPath {
    const trimmed = std.mem.trimStart(u8, url_path, "/");
    var it = std.mem.splitScalar(u8, trimmed, '/');
    const branch = it.next() orelse return null;
    const repo = it.next() orelse return null;
    const arch = it.next() orelse return null;
    const file = it.next() orelse return null;
    if (it.next() != null) return null;
    if (!index.isSafeRepoSegment(branch) or
        !index.isSafeRepoSegment(repo) or
        !index.isSafeRepoSegment(arch) or
        !index.isSafeRepoSegment(file))
    {
        return null;
    }
    const is_idx = std.mem.eql(u8, file, "APKINDEX.tar.gz");
    if (!is_idx and index.parseApkFilenamePkgName(file) == null) return null;
    return .{ .branch = branch, .repo = repo, .arch = arch, .file = file };
}

fn joinRepoPath(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    rp: RepoPath,
) ![]u8 {
    return allocator.print(
        "{s}/{s}/{s}/{s}/{s}",
        .{ base_dir, rp.branch, rp.repo, rp.arch, rp.file },
    );
}

pub fn ensureRepoArtifact(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    rp: RepoPath,
    force_refresh: bool,
    port: u16,
) ![]u8 {
    const cache_path = try joinRepoPath(
        allocator,
        sysconfig.DEFAULT_PKG_CACHE_DIR,
        rp,
    );
    errdefer allocator.free(cache_path);

    if (!force_refresh) {
        var cz_buf: [common.MAX_PATH_LEN]u8 = undefined;
        if (common.toPathZ(cache_path, &cz_buf)) |cz| {
            if (common.fileExistsPath(cz.ptr)) return cache_path;
        }
        const seed_path = try joinRepoPath(
            allocator,
            sysconfig.DEFAULT_APK_SEED_DIR,
            rp,
        );
        var sz_buf: [common.MAX_PATH_LEN]u8 = undefined;
        if (common.toPathZ(seed_path, &sz_buf)) |sz| {
            if (common.fileExistsPath(sz.ptr)) {
                allocator.free(cache_path);
                return seed_path;
            }
        }
        allocator.free(seed_path);
    }

    net_http.ensureParentDir(cache_path);
    const part_z = try allocator.printSentinel("{s}.part", .{cache_path}, 0);
    defer allocator.free(part_z);
    if (part_z.len >= common.MAX_PATH_LEN) return error.PathTooLong;
    var cache_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const cache_z = common.toPathZ(cache_path, &cache_z_buf) orelse
        return error.PathTooLong;

    if (net_http.isHasParent(client)) {
        const parent_ip = net_http.resolveParentIpv4(client);
        const req_path = try allocator.print(
            "/{s}/{s}/{s}/{s}",
            .{ rp.branch, rp.repo, rp.arch, rp.file },
        );
        defer allocator.free(req_path);
        const resp = try net_http.httpClientRequest(
            allocator,
            parent_ip,
            port,
            "GET",
            req_path,
            null,
            "",
            MAX_APK_ARTIFACT_BYTES,
        );
        defer resp.deinit(allocator);
        if (resp.status == 403) return error.UpstreamForbidden;
        if (resp.status == 404) return error.FileNotFound;
        if (resp.status != 200) return error.UpstreamFailed;
        common.writeFile(part_z, resp.body) catch |werr| {
            _ = linux.unlink(part_z.ptr);
            return werr;
        };
    } else {
        const url = try allocator.print(
            "{s}/{s}/{s}/{s}/{s}",
            .{
                sysconfig.ALPINE_CDN_BASE_URL,
                rp.branch,
                rp.repo,
                rp.arch,
                rp.file,
            },
        );
        defer allocator.free(url);
        image.fetchRemoteFile(url, part_z.ptr) catch {
            _ = linux.unlink(part_z.ptr);
            return error.DownloadFailed;
        };
    }

    const rn: isize = @bitCast(linux.rename(part_z.ptr, cache_z.ptr));
    if (rn < 0) {
        _ = linux.unlink(part_z.ptr);
        return error.RenameFailed;
    }
    return cache_path;
}

fn checkChildPkgAccess(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    caller_cid: usize,
    rp: RepoPath,
    port: u16,
) !bool {
    if (caller_cid < common.CID_FIRST_CHILD) return true;
    const pkg_name = index.parseApkFilenamePkgName(rp.file) orelse return true;

    var self_pol = try policy.loadGuestManifestPolicy(
        allocator,
        client,
        common.CID_SELF,
    );
    defer self_pol.deinit(allocator);
    var child_pol = try policy.loadGuestManifestPolicy(
        allocator,
        client,
        caller_cid,
    );
    defer child_pol.deinit(allocator);

    var graph_opt: ?index.ApkGraph = null;
    defer if (graph_opt) |*g| g.deinit(allocator);

    const idx_rp = RepoPath{
        .branch = rp.branch,
        .repo = rp.repo,
        .arch = rp.arch,
        .file = "APKINDEX.tar.gz",
    };
    if (ensureRepoArtifact(allocator, client, idx_rp, false, port)) |idx_p| {
        defer allocator.free(idx_p);
        if (common.readBinaryFile(idx_p, MAX_APK_ARTIFACT_BYTES)) |gz| {
            defer common.unmapBinaryFile(gz);
            if (index.extractApkIndexFromTarGz(allocator, gz)) |raw_idx| {
                defer allocator.free(raw_idx);
                graph_opt = index.ApkGraph.parse(allocator, raw_idx) catch null;
            } else |_| {}
        } else |_| {}
    } else |_| {}

    const g_ptr: ?*const index.ApkGraph = if (graph_opt) |*g| g else null;
    return index.isPackagePermitted(
        allocator,
        g_ptr,
        &self_pol,
        &child_pol,
        pkg_name,
    );
}

fn handlePkgClient(
    allocator: std.mem.Allocator,
    client: *api.DiosixClient,
    cfd: i32,
    caller_cid: ?usize,
    port: u16,
) void {
    const cid = caller_cid orelse {
        net_http.writeHttpResponse(
            cfd,
            403,
            "Forbidden",
            "text/plain",
            "Peer CID authentication failed\n",
        ) catch {};
        return;
    };
    const req = net_http.readHttpRequest(
        allocator,
        cfd,
        MAX_HTTP_REQ_BODY,
    ) catch {
        net_http.writeHttpResponse(
            cfd,
            400,
            "Bad Request",
            "text/plain",
            "Malformed HTTP request\n",
        ) catch {};
        return;
    };
    defer req.deinit(allocator);

    const is_get = std.mem.eql(u8, req.method, "GET");
    const is_head = std.mem.eql(u8, req.method, "HEAD");
    if (!is_get and !is_head) {
        net_http.writeHttpResponse(
            cfd,
            405,
            "Method Not Allowed",
            "text/plain",
            "Only GET and HEAD are supported\n",
        ) catch {};
        return;
    }
    if (std.mem.eql(u8, req.path, "/healthz")) {
        const body = if (is_head) "" else "{\"ok\":true}\n";
        net_http.writeHttpResponse(
            cfd,
            200,
            "OK",
            "application/json",
            body,
        ) catch {};
        return;
    }

    const rp = parseRepoPath(req.path) orelse {
        net_http.writeHttpResponse(
            cfd,
            404,
            "Not Found",
            "text/plain",
            "Unknown APK repository path\n",
        ) catch {};
        return;
    };

    const allowed = checkChildPkgAccess(allocator, client, cid, rp, port) catch
        false;
    if (!allowed) {
        common.printFmt("[pkg] cid={d} {s} {s} -> 403\n", .{
            cid, req.method, req.path,
        });
        net_http.writeHttpResponse(
            cfd,
            403,
            "Forbidden",
            "text/plain",
            "Package denied by parent policy\n",
        ) catch {};
        return;
    }

    const art_path = ensureRepoArtifact(
        allocator,
        client,
        rp,
        false,
        port,
    ) catch |err| {
        const st: u16 = switch (err) {
            error.UpstreamForbidden => 403,
            error.FileNotFound, error.DownloadFailed => 404,
            else => 502,
        };
        const rsn = switch (st) {
            403 => "Forbidden",
            404 => "Not Found",
            else => "Bad Gateway",
        };
        common.printFmt("[pkg] cid={d} {s} {s} -> {d}\n", .{
            cid, req.method, req.path, st,
        });
        net_http.writeHttpResponse(
            cfd,
            st,
            rsn,
            "text/plain",
            "Package unavailable\n",
        ) catch {};
        return;
    };
    defer allocator.free(art_path);

    const data = common.readBinaryFile(art_path, MAX_APK_ARTIFACT_BYTES) catch {
        net_http.writeHttpResponse(
            cfd,
            404,
            "Not Found",
            "text/plain",
            "Artifact unreadable\n",
        ) catch {};
        return;
    };
    defer common.unmapBinaryFile(data);

    const payload = if (is_head) "" else data;
    common.printFmt("[pkg] cid={d} {s} {s} -> 200 ({d}B)\n", .{
        cid, req.method, req.path, data.len,
    });
    net_http.writeHttpResponse(
        cfd,
        200,
        "OK",
        "application/octet-stream",
        payload,
    ) catch {};
}

pub fn runServer(client: *api.DiosixClient, port: u16, daemon: bool) !void {
    if (daemon) {
        if (net_http.isPidFileRunning(sysconfig.PKG_PROXY_PID_PATH) != null) {
            return;
        }
    }
    const listen_fd = try net_http.bindAndListenTcp(port);
    if (daemon) {
        const is_child = try net_http.daemonizeServer(
            listen_fd,
            sysconfig.PKG_PROXY_PID_PATH,
            sysconfig.PKG_PROXY_LOG_PATH,
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

        const caller_cid = net_http.resolvePeerChildCid(peer.addr);
        handlePkgClient(allocator, client, cfd, caller_cid, port);
    }
}

test "pkg/server: parseRepoPath validation and path traversal defense" {
    std.testing.refAllDecls(@This());
    const t = std.testing;

    const rp1 = parseRepoPath("/v3.24/main/riscv64/APKINDEX.tar.gz").?;
    try t.expectEqualStrings("v3.24", rp1.branch);
    try t.expectEqualStrings("main", rp1.repo);
    try t.expectEqualStrings("riscv64", rp1.arch);
    try t.expectEqualStrings("APKINDEX.tar.gz", rp1.file);

    const rp2 = parseRepoPath("/v3.24/main/riscv64/doas-6.8.2-r8.apk").?;
    try t.expectEqualStrings("doas-6.8.2-r8.apk", rp2.file);

    try t.expect(parseRepoPath("/v3.24/main/../etc/passwd") == null);
    try t.expect(parseRepoPath("/v3.24/main/riscv64/random.txt") == null);
    try t.expect(parseRepoPath("/v3.24/main") == null);
}
