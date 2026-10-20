// Guest SSH Connectivity, Port Probing, and CLI Dispatch.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("api.zig");
const manifest = @import("manifest.zig");
const common = @import("common.zig");
const sysconfig = @import("sysconfig.zig");
const ssh_sync = @import("ssh/sync.zig");

pub const copyFileOverSsh = ssh_sync.copyFileOverSsh;
pub const ensureGuestDefaultImage = ssh_sync.ensureGuestDefaultImage;
pub const parseIpv4 = ssh_sync.parseIpv4;
pub const isSshPortOpen = ssh_sync.isSshPortOpen;

const MAX_SSH_TOKEN_LEN: usize = 64;

/// Validates an SSH username to prevent option injection or shell metacharacter
/// attacks (`[A-Za-z0-9._-]`, non-empty, not starting with `-`).
pub fn isValidSshUsername(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_SSH_TOKEN_LEN or name[0] == '-') {
        return false;
    }
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or
            c == '.' or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// Validates an SSH host IP literal (`[0-9a-fA-F.:]` or `"localhost"`,
/// non-empty, not starting with `-`).
pub fn isValidSshIp(ip: []const u8) bool {
    if (ip.len == 0 or ip.len > MAX_SSH_TOKEN_LEN or ip[0] == '-') {
        return false;
    }
    if (std.mem.eql(u8, ip, "localhost")) return true;
    for (ip) |c| {
        const ok = std.ascii.isHex(c) or c == '.' or c == ':';
        if (!ok) return false;
    }
    return true;
}

/// Holds the configured private key path; `MAX_PATH_LEN` is the Linux
/// PATH_MAX, so any path the kernel accepts fits.
var private_key_buf: [common.MAX_PATH_LEN]u8 = undefined;

pub fn findPrivateKey() ?[]const u8 {
    const sys_cfg = common.loadRuntimeSystemConfig();
    if (std.fmt.bufPrint(
        &private_key_buf,
        "{s}/id_management",
        .{sys_cfg.keysDir()},
    )) |cfg_key| {
        var z_buf: [common.MAX_PATH_LEN]u8 = undefined;
        if (common.toPathZ(cfg_key, &z_buf)) |kz| {
            if (common.fileExistsPath(kz.ptr)) return cfg_key;
        }
    } else |_| {
        common.printStr("Warning: Keys directory path too long.\n");
    }

    const fallback: [:0]const u8 = sysconfig.ETC_MANAGEMENT_PRIVKEY_PATH;
    if (common.fileExistsPath(fallback.ptr)) return fallback;
    return null;
}

