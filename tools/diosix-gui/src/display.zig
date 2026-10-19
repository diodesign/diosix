// Display Scanout and Evdev Input Handling for Diosix Monolithic GUI.
// Final Fantasy 7 & 8 Inspired BIOS/UEFI Menu Environment.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const fb = @import("framebuffer.zig");
const drm = @import("drm.zig");
const gui_mod = @import("gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const intro_mod = @import("intro.zig");

pub const MS_PER_SEC: i64 = 1000;
pub const NS_PER_MS: i64 = 1_000_000;
pub const TARGET_FPS: i64 = 60;
pub const FRAME_INTERVAL_MS: i64 = MS_PER_SEC / TARGET_FPS; // 16 ms (~60 FPS).
pub const POLL_TIMEOUT_MS: i32 = @intCast(FRAME_INTERVAL_MS);
pub const MAX_INPUT_DEVICES: usize = 32;

pub fn getMilliTimestamp() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    const sec_ms = @as(i64, @intCast(ts.sec)) * MS_PER_SEC;
    const nsec_ms = @divTrunc(@as(i64, @intCast(ts.nsec)), NS_PER_MS);
    return sec_ms + nsec_ms;
}

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
        // Try DRM/KMS first (e.g. VirtIO-GPU).
        const dri_paths = [_][]const u8{ "/dev/dri/card0", "/dev/dri/card1" };
        for (dri_paths) |card_path| {
            if (drm.DrmDevice.init(card_path)) |init_dev| {
                var dev = init_dev;
                errdefer dev.deinit();
                const stride_pixels = dev.pitch / @sizeOf(u32);
                const buffer_pixels = stride_pixels * dev.height;
                const bb_mem = try allocator.alloc(u32, buffer_pixels);
                errdefer allocator.free(bb_mem);
                const cb_mem = try allocator.alloc(u32, buffer_pixels);
                const w = dev.width;
                const h = dev.height;
                const pitch = dev.pitch;
                return Display{
                    .width = w,
                    .height = h,
                    .stride = pitch,
                    .fb_ptr = dev.screen_surface.pixels,
                    .drm_dev = dev,
                    .fb_fd = -1,
                    .backbuffer = fb.Surface.init(bb_mem.ptr, w, h, pitch),
                    .backbuffer_mem = bb_mem,
                    .clean_buffer = fb.Surface.init(cb_mem.ptr, w, h, pitch),
                    .clean_buffer_mem = cb_mem,
                };
            } else |err| {
                if (err == error.AccessDenied) had_access_denied = true;
            }
        }

        // Fallback to legacy /dev/fb0.
        const fb_path = "/dev/fb0";
        const fd_rc = linux.open(fb_path, .{ .ACCMODE = .RDWR }, 0);
        const signed_fd: isize = @bitCast(fd_rc);
        if (signed_fd >= 0) {
            const fd: i32 = @intCast(signed_fd);
            errdefer _ = linux.close(fd);
            const w: u32 = drm.PREFERRED_WIDTH;
            const h: u32 = drm.PREFERRED_HEIGHT;
            const stride: usize = w * @sizeOf(u32);
            const map_size = stride * h;

            const prot = linux.PROT{ .READ = true, .WRITE = true };
            const flags = linux.MAP{ .TYPE = .SHARED };
            const map_res = linux.mmap(null, map_size, prot, flags, fd, 0);
            const signed_map: isize = @bitCast(map_res);
            if (signed_map >= 0) {
                const pixels: [*]u32 = @ptrFromInt(map_res);
                errdefer _ = linux.munmap(@ptrCast(pixels), map_size);
                const bb_mem = try allocator.alloc(u32, w * h);
                errdefer allocator.free(bb_mem);
                const cb_mem = try allocator.alloc(u32, w * h);
                const st_u32: u32 = @intCast(stride);
                return Display{
                    .width = w,
                    .height = h,
                    .stride = stride,
                    .fb_ptr = pixels,
                    .drm_dev = null,
                    .fb_fd = fd,
                    .backbuffer = fb.Surface.init(bb_mem.ptr, w, h, st_u32),
                    .backbuffer_mem = bb_mem,
                    .clean_buffer = fb.Surface.init(cb_mem.ptr, w, h, st_u32),
                    .clean_buffer_mem = cb_mem,
                };
            }
            _ = linux.close(fd);
        } else {
            const eacces = -@as(isize, @backingInt(linux.E.ACCES));
            if (signed_fd == eacces) had_access_denied = true;
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
        return fb.Surface.init(
            self.fb_ptr,
            self.width,
            self.height,
            @intCast(self.stride),
        );
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
        const max_fb = (self.stride * self.height) / @sizeOf(u32);
        const max_len = @min(self.backbuffer_mem.len, max_fb);

        while (y < end_y) : (y += 1) {
            const row_start = std.math.mul(usize, y, stride_pixels) catch break;
            const row_offset = std.math.add(usize, row_start, ux0) catch break;
            const row_end = std.math.add(usize, row_offset, w) catch break;
            if (row_end > max_len) break;
            @memcpy(
                self.fb_ptr[row_offset..row_end],
                self.backbuffer_mem[row_offset..row_end],
            );
        }

        if (self.drm_dev) |*d| {
            d.dirtyFb(damage);
        }
    }

    pub fn flush(self: *Display) void {
        self.flushDamage(fb.Box.fromPosSize(0, 0, self.width, self.height));
    }
};

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

