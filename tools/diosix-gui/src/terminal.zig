// Interactive VT100/ANSI Terminal Emulator & Session Manager for Diosix GUI.
//
// Supports two guest interaction backends:
//   1. SSH / Local Shell via a Linux pseudo-terminal (/dev/ptmx + `dsx ssh`).
//   2. Hypervisor Serial Console (SBI DBCN / hvc0) via /dev/diosix ioctls.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const host_info = @import("host.zig");
pub const io_mod = @import("terminal/io.zig");

pub const MAX_TERM_COLS: usize = 200;
pub const MAX_TERM_ROWS: usize = 60;
pub const DEFAULT_TERM_COLS: usize = 120;
pub const DEFAULT_TERM_ROWS: usize = 28;
pub const TERM_COLS: usize = DEFAULT_TERM_COLS;
pub const TERM_ROWS: usize = DEFAULT_TERM_ROWS;
pub const MAX_BG_SSH_SESSIONS: usize = 6;
pub const GUEST_TITLE_CAP: usize = 64;
pub const MOCK_TX_CAP: usize = 256;

pub const TerminalMode = enum {
    ssh,
    console,

    pub fn label(self: TerminalMode) []const u8 {
        return switch (self) {
            .ssh => "SSH",
            .console => "Serial console",
        };
    }
};

pub const EscState = enum {
    ground,
    esc,
    csi,
    osc,
};

