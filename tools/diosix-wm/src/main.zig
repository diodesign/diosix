const std = @import("std");
const linux = std.os.linux;
const fb = @import("framebuffer.zig");
const font = @import("font.zig");
const cursor_mod = @import("cursor.zig");
const win_mod = @import("window.zig");

const drm = @import("drm.zig");

pub const InputEvent = extern struct {
    sec: i64,
    usec: i64,
    type: u16,
    code: u16,
    value: i32,
};

pub const DisplayBackend = union(enum) {
    drm_kms: drm.DrmDevice,
    fbdev: fb.FramebufferDevice,
};

pub const Display = struct {
    backend: DisplayBackend,
    width: u32,
    height: u32,
    backbuffer: fb.Surface,
    has_hw_cursor: bool,

    pub fn init(allocator: std.mem.Allocator) !Display {
        // 1. Attempt DRM KMS hardware acceleration (/dev/dri/card0)
        if (drm.DrmDevice.init("/dev/dri/card0")) |drm_dev| {
            var dev = drm_dev;
            const w = dev.width;
            const h = dev.height;
            const bb = try fb.Surface.init(allocator, w, h);
            var hw_cursor = false;
            if (dev.has_hw_cursor) {
                dev.setHardwareCursorSprite(
                    &cursor_mod.POINTER_PIXELS,
                    cursor_mod.POINTER_WIDTH,
                    cursor_mod.POINTER_HEIGHT,
                );
                hw_cursor = true;
            }
            return Display{
                .backend = .{ .drm_kms = dev },
                .width = w,
                .height = h,
                .backbuffer = bb,
                .has_hw_cursor = hw_cursor,
            };
        } else |_| {}

        // 2. Fall back to /dev/fb0 software rendering
        const fb_dev = try fb.FramebufferDevice.init(allocator, "/dev/fb0");
        return Display{
            .backend = .{ .fbdev = fb_dev },
            .width = fb_dev.width,
            .height = fb_dev.height,
            .backbuffer = fb_dev.backbuffer,
            .has_hw_cursor = false,
        };
    }

    pub fn deinit(self: *Display, allocator: std.mem.Allocator) void {
        switch (self.backend) {
            .drm_kms => |*d| {
                self.backbuffer.deinit(allocator);
                d.deinit();
            },
            .fbdev => {
                self.backbuffer.deinit(allocator);
            },
        }
    }

    pub fn screenSurface(self: *Display) *fb.Surface {
        return switch (self.backend) {
            .drm_kms => |*d| &d.screen_surface,
            .fbdev => |*f| &f.screen_surface,
        };
    }

    pub fn moveCursor(self: *Display, x: i32, y: i32) void {
        switch (self.backend) {
            .drm_kms => |*d| {
                if (self.has_hw_cursor) d.moveCursor(x, y);
            },
            .fbdev => {},
        }
    }

    pub fn flushDamage(self: *Display, maybe_box: ?fb.Box) void {
        const box = maybe_box orelse return;
        const screen = self.screenSurface();
        screen.copyBoxFrom(&self.backbuffer, box);

        switch (self.backend) {
            .drm_kms => |*d| d.dirtyFb(box),
            .fbdev => |*f| f.flush(),
        }
    }

    pub fn flushAll(self: *Display) void {
        self.flushDamage(fb.Box.fromPosSize(0, 0, self.width, self.height));
    }
};

