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
const intro_mod = @import("intro.zig");
const audio_mod = @import("audio.zig");
pub const noise_mod = @import("noise.zig");
pub const banner_font_mod = @import("banner_font.zig");
pub const host_info = @import("host_info.zig");
pub const cursor_mod = @import("cursor.zig");

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
        var had_access_denied = false;
        // Try DRM/KMS first (e.g. VirtIO-GPU)
        const dri_paths = [_][]const u8{ "/dev/dri/card0", "/dev/dri/card1" };
        for (dri_paths) |card_path| {
            if (drm.DrmDevice.init(card_path)) |dev| {
                const stride_pixels = dev.pitch / @sizeOf(u32);
                const buffer_pixels = stride_pixels * dev.height;
                const bb_mem = try allocator.alloc(u32, buffer_pixels);
                const cb_mem = try allocator.alloc(u32, buffer_pixels);
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
            } else |err| {
                if (err == error.AccessDenied) had_access_denied = true;
            }
        }

        // Fallback to legacy /dev/fb0
        const fb_path = "/dev/fb0";
        const fd_rc = linux.open(fb_path, .{ .ACCMODE = .RDWR }, 0);
        const signed_fd: isize = @bitCast(fd_rc);
        if (signed_fd >= 0) {
            const fd: i32 = @intCast(signed_fd);
            const w: u32 = drm.PREFERRED_WIDTH;
            const h: u32 = drm.PREFERRED_HEIGHT;
            const stride: usize = w * @sizeOf(u32);
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
            _ = linux.close(fd);
        } else {
            if (signed_fd == -@as(isize, @intFromEnum(linux.E.ACCES))) had_access_denied = true;
        }

        if (had_access_denied) return error.AccessDenied;
        return error.NoDisplayDeviceFound;
    }

    pub fn deinit(self: *Display, allocator: std.mem.Allocator) void {
        allocator.free(self.backbuffer_mem);
        allocator.free(self.clean_buffer_mem);
        if (self.drm_dev) |*d| d.deinit();
        if (self.fb_fd >= 0) {
            const map_size = self.stride * self.height;
            if (map_size > 0) {
                _ = linux.munmap(@ptrCast(self.fb_ptr), map_size);
            }
            _ = linux.close(self.fb_fd);
            self.fb_fd = -1;
        }
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
        const stride_pixels = self.stride / @sizeOf(u32);
        const ux0: usize = @intCast(x0);

        var y: usize = @intCast(y0);
        const end_y: usize = @intCast(y1);
        const max_len = @min(self.backbuffer_mem.len, (self.stride * self.height) / @sizeOf(u32));

        while (y < end_y) : (y += 1) {
            const row_start = std.math.mul(usize, y, stride_pixels) catch break;
            const row_offset = std.math.add(usize, row_start, ux0) catch break;
            const row_end = std.math.add(usize, row_offset, w) catch break;
            if (row_end > max_len) break;
            @memcpy(self.fb_ptr[row_offset..row_end], self.backbuffer_mem[row_offset..row_end]);
        }

        if (self.drm_dev) |*d| {
            d.dirtyFb(damage);
        }
    }

    pub fn flush(self: *Display) void {
        self.flushDamage(fb.Box.fromPosSize(0, 0, self.width, self.height));
    }
};

pub const MS_PER_SEC: i64 = 1000;
pub const NS_PER_MS: i64 = 1_000_000;
pub const TARGET_FPS: i64 = 60;
pub const FRAME_INTERVAL_MS: i64 = MS_PER_SEC / TARGET_FPS; // 16 ms (~60 FPS)
pub const POLL_TIMEOUT_MS: i32 = @intCast(FRAME_INTERVAL_MS);
pub const MAX_INPUT_DEVICES: usize = 32;

fn getMilliTimestamp() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * MS_PER_SEC + @divTrunc(@as(i64, @intCast(ts.nsec)), NS_PER_MS);
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
pub const REL_WHEEL: u16 = 0x08;
pub const ABS_X: u16 = 0x00;
pub const ABS_Y: u16 = 0x01;
pub const ABS_MT_POSITION_X: u16 = 0x35;
pub const ABS_MT_POSITION_Y: u16 = 0x36;
pub const EVDEV_ABS_MAX: i64 = 32767;

pub const input_absinfo = extern struct {
    value: i32 = 0,
    minimum: i32 = 0,
    maximum: i32 = 0,
    fuzz: i32 = 0,
    flat: i32 = 0,
    resolution: i32 = 0,
};

pub fn EVIOCGABS(abs: u32) u32 {
    const ioc_read: u32 = 2;
    const size: u32 = @sizeOf(input_absinfo);
    const type_char: u32 = 'E';
    return (ioc_read << 30) | (size << 16) | (type_char << 8) | (0x40 + abs);
}

pub const InputDeviceInfo = struct {
    fd: i32,
    min_x: i32 = 0,
    max_x: i32 = EVDEV_ABS_MAX,
    min_y: i32 = 0,
    max_y: i32 = EVDEV_ABS_MAX,
    has_abs: bool = false,

    pub fn scaleX(self: *const InputDeviceInfo, raw_x: i32, screen_w: u32) i32 {
        const span = self.max_x - self.min_x;
        if (span <= 0) return 0;
        const clamped_raw = std.math.clamp(raw_x, self.min_x, self.max_x);
        const rel: i64 = @as(i64, clamped_raw - self.min_x);
        const res = @divTrunc(rel * @as(i64, @intCast(screen_w)), @as(i64, span));
        return std.math.clamp(@as(i32, @intCast(res)), 0, @as(i32, @intCast(screen_w - 1)));
    }

    pub fn scaleY(self: *const InputDeviceInfo, raw_y: i32, screen_h: u32) i32 {
        const span = self.max_y - self.min_y;
        if (span <= 0) return 0;
        const clamped_raw = std.math.clamp(raw_y, self.min_y, self.max_y);
        const rel: i64 = @as(i64, clamped_raw - self.min_y);
        const res = @divTrunc(rel * @as(i64, @intCast(screen_h)), @as(i64, span));
        return std.math.clamp(@as(i32, @intCast(res)), 0, @as(i32, @intCast(screen_h - 1)));
    }
};

