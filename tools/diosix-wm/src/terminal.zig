// Terminal Emulator for Diosix Window Manager
// Provides interactive PTY shell access to the Linux guest VM within a Wuss window
const std = @import("std");
const linux = std.os.linux;
const fb = @import("framebuffer.zig");
const font = @import("font.zig");
const win_mod = @import("window.zig");

pub const MAX_COLS: usize = 120;
pub const MAX_ROWS: usize = 256;

pub const DEFAULT_FG: u32 = 0x00E8E8E8;
pub const DEFAULT_BG: u32 = 0x0014161C;
pub const CURSOR_COLOR: u32 = 0x0000D084;
pub const CELL_WIDTH: i32 = 11;
pub const CELL_HEIGHT: i32 = 20;

pub const ANSI_COLORS = [_]u32{
    0x00000000, // 0: Black
    0x00CD3131, // 1: Red
    0x000DBC79, // 2: Green
    0x00E5E510, // 3: Yellow
    0x002472C8, // 4: Blue
    0x00BC3FBC, // 5: Magenta
    0x0011A8CD, // 6: Cyan
    0x00E5E5E5, // 7: White
};

pub const ANSI_BRIGHT_COLORS = [_]u32{
    0x00666666, // 8: Bright Black (Grey)
    0x00F14C4C, // 9: Bright Red
    0x0023D18B, // 10: Bright Green
    0x00F5F543, // 11: Bright Yellow
    0x003B8EEA, // 12: Bright Blue
    0x00D670D6, // 13: Bright Magenta
    0x0029B8DB, // 14: Bright Cyan
    0x00FFFFFF, // 15: Bright White
};

// Linux PTY ioctls
const TIOCGPTN: u32 = 0x80045430;
const TIOCSPTLCK: u32 = 0x40045431;
const TIOCSCTTY: u32 = 0x540E;
const TIOCSWINSZ: u32 = 0x5414;

pub const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

pub const EscapeState = enum {
    ground,
    escape,
    csi,
    osc,
};

