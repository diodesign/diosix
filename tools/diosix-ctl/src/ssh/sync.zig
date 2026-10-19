// Guest SSH Default Image Syncing for Nested Virtualization.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const common = @import("../common.zig");
const ssh = @import("../ssh.zig");

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

    var remote_cmd_buf: [common.MAX_PATH_LEN + 32]u8 = undefined;
    const remote_cmd = std.fmt.bufPrint(
        &remote_cmd_buf,
        "cat > '{s}'",
        .{remote_dest},
    ) catch return false;
    var remote_cmd_z_buf: [common.MAX_PATH_LEN + 32]u8 = undefined;
    const remote_cmd_z = common.toPathZ(remote_cmd, &remote_cmd_z_buf) orelse
        return false;

    const pid_res = linux.fork();
    const pid_signed: isize = @bitCast(pid_res);
    if (pid_signed < 0) return false;
    if (pid_signed == 0) {
        _ = linux.dup2(src_fd, linux.STDIN_FILENO);
        _ = linux.close(src_fd);

        const devnull_res = linux.open(
            "/dev/null",
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

        const ssh_bins = [_][*:0]const u8{
            "/usr/bin/ssh",
            "/usr/bin/dbclient",
            "/bin/ssh",
        };
        const envp: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
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
            argv_buf[argc + 2] = remote_cmd_z.ptr;
            argv_buf[argc + 3] = null;
            _ = linux.execve(bin, &argv_buf, envp);
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

pub fn ensureGuestDefaultImage(
    key_str: ?[:0]const u8,
    ip_addr: []const u8,
) void {
    const candidate_sources = [_][]const u8{
        "/var/lib/diosix/images/linux-guest.elf",
        "/boot/vmlinux.elf",
        "/boot/linux-guest.elf",
        "/var/lib/diosix/images/default.elf",
        "/boot/default.elf",
    };
    var found_src: ?[]const u8 = null;
    var found_fd: i32 = -1;
    var src_size: usize = 0;
    for (candidate_sources) |src_candidate| {
        var src_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
        const src_z = common.toPathZ(src_candidate, &src_z_buf) orelse continue;

        const fd_src = linux.open(src_z.ptr, .{ .ACCMODE = .RDONLY }, 0);
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
    if (found_src == null or found_fd < 0) return;
    defer _ = linux.close(found_fd);
    var src_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const src_z = common.toPathZ(found_src.?, &src_z_buf) orelse return;

    var dest_buf: [128]u8 = undefined;
    const dest_slice = std.fmt.bufPrint(
        &dest_buf,
        "root@{s}",
        .{ip_addr},
    ) catch return;
    var dest_z_buf: [128]u8 = undefined;
    const dest_str = common.toPathZ(dest_slice, &dest_z_buf) orelse return;

    const check_cmd: [:0]const u8 =
        "test -s /boot/default.elf || test -s /boot/vmlinux.elf || " ++
        "test -s /boot/linux-guest.elf || " ++
        "test -s /var/lib/diosix/images/default.elf || " ++
        "test -s /var/lib/diosix/images/linux-guest.elf";
    if (ssh.runSshCommand(key_str, dest_str, check_cmd, true) == 0) return;

    var test_cmd_buf: [128]u8 = undefined;
    const test_cmd = std.fmt.bufPrint(
        &test_cmd_buf,
        "[ $(wc -c < /var/lib/diosix/images/default.elf " ++
            "2>/dev/null || echo 0) -eq {d} ]",
        .{src_size},
    ) catch return;
    var test_cmd_z_buf: [128]u8 = undefined;
    const test_cmd_z = common.toPathZ(test_cmd, &test_cmd_z_buf) orelse return;
    if (ssh.runSshCommand(key_str, dest_str, test_cmd_z, true) == 0) return;

    common.printStr(
        "Syncing default guest image to child VM for nested " ++
            "virtualization...\n",
    );

    const mkdir_cmd: [:0]const u8 = "mkdir -p /var/lib/diosix/images";
    _ = ssh.runSshCommand(key_str, dest_str, mkdir_cmd, true);

    const remote_tmp: [:0]const u8 = "/var/lib/diosix/images/.default.elf.tmp";
    const cleanup_cmd: [:0]const u8 =
        "rm -f /var/lib/diosix/images/.default.elf.tmp";
    if (copyFileOverSsh(key_str, dest_str, src_z.ptr, remote_tmp)) {
        var verify_cmd_buf: [128]u8 = undefined;
        const verify_cmd = std.fmt.bufPrint(
            &verify_cmd_buf,
            "[ $(wc -c < /var/lib/diosix/images/.default.elf.tmp " ++
                "2>/dev/null || echo 0) -eq {d} ]",
            .{src_size},
        ) catch return;
        var verify_z_buf: [128]u8 = undefined;
        const verify_z = common.toPathZ(verify_cmd, &verify_z_buf) orelse
            return;

        if (ssh.runSshCommand(key_str, dest_str, verify_z, true) == 0) {
            const install_cmd: [:0]const u8 =
                "mv -f /var/lib/diosix/images/.default.elf.tmp " ++
                "/var/lib/diosix/images/default.elf && " ++
                "chmod +x /var/lib/diosix/images/default.elf";
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
