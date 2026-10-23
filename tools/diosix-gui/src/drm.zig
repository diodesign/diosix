// Direct Rendering Manager (DRM/KMS) Scanout Engine for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const fb = @import("framebuffer.zig");
const dither = @import("dither.zig");
pub const abi = @import("drm/abi.zig");

pub const PREFERRED_WIDTH: u16 = 1280;
pub const PREFERRED_HEIGHT: u16 = 800;
pub const DEFAULT_BPP: u32 = 32;
pub const DEFAULT_DEPTH: u32 = 24;
pub const HW_CURSOR_WIDTH: u32 = 64;
pub const HW_CURSOR_HEIGHT: u32 = 64;
pub const DRM_CARD_PATH_BUF_BYTES: usize = 64;
pub const MAX_CONNECTOR_MODES: usize = 128;

pub const drm_version = abi.drm_version;
pub const drm_mode_card_res = abi.drm_mode_card_res;
pub const drm_mode_modeinfo = abi.drm_mode_modeinfo;
pub const drm_mode_crtc = abi.drm_mode_crtc;
pub const drm_mode_get_connector = abi.drm_mode_get_connector;
pub const drm_mode_fb_cmd = abi.drm_mode_fb_cmd;
pub const drm_clip_rect = abi.drm_clip_rect;
pub const drm_mode_fb_dirty_cmd = abi.drm_mode_fb_dirty_cmd;
pub const drm_mode_create_dumb = abi.drm_mode_create_dumb;
pub const drm_mode_map_dumb = abi.drm_mode_map_dumb;
pub const drm_mode_destroy_dumb = abi.drm_mode_destroy_dumb;
pub const drm_mode_cursor = abi.drm_mode_cursor;

pub const DRM_IOCTL_VERSION = abi.DRM_IOCTL_VERSION;
pub const DRM_IOCTL_MODE_GETRESOURCES = abi.DRM_IOCTL_MODE_GETRESOURCES;
pub const DRM_IOCTL_MODE_GETCRTC = abi.DRM_IOCTL_MODE_GETCRTC;
pub const DRM_IOCTL_MODE_SETCRTC = abi.DRM_IOCTL_MODE_SETCRTC;
pub const DRM_IOCTL_MODE_CURSOR = abi.DRM_IOCTL_MODE_CURSOR;
pub const DRM_IOCTL_MODE_GETCONNECTOR = abi.DRM_IOCTL_MODE_GETCONNECTOR;
pub const DRM_IOCTL_MODE_ADDFB = abi.DRM_IOCTL_MODE_ADDFB;
pub const DRM_IOCTL_MODE_RMFB = abi.DRM_IOCTL_MODE_RMFB;
pub const DRM_IOCTL_MODE_DIRTYFB = abi.DRM_IOCTL_MODE_DIRTYFB;
pub const DRM_IOCTL_MODE_CREATE_DUMB = abi.DRM_IOCTL_MODE_CREATE_DUMB;
pub const DRM_IOCTL_MODE_MAP_DUMB = abi.DRM_IOCTL_MODE_MAP_DUMB;
pub const DRM_IOCTL_MODE_DESTROY_DUMB = abi.DRM_IOCTL_MODE_DESTROY_DUMB;
pub const DRM_MODE_CURSOR_BO = abi.DRM_MODE_CURSOR_BO;
pub const DRM_MODE_CURSOR_MOVE = abi.DRM_MODE_CURSOR_MOVE;
pub const DRM_MODE_CONNECTED = abi.DRM_MODE_CONNECTED;