pub const BTN_LEFT: u16 = 0x110;
pub const BTN_RIGHT: u16 = 0x111;
pub const BTN_MIDDLE: u16 = 0x112;
pub const BTN_TOUCH: u16 = 0x14a;

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
        const w_i64: i64 = @intCast(screen_w);
        const res = @divTrunc(rel * w_i64, @as(i64, span));
        const max_coord: i32 = @intCast(screen_w - 1);
        return std.math.clamp(@as(i32, @intCast(res)), 0, max_coord);
    }

    pub fn scaleY(self: *const InputDeviceInfo, raw_y: i32, screen_h: u32) i32 {
        const span = self.max_y - self.min_y;
        if (span <= 0) return 0;
        const clamped_raw = std.math.clamp(raw_y, self.min_y, self.max_y);
        const rel: i64 = @as(i64, clamped_raw - self.min_y);
        const h_i64: i64 = @intCast(screen_h);
        const res = @divTrunc(rel * h_i64, @as(i64, span));
        const max_coord: i32 = @intCast(screen_h - 1);
        return std.math.clamp(@as(i32, @intCast(res)), 0, max_coord);
    }
};

fn queryAxis(ifd: i32, a: u32, b: u32, min_p: *i32, max_p: *i32) bool {
    var info = input_absinfo{};
    const ptr = @intFromPtr(&info);
    if (@as(isize, @bitCast(linux.ioctl(ifd, EVIOCGABS(a), ptr))) >= 0 and
        info.maximum > info.minimum)
    {
        min_p.* = info.minimum;
        max_p.* = info.maximum;
        return true;
    }
    if (@as(isize, @bitCast(linux.ioctl(ifd, EVIOCGABS(b), ptr))) >= 0 and
        info.maximum > info.minimum)
    {
        min_p.* = info.minimum;
        max_p.* = info.maximum;
        return true;
    }
    return false;
}

pub fn openInputDevices(
    input_devs: *[MAX_INPUT_DEVICES]InputDeviceInfo,
    had_eacces: *bool,
) usize {
    var input_count: usize = 0;
    var dev_idx: u8 = 0;
    had_eacces.* = false;

    while (dev_idx < MAX_INPUT_DEVICES) : (dev_idx += 1) {
        var path_buf: [32]u8 = undefined;
        const p_slice = std.fmt.bufPrint(
            &path_buf,
            "/dev/input/event{d}",
            .{dev_idx},
        ) catch continue;
        path_buf[p_slice.len] = 0;
        const dev_z: [*:0]const u8 = @ptrCast(path_buf[0..p_slice.len :0]);
        const flags = linux.O{ .ACCMODE = .RDONLY, .NONBLOCK = true };
        const rc = linux.open(dev_z, flags, 0);
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc >= 0) {
            const ifd: i32 = @intCast(signed_rc);
            var d = InputDeviceInfo{ .fd = ifd };
            if (queryAxis(ifd, ABS_X, ABS_MT_POSITION_X, &d.min_x, &d.max_x)) {
                d.has_abs = true;
            }
            if (queryAxis(ifd, ABS_Y, ABS_MT_POSITION_Y, &d.min_y, &d.max_y)) {
                d.has_abs = true;
            }
            input_devs[input_count] = d;
            input_count += 1;
        } else {
            const eacces = -@as(isize, @backingInt(linux.E.ACCES));
            if (signed_rc == eacces) had_eacces.* = true;
        }
    }
    return input_count;
}

