// Main Entry Point and Display Loop for Diosix Monolithic GUI
// Final Fantasy 7 & 8 Inspired BIOS/UEFI Menu Environment
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const fb = @import("framebuffer.zig");
const font = @import("font.zig");
const drm = @import("drm.zig");
const gui_mod = @import("gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const icon_mod = @import("icon.zig");
const Icon = icon_mod.Icon;
const window_mod = @import("window.zig");
const Window = window_mod.Window;

pub const Display = struct {
    width: u32,
    height: u32,
    stride: usize,
    fb_ptr: [*]u32,
    drm_dev: ?drm.DrmDevice,
    fb_fd: i32,
    backbuffer: fb.Surface,
    backbuffer_mem: []u32,
    clean_buffer: fb.Surface,
    clean_buffer_mem: []u32,
    prev_cursor_box: fb.Box = fb.Box{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 },
    prev_cursor_x: i32 = -1,
    prev_cursor_y: i32 = -1,
    cursor_drawn: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Display {
        // Try DRM/KMS first (e.g. VirtIO-GPU)
        const dri_paths = [_][]const u8{ "/dev/dri/card0", "/dev/dri/card1" };
        for (dri_paths) |card_path| {
            if (drm.DrmDevice.init(card_path)) |dev| {
                const bb_mem = try allocator.alloc(u32, dev.width * dev.height);
                const cb_mem = try allocator.alloc(u32, dev.width * dev.height);
                return Display{
                    .width = dev.width,
                    .height = dev.height,
                    .stride = dev.pitch,
                    .fb_ptr = dev.screen_surface.pixels,
                    .drm_dev = dev,
                    .fb_fd = -1,
                    .backbuffer = fb.Surface.init(bb_mem.ptr, dev.width, dev.height, dev.pitch),
                    .backbuffer_mem = bb_mem,
                    .clean_buffer = fb.Surface.init(cb_mem.ptr, dev.width, dev.height, dev.pitch),
                    .clean_buffer_mem = cb_mem,
                };
            } else |_| {}
        }

        // Fallback to legacy /dev/fb0
        const fb_path = "/dev/fb0";
        const fd_rc = linux.open(fb_path, .{ .ACCMODE = .RDWR }, 0);
        const signed_fd: isize = @bitCast(fd_rc);
        if (signed_fd >= 0) {
            const fd: i32 = @intCast(signed_fd);
            const w: u32 = 1280;
            const h: u32 = 800;
            const stride: usize = w * 4;
            const map_size = stride * h;

            const map_res = linux.mmap(null, map_size, linux.PROT{ .READ = true, .WRITE = true }, linux.MAP{ .TYPE = .SHARED }, fd, 0);
            const signed_map: isize = @bitCast(map_res);
            if (signed_map >= 0) {
                const pixels: [*]u32 = @ptrFromInt(map_res);
                const bb_mem = try allocator.alloc(u32, w * h);
                const cb_mem = try allocator.alloc(u32, w * h);
                return Display{
                    .width = w,
                    .height = h,
                    .stride = stride,
                    .fb_ptr = pixels,
                    .drm_dev = null,
                    .fb_fd = fd,
                    .backbuffer = fb.Surface.init(bb_mem.ptr, w, h, @intCast(stride)),
                    .backbuffer_mem = bb_mem,
                    .clean_buffer = fb.Surface.init(cb_mem.ptr, w, h, @intCast(stride)),
                    .clean_buffer_mem = cb_mem,
                };
            }
        }

        return error.NoDisplayDeviceFound;
    }

    pub fn deinit(self: *Display, allocator: std.mem.Allocator) void {
        allocator.free(self.backbuffer_mem);
        allocator.free(self.clean_buffer_mem);
        if (self.drm_dev) |*d| d.deinit();
        if (self.fb_fd >= 0) _ = linux.close(self.fb_fd);
    }

    pub fn screenSurface(self: *Display) fb.Surface {
        return fb.Surface.init(self.fb_ptr, self.width, self.height, @intCast(self.stride));
    }

    pub fn flushDamage(self: *Display, damage: fb.Box) void {
        const x0 = @max(0, damage.x0);
        const y0 = @max(0, damage.y0);
        const x1 = @min(@as(i32, @intCast(self.width)), damage.x1);
        const y1 = @min(@as(i32, @intCast(self.height)), damage.y1);
        if (x0 >= x1 or y0 >= y1) return;

        const w: usize = @intCast(x1 - x0);
        const stride_pixels = self.stride / 4;
        const ux0: usize = @intCast(x0);

        var y: usize = @intCast(y0);
        const end_y: usize = @intCast(y1);

        while (y < end_y) : (y += 1) {
            const row_offset = y * stride_pixels + ux0;
            @memcpy(self.fb_ptr[row_offset .. row_offset + w], self.backbuffer_mem[row_offset .. row_offset + w]);
        }

        if (self.drm_dev) |*d| {
            d.dirtyFb(damage);
        }
    }

    pub fn flush(self: *Display) void {
        self.flushDamage(fb.Box.fromPosSize(0, 0, self.width, self.height));
    }
};

fn getMilliTimestamp() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

pub const InputEvent = extern struct {
    sec: isize,
    usec: isize,
    type: u16,
    code: u16,
    value: i32,
};

pub const EV_KEY: u16 = 0x01;
pub const EV_REL: u16 = 0x02;
pub const EV_ABS: u16 = 0x03;

pub const REL_X: u16 = 0x00;
pub const REL_Y: u16 = 0x01;
pub const ABS_X: u16 = 0x00;
pub const ABS_Y: u16 = 0x01;
pub const EVDEV_ABS_MAX: i64 = 32767;

pub const BTN_LEFT: u16 = 0x110;
pub const BTN_TOUCH: u16 = 0x14a;

pub const KEY_1: u16 = 2;
pub const KEY_2: u16 = 3;
pub const KEY_3: u16 = 4;
pub const KEY_4: u16 = 5;
pub const KEY_5: u16 = 6;
pub const KEY_6: u16 = 7;
pub const KEY_7: u16 = 8;
pub const KEY_8: u16 = 9;
pub const KEY_9: u16 = 10;
pub const KEY_0: u16 = 11;
pub const KEY_MINUS: u16 = 12;
pub const KEY_EQUAL: u16 = 13;
pub const KEY_BACKSPACE: u16 = 14;
pub const KEY_TAB: u16 = 15;
pub const KEY_Q: u16 = 16;
pub const KEY_W: u16 = 17;
pub const KEY_E: u16 = 18;
pub const KEY_R: u16 = 19;
pub const KEY_T: u16 = 20;
pub const KEY_Y: u16 = 21;
pub const KEY_U: u16 = 22;
pub const KEY_I: u16 = 23;
pub const KEY_O: u16 = 24;
pub const KEY_P: u16 = 25;
pub const KEY_ENTER: u16 = 28;
pub const KEY_A: u16 = 30;
pub const KEY_S: u16 = 31;
pub const KEY_D: u16 = 32;
pub const KEY_F: u16 = 33;
pub const KEY_G: u16 = 34;
pub const KEY_H: u16 = 35;
pub const KEY_J: u16 = 36;
pub const KEY_K: u16 = 37;
pub const KEY_L: u16 = 38;
pub const KEY_Z: u16 = 44;
pub const KEY_X: u16 = 45;
pub const KEY_C: u16 = 46;
pub const KEY_V: u16 = 47;
pub const KEY_B: u16 = 48;
pub const KEY_N: u16 = 49;
pub const KEY_M: u16 = 50;
pub const KEY_DOT: u16 = 52;
pub const KEY_SLASH: u16 = 53;
pub const KEY_SPACE: u16 = 57;
pub const KEY_UP: u16 = 103;
pub const KEY_LEFT: u16 = 105;
pub const KEY_RIGHT: u16 = 106;
pub const KEY_DOWN: u16 = 108;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var stdout_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&stdout_buf, "Starting Diosix Monolithic GUI (diosix-gui)...\n", .{}) catch return;
    _ = linux.write(1, msg.ptr, msg.len);

    // 1. Initialize Display
    var display = Display.init(allocator) catch |err| {
        std.debug.print("Failed to initialize display: {}\n", .{err});
        return;
    };
    defer display.deinit(allocator);

    std.debug.print("Display initialized: {d}x{d}, Final Fantasy 7/8 theme engine active.\n", .{ display.width, display.height });

    // 2. Initialize Diosix GUI Coordinator
    var gui = try DiosixGui.init(allocator, display.width, display.height);
    defer gui.deinit();

    // 3. Open Evdev Input Devices
    var input_fds: [8]i32 = undefined;
    var input_count: usize = 0;
    var dev_idx: u8 = 0;
    while (dev_idx < 8) : (dev_idx += 1) {
        var path_buf: [32]u8 = undefined;
        const p_slice = std.fmt.bufPrint(&path_buf, "/dev/input/event{d}", .{dev_idx}) catch continue;
        path_buf[p_slice.len] = 0;
        const dev_z: [*:0]const u8 = @ptrCast(path_buf[0..p_slice.len :0]);
        const rc = linux.open(dev_z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc >= 0) {
            input_fds[input_count] = @intCast(signed_rc);
            input_count += 1;
        }
    }

    // 4. Initial Render Frame (Full Screen Composited)
    gui.markFullDirty();
    const init_damage = gui.renderDamaged(&display.clean_buffer);
    display.backbuffer.copyBoxFrom(&display.clean_buffer, init_damage);
    gui.cursor.draw(&display.backbuffer);
    display.prev_cursor_box = gui.cursor.getBox();
    display.prev_cursor_x = gui.cursor.x;
    display.prev_cursor_y = gui.cursor.y;
    display.cursor_drawn = true;
    display.flushDamage(init_damage);

    // 5. Main Multitasking and Event Loop
    var last_time: i64 = getMilliTimestamp();

    while (true) {
        var pfds: [16]linux.pollfd = undefined;
        for (input_fds[0..input_count], 0..) |fd, i| {
            pfds[i] = linux.pollfd{
                .fd = fd,
                .events = linux.POLL.IN,
                .revents = 0,
            };
        }

        const poll_res = linux.poll(&pfds, input_count, 16); // 16ms timeout (~60 FPS)
        const signed_poll: isize = @bitCast(poll_res);

        const cur_time = getMilliTimestamp();
        const dt_ms: u32 = @intCast(@max(1, cur_time - last_time));
        last_time = cur_time;

        // Preemptive Multitasking: Deliver CPU time to all sub-programs every frame
        gui.tick(dt_ms);

        if (signed_poll > 0) {
            var i: usize = 0;
            while (i < input_count) : (i += 1) {
                if ((pfds[i].revents & linux.POLL.IN) != 0) {
                    var ev_buf: [64]InputEvent = undefined;
                    const rd = linux.read(pfds[i].fd, @ptrCast(&ev_buf), @sizeOf(@TypeOf(ev_buf)));
                    const signed_rd: isize = @bitCast(rd);
                    if (signed_rd > 0) {
                        const count = @as(usize, @intCast(signed_rd)) / @sizeOf(InputEvent);
                        for (ev_buf[0..count]) |ev| {
                            switch (ev.type) {
                                EV_KEY => {
                                    const pressed = (ev.value != 0);
                                    const code = ev.code;

                                    if (code == BTN_LEFT or code == BTN_TOUCH) {
                                        if (pressed) {
                                            gui.handleMouseClick(gui.cursor.x, gui.cursor.y);
                                        }
                                        gui.mouse_left_down = pressed;
                                    } else {
                                        const key_char = mapEvdevToAscii(code, false);
                                        gui.handleKey(code, key_char, pressed);
                                    }
                                },
                                EV_REL => {
                                    var nx = gui.cursor.x;
                                    var ny = gui.cursor.y;
                                    if (ev.code == REL_X) nx += ev.value;
                                    if (ev.code == REL_Y) ny += ev.value;
                                    nx = std.math.clamp(nx, 0, @as(i32, @intCast(display.width - 1)));
                                    ny = std.math.clamp(ny, 0, @as(i32, @intCast(display.height - 1)));
                                    gui.handleMouseMove(nx, ny, gui.mouse_left_down);
                                },
                                EV_ABS => {
                                    // Handle tablet absolute coordinates
                                    if (ev.code == ABS_X) {
                                        const nx = @divTrunc(@as(i64, ev.value) * @as(i64, @intCast(display.width)), EVDEV_ABS_MAX);
                                        gui.handleMouseMove(@intCast(nx), gui.cursor.y, gui.mouse_left_down);
                                    } else if (ev.code == ABS_Y) {
                                        const ny = @divTrunc(@as(i64, ev.value) * @as(i64, @intCast(display.height)), EVDEV_ABS_MAX);
                                        gui.handleMouseMove(gui.cursor.x, @intCast(ny), gui.mouse_left_down);
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                }
            }
        }

        // Render updated frame with intelligent damage tracking
        const damage = gui.renderDamaged(&display.clean_buffer);
        const cursor_moved = (gui.cursor.x != display.prev_cursor_x or gui.cursor.y != display.prev_cursor_y);
        const cursor_box = gui.cursor.getBox();

        if (!damage.isEmpty() or cursor_moved or !display.cursor_drawn) {
            var flush_box = fb.Box{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };

            // 1. If clean_buffer had damage, copy damaged rect to backbuffer
            if (!damage.isEmpty()) {
                display.backbuffer.copyBoxFrom(&display.clean_buffer, damage);
                flush_box = flush_box.merge(damage);
            }

            // 2. If cursor moved, restore old cursor area from clean_buffer into backbuffer
            if (cursor_moved and display.cursor_drawn) {
                display.backbuffer.copyBoxFrom(&display.clean_buffer, display.prev_cursor_box);
                flush_box = flush_box.merge(display.prev_cursor_box);
            }

            // 3. Stamp cursor sprite onto backbuffer
            gui.cursor.draw(&display.backbuffer);
            flush_box = flush_box.merge(cursor_box);

            display.prev_cursor_box = cursor_box;
            display.prev_cursor_x = gui.cursor.x;
            display.prev_cursor_y = gui.cursor.y;
            display.cursor_drawn = true;

            // 4. Flush only the damaged region to hardware scanout and DRM
            display.flushDamage(flush_box);
        }
    }
}

// Convert evdev keycode to standard ASCII character
fn mapEvdevToAscii(code: u16, shift: bool) ?u8 {
    _ = shift;
    return switch (code) {
        KEY_1 => '1',
        KEY_2 => '2',
        KEY_3 => '3',
        KEY_4 => '4',
        KEY_5 => '5',
        KEY_6 => '6',
        KEY_7 => '7',
        KEY_8 => '8',
        KEY_9 => '9',
        KEY_0 => '0',
        KEY_A => 'a',
        KEY_B => 'b',
        KEY_C => 'c',
        KEY_D => 'd',
        KEY_E => 'e',
        KEY_F => 'f',
        KEY_G => 'g',
        KEY_H => 'h',
        KEY_I => 'i',
        KEY_J => 'j',
        KEY_K => 'k',
        KEY_L => 'l',
        KEY_M => 'm',
        KEY_N => 'n',
        KEY_O => 'o',
        KEY_P => 'p',
        KEY_Q => 'q',
        KEY_R => 'r',
        KEY_S => 's',
        KEY_T => 't',
        KEY_U => 'u',
        KEY_V => 'v',
        KEY_W => 'w',
        KEY_X => 'x',
        KEY_Y => 'y',
        KEY_Z => 'z',
        KEY_SPACE => ' ',
        KEY_MINUS => '-',
        KEY_DOT => '.',
        KEY_SLASH => '/',
        else => null,
    };
}

// --- Unit Tests for diosix-gui ---

const testing = std.testing;

test "diosix-gui: surface drawing and translucent window pane" {
    var pixel_buffer: [100 * 100]u32 = undefined;
    @memset(&pixel_buffer, 0x004C8BE0);
    var surface = fb.Surface.init(&pixel_buffer, 100, 100, 400);

    const test_box = fb.Box.fromPosSize(10, 10, 80, 80);
    surface.drawWindowPane(test_box);

    // Check that inside client area is translucent blended with background
    const client_pixel = surface.getPixel(50, 50);
    try testing.expect(client_pixel != 0x004C8BE0);
    try testing.expect(client_pixel != fb.Color.GLASS_BG);

    // Outside corner should remain untouched background
    const outside_corner = surface.getPixel(10, 10);
    try testing.expectEqual(@as(u32, 0x004C8BE0), outside_corner);
}

test "diosix-gui: text rendering with drop shadow" {
    var pixel_buffer: [200 * 50]u32 = undefined;
    @memset(&pixel_buffer, 0);
    var surface = fb.Surface.init(&pixel_buffer, 200, 50, 800);

    font.drawTextWithShadow(&surface, "DIOSIX", 10, 10, fb.Color.WHITE, fb.Color.BLACK);

    // Verify string width measurement
    const measured_w = font.measureString("DIOSIX");
    try testing.expect(measured_w > 0);
}

test "diosix-gui: icon types, sliders, and editing" {
    var ic_ro = Icon.createReadOnly(1, 0, 0, 100, 20, "Read-Only");
    try testing.expectEqualStrings("Read-Only", ic_ro.getText());

    var ic_rw = Icon.createReadWrite(2, 0, 25, 100, 25, "Initial");
    ic_rw.insertChar('!');
    try testing.expectEqualStrings("Initial!", ic_rw.getText());
    ic_rw.deleteBackward();
    try testing.expectEqualStrings("Initial", ic_rw.getText());

    var ic_sl = Icon.createSlider(3, 0, 55, 120, 30, 0, 100, 50, "%");
    ic_sl.adjustSlider(10);
    try testing.expectEqual(@as(i32, 60), ic_sl.slider_val);
    ic_sl.adjustSlider(-100);
    try testing.expectEqual(@as(i32, 0), ic_sl.slider_val); // Clamped to min
}

test "diosix-gui: icon grouping and exclusive radio behavior" {
    const allocator = testing.allocator;
    var win = Window.init(allocator, 1, 0, 0, 300, 300, "Group Test");
    defer win.deinit();

    // Add 3 radio tick boxes in exclusive group 1
    const r1 = try win.addIcon(Icon.createTickBox(10, 10, 10, 200, 24, "Option A", true, 1, .exclusive));
    const r2 = try win.addIcon(Icon.createTickBox(11, 10, 40, 200, 24, "Option B", false, 1, .exclusive));
    const r3 = try win.addIcon(Icon.createTickBox(12, 10, 70, 200, 24, "Option C", false, 1, .exclusive));

    try testing.expect(r1.is_ticked);
    try testing.expect(!r2.is_ticked);
    try testing.expect(!r3.is_ticked);

    // Trigger option B: option A and C must become unticked!
    var dummy_gui: usize = 0;
    win.triggerIcon(@ptrCast(&dummy_gui), r2);

    try testing.expect(!win.icons.items[0].is_ticked);
    try testing.expect(win.icons.items[1].is_ticked);
    try testing.expect(!win.icons.items[2].is_ticked);
}

test "diosix-gui: window offscreen parking and movement" {
    const allocator = testing.allocator;
    var win = Window.init(allocator, 42, 50, 60, 400, 300, "Window Move Test");
    defer win.deinit();

    // Starts parked offscreen
    try testing.expect(!win.is_onscreen);
    try testing.expect(win.x < 0);

    // Bring onscreen
    win.setOnScreen(true);
    try testing.expect(win.is_onscreen);
    try testing.expectEqual(@as(i32, 50), win.x);
    try testing.expectEqual(@as(i32, 60), win.y);

    // Park window back offscreen
    win.setOnScreen(false);
    try testing.expect(!win.is_onscreen);
    try testing.expect(win.x < 0);
}

test "diosix-gui: coordinator initialization and preemptive multitasking" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    try testing.expectEqual(@as(usize, 5), gui.subprograms.items.len);
    try testing.expectEqual(@as(usize, 0), gui.active_sub_idx);

    // Initial subprogram 0 is active: its windows are on-screen
    try testing.expect(gui.windows.items[0].is_onscreen); // specs pane
    try testing.expect(!gui.windows.items[3].is_onscreen); // icon showcase pane parked

    // Check that subprograms get background CPU time on tick
    gui.tick(100);
    gui.tick(500);

    // Switch tab
    gui.activateSubProgram(1);
    try testing.expectEqual(@as(usize, 1), gui.active_sub_idx);

    // Ensure tab 0 windows are parked off-screen and tab 1 windows are on screen
    try testing.expect(!gui.windows.items[0].is_onscreen);
    try testing.expect(gui.windows.items[3].is_onscreen); // icon showcase pane
}

test "diosix-gui: static graduated background rendering" {
    var pixel_buffer: [100 * 100]u32 = undefined;
    var surface = fb.Surface.init(&pixel_buffer, 100, 100, 400);

    const top_col: u32 = 0x004C8BE0; // Light Blue
    const bot_col: u32 = 0x000C1836; // Dark Blue

    surface.drawGraduatedBackground(top_col, bot_col);

    // Top row has light blue hue
    const top_px = surface.getPixel(50, 0);
    const top_b = top_px & 0xFF;
    try testing.expect(top_b >= 200);

    // Bottom row has dark blue hue
    const bot_px = surface.getPixel(50, 99);
    const bot_r = (bot_px >> 16) & 0xFF;
    const bot_b = bot_px & 0xFF;
    try testing.expect(bot_r < 50 and bot_b < 80);

    // Middle row (y=50) is smoothly interpolated between top and bot
    const mid_col = surface.getPixel(50, 50);
    const mid_b = mid_col & 0xFF;
    try testing.expect(mid_b < top_b and mid_b > bot_b);
}

test "diosix-gui: real-time window transparency and backdrop controls" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 800, 600);
    defer gui.deinit();

    // Default transparency is 50%
    try testing.expectEqual(@as(u32, 50), gui.window_transparency);
    try testing.expectEqual(@as(u8, 127), gui.getWindowOpacityAlpha());

    // Adjust transparency to 0% (fully opaque)
    gui.setWindowTransparency(0);
    try testing.expectEqual(@as(u32, 0), gui.window_transparency);
    try testing.expectEqual(@as(u8, 255), gui.getWindowOpacityAlpha());

    // Adjust transparency to 80% (20% opaque)
    gui.setWindowTransparency(80);
    try testing.expectEqual(@as(u32, 80), gui.window_transparency);
    try testing.expectEqual(@as(u8, 51), gui.getWindowOpacityAlpha());

    // Default blur strength is 50% (radius 5)
    try testing.expectEqual(@as(u32, 50), gui.getBlurStrength());
    try testing.expectEqual(@as(u32, 5), gui.getBlurRadius());

    // Adjust blur strength to 100% (radius 10)
    gui.setBlurStrength(100);
    try testing.expectEqual(@as(u32, 100), gui.getBlurStrength());
    try testing.expectEqual(@as(u32, 10), gui.getBlurRadius());

    // Adjust blur strength to 0% (radius 0)
    gui.setBlurStrength(0);
    try testing.expectEqual(@as(u32, 0), gui.getBlurStrength());
    try testing.expectEqual(@as(u32, 0), gui.getBlurRadius());

    // Adjust backdrop colors
    gui.setBackdropTopColor(0x002EB8D8);
    gui.setBackdropBotColor(0x00060B18);
    try testing.expectEqual(@as(u32, 0x002EB8D8), gui.bg_top_color);
    try testing.expectEqual(@as(u32, 0x00060B18), gui.bg_bot_color);
}

test "diosix-gui: surface copyBoxFrom tile copying" {
    var src_buf: [100 * 100]u32 = @splat(0x00FF0000); // Red
    var dst_buf: [100 * 100]u32 = @splat(0x000000FF); // Blue

    var src = fb.Surface.init(&src_buf, 100, 100, 400);
    var dst = fb.Surface.init(&dst_buf, 100, 100, 400);

    // Copy a 20x20 tile at (30, 40)
    const copy_box = fb.Box.fromPosSize(30, 40, 20, 20);
    dst.copyBoxFrom(&src, copy_box);

    // Inside tile should be red
    try testing.expectEqual(@as(u32, 0x00FF0000), dst.getPixel(30, 40));
    try testing.expectEqual(@as(u32, 0x00FF0000), dst.getPixel(49, 59));

    // Outside tile should remain blue
    try testing.expectEqual(@as(u32, 0x000000FF), dst.getPixel(29, 40));
    try testing.expectEqual(@as(u32, 0x000000FF), dst.getPixel(50, 40));
    try testing.expectEqual(@as(u32, 0x000000FF), dst.getPixel(30, 39));
    try testing.expectEqual(@as(u32, 0x000000FF), dst.getPixel(30, 60));
}

test "diosix-gui: intelligent damage tracking and idle frame skipping" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const clean_buf = try allocator.alloc(u32, 1280 * 800);
    defer allocator.free(clean_buf);
    var clean_surface = fb.Surface.init(clean_buf.ptr, 1280, 800, 1280 * 4);

    // 1. On startup, gui is full dirty
    try testing.expect(gui.isDirty());
    const init_damage = gui.renderDamaged(&clean_surface);
    try testing.expectEqual(@as(i32, 0), init_damage.x0);
    try testing.expectEqual(@as(i32, 0), init_damage.y0);
    try testing.expectEqual(@as(i32, 1280), init_damage.x1);
    try testing.expectEqual(@as(i32, 800), init_damage.y1);

    // 2. Immediately afterwards (idle), damage must be completely EMPTY!
    try testing.expect(!gui.isDirty());
    const idle_damage = gui.renderDamaged(&clean_surface);
    try testing.expect(idle_damage.isEmpty());

    // 3. Updating an icon in Window 0 marks only that window dirty
    if (gui.findIcon(100, 1008)) |ic| { // WIN_SPECS_ID, ICON_UPTIME_ID
        ic.setText("Uptime: 5s");
    }
    try testing.expect(gui.isDirty());

    // 4. Redraw damaged region: must ONLY damage window 0's bounds, not full screen!
    const win_damage = gui.renderDamaged(&clean_surface);
    try testing.expect(!win_damage.isEmpty());
    try testing.expect(win_damage.width() <= 780);
    try testing.expect(win_damage.height() <= 536);
    try testing.expect(!gui.isDirty());
}
