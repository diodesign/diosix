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

// Real System Monitor Task State
const SystemInfoTask = struct {
    pub const LINES = [_][]const u8{
        "Diosix RISC-V 64 Micro-Hypervisor",
        "Architecture: RV64GC (Hypervisor Extension H/VS Mode)",
        "Window Manager: Wuss Native Zig Architecture",
        "Acceleration: DRM/KMS VirtIO-GPU Hardware Cursor Plane",
        "Multi-Window Management: Z-Ordering & Occlusion Clipping",
        "Window Furniture: Titlebar, Close [x], Back [v], Toggle [^], Resize Grip",
        "Scrollbars: Proportional Sausage Thumb & Stepper Arrows",
        "Memory Protection: PMP & Two-Stage Page Tables Active",
        "RootVM: Linux Guest Container (VirtIO Console, Net, Block)",
        "Display Mode: 1280x800 @ 32 bpp TrueColor",
        "Input Drivers: evdev (Mouse, Tablet, Keyboard)",
        "Drag Mechanism: Topmost Whole-Window Blit Move",
        "Event Architecture: Direct Task Delegation Callbacks",
        "Kernel Status: Nominal, Preemptive Scheduling Active",
        "----------------------------------------------------------------",
        "* Drag window titlebar to move window as a whole",
        "* Drag vertical/horizontal scrollbar sausage to scroll view",
        "* Click scrollbar arrow buttons to step scroll by 20px",
        "* Drag bottom-right corner grip to resize window footprint",
        "* Click [v] to send window to back, [^] to maximize/restore",
        "* Click [x] to close window; click window body to focus",
    };

    pub fn handle(win: *win_mod.Window, ev: *const win_mod.Event, _: ?*anyopaque) anyerror!void {
        switch (ev.kind) {
            .redraw => {
                const surf = ev.data.redraw.surface;
                const clip = ev.data.redraw.content;
                const bounds = ev.data.redraw.bounds;
                const scroll = ev.data.redraw.scroll;

                surf.setClip(clip);

                for (LINES, 0..) |line, i| {
                    const line_y = bounds.y0 + 10 + @as(i32, @intCast(i * 20)) - scroll.y;
                    const line_x = bounds.x0 + 12 - scroll.x;
                    if (line_y + @as(i32, @intCast(font.GLYPH_HEIGHT)) >= clip.y0 and line_y <= clip.y1) {
                        const col = if (i == 0) fb.Color.TEXT_BLACK else if (i < 14) fb.Color.TEXT_BLACK else fb.Color.TEXT_MUTED;
                        font.drawText(surf, line, line_x, line_y, col);
                    }
                }

                surf.resetClip();
            },
            .scroll => {
                win.scrollStep(.{ .x = 0, .y = -ev.data.scroll.delta * win_mod.Window.SCROLL_STEP });
            },
            else => {},
        }
    }
};

// Real Diagnostics Task State
const DiagnosticsData = struct {
    last_click_x: i32 = 0,
    last_click_y: i32 = 0,
    click_count: u32 = 0,
    last_button: []const u8 = "None",
};

var global_diag = DiagnosticsData{};

