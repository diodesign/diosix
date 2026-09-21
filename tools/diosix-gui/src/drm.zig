const std = @import("std");
const linux = std.os.linux;
const fb = @import("framebuffer.zig");

const IOC_INOUT: u32 = 3;
const IOC_DIRSHIFT: u5 = 30;
const IOC_SIZESHIFT: u5 = 16;
const IOC_TYPESHIFT: u5 = 8;
const DRM_IOCTL_BASE: u32 = 'd';

fn DRM_IOWR(nr: u32, comptime T: type) u32 {
    return (IOC_INOUT << IOC_DIRSHIFT) | (@as(u32, @sizeOf(T)) << IOC_SIZESHIFT) | (DRM_IOCTL_BASE << IOC_TYPESHIFT) | nr;
}

pub const PREFERRED_WIDTH: u16 = 1280;
pub const PREFERRED_HEIGHT: u16 = 800;
pub const DEFAULT_BPP: u32 = 32;
pub const DEFAULT_DEPTH: u32 = 24;
pub const HW_CURSOR_WIDTH: u32 = 64;
pub const HW_CURSOR_HEIGHT: u32 = 64;

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
    fb_pixels: ?[*]u32 = null,
    width: u32,
    height: u32,
    pitch: u32,
    screen_surface: fb.Surface,

    pub fn init(card_path: []const u8) !DrmDevice {
        var z_path: [64]u8 = undefined;
        if (card_path.len >= z_path.len) return error.PathTooLong;
        @memcpy(z_path[0..card_path.len], card_path);
        z_path[card_path.len] = 0;

        const open_rc = linux.open(@ptrCast(&z_path), .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        const signed_fd: isize = @bitCast(open_rc);
        if (signed_fd < 0) {
            if (signed_fd == -@as(isize, @intFromEnum(linux.E.ACCES))) return error.AccessDenied;
            return error.DeviceOpenFailed;
        }
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
                    if (modes[m_idx].hdisplay == PREFERRED_WIDTH and modes[m_idx].vdisplay == PREFERRED_HEIGHT) {
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
            .bpp = DEFAULT_BPP,
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
            .bpp = DEFAULT_BPP,
            .depth = DEFAULT_DEPTH,
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

        const dev = DrmDevice{
            .fd = fd,
            .crtc_id = crtc_id,
            .conn_id = conn_id,
            .fb_id = fb_id,
            .fb_handle = fb_handle,
            .fb_size = fb_size,
            .fb_pixels = fb_pixels,
            .width = w,
            .height = h,
            .pitch = pitch,
            .screen_surface = fb.Surface.init(fb_pixels, w, h, pitch),
        };

        return dev;
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
        if (self.fb_pixels) |fp| {
            if (self.fb_size > 0) {
                _ = linux.munmap(@ptrCast(fp), self.fb_size);
            }
            self.fb_pixels = null;
        }
        if (self.fb_handle != 0) {
            var destroy = drm_mode_destroy_dumb{ .handle = self.fb_handle };
            _ = linux.ioctl(self.fd, DRM_IOCTL_MODE_DESTROY_DUMB, @intFromPtr(&destroy));
            self.fb_handle = 0;
        }
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
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
