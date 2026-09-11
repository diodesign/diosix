const std = @import("std");
const linux = std.os.linux;
const fb = @import("framebuffer.zig");

const DRM_IOCTL_BASE = 'd';
fn DRM_IOWR(nr: u32, comptime T: type) u32 {
    return (3 << 30) | (@as(u32, @sizeOf(T)) << 16) | (@as(u32, DRM_IOCTL_BASE) << 8) | nr;
}

pub const drm_version = extern struct {
    version_major: i32 = 0,
    version_minor: i32 = 0,
    version_patchlevel: i32 = 0,
    name_len: usize = 0,
    name: [*]u8 = undefined,
    date_len: usize = 0,
    date: [*]u8 = undefined,
    desc_len: usize = 0,
    desc: [*]u8 = undefined,
};

pub const drm_mode_card_res = extern struct {
    fb_id_ptr: u64 = 0,
    crtc_id_ptr: u64 = 0,
    connector_id_ptr: u64 = 0,
    encoder_id_ptr: u64 = 0,
    count_fbs: u32 = 0,
    count_crtcs: u32 = 0,
    count_connectors: u32 = 0,
    count_encoders: u32 = 0,
    min_width: u32 = 0,
    max_width: u32 = 0,
    min_height: u32 = 0,
    max_height: u32 = 0,
};

pub const drm_mode_modeinfo = extern struct {
    clock: u32 = 0,
    hdisplay: u16 = 0,
    hsync_start: u16 = 0,
    hsync_end: u16 = 0,
    htotal: u16 = 0,
    hskew: u16 = 0,
    vdisplay: u16 = 0,
    vsync_start: u16 = 0,
    vsync_end: u16 = 0,
    vtotal: u16 = 0,
    vscan: u16 = 0,
    vrefresh: u32 = 0,
    flags: u32 = 0,
    type: u32 = 0,
    name: [32]u8 = undefined,
};

pub const drm_mode_crtc = extern struct {
    set_connectors_ptr: u64 = 0,
    count_connectors: u32 = 0,
    crtc_id: u32 = 0,
    fb_id: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    gamma_size: u32 = 0,
    mode_valid: u32 = 0,
    mode: drm_mode_modeinfo = .{},
};

pub const drm_mode_get_connector = extern struct {
    encoders_ptr: u64 = 0,
    modes_ptr: u64 = 0,
    props_ptr: u64 = 0,
    prop_values_ptr: u64 = 0,
    count_modes: u32 = 0,
    count_props: u32 = 0,
    count_encoders: u32 = 0,
    encoder_id: u32 = 0,
    connector_id: u32 = 0,
    connector_type: u32 = 0,
    connector_type_id: u32 = 0,
    connection: u32 = 0,
    mm_width: u32 = 0,
    mm_height: u32 = 0,
    subpixel: u32 = 0,
    pad: u32 = 0,
};

pub const drm_mode_fb_cmd = extern struct {
    fb_id: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    pitch: u32 = 0,
    bpp: u32 = 0,
    depth: u32 = 0,
    handle: u32 = 0,
};

pub const drm_clip_rect = extern struct {
    x1: u16 = 0,
    y1: u16 = 0,
    x2: u16 = 0,
    y2: u16 = 0,
};

pub const drm_mode_fb_dirty_cmd = extern struct {
    fb_id: u32 = 0,
    flags: u32 = 0,
    color: u32 = 0,
    num_clips: u32 = 0,
    clips_ptr: u64 = 0,
};

pub const drm_mode_create_dumb = extern struct {
    height: u32 = 0,
    width: u32 = 0,
    bpp: u32 = 0,
    flags: u32 = 0,
    handle: u32 = 0,
    pitch: u32 = 0,
    size: u64 = 0,
};

pub const drm_mode_map_dumb = extern struct {
    handle: u32 = 0,
    pad: u32 = 0,
    offset: u64 = 0,
};

pub const drm_mode_destroy_dumb = extern struct {
    handle: u32 = 0,
};

pub const drm_mode_cursor = extern struct {
    flags: u32 = 0,
    crtc_id: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    handle: u32 = 0,
};

