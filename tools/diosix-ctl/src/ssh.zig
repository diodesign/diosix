// Guest SSH Connectivity, Port Probing, and CLI Dispatch.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("api.zig");
const manifest = @import("manifest.zig");
const common = @import("common.zig");
const ssh_sync = @import("ssh/sync.zig");

pub const copyFileOverSsh = ssh_sync.copyFileOverSsh;
pub const ensureGuestDefaultImage = ssh_sync.ensureGuestDefaultImage;

pub fn findPrivateKey() ?[]const u8 {
    const paths = [_][*:0]const u8{
        "/var/lib/diosix/keys/id_management",
        "/etc/diosix/keys/id_management",
        "/etc/diosix/keys/id_dropbear",
        "/etc/diosix/keys/id_ed25519",
        "/root/.ssh/id_dropbear",
        "/root/.ssh/id_ed25519",
        "/etc/diosix/id_ed25519",
    };
    for (paths) |p| {
        if (common.fileExistsPath(p)) {
            return std.mem.span(p);
        }
    }
    return null;
}

fn redirectStderrToDevNull() void {
    const devnull_res = linux.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0);
    const devnull_signed: isize = @bitCast(devnull_res);
    if (devnull_signed >= 0) {
        const fd: i32 = @intCast(devnull_signed);
        _ = linux.dup2(fd, linux.STDERR_FILENO);
        _ = linux.close(fd);
    }
}

pub fn runSshCommand(
    key_str: ?[:0]const u8,
    dest_str: [:0]const u8,
    cmd_str: ?[:0]const u8,
    silence_stderr: bool,
) u32 {
    const pid_res = linux.fork();
    const pid_signed: isize = @bitCast(pid_res);
    if (pid_signed < 0) return 255;
    if (pid_signed == 0) {
        if (silence_stderr) redirectStderrToDevNull();
        const ssh_bins = [_][*:0]const u8{
            "/usr/bin/ssh",
            "/usr/bin/dbclient",
            "/bin/ssh",
            "/usr/sbin/dropbear",
        };
        const envp: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
            "TERM=xterm",
            "PATH=/bin:/sbin:/usr/bin:/usr/sbin",
            null,
        };
        for (ssh_bins) |bin| {
            var argv_buf: [8:null]?[*:0]const u8 = @splat(null);
            var argc: usize = 0;
            argv_buf[argc] = bin;
            argc += 1;
            if (key_str) |ks| {
                argv_buf[argc] = "-i";
                argv_buf[argc + 1] = ks.ptr;
                argc += 2;
            }
            argv_buf[argc] = "-y";
            argv_buf[argc + 1] = dest_str.ptr;
            argc += 2;
            if (cmd_str) |cs| {
                argv_buf[argc] = cs.ptr;
                argc += 1;
            }
            argv_buf[argc] = null;
            _ = linux.execve(bin, &argv_buf, envp);
        }
        linux.exit(127);
    }

    const child_pid: linux.pid_t = @intCast(pid_signed);
    var status: i32 = 0;
    while (true) {
        const wait_res = linux.waitpid(child_pid, &status, 0);
        const wait_signed: isize = @bitCast(wait_res);
        if (wait_signed >= 0) break;
        const neg_rc: usize = @bitCast(-wait_signed);
        const err_code: u32 = @truncate(neg_rc);
        if (err_code != @backingInt(linux.E.INTR)) break;
    }
    return if (status == 0) 0 else 1;
}

pub fn parseIpv4(s: []const u8) ?u32 {
    var parts: [4]u8 = undefined;
    var part_idx: usize = 0;
    var cur_val: u32 = 0;
    var has_digits = false;

    for (s) |c| {
        if (c >= '0' and c <= '9') {
            cur_val = cur_val * 10 + (c - '0');
            if (cur_val > 255) return null;
            has_digits = true;
        } else if (c == '.') {
            if (!has_digits or part_idx >= 3) return null;
            parts[part_idx] = @intCast(cur_val);
            part_idx += 1;
            cur_val = 0;
            has_digits = false;
        } else {
            return null;
        }
    }
    if (!has_digits or part_idx != 3) return null;
    parts[3] = @intCast(cur_val);
    return @as(u32, parts[0]) |
        (@as(u32, parts[1]) << 8) |
        (@as(u32, parts[2]) << 16) |
        (@as(u32, parts[3]) << 24);
}