const wm_mod = @import("wm.zig");
const term_mod = @import("terminal.zig");
const rd_mod = @import("remote_desktop.zig");
const wayland_mod = @import("wayland.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var stdout_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&stdout_buf, "Starting Diosix Homegrown Window Manager (diosix-wm)...\n", .{}) catch return;
    _ = linux.write(linux.STDOUT_FILENO, msg.ptr, msg.len);

    // 1. Initialize Display Device (DRM KMS accelerated or /dev/fb0 fallback)
    var display = try Display.init(allocator);
    defer display.deinit(allocator);

    // 2. Suppress blinking text console cursor
    fb.FramebufferDevice.disableConsoleCursor();

    const sw = display.width;
    const sh = display.height;

    const is_drm = (display.backend == .drm_kms);
    var info_buf: [256]u8 = undefined;
    const info_msg = std.fmt.bufPrint(
        &info_buf,
        "Display initialized: {d}x{d}, backend={s}, hw_cursor={s}.\n",
        .{
            sw,
            sh,
            if (is_drm) "DRM/KMS (VirtIO-GPU)" else "fbdev (/dev/fb0)",
            if (display.has_hw_cursor) "enabled" else "disabled (sw)",
        },
    ) catch "";
    if (info_msg.len > 0) {
        _ = linux.write(linux.STDOUT_FILENO, info_msg.ptr, info_msg.len);
    }

    // 3. Initialize Window Manager
    var wm = wm_mod.WindowManager.init(allocator, sw, sh);
    defer wm.deinit();

    // 4. Create Terminal Window
    const win_w: u32 = @min(sw - 40, @max(640, (sw * 55) / 100));
    const win_h: u32 = @min(sh - 60, @max(400, (sh * 55) / 100));
    const win_x: i32 = 20;
    const win_y: i32 = 24;

    term_mod.global_terminal.cols = 80;
    term_mod.global_terminal.rows = 24;
    term_mod.global_terminal.spawnShell() catch {};

    const term_task = win_mod.Task{
        .handle = term_mod.terminalTaskHandle,
        .task_data = &term_mod.global_terminal,
        .bg = term_mod.DEFAULT_BG,
    };
    const term_win = try wm.createWindow(
        win_x,
        win_y,
        win_w,
        win_h,
        "Terminal",
        win_mod.WindowFlags.none,
        term_task,
        win_w,
        5000,
    );
    _ = term_win;

    // 5. Initialize Remote Desktop (Debian Guest Window)
    rd_mod.global_remote_desktop = rd_mod.RemoteDesktop.init(allocator, "10.0.3.2", 5900);
    const debian_w: u32 = @min(sw - 40, @max(680, (sw * 60) / 100));
    const debian_h: u32 = @min(sh - 60, @max(440, (sh * 60) / 100));
    const debian_x: i32 = @min(@as(i32, @intCast(sw - debian_w)), 70);
    const debian_y: i32 = @min(@as(i32, @intCast(sh - debian_h)), 50);

    const debian_task = win_mod.Task{
        .handle = rd_mod.remoteDesktopTaskHandle,
        .task_data = if (rd_mod.global_remote_desktop) |*g| g else null,
        .bg = 0x00181A20,
    };
    const debian_win = try wm.createWindow(
        debian_x,
        debian_y,
        debian_w,
        debian_h,
        "Debian Desktop [10.0.3.2]",
        win_mod.WindowFlags.none,
        debian_task,
        1024,
        768,
    );
    _ = debian_win;

    // 6. Initialize Wayland Translation Bridge (/tmp/wayland-0 and TCP 8484)
    wayland_mod.global_wayland_server = wayland_mod.WaylandServer.init(allocator, "/tmp/wayland-0", 8484);

    // 7. Initialize Cursor and Mouse Coordinates
    var mouse_x: i32 = @as(i32, @intCast(sw / 2));
    var mouse_y: i32 = @as(i32, @intCast(sh / 2));
    var cursor = cursor_mod.Cursor{
        .x = mouse_x,
        .y = mouse_y,
    };

    // 8. Open Input Event Devices
    var input_fds: [8]i32 = undefined;
    var input_count: usize = 0;
    var dev_idx: u8 = 0;
    while (dev_idx < 8) : (dev_idx += 1) {
        var dev_path_buf: [32]u8 = undefined;
        const dev_path = std.fmt.bufPrint(&dev_path_buf, "/dev/input/event{d}\x00", .{dev_idx}) catch continue;
        const open_rc = linux.open(@ptrCast(dev_path.ptr), .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
        const signed_rc: isize = @bitCast(open_rc);
        if (signed_rc >= 0) {
            input_fds[input_count] = @intCast(signed_rc);
            input_count += 1;
        }
    }

    // 9. Render Initial Desktop Frame
    const initial_damage = wm.redrawAll(&display.backbuffer);
    display.flushDamage(initial_damage);

    if (display.has_hw_cursor) {
        display.moveCursor(mouse_x, mouse_y);
    } else {
        cursor.draw(display.screenSurface());
    }

    // 10. Main Event Loop
    while (true) {
        var pfds: [32]linux.pollfd = undefined;
        var poll_count: usize = 0;
        for (input_fds[0..input_count]) |fd| {
            pfds[poll_count] = linux.pollfd{
                .fd = fd,
                .events = linux.POLL.IN,
                .revents = 0,
            };
            poll_count += 1;
        }

        const term_pfd_idx = poll_count;
        if (term_mod.global_terminal.master_fd >= 0) {
            pfds[poll_count] = linux.pollfd{
                .fd = term_mod.global_terminal.master_fd,
                .events = linux.POLL.IN,
                .revents = 0,
            };
            poll_count += 1;
        }

        if (rd_mod.global_remote_desktop) |*rd| {
            if (rd.sock_fd >= 0 and poll_count < pfds.len) {
                pfds[poll_count] = linux.pollfd{
                    .fd = rd.sock_fd,
                    .events = linux.POLL.IN | (if (rd.state == .connecting) @as(i16, linux.POLL.OUT) else 0),
                    .revents = 0,
                };
                poll_count += 1;
            }
        }

        if (wayland_mod.global_wayland_server) |*ws| {
            if (ws.unix_fd >= 0 and poll_count < pfds.len) {
                pfds[poll_count] = linux.pollfd{
                    .fd = ws.unix_fd,
                    .events = linux.POLL.IN,
                    .revents = 0,
                };
                poll_count += 1;
            }
            if (ws.tcp_fd >= 0 and poll_count < pfds.len) {
                pfds[poll_count] = linux.pollfd{
                    .fd = ws.tcp_fd,
                    .events = linux.POLL.IN,
                    .revents = 0,
                };
                poll_count += 1;
            }
            for (&ws.clients) |*slot| {
                if (slot.*) |*c| {
                    if (c.sock_fd >= 0 and poll_count < pfds.len) {
                        pfds[poll_count] = linux.pollfd{
                            .fd = c.sock_fd,
                            .events = linux.POLL.IN | (if (c.out_len > 0) @as(i16, linux.POLL.OUT) else 0),
                            .revents = 0,
                        };
                        poll_count += 1;
                    }
                }
            }
        }

        const poll_res = linux.poll(&pfds, poll_count, 16);
        const signed_poll: isize = @bitCast(poll_res);

        // Process Wayland events and connections
        if (wayland_mod.global_wayland_server) |*ws| {
            ws.pollAndProcess(&wm);
        }

        if (signed_poll > 0) {
            // Check terminal master_fd output from subshell
            if (term_mod.global_terminal.master_fd >= 0 and (pfds[term_pfd_idx].revents & linux.POLL.IN) != 0) {
                if (term_mod.global_terminal.readMaster()) {
                    if (wm.focusedWindow()) |fwin| {
                        fwin.invalidateAll();
                    }
                }
            }

            // Check input devices
            for (pfds[0..input_count], 0..) |pfd, idx| {
                if ((pfd.revents & linux.POLL.IN) != 0) {
                    const fd = input_fds[idx];
                    while (true) {
                        var ev_buf: [32]InputEvent = undefined;
                        const read_bytes = linux.read(fd, @ptrCast(&ev_buf), @sizeOf(@TypeOf(ev_buf)));
                        const signed_read: isize = @bitCast(read_bytes);
                        if (signed_read <= 0) break;
                        const count = @as(usize, @intCast(signed_read)) / @sizeOf(InputEvent);

                        for (ev_buf[0..count]) |ev| {
                            if (ev.type == 0x02) { // EV_REL (Mouse relative motion)
                                if (ev.code == 0x00) {
                                    mouse_x = std.math.clamp(mouse_x + ev.value, 0, @as(i32, @intCast(sw)) - 1);
                                } else if (ev.code == 0x01) {
                                    mouse_y = std.math.clamp(mouse_y + ev.value, 0, @as(i32, @intCast(sh)) - 1);
                                } else if (ev.code == 0x08) { // Wheel
                                    try wm.scroll(.{ .x = mouse_x, .y = mouse_y }, ev.value);
                                }
                            } else if (ev.type == 0x03) { // EV_ABS (Tablet absolute motion)
                                if (ev.code == 0x00) {
                                    const clamped: u64 = @intCast(std.math.clamp(ev.value, 0, 32767));
                                    mouse_x = @as(i32, @intCast((clamped * @as(u64, sw)) / 32767));
                                } else if (ev.code == 0x01) {
                                    const clamped: u64 = @intCast(std.math.clamp(ev.value, 0, 32767));
                                    mouse_y = @as(i32, @intCast((clamped * @as(u64, sh)) / 32767));
                                }
                            } else if (ev.type == 0x01) { // EV_KEY
                                if (ev.code == 0x110 or ev.code == 0x14a or ev.code == 0x111 or ev.code == 0x112) {
                                    const is_press = (ev.value != 0);
                                    const action: win_mod.MouseAction = if (is_press) .down else .up;

                                    var maybe_button: ?win_mod.Button = null;
                                    if (ev.code == 0x110 or ev.code == 0x14a) {
                                        maybe_button = .select;
                                    } else if (ev.code == 0x111) {
                                        maybe_button = .adjust;
                                    } else if (ev.code == 0x112) {
                                        maybe_button = .menu;
                                    }

                                    if (maybe_button) |btn| {
                                        try wm.mouseClick(.{ .x = mouse_x, .y = mouse_y }, btn, action);
                                    }
                                } else {
                                    // Deliver keyboard event to focused window
                                    try wm.handleKey(ev.code, ev.value);
                                }
                            }
                        }
                    }
                }
            }
        }

        // Process pointer motion and dragging
        try wm.mouseMove(.{ .x = mouse_x, .y = mouse_y }, &display.backbuffer);

        // Update cursor position
        if (display.has_hw_cursor) {
            display.moveCursor(mouse_x, mouse_y);
        } else {
            _ = cursor.moveTo(display.screenSurface(), &display.backbuffer, mouse_x, mouse_y);
        }

        // Redraw dirty regions
        const maybe_damage = wm.redrawDirty(&display.backbuffer);
        if (maybe_damage) |dmg| {
            if (!display.has_hw_cursor) cursor.erase(display.screenSurface(), &display.backbuffer);
            display.flushDamage(dmg);
            if (!display.has_hw_cursor) cursor.draw(display.screenSurface());
        }

        // Broadcast idle event
        try wm.idle();
    }
}

test "diosix-wm: wuss window manager integration" {
    const testing = std.testing;
    var wm = wm_mod.WindowManager.init(testing.allocator, 1024, 768);
    defer wm.deinit();

    var surf = try fb.Surface.init(testing.allocator, 1024, 768);
    defer surf.deinit(testing.allocator);

    // Create 2 real windows
    const w1 = try wm.createWindow(50, 50, 400, 300, "Window 1", .{}, .{}, 600, 500);
    const w2 = try wm.createWindow(200, 150, 400, 300, "Window 2", .{}, .{}, 600, 500);

    // Redraw all
    const dmg = wm.redrawAll(&surf);
    try testing.expectEqual(@as(i32, 0), dmg.x0);
    try testing.expectEqual(@as(u32, 1024), dmg.width());

    // Window 2 is topmost
    try testing.expectEqual(w2, wm.windows.items[0]);
    try testing.expectEqual(w1, wm.windows.items[1]);

    // Click inside w1's titlebar brings it to front and starts drag
    const tb1 = w1.titlebarBox();
    try wm.mouseClick(.{ .x = tb1.x0 + 40, .y = tb1.y0 + 10 }, .select, .down);
    try testing.expectEqual(w1, wm.windows.items[0]);
    try testing.expectEqual(w1, wm.drag_window);

    // Drag moves window
    try wm.mouseMove(.{ .x = tb1.x0 + 70, .y = tb1.y0 + 30 }, &surf);
    try wm.mouseClick(.{ .x = tb1.x0 + 70, .y = tb1.y0 + 30 }, .select, .up);
    try testing.expect(wm.drag_window == null);

    // Redraw dirty correctly clears and redraws
    const dirty_dmg = wm.redrawDirty(&surf);
    try testing.expect(dirty_dmg != null);
}

test "diosix-wm: clean cursor restoration without trails" {
    const testing = std.testing;
    var screen = try fb.Surface.init(testing.allocator, 200, 200);
    defer screen.deinit(testing.allocator);
    var backbuffer = try fb.Surface.init(testing.allocator, 200, 200);
    defer backbuffer.deinit(testing.allocator);

    backbuffer.clear(fb.Color.DESKTOP_BG);
    backbuffer.fillBox(fb.Box{ .x0 = 40, .y0 = 40, .x1 = 90, .y1 = 90 }, fb.Color.WINDOW_BG);
    screen.copyBoxFrom(&backbuffer, fb.Box{ .x0 = 0, .y0 = 0, .x1 = 200, .y1 = 200 });

    var cursor = cursor_mod.Cursor{ .x = 50, .y = 50 };
    cursor.draw(&screen);

    try testing.expectEqual(fb.Color.BLACK, screen.pixels[50 * 200 + 50]);

    _ = cursor.moveTo(&screen, &backbuffer, 100, 100);

    try testing.expectEqual(fb.Color.WINDOW_BG, screen.pixels[50 * 200 + 50]);
    try testing.expectEqual(fb.Color.BLACK, screen.pixels[100 * 200 + 100]);
}

test "diosix-wm: terminal emulator parser and input" {
    const testing = std.testing;
    var term = term_mod.Terminal.init();
    term.cols = 80;
    term.rows = 24;

    term.feed("Hello Diosix Shell\r\n");
    try testing.expectEqual(@as(usize, 0), term.cursor_col);
    try testing.expectEqual(@as(usize, 1), term.cursor_row);
    try testing.expectEqual(@as(u8, 'H'), term.chars[0][0]);
    try testing.expectEqual(@as(u8, 'e'), term.chars[0][1]);

    // Test ANSI cursor position CSI 5;10H
    term.feed("\x1b[5;10H");
    try testing.expectEqual(@as(usize, 4), term.cursor_row);
    try testing.expectEqual(@as(usize, 9), term.cursor_col);

    // Test ANSI clear line CSI 2K
    term.feed("Test\x1b[2K");
    try testing.expectEqual(@as(usize, 0), term.line_lens[4]);

    // Test key mapping (keystroke when master_fd < 0 is a clean no-op)
    term.handleKey(30, 1); // 'a'
    term.handleKey(28, 1); // Enter
}



