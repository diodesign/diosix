// Peer CID Authentication, Interface-Bound Listeners, and Socket Timeouts.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("../../api.zig");
const common = @import("../../common.zig");
const registry = @import("../../registry.zig");
const ssh = @import("../../ssh.zig");
const sysconfig = @import("../../sysconfig.zig");

const LISTEN_BACKLOG: u32 = 32;
const PROC_READ_MAX: usize = 64 * 1024;
const E_INTR: isize = -@as(isize, @backingInt(linux.E.INTR));

const KernelTimeval = extern struct {
    sec: isize,
    usec: isize,
};

pub fn setSocketTimeouts(fd: i32, sec: i64) void {
    const tv = KernelTimeval{ .sec = @intCast(sec), .usec = 0 };
    _ = linux.setsockopt(
        fd,
        linux.SOL.SOCKET,
        linux.SO.RCVTIMEO,
        @ptrCast(&tv),
        @sizeOf(KernelTimeval),
    );
    _ = linux.setsockopt(
        fd,
        linux.SOL.SOCKET,
        linux.SO.SNDTIMEO,
        @ptrCast(&tv),
        @sizeOf(KernelTimeval),
    );
}

pub fn formatIpv4(addr_be: u32, buf: *[16]u8) []const u8 {
    const b: [4]u8 = @bitCast(addr_be);
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
        b[0], b[1], b[2], b[3],
    }) catch "0.0.0.0";
}

pub fn parseArpChildCid(arp_text: []const u8, peer_ip: []const u8) ?usize {
    var lines = std.mem.splitScalar(u8, arp_text, '\n');
    while (lines.next()) |raw_line| {
        const line = common.trimWhitespace(raw_line);
        if (line.len == 0) continue;
        var tok = std.mem.tokenizeAny(u8, line, " \t");
        const ip = tok.next() orelse continue;
        _ = tok.next() orelse continue;
        const flags = tok.next() orelse continue;
        const mac = tok.next() orelse continue;
        _ = tok.next() orelse continue;
        const dev = tok.next() orelse continue;
        if (!std.mem.eql(u8, ip, peer_ip) or !std.mem.eql(u8, dev, "diosix0"))
            continue;
        if (!std.mem.startsWith(u8, flags, "0x") or
            std.mem.eql(u8, flags, "0x0")) continue;
        if (mac.len != 17 or mac[14] != ':') continue;
        if (!std.ascii.eqlIgnoreCase(mac[0..12], "02:00:00:00:")) continue;
        const hi = std.fmt.parseInt(u8, mac[12..14], 16) catch continue;
        const lo = std.fmt.parseInt(u8, mac[15..17], 16) catch continue;
        const cid = (@as(usize, hi) << 8) | @as(usize, lo);
        if (cid >= common.CID_FIRST_CHILD) return cid;
    }
    return null;
}

pub fn isArpPeerOnDev(
    arp_text: []const u8,
    peer_ip: []const u8,
    target_dev: []const u8,
) bool {
    var lines = std.mem.splitScalar(u8, arp_text, '\n');
    while (lines.next()) |raw_line| {
        const line = common.trimWhitespace(raw_line);
        if (line.len == 0) continue;
        var tok = std.mem.tokenizeAny(u8, line, " \t");
        const ip = tok.next() orelse continue;
        _ = tok.next() orelse continue;
        const flags = tok.next() orelse continue;
        _ = tok.next() orelse continue;
        _ = tok.next() orelse continue;
        const dev = tok.next() orelse continue;
        if (!std.mem.eql(u8, ip, peer_ip)) continue;
        if (!std.mem.eql(u8, dev, target_dev)) continue;
        if (!std.mem.startsWith(u8, flags, "0x") or
            std.mem.eql(u8, flags, "0x0")) continue;
        return true;
    }
    return false;
}

fn ipMatchesExpectedCid(peer_ip: []const u8, cid: usize) bool {
    if (common.readBinaryFile(
        sysconfig.GUEST_REGISTRY_PATH,
        common.MAX_MANIFEST_SIZE,
    )) |reg_raw| {
        defer common.unmapBinaryFile(reg_raw);
        var it = registry.GuestRegistryIter.init(reg_raw);
        while (it.next()) |entry| {
            if (entry.cid == cid and entry.ip.len > 0) {
                return std.mem.eql(u8, entry.ip, peer_ip);
            }
        }
    } else |_| {}

    const sys_cfg = common.loadRuntimeSystemConfig();
    var exp_buf: [32]u8 = undefined;
    const exp = std.fmt.bufPrint(&exp_buf, "{s}{d}", .{
        sys_cfg.subnetPrefix(),
        cid,
    }) catch return true;
    return std.mem.eql(u8, peer_ip, exp);
}