pub const BTN_LEFT: u16 = 0x110;
pub const BTN_RIGHT: u16 = 0x111;
pub const BTN_MIDDLE: u16 = 0x112;
pub const BTN_TOUCH: u16 = 0x14a;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Singleton lock: kernel-enforced flock preventing concurrent GUI processes
    // Check /run/diosix/diosix-gui.lock first, fallback to /tmp/.diosix-gui.lock
    var lock_fd: i32 = -1;
    const run_lock_path = "/run/diosix/diosix-gui.lock";
    const tmp_lock_path = "/tmp/.diosix-gui.lock";

    var lock_rc = linux.open(run_lock_path, .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true }, 0o600);
    var signed_lock: isize = @bitCast(lock_rc);
    if (signed_lock < 0) {
        lock_rc = linux.open(tmp_lock_path, .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true }, 0o600);
        signed_lock = @bitCast(lock_rc);
    }
    if (signed_lock >= 0) {
        lock_fd = @intCast(signed_lock);
        // Apply exclusive non-blocking lock (LOCK_EX | LOCK_NB = 2 | 4)
        const flock_rc = linux.flock(lock_fd, 2 | 4);
        const signed_flock: isize = @bitCast(flock_rc);
        if (signed_flock != 0) {
            std.debug.print("diosix-gui: Another instance is already running (locked). Exiting.\n", .{});
            _ = linux.close(lock_fd);
            return;
        }
        var pbuf: [32]u8 = undefined;
        const my_pid = linux.getpid();
        const s = std.fmt.bufPrint(&pbuf, "{d}\n", .{my_pid}) catch "";
        if (s.len > 0) {
            _ = linux.write(lock_fd, s.ptr, s.len);
        }
    }
    defer {
        if (lock_fd >= 0) {
            _ = linux.close(lock_fd);
        }
    }

    var stdout_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&stdout_buf, "Starting Diosix Monolithic GUI (diosix-gui)...\n", .{}) catch return;
    _ = linux.write(1, msg.ptr, msg.len);

    // 1. Initialize Display
    var display = Display.init(allocator) catch |err| {
        if (err == error.AccessDenied) {
            std.debug.print("diosix-gui: Permission denied accessing display device (/dev/dri/card* or /dev/fb0).\nEnsure user is in 'video' group or running with appropriate privileges.\n", .{});
        } else {
            std.debug.print("Failed to initialize display: {}\n", .{err});
        }
        return;
    };
    defer display.deinit(allocator);

    std.debug.print("Display initialized: {d}x{d}, Final Fantasy 7/8 theme engine active.\n", .{ display.width, display.height });

    // 2. Initialize Diosix GUI Coordinator
    var gui = try DiosixGui.init(allocator, display.width, display.height);
    defer gui.deinit();

    // 3. Open Evdev Input Devices with EVIOCGABS calibration
    var input_devs: [MAX_INPUT_DEVICES]InputDeviceInfo = undefined;
    var input_count: usize = 0;
    var dev_idx: u8 = 0;
    var had_input_eacces = false;

    while (dev_idx < MAX_INPUT_DEVICES) : (dev_idx += 1) {
        var path_buf: [32]u8 = undefined;
        const p_slice = std.fmt.bufPrint(&path_buf, "/dev/input/event{d}", .{dev_idx}) catch continue;
        path_buf[p_slice.len] = 0;
        const dev_z: [*:0]const u8 = @ptrCast(path_buf[0..p_slice.len :0]);
        const rc = linux.open(dev_z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc >= 0) {
            const ifd: i32 = @intCast(signed_rc);
            var dev_info = InputDeviceInfo{ .fd = ifd };

            var abs_x_info = input_absinfo{};
            if (@as(isize, @bitCast(linux.ioctl(ifd, EVIOCGABS(ABS_X), @intFromPtr(&abs_x_info)))) >= 0 and abs_x_info.maximum > abs_x_info.minimum) {
                dev_info.min_x = abs_x_info.minimum;
                dev_info.max_x = abs_x_info.maximum;
                dev_info.has_abs = true;
            } else if (@as(isize, @bitCast(linux.ioctl(ifd, EVIOCGABS(ABS_MT_POSITION_X), @intFromPtr(&abs_x_info)))) >= 0 and abs_x_info.maximum > abs_x_info.minimum) {
                dev_info.min_x = abs_x_info.minimum;
                dev_info.max_x = abs_x_info.maximum;
                dev_info.has_abs = true;
            }

            var abs_y_info = input_absinfo{};
            if (@as(isize, @bitCast(linux.ioctl(ifd, EVIOCGABS(ABS_Y), @intFromPtr(&abs_y_info)))) >= 0 and abs_y_info.maximum > abs_y_info.minimum) {
                dev_info.min_y = abs_y_info.minimum;
                dev_info.max_y = abs_y_info.maximum;
                dev_info.has_abs = true;
            } else if (@as(isize, @bitCast(linux.ioctl(ifd, EVIOCGABS(ABS_MT_POSITION_Y), @intFromPtr(&abs_y_info)))) >= 0 and abs_y_info.maximum > abs_y_info.minimum) {
                dev_info.min_y = abs_y_info.minimum;
                dev_info.max_y = abs_y_info.maximum;
                dev_info.has_abs = true;
            }

            input_devs[input_count] = dev_info;
            input_count += 1;
        } else {
            if (signed_rc == -@as(isize, @intFromEnum(linux.E.ACCES))) had_input_eacces = true;
        }
    }

    if (input_count == 0) {
        if (had_input_eacces) {
            std.debug.print("diosix-gui: Warning: Permission denied accessing input devices (/dev/input/event*).\nEnsure user is in 'input' group or running with appropriate privileges.\n", .{});
        } else {
            std.debug.print("diosix-gui: Warning: No input devices (/dev/input/event*) detected.\n", .{});
        }
    }

    // 4. Graphical Intro Animation and Audio Chime (Plays once per boot)
    var audio_player = audio_mod.AudioPlayer{};
    defer audio_player.stop();

    if (intro_mod.shouldPlayIntro()) {
        std.debug.print("Playing Diosix graphical intro animation and chime...\n", .{});
        audio_player.start();

        var intro_state = intro_mod.IntroState.init(getMilliTimestamp());
        var intro_last_time: i64 = intro_state.start_time_ms;

        while (intro_state.is_active) {
            const now = getMilliTimestamp();
            const dt: u32 = @intCast(@max(1, now - intro_last_time));
            intro_last_time = now;

            // Poll input devices non-blocking so mouse pointer and touch are live and responsive
            var pfds: [MAX_INPUT_DEVICES]linux.pollfd = undefined;
            for (input_devs[0..input_count], 0..) |idev, i| {
                pfds[i] = linux.pollfd{
                    .fd = idev.fd,
                    .events = linux.POLL.IN,
                    .revents = 0,
                };
            }
            const poll_res = linux.poll(&pfds, input_count, 0);
            const signed_poll: isize = @bitCast(poll_res);
            if (signed_poll > 0) {
                var i: usize = 0;
                while (i < input_count) : (i += 1) {
                    if ((pfds[i].revents & linux.POLL.IN) != 0) {
                        var ev_buf: [32]InputEvent = undefined;
                        const rd = linux.read(pfds[i].fd, @ptrCast(&ev_buf), @sizeOf(@TypeOf(ev_buf)));
                        const signed_rd: isize = @bitCast(rd);
                        if (signed_rd > 0) {
                            const count = @as(usize, @intCast(signed_rd)) / @sizeOf(InputEvent);
                            const dev_info = &input_devs[i];
                            var pending_x = gui.cursor.x;
                            var pending_y = gui.cursor.y;
                            var coords_changed = false;
                            var touch_skip = false;

                            for (ev_buf[0..count]) |ev| {
                                switch (ev.type) {
                                    EV_REL => {
                                        // Mouse motion updates real cursor position
                                        if (ev.code == REL_X) {
                                            pending_x = std.math.clamp(pending_x + ev.value, 0, @as(i32, @intCast(display.width - 1)));
                                            coords_changed = true;
                                        } else if (ev.code == REL_Y) {
                                            pending_y = std.math.clamp(pending_y + ev.value, 0, @as(i32, @intCast(display.height - 1)));
                                            coords_changed = true;
                                        }
                                    },
                                    EV_ABS => {
                                        if (ev.code == ABS_X or ev.code == ABS_MT_POSITION_X) {
                                            pending_x = dev_info.scaleX(ev.value, display.width);
                                            coords_changed = true;
                                        } else if (ev.code == ABS_Y or ev.code == ABS_MT_POSITION_Y) {
                                            pending_y = dev_info.scaleY(ev.value, display.height);
                                            coords_changed = true;
                                        }
                                    },
                                    EV_KEY => {
                                        const pressed = (ev.value != 0);
                                        if (pressed and (ev.code == BTN_LEFT or ev.code == BTN_TOUCH)) {
                                            touch_skip = true;
                                        }
                                    },
                                    else => {},
                                }
                            }

                            if (coords_changed) {
                                gui.handleMouseMove(pending_x, pending_y, gui.mouse_left_down);
                            }
                            if (touch_skip) {
                                intro_state.skip();
                                gui.handleMouseClick(pending_x, pending_y);
                                gui.mouse_left_down = true;
                                break;
                            }
                        }
                    }
                    if (!intro_state.is_active) break;
                }
            }

            if (!intro_state.is_active) break;

            intro_state.tick(dt, now, display.width, display.height);
            intro_state.render(&display.backbuffer, &gui);
            display.flushDamage(fb.Box.fromPosSize(0, 0, display.width, display.height));

            // Pace intro frame rate (~60 FPS)
            const frame_end = getMilliTimestamp();
            const frame_dur = frame_end - now;
            if (frame_dur < FRAME_INTERVAL_MS) {
                var sleep_ts = linux.timespec{
                    .sec = 0,
                    .nsec = @intCast((FRAME_INTERVAL_MS - frame_dur) * 1_000_000),
                };
                _ = linux.nanosleep(&sleep_ts, null);
            }
        }
        std.debug.print("Intro sequence completed (elapsed {d}ms). Handing over to live desktop.\n", .{intro_state.elapsed_ms});
    }

    // 6. Initial Render Frame (Full Screen Composited)
    gui.markFullDirty();
    const init_damage = gui.renderDamaged(&display.clean_buffer);
    display.backbuffer.copyBoxFrom(&display.clean_buffer, init_damage);
    if (gui.cursor.visible) {
        gui.cursor.draw(&display.backbuffer);
        display.prev_cursor_box = gui.cursor.getBox();
        display.prev_cursor_x = gui.cursor.x;
        display.prev_cursor_y = gui.cursor.y;
        display.cursor_drawn = true;
    } else {
        display.cursor_drawn = false;
    }
    display.flushDamage(init_damage);

    // 7. Main Multitasking and Event Loop with 60 FPS Frame Pacing
    var last_time: i64 = getMilliTimestamp();
    var last_render_time: i64 = last_time;

    while (true) {
        const cur_time = getMilliTimestamp();
        const elapsed_since_render = cur_time - last_render_time;
        const poll_timeout: i32 = if (gui.hasActiveAnimation())
            0
        else if (elapsed_since_render >= FRAME_INTERVAL_MS)
            0
        else
            @intCast(FRAME_INTERVAL_MS - elapsed_since_render);

        var pfds: [MAX_INPUT_DEVICES]linux.pollfd = undefined;
        for (input_devs[0..input_count], 0..) |idev, i| {
            pfds[i] = linux.pollfd{
                .fd = idev.fd,
                .events = linux.POLL.IN,
                .revents = 0,
            };
        }

        const poll_res = linux.poll(&pfds, input_count, poll_timeout);
        const signed_poll: isize = @bitCast(poll_res);

        const now = getMilliTimestamp();
        const dt_ms: u32 = @intCast(@max(1, now - last_time));
        last_time = now;

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
                        const dev_info = &input_devs[i];
                        var pending_x = gui.cursor.x;
                        var pending_y = gui.cursor.y;
                        var coords_changed = false;
                        var touch_press = false;
                        var touch_release = false;
                        var wheel_delta: i32 = 0;

                        for (ev_buf[0..count]) |ev| {
                            switch (ev.type) {
                                EV_KEY => {
                                    const pressed = (ev.value != 0);
                                    const code = ev.code;
                                    if (code == BTN_LEFT or code == BTN_TOUCH) {
                                        if (pressed) {
                                            touch_press = true;
                                        } else {
                                            touch_release = true;
                                        }
                                    }
                                },
                                EV_REL => {
                                    if (ev.code == REL_WHEEL) {
                                        wheel_delta -= ev.value;
                                    } else if (ev.code == REL_X) {
                                        pending_x = std.math.clamp(pending_x + ev.value, 0, @as(i32, @intCast(display.width - 1)));
                                        coords_changed = true;
                                    } else if (ev.code == REL_Y) {
                                        pending_y = std.math.clamp(pending_y + ev.value, 0, @as(i32, @intCast(display.height - 1)));
                                        coords_changed = true;
                                    }
                                },
                                EV_ABS => {
                                    // Handle tablet and touchscreen absolute coordinates
                                    if (ev.code == ABS_X or ev.code == ABS_MT_POSITION_X) {
                                        pending_x = dev_info.scaleX(ev.value, display.width);
                                        coords_changed = true;
                                    } else if (ev.code == ABS_Y or ev.code == ABS_MT_POSITION_Y) {
                                        pending_y = dev_info.scaleY(ev.value, display.height);
                                        coords_changed = true;
                                    }
                                },
                                else => {},
                            }
                        }

                        // Touch-first event resolution: position updates before touch action
                        if (coords_changed) {
                            gui.handleMouseMove(pending_x, pending_y, gui.mouse_left_down);
                        }
                        if (touch_press) {
                            gui.mouse_left_down = true;
                            gui.handleMouseClick(pending_x, pending_y);
                        }
                        if (touch_release) {
                            gui.mouse_left_down = false;
                            gui.handleMouseRelease();
                        }
                        if (wheel_delta != 0) {
                            gui.handleMouseScroll(pending_x, pending_y, wheel_delta);
                        }
                    }
                }
            }
        }

        // Pace frame composition and scanout to the target framerate (~60 FPS)
        if (now - last_render_time >= FRAME_INTERVAL_MS or signed_poll <= 0) {
            last_render_time = now;

            // Render updated frame with intelligent damage tracking
            const damage = gui.renderDamaged(&display.clean_buffer);

            const cursor_should_show = gui.cursor.visible;
            const cursor_state_changed = (cursor_should_show != display.cursor_drawn);
            const cursor_moved = cursor_should_show and (gui.cursor.x != display.prev_cursor_x or gui.cursor.y != display.prev_cursor_y);
            const cursor_box = gui.cursor.getBox();

            if (!damage.isEmpty() or cursor_moved or cursor_state_changed) {
                var flush_box = fb.Box{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };

                // 1. If clean_buffer had damage, copy damaged rect to backbuffer
                if (!damage.isEmpty()) {
                    display.backbuffer.copyBoxFrom(&display.clean_buffer, damage);
                    flush_box = flush_box.merge(damage);
                }

                // 2. If cursor moved or became hidden while previously drawn, restore old cursor area from clean_buffer into backbuffer
                if ((cursor_moved or (!cursor_should_show and display.cursor_drawn)) and display.cursor_drawn) {
                    display.backbuffer.copyBoxFrom(&display.clean_buffer, display.prev_cursor_box);
                    flush_box = flush_box.merge(display.prev_cursor_box);
                }

                // 3. Stamp cursor sprite onto backbuffer if cursor should show
                if (cursor_should_show) {
                    gui.cursor.draw(&display.backbuffer);
                    flush_box = flush_box.merge(cursor_box);

                    display.prev_cursor_box = cursor_box;
                    display.prev_cursor_x = gui.cursor.x;
                    display.prev_cursor_y = gui.cursor.y;
                    display.cursor_drawn = true;
                } else {
                    display.cursor_drawn = false;
                }

                // 4. Flush only the damaged region to hardware scanout and DRM
                if (!flush_box.isEmpty()) {
                    display.flushDamage(flush_box);
                }
            }
        }
    }
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
    try testing.expectEqual(@as(i32, 0), ic_sl.slider_val);
}

test "diosix-gui: icon grouping and exclusive radio behavior" {
    const allocator = testing.allocator;
    var win = Window.init(allocator, 1, 0, 0, 300, 300, "Group Test");
    defer win.deinit();

    const r1 = try win.addIcon(Icon.createTickBox(10, 10, 10, 200, 24, "Option A", true, 1, .exclusive));
    const r2 = try win.addIcon(Icon.createTickBox(11, 10, 40, 200, 24, "Option B", false, 1, .exclusive));
    const r3 = try win.addIcon(Icon.createTickBox(12, 10, 70, 200, 24, "Option C", false, 1, .exclusive));

    try testing.expect(r1.is_ticked);
    try testing.expect(!r2.is_ticked);
    try testing.expect(!r3.is_ticked);

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

    try testing.expect(!win.is_onscreen);
    try testing.expect(win.x < 0);

    win.setOnScreen(true);
    try testing.expect(win.is_onscreen);
    try testing.expectEqual(@as(i32, 50), win.x);
    try testing.expectEqual(@as(i32, 60), win.y);

    win.setOnScreen(false);
    try testing.expect(!win.is_onscreen);
    try testing.expect(win.x < 0);
}

