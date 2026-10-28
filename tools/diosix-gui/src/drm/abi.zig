// Direct Rendering Manager (DRM/KMS) Kernel ABI Structures & Ioctl Definitions.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

const IOC_INOUT: u32 = 3;
const IOC_DIRSHIFT: u5 = 30;
const IOC_SIZESHIFT: u5 = 16;
const IOC_TYPESHIFT: u5 = 8;
const DRM_IOCTL_BASE: u32 = 'd';

pub fn DRM_IOWR(nr: u32, comptime T: type) u32 {
    return (IOC_INOUT << IOC_DIRSHIFT) |
        (@as(u32, @sizeOf(T)) << IOC_SIZESHIFT) |
        (DRM_IOCTL_BASE << IOC_TYPESHIFT) | nr;
}

pub const DRM_DISPLAY_MODE_LEN: usize = 32;

pub const drm_version = extern struct {
    version_major: i32 = 0,
    version_minor: i32 = 0,
    version_patchlevel: i32 = 0,
    name_len: u64 = 0,
    name: ?[*]u8 = null,
    date_len: u64 = 0,
    date: ?[*]u8 = null,
    desc_len: u64 = 0,
    desc: ?[*]u8 = null,
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
    name: [DRM_DISPLAY_MODE_LEN]u8 = @splat(0),
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
pub const DRM_IOCTL_MODE_GETRESOURCES = DRM_IOWR(0xa0, drm_mode_card_res);
pub const DRM_IOCTL_MODE_GETCRTC = DRM_IOWR(0xa1, drm_mode_crtc);
pub const DRM_IOCTL_MODE_SETCRTC = DRM_IOWR(0xa2, drm_mode_crtc);
pub const DRM_IOCTL_MODE_CURSOR = DRM_IOWR(0xa3, drm_mode_cursor);
pub const DRM_IOCTL_MODE_GETCONNECTOR = DRM_IOWR(0xa7, drm_mode_get_connector);
pub const DRM_IOCTL_MODE_ADDFB = DRM_IOWR(0xae, drm_mode_fb_cmd);
pub const DRM_IOCTL_MODE_RMFB = DRM_IOWR(0xaf, u32);
pub const DRM_IOCTL_MODE_DIRTYFB = DRM_IOWR(0xb1, drm_mode_fb_dirty_cmd);
pub const DRM_IOCTL_MODE_CREATE_DUMB = DRM_IOWR(0xb2, drm_mode_create_dumb);
pub const DRM_IOCTL_MODE_MAP_DUMB = DRM_IOWR(0xb3, drm_mode_map_dumb);
pub const DRM_IOCTL_MODE_DESTROY_DUMB = DRM_IOWR(0xb4, drm_mode_destroy_dumb);

pub const DRM_MODE_CURSOR_BO = 0x01;
pub const DRM_MODE_CURSOR_MOVE = 0x02;
pub const DRM_MODE_CONNECTED = 1;

/// Synthesizes a 60Hz VESA/CVT `drm_mode_modeinfo` for `(req_w, req_h)` so
/// virtualized KMS drivers (`virtio-gpu`, `bochs-drm`) and flexible CRTCs can
/// switch scanout resolution even when `(req_w, req_h)` is not in the static
/// connector mode table.
pub fn synthesizeModeInfo(
    req_w: u32,
    req_h: u32,
    base: drm_mode_modeinfo,
) drm_mode_modeinfo {
    const w16: u16 = @intCast(std.math.clamp(req_w, 640, 7680));
    const h16: u16 = @intCast(std.math.clamp(req_h, 480, 4320));
    const hblank: u16 = @max(160, w16 / 5);
    const vblank: u16 = @max(28, h16 / 25);
    const htotal: u16 = w16 +| hblank;
    const vtotal: u16 = h16 +| vblank;
    const pixel_clock_khz: u32 =
        (@as(u32, htotal) * @as(u32, vtotal) * 60) / 1000;

    var m = base;
    m.clock = pixel_clock_khz;
    m.hdisplay = w16;
    m.hsync_start = w16 +| (hblank / 4);
    m.hsync_end = w16 +| (hblank / 2);
    m.htotal = htotal;
    m.hskew = 0;
    m.vdisplay = h16;
    m.vsync_start = h16 +| 3;
    m.vsync_end = h16 +| 9;
    m.vtotal = vtotal;
    m.vscan = 0;
    m.vrefresh = 60;
    m.flags = 0;
    m.type = 0;
    @memset(&m.name, 0);
    _ = std.fmt.bufPrint(&m.name, "{d}x{d}", .{ w16, h16 }) catch {};
    return m;
}

test "abi: synthesizeModeInfo clears DRM_MODE_TYPE_PREFERRED for virtio-gpu" {
    std.testing.refAllDecls(@This());
    var base = drm_mode_modeinfo{};
    base.hdisplay = 1280;
    base.vdisplay = 800;
    base.type = 0x48; // DRM_MODE_TYPE_DRIVER | DRM_MODE_TYPE_PREFERRED
    const synth = synthesizeModeInfo(1600, 900, base);
    try std.testing.expectEqual(@as(u16, 1600), synth.hdisplay);
    try std.testing.expectEqual(@as(u16, 900), synth.vdisplay);
    try std.testing.expectEqual(@as(u32, 0), synth.type);
    try std.testing.expectEqual(@as(u32, 60), synth.vrefresh);
}