pub fn isSshPortOpen(ip_str: []const u8) bool {
    const ip_addr = parseIpv4(ip_str) orelse return false;
    const sock_flags =
        linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC;
    const fd_res = linux.socket(linux.AF.INET, sock_flags, 0);
    const fd_signed: isize = @bitCast(fd_res);
    if (fd_signed < 0) return false;
    const fd: i32 = @intCast(fd_signed);
    defer _ = linux.close(fd);

    var addr: linux.sockaddr.in = undefined;
    addr.family = linux.AF.INET;
    addr.port = std.mem.nativeToBig(u16, 22);
    addr.addr = ip_addr;

    const connect_res = linux.connect(
        fd,
        @ptrCast(&addr),
        @sizeOf(linux.sockaddr.in),
    );
    const connect_signed: isize = @bitCast(connect_res);
    if (connect_signed == 0) return true;

    const neg_rc: usize = @bitCast(-connect_signed);
    const err_code: u32 = @truncate(neg_rc);
    if (err_code == @backingInt(linux.E.INPROGRESS)) {
        var pfd = [_]linux.pollfd{.{
            .fd = fd,
            .events = linux.POLL.OUT,
            .revents = 0,
        }};
        const poll_res = linux.poll(&pfd, 1, 1000);
        const poll_signed: isize = @bitCast(poll_res);
        const revents = pfd[0].revents;
        const ready = (revents & linux.POLL.OUT) != 0 and
            (revents & (linux.POLL.ERR | linux.POLL.HUP)) == 0;
        if (poll_signed > 0 and ready) {
            var so_error: i32 = 0;
            var optlen: u32 = @sizeOf(i32);
            _ = linux.getsockopt(
                fd,
                linux.SOL.SOCKET,
                linux.SO.ERROR,
                @ptrCast(&so_error),
                &optlen,
            );
            return so_error == 0;
        }
    }
    return false;
}

pub fn execSsh(
    key_path: ?[]const u8,
    username: []const u8,
    ip_addr: []const u8,
    remote_cmd: ?[]const u8,
) !void {
    var key_buf: [128]u8 = undefined;
    const key_str: ?[:0]const u8 = if (key_path) |kp|
        (common.toPathZ(kp, &key_buf) orelse return error.PathTooLong)
    else
        null;

    var dest_buf: [128]u8 = undefined;
    const dest_slice = try std.fmt.bufPrint(
        dest_buf[0 .. dest_buf.len - 1],
        "{s}@{s}",
        .{ username, ip_addr },
    );
    dest_buf[dest_slice.len] = 0;
    const dest_str: [:0]const u8 = dest_buf[0..dest_slice.len :0];

    var cmd_buf: [512]u8 = undefined;
    const cmd_str: ?[:0]const u8 = if (remote_cmd) |rc| blk: {
        const cs = try std.fmt.bufPrint(
            cmd_buf[0 .. cmd_buf.len - 1],
            "{s}",
            .{rc},
        );
        cmd_buf[cs.len] = 0;
        break :blk cmd_buf[0..cs.len :0];
    } else null;

    const is_local = std.mem.eql(u8, ip_addr, "127.0.0.1") or
        std.mem.eql(u8, ip_addr, "localhost");
    if (!is_local) {
        var attempts: usize = 0;
        var printed_waiting = false;
        var ssh_ready = false;
        while (attempts < 25) : (attempts += 1) {
            if (isSshPortOpen(ip_addr)) {
                ssh_ready = true;
                break;
            }
            if (!printed_waiting) {
                common.printStr(
                    "Waiting for guest to finish booting and " ++
                        "start SSH service...\n",
                );
                printed_waiting = true;
            }
            var req = linux.timespec{ .sec = 1, .nsec = 0 };
            var rem: linux.timespec = undefined;
            _ = linux.nanosleep(&req, &rem);
        }
        if (!ssh_ready) {
            common.printStr(
                "Error: SSH service not reachable on guest " ++
                    "(port 22 closed or timed out).\n",
            );
            common.printStr(
                "Note: If the guest is running a minimal payload without " ++
                    "an SSH daemon (such as micro-guest), SSH connections " ++
                    "are not supported.\n",
            );
            return;
        }
        if (cmd_str == null) {
            ensureGuestDefaultImage(key_str, ip_addr);
        }
    }

    _ = runSshCommand(key_str, dest_str, cmd_str, false);
}