pub fn resolvePeerChildCid(peer_addr_be: u32) ?usize {
    if (peer_addr_be == (ssh.parseIpv4("127.0.0.1") orelse 0)) return 0;
    var ip_buf: [16]u8 = undefined;
    const ip_str = formatIpv4(peer_addr_be, &ip_buf);
    const arp_raw = common.readBinaryFile(
        sysconfig.PROC_NET_ARP_PATH,
        PROC_READ_MAX,
    ) catch return null;
    defer common.unmapBinaryFile(arp_raw);
    const cid = parseArpChildCid(arp_raw, ip_str) orelse return null;
    if (!ipMatchesExpectedCid(ip_str, cid)) return null;
    return cid;
}

/// Returns true if a TCP peer came from the downstream `diosix0` child bridge
/// (matching any ARP entry on `diosix0` or the local `diosix0` subnet prefix).
pub fn isPeerFromDiosixBridge(peer_addr_be: u32) bool {
    var ip_buf: [16]u8 = undefined;
    const ip_str = formatIpv4(peer_addr_be, &ip_buf);
    if (common.readBinaryFile(sysconfig.PROC_NET_ARP_PATH, PROC_READ_MAX)) |a| {
        defer common.unmapBinaryFile(a);
        if (isArpPeerOnDev(a, ip_str, "diosix0")) return true;
    } else |_| {}
    if (common.fileExistsPath("/sys/class/net/diosix0")) {
        const sys_cfg = common.loadRuntimeSystemConfig();
        if (std.mem.startsWith(u8, ip_str, sys_cfg.subnetPrefix())) {
            return true;
        }
    }
    return false;
}

pub fn parseHostsIpv4(hosts_text: []const u8, hostname: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, hosts_text, '\n');
    while (lines.next()) |raw_line| {
        const nc = if (std.mem.indexOfScalar(u8, raw_line, '#')) |c|
            raw_line[0..c]
        else
            raw_line;
        const line = common.trimWhitespace(nc);
        if (line.len == 0) continue;
        var tok = std.mem.tokenizeAny(u8, line, " \t");
        const ip_str = tok.next() orelse continue;
        const ip_be = ssh.parseIpv4(ip_str) orelse continue;
        while (tok.next()) |alias| {
            if (std.mem.eql(u8, alias, hostname)) return ip_be;
        }
    }
    return null;
}

fn readNodeEnvValue(key: []const u8, out_buf: *[64]u8) ?[]const u8 {
    const raw = common.readBinaryFile(sysconfig.NODE_ENV_PATH, 4096) catch
        return null;
    defer common.unmapBinaryFile(raw);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |raw_l| {
        const line = common.trimWhitespace(raw_l);
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, common.trimWhitespace(line[0..eq]), key)) continue;
        const val = common.unquoteToml(line[eq + 1 ..]);
        const n: usize = @min(val.len, out_buf.len);
        @memcpy(out_buf[0..n], val[0..n]);
        return out_buf[0..n];
    }
    return null;
}

pub fn resolveParentIpv4(client: ?*api.DiosixClient) u32 {
    if (client) |cl| {
        const alloc = std.heap.page_allocator;
        if (alloc.alloc(u8, common.MAX_MANIFEST_SIZE)) |buf| {
            defer alloc.free(buf);
            if (cl.getManifest(common.CID_SELF, buf)) |mlen| {
                var lines = std.mem.splitScalar(u8, buf[0..mlen], '\n');
                while (lines.next()) |raw| {
                    const line = common.trimWhitespace(raw);
                    const pfx = "# diosix-net-gateway:";
                    if (std.mem.startsWith(u8, line, pfx)) {
                        const gw = common.trimWhitespace(line[pfx.len..]);
                        if (ssh.parseIpv4(gw)) |ip_be| return ip_be;
                    }
                }
            } else |_| {}
        } else |_| {}
    }
    var env_buf: [64]u8 = undefined;
    if (readNodeEnvValue("PARENT_IP", &env_buf)) |pip| {
        if (ssh.parseIpv4(pip)) |ip_be| return ip_be;
    }
    if (common.readBinaryFile(sysconfig.ETC_HOSTS_PATH, PROC_READ_MAX)) |h| {
        defer common.unmapBinaryFile(h);
        if (parseHostsIpv4(h, "diosix-parent")) |ip_be| return ip_be;
    } else |_| {}
    return ssh.parseIpv4(sysconfig.DEFAULT_GATEWAY_IP) orelse 0;
}

pub fn isHasParent(client: *api.DiosixClient) bool {
    if (client.getInfo(common.CID_SELF)) |info| {
        return info.has_parent != 0;
    } else |_| {}
    var env_buf: [64]u8 = undefined;
    if (readNodeEnvValue("HAS_PARENT", &env_buf)) |v| {
        return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
    }
    return false;
}