pub const Terminal = struct {
    master_fd: i32 = -1,
    child_pid: i32 = -1,

    cols: usize = 80,
    rows: usize = 24,

    // Compact flat 2D arrays for instant compilation and minimal memory
    chars: [MAX_ROWS][MAX_COLS]u8 = @splat(@splat(' ')),
    colors: [MAX_ROWS][MAX_COLS]u8 = @splat(@splat(7)),
    line_lens: [MAX_ROWS]usize = @splat(0),
    ring_start: usize = 0,

    cursor_col: usize = 0,
    cursor_row: usize = 0,

    history_count: usize = 0,
    scroll_offset: usize = 0,

    current_fg: u8 = 7, // Default white/silver (index 7)

    cursor_visible: bool = true,
    blink_on: bool = true,
    blink_counter: u32 = 0,

    shift_down: bool = false,
    ctrl_down: bool = false,
    alt_down: bool = false,
    caps_lock: bool = false,

    escape_state: EscapeState = .ground,
    esc_buf: [64]u8 = undefined,
    esc_len: usize = 0,

    saved_col: usize = 0,
    saved_row: usize = 0,

    pub fn init() Terminal {
        return Terminal{};
    }

    pub fn deinit(self: *Terminal) void {
        if (self.child_pid > 0) {
            _ = linux.kill(self.child_pid, linux.SIG.TERM);
            self.child_pid = -1;
        }
        if (self.master_fd >= 0) {
            _ = linux.close(self.master_fd);
            self.master_fd = -1;
        }
    }

    pub fn clearScreen(self: *Terminal) void {
        for (0..MAX_ROWS) |r| {
            @memset(&self.chars[r], ' ');
            @memset(&self.colors[r], 7);
            self.line_lens[r] = 0;
        }
        self.cursor_col = 0;
        self.cursor_row = 0;
        self.ring_start = 0;
        self.history_count = 0;
        self.scroll_offset = 0;
    }

    pub fn spawnShell(self: *Terminal) !void {
        // 1. Open master PTY
        const ptmx_rc = linux.open("/dev/ptmx\x00", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
        const s_ptmx: isize = @bitCast(ptmx_rc);
        if (s_ptmx < 0) return error.OpenPtmxFailed;
        self.master_fd = @intCast(s_ptmx);

        // 2. Unlock PTY
        var unlock: c_int = 0;
        _ = linux.ioctl(self.master_fd, TIOCSPTLCK, @intFromPtr(&unlock));

        // 3. Query slave PTY number
        var pty_num: u32 = 0;
        _ = linux.ioctl(self.master_fd, TIOCGPTN, @intFromPtr(&pty_num));

        // 4. Set PTY window size
        var ws = Winsize{
            .ws_row = @intCast(self.rows),
            .ws_col = @intCast(self.cols),
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        _ = linux.ioctl(self.master_fd, TIOCSWINSZ, @intFromPtr(&ws));

        // 5. Fork child process
        const fork_rc = linux.fork();
        const s_fork: isize = @bitCast(fork_rc);
        if (s_fork < 0) {
            _ = linux.close(self.master_fd);
            self.master_fd = -1;
            return error.ForkFailed;
        }

        if (s_fork == 0) {
            // --- CHILD PROCESS ---
            _ = linux.setsid();

            var slave_path_buf: [32]u8 = undefined;
            const slave_path = std.fmt.bufPrint(&slave_path_buf, "/dev/pts/{d}\x00", .{pty_num}) catch "/dev/pts/0\x00";
            const slave_rc = linux.open(@ptrCast(slave_path.ptr), .{ .ACCMODE = .RDWR }, 0);
            const s_slave: isize = @bitCast(slave_rc);
            if (s_slave >= 0) {
                const slave_fd: i32 = @intCast(s_slave);
                _ = linux.ioctl(slave_fd, TIOCSCTTY, 0);

                _ = linux.dup2(slave_fd, 0);
                _ = linux.dup2(slave_fd, 1);
                _ = linux.dup2(slave_fd, 2);
                if (slave_fd > 2) _ = linux.close(slave_fd);
            }
            _ = linux.close(self.master_fd);

            const envp = [_:null]?[*:0]const u8{
                "TERM=linux",
                "HOME=/root",
                "USER=root",
                "LOGNAME=root",
                "PATH=/bin:/sbin:/usr/bin:/usr/sbin",
                "SHELL=/bin/sh",
                null,
            };

            const argv = [_:null]?[*:0]const u8{
                "/bin/sh",
                "-i",
                null,
            };

            _ = linux.execve("/bin/sh\x00", &argv, &envp);
            linux.exit(1);
        }

        // --- PARENT PROCESS ---
        self.child_pid = @intCast(s_fork);

        // Set master_fd to non-blocking (O_NONBLOCK = 0x800)
        const flags_rc = linux.fcntl(self.master_fd, linux.F.GETFL, 0);
        const s_flags: isize = @bitCast(flags_rc);
        if (s_flags >= 0) {
            _ = linux.fcntl(self.master_fd, linux.F.SETFL, @as(usize, @bitCast(s_flags)) | 0x800);
        }
    }

    pub fn readMaster(self: *Terminal) bool {
        if (self.master_fd < 0) return false;
        var buf: [1024]u8 = undefined;
        var had_data = false;
        while (true) {
            const rc = linux.read(self.master_fd, &buf, buf.len);
            const signed_rc: isize = @bitCast(rc);
            if (signed_rc <= 0) break;
            self.feed(buf[0..@as(usize, @intCast(signed_rc))]);
            had_data = true;
        }
        return had_data;
    }

    pub fn writeInput(self: *Terminal, data: []const u8) void {
        if (self.master_fd >= 0 and data.len > 0) {
            _ = linux.write(self.master_fd, data.ptr, data.len);
        }
    }

    pub fn newline(self: *Terminal) void {
        self.cursor_col = 0;
        if (self.cursor_row + 1 < self.rows) {
            self.cursor_row += 1;
        } else {
            self.scrollUp(1);
        }
    }

    pub fn scrollUp(self: *Terminal, count: usize) void {
        for (0..count) |_| {
            self.ring_start = (self.ring_start + 1) % MAX_ROWS;
            const new_line = (self.ring_start + self.rows - 1) % MAX_ROWS;
            @memset(&self.chars[new_line], ' ');
            @memset(&self.colors[new_line], self.current_fg);
            self.line_lens[new_line] = 0;
            if (self.history_count + self.rows < MAX_ROWS) {
                self.history_count += 1;
            }
        }
    }

    pub fn writeChar(self: *Terminal, ch: u8) void {
        if (self.cursor_col >= self.cols) {
            self.newline();
        }
        const phys = (self.ring_start + self.cursor_row) % MAX_ROWS;
        self.chars[phys][self.cursor_col] = ch;
        self.colors[phys][self.cursor_col] = self.current_fg;
        if (self.cursor_col + 1 > self.line_lens[phys]) {
            self.line_lens[phys] = self.cursor_col + 1;
        }
        self.cursor_col += 1;
    }

    pub fn backspace(self: *Terminal) void {
        if (self.cursor_col > 0) {
            self.cursor_col -= 1;
        }
    }

    pub fn tab(self: *Terminal) void {
        const next_stop = (self.cursor_col + 8) & ~@as(usize, 7);
        self.cursor_col = @min(next_stop, self.cols - 1);
    }

    pub fn feed(self: *Terminal, data: []const u8) void {
        for (data) |b| {
            switch (self.escape_state) {
                .ground => {
                    if (b == 0x1B) {
                        self.escape_state = .escape;
                    } else if (b == '\r') {
                        self.cursor_col = 0;
                    } else if (b == '\n') {
                        self.newline();
                    } else if (b == 0x08 or b == 0x7F) {
                        self.backspace();
                    } else if (b == '\t') {
                        self.tab();
                    } else if (b == 0x07) {
                        // Bell - ignore
                    } else if (b >= 32 and b <= 126) {
                        self.writeChar(b);
                    }
                },
                .escape => {
                    if (b == '[') {
                        self.escape_state = .csi;
                        self.esc_len = 0;
                    } else if (b == ']') {
                        self.escape_state = .osc;
                        self.esc_len = 0;
                    } else if (b == 'c') {
                        self.clearScreen();
                        self.escape_state = .ground;
                    } else if (b == '7') {
                        self.saved_col = self.cursor_col;
                        self.saved_row = self.cursor_row;
                        self.escape_state = .ground;
                    } else if (b == '8') {
                        self.cursor_col = self.saved_col;
                        self.cursor_row = self.saved_row;
                        self.escape_state = .ground;
                    } else {
                        self.escape_state = .ground;
                    }
                },
                .csi => {
                    if ((b >= '0' and b <= '9') or b == ';' or b == '?') {
                        if (self.esc_len < self.esc_buf.len) {
                            self.esc_buf[self.esc_len] = b;
                            self.esc_len += 1;
                        }
                    } else if (b >= 0x40 and b <= 0x7E) {
                        self.parseCsi(b);
                        self.escape_state = .ground;
                    } else {
                        self.escape_state = .ground;
                    }
                },
                .osc => {
                    if (b == 0x07 or b == 0x1B) {
                        self.escape_state = .ground;
                    } else if (self.esc_len < self.esc_buf.len) {
                        self.esc_buf[self.esc_len] = b;
                        self.esc_len += 1;
                    }
                },
            }
        }
    }

    fn parseCsi(self: *Terminal, cmd: u8) void {
        const slice = self.esc_buf[0..self.esc_len];
        var params: [8]i32 = @splat(0);
        var param_count: usize = 0;

        var has_digits = false;
        var cur_val: i32 = 0;
        const is_private = (slice.len > 0 and slice[0] == '?');
        const num_slice = if (is_private) slice[1..] else slice;

        for (num_slice) |ch| {
            if (ch >= '0' and ch <= '9') {
                cur_val = cur_val * 10 + (ch - '0');
                has_digits = true;
            } else if (ch == ';') {
                if (param_count < params.len) {
                    params[param_count] = cur_val;
                    param_count += 1;
                }
                cur_val = 0;
                has_digits = false;
            }
        }
        if (has_digits and param_count < params.len) {
            params[param_count] = cur_val;
            param_count += 1;
        }

        switch (cmd) {
            'H', 'f' => { // Cursor Position
                const r = if (param_count > 0 and params[0] > 0) @as(usize, @intCast(params[0] - 1)) else 0;
                const c = if (param_count > 1 and params[1] > 0) @as(usize, @intCast(params[1] - 1)) else 0;
                self.cursor_row = @min(r, self.rows - 1);
                self.cursor_col = @min(c, self.cols - 1);
            },
            'A' => { // Cursor Up
                const n = if (param_count > 0 and params[0] > 0) @as(usize, @intCast(params[0])) else 1;
                if (self.cursor_row >= n) self.cursor_row -= n else self.cursor_row = 0;
            },
            'B' => { // Cursor Down
                const n = if (param_count > 0 and params[0] > 0) @as(usize, @intCast(params[0])) else 1;
                self.cursor_row = @min(self.cursor_row + n, self.rows - 1);
            },
            'C' => { // Cursor Forward
                const n = if (param_count > 0 and params[0] > 0) @as(usize, @intCast(params[0])) else 1;
                self.cursor_col = @min(self.cursor_col + n, self.cols - 1);
            },
            'D' => { // Cursor Back
                const n = if (param_count > 0 and params[0] > 0) @as(usize, @intCast(params[0])) else 1;
                if (self.cursor_col >= n) self.cursor_col -= n else self.cursor_col = 0;
            },
            'J' => { // Erase in Display
                const mode = if (param_count > 0) params[0] else 0;
                if (mode == 2 or mode == 3) {
                    self.clearScreen();
                } else if (mode == 0) {
                    var r = self.cursor_row;
                    while (r < self.rows) : (r += 1) {
                        const phys = (self.ring_start + r) % MAX_ROWS;
                        const start_c = if (r == self.cursor_row) self.cursor_col else 0;
                        @memset(self.chars[phys][start_c..], ' ');
                        @memset(self.colors[phys][start_c..], self.current_fg);
                        self.line_lens[phys] = start_c;
                    }
                }
            },
            'K' => { // Erase in Line
                const mode = if (param_count > 0) params[0] else 0;
                const phys = (self.ring_start + self.cursor_row) % MAX_ROWS;
                if (mode == 0) {
                    @memset(self.chars[phys][self.cursor_col..], ' ');
                    @memset(self.colors[phys][self.cursor_col..], self.current_fg);
                    self.line_lens[phys] = self.cursor_col;
                } else if (mode == 1) {
                    const end_c = @min(self.cursor_col + 1, MAX_COLS);
                    @memset(self.chars[phys][0..end_c], ' ');
                    @memset(self.colors[phys][0..end_c], self.current_fg);
                } else if (mode == 2) {
                    @memset(&self.chars[phys], ' ');
                    @memset(&self.colors[phys], self.current_fg);
                    self.line_lens[phys] = 0;
                }
            },
            'm' => { // Select Graphic Rendition (Colors)
                if (param_count == 0) {
                    self.current_fg = 7;
                    return;
                }
                for (params[0..param_count]) |p| {
                    if (p == 0) {
                        self.current_fg = 7;
                    } else if (p >= 30 and p <= 37) {
                        self.current_fg = @intCast(p - 30);
                    } else if (p == 39) {
                        self.current_fg = 7;
                    } else if (p >= 90 and p <= 97) {
                        self.current_fg = @intCast(p - 90 + 8);
                    }
                }
            },
            'h' => {
                if (is_private and param_count > 0 and params[0] == 25) {
                    self.cursor_visible = true;
                }
            },
            'l' => {
                if (is_private and param_count > 0 and params[0] == 25) {
                    self.cursor_visible = false;
                }
            },
            else => {},
        }
    }

    pub fn handleKey(self: *Terminal, code: u16, value: i32) void {
        const is_press = (value != 0);

        if (code == 42 or code == 54) { // Shift
            self.shift_down = is_press;
            return;
        } else if (code == 29 or code == 97) { // Ctrl
            self.ctrl_down = is_press;
            return;
        } else if (code == 56 or code == 100) { // Alt
            self.alt_down = is_press;
            return;
        } else if (code == 58) { // CapsLock
            if (value == 1) self.caps_lock = !self.caps_lock;
            return;
        }

        if (!is_press) return;

        // Reset blink on key press so cursor is immediately visible
        self.blink_on = true;
        self.blink_counter = 0;

        switch (code) {
            // Letters A-Z
            30 => self.sendCharOrCtrl('a', 'A', 1),
            48 => self.sendCharOrCtrl('b', 'B', 2),
            46 => self.sendCharOrCtrl('c', 'C', 3), // Ctrl+C
            32 => self.sendCharOrCtrl('d', 'D', 4), // Ctrl+D
            18 => self.sendCharOrCtrl('e', 'E', 5),
            33 => self.sendCharOrCtrl('f', 'F', 6),
            34 => self.sendCharOrCtrl('g', 'G', 7),
            35 => self.sendCharOrCtrl('h', 'H', 8),
            23 => self.sendCharOrCtrl('i', 'I', 9),
            36 => self.sendCharOrCtrl('j', 'J', 10),
            37 => self.sendCharOrCtrl('k', 'K', 11),
            38 => self.sendCharOrCtrl('l', 'L', 12), // Ctrl+L (clear)
            50 => self.sendCharOrCtrl('m', 'M', 13),
            49 => self.sendCharOrCtrl('n', 'N', 14),
            24 => self.sendCharOrCtrl('o', 'O', 15),
            25 => self.sendCharOrCtrl('p', 'P', 16),
            16 => self.sendCharOrCtrl('q', 'Q', 17),
            19 => self.sendCharOrCtrl('r', 'R', 18),
            31 => self.sendCharOrCtrl('s', 'S', 19),
            20 => self.sendCharOrCtrl('t', 'T', 20),
            22 => self.sendCharOrCtrl('u', 'U', 21), // Ctrl+U (erase line)
            47 => self.sendCharOrCtrl('v', 'V', 22),
            17 => self.sendCharOrCtrl('w', 'W', 23), // Ctrl+W (erase word)
            45 => self.sendCharOrCtrl('x', 'X', 24),
            21 => self.sendCharOrCtrl('y', 'Y', 25),
            44 => self.sendCharOrCtrl('z', 'Z', 26), // Ctrl+Z

            // Numbers
            2 => self.sendChar(if (self.shift_down) '!' else '1'),
            3 => self.sendChar(if (self.shift_down) '@' else '2'),
            4 => self.sendChar(if (self.shift_down) '#' else '3'),
            5 => self.sendChar(if (self.shift_down) '$' else '4'),
            6 => self.sendChar(if (self.shift_down) '%' else '5'),
            7 => self.sendChar(if (self.shift_down) '^' else '6'),
            8 => self.sendChar(if (self.shift_down) '&' else '7'),
            9 => self.sendChar(if (self.shift_down) '*' else '8'),
            10 => self.sendChar(if (self.shift_down) '(' else '9'),
            11 => self.sendChar(if (self.shift_down) ')' else '0'),

            // Symbols
            12 => self.sendChar(if (self.shift_down) '_' else '-'),
            13 => self.sendChar(if (self.shift_down) '+' else '='),
            26 => self.sendChar(if (self.shift_down) '{' else '['),
            27 => self.sendChar(if (self.shift_down) '}' else ']'),
            39 => self.sendChar(if (self.shift_down) ':' else ';'),
            40 => self.sendChar(if (self.shift_down) '"' else '\''),
            41 => self.sendChar(if (self.shift_down) '~' else '`'),
            43 => self.sendChar(if (self.shift_down) '|' else '\\'),
            51 => self.sendChar(if (self.shift_down) '<' else ','),
            52 => self.sendChar(if (self.shift_down) '>' else '.'),
            53 => self.sendChar(if (self.shift_down) '?' else '/'),
            57 => self.sendChar(' '),

            // Control
            28 => self.sendChar('\r'), // Enter
            14 => self.sendChar(0x7F), // Backspace
            15 => self.sendChar('\t'), // Tab
            1 => self.sendChar(0x1B),  // Esc

            // Keypad
            82 => self.sendChar('0'),
            79 => self.sendChar('1'),
            80 => self.sendChar('2'),
            81 => self.sendChar('3'),
            75 => self.sendChar('4'),
            76 => self.sendChar('5'),
            77 => self.sendChar('6'),
            71 => self.sendChar('7'),
            72 => self.sendChar('8'),
            73 => self.sendChar('9'),
            96 => self.sendChar('\r'),
            78 => self.sendChar('+'),
            74 => self.sendChar('-'),
            55 => self.sendChar('*'),
            98 => self.sendChar('/'),
            83 => self.sendChar('.'),

            // Navigation
            103 => self.writeInput("\x1b[A"), // Up
            108 => self.writeInput("\x1b[B"), // Down
            106 => self.writeInput("\x1b[C"), // Right
            105 => self.writeInput("\x1b[D"), // Left
            102 => self.writeInput("\x1b[H"), // Home
            107 => self.writeInput("\x1b[F"), // End
            104 => self.writeInput("\x1b[5~"), // Page Up
            109 => self.writeInput("\x1b[6~"), // Page Down
            111 => self.writeInput("\x1b[3~"), // Delete

            else => {},
        }
    }

    fn sendCharOrCtrl(self: *Terminal, lower: u8, upper: u8, ctrl_code: u8) void {
        if (self.ctrl_down) {
            self.sendChar(ctrl_code);
        } else {
            const use_upper = self.shift_down ^ self.caps_lock;
            self.sendChar(if (use_upper) upper else lower);
        }
    }

    fn sendChar(self: *Terminal, ch: u8) void {
        const slice = [_]u8{ch};
        self.writeInput(&slice);
    }

    pub fn tickBlink(self: *Terminal, win: *win_mod.Window) void {
        self.blink_counter += 1;
        if (self.blink_counter >= 30) {
            self.blink_counter = 0;
            self.blink_on = !self.blink_on;
            win.invalidateAll();
        }
    }

    pub fn draw(
        self: *Terminal,
        surf: *fb.Surface,
        clip: fb.Box,
        bounds: fb.Box,
        scroll: fb.Point,
    ) void {
        surf.setClip(clip);
        surf.fillBox(bounds, DEFAULT_BG);

        const visible_rows = self.rows;

        for (0..visible_rows) |r| {
            const line_y = bounds.y0 + 6 + @as(i32, @intCast(r * 20)) - scroll.y;
            if (line_y + 20 < clip.y0 or line_y > clip.y1) continue;

            const physical_line = (self.ring_start + r) % MAX_ROWS;
            const line_len = self.line_lens[physical_line];

            for (0..line_len) |c| {
                const ch = self.chars[physical_line][c];
                if (ch == ' ') continue;
                const col_idx = self.colors[physical_line][c];
                const color = if (col_idx < 8) ANSI_COLORS[col_idx] else ANSI_BRIGHT_COLORS[col_idx - 8];
                const glyph = font.getGlyphOrDefault(ch);
                const char_x = bounds.x0 + 10 - scroll.x + @as(i32, @intCast(c)) * CELL_WIDTH;
                const offset_x = if (glyph.advance < CELL_WIDTH) @divTrunc(CELL_WIDTH - @as(i32, @intCast(glyph.advance)), 2) else 0;

                font.drawGlyph(surf, glyph, char_x + offset_x, line_y, color);
            }

            // Draw cursor
            if (r == self.cursor_row and self.cursor_visible and self.blink_on) {
                const cursor_x = bounds.x0 + 10 - scroll.x + @as(i32, @intCast(self.cursor_col)) * CELL_WIDTH;
                const cursor_box = fb.Box.fromPosSize(cursor_x, line_y, CELL_WIDTH, 18);
                surf.fillBox(cursor_box, CURSOR_COLOR);

                if (self.cursor_col < line_len and self.chars[physical_line][self.cursor_col] != ' ') {
                    const ch = self.chars[physical_line][self.cursor_col];
                    const glyph = font.getGlyphOrDefault(ch);
                    const offset_x = if (glyph.advance < CELL_WIDTH) @divTrunc(CELL_WIDTH - @as(i32, @intCast(glyph.advance)), 2) else 0;
                    font.drawGlyph(surf, glyph, cursor_x + offset_x, line_y, DEFAULT_BG);
                }
            }
        }

        surf.resetClip();
    }
};

// Global terminal instance for the desktop
pub var global_terminal = Terminal.init();

pub fn terminalTaskHandle(win: *win_mod.Window, ev: *const win_mod.Event, data_ptr: ?*anyopaque) anyerror!void {
    const term = if (data_ptr) |p| @as(*Terminal, @ptrCast(@alignCast(p))) else &global_terminal;

    switch (ev.kind) {
        .redraw => {
            term.draw(
                ev.data.redraw.surface,
                ev.data.redraw.content,
                ev.data.redraw.bounds,
                ev.data.redraw.scroll,
            );
        },
        .key => {
            term.handleKey(ev.data.key.code, ev.data.key.value);
            win.invalidateAll();
        },
        .scroll => {
            win.scrollStep(.{ .x = 0, .y = -ev.data.scroll.delta * win_mod.Window.SCROLL_STEP });
        },
        .idle => {
            term.tickBlink(win);
        },
        .close, .quit => {
            term.deinit();
        },
        else => {},
    }
}