test "diosix-gui: coordinator initialization, dynamic layout, and host telemetry panes" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // 1. Initial layout has exactly 3 windows: Main Menu (100), Version (101), Host Uptime (102)
    try testing.expectEqual(@as(usize, 3), gui.windows.items.len);

    const win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    try testing.expect(win_menu.is_onscreen);
    try testing.expectEqual(gui_mod.BORDER_GAP, win_menu.x);
    try testing.expectEqual(gui_mod.BORDER_GAP, win_menu.y);
    try testing.expectEqual(@as(usize, 3), win_menu.icons.items.len);

    const item_guests = &win_menu.icons.items[0];
    const item_status = &win_menu.icons.items[1];
    const item_config = &win_menu.icons.items[2];
    try testing.expectEqualStrings("Guests", item_guests.getText());
    try testing.expectEqualStrings("Status", item_status.getText());
    try testing.expectEqualStrings("Config", item_config.getText());
    try testing.expectEqual(icon_mod.IconType.menu_item, item_guests.icon_type);
    try testing.expectEqual(icon_mod.IconType.menu_item, item_status.icon_type);
    try testing.expectEqual(icon_mod.IconType.menu_item, item_config.icon_type);
    // 2. Mouse hover over menu items sets is_hovered
    gui.handleMouseMove(win_menu.x + item_guests.rel_x + 5, win_menu.y + item_guests.rel_y + 5, false);
    try testing.expect(item_guests.is_hovered);
    try testing.expect(!item_status.is_hovered);

    gui.handleMouseMove(win_menu.x + item_status.rel_x + 5, win_menu.y + item_status.rel_y + 5, false);
    try testing.expect(!item_guests.is_hovered);
    try testing.expect(item_status.is_hovered);

    gui.handleMouseMove(win_menu.x + item_config.rel_x + 5, win_menu.y + item_config.rel_y + 5, false);
    try testing.expect(!item_status.is_hovered);
    try testing.expect(item_config.is_hovered);

    // 4. Version pane in bottom-right corner
    const win_ver = gui.getWindow(gui_mod.WIN_VERSION_ID).?;
    try testing.expect(win_ver.is_onscreen);
    try testing.expectEqual(@as(u32, 40), win_ver.height);
    try testing.expectEqual(@as(i32, 1280) - @as(i32, @intCast(win_ver.width)) - gui_mod.BORDER_GAP, win_ver.x);
    try testing.expectEqual(@as(i32, 800) - @as(i32, @intCast(win_ver.height)) - gui_mod.BORDER_GAP, win_ver.y);
    const ver_icon = win_ver.getIconById(gui_mod.ICON_VERSION_TEXT_ID).?;
    try testing.expect(std.mem.startsWith(u8, ver_icon.getText(), "diosix"));
    try testing.expect(!ver_icon.is_selectable);

    // 5. Active Help pane spanning remaining screen width with even spacing
    const win_help = gui.getWindow(gui_mod.WIN_HELP_ID).?;
    try testing.expect(win_help.is_onscreen);
    try testing.expectEqual(@as(u32, 40), win_help.height);
    try testing.expectEqual(gui_mod.BORDER_GAP, win_help.x);
    try testing.expectEqual(win_ver.y, win_help.y);
    // Spacing between help pane and version pane equals BORDER_GAP (16px)
    try testing.expectEqual(gui_mod.BORDER_GAP, win_ver.x - (win_help.x + @as(i32, @intCast(win_help.width))));
    // Spacing between version pane and right screen edge equals BORDER_GAP (16px)
    try testing.expectEqual(gui_mod.BORDER_GAP, @as(i32, 1280) - (win_ver.x + @as(i32, @intCast(win_ver.width))));

    const help_icon = win_help.getIconById(gui_mod.ICON_HELP_TEXT_ID).?;

    // 6. Active Help dynamic updates:
    // Hovering over Guests menu item
    gui.handleMouseMove(win_menu.x + item_guests.rel_x + 5, win_menu.y + item_guests.rel_y + 5, false);
    try testing.expectEqualStrings("View and manage guest virtual machines", help_icon.getText());

    // Hovering over Status menu item
    gui.handleMouseMove(win_menu.x + item_status.rel_x + 5, win_menu.y + item_status.rel_y + 5, false);
    try testing.expectEqualStrings("View real-time system information", help_icon.getText());

    // Hovering over Config menu item
    gui.handleMouseMove(win_menu.x + item_config.rel_x + 5, win_menu.y + item_config.rel_y + 5, false);
    try testing.expectEqualStrings("Configure window appearance and desktop background themes", help_icon.getText());

    // Hovering over Version pane text
    gui.handleMouseMove(win_ver.x + ver_icon.rel_x + 5, win_ver.y + ver_icon.rel_y + 5, false);
    try testing.expectEqualStrings("Hypervisor name, version number, build branch, commit hash, and security lock mode", help_icon.getText());

    // Moving mouse to empty space displays priority fallback "Welcome to diosix"
    gui.handleMouseMove(500, 500, false);
    try testing.expectEqualStrings("Welcome to diosix", help_icon.getText());

    // 7. Clicking Status menu item opens the Status pane
    gui.handleMouseClick(win_menu.x + item_status.rel_x + 5, win_menu.y + item_status.rel_y + 5);
    gui.completeNavAnimation();

    const win_status = gui.getWindow(gui_mod.WIN_STATUS_ID).?;
    try testing.expect(win_status.is_onscreen);
    try testing.expectEqual(@as(u32, @intCast(@as(i32, 1280) - gui_mod.BORDER_GAP - win_status.x)), win_status.width);

    // Verify Host section
    const status_host_hdr = win_status.getIconById(gui_mod.ICON_STATUS_HOST_HDR_ID).?;
    try testing.expectEqualStrings("Host", status_host_hdr.getText());

    // Verify Table Column Alignment (Right-aligned labels ending at col1_right = 140, values starting at col2_x = 160)
    const col1_right: i32 = 140;
    const col2_x: i32 = 160;

    const lbl_uptime = win_status.getIconById(gui_mod.ICON_STATUS_HOST_UPTIME_LABEL_ID).?;
    const val_uptime = win_status.getIconById(gui_mod.ICON_STATUS_HOST_UPTIME_ID).?;
    try testing.expectEqualStrings("Uptime", lbl_uptime.getText());
    try testing.expectEqual(col1_right, lbl_uptime.rel_x + @as(i32, @intCast(font.measureString(lbl_uptime.getText()))));
    try testing.expectEqual(col2_x, val_uptime.rel_x);
    try testing.expectEqual(lbl_uptime.rel_y, val_uptime.rel_y);

    const lbl_cpu = win_status.getIconById(gui_mod.ICON_STATUS_HOST_CPU_LABEL_ID).?;
    const val_cpu = win_status.getIconById(gui_mod.ICON_STATUS_HOST_CPU_ID).?;
    try testing.expectEqualStrings("CPU cores", lbl_cpu.getText());
    try testing.expectEqual(col1_right, lbl_cpu.rel_x + @as(i32, @intCast(font.measureString(lbl_cpu.getText()))));
    try testing.expectEqual(col2_x, val_cpu.rel_x);
    try testing.expectEqual(lbl_cpu.rel_y, val_cpu.rel_y);

    const lbl_ram = win_status.getIconById(gui_mod.ICON_STATUS_HOST_RAM_LABEL_ID).?;
    const val_ram = win_status.getIconById(gui_mod.ICON_STATUS_HOST_RAM_ID).?;
    try testing.expectEqualStrings("RAM", lbl_ram.getText());
    try testing.expectEqual(col1_right, lbl_ram.rel_x + @as(i32, @intCast(font.measureString(lbl_ram.getText()))));
    try testing.expectEqual(col2_x, val_ram.rel_x);
    try testing.expectEqual(lbl_ram.rel_y, val_ram.rel_y);

    const lbl_time = win_status.getIconById(gui_mod.ICON_STATUS_HOST_TIME_LABEL_ID).?;
    const val_time = win_status.getIconById(gui_mod.ICON_STATUS_HOST_TIME_ID).?;
    try testing.expectEqualStrings("Time and date", lbl_time.getText());
    try testing.expectEqual(col1_right, lbl_time.rel_x + @as(i32, @intCast(font.measureString(lbl_time.getText()))));
    try testing.expectEqual(col2_x, val_time.rel_x);
    try testing.expectEqual(lbl_time.rel_y, val_time.rel_y);

    // Verify Hypervisor section
    const status_hv_hdr = win_status.getIconById(gui_mod.ICON_STATUS_HV_HDR_ID).?;
    try testing.expectEqualStrings("Hypervisor", status_hv_hdr.getText());

    const lbl_build = win_status.getIconById(gui_mod.ICON_STATUS_HV_BUILD_LABEL_ID).?;
    const val_b1 = win_status.getIconById(gui_mod.ICON_STATUS_HV_BUILD1_ID).?;
    const val_b2 = win_status.getIconById(gui_mod.ICON_STATUS_HV_BUILD2_ID).?;
    try testing.expectEqualStrings("Build", lbl_build.getText());
    try testing.expectEqual(col1_right, lbl_build.rel_x + @as(i32, @intCast(font.measureString(lbl_build.getText()))));
    try testing.expectEqual(col2_x, val_b1.rel_x);
    try testing.expectEqual(col2_x, val_b2.rel_x);
    try testing.expectEqual(lbl_build.rel_y, val_b1.rel_y);

    const lbl_foot = win_status.getIconById(gui_mod.ICON_STATUS_HV_FOOTPRINT_LABEL_ID).?;
    const val_foot = win_status.getIconById(gui_mod.ICON_STATUS_HV_FOOTPRINT_ID).?;
    try testing.expectEqualStrings("Footprint", lbl_foot.getText());
    try testing.expectEqual(col1_right, lbl_foot.rel_x + @as(i32, @intCast(font.measureString(lbl_foot.getText()))));
    try testing.expectEqual(col2_x, val_foot.rel_x);
    try testing.expectEqual(lbl_foot.rel_y, val_foot.rel_y);

    // When hypervisor info is unavailable (/dev/diosix not present), fallback is strictly "--"
    try testing.expectEqualStrings("--", val_cpu.getText());
    try testing.expectEqualStrings("--", val_ram.getText());
    try testing.expectEqualStrings("--", val_b1.getText());
    try testing.expectEqualStrings("--", val_foot.getText());

    // Priority 2: Moving cursor over Status pane displays pane help text (text icons have no help text)
    gui.handleMouseMove(win_status.x + 10, win_status.y + 10, false);
    try testing.expectEqualStrings("Information about this host system and hypervisor", help_icon.getText());

    // Verify Status menu item is selected and menu is contracted with Back pane present
    const icon_status = win_menu.getIconById(gui_mod.ICON_MENU_STATUS_ID).?;
    try testing.expect(icon_status.is_selected);
    try testing.expect(gui.getWindow(gui_mod.WIN_BACK_ID) != null);
    try testing.expectEqual(gui_mod.MENU_CONTRACTED_H, win_menu.height);

    // 8. Clicking Back button returns to main menu and repopulates full menu
    const win_back = gui.getWindow(gui_mod.WIN_BACK_ID).?;
    const back_btn = win_back.getIconById(gui_mod.ICON_BACK_BTN_ID).?;
    gui.handleMouseClick(win_back.x + back_btn.rel_x + 5, win_back.y + back_btn.rel_y + 5);
    gui.completeNavAnimation();
    try testing.expect(gui.getWindow(gui_mod.WIN_STATUS_ID) == null);
    try testing.expect(gui.getWindow(gui_mod.WIN_BACK_ID) == null);
    try testing.expectEqual(gui_mod.MENU_FULL_H, win_menu.height);
    try testing.expectEqual(@as(usize, 3), win_menu.icons.items.len);

    // Moving mouse to empty space displays fallback "Welcome to diosix"
    gui.handleMouseMove(500, 500, false);
    try testing.expectEqualStrings("Welcome to diosix", help_icon.getText());
}

test "diosix-gui: dynamic window lifecycle (createWindow, destroyWindow, destroyAllWindows)" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // 1. Create dynamic window
    const win = try gui.createWindow(501, 100, 100, 300, 200, "Dynamic Pane");
    try testing.expect(win.is_onscreen);
    try testing.expectEqual(@as(usize, 4), gui.windows.items.len);

    _ = try win.addIcon(Icon.createButton(5001, 10, 10, 100, 30, "Action"));
    try testing.expect(gui.getWindow(501) != null);

    // 2. Destroy dynamic window
    const destroyed = gui.destroyWindow(501);
    try testing.expect(destroyed);
    try testing.expectEqual(@as(usize, 3), gui.windows.items.len);
    try testing.expect(gui.getWindow(501) == null);

    // 3. Destroy all windows
    gui.destroyAllWindows();
    try testing.expectEqual(@as(usize, 0), gui.windows.items.len);
}