const DiagnosticsTask = struct {
    pub fn handle(win: *win_mod.Window, ev: *const win_mod.Event, data_ptr: ?*anyopaque) anyerror!void {
        const diag = if (data_ptr) |p| @as(*DiagnosticsData, @ptrCast(@alignCast(p))) else &global_diag;
        switch (ev.kind) {
            .redraw => {
                const surf = ev.data.redraw.surface;
                const clip = ev.data.redraw.content;
                const bounds = ev.data.redraw.bounds;

                surf.setClip(clip);

                var buf: [64]u8 = undefined;

                font.drawText(surf, "Input & Hardware Diagnostics", bounds.x0 + 12, bounds.y0 + 12, fb.Color.TEXT_BLACK);

                const c_str = std.fmt.bufPrint(&buf, "Clicks Count: {d}", .{diag.click_count}) catch "";
                font.drawText(surf, c_str, bounds.x0 + 12, bounds.y0 + 36, fb.Color.TEXT_BLACK);

                var b_buf: [64]u8 = undefined;
                const b_str = std.fmt.bufPrint(&b_buf, "Last Click: {s} at ({d}, {d})", .{ diag.last_button, diag.last_click_x, diag.last_click_y }) catch "";
                font.drawText(surf, b_str, bounds.x0 + 12, bounds.y0 + 58, fb.Color.TEXT_BLACK);

                font.drawText(surf, "Status: Active Event Delivery", bounds.x0 + 12, bounds.y0 + 80, fb.Color.TEXT_MUTED);
                font.drawText(surf, "Z-Order: Wuss Window Delegation", bounds.x0 + 12, bounds.y0 + 102, fb.Color.TEXT_MUTED);

                surf.resetClip();
            },
            .mouse => {
                if (ev.data.mouse.action == .down) {
                    diag.click_count += 1;
                    diag.last_click_x = ev.data.mouse.point.x;
                    diag.last_click_y = ev.data.mouse.point.y;
                    diag.last_button = switch (ev.data.mouse.button) {
                        .select => "Select (Left)",
                        .adjust => "Adjust (Right)",
                        .menu => "Menu (Middle)",
                    };
                    win.invalidateAll();
                }
            },
            else => {},
        }
    }
};

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

    // 4. Create Two Real Windows (Wuss-compliant with Task Delegates)
    // Window 1: System Monitor (scrollable text task)
    const win1_w: u32 = @min(sw - 40, @max(480, (sw * 50) / 100));
    const win1_h: u32 = @min(sh - 60, @max(300, (sh * 55) / 100));
    const win1_x: i32 = 40;
    const win1_y: i32 = 30;

    const sys_task = win_mod.Task{
        .handle = SystemInfoTask.handle,
        .task_data = null,
        .bg = fb.Color.WINDOW_BG,
    };
    _ = try wm.createWindow(
        win1_x,
        win1_y,
        win1_w,
        win1_h,
        "Diosix System Monitor",
        win_mod.WindowFlags.none,
        sys_task,
        640,
        500,
    );

    // Window 2: Diagnostics (interactive task)
    const win2_w: u32 = @min(sw - 60, 420);
    const win2_h: u32 = @min(sh - 80, 220);
    const win2_x: i32 = @as(i32, @intCast(sw)) - @as(i32, @intCast(win2_w)) - 50;
    const win2_y: i32 = @as(i32, @intCast(sh)) - @as(i32, @intCast(win2_h)) - 60;

    const diag_task = win_mod.Task{
        .handle = DiagnosticsTask.handle,
        .task_data = &global_diag,
        .bg = fb.Color.WINDOW_BG,
    };
    _ = try wm.createWindow(
        win2_x,
        win2_y,
        win2_w,
        win2_h,
        "Input Diagnostics",
        win_mod.WindowFlags.none,
        diag_task,
        win2_w,
        win2_h,
    );

    // 5. Initialize Cursor and Mouse Coordinates
    var mouse_x: i32 = @as(i32, @intCast(sw / 2));
    var mouse_y: i32 = @as(i32, @intCast(sh / 2));
    var cursor = cursor_mod.Cursor{
        .x = mouse_x,
        .y = mouse_y,
    };

    // 6. Open Input Event Devices
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

    // 7. Render Initial Desktop Frame
    const initial_damage = wm.redrawAll(&display.backbuffer);
    display.flushDamage(initial_damage);

    if (display.has_hw_cursor) {
        display.moveCursor(mouse_x, mouse_y);
    } else {
        cursor.draw(display.screenSurface());
    }

    // 8. Main Event Loop
    while (true) {
        var pfds: [8]linux.pollfd = undefined;
        for (input_fds[0..input_count], 0..) |fd, i| {
            pfds[i] = linux.pollfd{
                .fd = fd,
                .events = linux.POLL.IN,
                .revents = 0,
            };
        }

        const poll_res = linux.poll(&pfds, input_count, 16);
        const signed_poll: isize = @bitCast(poll_res);

        if (signed_poll > 0) {
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
                            } else if (ev.type == 0x01) { // EV_KEY (Buttons)
                                const is_press = (ev.value != 0);
                                const action: win_mod.MouseAction = if (is_press) .down else .up;

                                var maybe_button: ?win_mod.Button = null;
                                if (ev.code == 0x110 or ev.code == 0x14a) { // BTN_LEFT or BTN_TOUCH
                                    maybe_button = .select;
                                } else if (ev.code == 0x111) { // BTN_RIGHT
                                    maybe_button = .adjust;
                                } else if (ev.code == 0x112) { // BTN_MIDDLE
                                    maybe_button = .menu;
                                }

                                if (maybe_button) |btn| {
                                    try wm.mouseClick(.{ .x = mouse_x, .y = mouse_y }, btn, action);
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


