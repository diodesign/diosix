// Display Scanout, Dynamic Resolution/Depth Management & Evdev Input Handling
// for Diosix Monolithic GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const fb = @import("framebuffer.zig");
const drm = @import("drm.zig");
const dither = @import("dither.zig");
const paths = @import("paths.zig");
pub const input = @import("display/input.zig");

pub const MS_PER_SEC: i64 = 1000;
pub const NS_PER_MS: i64 = 1_000_000;
pub const TARGET_FPS: i64 = 60;
pub const FRAME_INTERVAL_MS: i64 = MS_PER_SEC / TARGET_FPS;
pub const POLL_TIMEOUT_MS: i32 = @intCast(FRAME_INTERVAL_MS);

pub const MAX_INPUT_DEVICES = input.MAX_INPUT_DEVICES;
pub const InputEvent = input.InputEvent;
pub const EV_KEY = input.EV_KEY;
pub const EV_REL = input.EV_REL;
pub const EV_ABS = input.EV_ABS;
pub const REL_X = input.REL_X;
pub const REL_Y = input.REL_Y;
pub const REL_WHEEL = input.REL_WHEEL;
pub const ABS_X = input.ABS_X;
pub const ABS_Y = input.ABS_Y;
pub const ABS_MT_POSITION_X = input.ABS_MT_POSITION_X;
pub const ABS_MT_POSITION_Y = input.ABS_MT_POSITION_Y;
pub const EVDEV_ABS_MAX = input.EVDEV_ABS_MAX;
pub const BTN_LEFT = input.BTN_LEFT;
pub const BTN_RIGHT = input.BTN_RIGHT;
pub const BTN_MIDDLE = input.BTN_MIDDLE;
pub const BTN_TOUCH = input.BTN_TOUCH;
pub const input_absinfo = input.input_absinfo;
pub const EVIOCGABS = input.EVIOCGABS;
pub const InputDeviceInfo = input.InputDeviceInfo;
pub const openInputDevices = input.openInputDevices;
pub const closeInputDevices = input.closeInputDevices;
pub const fillPollFds = input.fillPollFds;
pub const applyMotionEvent = input.applyMotionEvent;
pub const pollIntroInput = input.pollIntroInput;

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
    hw_w: u32,
    hw_h: u32,
    hw_stride: usize,
    hw_bpp: u32 = 32,
    mm_width: u32 = 0,
    mm_height: u32 = 0,
    color_depth: dither.ColorDepth = .bpp32,
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
        for (paths.DRI_CARD_PATHS) |card_path| {
            if (drm.DrmDevice.init(card_path)) |init_dev| {
                var dev = init_dev;
                errdefer dev.deinit();
                const w = dev.width;
                const h = dev.height;
                const log_stride: usize = @as(usize, w) * @sizeOf(u32);
                const buffer_pixels: usize = @as(usize, w) * @as(usize, h);
                const bb_mem = try allocator.alloc(u32, buffer_pixels);
                errdefer allocator.free(bb_mem);
                const cb_mem = try allocator.alloc(u32, buffer_pixels);
                const st_u32: u32 = @intCast(log_stride);
                return Display{
                    .width = w,
                    .height = h,
                    .stride = log_stride,
                    .hw_w = w,
                    .hw_h = h,
                    .hw_stride = dev.pitch,
                    .hw_bpp = dev.hw_bpp,
                    .mm_width = dev.mm_width,
                    .mm_height = dev.mm_height,
                    .color_depth = dither.ColorDepth.fromBpp(dev.hw_bpp),
                    .fb_ptr = dev.screen_surface.pixels,
                    .drm_dev = dev,
                    .fb_fd = -1,
                    .backbuffer = fb.Surface.init(bb_mem.ptr, w, h, st_u32),
                    .backbuffer_mem = bb_mem,
                    .clean_buffer = fb.Surface.init(cb_mem.ptr, w, h, st_u32),
                    .clean_buffer_mem = cb_mem,
                };
            } else |err| {
                if (err == error.AccessDenied) had_access_denied = true;
            }
        }

        const fb_path = paths.FB0_DEVICE_PATH;
        const fd_rc = linux.open(fb_path, .{ .ACCMODE = .RDWR }, 0);
        const signed_fd: isize = @bitCast(fd_rc);
        if (signed_fd >= 0) {
            const fd: i32 = @intCast(signed_fd);
            errdefer _ = linux.close(fd);
            const w: u32 = drm.PREFERRED_WIDTH;
            const h: u32 = drm.PREFERRED_HEIGHT;
            const stride: usize = @as(usize, w) * @sizeOf(u32);
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
                    .hw_w = w,
                    .hw_h = h,
                    .hw_stride = stride,
                    .hw_bpp = 32,
                    .mm_width = 0,
                    .mm_height = 0,
                    .color_depth = .bpp32,
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
            const map_size = self.hw_stride * self.hw_h;
            if (map_size > 0) {
                _ = linux.munmap(@ptrCast(self.fb_ptr), map_size);
            }
            _ = linux.close(self.fb_fd);
            self.fb_fd = -1;
        }
    }

    /// Reconfigures the display resolution and color depth at runtime.
    pub fn reconfigure(
        self: *Display,
        allocator: std.mem.Allocator,
        req_w: u32,
        req_h: u32,
        depth: dither.ColorDepth,
    ) !void {
        if (req_w == 0 or req_h == 0) return;
        self.color_depth = depth;

        if (self.drm_dev) |*d| {
            d.trySetModeAndDepth(req_w, req_h, depth);
            self.hw_w = d.width;
            self.hw_h = d.height;
            self.hw_stride = d.pitch;
            self.hw_bpp = d.hw_bpp;
            self.fb_ptr = d.screen_surface.pixels;
        }

        if (self.width != req_w or self.height != req_h) {
            const new_px = @as(usize, req_w) * @as(usize, req_h);
            const new_bb = try allocator.alloc(u32, new_px);
            errdefer allocator.free(new_bb);
            const new_cb = try allocator.alloc(u32, new_px);

            allocator.free(self.backbuffer_mem);
            allocator.free(self.clean_buffer_mem);

            const new_stride: usize = @as(usize, req_w) * @sizeOf(u32);
            const st_u32: u32 = @intCast(new_stride);
            self.width = req_w;
            self.height = req_h;
            self.stride = new_stride;
            self.backbuffer_mem = new_bb;
            self.clean_buffer_mem = new_cb;
            self.backbuffer = fb.Surface.init(new_bb.ptr, req_w, req_h, st_u32);
            self.clean_buffer = fb.Surface.init(
                new_cb.ptr,
                req_w,
                req_h,
                st_u32,
            );
            self.cursor_drawn = false;
        }
    }

    pub fn screenSurface(self: *Display) fb.Surface {
        return fb.Surface.init(
            self.fb_ptr,
            self.hw_w,
            self.hw_h,
            @intCast(self.hw_stride),
        );
    }

    pub fn flushDamage(self: *Display, damage: fb.Box) void {
        const x0 = @max(0, damage.x0);
        const y0 = @max(0, damage.y0);
        const x1 = @min(@as(i32, @intCast(self.width)), damage.x1);
        const y1 = @min(@as(i32, @intCast(self.height)), damage.y1);
        if (x0 >= x1 or y0 >= y1) return;

        const dst_bytes_len = self.hw_stride * @as(usize, self.hw_h);
        const dst_ptr: [*]u8 = @ptrCast(self.fb_ptr);
        const dst_bytes: []u8 = dst_ptr[0..dst_bytes_len];

        if (self.width == self.hw_w and self.height == self.hw_h) {
            dither.flushRectWithDepth(
                self.backbuffer_mem,
                self.width,
                dst_bytes,
                self.hw_stride,
                self.hw_bpp,
                self.color_depth,
                @intCast(x0),
                @intCast(y0),
                @intCast(x1),
                @intCast(y1),
            );
            if (self.drm_dev) |*d| d.dirtyFb(damage);
            return;
        }

        // Resample logical compositor resolution `(width, height)` into
        // hardware scanout buffer `(hw_w, hw_h)` with color depth dithering.
        const hx0: usize = (@as(usize, @intCast(x0)) * self.hw_w) / self.width;
        const hy0: usize = (@as(usize, @intCast(y0)) * self.hw_h) / self.height;
        const hx1: usize = @min(
            @as(usize, self.hw_w),
            ((@as(usize, @intCast(x1)) * self.hw_w) + self.width - 1) /
                self.width + 1,
        );
        const hy1: usize = @min(
            @as(usize, self.hw_h),
            ((@as(usize, @intCast(y1)) * self.hw_h) + self.height - 1) /
                self.height + 1,
        );

        const dst_u32: [*]u32 = @ptrCast(@alignCast(dst_bytes.ptr));
        const hw_stride_u32 = self.hw_stride / @sizeOf(u32);
        const max_sx: usize = self.width -| 1;
        const max_sy: usize = self.height -| 1;

        var hy: usize = hy0;
        while (hy < hy1) : (hy += 1) {
            const fy_fp = (hy * @as(usize, self.height) * 256) / self.hw_h;
            const sy0 = @min(max_sy, fy_fp >> 8);
            const sy1 = @min(max_sy, sy0 + 1);
            const wy: u32 = @intCast(fy_fp & 0xff);
            const row0 = sy0 * @as(usize, self.width);
            const row1 = sy1 * @as(usize, self.width);
            const dst_row = hy * hw_stride_u32;

            var hx: usize = hx0;
            while (hx < hx1) : (hx += 1) {
                const fx_fp = (hx * @as(usize, self.width) * 256) / self.hw_w;
                const sx0 = @min(max_sx, fx_fp >> 8);
                const sx1 = @min(max_sx, sx0 + 1);
                const wx: u32 = @intCast(fx_fp & 0xff);

                const p00 = self.backbuffer_mem[row0 + sx0];
                const p10 = self.backbuffer_mem[row0 + sx1];
                const p01 = self.backbuffer_mem[row1 + sx0];
                const p11 = self.backbuffer_mem[row1 + sx1];
                const top_c = fb.blendPixel(p00, p10, @intCast(wx));
                const bot_c = fb.blendPixel(p01, p11, @intCast(wx));
                const raw = fb.blendPixel(top_c, bot_c, @intCast(wy));

                dst_u32[dst_row + hx] = dither.quantizeAndDitherXrgb(
                    raw,
                    @intCast(hx),
                    @intCast(hy),
                    self.color_depth,
                );
            }
        }

        if (self.drm_dev) |*d| {
            d.dirtyFb(fb.Box{
                .x0 = @intCast(hx0),
                .y0 = @intCast(hy0),
                .x1 = @intCast(hx1),
                .y1 = @intCast(hy1),
            });
        }
    }

    pub fn flush(self: *Display) void {
        self.flushDamage(fb.Box.fromPosSize(0, 0, self.width, self.height));
    }
};

test {
    _ = input;
    std.testing.refAllDecls(@This());
}