test "diosix-gui: left menu scrollable auto-activation when exceeding screen height" {
    const allocator = testing.allocator;
    // When screen height is small (e.g. 70px), available height is 70 - 32 = 38px
    // Total menu content is 92px, so window height is clamped to 38px, making it scrollable
    var gui = try DiosixGui.init(allocator, 800, 70);
    defer gui.deinit();

    const win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    try testing.expect(win_menu.isScrollable());
    try testing.expect(win_menu.getMaxScroll() > 0);
}

test "diosix-gui: static graduated background rendering" {
    var pixel_buffer: [100 * 100]u32 = undefined;
    var surface = fb.Surface.init(&pixel_buffer, 100, 100, 400);

    const top_col: u32 = 0x004C8BE0;
    const bot_col: u32 = 0x000C1836;

    surface.drawGraduatedBackground(top_col, bot_col);

    const top_px = surface.getPixel(50, 0);
    const top_b = top_px & 0xFF;
    try testing.expect(top_b >= 200);

    const bot_px = surface.getPixel(50, 99);
    const bot_b = bot_px & 0xFF;
    try testing.expect(bot_b < 100);
}

test "diosix-gui: real-time window transparency and backdrop controls" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    try testing.expectEqual(@as(u32, 30), gui.window_transparency);
    try testing.expectEqual(@as(u8, 178), gui.getWindowOpacityAlpha());

    gui.setWindowTransparency(0);
    try testing.expectEqual(@as(u32, 0), gui.window_transparency);
    try testing.expectEqual(@as(u8, 255), gui.getWindowOpacityAlpha());

    gui.setWindowTransparency(80);
    try testing.expectEqual(@as(u32, 80), gui.window_transparency);
    try testing.expectEqual(@as(u8, 51), gui.getWindowOpacityAlpha());

    try testing.expectEqual(@as(u32, 50), gui.getBlurStrength());
    try testing.expectEqual(@as(u32, 5), gui.getBlurRadius());

    gui.setBlurStrength(100);
    try testing.expectEqual(@as(u32, 100), gui.getBlurStrength());
    try testing.expectEqual(@as(u32, 10), gui.getBlurRadius());

    gui.setBackdropTopColor(0x00C86840);
    try testing.expectEqual(@as(u32, 0x00C86840), gui.bg_top_color);

    gui.setBackdropBotColor(0x00060B18);
    try testing.expectEqual(@as(u32, 0x00060B18), gui.bg_bot_color);
}

test "diosix-gui: surface copyBoxFrom tile copying" {
    var src_pixels: [100 * 100]u32 = undefined;
    var dst_pixels: [100 * 100]u32 = undefined;

    @memset(&src_pixels, 0x00FF0000);
    @memset(&dst_pixels, 0x00000000);

    var src = fb.Surface.init(&src_pixels, 100, 100, 400);
    var dst = fb.Surface.init(&dst_pixels, 100, 100, 400);

    const copy_box = fb.Box.fromPosSize(20, 20, 40, 40);
    dst.copyBoxFrom(&src, copy_box);

    try testing.expectEqual(@as(u32, 0x00FF0000), dst.getPixel(30, 30));
    try testing.expectEqual(@as(u32, 0x00000000), dst.getPixel(10, 10));
    try testing.expectEqual(@as(u32, 0x00000000), dst.getPixel(70, 70));
}

test "diosix-gui: intelligent damage tracking and idle frame skipping" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const clean_pixels = try allocator.alloc(u32, 1280 * 800);
    defer allocator.free(clean_pixels);
    var clean_surface = fb.Surface.init(clean_pixels.ptr, 1280, 800, 1280 * @sizeOf(u32));

    try testing.expect(gui.isDirty());
    const init_damage = gui.renderDamaged(&clean_surface);
    try testing.expect(!init_damage.isEmpty());
    try testing.expect(!gui.isDirty());

    const idle_damage = gui.renderDamaged(&clean_surface);
    try testing.expect(idle_damage.isEmpty());

    gui.markWindowDirty(gui_mod.WIN_MENU_ID);
    try testing.expect(gui.isDirty());

    const partial_damage = gui.renderDamaged(&clean_surface);
    try testing.expect(!partial_damage.isEmpty());
    try testing.expect(!gui.isDirty());
}

test "diosix-gui: icon text selection, select-all, and cut/copy/paste primitives" {
    var ic = Icon.createReadWrite(1, 0, 0, 200, 30, "Hello World");
    try testing.expectEqualStrings("Hello World", ic.getText());
    try testing.expect(!ic.hasSelection());

    ic.selection_start = 0;
    ic.selection_end = 5;
    try testing.expect(ic.hasSelection());
    try testing.expectEqualStrings("Hello", ic.getSelectedText());

    _ = ic.deleteSelection();
    try testing.expectEqualStrings(" World", ic.getText());
    try testing.expect(!ic.hasSelection());

    ic.insertString("Brave");
    try testing.expectEqualStrings("Brave World", ic.getText());

    ic.selectAll();
    try testing.expect(ic.hasSelection());
    try testing.expectEqualStrings("Brave World", ic.getSelectedText());

    ic.clearField();
    try testing.expectEqualStrings("", ic.getText());
    try testing.expectEqual(@as(usize, 0), ic.cursor_pos);
}

test "diosix-gui: mouse click and select dragging in text field" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const win = try gui.createWindow(201, 100, 100, 600, 400, "Drag Test Pane");
    const icon = try win.addIcon(Icon.createReadWrite(1, 10, 50, 400, 30, "Diosix Drag Test"));
    gui.focusWindow(gui.windows.items.len - 1);

    const click_x = win.x + icon.rel_x + 10;
    const click_y = win.y + icon.rel_y + 10;

    _ = win.handleMouseClick(@ptrCast(&gui), click_x, click_y);
    try testing.expect(icon.is_focused);
    try testing.expect(icon.is_dragging_select);
    try testing.expectEqual(@as(usize, 0), icon.selection_start.?);

    const drag_x = win.x + icon.rel_x + 80;
    _ = win.handleMouseMove(@ptrCast(&gui), drag_x, click_y, true);
    try testing.expect(icon.hasSelection());
    try testing.expect(icon.selection_end.? > 0);

    _ = win.handleMouseRelease();
    try testing.expect(!icon.is_dragging_select);
    try testing.expect(icon.hasSelection());

    _ = icon.deleteSelection();
    try testing.expect(!icon.hasSelection());
    try testing.expect(icon.getText().len < 16);
}

test "diosix-gui: action button selection via mouse click with press and release feedback" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const win = try gui.createWindow(401, 50, 50, 300, 200, "Button Test Pane");
    var btn = Icon.createButton(1, 10, 45, 200, 30, "Action Button");

    const Handler = struct {
        var clicked_count: u32 = 0;
        fn onClick(_: *anyopaque, _: *anyopaque, _: *Icon) void {
            clicked_count += 1;
        }
    };
    Handler.clicked_count = 0;
    btn.callback = Handler.onClick;
    _ = try win.addIcon(btn);
    gui.focusWindow(gui.windows.items.len - 1);

    const btn_ref = &win.icons.items[0];

    // 1. Mouse click button
    gui.handleMouseClick(win.x + btn_ref.rel_x + 5, win.y + btn_ref.rel_y + 5);
    try testing.expect(btn_ref.is_active_press);
    try testing.expectEqual(@as(u32, 1), Handler.clicked_count);

    // 2. Mouse release
    gui.handleMouseRelease();
    try testing.expect(!btn_ref.is_active_press);
}

test "diosix-gui: graphical clipping of icons to bounding box" {
    const allocator = testing.allocator;
    const s_w: u32 = 200;
    const s_h: u32 = 100;
    const pixel_mem = try allocator.alloc(u32, s_w * s_h);
    defer allocator.free(pixel_mem);
    @memset(pixel_mem, 0);
    var surface = fb.Surface.init(pixel_mem.ptr, s_w, s_h, s_w * @sizeOf(u32));

    var label_icon = icon_mod.Icon.createReadOnly(
        1001,
        20,
        20,
        50,
        24,
        "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW",
    );
    label_icon.render(&surface, 0, 0, false);

    var inside_non_zero: usize = 0;
    var y: u32 = 20;
    while (y < 44) : (y += 1) {
        var x: u32 = 20;
        while (x < 70) : (x += 1) {
            if (pixel_mem[y * s_w + x] != 0) inside_non_zero += 1;
        }
    }
    try testing.expect(inside_non_zero > 0);

    y = 0;
    while (y < s_h) : (y += 1) {
        var x: u32 = 70;
        while (x < s_w) : (x += 1) {
            try testing.expectEqual(@as(u32, 0), pixel_mem[y * s_w + x]);
        }
    }
}

test "diosix-gui: graphical clipping inside button and editable text field" {
    const allocator = testing.allocator;
    const s_w: u32 = 180;
    const s_h: u32 = 80;
    const pixel_mem = try allocator.alloc(u32, s_w * s_h);
    defer allocator.free(pixel_mem);

    @memset(pixel_mem, 0);
    var surface = fb.Surface.init(pixel_mem.ptr, s_w, s_h, s_w * @sizeOf(u32));

    var btn = icon_mod.Icon.createButton(
        2001,
        10,
        10,
        60,
        30,
        "An Extremely Long Button Label That Exceeds Width",
    );
    btn.render(&surface, 0, 0, false);

    var y: u32 = 0;
    while (y < s_h) : (y += 1) {
        var x: u32 = 70;
        while (x < s_w) : (x += 1) {
            try testing.expectEqual(@as(u32, 0), pixel_mem[y * s_w + x]);
        }
    }
}

test "diosix-gui: Surface pushClip and popClip stack nesting" {
    const allocator = testing.allocator;
    const s_w: u32 = 100;
    const s_h: u32 = 100;
    const pixel_mem = try allocator.alloc(u32, s_w * s_h);
    defer allocator.free(pixel_mem);
    var surface = fb.Surface.init(pixel_mem.ptr, s_w, s_h, s_w * @sizeOf(u32));

    try testing.expectEqual(@as(i32, 0), surface.clip.x0);
    try testing.expectEqual(@as(i32, 100), surface.clip.x1);

    const clip1 = surface.pushClip(fb.Box.fromPosSize(10, 10, 50, 50));
    try testing.expectEqual(@as(i32, 10), surface.clip.x0);
    try testing.expectEqual(@as(i32, 60), surface.clip.x1);

    const clip2 = surface.pushClip(fb.Box.fromPosSize(30, 30, 50, 50));
    try testing.expectEqual(@as(i32, 30), surface.clip.x0);
    try testing.expectEqual(@as(i32, 60), surface.clip.x1);

    surface.popClip(clip2);
    try testing.expectEqual(@as(i32, 10), surface.clip.x0);
    try testing.expectEqual(@as(i32, 60), surface.clip.x1);

    surface.popClip(clip1);
    try testing.expectEqual(@as(i32, 0), surface.clip.x0);
    try testing.expectEqual(@as(i32, 100), surface.clip.x1);
}

test "diosix-gui: scrollable pane scrolling, bounds, and scrollToKeepIconVisible" {
    const allocator = testing.allocator;
    var win = Window.init(allocator, 999, 100, 100, 400, 300, "SCROLL TEST");
    defer win.deinit();
    win.setOnScreen(true);

    _ = try win.addIcon(Icon.createReadOnly(1, 20, 50, 360, 30, "Item 1"));
    _ = try win.addIcon(Icon.createReadOnly(2, 20, 150, 360, 30, "Item 2"));
    _ = try win.addIcon(Icon.createReadOnly(3, 20, 250, 360, 30, "Item 3"));
    _ = try win.addIcon(Icon.createReadOnly(4, 20, 350, 360, 30, "Item 4"));
    _ = try win.addIcon(Icon.createReadOnly(5, 20, 450, 360, 30, "Item 5"));

    try testing.expect(win.isScrollable());
    try testing.expectEqual(@as(i32, 190), win.getMaxScroll());

    _ = win.scrollBy(50);
    try testing.expectEqual(@as(i32, 50), win.scroll_y);

    _ = win.scrollBy(500);
    try testing.expectEqual(@as(i32, 190), win.scroll_y);

    _ = win.scrollBy(-500);
    try testing.expectEqual(@as(i32, 0), win.scroll_y);
}