pub fn closeInputDevices(devs: []const InputDeviceInfo) void {
    for (devs) |d| {
        if (d.fd >= 0) _ = linux.close(d.fd);
    }
}

pub fn fillPollFds(
    devs: []const InputDeviceInfo,
    pfds: *[MAX_INPUT_DEVICES]linux.pollfd,
) void {
    for (devs, 0..) |idev, i| {
        pfds[i] = linux.pollfd{
            .fd = idev.fd,
            .events = linux.POLL.IN,
            .revents = 0,
        };
    }
}

pub fn applyMotionEvent(
    ev: InputEvent,
    dev_info: *const InputDeviceInfo,
    screen_w: u32,
    screen_h: u32,
    pending_x: *i32,
    pending_y: *i32,
    coords_changed: *bool,
) void {
    const max_x: i32 = @intCast(screen_w - 1);
    const max_y: i32 = @intCast(screen_h - 1);
    switch (ev.type) {
        EV_REL => {
            if (ev.code == REL_X) {
                pending_x.* = std.math.clamp(pending_x.* + ev.value, 0, max_x);
                coords_changed.* = true;
            } else if (ev.code == REL_Y) {
                pending_y.* = std.math.clamp(pending_y.* + ev.value, 0, max_y);
                coords_changed.* = true;
            }
        },
        EV_ABS => {
            if (ev.code == ABS_X or ev.code == ABS_MT_POSITION_X) {
                pending_x.* = dev_info.scaleX(ev.value, screen_w);
                coords_changed.* = true;
            } else if (ev.code == ABS_Y or ev.code == ABS_MT_POSITION_Y) {
                pending_y.* = dev_info.scaleY(ev.value, screen_h);
                coords_changed.* = true;
            }
        },
        else => {},
    }
}

pub fn pollIntroInput(
    devs: []const InputDeviceInfo,
    display: *Display,
    gui: *DiosixGui,
    intro_state: *intro_mod.IntroState,
) void {
    var pfds: [MAX_INPUT_DEVICES]linux.pollfd = undefined;
    fillPollFds(devs, &pfds);
    const poll_res = linux.poll(&pfds, devs.len, 0);
    const signed_poll: isize = @bitCast(poll_res);
    if (signed_poll <= 0) return;

    for (devs, 0..) |*dev_info, i| {
        if ((pfds[i].revents & linux.POLL.IN) != 0) {
            var ev_buf: [32]InputEvent = undefined;
            const rd = linux.read(
                pfds[i].fd,
                @ptrCast(&ev_buf),
                @sizeOf(@TypeOf(ev_buf)),
            );
            const signed_rd: isize = @bitCast(rd);
            if (signed_rd > 0) {
                const n_bytes: usize = @intCast(signed_rd);
                const count = n_bytes / @sizeOf(InputEvent);
                var pending_x = gui.cursor.x;
                var pending_y = gui.cursor.y;
                var coords_changed = false;
                var touch_skip = false;

                for (ev_buf[0..count]) |ev| {
                    applyMotionEvent(
                        ev,
                        dev_info,
                        display.width,
                        display.height,
                        &pending_x,
                        &pending_y,
                        &coords_changed,
                    );
                    if (ev.type == EV_KEY and ev.value != 0 and
                        (ev.code == BTN_LEFT or ev.code == BTN_TOUCH))
                    {
                        touch_skip = true;
                    }
                }

                if (coords_changed) {
                    const down = gui.mouse_left_down;
                    gui.handleMouseMove(pending_x, pending_y, down);
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
