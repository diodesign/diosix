// Remote Desktop (RFB / VNC) Client Task for Diosix Window Manager
// Allows diosix-wm to host a full remote guest desktop (Debian XFCE/LXQt) inside a native Wuss window.
const std = @import("std");
const linux = std.os.linux;
const fb = @import("framebuffer.zig");
const font = @import("font.zig");
const win_mod = @import("window.zig");

pub const RFB_VERSION_STRING = "RFB 003.008\n";

pub const State = enum {
    disconnected,
    connecting,
    handshake_version,
    handshake_security,
    handshake_security_result,
    handshake_client_init,
    handshake_server_init,
    connected,
    error_state,
};

pub const RemoteDesktop = struct {
    allocator: std.mem.Allocator,
    sock_fd: i32 = -1,

    host_ip: [32]u8 = @splat(0),
    host_len: usize = 0,
    port: u16 = 5900,

    state: State = .disconnected,

    desktop_width: u32 = 1024,
    desktop_height: u32 = 768,
    desktop_name: [64]u8 = @splat(0),
    desktop_name_len: usize = 0,

    surface: ?fb.Surface = null,
    button_mask: u8 = 0,

    last_attempt_sec: i64 = 0,
    retry_count: u32 = 0,
    status_buf: [128]u8 = @splat(0),
    status_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, ip: []const u8, port: u16) RemoteDesktop {
        var rd = RemoteDesktop{
            .allocator = allocator,
            .port = port,
        };
        const default_ip = "10.0.3.2";
        const actual_ip = if (ip.len > 0) ip else default_ip;
        const copy_len = @min(actual_ip.len, rd.host_ip.len - 1);
        @memcpy(rd.host_ip[0..copy_len], actual_ip[0..copy_len]);
        rd.host_ip[copy_len] = 0;
        rd.host_len = copy_len;
        rd.setStatus("Ready to connect to guest desktop");
        return rd;
    }

    pub fn deinit(self: *RemoteDesktop) void {
        self.disconnect();
        if (self.surface) |*s| {
            s.deinit(self.allocator);
            self.surface = null;
        }
    }

    pub fn setStatus(self: *RemoteDesktop, text: []const u8) void {
        const copy_len = @min(text.len, self.status_buf.len);
        @memcpy(self.status_buf[0..copy_len], text[0..copy_len]);
        self.status_len = copy_len;
    }

    pub fn statusText(self: *const RemoteDesktop) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    pub fn disconnect(self: *RemoteDesktop) void {
        if (self.sock_fd >= 0) {
            _ = linux.close(self.sock_fd);
            self.sock_fd = -1;
        }
        self.state = .disconnected;
    }

    fn parseIpv4(ip_str: []const u8) ?u32 {
        var parts: [4]u8 = undefined;
        var part_idx: usize = 0;
        var current: u16 = 0;
        var has_digits = false;

        for (ip_str) |c| {
            if (c >= '0' and c <= '9') {
                current = current * 10 + (c - '0');
                if (current > 255) return null;
                has_digits = true;
            } else if (c == '.') {
                if (!has_digits or part_idx >= 3) return null;
                parts[part_idx] = @intCast(current);
                part_idx += 1;
                current = 0;
                has_digits = false;
            } else {
                break;
            }
        }
        if (!has_digits or part_idx != 3) return null;
        parts[3] = @intCast(current);

        // Network byte order: first octet in lowest memory byte
        return @as(u32, parts[0]) |
            (@as(u32, parts[1]) << 8) |
            (@as(u32, parts[2]) << 16) |
            (@as(u32, parts[3]) << 24);
    }

    pub fn tryConnect(self: *RemoteDesktop) bool {
        if (self.sock_fd >= 0) return true;

        const ip_bytes = self.host_ip[0..self.host_len];
        const parsed_ip = parseIpv4(ip_bytes) orelse return false;

        const s = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK, 0);
        const signed_s: isize = @bitCast(s);
        if (signed_s < 0) {
            self.setStatus("Failed to create socket");
            self.state = .error_state;
            return false;
        }
        const fd: i32 = @intCast(signed_s);

        const SockaddrIn = extern struct {
            family: u16,
            port: u16,
            addr: u32,
            zero: [8]u8 = @splat(0),
        };

        const port_be = @as(u16, (self.port >> 8) | (self.port << 8));
        const addr = SockaddrIn{
            .family = linux.AF.INET,
            .port = port_be,
            .addr = parsed_ip,
        };

        const conn_res = linux.connect(fd, @ptrCast(&addr), @sizeOf(SockaddrIn));
        const signed_conn: isize = @bitCast(conn_res);

        self.sock_fd = fd;
        if (signed_conn == 0) {
            self.state = .handshake_version;
            self.setStatus("Connected. Negotiating protocol...");
            return true;
        } else if (signed_conn == -@as(isize, 115)) { // EINPROGRESS = 115
            self.state = .connecting;
            self.setStatus("Connecting to desktop session...");
            return true;
        } else {
            _ = linux.close(fd);
            self.sock_fd = -1;
            self.state = .disconnected;
            self.setStatus("Connection refused. Guest VNC service not running.");
            return false;
        }
    }

    pub fn pollNetwork(self: *RemoteDesktop, win: *win_mod.Window) void {
        if (self.sock_fd < 0) return;

        switch (self.state) {
            .connecting => {
                // Check if socket is writable
                var pfd = linux.pollfd{
                    .fd = self.sock_fd,
                    .events = linux.POLL.OUT | linux.POLL.ERR,
                    .revents = 0,
                };
                const pres = linux.poll(@ptrCast(&pfd), 1, 0);
                if (pres > 0) {
                    if ((pfd.revents & (linux.POLL.ERR | linux.POLL.HUP)) != 0) {
                        self.disconnect();
                        self.setStatus("VNC server closed connection");
                        win.invalidateAll();
                        return;
                    }
                    if ((pfd.revents & linux.POLL.OUT) != 0) {
                        self.state = .handshake_version;
                        self.setStatus("Negotiating RFB version...");
                        win.invalidateAll();
                    }
                }
            },
            .handshake_version => {
                var ver_buf: [12]u8 = undefined;
                const r = linux.read(self.sock_fd, @ptrCast(&ver_buf), 12);
                if (r == 12) {
                    // Send matching version string back
                    _ = linux.write(self.sock_fd, RFB_VERSION_STRING.ptr, RFB_VERSION_STRING.len);
                    self.state = .handshake_security;
                    self.setStatus("Negotiating authentication...");
                }
            },
            .handshake_security => {
                var num_types: [1]u8 = undefined;
                const r = linux.read(self.sock_fd, @ptrCast(&num_types), 1);
                if (r == 1) {
                    if (num_types[0] == 0) {
                        self.setStatus("Security negotiation failed");
                        self.state = .error_state;
                        return;
                    }
                    var sec_types: [16]u8 = undefined;
                    const n_to_read = @min(@as(usize, num_types[0]), 16);
                    _ = linux.read(self.sock_fd, @ptrCast(&sec_types), n_to_read);

                    // Choose Security Type 1: None (standard for isolated guest VM)
                    var chosen: [1]u8 = .{1};
                    _ = linux.write(self.sock_fd, @ptrCast(&chosen), 1);
                    self.state = .handshake_security_result;
                }
            },
            .handshake_security_result => {
                var res_buf: [4]u8 = undefined;
                const r = linux.read(self.sock_fd, @ptrCast(&res_buf), 4);
                if (r == 4) {
                    const res = std.mem.readInt(u32, res_buf[0..4], .big);
                    if (res == 0) {
                        // Send ClientInit: shared-flag = 1
                        var client_init: [1]u8 = .{1};
                        _ = linux.write(self.sock_fd, @ptrCast(&client_init), 1);
                        self.state = .handshake_server_init;
                        self.setStatus("Initializing display dimensions...");
                    } else {
                        self.setStatus("VNC authentication rejected");
                        self.state = .error_state;
                    }
                }
            },
            .handshake_server_init => {
                var init_buf: [24]u8 = undefined;
                const r = linux.read(self.sock_fd, @ptrCast(&init_buf), 24);
                if (r == 24) {
                    self.desktop_width = std.mem.readInt(u16, init_buf[0..2], .big);
                    self.desktop_height = std.mem.readInt(u16, init_buf[2..4], .big);
                    const name_len = std.mem.readInt(u32, init_buf[20..24], .big);

                    if (name_len > 0) {
                        var name_tmp: [64]u8 = undefined;
                        const to_read = @min(name_len, 63);
                        _ = linux.read(self.sock_fd, @ptrCast(&name_tmp), to_read);
                        @memcpy(self.desktop_name[0..to_read], name_tmp[0..to_read]);
                        self.desktop_name_len = to_read;
                    }

                    // Allocate internal desktop canvas
                    if (self.surface) |*s| s.deinit(self.allocator);
                    self.surface = fb.Surface.init(self.allocator, self.desktop_width, self.desktop_height) catch null;
                    if (self.surface) |*s| {
                        s.clear(0x0014161C); // Initial dark charcoal background
                    }

                    // Update window work area dimensions to match guest desktop size
                    win.setExtent(self.desktop_width, self.desktop_height);

                    // Send SetPixelFormat: 32bpp, TrueColor, 0x00RRGGBB native format
                    var pix_fmt_msg: [20]u8 = @splat(0);
                    pix_fmt_msg[0] = 0; // msg type: SetPixelFormat
                    pix_fmt_msg[4] = 32; // bpp
                    pix_fmt_msg[5] = 24; // depth
                    pix_fmt_msg[6] = 0; // big endian
                    pix_fmt_msg[7] = 1; // true color
                    std.mem.writeInt(u16, pix_fmt_msg[8..10], 255, .big); // red_max
                    std.mem.writeInt(u16, pix_fmt_msg[10..12], 255, .big); // green_max
                    std.mem.writeInt(u16, pix_fmt_msg[12..14], 255, .big); // blue_max
                    pix_fmt_msg[14] = 16; // red_shift
                    pix_fmt_msg[15] = 8; // green_shift
                    pix_fmt_msg[16] = 0; // blue_shift
                    _ = linux.write(self.sock_fd, @ptrCast(&pix_fmt_msg), 20);

                    // Send SetEncodings: Raw (0)
                    var enc_msg: [8]u8 = @splat(0);
                    enc_msg[0] = 2; // SetEncodings
                    std.mem.writeInt(u16, enc_msg[2..4], 1, .big); // 1 encoding
                    std.mem.writeInt(i32, enc_msg[4..8], 0, .big); // 0 = Raw
                    _ = linux.write(self.sock_fd, @ptrCast(&enc_msg), 8);

                    // Send initial FramebufferUpdateRequest: non-incremental
                    self.requestUpdate(false);

                    self.state = .connected;
                    self.setStatus("Connected to Debian Desktop");
                    win.invalidateAll();
                }
            },
            .connected => {
                self.processConnectedMessages(win);
            },
            else => {},
        }
    }

    fn requestUpdate(self: *RemoteDesktop, incremental: bool) void {
        if (self.sock_fd < 0) return;
        var req: [10]u8 = undefined;
        req[0] = 3; // FramebufferUpdateRequest
        req[1] = if (incremental) 1 else 0;
        std.mem.writeInt(u16, req[2..4], 0, .big); // x
        std.mem.writeInt(u16, req[4..6], 0, .big); // y
        std.mem.writeInt(u16, req[6..8], @intCast(@min(self.desktop_width, 65535)), .big);
        std.mem.writeInt(u16, req[8..10], @intCast(@min(self.desktop_height, 65535)), .big);
        _ = linux.write(self.sock_fd, @ptrCast(&req), 10);
    }

    fn processConnectedMessages(self: *RemoteDesktop, win: *win_mod.Window) void {
        while (true) {
            var msg_type_buf: [1]u8 = undefined;
            const r = linux.read(self.sock_fd, @ptrCast(&msg_type_buf), 1);
            if (r <= 0) break;

            const msg_type = msg_type_buf[0];
            switch (msg_type) {
                0 => { // FramebufferUpdate
                    var header: [3]u8 = undefined; // pad (1), num_rects (2)
                    if (linux.read(self.sock_fd, @ptrCast(&header), 3) < 3) break;
                    const num_rects = std.mem.readInt(u16, header[1..3], .big);

                    var i: usize = 0;
                    while (i < num_rects) : (i += 1) {
                        var rect_hdr: [12]u8 = undefined;
                        if (linux.read(self.sock_fd, @ptrCast(&rect_hdr), 12) < 12) break;
                        const rx = std.mem.readInt(u16, rect_hdr[0..2], .big);
                        const ry = std.mem.readInt(u16, rect_hdr[2..4], .big);
                        const rw = std.mem.readInt(u16, rect_hdr[4..6], .big);
                        const rh = std.mem.readInt(u16, rect_hdr[6..8], .big);
                        const encoding = std.mem.readInt(i32, rect_hdr[8..12], .big);

                        if (encoding == 0 and rw > 0 and rh > 0) { // Raw
                            if (self.surface) |*surf| {
                                var row: usize = 0;
                                while (row < rh) : (row += 1) {
                                    const y = ry + row;
                                    if (y >= surf.height) break;
                                    const dst_offset = y * (surf.stride / 4) + rx;
                                    const dst_slice = std.mem.sliceAsBytes(surf.pixels[dst_offset .. dst_offset + rw]);
                                    _ = linux.read(self.sock_fd, @ptrCast(dst_slice.ptr), rw * 4);
                                }
                            }
                        }
                    }

                    // Request next incremental frame and redraw
                    self.requestUpdate(true);
                    win.invalidateAll();
                },
                3 => { // ServerCutText (Clipboard)
                    var cut_hdr: [7]u8 = undefined;
                    _ = linux.read(self.sock_fd, @ptrCast(&cut_hdr), 7);
                },
                else => {
                    break;
                },
            }
        }
    }

    pub fn handlePointer(self: *RemoteDesktop, x: i32, y: i32, action: win_mod.MouseAction, button: win_mod.Button) void {
        if (self.sock_fd < 0 or self.state != .connected) return;

        switch (button) {
            .select => {
                if (action == .down) self.button_mask |= 1 else self.button_mask &= ~@as(u8, 1);
            },
            .menu => {
                if (action == .down) self.button_mask |= 2 else self.button_mask &= ~@as(u8, 2);
            },
            .adjust => {
                if (action == .down) self.button_mask |= 4 else self.button_mask &= ~@as(u8, 4);
            },
        }

        const cx: u16 = @intCast(std.math.clamp(x, 0, @as(i32, @intCast(self.desktop_width)) - 1));
        const cy: u16 = @intCast(std.math.clamp(y, 0, @as(i32, @intCast(self.desktop_height)) - 1));

        var ptr_msg: [6]u8 = undefined;
        ptr_msg[0] = 5; // PointerEvent
        ptr_msg[1] = self.button_mask;
        std.mem.writeInt(u16, ptr_msg[2..4], cx, .big);
        std.mem.writeInt(u16, ptr_msg[4..6], cy, .big);
        _ = linux.write(self.sock_fd, @ptrCast(&ptr_msg), 6);
    }

    pub fn handleScroll(self: *RemoteDesktop, x: i32, y: i32, delta: i32) void {
        if (self.sock_fd < 0 or self.state != .connected) return;
        const cx: u16 = @intCast(std.math.clamp(x, 0, @as(i32, @intCast(self.desktop_width)) - 1));
        const cy: u16 = @intCast(std.math.clamp(y, 0, @as(i32, @intCast(self.desktop_height)) - 1));

        const scroll_bit: u8 = if (delta > 0) 8 else 16; // Button 4 (Up) or 5 (Down)
        var msg: [6]u8 = undefined;
        msg[0] = 5;
        msg[1] = self.button_mask | scroll_bit;
        std.mem.writeInt(u16, msg[2..4], cx, .big);
        std.mem.writeInt(u16, msg[4..6], cy, .big);
        _ = linux.write(self.sock_fd, @ptrCast(&msg), 6);

        // Immediate release
        msg[1] = self.button_mask;
        _ = linux.write(self.sock_fd, @ptrCast(&msg), 6);
    }

    pub fn handleKey(self: *RemoteDesktop, code: u16, value: i32) void {
        if (self.sock_fd < 0 or self.state != .connected) return;

        const keysym = evdevToKeysym(code) orelse return;
        var key_msg: [8]u8 = undefined;
        key_msg[0] = 4; // KeyEvent
        key_msg[1] = if (value != 0) 1 else 0; // Down flag
        key_msg[2] = 0;
        key_msg[3] = 0;
        std.mem.writeInt(u32, key_msg[4..8], keysym, .big);
        _ = linux.write(self.sock_fd, @ptrCast(&key_msg), 8);
    }

    pub fn draw(self: *RemoteDesktop, surf: *fb.Surface, content: fb.Box, bounds: fb.Box, scroll: fb.Point) void {
        _ = content;
        surf.setClip(bounds);

        if (self.state == .connected and self.surface != null) {
            const dt = &self.surface.?;
            // Copy relevant portion of desktop surface into window content
            const src_x0 = std.math.clamp(scroll.x, 0, @as(i32, @intCast(dt.width)));
            const src_y0 = std.math.clamp(scroll.y, 0, @as(i32, @intCast(dt.height)));
            const copy_w = @min(@as(u32, @intCast(@max(0, @as(i32, @intCast(dt.width)) - src_x0))), bounds.width());
            const copy_h = @min(@as(u32, @intCast(@max(0, @as(i32, @intCast(dt.height)) - src_y0))), bounds.height());

            if (copy_w > 0 and copy_h > 0) {
                const src_box = fb.Box.fromPosSize(src_x0, src_y0, copy_w, copy_h);
                const dst_box = fb.Box.fromPosSize(bounds.x0, bounds.y0, copy_w, copy_h);

                var y: u32 = 0;
                while (y < copy_h) : (y += 1) {
                    const src_row = (src_box.y0 + @as(i32, @intCast(y))) * @as(i32, @intCast(dt.stride / 4)) + src_box.x0;
                    const dst_row = (dst_box.y0 + @as(i32, @intCast(y))) * @as(i32, @intCast(surf.stride / 4)) + dst_box.x0;
                    if (src_row >= 0 and dst_row >= 0) {
                        const s_idx: usize = @intCast(src_row);
                        const d_idx: usize = @intCast(dst_row);
                        if (s_idx + copy_w <= dt.pixels.len and d_idx + copy_w <= surf.pixels.len) {
                            @memcpy(surf.pixels[d_idx .. d_idx + copy_w], dt.pixels[s_idx .. s_idx + copy_w]);
                        }
                    }
                }
            }
        } else {
            // Render connecting placeholder screen
            surf.fillBox(bounds, 0x00181A20); // Dark sleek background

            const center_x = bounds.x0 + @divTrunc(@as(i32, @intCast(bounds.width())), 2);
            const center_y = bounds.y0 + @divTrunc(@as(i32, @intCast(bounds.height())), 2);

            // Draw decorative dialog card
            const card_w: u32 = @min(bounds.width() - 40, 480);
            const card_h: u32 = 180;
            const card_x = center_x - @divTrunc(@as(i32, @intCast(card_w)), 2);
            const card_y = center_y - @divTrunc(@as(i32, @intCast(card_h)), 2);
            const card_box = fb.Box.fromPosSize(card_x, card_y, card_w, card_h);

            surf.fillBox(card_box, 0x00232732);
            surf.drawBoxOutline(card_box, 1, 0x003A4050);

            // Title
            const title = "Debian RISC-V Desktop Session";
            const title_x = card_x + 24;
            const title_y = card_y + 24;
            font.drawText(surf, title, title_x, title_y, 0x00FFFFFF);

            // Divider line
            const div_box = fb.Box.fromPosSize(card_x + 20, card_y + 52, card_w - 40, 1);
            surf.fillBox(div_box, 0x003A4050);

            // Status message
            const status_str = self.statusText();
            font.drawText(surf, status_str, card_x + 24, card_y + 70, 0x0000D084);

            // Target host detail
            var host_buf: [64]u8 = undefined;
            const host_str = std.fmt.bufPrint(&host_buf, "Target: {s}:{d} (Virtual Net: diosix0)", .{ self.host_ip[0..self.host_len], self.port }) catch "";
            font.drawText(surf, host_str, card_x + 24, card_y + 98, 0x00A0A8B8);

            // Instructions
            const tip = "Tip: Launch VNC inside guest with: dsx ssh debian-vm";
            font.drawText(surf, tip, card_x + 24, card_y + 130, 0x006E7688);
        }

        surf.resetClip();
    }
};