test "diosix-gui: scrollbar proximity detection, auto-hiding fade, and drag interaction" {
    const allocator = testing.allocator;
    var win = Window.init(allocator, 998, 100, 100, 400, 300, "PROXIMITY TEST");
    defer win.deinit();
    win.setOnScreen(true);

    _ = try win.addIcon(Icon.createReadOnly(1, 20, 50, 360, 30, "Item 1"));
    _ = try win.addIcon(Icon.createReadOnly(2, 20, 450, 360, 30, "Item 2"));

    const track = win.getScrollbarTrackBox();
    const near_x = track.x0 - 10;
    const near_y = track.y0 + 20;

    _ = win.handleMouseMove(undefined, near_x, near_y, false);
    try testing.expect(win.scrollbar_alpha > 0);

    const far_x = win.x + 20;
    const far_y = win.y + 20;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        _ = win.handleMouseMove(undefined, far_x, far_y, false);
    }
    try testing.expectEqual(@as(u8, 0), win.scrollbar_alpha);
}

test "diosix-gui: strict viewport clipping prevents content from overdrawing title bar and borders" {
    const allocator = testing.allocator;
    var win = Window.init(allocator, 997, 100, 100, 400, 300, "STRICT CLIPPING TEST");
    defer win.deinit();
    win.setOnScreen(true);

    _ = try win.addIcon(Icon.createReadOnly(1, 20, 50, 360, 30, "Item 1"));
    _ = try win.addIcon(Icon.createReadOnly(2, 20, 450, 360, 30, "Item 2"));

    _ = win.scrollTo(100);

    const pixel_mem = try allocator.alloc(u32, 600 * 500);
    defer allocator.free(pixel_mem);
    @memset(pixel_mem, 0);
    var surface = fb.Surface.init(pixel_mem.ptr, 600, 500, 600 * @sizeOf(u32));

    win.render(&surface, 255);

    var y: u32 = 0;
    while (y < 100) : (y += 1) {
        var x: u32 = 0;
        while (x < 600) : (x += 1) {
            try testing.expectEqual(@as(u32, 0), pixel_mem[y * 600 + x]);
        }
    }
}

test "diosix-gui: mouse wheel scroll navigation" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const win = try gui.createWindow(601, 50, 50, 400, 300, "Scroll Nav Test");
    _ = try win.addIcon(Icon.createReadOnly(1, 20, 50, 360, 30, "Item 1"));
    _ = try win.addIcon(Icon.createReadOnly(2, 20, 450, 360, 30, "Item 2"));
    gui.focusWindow(gui.windows.items.len - 1);

    try testing.expect(win.isScrollable());
    const max_s = win.getMaxScroll();
    try testing.expect(max_s > 0);

    // 1. Mouse wheel down -> scroll by 30
    gui.handleMouseScroll(win.x + 50, win.y + 50, 1);
    try testing.expectEqual(@as(i32, 30), win.scroll_y);

    // 2. Mouse wheel up -> scroll back up
    gui.handleMouseScroll(win.x + 50, win.y + 50, -1);
    try testing.expectEqual(@as(i32, 0), win.scroll_y);
}

fn writePpmFile(surface: *const fb.Surface, path_z: [*:0]const u8) !void {
    const rc = linux.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    const signed_rc: isize = @bitCast(rc);
    if (signed_rc < 0) return error.OpenFileFailed;
    const fd: i32 = @intCast(signed_rc);
    defer _ = linux.close(fd);

    var hdr_buf: [32]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "P6\n{d} {d}\n255\n", .{ surface.width, surface.height }) catch return;
    _ = linux.write(fd, hdr.ptr, hdr.len);

    var rgb_row: [1280 * 3]u8 = undefined;
    var y: u32 = 0;
    while (y < surface.height) : (y += 1) {
        var x: u32 = 0;
        while (x < surface.width) : (x += 1) {
            const px = surface.pixels[y * surface.stridePixels() + x];
            rgb_row[x * 3 + 0] = @intCast((px >> 16) & 0xFF);
            rgb_row[x * 3 + 1] = @intCast((px >> 8) & 0xFF);
            rgb_row[x * 3 + 2] = @intCast(px & 0xFF);
        }
        _ = linux.write(fd, &rgb_row, surface.width * 3);
    }
}

test "diosix-gui: render intro animation frames for the two warm moments" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const pixel_mem = try allocator.alloc(u32, 1280 * 800);
    defer allocator.free(pixel_mem);
    var surface = fb.Surface.init(pixel_mem.ptr, 1280, 800, 1280 * @sizeOf(u32));

    var intro = intro_mod.IntroState.init(0);

    intro.elapsed_ms = 2100;
    intro.render(&surface, &gui);
    try writePpmFile(&surface, "/tmp/diosix_intro_moment1.ppm");

    intro.elapsed_ms = 4600;
    intro.render(&surface, &gui);
    try writePpmFile(&surface, "/tmp/diosix_intro_moment2.ppm");
}

test "diosix-gui: render dynamic layout screenshot for visual verification" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const pixel_mem = try allocator.alloc(u32, 1280 * 800);
    defer allocator.free(pixel_mem);
    var surface = fb.Surface.init(pixel_mem.ptr, 1280, 800, 1280 * @sizeOf(u32));

    // 1. Mouse Mode: Hover mouse over "Status" menu item
    const win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    const status_item = &win_menu.icons.items[1];
    gui.handleMouseMove(win_menu.x + status_item.rel_x + 10, win_menu.y + status_item.rel_y + 10, false);

    gui.markFullDirty();
    _ = gui.renderDamaged(&surface);
    gui.cursor.draw(&surface);
    try writePpmFile(&surface, "/tmp/diosix_new_layout.ppm");
}

test "diosix-gui: taller info panes and non-selectable icon text immunity" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const win_ver = gui.getWindow(gui_mod.WIN_VERSION_ID).?;
    const win_help = gui.getWindow(gui_mod.WIN_HELP_ID).?;
    const win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;

    // 1. Geometry verification: 40px height for panes, 24px height for icons, rel_y 8
    try testing.expectEqual(@as(u32, 40), win_ver.height);
    try testing.expectEqual(@as(u32, 40), win_help.height);

    const ver_icon = win_ver.getIconById(gui_mod.ICON_VERSION_TEXT_ID).?;
    try testing.expectEqual(@as(u32, 24), ver_icon.height);
    try testing.expectEqual(@as(i32, 8), ver_icon.rel_y);
    try testing.expect(!ver_icon.is_selectable);

    const help_icon = win_help.getIconById(gui_mod.ICON_HELP_TEXT_ID).?;
    try testing.expectEqual(@as(u32, 24), help_icon.height);
    try testing.expectEqual(@as(i32, 8), help_icon.rel_y);
    try testing.expect(!help_icon.is_selectable);

    // 2. Active window is initially the left menu
    try testing.expect(win_menu.is_active);
    try testing.expect(!win_ver.is_active);
    try testing.expect(!win_help.is_active);
    try testing.expectEqual(@as(?usize, null), win_ver.focused_icon_idx);
    try testing.expectEqual(@as(?usize, null), win_help.focused_icon_idx);

    // 3. Mouse clicks inside version pane or help pane do NOT steal focus or select text
    gui.handleMouseClick(win_ver.x + 20, win_ver.y + 20);
    try testing.expect(win_menu.is_active);
    try testing.expect(!win_ver.is_active);
    try testing.expect(!ver_icon.is_focused);
    try testing.expectEqual(@as(?usize, null), win_ver.focused_icon_idx);

    gui.handleMouseClick(win_help.x + 20, win_help.y + 20);
    try testing.expect(win_menu.is_active);
    try testing.expect(!win_help.is_active);
    try testing.expect(!help_icon.is_focused);
    try testing.expectEqual(@as(?usize, null), win_help.focused_icon_idx);

    // 4. Mouse movement over version/help pane does NOT set is_hovered on non-selectable icons
    gui.handleMouseMove(win_ver.x + 20, win_ver.y + 20, false);
    try testing.expect(!ver_icon.is_hovered);

    gui.handleMouseMove(win_help.x + 20, win_help.y + 20, false);
    try testing.expect(!help_icon.is_hovered);

    // 5. Programmatic setSelectable(false) disables hit testing and clears focus
    var btn = Icon.createButton(9999, 10, 10, 100, 30, "Click Me");
    try testing.expect(btn.is_selectable);
    try testing.expect(btn.hitTest(0, 0, 20, 20));

    btn.is_focused = true;
    btn.is_hovered = true;
    btn.setSelectable(false);
    try testing.expect(!btn.is_selectable);
    try testing.expect(!btn.is_focused);
    try testing.expect(!btn.is_hovered);
    try testing.expect(!btn.hitTest(0, 0, 20, 20));
}

test "diosix-gui: render active help and status pane screenshots for visual verification" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const pixel_mem = try allocator.alloc(u32, 1280 * 800);
    defer allocator.free(pixel_mem);
    var surface = fb.Surface.init(pixel_mem.ptr, 1280, 800, 1280 * @sizeOf(u32));

    const win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    const guests_item = &win_menu.icons.items[0];
    const status_item = &win_menu.icons.items[1];

    // 1. Mouse hover over "Guests": Active Help displays help text
    gui.handleMouseMove(win_menu.x + guests_item.rel_x + 15, win_menu.y + guests_item.rel_y + 15, false);
    gui.markFullDirty();
    _ = gui.renderDamaged(&surface);
    gui.cursor.draw(&surface);
    try writePpmFile(&surface, "/tmp/diosix_help_guests.ppm");

    // 2. Mouse hover over "Status": Active Help displays status help text
    gui.handleMouseMove(win_menu.x + status_item.rel_x + 15, win_menu.y + status_item.rel_y + 15, false);
    gui.markFullDirty();
    _ = gui.renderDamaged(&surface);
    gui.cursor.draw(&surface);
    try writePpmFile(&surface, "/tmp/diosix_help_status.ppm");

    // 3. Click Status to open Status pane (fallback view: unmocked environment renders clean '--' values)
    gui.handleMouseClick(win_menu.x + status_item.rel_x + 15, win_menu.y + status_item.rel_y + 15);
    gui.completeNavAnimation();
    gui.markFullDirty();
    _ = gui.renderDamaged(&surface);
    gui.cursor.draw(&surface);
    try writePpmFile(&surface, "/tmp/diosix_status_pane_fallback.ppm");

    // 4. Populate with live Hypervisor telemetry: table alignment and formatted values
    var mock_info = std.mem.zeroes(host_info.HypervisorInfo);
    mock_info.version_major = 26;
    mock_info.version_minor = 1;
    mock_info.host_physical_cores = 4;
    mock_info.host_total_ram_kb = 16 * 1024 * 1024; // 16 GB
    mock_info.host_free_ram_kb = 9 * 1024 * 1024;  // 9 GB free
    mock_info.hv_reserved_bytes = 16 * 1024 * 1024; // 16 MB reserved
    mock_info.hv_heap_free_bytes = 16580608;        // 15.8 MB free
    const isa_src = "RV64IMAFDC";
    @memcpy(mock_info.host_cpu_isa[0..isa_src.len], isa_src);
    const commit_src = "760a3d7";
    @memcpy(mock_info.build_commit[0..commit_src.len], commit_src);
    const desc_src = "Version 26.1 guestdev/760a3d7 Wed Sep 16 12:48:32 AM PDT 2026 chris@violet (Zig 0.17.0-dev.648+8d1b6e339 riscv64)";
    @memcpy(mock_info.build_desc[0..desc_src.len], desc_src);

    host_info.mock_hypervisor_info = mock_info;
    defer host_info.mock_hypervisor_info = null;

    gui.updateStatusPaneData();
    gui.markFullDirty();
    _ = gui.renderDamaged(&surface);
    gui.cursor.draw(&surface);
    try writePpmFile(&surface, "/tmp/diosix_status_pane.ppm");
    try writePpmFile(&surface, "/tmp/diosix_status_pane_table.ppm");

    // 5. Open Config pane and export visual verification screenshot
    try gui.activateMenuItem(gui_mod.ICON_MENU_CONFIG_ID);
    gui.completeNavAnimation();
    gui.markFullDirty();
    _ = gui.renderDamaged(&surface);
    try writePpmFile(&surface, "/tmp/diosix_config_pane.ppm");

    // 6. Open PIN Modal and export visual verification screenshot
    gui.lockConsole();
    try gui.openPinModal();
    gui.handlePinDigit('1');
    gui.handlePinDigit('2');
    gui.markFullDirty();
    _ = gui.renderDamaged(&surface);
    gui.cursor.draw(&surface);
    try writePpmFile(&surface, "/tmp/diosix_pin_modal.ppm");

    // 7. Complete unlocking and export unlocked view
    gui.handlePinDigit('3');
    gui.handlePinDigit('4');
    gui.handlePinSubmit();
    gui.markFullDirty();
    _ = gui.renderDamaged(&surface);
    gui.cursor.draw(&surface);
    try writePpmFile(&surface, "/tmp/diosix_console_unlocked.ppm");
}