pub fn ensureDirRecursive(path: []const u8) void {
    if (path.len == 0 or path.len >= common.MAX_PATH_LEN) return;
    var buf: [common.MAX_PATH_LEN]u8 = undefined;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            @memcpy(buf[0..i], path[0..i]);
            buf[i] = 0;
            const z: [*:0]const u8 = @ptrCast(buf[0..i :0]);
            _ = linux.mkdir(z, 0o755);
        }
    }
}

pub fn ensureParentDir(file_path: []const u8) void {
    if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |slash| {
        if (slash > 0) ensureDirRecursive(file_path[0..slash]);
    }
}

const SIOCGIFADDR: u32 = 0x8915;

const IfreqIpv4 = extern struct {
    name: [16]u8 align(8) = @splat(0),
    addr: linux.sockaddr.in = .{
        .family = 0,
        .port = 0,
        .addr = 0,
        .zero = @splat(0),
    },
    pad: [8]u8 = @splat(0),
};

comptime {
    std.debug.assert(@sizeOf(IfreqIpv4) == 40);
}

/// Return the assigned IPv4 address (network byte order) of `dev_name`,
/// or null if the interface is absent or has no IPv4 address.
pub fn queryIfaceIpv4(dev_name: []const u8) ?u32 {
    if (dev_name.len == 0 or dev_name.len >= 16) return null;
    const stype = linux.SOCK.DGRAM | linux.SOCK.CLOEXEC;
    const fd_s: isize = @bitCast(linux.socket(linux.AF.INET, stype, 0));
    if (fd_s < 0) return null;
    const fd: i32 = @intCast(fd_s);
    defer _ = linux.close(fd);

    var ifr = IfreqIpv4{};
    @memcpy(ifr.name[0..dev_name.len], dev_name);
    const rc: isize = @bitCast(
        linux.ioctl(fd, SIOCGIFADDR, @intFromPtr(&ifr)),
    );
    if (rc < 0 or ifr.addr.family != linux.AF.INET or ifr.addr.addr == 0) {
        return null;
    }
    return ifr.addr.addr;
}

pub fn bindTcpOnAddr(
    port: u16,
    ip_be: u32,
    dev_name: ?[:0]const u8,
) !i32 {
    const stype = linux.SOCK.STREAM | linux.SOCK.CLOEXEC;
    const fd_s: isize = @bitCast(linux.socket(linux.AF.INET, stype, 0));
    if (fd_s < 0) return error.SocketFailed;
    const fd: i32 = @intCast(fd_s);
    errdefer _ = linux.close(fd);
    const enable: c_int = 1;
    _ = linux.setsockopt(
        fd,
        linux.SOL.SOCKET,
        linux.SO.REUSEADDR,
        @ptrCast(&enable),
        @sizeOf(c_int),
    );
    if (dev_name) |dn| {
        _ = linux.setsockopt(
            fd,
            linux.SOL.SOCKET,
            linux.SO.BINDTODEVICE,
            dn.ptr,
            @intCast(dn.len + 1),
        );
    }
    var addr: linux.sockaddr.in = .{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = ip_be,
        .zero = @splat(0),
    };
    const b: isize = @bitCast(
        linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)),
    );
    if (b < 0) return error.BindFailed;
    const l: isize = @bitCast(linux.listen(fd, LISTEN_BACKLOG));
    if (l < 0) return error.ListenFailed;
    return fd;
}

pub fn bindAndListenTcp(port: u16) !i32 {
    return bindTcpOnAddr(port, 0, null);
}

pub const AcceptedClient = struct {
    cfd: i32,
    caller_cid: ?usize,
};