// Map Linux evdev input keycodes to standard X11 Keysyms expected by RFB/VNC
pub fn evdevToKeysym(code: u16) ?u32 {
    return switch (code) {
        1 => 0xFF1B, // Escape
        2 => 0x0031, // 1
        3 => 0x0032, // 2
        4 => 0x0033, // 3
        5 => 0x0034, // 4
        6 => 0x0035, // 5
        7 => 0x0036, // 6
        8 => 0x0037, // 7
        9 => 0x0038, // 8
        10 => 0x0039, // 9
        11 => 0x0030, // 0
        12 => 0x002D, // Minus
        13 => 0x003D, // Equal
        14 => 0xFF08, // Backspace
        15 => 0xFF09, // Tab
        16 => 0x0071, // q
        17 => 0x0077, // w
        18 => 0x0065, // e
        19 => 0x0072, // r
        20 => 0x0074, // t
        21 => 0x0079, // y
        22 => 0x0075, // u
        23 => 0x0069, // i
        24 => 0x006F, // o
        25 => 0x0070, // p
        26 => 0x005B, // [
        27 => 0x005D, // ]
        28 => 0xFF0D, // Enter
        29 => 0xFFE3, // Left Ctrl
        30 => 0x0061, // a
        31 => 0x0073, // s
        32 => 0x0064, // d
        33 => 0x0066, // f
        34 => 0x0067, // g
        35 => 0x0068, // h
        36 => 0x006A, // j
        37 => 0x006B, // k
        38 => 0x006C, // l
        39 => 0x003B, // Semicolon
        40 => 0x0027, // Quote
        41 => 0x0060, // Grave
        42 => 0xFFE1, // Left Shift
        43 => 0x005C, // Backslash
        44 => 0x007A, // z
        45 => 0x0078, // x
        46 => 0x0063, // c
        47 => 0x0076, // v
        48 => 0x0062, // b
        49 => 0x006E, // n
        50 => 0x006D, // m
        51 => 0x002C, // Comma
        52 => 0x002E, // Period
        53 => 0x002F, // Slash
        54 => 0xFFE2, // Right Shift
        56 => 0xFFE9, // Left Alt
        57 => 0x0020, // Space
        97 => 0xFFE4, // Right Ctrl
        100 => 0xFFEA, // Right Alt
        103 => 0xFF52, // Up
        105 => 0xFF51, // Left
        106 => 0xFF53, // Right
        108 => 0xFF54, // Down
        111 => 0xFFFF, // Delete
        125 => 0xFFEB, // Super / Meta
        else => null,
    };
}