test "diosix-gui: host_info hypervisor footprint format" {
    var mock_info = std.mem.zeroes(host_info.HypervisorInfo);
    mock_info.hv_reserved_bytes = 16 * 1024 * 1024;
    mock_info.hv_heap_free_bytes = 16580608;
    host_info.mock_hypervisor_info = mock_info;
    defer host_info.mock_hypervisor_info = null;

    var buf: [80]u8 = undefined;
    const str = host_info.getHvFootprintString(&buf);
    try testing.expectEqualStrings("15.8 MB free of 16 MB reserved (98% free)", str);
}

test "diosix-gui: config pane controls and dynamic appearance customization" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // 1. Open Config pane
    try gui.activateMenuItem(gui_mod.ICON_MENU_CONFIG_ID);
    gui.completeNavAnimation();
    const win_config = gui.getWindow(gui_mod.WIN_CONFIG_ID).?;
    try testing.expect(win_config.is_onscreen);
    try testing.expectEqual(gui_mod.WIN_MENU_ID, win_config.parent_window_id.?);
    try testing.expectEqual(gui_mod.ICON_MENU_CONFIG_ID, win_config.linked_menu_item_id.?);

    const win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    try testing.expectEqual(gui_mod.WIN_CONFIG_ID, win_menu.child_window_id.?);

    const icon_config_menu = win_menu.getIconById(gui_mod.ICON_MENU_CONFIG_ID).?;
    try testing.expect(icon_config_menu.is_selected);
    try testing.expect(gui.getWindow(gui_mod.WIN_BACK_ID) != null);
    try testing.expectEqual(gui_mod.MENU_CONTRACTED_H, win_menu.height);

    // 2. Adjust Transparency slider
    const trans_slider = win_config.getIconById(gui_mod.ICON_CONFIG_TRANSPARENCY_SLIDER_ID).?;
    try testing.expectEqual(@as(u32, 30), gui.window_transparency);
    try testing.expectEqual(@as(i32, 30), trans_slider.slider_val);

    // Adjust slider up by +10
    trans_slider.adjustSlider(10);
    if (trans_slider.callback) |cb| cb(&gui, win_config, trans_slider);
    try testing.expectEqual(@as(u32, 40), gui.window_transparency);
    try testing.expectEqual(@as(i32, 40), trans_slider.slider_val);

    // 3. Adjust Blur strength slider
    const blur_slider = win_config.getIconById(gui_mod.ICON_CONFIG_BLUR_SLIDER_ID).?;
    try testing.expectEqual(@as(u32, 50), gui.blur_strength);
    try testing.expectEqual(@as(i32, 50), blur_slider.slider_val);

    // Adjust slider down by -20
    blur_slider.adjustSlider(-20);
    if (blur_slider.callback) |cb| cb(&gui, win_config, blur_slider);
    try testing.expectEqual(@as(u32, 30), gui.blur_strength);
    try testing.expectEqual(@as(i32, 30), blur_slider.slider_val);
    try testing.expectEqual(@as(u32, 3), gui.getBlurRadius());

    // 4. Adjust Background Animation Speed slider (0% to 100%, default 50%)
    const speed_slider = win_config.getIconById(gui_mod.ICON_CONFIG_SPEED_SLIDER_ID).?;
    try testing.expectEqual(@as(u32, 50), gui.bg_animation_speed);
    try testing.expectEqual(@as(i32, 50), speed_slider.slider_val);

    // Adjust slider up by +25 -> 75%
    speed_slider.adjustSlider(25);
    if (speed_slider.callback) |cb| cb(&gui, win_config, speed_slider);
    try testing.expectEqual(@as(u32, 75), gui.bg_animation_speed);
    try testing.expectEqual(@as(i32, 75), speed_slider.slider_val);

    // Adjust slider down to 0% (stops animation movement)
    speed_slider.setSliderValue(0);
    if (speed_slider.callback) |cb| cb(&gui, win_config, speed_slider);
    try testing.expectEqual(@as(u32, 0), gui.bg_animation_speed);
    try testing.expectEqual(@as(i32, 0), speed_slider.slider_val);

    // 5. Test Theme buttons: Midnight, Sunset, Emerald, Day Sky
    const btn_midnight = win_config.getIconById(gui_mod.ICON_CONFIG_THEME_MIDNIGHT_ID).?;
    if (btn_midnight.callback) |cb| cb(&gui, win_config, btn_midnight);
    try testing.expectEqual(fb.Color.rgb(16, 24, 48), gui.bg_top_color);
    try testing.expectEqual(fb.Color.rgb(4, 6, 16), gui.bg_bot_color);

    const btn_sunset = win_config.getIconById(gui_mod.ICON_CONFIG_THEME_SUNSET_ID).?;
    if (btn_sunset.callback) |cb| cb(&gui, win_config, btn_sunset);
    try testing.expectEqual(fb.Color.rgb(180, 70, 60), gui.bg_top_color);
    try testing.expectEqual(fb.Color.rgb(40, 20, 50), gui.bg_bot_color);

    const btn_emerald = win_config.getIconById(gui_mod.ICON_CONFIG_THEME_EMERALD_ID).?;
    if (btn_emerald.callback) |cb| cb(&gui, win_config, btn_emerald);
    try testing.expectEqual(fb.Color.rgb(32, 120, 90), gui.bg_top_color);
    try testing.expectEqual(fb.Color.rgb(10, 36, 30), gui.bg_bot_color);

    const btn_day = win_config.getIconById(gui_mod.ICON_CONFIG_THEME_DAY_ID).?;
    if (btn_day.callback) |cb| cb(&gui, win_config, btn_day);
    try testing.expectEqual(fb.Color.SKY_BASE_TOP, gui.bg_top_color);
    try testing.expectEqual(fb.Color.GRADIENT_BOT_DEFAULT, gui.bg_bot_color);
}

test "diosix-gui: linked list pane architecture and switching between panes" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    const icon_status = win_menu.getIconById(gui_mod.ICON_MENU_STATUS_ID).?;
    const icon_config = win_menu.getIconById(gui_mod.ICON_MENU_CONFIG_ID).?;

    // 1. Initially no child panes and full menu
    try testing.expect(win_menu.child_window_id == null);
    try testing.expect(!icon_status.is_selected);
    try testing.expect(!icon_config.is_selected);
    try testing.expect(gui.getWindow(gui_mod.WIN_BACK_ID) == null);
    try testing.expectEqual(gui_mod.MENU_FULL_H, win_menu.height);

    // 2. Open Status pane: menu rolls up to show just Status, Back pane appears, Status pane appears
    try gui.activateMenuItem(gui_mod.ICON_MENU_STATUS_ID);
    gui.completeNavAnimation();
    try testing.expectEqual(gui_mod.WIN_STATUS_ID, win_menu.child_window_id.?);
    try testing.expect(gui.getWindow(gui_mod.WIN_STATUS_ID) != null);
    try testing.expect(gui.getWindow(gui_mod.WIN_BACK_ID) != null);
    try testing.expectEqual(gui_mod.MENU_CONTRACTED_H, win_menu.height);
    const win_status_item = win_menu.getIconById(gui_mod.ICON_MENU_STATUS_ID).?;
    try testing.expect(win_status_item.is_selected);

    // 3. Switch to Config pane: Status is torn down, Config is opened
    try gui.activateMenuItem(gui_mod.ICON_MENU_CONFIG_ID);
    gui.completeNavAnimation();
    try testing.expect(gui.getWindow(gui_mod.WIN_STATUS_ID) == null);
    try testing.expect(gui.getWindow(gui_mod.WIN_CONFIG_ID) != null);
    try testing.expectEqual(gui_mod.WIN_CONFIG_ID, win_menu.child_window_id.?);
    try testing.expect(gui.getWindow(gui_mod.WIN_BACK_ID) != null);
    try testing.expectEqual(gui_mod.MENU_CONTRACTED_H, win_menu.height);
    const win_config_item = win_menu.getIconById(gui_mod.ICON_MENU_CONFIG_ID).?;
    try testing.expect(win_config_item.is_selected);

    // 4. Clicking Back button restores full main menu and repopulates
    const win_back = gui.getWindow(gui_mod.WIN_BACK_ID).?;
    const back_btn = win_back.getIconById(gui_mod.ICON_BACK_BTN_ID).?;
    gui.handleMouseClick(win_back.x + back_btn.rel_x + 5, win_back.y + back_btn.rel_y + 5);
    gui.completeNavAnimation();
    try testing.expect(gui.getWindow(gui_mod.WIN_CONFIG_ID) == null);
    try testing.expect(gui.getWindow(gui_mod.WIN_BACK_ID) == null);
    try testing.expect(win_menu.child_window_id == null);
    try testing.expectEqual(gui_mod.MENU_FULL_H, win_menu.height);
    try testing.expectEqual(@as(usize, 3), win_menu.icons.items.len);
}

test "diosix-gui: 3-tier active help priority system" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const win_help = gui.getWindow(gui_mod.WIN_HELP_ID).?;
    const help_icon = win_help.getIconById(gui_mod.ICON_HELP_TEXT_ID).?;
    const win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    const item_guests = &win_menu.icons.items[0];

    // Priority 1: Cursor over icon with help text displays icon help text
    gui.handleMouseMove(win_menu.x + item_guests.rel_x + 5, win_menu.y + item_guests.rel_y + 5, false);
    try testing.expectEqualStrings("View and manage guest virtual machines", help_icon.getText());

    // Priority 2: Open Status pane. Text icons have no help text, but the pane itself has help text
    try gui.activateMenuItem(gui_mod.ICON_MENU_STATUS_ID);
    gui.completeNavAnimation();
    const win_status = gui.getWindow(gui_mod.WIN_STATUS_ID).?;

    // Cursor over Back button shows Back button help text
    const win_back = gui.getWindow(gui_mod.WIN_BACK_ID).?;
    const back_btn = win_back.getIconById(gui_mod.ICON_BACK_BTN_ID).?;
    gui.handleMouseMove(win_back.x + back_btn.rel_x + 5, win_back.y + back_btn.rel_y + 5, false);
    try testing.expectEqualStrings("Return to the main menu", help_icon.getText());

    // Cursor over status pane's "Uptime" label (icon has no help text) -> shows pane help text
    const lbl_uptime = win_status.getIconById(gui_mod.ICON_STATUS_HOST_UPTIME_LABEL_ID).?;
    gui.handleMouseMove(win_status.x + lbl_uptime.rel_x + 2, win_status.y + lbl_uptime.rel_y + 2, false);
    try testing.expectEqualStrings("Information about this host system and hypervisor", help_icon.getText());

    // Cursor over empty region of status pane (no icon under cursor) -> shows pane help text
    gui.handleMouseMove(win_status.x + 10, win_status.y + 10, false);
    try testing.expectEqualStrings("Information about this host system and hypervisor", help_icon.getText());

    // Priority 3: Cursor over empty desktop (no window, no icon) -> shows fallback text
    gui.handleMouseMove(500, 500, false);
    try testing.expectEqualStrings("Welcome to diosix", help_icon.getText());
}