pub const DRM_IOCTL_VERSION = DRM_IOWR(0x00, drm_version);
pub const DRM_IOCTL_MODE_GETRESOURCES = DRM_IOWR(0xA0, drm_mode_card_res);
pub const DRM_IOCTL_MODE_GETCRTC = DRM_IOWR(0xA1, drm_mode_crtc);
pub const DRM_IOCTL_MODE_SETCRTC = DRM_IOWR(0xA2, drm_mode_crtc);
pub const DRM_IOCTL_MODE_CURSOR = DRM_IOWR(0xA3, drm_mode_cursor);
pub const DRM_IOCTL_MODE_GETCONNECTOR = DRM_IOWR(0xA7, drm_mode_get_connector);
pub const DRM_IOCTL_MODE_ADDFB = DRM_IOWR(0xAE, drm_mode_fb_cmd);
pub const DRM_IOCTL_MODE_DIRTYFB = DRM_IOWR(0xB1, drm_mode_fb_dirty_cmd);
pub const DRM_IOCTL_MODE_CREATE_DUMB = DRM_IOWR(0xB2, drm_mode_create_dumb);
pub const DRM_IOCTL_MODE_MAP_DUMB = DRM_IOWR(0xB3, drm_mode_map_dumb);
pub const DRM_IOCTL_MODE_DESTROY_DUMB = DRM_IOWR(0xB4, drm_mode_destroy_dumb);

pub const DRM_MODE_CURSOR_BO = 0x01;
pub const DRM_MODE_CURSOR_MOVE = 0x02;
pub const DRM_MODE_CONNECTED = 1;