pub const DrmDevice = struct {
    fd: i32,
    crtc_id: u32,
    conn_id: u32,
    fb_id: u32,
    fb_handle: u32,
    fb_size: u64,
    fb_pixels: ?[*]u32 = null,
    width: u32,
    height: u32,
    pitch: u32,
    hw_bpp: u32 = DEFAULT_BPP,
    mm_width: u32 = 0,
    mm_height: u32 = 0,
    active_mode: drm_mode_modeinfo = .{},
    modes: [MAX_CONNECTOR_MODES]drm_mode_modeinfo = @splat(.{}),
    mode_count: usize = 0,
    screen_surface: fb.Surface,

    pub fn init(card_path: []const u8) !DrmDevice {
        var z_path: [DRM_CARD_PATH_BUF_BYTES]u8 = undefined;
        if (card_path.len >= z_path.len) return error.PathTooLong;
        @memcpy(z_path[0..card_path.len], card_path);
        z_path[card_path.len] = 0;

        const open_rc = linux.open(
            @ptrCast(&z_path),
            .{ .ACCMODE = .RDWR, .CLOEXEC = true },
            0,
        );
        const signed_fd: isize = @bitCast(open_rc);
        if (signed_fd < 0) {
            if (signed_fd == -@as(isize, @backingInt(linux.E.ACCES))) {
                return error.AccessDenied;
            }
            return error.DeviceOpenFailed;
        }
        const fd: i32 = @intCast(signed_fd);
        errdefer _ = linux.close(fd);

        var res = drm_mode_card_res{};
        var crtc_ids: [16]u32 = @splat(0);
        var conn_ids: [16]u32 = @splat(0);
        var fb_ids: [16]u32 = @splat(0);
        var enc_ids: [16]u32 = @splat(0);
        res.crtc_id_ptr = @intFromPtr(&crtc_ids);
        res.connector_id_ptr = @intFromPtr(&conn_ids);
        res.fb_id_ptr = @intFromPtr(&fb_ids);
        res.encoder_id_ptr = @intFromPtr(&enc_ids);
        res.count_crtcs = crtc_ids.len;
        res.count_connectors = conn_ids.len;
        res.count_fbs = fb_ids.len;
        res.count_encoders = enc_ids.len;

        var res_rc = linux.ioctl(
            fd,
            DRM_IOCTL_MODE_GETRESOURCES,
            @intFromPtr(&res),
        );
        if (@as(isize, @bitCast(res_rc)) < 0 or res.count_crtcs == 0 or
            res.count_connectors == 0)
        {
            return error.NoResources;
        }

        const crtc_id = crtc_ids[0];
        var chosen_conn: ?u32 = null;
        var chosen_mode: ?drm_mode_modeinfo = null;
        var conn_mm_w: u32 = 0;
        var conn_mm_h: u32 = 0;
        var saved_modes: [MAX_CONNECTOR_MODES]drm_mode_modeinfo = @splat(.{});
        var saved_mode_count: usize = 0;

        var c_idx: usize = 0;
        const total_conns: usize = @min(
            @as(usize, res.count_connectors),
            conn_ids.len,
        );
        while (c_idx < total_conns) : (c_idx += 1) {
            const cid = conn_ids[c_idx];
            var modes: [MAX_CONNECTOR_MODES]drm_mode_modeinfo = @splat(.{});
            var conn = drm_mode_get_connector{
                .connector_id = cid,
                .modes_ptr = @intFromPtr(&modes),
                .count_modes = modes.len,
            };
            res_rc = linux.ioctl(
                fd,
                DRM_IOCTL_MODE_GETCONNECTOR,
                @intFromPtr(&conn),
            );
            if (@as(isize, @bitCast(res_rc)) == 0 and
                conn.connection == DRM_MODE_CONNECTED and
                conn.count_modes > 0)
            {
                chosen_conn = cid;
                conn_mm_w = conn.mm_width;
                conn_mm_h = conn.mm_height;
                const total_modes: usize = @min(
                    @as(usize, conn.count_modes),
                    modes.len,
                );
                saved_mode_count = total_modes;
                @memcpy(saved_modes[0..total_modes], modes[0..total_modes]);
                chosen_mode = modes[0];
                for (modes[0..total_modes]) |m| {
                    if (m.hdisplay == PREFERRED_WIDTH and
                        m.vdisplay == PREFERRED_HEIGHT)
                    {
                        chosen_mode = m;
                        break;
                    }
                }
                break;
            }
        }

        if (chosen_conn == null or chosen_mode == null) {
            return error.NoConnectedDisplay;
        }

        const conn_id = chosen_conn.?;
        const mode = chosen_mode.?;
        const alloc = try createAndSetScanoutBuffer(
            fd,
            crtc_id,
            conn_id,
            mode,
            DEFAULT_BPP,
            DEFAULT_DEPTH,
        );

        return DrmDevice{
            .fd = fd,
            .crtc_id = crtc_id,
            .conn_id = conn_id,
            .fb_id = alloc.fb_id,
            .fb_handle = alloc.fb_handle,
            .fb_size = alloc.fb_size,
            .fb_pixels = alloc.fb_pixels,
            .width = mode.hdisplay,
            .height = mode.vdisplay,
            .pitch = alloc.pitch,
            .hw_bpp = alloc.bpp,
            .mm_width = conn_mm_w,
            .mm_height = conn_mm_h,
            .active_mode = mode,
            .modes = saved_modes,
            .mode_count = saved_mode_count,
            .screen_surface = fb.Surface.init(
                alloc.fb_pixels,
                mode.hdisplay,
                mode.vdisplay,
                alloc.pitch,
            ),
        };
    }

    const ScanoutAlloc = struct {
        fb_id: u32,
        fb_handle: u32,
        fb_size: u64,
        fb_pixels: [*]u32,
        pitch: u32,
        bpp: u32,
    };

    fn createAndSetScanoutBuffer(
        fd: i32,
        crtc_id: u32,
        conn_id: u32,
        mode: drm_mode_modeinfo,
        req_bpp: u32,
        req_depth: u32,
    ) !ScanoutAlloc {
        const w: u32 = mode.hdisplay;
        const h: u32 = mode.vdisplay;

        var create_dumb = drm_mode_create_dumb{
            .width = w,
            .height = h,
            .bpp = req_bpp,
        };
        var ioctl_rc = linux.ioctl(
            fd,
            DRM_IOCTL_MODE_CREATE_DUMB,
            @intFromPtr(&create_dumb),
        );
        if (@as(isize, @bitCast(ioctl_rc)) < 0) return error.CreateDumbFailed;
        const fb_handle = create_dumb.handle;
        const fb_size = create_dumb.size;
        const pitch = create_dumb.pitch;
        errdefer {
            var destroy = drm_mode_destroy_dumb{ .handle = fb_handle };
            _ = linux.ioctl(
                fd,
                DRM_IOCTL_MODE_DESTROY_DUMB,
                @intFromPtr(&destroy),
            );
        }

        var fb_cmd = drm_mode_fb_cmd{
            .width = w,
            .height = h,
            .pitch = pitch,
            .bpp = req_bpp,
            .depth = req_depth,
            .handle = fb_handle,
        };
        ioctl_rc = linux.ioctl(fd, DRM_IOCTL_MODE_ADDFB, @intFromPtr(&fb_cmd));
        if (@as(isize, @bitCast(ioctl_rc)) < 0) return error.AddFbFailed;
        const fb_id = fb_cmd.fb_id;
        errdefer {
            var rm_id = fb_id;
            _ = linux.ioctl(fd, DRM_IOCTL_MODE_RMFB, @intFromPtr(&rm_id));
        }

        var map_dumb = drm_mode_map_dumb{ .handle = fb_handle };
        ioctl_rc = linux.ioctl(
            fd,
            DRM_IOCTL_MODE_MAP_DUMB,
            @intFromPtr(&map_dumb),
        );
        if (@as(isize, @bitCast(ioctl_rc)) < 0) return error.MapDumbFailed;

        const map_res = linux.mmap(
            null,
            fb_size,
            linux.PROT{ .READ = true, .WRITE = true },
            linux.MAP{ .TYPE = .SHARED },
            fd,
            @as(i64, @bitCast(map_dumb.offset)),
        );
        if (@as(isize, @bitCast(map_res)) < 0) return error.MmapFailed;

        const fb_pixels: [*]u32 = @ptrFromInt(map_res);
        errdefer if (fb_size > 0) {
            _ = linux.munmap(@ptrCast(fb_pixels), fb_size);
        };

        var conn_id_copy = conn_id;
        var set_crtc = drm_mode_crtc{
            .crtc_id = crtc_id,
            .fb_id = fb_id,
            .x = 0,
            .y = 0,
            .set_connectors_ptr = @intFromPtr(&conn_id_copy),
            .count_connectors = 1,
            .mode = mode,
            .mode_valid = 1,
        };
        ioctl_rc = linux.ioctl(
            fd,
            DRM_IOCTL_MODE_SETCRTC,
            @intFromPtr(&set_crtc),
        );
        if (@as(isize, @bitCast(ioctl_rc)) < 0) return error.SetCrtcFailed;

        return .{
            .fb_id = fb_id,
            .fb_handle = fb_handle,
            .fb_size = fb_size,
            .fb_pixels = fb_pixels,
            .pitch = pitch,
            .bpp = req_bpp,
        };
    }

    /// Attempts to switch hardware CRTC mode and/or dumb buffer color depth.
    /// Falls back gracefully to the active CRTC mode and 32bpp dumb buffer if
    /// the driver rejects a non-native mode or bit depth.
    pub fn trySetModeAndDepth(
        self: *DrmDevice,
        req_w: u32,
        req_h: u32,
        depth: dither.ColorDepth,
    ) void {
        var target_mode = abi.synthesizeModeInfo(
            req_w,
            req_h,
            self.active_mode,
        );
        for (self.modes[0..self.mode_count]) |m| {
            if (m.hdisplay == req_w and m.vdisplay == req_h) {
                target_mode = m;
                break;
            }
        }

        const req_bpp = depth.bitsPerPixel();
        const req_drm_depth = depth.drmDepth();

        const new_alloc = createAndSetScanoutBuffer(
            self.fd,
            self.crtc_id,
            self.conn_id,
            target_mode,
            req_bpp,
            req_drm_depth,
        ) catch createAndSetScanoutBuffer(
            self.fd,
            self.crtc_id,
            self.conn_id,
            target_mode,
            DEFAULT_BPP,
            DEFAULT_DEPTH,
        ) catch blk: {
            target_mode = self.active_mode;
            break :blk createAndSetScanoutBuffer(
                self.fd,
                self.crtc_id,
                self.conn_id,
                target_mode,
                DEFAULT_BPP,
                DEFAULT_DEPTH,
            ) catch return;
        };

        // Release old scanout buffer after new CRTC mode is active.
        if (self.fb_pixels) |fp| {
            if (self.fb_size > 0) _ = linux.munmap(@ptrCast(fp), self.fb_size);
        }
        if (self.fb_id != 0) {
            var rm_id = self.fb_id;
            _ = linux.ioctl(self.fd, DRM_IOCTL_MODE_RMFB, @intFromPtr(&rm_id));
        }
        if (self.fb_handle != 0) {
            var destroy = drm_mode_destroy_dumb{ .handle = self.fb_handle };
            _ = linux.ioctl(
                self.fd,
                DRM_IOCTL_MODE_DESTROY_DUMB,
                @intFromPtr(&destroy),
            );
        }

        self.fb_id = new_alloc.fb_id;
        self.fb_handle = new_alloc.fb_handle;
        self.fb_size = new_alloc.fb_size;
        self.fb_pixels = new_alloc.fb_pixels;
        self.width = target_mode.hdisplay;
        self.height = target_mode.vdisplay;
        self.pitch = new_alloc.pitch;
        self.hw_bpp = new_alloc.bpp;
        self.active_mode = target_mode;
        self.screen_surface = fb.Surface.init(
            new_alloc.fb_pixels,
            self.width,
            self.height,
            self.pitch,
        );
    }

    pub fn dirtyFb(self: *DrmDevice, box: fb.Box) void {
        const max_dim: i32 = std.math.maxInt(u16);
        const max_w = @min(@as(i32, @intCast(self.width)), max_dim);
        const max_h = @min(@as(i32, @intCast(self.height)), max_dim);
        const x0 = @max(0, box.x0);
        const y0 = @max(0, box.y0);
        const x1 = @min(max_w, box.x1);
        const y1 = @min(max_h, box.y1);
        if (x0 >= x1 or y0 >= y1) return;

        var clip = drm_clip_rect{
            .x1 = @intCast(x0),
            .y1 = @intCast(y0),
            .x2 = @intCast(x1),
            .y2 = @intCast(y1),
        };
        var dirty = drm_mode_fb_dirty_cmd{
            .fb_id = self.fb_id,
            .num_clips = 1,
            .clips_ptr = @intFromPtr(&clip),
        };
        _ = linux.ioctl(self.fd, DRM_IOCTL_MODE_DIRTYFB, @intFromPtr(&dirty));
    }

    pub fn getDriverName(self: *DrmDevice, buf: []u8) []const u8 {
        var v = drm_version{
            .name_len = buf.len,
            .name = buf.ptr,
            .date_len = 0,
            .desc_len = 0,
        };
        const rc = linux.ioctl(self.fd, DRM_IOCTL_VERSION, @intFromPtr(&v));
        if (@as(isize, @bitCast(rc)) == 0 and v.name_len > 0) {
            const name_len: usize = @intCast(@min(v.name_len, buf.len));
            return buf[0..name_len];
        }
        return "unknown";
    }

    pub fn hasHardwareAcceleration(self: *DrmDevice) bool {
        _ = self;
        return false;
    }

    pub fn deinit(self: *DrmDevice) void {
        if (self.fb_pixels) |fp| {
            if (self.fb_size > 0) {
                _ = linux.munmap(@ptrCast(fp), self.fb_size);
            }
            self.fb_pixels = null;
        }
        if (self.fb_id != 0) {
            var rm_id = self.fb_id;
            _ = linux.ioctl(self.fd, DRM_IOCTL_MODE_RMFB, @intFromPtr(&rm_id));
            self.fb_id = 0;
        }
        if (self.fb_handle != 0) {
            var destroy = drm_mode_destroy_dumb{ .handle = self.fb_handle };
            _ = linux.ioctl(
                self.fd,
                DRM_IOCTL_MODE_DESTROY_DUMB,
                @intFromPtr(&destroy),
            );
            self.fb_handle = 0;
        }
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
    }
};

test "drm: over-long card path is rejected, not truncated" {
    const long_path: [DRM_CARD_PATH_BUF_BYTES]u8 = @splat('x');
    try std.testing.expectError(error.PathTooLong, DrmDevice.init(&long_path));
}

test "drm: types and ioctls" {
    _ = abi;
    const testing = std.testing;
    std.testing.refAllDecls(@This());
    try testing.expectEqual(@as(usize, 64), @sizeOf(drm_mode_card_res));
    try testing.expectEqual(@as(usize, 104), @sizeOf(drm_mode_crtc));
    try testing.expectEqual(@as(usize, 80), @sizeOf(drm_mode_get_connector));
    try testing.expectEqual(@as(usize, 28), @sizeOf(drm_mode_fb_cmd));
    try testing.expectEqual(@as(usize, 24), @sizeOf(drm_mode_fb_dirty_cmd));
    try testing.expectEqual(@as(usize, 32), @sizeOf(drm_mode_create_dumb));
    try testing.expectEqual(@as(usize, 16), @sizeOf(drm_mode_map_dumb));
    try testing.expectEqual(@as(usize, 28), @sizeOf(drm_mode_cursor));
}