test "diosix-gui: menu roll-up animation, pane slide-in, and back button repopulation" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const pixel_mem = try allocator.alloc(u32, 1280 * 800);
    defer allocator.free(pixel_mem);
    var surface = fb.Surface.init(pixel_mem.ptr, 1280, 800, 1280 * @sizeOf(u32));

    const win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    try testing.expectEqual(gui_mod.MENU_FULL_H, win_menu.height);
    try testing.expectEqual(gui_mod.NavAnimState.idle, gui.nav_anim_state);

    // 1. Activate Status menu item initiates opening animation
    try gui.activateMenuItem(gui_mod.ICON_MENU_STATUS_ID);
    try testing.expectEqual(gui_mod.NavAnimState.opening, gui.nav_anim_state);
    try testing.expect(gui.hasActiveAnimation());

    // 2. Tick 100ms: intermediate animation frame
    gui.tick(100);
    try testing.expectEqual(gui_mod.NavAnimState.opening, gui.nav_anim_state);
    try testing.expect(gui.nav_anim_progress > 0.0 and gui.nav_anim_progress < 1.0);
    try testing.expect(win_menu.height < gui_mod.MENU_FULL_H and win_menu.height > gui_mod.MENU_CONTRACTED_H);

    const win_back = gui.getWindow(gui_mod.WIN_BACK_ID).?;
    try testing.expect(win_back.x < gui_mod.BORDER_GAP); // sliding in from left

    const win_status = gui.getWindow(gui_mod.WIN_STATUS_ID).?;
    try testing.expect(win_status.x > gui.getChildTargetX()); // sliding in from right

    gui.markFullDirty();
    _ = gui.renderDamaged(&surface);
    try writePpmFile(&surface, "/tmp/diosix_menu_anim_midway.ppm");

    // 3. Tick 150ms: animation completes
    gui.tick(150);
    try testing.expectEqual(gui_mod.NavAnimState.idle, gui.nav_anim_state);
    try testing.expectEqual(gui_mod.MENU_CONTRACTED_H, win_menu.height);
    try testing.expectEqual(gui_mod.BORDER_GAP, win_back.x);
    try testing.expectEqual(gui.getChildTargetX(), win_status.x);

    // 4. Click Back button initiates closing animation
    const back_btn = win_back.getIconById(gui_mod.ICON_BACK_BTN_ID).?;
    gui.handleMouseClick(win_back.x + back_btn.rel_x + 5, win_back.y + back_btn.rel_y + 5);
    try testing.expectEqual(gui_mod.NavAnimState.closing, gui.nav_anim_state);
    try testing.expect(gui.hasActiveAnimation());

    // 5. Tick 100ms: intermediate closing frame
    gui.tick(100);
    try testing.expectEqual(gui_mod.NavAnimState.closing, gui.nav_anim_state);
    try testing.expect(win_menu.height > gui_mod.MENU_CONTRACTED_H and win_menu.height < gui_mod.MENU_FULL_H);
    try testing.expect(win_back.x < gui_mod.BORDER_GAP); // sliding back to left
    try testing.expect(win_status.x > gui.getChildTargetX()); // sliding back to right

    // 6. Tick 150ms: closing completes, repopulating full menu
    gui.tick(150);
    try testing.expectEqual(gui_mod.NavAnimState.idle, gui.nav_anim_state);
    try testing.expectEqual(gui_mod.MENU_FULL_H, win_menu.height);
    try testing.expect(gui.getWindow(gui_mod.WIN_BACK_ID) == null);
    try testing.expect(gui.getWindow(gui_mod.WIN_STATUS_ID) == null);
    try testing.expectEqual(@as(usize, 3), win_menu.icons.items.len);
}

test "diosix-gui: back menu item undecorated styling, elegant arrow, and navigation" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // 1. Activate Status menu item
    try gui.activateMenuItem(gui_mod.ICON_MENU_STATUS_ID);
    gui.completeNavAnimation();

    // 2. Verify WIN_BACK_ID contains an undecorated menu_item with has_back_arrow set
    const win_back = gui.getWindow(gui_mod.WIN_BACK_ID).?;
    try testing.expectEqual(gui_mod.BACK_PANE_H, win_back.height);
    try testing.expectEqual(gui_mod.MENU_CONTRACTED_H, win_back.height);

    const back_item = win_back.getIconById(gui_mod.ICON_BACK_BTN_ID).?;
    try testing.expectEqual(icon_mod.IconType.menu_item, back_item.icon_type);
    try testing.expect(back_item.has_back_arrow);
    try testing.expectEqualStrings("Back", back_item.getText());

    // 3. Hovering over back menu item sets is_hovered
    gui.handleMouseMove(win_back.x + back_item.rel_x + 5, win_back.y + back_item.rel_y + 5, false);
    try testing.expect(back_item.is_hovered);

    // 4. Clicking triggers back navigation
    gui.handleMouseClick(win_back.x + back_item.rel_x + 5, win_back.y + back_item.rel_y + 5);
    gui.completeNavAnimation();
    try testing.expect(gui.getWindow(gui_mod.WIN_BACK_ID) == null);
    try testing.expectEqual(gui_mod.MENU_FULL_H, gui.getWindow(gui_mod.WIN_MENU_ID).?.height);
}

test "diosix-gui: slider drag exclusivity prevents multiple sliders from moving simultaneously" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // 1. Open Config pane
    try gui.activateMenuItem(gui_mod.ICON_MENU_CONFIG_ID);
    gui.completeNavAnimation();

    const win_config = gui.getWindow(gui_mod.WIN_CONFIG_ID).?;
    const trans_slider = win_config.getIconById(gui_mod.ICON_CONFIG_TRANSPARENCY_SLIDER_ID).?;
    const blur_slider = win_config.getIconById(gui_mod.ICON_CONFIG_BLUR_SLIDER_ID).?;

    // Initial state: transparency slider at 30% (default), blur slider at 50%
    try testing.expectEqual(@as(i32, 30), trans_slider.slider_val);
    try testing.expectEqual(@as(i32, 50), blur_slider.slider_val);

    // 2. Click on the Blur slider track
    const blur_click_x = win_config.x + blur_slider.rel_x + 180;
    const blur_click_y = win_config.y + blur_slider.rel_y + 14;
    gui.handleMouseClick(blur_click_x, blur_click_y);

    // Blur slider updated, but Transparency slider must remain unchanged at 30
    const blur_val_after_click = blur_slider.slider_val;
    try testing.expect(blur_val_after_click != 50);
    try testing.expectEqual(@as(i32, 30), trans_slider.slider_val);
    try testing.expect(blur_slider.is_dragging_slider);
    try testing.expect(!trans_slider.is_dragging_slider);

    // 3. Drag mouse vertically UP into Transparency slider coordinates while holding left button down
    const trans_y = win_config.y + trans_slider.rel_y + 14;
    const drag_x = win_config.x + blur_slider.rel_x + 50; // Drag towards left
    gui.handleMouseMove(drag_x, trans_y, true);

    // ONLY Blur slider should update; Transparency slider MUST NOT MOVE!
    try testing.expect(blur_slider.slider_val < blur_val_after_click);
    try testing.expectEqual(@as(i32, 30), trans_slider.slider_val);
    try testing.expect(blur_slider.is_hovered);
    try testing.expect(!trans_slider.is_hovered);

    // 4. Release mouse button: ends drag
    gui.handleMouseRelease();
    try testing.expect(!blur_slider.is_dragging_slider);
    try testing.expectEqual(@as(?usize, null), win_config.active_drag_icon_idx);
    try testing.expectEqual(@as(?u32, null), gui.active_drag_win_id);
    try testing.expectEqual(@as(i32, 30), trans_slider.slider_val);
}

test "diosix-gui: touch-first single-icon and single-window hit exclusivity" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // 1. Verify main menu items: touching/clicking the Status menu item exclusively selects it
    const win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    const status_item = win_menu.getIconById(gui_mod.ICON_MENU_STATUS_ID).?;
    const config_item = win_menu.getIconById(gui_mod.ICON_MENU_CONFIG_ID).?;

    // Touch coordinate on Status menu item
    const touch_x = win_menu.x + status_item.rel_x + 20;
    const touch_y = win_menu.y + status_item.rel_y + 10;

    // Hover check
    gui.handleMouseMove(touch_x, touch_y, false);
    try testing.expect(status_item.is_hovered);
    try testing.expect(!config_item.is_hovered);

    // Touch down / click check
    gui.handleMouseClick(touch_x, touch_y);
    gui.completeNavAnimation();

    // Now Status pane is open. Switch to Config pane to test multiple controls
    try gui.activateMenuItem(gui_mod.ICON_MENU_CONFIG_ID);
    gui.completeNavAnimation();

    const win_config = gui.getWindow(gui_mod.WIN_CONFIG_ID).?;
    const trans_slider = win_config.getIconById(gui_mod.ICON_CONFIG_TRANSPARENCY_SLIDER_ID).?;
    const blur_slider = win_config.getIconById(gui_mod.ICON_CONFIG_BLUR_SLIDER_ID).?;

    // Touch on transparency slider
    const trans_touch_x = win_config.x + trans_slider.rel_x + 100;
    const trans_touch_y = win_config.y + trans_slider.rel_y + 14;
    gui.handleMouseClick(trans_touch_x, trans_touch_y);

    // Only transparency slider is captured; blur slider is untouched
    try testing.expect(trans_slider.is_dragging_slider);
    try testing.expect(!blur_slider.is_dragging_slider);
    try testing.expect(win_config.active_drag_icon_idx != null);
    try testing.expectEqual(gui_mod.ICON_CONFIG_TRANSPARENCY_SLIDER_ID, win_config.icons.items[win_config.active_drag_icon_idx.?].id);

    gui.handleMouseRelease();
    try testing.expect(!trans_slider.is_dragging_slider);
    try testing.expect(!blur_slider.is_dragging_slider);
    try testing.expectEqual(@as(?usize, null), win_config.active_drag_icon_idx);
}

test "diosix-gui: background texture drift shifts in randomized/configured direction across ticks" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // Verify initial drift position, default 50% speed, and valid randomized direction
    try testing.expectEqual(@as(i32, 0), gui.drift_x);
    try testing.expectEqual(@as(i32, 0), gui.drift_y);
    try testing.expectEqual(@as(u32, 50), gui.getBgAnimationSpeed());
    const initial_dir = gui.getDriftDirection();
    try testing.expect(@intFromEnum(initial_dir) < 4);

    // 1. When speed is 0% (stopped), no movement occurs across ticks
    gui.setBgAnimationSpeed(0);
    gui.setDriftDirection(.left);
    gui.tick(gui_mod.DRIFT_INTERVAL_MS * 10);
    try testing.expectEqual(@as(i32, 0), gui.drift_x);
    try testing.expectEqual(@as(i32, 0), gui.drift_y);

    // 2. Test full speed (100%): 1 step per DRIFT_INTERVAL_MS (60ms)
    gui.setBgAnimationSpeed(100);
    // Left drift
    gui.setDriftDirection(.left);
    gui.tick(gui_mod.DRIFT_INTERVAL_MS);
    try testing.expectEqual(@as(i32, -1), gui.drift_x);
    try testing.expectEqual(@as(i32, 0), gui.drift_y);
    try testing.expect(gui.isDirty());

    // Right drift
    gui.setDriftDirection(.right);
    gui.tick(gui_mod.DRIFT_INTERVAL_MS * 2);
    try testing.expectEqual(@as(i32, 1), gui.drift_x);
    try testing.expectEqual(@as(i32, 0), gui.drift_y);

    // Up drift
    gui.setDriftDirection(.up);
    gui.tick(gui_mod.DRIFT_INTERVAL_MS);
    try testing.expectEqual(@as(i32, 1), gui.drift_x);
    try testing.expectEqual(@as(i32, -1), gui.drift_y);

    // Down drift
    gui.setDriftDirection(.down);
    gui.tick(gui_mod.DRIFT_INTERVAL_MS * 2);
    try testing.expectEqual(@as(i32, 1), gui.drift_x);
    try testing.expectEqual(@as(i32, 1), gui.drift_y);

    // 3. Test half speed (default 50%): takes 2x interval (120ms) for 1 step
    gui.setBgAnimationSpeed(50);
    gui.setDriftDirection(.right);
    gui.tick(gui_mod.DRIFT_INTERVAL_MS); // 60ms * 50% = half threshold -> no step yet
    try testing.expectEqual(@as(i32, 1), gui.drift_x);
    gui.tick(gui_mod.DRIFT_INTERVAL_MS); // Another 60ms * 50% -> threshold reached, +1 step
    try testing.expectEqual(@as(i32, 2), gui.drift_x);
}