pub const TerminalSession = struct {
    active: bool = false,
    target_cid: u64 = 0,
    mode: TerminalMode = .ssh,
    inverted: bool = false,
    cols: usize = DEFAULT_TERM_COLS,
    rows: usize = DEFAULT_TERM_ROWS,
    guest_name: [GUEST_TITLE_CAP]u8 = @splat(0),
    guest_name_len: usize = 0,
    grid: [MAX_TERM_ROWS][MAX_TERM_COLS]u8 = @splat(@splat(' ')),
    cursor_row: usize = 0,
    cursor_col: usize = 0,
    esc_state: EscState = .ground,
    csi_params: [4]u16 = @splat(0),
    csi_param_count: usize = 0,
    csi_has_digits: bool = false,
    pty_master_fd: i32 = -1,
    child_pid: i32 = -1,
    exited: bool = false,
    mock_tx_buf: [MOCK_TX_CAP]u8 = @splat(0),
    mock_tx_len: usize = 0,

    pub fn getGuestName(self: *const TerminalSession) []const u8 {
        return self.guest_name[0..self.guest_name_len];
    }

    pub fn getMockSentBytes(self: *const TerminalSession) []const u8 {
        return self.mock_tx_buf[0..self.mock_tx_len];
    }

    pub fn getRowSlice(self: *const TerminalSession, row: usize) []const u8 {
        const eff_rows = @min(self.rows, MAX_TERM_ROWS);
        const eff_cols = @min(self.cols, MAX_TERM_COLS);
        if (row >= eff_rows) return "";
        return self.grid[row][0..eff_cols];
    }

    pub fn getRowTrimmed(self: *const TerminalSession, row: usize) []const u8 {
        return std.mem.trimEnd(u8, self.getRowSlice(row), " ");
    }

    pub fn resizeGrid(
        self: *TerminalSession,
        new_cols: usize,
        new_rows: usize,
    ) void {
        const c = std.math.clamp(new_cols, 20, MAX_TERM_COLS);
        const r = std.math.clamp(new_rows, 6, MAX_TERM_ROWS);
        if (c == self.cols and r == self.rows) return;
        while (self.cursor_row >= r and self.cursor_row > 0) {
            self.scrollUp();
            self.cursor_row -= 1;
        }
        self.cols = c;
        self.rows = r;
        self.cursor_col = @min(self.cursor_col, c - 1);
        self.cursor_row = @min(self.cursor_row, r - 1);
        io_mod.updatePtyWinsize(self);
    }

    pub fn clearScreen(self: *TerminalSession) void {
        for (&self.grid) |*r| r.* = @splat(' ');
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.esc_state = .ground;
    }

    fn scrollUp(self: *TerminalSession) void {
        const eff_rows = std.math.clamp(self.rows, 1, MAX_TERM_ROWS);
        for (0..eff_rows - 1) |r| {
            self.grid[r] = self.grid[r + 1];
        }
        self.grid[eff_rows - 1] = @splat(' ');
    }

    fn lineFeed(self: *TerminalSession) void {
        const eff_rows = std.math.clamp(self.rows, 1, MAX_TERM_ROWS);
        if (self.cursor_row + 1 < eff_rows) {
            self.cursor_row += 1;
        } else {
            self.scrollUp();
        }
    }

    fn resetCsi(self: *TerminalSession) void {
        self.csi_params = @splat(0);
        self.csi_param_count = 0;
        self.csi_has_digits = false;
    }

    fn csiParam(self: *const TerminalSession, idx: usize, def: u16) u16 {
        if (idx < self.csi_param_count and self.csi_params[idx] > 0) {
            return self.csi_params[idx];
        }
        return def;
    }

    fn executeCsi(self: *TerminalSession, final_byte: u8) void {
        const eff_rows = std.math.clamp(self.rows, 1, MAX_TERM_ROWS);
        const eff_cols = std.math.clamp(self.cols, 1, MAX_TERM_COLS);
        if (self.csi_has_digits and
            self.csi_param_count < self.csi_params.len)
        {
            self.csi_param_count += 1;
        }
        switch (final_byte) {
            'A' => {
                const n: usize = self.csiParam(0, 1);
                self.cursor_row -|= n;
            },
            'B' => {
                const n: usize = self.csiParam(0, 1);
                self.cursor_row = @min(eff_rows - 1, self.cursor_row + n);
            },
            'C' => {
                const n: usize = self.csiParam(0, 1);
                self.cursor_col = @min(eff_cols - 1, self.cursor_col + n);
            },
            'D' => {
                const n: usize = self.csiParam(0, 1);
                self.cursor_col -|= n;
            },
            'G' => {
                const col1: usize = self.csiParam(0, 1);
                self.cursor_col = @min(eff_cols - 1, col1 -| 1);
            },
            'H', 'f' => {
                const r1: usize = self.csiParam(0, 1);
                const c1: usize = self.csiParam(1, 1);
                self.cursor_row = @min(eff_rows - 1, r1 -| 1);
                self.cursor_col = @min(eff_cols - 1, c1 -| 1);
            },
            'J' => {
                const mode = self.csiParam(0, 0);
                if (mode == 2 or mode == 3) {
                    self.clearScreen();
                } else if (mode == 0) {
                    for (self.cursor_col..MAX_TERM_COLS) |c| {
                        self.grid[self.cursor_row][c] = ' ';
                    }
                    for (self.cursor_row + 1..MAX_TERM_ROWS) |r| {
                        self.grid[r] = @splat(' ');
                    }
                }
            },
            'K' => {
                const mode = self.csiParam(0, 0);
                if (mode == 0) {
                    for (self.cursor_col..MAX_TERM_COLS) |c| {
                        self.grid[self.cursor_row][c] = ' ';
                    }
                } else if (mode == 1) {
                    const end_c = @min(MAX_TERM_COLS, self.cursor_col + 1);
                    for (0..end_c) |c| self.grid[self.cursor_row][c] = ' ';
                } else if (mode == 2) {
                    self.grid[self.cursor_row] = @splat(' ');
                }
            },
            else => {},
        }
    }

    pub fn putByte(self: *TerminalSession, b: u8) void {
        const eff_cols = std.math.clamp(self.cols, 1, MAX_TERM_COLS);
        switch (self.esc_state) {
            .ground => switch (b) {
                0x1b => self.esc_state = .esc,
                '\r' => self.cursor_col = 0,
                '\n' => {
                    self.cursor_col = 0;
                    self.lineFeed();
                },
                0x08 => self.cursor_col -|= 1,
                '\t' => {
                    const next_tab = (self.cursor_col + 8) & ~@as(usize, 7);
                    self.cursor_col = @min(eff_cols - 1, next_tab);
                },
                0x20...0x7e => {
                    if (self.cursor_col >= eff_cols) {
                        self.cursor_col = 0;
                        self.lineFeed();
                    }
                    self.grid[self.cursor_row][self.cursor_col] = b;
                    self.cursor_col += 1;
                },
                else => {},
            },
            .esc => switch (b) {
                '[' => {
                    self.resetCsi();
                    self.esc_state = .csi;
                },
                ']' => self.esc_state = .osc,
                'c' => self.clearScreen(),
                else => self.esc_state = .ground,
            },
            .csi => {
                if (b >= '0' and b <= '9') {
                    const idx = self.csi_param_count;
                    if (idx < self.csi_params.len) {
                        self.csi_params[idx] = self.csi_params[idx] *| 10 +|
                            @as(u16, b - '0');
                    }
                    self.csi_has_digits = true;
                } else if (b == ';') {
                    if (self.csi_param_count < self.csi_params.len) {
                        self.csi_param_count += 1;
                    }
                    self.csi_has_digits = false;
                } else if (b >= 0x40 and b <= 0x7e) {
                    self.executeCsi(b);
                    self.esc_state = .ground;
                }
            },
            .osc => {
                if (b == 0x07 or b == '\n') {
                    self.esc_state = .ground;
                }
            },
        }
    }

    pub fn feedBytes(self: *TerminalSession, data: []const u8) bool {
        if (data.len == 0) return false;
        for (data) |b| self.putByte(b);
        return true;
    }

    pub fn closeSession(self: *TerminalSession) void {
        if (self.pty_master_fd >= 0) {
            _ = linux.close(self.pty_master_fd);
            self.pty_master_fd = -1;
        }
        if (self.child_pid > 0) {
            _ = linux.kill(self.child_pid, linux.SIG.HUP);
            var status: i32 = 0;
            _ = linux.waitpid(self.child_pid, &status, linux.W.NOHANG);
            self.child_pid = -1;
        }
        self.active = false;
        self.exited = false;
    }

    pub fn openSession(
        self: *TerminalSession,
        cid: u64,
        name: []const u8,
        mode: TerminalMode,
    ) void {
        self.closeSession();
        self.clearScreen();
        self.active = true;
        self.target_cid = cid;
        self.mode = mode;
        self.mock_tx_len = 0;

        const n_len: usize = @min(name.len, GUEST_TITLE_CAP - 1);
        @memcpy(self.guest_name[0..n_len], name[0..n_len]);
        self.guest_name[n_len] = 0;
        self.guest_name_len = n_len;

        var banner_buf: [128]u8 = undefined;
        if (mode == .console) {
            const banner = std.fmt.bufPrint(
                &banner_buf,
                "[Attached to '{s}' (CID {d}) hvc0 serial console]\n",
                .{ self.getGuestName(), cid },
            ) catch "[Attached to serial console]\n";
            _ = self.feedBytes(banner);
            _ = io_mod.pollConsoleIo(self);
            return;
        }

        if (builtin.is_test or host_info.guests.mock_running_guests != null or
            host_info.mock_hypervisor_info != null)
        {
            const banner = std.fmt.bufPrint(
                &banner_buf,
                "[Connected to '{s}' (CID {d}) via {s}]\n# ",
                .{ self.getGuestName(), cid, mode.label() },
            ) catch "[Connected]\n# ";
            _ = self.feedBytes(banner);
            return;
        }

        io_mod.spawnPtyProcess(self);
    }

    pub fn sendBytes(self: *TerminalSession, data: []const u8) void {
        if (!self.active or data.len == 0) return;

        for (data) |b| {
            if (self.mock_tx_len < MOCK_TX_CAP) {
                self.mock_tx_buf[self.mock_tx_len] = b;
                self.mock_tx_len += 1;
            }
        }

        if (builtin.is_test or host_info.guests.mock_running_guests != null or
            host_info.mock_hypervisor_info != null)
        {
            for (data) |b| {
                if (b == 0x7f or b == 0x08) {
                    _ = self.feedBytes("\x08 \x08");
                } else {
                    self.putByte(b);
                }
            }
            return;
        }

        io_mod.sendConsoleOrPtyBytes(self, data);
    }

    pub fn poll(self: *TerminalSession) bool {
        if (!self.active) return false;
        if (self.mode == .console) {
            return io_mod.pollConsoleIo(self);
        }
        return io_mod.pollPtyIo(self);
    }
};

test "terminal: VT100 escape sequences, scrolling, and mock session I/O" {
    _ = io_mod;
    std.testing.refAllDecls(@This());
    var term = TerminalSession{};
    term.openSession(2, "new-guest", .ssh);
    try std.testing.expect(term.active);
    try std.testing.expectEqual(@as(u64, 2), term.target_cid);
    try std.testing.expectEqualStrings(
        "[Connected to 'new-guest' (CID 2) via SSH]",
        term.getRowTrimmed(0),
    );

    term.sendBytes("uname -a\n");
    try std.testing.expectEqualStrings("uname -a\n", term.getMockSentBytes());
    try std.testing.expectEqualStrings("# uname -a", term.getRowTrimmed(1));

    // ANSI color SGR and clear line K.
    _ = term.feedBytes("\x1b[32mLinux riscv64\x1b[0m\r\x1b[2KReady");
    try std.testing.expectEqualStrings("Ready", term.getRowTrimmed(2));

    // Clear screen CSI 2J + cursor home CSI H.
    _ = term.feedBytes("\x1b[2J\x1b[HTopLine");
    try std.testing.expectEqualStrings("TopLine", term.getRowTrimmed(0));
    term.closeSession();
    try std.testing.expect(!term.active);
}