fn redirectStderrToDevNull() void {
    const devnull_res = linux.open(
        sysconfig.DEV_NULL_PATH,
        .{ .ACCMODE = .WRONLY },
        0,
    );
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
        const envp: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
            "TERM=xterm",
            "PATH=/bin:/sbin:/usr/bin:/usr/sbin",
            null,
        };
        for (sysconfig.SSH_CLIENT_BINS) |bin| {
            var z_bin_buf: [common.MAX_PATH_LEN]u8 = undefined;
            const bin_z = common.toPathZ(bin, &z_bin_buf) orelse continue;
            var argv_buf: [10:null]?[*:0]const u8 = @splat(null);
            var argc: usize = 0;
            argv_buf[argc] = bin_z.ptr;
            argc += 1;
            if (key_str) |ks| {
                argv_buf[argc] = "-i";
                argv_buf[argc + 1] = ks.ptr;
                argc += 2;
            }
            argv_buf[argc] = "-y";
            argv_buf[argc + 1] = "--";
            argv_buf[argc + 2] = dest_str.ptr;
            argc += 3;
            if (cmd_str) |cs| {
                argv_buf[argc] = cs.ptr;
                argc += 1;
            }
            argv_buf[argc] = null;
            _ = linux.execve(bin_z.ptr, &argv_buf, envp);
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

pub fn execSsh(
    key_path: ?[]const u8,
    username: []const u8,
    ip_addr: []const u8,
    remote_cmd: ?[]const u8,
) !void {
    if (!isValidSshUsername(username) or !isValidSshIp(ip_addr)) {
        return error.InvalidSshTarget;
    }
    const allocator = std.heap.page_allocator;
    const key_str: ?[:0]const u8 = if (key_path) |kp|
        try allocator.dupeSentinel(u8, kp, 0)
    else
        null;
    defer if (key_str) |ks| allocator.free(ks);

    const dest_str = try allocator.printSentinel(
        "{s}@{s}",
        .{ username, ip_addr },
        0,
    );
    defer allocator.free(dest_str);

    const cmd_str: ?[:0]const u8 = if (remote_cmd) |rc|
        try allocator.dupeSentinel(u8, rc, 0)
    else
        null;
    defer if (cmd_str) |cs| allocator.free(cs);

    const LoopbackHost = enum { @"127.0.0.1", localhost };
    const is_local = std.meta.stringToEnum(LoopbackHost, ip_addr) != null;
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

fn joinArgs(
    allocator: std.mem.Allocator,
    slice: []const [*:0]const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (slice) |arg| {
        if (out.items.len > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, std.mem.span(arg));
    }
    return out.toOwnedSlice(allocator);
}

pub fn cmdSsh(client: *api.DiosixClient, args: []const [*:0]const u8) !void {
    const exe_name = common.getExeName();
    const sys_cfg = common.loadRuntimeSystemConfig();
    _ = client;
    if (args.len == 0) {
        common.printFmt(
            \\Usage: {s} ssh [user@]<name|cid> [-- [command...]]
            \\       {s} ssh [--user <username>] <name|cid> [-- [command...]]
            \\
        , .{ exe_name, exe_name });
        return;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const SshOption = enum { @"--user", @"-u", @"--" };
    var target_arg: []const u8 = "";
    var username: []const u8 = "root";
    var remote_cmd: ?[]const u8 = null;

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
                        remote_cmd = try joinArgs(allocator, args[i + 1 ..]);
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
            remote_cmd = try joinArgs(allocator, args[i..]);
            break;
        } else if (std.mem.startsWith(u8, span, "-")) {
            common.printFmt(
                "Error: Unknown option '{s}'. " ++
                    "Usage: {s} ssh [user@]<name|cid> [-- [cmd...]]\n",
                .{ span, exe_name },
            );
            return;
        }
    }

    if (target_arg.len == 0) {
        common.printFmt(
            "Error: No target VM specified. " ++
                "Usage: {s} ssh [user@]<name|cid>\n",
            .{exe_name},
        );
        return;
    }

    var target_str: []const u8 = target_arg;
    if (std.mem.indexOfScalar(u8, target_arg, '@')) |at_idx| {
        username = target_arg[0..at_idx];
        target_str = target_arg[at_idx + 1 ..];
    }
    if (!isValidSshUsername(username)) {
        common.printStr("Error: Invalid SSH username.\n");
        return;
    }

    var resolved_cid: usize = common.parseCid(target_str) catch 0;
    var resolved_name: []const u8 = target_str;
    var resolved_ip: []const u8 = "";

    const SelfAlias = enum { root, self };
    const is_self = std.meta.stringToEnum(SelfAlias, target_str) != null or
        resolved_cid == 1;
    if (is_self) {
        resolved_cid = 1;
        resolved_name = "root";
        resolved_ip = "127.0.0.1";
    }

    if (common.readBinaryFile(
        common.GUEST_REGISTRY_PATH,
        common.MAX_MANIFEST_SIZE,
    )) |content| {
        defer common.unmapBinaryFile(content);
        var iter = common.GuestRegistryIter.init(content);
        while (iter.next()) |e| {
            if (common.matchTarget(target_str, resolved_cid, e.cid, e.name)) {
                resolved_cid = e.cid;
                resolved_name = try allocator.dupe(u8, e.name);
                resolved_ip = try allocator.dupe(u8, e.ip);
                break;
            }
        }
    } else |_| {}

    if (resolved_ip.len == 0) {
        if (common.readBinaryFile(
            sys_cfg.systemManifestPath(),
            common.MAX_MANIFEST_SIZE,
        )) |content| {
            defer common.unmapBinaryFile(content);
            if (manifest.parseSystemManifest(allocator, content)) |sys_m_val| {
                var sys_m = sys_m_val;
                defer sys_m.deinit();
                if (sys_m.domains.get(target_str)) |dom| {
                    if (dom.ip.len > 0) {
                        resolved_ip = try allocator.dupe(u8, dom.ip);
                    }
                    if (dom.name.len > 0) {
                        resolved_name = try allocator.dupe(u8, dom.name);
                    }
                }
            } else |_| {}
        } else |_| {}
    }

    if (resolved_ip.len == 0) {
        if (resolved_cid >= common.CID_FIRST_CHILD) {
            resolved_ip = try allocator.print(
                "{s}{d}",
                .{ sys_cfg.subnetPrefix(), resolved_cid },
            );
        } else if (is_self) {
            resolved_ip = "127.0.0.1";
        } else {
            common.printFmt(
                "Error: Guest '{s}' not found. " ++
                    "Use '{s} list' to view running guests.\n",
                .{ target_str, exe_name },
            );
            return;
        }
    }

    if (!isValidSshIp(resolved_ip)) {
        common.printStr("Error: Invalid guest IP address for SSH.\n");
        return;
    }

    const key_file = findPrivateKey();
    if (remote_cmd) |rc| {
        common.printFmt(
            "Connecting to guest '{s}' ({s}) as '{s}': {s}\n",
            .{ resolved_name, resolved_ip, username, rc },
        );
    } else {
        common.printFmt(
            "Connecting to guest '{s}' ({s}) as '{s}' via SSH...\n",
            .{ resolved_name, resolved_ip, username },
        );
    }

    try execSsh(key_file, username, resolved_ip, remote_cmd);
}

test "ssh: parseIpv4, isValidSshUsername, and isValidSshIp validate inputs" {
    std.testing.refAllDecls(@This());
    _ = ssh_sync;
    try std.testing.expect(parseIpv4("127.0.0.1") != null);
    try std.testing.expect(parseIpv4("10.0.3.2") != null);
    try std.testing.expect(parseIpv4("256.0.0.1") == null);
    try std.testing.expect(isValidSshUsername("root"));
    try std.testing.expect(!isValidSshUsername("-oProxyCommand=evil"));
    try std.testing.expect(isValidSshIp("10.0.3.2"));
    try std.testing.expect(!isValidSshIp("-oProxyCommand=evil"));
}