pub const DrmDevice = struct {
    fd: i32,
    crtc_id: u32,
    conn_id: u32,
    fb_id: u32,
    fb_handle: u32,
    fb_size: u64,
    cursor_handle: u32 = 0,
    cursor_size: u64 = 0,
    width: u32,
    height: u32,
    pitch: u32,
    screen_surface: fb.Surface,
    has_hw_cursor: bool = false,

    pub fn init(card_path: []const u8) !DrmDevice {
        var z_path: [64]u8 = undefined;
        if (card_path.len >= z_path.len) return error.PathTooLong;
        @memcpy(z_path[0..card_path.len], card_path);
        z_path[card_path.len] = 0;

        const open_rc = linux.open(@ptrCast(&z_path), .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        const signed_fd: isize = @bitCast(open_rc);
        if (signed_fd < 0) return error.DeviceOpenFailed;
        const fd: i32 = @intCast(signed_fd);
        errdefer _ = linux.close(fd);

        // 1. Probe resources
        var res = drm_mode_card_res{};
        var crtc_ids: [16]u32 = undefined;
        var conn_ids: [16]u32 = undefined;
        var fb_ids: [16]u32 = undefined;
        var enc_ids: [16]u32 = undefined;
        res.crtc_id_ptr = @intFromPtr(&crtc_ids);
        res.connector_id_ptr = @intFromPtr(&conn_ids);
        res.fb_id_ptr = @intFromPtr(&fb_ids);
        res.encoder_id_ptr = @intFromPtr(&enc_ids);
        res.count_crtcs = crtc_ids.len;
        res.count_connectors = conn_ids.len;
        res.count_fbs = fb_ids.len;
        res.count_encoders = enc_ids.len;

        const res_rc = linux.ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, @intFromPtr(&res));
        const signed_res: isize = @bitCast(res_rc);
        if (signed_res < 0 or res.count_crtcs == 0 or res.count_connectors == 0) {
            return error.NoResources;
        }

        const crtc_id = crtc_ids[0];
        var chosen_conn: ?u32 = null;
        var chosen_mode: ?drm_mode_modeinfo = null;

        // 2. Find connected connector and mode
        var c_idx: usize = 0;
        const total_conns = @min(res.count_connectors, conn_ids.len);
        while (c_idx < total_conns) : (c_idx += 1) {
            const cid = conn_ids[c_idx];
            var conn = drm_mode_get_connector{ .connector_id = cid };
            var modes: [32]drm_mode_modeinfo = undefined;
            conn.modes_ptr = @intFromPtr(&modes);
            conn.count_modes = modes.len;
            conn.count_props = 0;
            conn.props_ptr = 0;
            conn.count_encoders = 0;
            conn.encoders_ptr = 0;

            const conn_rc = linux.ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, @intFromPtr(&conn));
            const signed_conn: isize = @bitCast(conn_rc);
            if (signed_conn == 0 and conn.connection == DRM_MODE_CONNECTED and conn.count_modes > 0) {
                chosen_conn = cid;
                // Look for 1280x800 first, or take preferred/first mode
                var m_idx: usize = 0;
                const total_modes = @min(conn.count_modes, modes.len);
                chosen_mode = modes[0];
                while (m_idx < total_modes) : (m_idx += 1) {
                    if (modes[m_idx].hdisplay == 1280 and modes[m_idx].vdisplay == 800) {
                        chosen_mode = modes[m_idx];
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
        const w: u32 = mode.hdisplay;
        const h: u32 = mode.vdisplay;

        // 3. Create scanout dumb buffer
        var create_dumb = drm_mode_create_dumb{
            .width = w,
            .height = h,
            .bpp = 32,
        };
        var ioctl_rc = linux.ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, @intFromPtr(&create_dumb));
        if (@as(isize, @bitCast(ioctl_rc)) < 0) return error.CreateDumbFailed;
        const fb_handle = create_dumb.handle;
        const fb_size = create_dumb.size;
        const pitch = create_dumb.pitch;

        // 4. Register framebuffer
        var fb_cmd = drm_mode_fb_cmd{
            .width = w,
            .height = h,
            .pitch = pitch,
            .bpp = 32,
            .depth = 24,
            .handle = fb_handle,
        };
        ioctl_rc = linux.ioctl(fd, DRM_IOCTL_MODE_ADDFB, @intFromPtr(&fb_cmd));
        if (@as(isize, @bitCast(ioctl_rc)) < 0) return error.AddFbFailed;
        const fb_id = fb_cmd.fb_id;

        // 5. Map dumb buffer (standard shared RAM - no page faults!)
        var map_dumb = drm_mode_map_dumb{ .handle = fb_handle };
        ioctl_rc = linux.ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, @intFromPtr(&map_dumb));
        if (@as(isize, @bitCast(ioctl_rc)) < 0) return error.MapDumbFailed;

        const map_res = linux.mmap(
            null,
            fb_size,
            linux.PROT{ .READ = true, .WRITE = true },
            linux.MAP{ .TYPE = .SHARED },
            fd,
            @as(i64, @bitCast(map_dumb.offset)),
        );
        const signed_map: isize = @bitCast(map_res);
        if (signed_map < 0) return error.MmapFailed;

        const fb_pixels: [*]u32 = @ptrFromInt(map_res);

        // 6. Set CRTC mode
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
        ioctl_rc = linux.ioctl(fd, DRM_IOCTL_MODE_SETCRTC, @intFromPtr(&set_crtc));
        if (@as(isize, @bitCast(ioctl_rc)) < 0) return error.SetCrtcFailed;

        var dev = DrmDevice{
            .fd = fd,
            .crtc_id = crtc_id,
            .conn_id = conn_id,
            .fb_id = fb_id,
            .fb_handle = fb_handle,
            .fb_size = fb_size,
            .width = w,
            .height = h,
            .pitch = pitch,
            .screen_surface = fb.Surface.init(fb_pixels, w, h, pitch),
        };

        // 7. Setup Hardware Cursor Plane (64x64 ARGB8888)
        var cur_dumb = drm_mode_create_dumb{
            .width = 64,
            .height = 64,
            .bpp = 32,
        };
        const cur_create_rc = linux.ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, @intFromPtr(&cur_dumb));
        if (@as(isize, @bitCast(cur_create_rc)) == 0) {
            var cur_map = drm_mode_map_dumb{ .handle = cur_dumb.handle };
            const cur_map_rc = linux.ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, @intFromPtr(&cur_map));
            if (@as(isize, @bitCast(cur_map_rc)) == 0) {
                const cur_mmap_res = linux.mmap(
                    null,
                    cur_dumb.size,
                    linux.PROT{ .READ = true, .WRITE = true },
                    linux.MAP{ .TYPE = .SHARED },
                    fd,
                    @as(i64, @bitCast(cur_map.offset)),
                );
                const signed_cur_mmap: isize = @bitCast(cur_mmap_res);
                if (signed_cur_mmap >= 0) {
                    dev.cursor_handle = cur_dumb.handle;
                    dev.cursor_size = cur_dumb.size;
                    const cur_pixels: [*]u32 = @ptrFromInt(cur_mmap_res);
                    @memset(cur_pixels[0 .. 64 * 64], 0x00000000); // transparent

                    var cur_cmd = drm_mode_cursor{
                        .flags = DRM_MODE_CURSOR_BO,
                        .crtc_id = crtc_id,
                        .width = 64,
                        .height = 64,
                        .handle = cur_dumb.handle,
                    };
                    const set_bo_rc = linux.ioctl(fd, DRM_IOCTL_MODE_CURSOR, @intFromPtr(&cur_cmd));
                    if (@as(isize, @bitCast(set_bo_rc)) == 0) {
                        dev.has_hw_cursor = true;
                    }
                }
            }
        }

        return dev;
    }

    pub fn setHardwareCursorSprite(
        self: *DrmDevice,
        sprite_pixels: []const u32,
        sprite_w: u32,
        sprite_h: u32,
    ) void {
        if (!self.has_hw_cursor or self.cursor_handle == 0) return;

        // Map cursor buffer to write pixels
        var cur_map = drm_mode_map_dumb{ .handle = self.cursor_handle };
        const rc = linux.ioctl(self.fd, DRM_IOCTL_MODE_MAP_DUMB, @intFromPtr(&cur_map));
        if (@as(isize, @bitCast(rc)) < 0) return;

        const mmap_res = linux.mmap(
            null,
            self.cursor_size,
            linux.PROT{ .READ = true, .WRITE = true },
            linux.MAP{ .TYPE = .SHARED },
            self.fd,
            @as(i64, @bitCast(cur_map.offset)),
        );
        const signed_mmap: isize = @bitCast(mmap_res);
        if (signed_mmap < 0) return;

        const ptr: [*]u32 = @ptrFromInt(mmap_res);
        @memset(ptr[0 .. 64 * 64], 0x00000000); // transparent background

        const copy_w = @min(64, sprite_w);
        const copy_h = @min(64, sprite_h);
        var y: usize = 0;
        while (y < copy_h) : (y += 1) {
            var x: usize = 0;
            while (x < copy_w) : (x += 1) {
                ptr[y * 64 + x] = sprite_pixels[y * sprite_w + x];
            }
        }

        // Re-issue CURSOR_BO to upload cursor image
        var cur_cmd = drm_mode_cursor{
            .flags = DRM_MODE_CURSOR_BO,
            .crtc_id = self.crtc_id,
            .width = 64,
            .height = 64,
            .handle = self.cursor_handle,
        };
        _ = linux.ioctl(self.fd, DRM_IOCTL_MODE_CURSOR, @intFromPtr(&cur_cmd));
    }

    // Move hardware cursor: 0 CPU overhead, composites on host GPU
    pub fn moveCursor(self: *DrmDevice, x: i32, y: i32) void {
        if (!self.has_hw_cursor) return;
        var cur_cmd = drm_mode_cursor{
            .flags = DRM_MODE_CURSOR_MOVE,
            .crtc_id = self.crtc_id,
            .x = x,
            .y = y,
        };
        _ = linux.ioctl(self.fd, DRM_IOCTL_MODE_CURSOR, @intFromPtr(&cur_cmd));
    }

    // Immediately flush dirty rect to VirtIO-GPU without 50ms deferred IO delay
    pub fn dirtyFb(self: *DrmDevice, box: fb.Box) void {
        const x0 = @max(0, box.x0);
        const y0 = @max(0, box.y0);
        const x1 = @min(@as(i32, @intCast(self.width)), box.x1);
        const y1 = @min(@as(i32, @intCast(self.height)), box.y1);
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

    pub fn deinit(self: *DrmDevice) void {
        if (self.cursor_handle != 0) {
            var destroy = drm_mode_destroy_dumb{ .handle = self.cursor_handle };
            _ = linux.ioctl(self.fd, DRM_IOCTL_MODE_DESTROY_DUMB, @intFromPtr(&destroy));
        }
        if (self.fb_handle != 0) {
            var destroy = drm_mode_destroy_dumb{ .handle = self.fb_handle };
            _ = linux.ioctl(self.fd, DRM_IOCTL_MODE_DESTROY_DUMB, @intFromPtr(&destroy));
        }
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
        }
    }
};

test "drm: types and ioctls" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 64), @sizeOf(drm_mode_card_res));
    try testing.expectEqual(@as(usize, 104), @sizeOf(drm_mode_crtc));
    try testing.expectEqual(@as(usize, 80), @sizeOf(drm_mode_get_connector));
    try testing.expectEqual(@as(usize, 28), @sizeOf(drm_mode_fb_cmd));
    try testing.expectEqual(@as(usize, 24), @sizeOf(drm_mode_fb_dirty_cmd));
    try testing.expectEqual(@as(usize, 32), @sizeOf(drm_mode_create_dumb));
    try testing.expectEqual(@as(usize, 16), @sizeOf(drm_mode_map_dumb));
    try testing.expectEqual(@as(usize, 28), @sizeOf(drm_mode_cursor));
}
