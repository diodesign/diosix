// Linux PTY & Hypervisor Serial Console I/O Backend for Diosix GUI Terminal.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const sbi = @import("interface").sbi;
const paths = @import("../paths.zig");
const host_info = @import("../host.zig");
const term_mod = @import("../terminal.zig");
const TerminalSession = term_mod.TerminalSession;

const IOCTL_CONSOLE_WRITE: u32 = 0x1016;
const IOCTL_CONSOLE_READ: u32 = 0x1017;

const TIOCSCTTY: u32 = 0x540e;
const TIOCSWINSZ: u32 = 0x5414;
const TIOCGPTN: u32 = 0x80045430;
const TIOCSPTLCK: u32 = 0x40045431;

const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16 = 0,
    ws_ypixel: u16 = 0,
};

fn makeWinsize(self: *const TerminalSession) Winsize {
    return .{
        .ws_row = @intCast(
            std.math.clamp(self.rows, 6, term_mod.MAX_TERM_ROWS),
        ),
        .ws_col = @intCast(
            std.math.clamp(self.cols, 20, term_mod.MAX_TERM_COLS),
        ),
    };
}

pub fn updatePtyWinsize(self: *const TerminalSession) void {
    if (self.pty_master_fd < 0) return;
    var ws = makeWinsize(self);
    _ = linux.ioctl(self.pty_master_fd, TIOCSWINSZ, @intFromPtr(&ws));
}

pub fn spawnPtyProcess(self: *TerminalSession) void {
    const m_rc = linux.open(
        paths.DEV_PTMX_PATH,
        .{ .ACCMODE = .RDWR, .NOCTTY = true, .NONBLOCK = true },
        0,
    );
    const signed_m: isize = @bitCast(m_rc);
    if (signed_m < 0) {
        _ = self.feedBytes("Error: Failed to allocate PTY (/dev/ptmx).\n");
        self.exited = true;
        return;
    }
    const m_fd: i32 = @intCast(signed_m);

    var unlock: i32 = 0;
    _ = linux.ioctl(m_fd, TIOCSPTLCK, @intFromPtr(&unlock));
    var pty_num: u32 = 0;
    if (linux.errno(
        linux.ioctl(m_fd, TIOCGPTN, @intFromPtr(&pty_num)),
    ) != .SUCCESS) {
        _ = linux.close(m_fd);
        _ = self.feedBytes("Error: Failed to query slave PTY number.\n");
        self.exited = true;
        return;
    }
    var ws = makeWinsize(self);
    _ = linux.ioctl(m_fd, TIOCSWINSZ, @intFromPtr(&ws));

    var pts_buf: [32]u8 = undefined;
    const pts_slice = std.fmt.bufPrint(
        &pts_buf,
        paths.DEV_PTS_FMT ++ "\x00",
        .{pty_num},
    ) catch {
        _ = linux.close(m_fd);
        return;
    };
    const pts_z: [*:0]const u8 = @ptrCast(pts_slice.ptr);

    const fork_rc = linux.fork();
    if (linux.errno(fork_rc) != .SUCCESS) {
        _ = linux.close(m_fd);
        _ = self.feedBytes("Error: Failed to fork terminal process.\n");
        self.exited = true;
        return;
    }

    if (fork_rc == 0) {
        _ = linux.setsid();
        const s_rc = linux.open(pts_z, .{ .ACCMODE = .RDWR }, 0);
        const signed_s: isize = @bitCast(s_rc);
        if (signed_s < 0) linux.exit_group(1);
        const s_fd: i32 = @intCast(signed_s);
        _ = linux.ioctl(s_fd, TIOCSCTTY, 0);
        _ = linux.dup2(s_fd, 0);
        _ = linux.dup2(s_fd, 1);
        _ = linux.dup2(s_fd, 2);
        if (m_fd > 2) _ = linux.close(m_fd);
        if (s_fd > 2) _ = linux.close(s_fd);

        const envp = [_:null]?[*:0]const u8{
            "TERM=vt100",
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME=/root",
        };
        if (self.target_cid <= sbi.CID_SELF) {
            const sh_argv = [_:null]?[*:0]const u8{
                paths.SHELL_BIN_PATH,
                "-l",
            };
            _ = linux.execve(paths.SHELL_BIN_PATH, &sh_argv, &envp);
        } else {
            var cid_buf: [24]u8 = undefined;
            const cid_s = std.fmt.bufPrint(
                &cid_buf,
                "{d}\x00",
                .{self.target_cid},
            ) catch linux.exit_group(1);
            const cid_z: [*:0]const u8 = @ptrCast(cid_s.ptr);
            for (paths.DSX_BIN_PATHS) |dsx_bin| {
                const ssh_argv = [_:null]?[*:0]const u8{
                    dsx_bin,
                    "ssh",
                    cid_z,
                };
                _ = linux.execve(dsx_bin, &ssh_argv, &envp);
            }
        }
        linux.exit_group(127);
    }

    self.pty_master_fd = m_fd;
    self.child_pid = @intCast(fork_rc);
}