fn joinArgs(slice: []const [*:0]const u8, buf: []u8) []const u8 {
    var buf_len: usize = 0;
    for (slice) |arg| {
        const s = std.mem.span(arg);
        if (buf_len > 0 and buf_len < buf.len) {
            buf[buf_len] = ' ';
            buf_len += 1;
        }
        const copy_len = @min(s.len, buf.len - buf_len);
        @memcpy(buf[buf_len .. buf_len + copy_len], s[0..copy_len]);
        buf_len += copy_len;
    }
    return buf[0..buf_len];
}

pub fn cmdSsh(client: *api.DiosixClient, args: []const [*:0]const u8) !void {
    const exe_name = common.getExeName();
    _ = client;
    if (args.len == 0) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            \\Usage: {s} ssh [user@]<name|cid> [-- [command...]]
            \\       {s} ssh [--user <username>] <name|cid> [-- [command...]]
            \\
        , .{ exe_name, exe_name }) catch return;
        common.printStr(msg);
        return;
    }

    const SshOption = enum { @"--user", @"-u", @"--" };
    var target_arg: []const u8 = "";
    var username: []const u8 = "root";
    var remote_cmd: ?[]const u8 = null;

    var cmd_str_buf: [512]u8 = undefined;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const span = std.mem.span(args[i]);
        if (std.meta.stringToEnum(SshOption, span)) |opt| {
            switch (opt) {
                .@"--user", .@"-u" => {
                    if (i + 1 >= args.len) {
                        common.printStr(
                            "Error: Option '--user' requires a username.\n",
                        );
                        return;
                    }
                    i += 1;
                    username = std.mem.span(args[i]);
                },
                .@"--" => {
                    if (i + 1 < args.len) {
                        remote_cmd = joinArgs(args[i + 1 ..], &cmd_str_buf);
                    }
                    break;
                },
            }
        } else if (target_arg.len == 0 and !std.mem.startsWith(u8, span, "-")) {
            target_arg = span;
        } else if (target_arg.len > 0 and
            remote_cmd == null and
            !std.mem.startsWith(u8, span, "-"))
        {
            remote_cmd = joinArgs(args[i..], &cmd_str_buf);
            break;
        } else if (std.mem.startsWith(u8, span, "-")) {
            var err_buf: [160]u8 = undefined;
            const err_msg = std.fmt.bufPrint(
                &err_buf,
                "Error: Unknown option '{s}'. " ++
                    "Usage: {s} ssh [user@]<name|cid> [-- [cmd...]]\n",
                .{ span, exe_name },
            ) catch "Error: Unknown option.\n";
            common.printStr(err_msg);
            return;
        }
    }

    if (target_arg.len == 0) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "Error: No target VM specified. " ++
                "Usage: {s} ssh [user@]<name|cid>\n",
            .{exe_name},
        ) catch return;
        common.printStr(msg);
        return;
    }

    var target_str: []const u8 = target_arg;
    if (std.mem.indexOfScalar(u8, target_arg, '@')) |at_idx| {
        username = target_arg[0..at_idx];
        target_str = target_arg[at_idx + 1 ..];
    }

    var resolved_cid: usize = common.parseCid(target_str) catch 0;
    var resolved_name: []const u8 = target_str;
    var resolved_ip: []const u8 = "";

    var ip_storage: [64]u8 = undefined;
    var name_storage: [64]u8 = undefined;

    const is_self = std.mem.eql(u8, target_str, "root") or
        std.mem.eql(u8, target_str, "self") or
        resolved_cid == 1;
    if (is_self) {
        resolved_cid = 1;
        resolved_name = "root";
        resolved_ip = "127.0.0.1";
    }

    if (common.readBinaryFile(
        "/var/run/diosix/guests.toml",
        common.MAX_MANIFEST_SIZE,
    )) |content| {
        defer common.unmapBinaryFile(content);
        var iter = common.GuestRegistryIter.init(content);
        while (iter.next()) |e| {
            if (common.matchTarget(target_str, resolved_cid, e.cid, e.name)) {
                resolved_cid = e.cid;
                resolved_name = common.copyStr(&name_storage, e.name);
                resolved_ip = common.copyStr(&ip_storage, e.ip);
                break;
            }
        }
    } else |_| {}

    if (resolved_ip.len == 0) {
        if (common.readBinaryFile(
            "/etc/diosix/system.toml",
            common.MAX_MANIFEST_SIZE,
        )) |content| {
            defer common.unmapBinaryFile(content);
            const allocator = std.heap.page_allocator;
            if (manifest.parseSystemManifest(allocator, content)) |sys_m_val| {
                var sys_m = sys_m_val;
                defer sys_m.deinit();
                if (sys_m.domains.get(target_str)) |dom| {
                    if (dom.ip.len > 0) {
                        resolved_ip = common.copyStr(&ip_storage, dom.ip);
                    }
                    if (dom.name.len > 0) {
                        resolved_name = common.copyStr(&name_storage, dom.name);
                    }
                }
            } else |_| {}
        } else |_| {}
    }

    if (resolved_ip.len == 0) {
        if (resolved_cid >= common.CID_FIRST_CHILD) {
            resolved_ip = std.fmt.bufPrint(
                &ip_storage,
                "10.0.3.{d}",
                .{resolved_cid},
            ) catch "10.0.3.2";
        } else if (is_self) {
            resolved_ip = "127.0.0.1";
        } else {
            var err_buf: [160]u8 = undefined;
            const err_msg = std.fmt.bufPrint(
                &err_buf,
                "Error: Guest '{s}' not found. " ++
                    "Use '{s} list' to view running guests.\n",
                .{ target_str, exe_name },
            ) catch "Error: Guest not found.\n";
            common.printStr(err_msg);
            return;
        }
    }

    const key_file = findPrivateKey();

    if (remote_cmd) |rc| {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &msg_buf,
            "Connecting to guest '{s}' ({s}) as '{s}': {s}\n",
            .{ resolved_name, resolved_ip, username, rc },
        ) catch return;
        common.printStr(msg);
    } else {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &msg_buf,
            "Connecting to guest '{s}' ({s}) as '{s}' via SSH...\n",
            .{ resolved_name, resolved_ip, username },
        ) catch return;
        common.printStr(msg);
    }

    try execSsh(key_file, username, resolved_ip, remote_cmd);
}

test "ssh: parseIpv4 validates dotted-quad addresses" {
    std.testing.refAllDecls(@This());
    _ = ssh_sync;
    try std.testing.expect(parseIpv4("127.0.0.1") != null);
    try std.testing.expect(parseIpv4("10.0.3.2") != null);
    try std.testing.expect(parseIpv4("256.0.0.1") == null);
    try std.testing.expect(parseIpv4("10.0.3") == null);
    try std.testing.expect(parseIpv4("invalid") == null);
}
