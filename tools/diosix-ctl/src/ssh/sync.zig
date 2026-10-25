// Guest SSH Default Image Syncing for Nested Virtualization.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const common = @import("../common.zig");
const sysconfig = @import("../sysconfig.zig");
const ssh = @import("../ssh.zig");

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

pub fn copyFileOverSsh(
    key_str: ?[:0]const u8,
    dest_str: [:0]const u8,
    src_path_z: [*:0]const u8,
    remote_dest: [:0]const u8,
) bool {
    const src_fd_res = linux.open(src_path_z, .{ .ACCMODE = .RDONLY }, 0);
    const src_fd_signed: isize = @bitCast(src_fd_res);
    if (src_fd_signed < 0) return false;
    const src_fd: i32 = @intCast(src_fd_signed);
    defer _ = linux.close(src_fd);

    const allocator = std.heap.page_allocator;
    const remote_cmd_z = allocator.printSentinel(
        "cat > '{s}'",
        .{remote_dest},
        0,
    ) catch {
        common.printStr(OOM_MESSAGE);
        return false;
    };
    defer allocator.free(remote_cmd_z);

    const pid_res = linux.fork();
    const pid_signed: isize = @bitCast(pid_res);
    if (pid_signed < 0) return false;
    if (pid_signed == 0) {
        _ = linux.dup2(src_fd, linux.STDIN_FILENO);
        _ = linux.close(src_fd);

        const devnull_res = linux.open(
            sysconfig.DEV_NULL_PATH,
            .{ .ACCMODE = .WRONLY },
            0,
        );
        const devnull_signed: isize = @bitCast(devnull_res);
        if (devnull_signed >= 0) {
            const dn_fd: i32 = @intCast(devnull_signed);
            _ = linux.dup2(dn_fd, linux.STDOUT_FILENO);
            _ = linux.dup2(dn_fd, linux.STDERR_FILENO);
            _ = linux.close(dn_fd);
        }

        const envp: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
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
            argv_buf[argc + 1] = dest_str.ptr;
            argv_buf[argc + 2] = remote_cmd_z.ptr;
            argv_buf[argc + 3] = null;
            _ = linux.execve(bin_z.ptr, &argv_buf, envp);
        }
        linux.exit(127);
    }

    const pid: i32 = @intCast(pid_signed);
    var status: i32 = 0;
    while (true) {
        const wait_res = linux.waitpid(pid, &status, 0);
        const wait_signed: isize = @bitCast(wait_res);
        if (wait_signed >= 0) break;
        if (wait_signed == -@as(isize, @backingInt(linux.E.INTR))) continue;
        return false;
    }
    return status == 0;
}

const OOM_MESSAGE = "Error: Out of memory preparing SSH command.\n";

pub fn ensureGuestDefaultImage(
    key_str: ?[:0]const u8,
    ip_addr: []const u8,
) void {
    if (!ssh.isValidSshIp(ip_addr)) return;
    const allocator = std.heap.page_allocator;
    const candidate_sources = [_][:0]const u8{
        sysconfig.LINUX_GUEST_IMAGE_PATH,
        sysconfig.DEFAULT_GUEST_IMAGE_PATH,
    };
    var found_src: ?[:0]const u8 = null;
    var found_fd: i32 = -1;
    var src_size: usize = 0;
    for (candidate_sources) |src_candidate| {
        const fd_src = linux.open(
            src_candidate.ptr,
            .{ .ACCMODE = .RDONLY },
            0,
        );
        const fd_signed: isize = @bitCast(fd_src);
        if (fd_signed < 0) continue;
        const fd: i32 = @intCast(fd_signed);

        const end_offset = linux.lseek(fd, 0, linux.SEEK.END);
        _ = linux.lseek(fd, 0, linux.SEEK.SET);
        const end_signed: isize = @bitCast(end_offset);
        if (end_signed <= 0) {
            _ = linux.close(fd);
            continue;
        }
        found_src = src_candidate;
        found_fd = fd;
        src_size = @intCast(end_signed);
        break;
    }
    const src_z = found_src orelse return;
    if (found_fd < 0) return;
    defer _ = linux.close(found_fd);

    const dest_str = allocator.printSentinel(
        "root@{s}",
        .{ip_addr},
        0,
    ) catch {
        common.printStr(OOM_MESSAGE);
        return;
    };
    defer allocator.free(dest_str);

    const check_cmd: [:0]const u8 =
        "test -s " ++ sysconfig.DEFAULT_GUEST_IMAGE_PATH ++ " || " ++
        "test -s " ++ sysconfig.LINUX_GUEST_IMAGE_PATH;
    if (ssh.runSshCommand(key_str, dest_str, check_cmd, true) == 0) return;

    const test_cmd_z = allocator.printSentinel(
        "[ $(wc -c < {s} 2>/dev/null || echo 0) -eq {d} ]",
        .{ sysconfig.DEFAULT_GUEST_IMAGE_PATH, src_size },
        0,
    ) catch {
        common.printStr(OOM_MESSAGE);
        return;
    };
    defer allocator.free(test_cmd_z);
    if (ssh.runSshCommand(key_str, dest_str, test_cmd_z, true) == 0) return;

    common.printStr(
        "Syncing default guest image to child VM for nested " ++
            "virtualization...\n",
    );

    const mkdir_cmd: [:0]const u8 = "mkdir -p " ++ sysconfig.DEFAULT_IMAGES_DIR;
    _ = ssh.runSshCommand(key_str, dest_str, mkdir_cmd, true);

    const remote_tmp: [:0]const u8 =
        sysconfig.DEFAULT_IMAGES_DIR ++ "/.default.bin.tmp";
    const cleanup_cmd: [:0]const u8 = "rm -f " ++ remote_tmp;
    if (copyFileOverSsh(key_str, dest_str, src_z.ptr, remote_tmp)) {
        const verify_z = allocator.printSentinel(
            "[ $(wc -c < {s} 2>/dev/null || echo 0) -eq {d} ]",
            .{ remote_tmp, src_size },
            0,
        ) catch {
            common.printStr(OOM_MESSAGE);
            return;
        };
        defer allocator.free(verify_z);

        if (ssh.runSshCommand(key_str, dest_str, verify_z, true) == 0) {
            const install_cmd: [:0]const u8 =
                "mv -f " ++ remote_tmp ++ " " ++
                sysconfig.DEFAULT_GUEST_IMAGE_PATH ++ " && " ++
                "chmod +x " ++ sysconfig.DEFAULT_GUEST_IMAGE_PATH;
            _ = ssh.runSshCommand(key_str, dest_str, install_cmd, true);
            common.printStr("✓ Guest image verified and ready on child VM.\n");
        } else {
            _ = ssh.runSshCommand(key_str, dest_str, cleanup_cmd, true);
            common.printStr(
                "Warning: Guest image transfer incomplete; " ++
                    "temporary file cleaned up.\n",
            );
        }
    } else {
        _ = ssh.runSshCommand(key_str, dest_str, cleanup_cmd, true);
        common.printStr("Warning: Failed to copy guest image to child VM.\n");
    }
}

test "ssh_sync: declarations compile cleanly" {
    std.testing.refAllDecls(@This());
}