// Global Remote Desktop instance
pub var global_remote_desktop: ?RemoteDesktop = null;

pub fn remoteDesktopTaskHandle(win: *win_mod.Window, ev: *const win_mod.Event, data_ptr: ?*anyopaque) anyerror!void {
    const rd = if (data_ptr) |p| @as(*RemoteDesktop, @ptrCast(@alignCast(p))) else if (global_remote_desktop) |*g| g else return;

    switch (ev.kind) {
        .redraw => {
            rd.draw(
                ev.data.redraw.surface,
                ev.data.redraw.content,
                ev.data.redraw.bounds,
                ev.data.redraw.scroll,
            );
        },
        .mouse => {
            rd.handlePointer(
                ev.data.mouse.point.x,
                ev.data.mouse.point.y,
                ev.data.mouse.action,
                ev.data.mouse.button,
            );
        },
        .scroll => {
            rd.handleScroll(
                ev.data.scroll.point.x,
                ev.data.scroll.point.y,
                ev.data.scroll.delta,
            );
        },
        .key => {
            rd.handleKey(ev.data.key.code, ev.data.key.value);
        },
        .idle => {
            // If disconnected, retry every 3 seconds
            if (rd.state == .disconnected) {
                _ = rd.tryConnect();
            }
            rd.pollNetwork(win);
        },
        .close, .quit => {
            rd.disconnect();
        },
        else => {},
    }
}

test "remote_desktop: ipv4 parsing and keysym translation" {
    const testing = std.testing;

    // Test IPv4 parsing
    const ip = RemoteDesktop.parseIpv4("10.0.3.2");
    try testing.expect(ip != null);
    try testing.expectEqual(@as(u32, 0x0203000a), ip.?);

    // Test keysym translation
    try testing.expectEqual(@as(?u32, 0xFF0D), evdevToKeysym(28)); // Enter
    try testing.expectEqual(@as(?u32, 0xFF1B), evdevToKeysym(1)); // Esc
    try testing.expectEqual(@as(?u32, 0x0020), evdevToKeysym(57)); // Space
    try testing.expectEqual(@as(?u32, 0x0061), evdevToKeysym(30)); // 'a'
}