pub const DownstreamListener = struct {
    lo_fd: i32,
    br_fd: i32 = -1,

    pub fn open(port: u16) !DownstreamListener {
        const lo_ip = ssh.parseIpv4("127.0.0.1") orelse 0;
        const lo_fd = try bindTcpOnAddr(port, lo_ip, "lo");
        errdefer _ = linux.close(lo_fd);
        var br_fd: i32 = -1;
        if (queryIfaceIpv4("diosix0")) |br_ip| {
            if (br_ip != lo_ip) {
                br_fd = bindTcpOnAddr(port, br_ip, "diosix0") catch -1;
            }
        }
        return .{ .lo_fd = lo_fd, .br_fd = br_fd };
    }

    pub fn close(self: *const DownstreamListener) void {
        _ = linux.close(self.lo_fd);
        if (self.br_fd >= 0) _ = linux.close(self.br_fd);
    }

    pub fn accept(
        self: *const DownstreamListener,
        timeout_sec: i64,
    ) ?AcceptedClient {
        var fds: [2]linux.pollfd = .{
            .{ .fd = self.lo_fd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = self.br_fd, .events = linux.POLL.IN, .revents = 0 },
        };
        const nfds: usize = if (self.br_fd >= 0) 2 else 1;
        const prc: isize = @bitCast(linux.poll(&fds, nfds, -1));
        if (prc <= 0) return null;
        for (0..nfds) |idx| {
            if ((fds[idx].revents & linux.POLL.IN) == 0) continue;
            var peer: linux.sockaddr.in = undefined;
            var plen: linux.socklen_t = @sizeOf(linux.sockaddr.in);
            const acc_s: isize = @bitCast(
                linux.accept4(
                    fds[idx].fd,
                    @ptrCast(&peer),
                    &plen,
                    linux.SOCK.CLOEXEC,
                ),
            );
            if (acc_s < 0) continue;
            const cfd: i32 = @intCast(acc_s);
            setSocketTimeouts(cfd, timeout_sec);
            const lo_ip = ssh.parseIpv4("127.0.0.1") orelse 0;
            const cid = if (idx == 0)
                (if (peer.addr == lo_ip) @as(?usize, 0) else null)
            else
                resolvePeerChildCid(peer.addr);
            return .{ .cfd = cfd, .caller_cid = cid };
        }
        return null;
    }
};

pub fn isPidFileRunning(pid_path: []const u8) ?i32 {
    const raw = common.readBinaryFile(pid_path, 128) catch return null;
    defer common.unmapBinaryFile(raw);
    const pid = std.fmt.parseInt(i32, common.trimWhitespace(raw), 10) catch
        return null;
    if (pid <= 1) return null;
    const rc: isize = @bitCast(linux.kill(pid, @fromBackingInt(@intCast(0))));
    return if (rc == 0) pid else null;
}

fn redirectStdioFd(
    path: [*:0]const u8,
    flags: linux.O,
    fd1: i32,
    fd2: ?i32,
) void {
    const rc: isize = @bitCast(linux.open(path, flags, 0o600));
    if (rc < 0) return;
    const fd: i32 = @intCast(rc);
    _ = linux.dup2(fd, fd1);
    if (fd2) |other| _ = linux.dup2(fd, other);
    if (fd > 2) _ = linux.close(fd);
}

pub fn daemonizeServer(
    listener_fd: i32,
    extra_fd: i32,
    pid_path: []const u8,
    log_path: []const u8,
) !bool {
    ensureParentDir(pid_path);
    ensureParentDir(log_path);
    const pid_s: isize = @bitCast(linux.fork());
    if (pid_s < 0) return error.ForkFailed;
    if (pid_s > 0) {
        var pid_buf: [32]u8 = undefined;
        const ps = std.fmt.bufPrint(&pid_buf, "{d}\n", .{pid_s}) catch
            return false;
        common.writePrivateFile(pid_path, ps) catch {};
        _ = linux.close(listener_fd);
        if (extra_fd >= 0) _ = linux.close(extra_fd);
        return false;
    }
    _ = linux.setsid();
    redirectStdioFd(sysconfig.DEV_NULL_PATH, .{ .ACCMODE = .RDONLY }, 0, null);
    var lz_buf: [common.MAX_PATH_LEN]u8 = undefined;
    if (common.toPathZ(log_path, &lz_buf)) |lz| {
        const wf: linux.O = .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .APPEND = true,
        };
        redirectStdioFd(lz.ptr, wf, 1, 2);
    }
    return true;
}

test "net/http/peer: ARP bridge check, CID lookup, and hosts parser" {
    std.testing.refAllDecls(@This());
    const t = std.testing;
    const arp =
        \\IP address HW type Flags HW address Mask Device
        \\10.0.2.2 0x1 0x2 52:54:00:12:35:02 * eth0
        \\10.0.3.2 0x1 0x6 02:00:00:00:00:02 * diosix0
        \\10.0.3.3 0x1 0x0 02:00:00:00:00:03 * diosix0
        \\10.0.3.250 0x1 0x2 06:00:00:00:00:03 * diosix0
    ;
    try t.expectEqual(@as(?usize, 2), parseArpChildCid(arp, "10.0.3.2"));
    try t.expectEqual(@as(?usize, null), parseArpChildCid(arp, "10.0.3.3"));
    try t.expectEqual(@as(?usize, null), parseArpChildCid(arp, "10.0.3.250"));
    try t.expect(isArpPeerOnDev(arp, "10.0.3.250", "diosix0"));
    try t.expect(!isArpPeerOnDev(arp, "10.0.2.2", "diosix0"));
    try t.expectEqual(ssh.parseIpv4("127.0.0.1"), queryIfaceIpv4("lo"));
    try t.expectEqual(@as(?u32, null), queryIfaceIpv4("nonexistent99"));
}