test "diosix-gui: input scaling and evdev absinfo calibration" {
    // 1. Calibration with standard 0..4095 touchscreen
    const touch_dev = InputDeviceInfo{
        .fd = 0,
        .min_x = 0,
        .max_x = 4095,
        .min_y = 0,
        .max_y = 4095,
        .has_abs = true,
    };
    try testing.expectEqual(@as(i32, 0), touch_dev.scaleX(0, 1920));
    try testing.expectEqual(@as(i32, 1919), touch_dev.scaleX(4095, 1920));
    try testing.expectEqual(@as(i32, 960), touch_dev.scaleX(2048, 1920));
    try testing.expectEqual(@as(i32, 0), touch_dev.scaleY(0, 1080));
    try testing.expectEqual(@as(i32, 1079), touch_dev.scaleY(4095, 1080));

    // 2. Calibration with standard tablet 0..32767
    const tablet_dev = InputDeviceInfo{
        .fd = 1,
        .min_x = 0,
        .max_x = 32767,
        .min_y = 0,
        .max_y = 32767,
        .has_abs = true,
    };
    try testing.expectEqual(@as(i32, 0), tablet_dev.scaleX(0, 1280));
    try testing.expectEqual(@as(i32, 1279), tablet_dev.scaleX(32767, 1280));
    try testing.expectEqual(@as(i32, 640), tablet_dev.scaleX(16384, 1280));

    // 3. Out-of-bounds input clamping
    try testing.expectEqual(@as(i32, 0), touch_dev.scaleX(-500, 1920));
    try testing.expectEqual(@as(i32, 1919), touch_dev.scaleX(10000, 1920));
    try testing.expectEqual(@as(i32, 0), touch_dev.scaleY(-100, 1080));
    try testing.expectEqual(@as(i32, 1079), touch_dev.scaleY(99999, 1080));

    // 4. Zero span fallback protection (prevents division by zero)
    const zero_span = InputDeviceInfo{ .fd = 2, .min_x = 100, .max_x = 100, .min_y = 0, .max_y = 0 };
    try testing.expectEqual(@as(i32, 0), zero_span.scaleX(50, 1920));
    try testing.expectEqual(@as(i32, 0), zero_span.scaleY(50, 1080));
}

test "diosix-gui: privilege modes, auth states, and security badges" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // 1. Root console mode
    gui.privilege_mode = .root_console;
    gui.auth_state = .locked;
    try testing.expectEqualStrings("[Root: Locked]", gui.getSecurityBadge());
    try testing.expect(!gui.isConsoleUnlocked());

    gui.auth_state = .unlocked;
    try testing.expectEqualStrings("[Root: Unlocked]", gui.getSecurityBadge());
    try testing.expect(gui.isConsoleUnlocked());

    // 2. Guest diagnostic mode
    gui.privilege_mode = .guest_diagnostic;
    gui.auth_state = .locked;
    try testing.expectEqualStrings("[Guest: Diagnostic]", gui.getSecurityBadge());
    try testing.expect(!gui.isConsoleUnlocked());

    gui.auth_state = .unlocked;
    try testing.expectEqualStrings("[Guest: Diagnostic]", gui.getSecurityBadge());
    // Guest diagnostic mode is always unprivileged (isConsoleUnlocked() is false)
    try testing.expect(!gui.isConsoleUnlocked());
}

test "diosix-gui: touch PIN authentication modal lifecycle, PIN verification, and secure memory zeroing" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // Set Root Console mode, Locked
    gui.privilege_mode = .root_console;
    gui.lockConsole();
    try testing.expectEqual(gui_mod.AuthState.locked, gui.auth_state);
    try testing.expectEqualStrings("[Root: Locked]", gui.getSecurityBadge());

    // 1. Tapping/Activating Guests menu item while locked opens PIN modal
    try gui.activateMenuItem(gui_mod.ICON_MENU_GUESTS_ID);
    const win_pin = gui.getWindow(gui_mod.WIN_PIN_MODAL_ID);
    try testing.expect(win_pin != null);
    try testing.expect(win_pin.?.is_onscreen);
    try testing.expect(gui.active_win_idx != null);
    try testing.expectEqual(gui_mod.WIN_PIN_MODAL_ID, gui.windows.items[gui.active_win_idx.?].id);

    // Verify initial masked display
    const pin_disp = win_pin.?.getIconById(gui_mod.ICON_PIN_DISPLAY_ID).?;
    try testing.expectEqualStrings("_ _ _ _", pin_disp.getText());

    // 2. Enter digits via touch buttons: '9', '9', '9', '9'
    const btn_k9 = win_pin.?.getIconById(gui_mod.ICON_PIN_KEY_BASE_ID + 9).?;
    const k9_x = win_pin.?.x + btn_k9.rel_x + 10;
    const k9_y = win_pin.?.y + btn_k9.rel_y + 10;

    gui.handleMouseClick(k9_x, k9_y);
    gui.handleMouseRelease();
    try testing.expectEqualStrings("*", pin_disp.getText());

    gui.handleMouseClick(k9_x, k9_y);
    gui.handleMouseRelease();
    try testing.expectEqualStrings("* *", pin_disp.getText());

    // Test Clear button
    const btn_clear = win_pin.?.getIconById(gui_mod.ICON_PIN_CLEAR_ID).?;
    gui.handleMouseClick(win_pin.?.x + btn_clear.rel_x + 10, win_pin.?.y + btn_clear.rel_y + 10);
    gui.handleMouseRelease();
    try testing.expectEqualStrings("_ _ _ _", pin_disp.getText());
    try testing.expectEqual(@as(usize, 0), gui.pin_len);

    // 3. Test Incorrect PIN submission: '9', '9', '9', '9' + Enter
    gui.handleMouseClick(k9_x, k9_y);
    gui.handleMouseRelease();
    gui.handleMouseClick(k9_x, k9_y);
    gui.handleMouseRelease();
    gui.handleMouseClick(k9_x, k9_y);
    gui.handleMouseRelease();
    gui.handleMouseClick(k9_x, k9_y);
    gui.handleMouseRelease();
    try testing.expectEqualStrings("* * * *", pin_disp.getText());

    const btn_submit = win_pin.?.getIconById(gui_mod.ICON_PIN_SUBMIT_ID).?;
    gui.handleMouseClick(win_pin.?.x + btn_submit.rel_x + 10, win_pin.?.y + btn_submit.rel_y + 10);
    gui.handleMouseRelease();

    // Verification failed: console remains locked, status icon shows error, pin memory zeroed
    try testing.expectEqual(gui_mod.AuthState.locked, gui.auth_state);
    try testing.expect(gui.getWindow(gui_mod.WIN_PIN_MODAL_ID) != null);
    const pin_status = win_pin.?.getIconById(gui_mod.ICON_PIN_STATUS_ID).?;
    try testing.expectEqualStrings("Invalid PIN. Try again.", pin_status.getText());
    try testing.expectEqual(@as(usize, 0), gui.pin_len);
    for (gui.pin_buf) |b| {
        try testing.expectEqual(@as(u8, 0), b);
    }

    // 4. Test Correct PIN submission: '1', '2', '3', '4' + Enter
    const btn_k1 = win_pin.?.getIconById(gui_mod.ICON_PIN_KEY_BASE_ID + 1).?;
    const btn_k2 = win_pin.?.getIconById(gui_mod.ICON_PIN_KEY_BASE_ID + 2).?;
    const btn_k3 = win_pin.?.getIconById(gui_mod.ICON_PIN_KEY_BASE_ID + 3).?;
    const btn_k4 = win_pin.?.getIconById(gui_mod.ICON_PIN_KEY_BASE_ID + 4).?;

    gui.handleMouseClick(win_pin.?.x + btn_k1.rel_x + 10, win_pin.?.y + btn_k1.rel_y + 10);
    gui.handleMouseRelease();
    gui.handleMouseClick(win_pin.?.x + btn_k2.rel_x + 10, win_pin.?.y + btn_k2.rel_y + 10);
    gui.handleMouseRelease();
    gui.handleMouseClick(win_pin.?.x + btn_k3.rel_x + 10, win_pin.?.y + btn_k3.rel_y + 10);
    gui.handleMouseRelease();
    gui.handleMouseClick(win_pin.?.x + btn_k4.rel_x + 10, win_pin.?.y + btn_k4.rel_y + 10);
    gui.handleMouseRelease();
    try testing.expectEqualStrings("* * * *", pin_disp.getText());

    gui.handleMouseClick(win_pin.?.x + btn_submit.rel_x + 10, win_pin.?.y + btn_submit.rel_y + 10);
    gui.handleMouseRelease();

    // Success: console unlocked, modal closed, pin_buf securely zeroed
    try testing.expectEqual(gui_mod.AuthState.unlocked, gui.auth_state);
    try testing.expect(gui.getWindow(gui_mod.WIN_PIN_MODAL_ID) == null);
    try testing.expectEqual(@as(usize, 0), gui.pin_len);
    for (gui.pin_buf) |b| {
        try testing.expectEqual(@as(u8, 0), b);
    }
    try testing.expectEqualStrings("[Root: Unlocked]", gui.getSecurityBadge());

    // 5. While unlocked, tapping Guests opens Guests pane without PIN prompt
    try gui.activateMenuItem(gui_mod.ICON_MENU_GUESTS_ID);
    try testing.expect(gui.getWindow(gui_mod.WIN_PIN_MODAL_ID) == null);

    // 6. Test Re-Locking: Open Config pane, click "Lock Console"
    try gui.activateMenuItem(gui_mod.ICON_MENU_CONFIG_ID);
    gui.completeNavAnimation();

    const win_cfg = gui.getWindow(gui_mod.WIN_CONFIG_ID).?;
    const lock_btn = win_cfg.getIconById(gui_mod.ICON_CONFIG_ADMIN_BTN_ID).?;
    try testing.expectEqualStrings("Lock Console", lock_btn.getText());

    gui.handleMouseClick(win_cfg.x + lock_btn.rel_x + 10, win_cfg.y + lock_btn.rel_y + 10);
    gui.handleMouseRelease();

    // Console is locked again
    try testing.expectEqual(gui_mod.AuthState.locked, gui.auth_state);
    try testing.expectEqualStrings("[Root: Locked]", gui.getSecurityBadge());
    try testing.expectEqualStrings("Admin Unlock", lock_btn.getText());

    // 7. Clicking "Unlock Console" opens PIN modal again, and Cancel ('X') closes and zeroes memory
    gui.handleMouseClick(win_cfg.x + lock_btn.rel_x + 10, win_cfg.y + lock_btn.rel_y + 10);
    gui.handleMouseRelease();

    const win_pin2 = gui.getWindow(gui_mod.WIN_PIN_MODAL_ID).?;
    gui.handlePinDigit('5');
    try testing.expectEqual(@as(usize, 1), gui.pin_len);

    const btn_cancel = win_pin2.getIconById(gui_mod.ICON_PIN_CANCEL_ID).?;
    gui.handleMouseClick(win_pin2.x + btn_cancel.rel_x + 10, win_pin2.y + btn_cancel.rel_y + 10);
    gui.handleMouseRelease();

    try testing.expect(gui.getWindow(gui_mod.WIN_PIN_MODAL_ID) == null);
    try testing.expectEqual(@as(usize, 0), gui.pin_len);
    for (gui.pin_buf) |b| {
        try testing.expectEqual(@as(u8, 0), b);
    }
}