pub fn pollConsoleIo(self: *TerminalSession) bool {
    if (builtin.is_test or host_info.guests.mock_running_guests != null) {
        return false;
    }
    const fd_rc = linux.open(paths.DEV_DIOSIX_PATH, .{ .ACCMODE = .RDWR }, 0);
    const signed_fd: isize = @bitCast(fd_rc);
    if (signed_fd < 0) return false;
    const fd: i32 = @intCast(signed_fd);
    defer _ = linux.close(fd);

    var changed = false;
    var buf: [512]u8 = undefined;
    while (true) {
        var cargs = sbi.ConsoleArgs{
            .target_cid = self.target_cid,
            .data_ptr = @intFromPtr(&buf),
            .max_len = buf.len,
            .actual_len = 0,
        };
        const rc = linux.ioctl(fd, IOCTL_CONSOLE_READ, @intFromPtr(&cargs));
        if (@as(isize, @bitCast(rc)) < 0) break;
        const got: usize = @min(
            @as(usize, @intCast(cargs.actual_len)),
            buf.len,
        );
        if (got == 0) break;
        if (self.feedBytes(buf[0..got])) changed = true;
        if (got < buf.len) break;
    }
    return changed;
}

pub fn sendConsoleOrPtyBytes(self: *TerminalSession, data: []const u8) void {
    if (self.mode == .console) {
        const fd_rc = linux.open(
            paths.DEV_DIOSIX_PATH,
            .{ .ACCMODE = .RDWR },
            0,
        );
        const signed_fd: isize = @bitCast(fd_rc);
        if (signed_fd < 0) return;
        const fd: i32 = @intCast(signed_fd);
        defer _ = linux.close(fd);

        var cargs = sbi.ConsoleArgs{
            .target_cid = self.target_cid,
            .data_ptr = @intFromPtr(data.ptr),
            .max_len = @min(data.len, sbi.MAX_CONSOLE_IO_BYTES),
            .actual_len = 0,
        };
        _ = linux.ioctl(fd, IOCTL_CONSOLE_WRITE, @intFromPtr(&cargs));
        return;
    }

    if (self.pty_master_fd >= 0) {
        _ = linux.write(self.pty_master_fd, data.ptr, data.len);
    }
}

pub fn pollPtyIo(self: *TerminalSession) bool {
    var changed = false;
    if (self.pty_master_fd >= 0) {
        var read_buf: [512]u8 = undefined;
        while (true) {
            const rc = linux.read(
                self.pty_master_fd,
                &read_buf,
                read_buf.len,
            );
            const err = linux.errno(rc);
            if (err == .SUCCESS) {
                if (rc == 0) break;
                if (self.feedBytes(read_buf[0..rc])) changed = true;
            } else if (err == .AGAIN) {
                break;
            } else {
                _ = linux.close(self.pty_master_fd);
                self.pty_master_fd = -1;
                break;
            }
        }
    }

    if (self.child_pid > 0) {
        var status: i32 = 0;
        const wrc = linux.waitpid(self.child_pid, &status, linux.W.NOHANG);
        if (linux.errno(wrc) == .SUCCESS and
            wrc == @as(usize, @intCast(self.child_pid)))
        {
            self.child_pid = -1;
            if (self.pty_master_fd >= 0) {
                _ = linux.close(self.pty_master_fd);
                self.pty_master_fd = -1;
            }
            self.exited = true;
            _ = self.feedBytes("\n[Session ended]\n");
            changed = true;
        }
    }
    return changed;
}

test {
    std.testing.refAllDecls(@This());
}
