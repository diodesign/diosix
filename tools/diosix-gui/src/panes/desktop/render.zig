// Native 1:1 & Bilinear VirtIO-GPU Scanout Blitter for Diosix GUI.
//
// Renders child VM XRGB8888 scanout frames inside the sunken glass viewport
// well at 1:1 native pixel alignment (with fixed-point bilinear filtering for
// fixed-mode guests), storing the active viewport bounding box for 1:1 tablet
// coordinate mapping.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("../../framebuffer.zig");
const font = @import("../../font.zig");
const window_mod = @import("../../window.zig");
const Window = window_mod.Window;
const gui_mod = @import("../../gui.zig");
const DiosixGui = gui_mod.DiosixGui;

pub const DISPLAY_WIDTH_ALIGN_MASK: u32 = 0x7;
pub const DISPLAY_HEIGHT_ALIGN_MASK: u32 = 0x1;
pub const VIEWPORT_PAD_X_BASE: u32 = 8;
const VIEWPORT_TOP_Y_BASE: u32 = 70;
const VIEWPORT_BOT_PAD_BASE: u32 = 8;
const VIEWPORT_INNER_PAD_BASE: u32 = 2;

const PIXEL_RGB_MASK: u32 = 0x00ff_ffff;
const BILINEAR_FRAC_BITS: u5 = 8;
const BILINEAR_SCALE: u32 = 1 << BILINEAR_FRAC_BITS;
const BILINEAR_FRAC_MASK: u32 = BILINEAR_SCALE - 1;
const BILINEAR_SHIFT_2D: u5 = 16;
const CHANNEL_MASK: u32 = 0xff;

pub const ViewportLayout = struct {
    well_box: fb.Box,
    inner_box: fb.Box,
};

pub fn computeViewportLayout(
    self: *const DiosixGui,
    win_x: i32,
    win_y: i32,
    win_w: u32,
    win_h: u32,
) ViewportLayout {
    const empty = fb.Box{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
    const pad_x: i32 = @intCast(self.scalePx(VIEWPORT_PAD_X_BASE));
    const top_off: i32 = @intCast(self.scalePx(VIEWPORT_TOP_Y_BASE));
    const top_y: i32 = win_y + top_off;
    const bot_y: i32 = win_y + @as(i32, @intCast(win_h)) -
        @as(i32, @intCast(self.scalePx(VIEWPORT_BOT_PAD_BASE)));
    const well_w: u32 = win_w -| @as(u32, @intCast(pad_x * 2));
    const well_h: u32 = if (bot_y > top_y + 16) @intCast(bot_y - top_y) else 0;
    if (well_w == 0 or well_h == 0) {
        return .{ .well_box = empty, .inner_box = empty };
    }

    const well_box = fb.Box.fromPosSize(win_x + pad_x, top_y, well_w, well_h);
    const inner_pad: u32 = self.scalePx(VIEWPORT_INNER_PAD_BASE);
    const raw_iw: u32 = well_w -| (inner_pad * 2);
    const raw_ih: u32 = well_h -| (inner_pad * 2);
    const aligned_iw: u32 = if (raw_iw >= 8)
        raw_iw & ~DISPLAY_WIDTH_ALIGN_MASK
    else
        raw_iw;
    const aligned_ih: u32 = if (raw_ih >= 2)
        raw_ih & ~DISPLAY_HEIGHT_ALIGN_MASK
    else
        raw_ih;
    const ix: i32 = well_box.x0 + @divTrunc(
        @as(i32, @intCast(well_w)) - @as(i32, @intCast(aligned_iw)),
        2,
    );
    const iy: i32 = well_box.y0 + @divTrunc(
        @as(i32, @intCast(well_h)) - @as(i32, @intCast(aligned_ih)),
        2,
    );
    return .{
        .well_box = well_box,
        .inner_box = fb.Box.fromPosSize(ix, iy, aligned_iw, aligned_ih),
    };
}

fn sampleBilinearPixel(
    p00: u32,
    p10: u32,
    p01: u32,
    p11: u32,
    wx: u32,
    wy: u32,
) u32 {
    const ix = BILINEAR_SCALE - wx;
    const iy = BILINEAR_SCALE - wy;
    const w00 = ix * iy;
    const w10 = wx * iy;
    const w01 = ix * wy;
    const w11 = wx * wy;
    const r = (((p00 >> 16) & CHANNEL_MASK) * w00 +
        ((p10 >> 16) & CHANNEL_MASK) * w10 +
        ((p01 >> 16) & CHANNEL_MASK) * w01 +
        ((p11 >> 16) & CHANNEL_MASK) * w11) >> BILINEAR_SHIFT_2D;
    const g = (((p00 >> 8) & CHANNEL_MASK) * w00 +
        ((p10 >> 8) & CHANNEL_MASK) * w10 +
        ((p01 >> 8) & CHANNEL_MASK) * w01 +
        ((p11 >> 8) & CHANNEL_MASK) * w11) >> BILINEAR_SHIFT_2D;
    const b = ((p00 & CHANNEL_MASK) * w00 +
        (p10 & CHANNEL_MASK) * w10 +
        (p01 & CHANNEL_MASK) * w01 +
        (p11 & CHANNEL_MASK) * w11) >> BILINEAR_SHIFT_2D;
    return (r << 16) | (g << 8) | b;
}

pub fn blitScaledScanout(
    surface: *fb.Surface,
    dst_box: fb.Box,
    src_px: []const u32,
    src_w: u32,
    src_h: u32,
) void {
    const surf_bounds = fb.Box.fromPosSize(0, 0, surface.width, surface.height);
    const vis = dst_box.intersect(surface.clip).intersect(surf_bounds);
    if (vis.isEmpty()) return;

    const dst_w = dst_box.width();
    const dst_h = dst_box.height();
    if (dst_w == 0 or dst_h == 0 or src_w == 0 or src_h == 0) return;

    const dst_stride = surface.stridePixels();

    // 1. Native 1:1 pixel-aligned fast path (host pixel == guest pixel).
    if (dst_w == src_w and dst_h == src_h) {
        var y = vis.y0;
        while (y < vis.y1) : (y += 1) {
            const sy: usize = @intCast(y - dst_box.y0);
            const src_row_off = sy * @as(usize, src_w);
            const dst_row_off = @as(usize, @intCast(y)) * dst_stride;
            var x = vis.x0;
            while (x < vis.x1) : (x += 1) {
                const sx: usize = @intCast(x - dst_box.x0);
                surface.pixels[dst_row_off + @as(usize, @intCast(x))] =
                    src_px[src_row_off + sx] & PIXEL_RGB_MASK;
            }
        }
        return;
    }

    // 2. Crisp exact-integer upscale path (e.g. 2x, 4x).
    if (dst_w >= src_w and dst_h >= src_h and
        dst_w % src_w == 0 and dst_h % src_h == 0)
    {
        var y = vis.y0;
        while (y < vis.y1) : (y += 1) {
            const rel_y: u64 = @intCast(y - dst_box.y0);
            const sy: usize = @intCast(
                (rel_y * @as(u64, src_h)) / @as(u64, dst_h),
            );
            const src_row_off = sy * @as(usize, src_w);
            const dst_row_off = @as(usize, @intCast(y)) * dst_stride;
            var x = vis.x0;
            while (x < vis.x1) : (x += 1) {
                const rel_x: u64 = @intCast(x - dst_box.x0);
                const sx: usize = @intCast(
                    (rel_x * @as(u64, src_w)) / @as(u64, dst_w),
                );
                surface.pixels[dst_row_off + @as(usize, @intCast(x))] =
                    src_px[src_row_off + sx] & PIXEL_RGB_MASK;
            }
        }
        return;
    }

    // 3. Fractional scaling fallback: fixed-point bilinear interpolation.
    const max_sx: usize = src_w - 1;
    const max_sy: usize = src_h - 1;
    var y = vis.y0;
    while (y < vis.y1) : (y += 1) {
        const rel_y: u64 = @intCast(y - dst_box.y0);
        const py_fp: u64 = if (dst_h <= 1 or src_h <= 1)
            0
        else
            (rel_y * @as(u64, src_h - 1) * BILINEAR_SCALE) /
                @as(u64, dst_h - 1);
        const sy0: usize = @intCast(py_fp >> BILINEAR_FRAC_BITS);
        const sy1: usize = @min(sy0 + 1, max_sy);
        const wy: u32 = @intCast(py_fp & BILINEAR_FRAC_MASK);
        const row0 = sy0 * @as(usize, src_w);
        const row1 = sy1 * @as(usize, src_w);
        const dst_row_off = @as(usize, @intCast(y)) * dst_stride;

        var x = vis.x0;
        while (x < vis.x1) : (x += 1) {
            const rel_x: u64 = @intCast(x - dst_box.x0);
            const px_fp: u64 = if (dst_w <= 1 or src_w <= 1)
                0
            else
                (rel_x * @as(u64, src_w - 1) * BILINEAR_SCALE) /
                    @as(u64, dst_w - 1);
            const sx0: usize = @intCast(px_fp >> BILINEAR_FRAC_BITS);
            const sx1: usize = @min(sx0 + 1, max_sx);
            const wx: u32 = @intCast(px_fp & BILINEAR_FRAC_MASK);
            surface.pixels[dst_row_off + @as(usize, @intCast(x))] =
                sampleBilinearPixel(
                    src_px[row0 + sx0],
                    src_px[row0 + sx1],
                    src_px[row1 + sx0],
                    src_px[row1 + sx1],
                    wx,
                    wy,
                );
        }
    }
}

/// Maps guest-space dirty rectangle `[dx, dy, dw, dh)` into screen `dst_box`.
pub fn mapDirtyRectToViewport(
    dst_box: fb.Box,
    src_w: u32,
    src_h: u32,
    dx: u32,
    dy: u32,
    dw: u32,
    dh: u32,
) fb.Box {
    if (dst_box.isEmpty() or src_w == 0 or src_h == 0 or dw == 0 or dh == 0) {
        return dst_box;
    }
    const dst_w: u64 = dst_box.width();
    const dst_h: u64 = dst_box.height();
    const sx0: i32 = @intCast((@as(u64, dx) * dst_w) / src_w);
    const sy0: i32 = @intCast((@as(u64, dy) * dst_h) / src_h);
    const sx1: i32 = @intCast(
        std.math.divCeil(u64, @as(u64, dx +| dw) * dst_w, src_w) catch dst_w,
    );
    const sy1: i32 = @intCast(
        std.math.divCeil(u64, @as(u64, dy +| dh) * dst_h, src_h) catch dst_h,
    );
    const expanded = fb.Box{
        .x0 = dst_box.x0 + sx0 - 1,
        .y0 = dst_box.y0 + sy0 - 1,
        .x1 = dst_box.x0 + sx1 + 1,
        .y1 = dst_box.y0 + sy1 + 1,
    };
    return expanded.intersect(dst_box);
}

fn blendCursorOverlay(
    surface: *fb.Surface,
    dst_box: fb.Box,
    self: *const DiosixGui,
) void {
    const desk = &self.desktop;
    if (!desk.cursor_visible or desk.cursor_w == 0 or desk.cursor_h == 0) {
        return;
    }
    const cur_px = desk.cursor_pixels orelse return;
    if (desk.fb_width == 0 or desk.fb_height == 0) return;

    const dst_w: i64 = @intCast(dst_box.width());
    const dst_h: i64 = @intCast(dst_box.height());
    const src_w: i64 = @intCast(desk.fb_width);
    const src_h: i64 = @intCast(desk.fb_height);
    const left_guest = @as(i64, desk.cursor_x) - @as(i64, desk.cursor_hot_x);
    const top_guest = @as(i64, desk.cursor_y) - @as(i64, desk.cursor_hot_y);

    const draw_x0: i32 = dst_box.x0 +
        @as(i32, @intCast(@divFloor(left_guest * dst_w, src_w)));
    const draw_y0: i32 = dst_box.y0 +
        @as(i32, @intCast(@divFloor(top_guest * dst_h, src_h)));
    const cur_dw: u32 = @max(
        1,
        @as(u32, @intCast(@divFloor(@as(i64, desk.cursor_w) * dst_w, src_w))),
    );
    const cur_dh: u32 = @max(
        1,
        @as(u32, @intCast(@divFloor(@as(i64, desk.cursor_h) * dst_h, src_h))),
    );
    const cbox = fb.Box.fromPosSize(draw_x0, draw_y0, cur_dw, cur_dh);
    const surf_bounds = fb.Box.fromPosSize(0, 0, surface.width, surface.height);
    const vis = cbox.intersect(dst_box).intersect(surface.clip).intersect(
        surf_bounds,
    );
    if (vis.isEmpty()) return;

    const stride = surface.stridePixels();
    var sy = vis.y0;
    while (sy < vis.y1) : (sy += 1) {
        const cy: usize = @intCast(
            (@as(u64, @intCast(sy - draw_y0)) * desk.cursor_h) / cur_dh,
        );
        if (cy >= 64) continue;
        const dst_row = @as(usize, @intCast(sy)) * stride;
        const cur_row = cy * 64;
        var sx = vis.x0;
        while (sx < vis.x1) : (sx += 1) {
            const cx: usize = @intCast(
                (@as(u64, @intCast(sx - draw_x0)) * desk.cursor_w) / cur_dw,
            );
            if (cx >= 64 or cur_row + cx >= cur_px.len) continue;
            const px = cur_px[cur_row + cx];
            const alpha: u8 = @truncate(px >> 24);
            if (alpha == 0) continue;
            const idx = dst_row + @as(usize, @intCast(sx));
            surface.pixels[idx] = fb.blendPixel(
                surface.pixels[idx],
                px & PIXEL_RGB_MASK,
                alpha,
            );
        }
    }
}

fn computeDstBox(
    inner_box: fb.Box,
    src_w: u64,
    src_h: u64,
) fb.Box {
    const avail_w: u64 = inner_box.width();
    const avail_h: u64 = inner_box.height();
    var dst_w: u32 = @intCast(avail_w);
    var dst_h: u32 = @intCast(avail_h);
    if (src_w <= avail_w and src_h <= avail_h and
        avail_w - src_w <= DISPLAY_WIDTH_ALIGN_MASK and
        avail_h - src_h <= DISPLAY_HEIGHT_ALIGN_MASK)
    {
        dst_w = @intCast(src_w);
        dst_h = @intCast(src_h);
    } else if (avail_w * src_h > avail_h * src_w) {
        dst_w = @max(1, @as(u32, @intCast((avail_h * src_w) / src_h)));
    } else {
        dst_h = @max(1, @as(u32, @intCast((avail_w * src_h) / src_w)));
    }
    const dx: i32 = inner_box.x0 + @divTrunc(
        @as(i32, @intCast(avail_w)) - @as(i32, @intCast(dst_w)),
        2,
    );
    const dy: i32 = inner_box.y0 + @divTrunc(
        @as(i32, @intCast(avail_h)) - @as(i32, @intCast(dst_h)),
        2,
    );
    return fb.Box.fromPosSize(dx, dy, dst_w, dst_h);
}

pub fn renderDesktopOverlay(
    self: *DiosixGui,
    surface: *fb.Surface,
    win: *Window,
) void {
    if (!self.desktop.active or !win.is_onscreen) return;

    const layout = computeViewportLayout(
        self,
        win.x,
        win.y,
        win.width,
        win.height,
    );
    if (layout.well_box.isEmpty() or layout.inner_box.isEmpty()) return;

    const inner_box = layout.inner_box;
    const avail_w: u64 = inner_box.width();
    const avail_h: u64 = inner_box.height();
    const src_w: u64 = self.desktop.fb_width;
    const src_h: u64 = self.desktop.fb_height;
    const need_px = std.math.mul(usize, @intCast(src_w), @intCast(src_h)) catch
        0;
    const src_opt = self.desktop.zero_copy_pixels orelse self.desktop.frame_buf;
    const active_ready = self.desktop.scanout_active and src_w > 0 and
        src_h > 0 and need_px > 0 and avail_w > 0 and avail_h > 0 and
        src_opt != null and src_opt.?.len >= need_px;

    const dst_box = if (active_ready)
        computeDstBox(inner_box, src_w, src_h)
    else
        fb.Box{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };

    const clip_inside_dst = active_ready and !surface.clip.isEmpty() and
        surface.clip.x0 >= dst_box.x0 and surface.clip.x1 <= dst_box.x1 and
        surface.clip.y0 >= dst_box.y0 and surface.clip.y1 <= dst_box.y1;
    if (!clip_inside_dst) {
        surface.drawGlassPane(
            layout.well_box,
            6,
            fb.Color.INK,
            250,
            fb.Color.GLASS_BORDER,
            false,
            false,
        );
    }

    const prev_clip = surface.pushClip(inner_box);
    defer surface.popClip(prev_clip);
    if (surface.clip.isEmpty()) return;

    if (active_ready) {
        self.desktop.viewport_box = dst_box;
        blitScaledScanout(
            surface,
            dst_box,
            src_opt.?[0..need_px],
            self.desktop.fb_width,
            self.desktop.fb_height,
        );
        if (self.desktop.zero_copy_pixels != null) {
            blendCursorOverlay(surface, dst_box, self);
        }
        return;
    }

    self.desktop.viewport_box = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
    const line1 = "Waiting for guest VirtIO-GPU display...";
    const line2 = "Use Serial console above to view early boot messages.";
    const lh: i32 = @intCast(font.getActiveLineHeight());
    const cx = inner_box.x0 + @as(i32, @intCast(avail_w / 2));
    const cy = inner_box.y0 + @as(i32, @intCast(avail_h / 2));
    const w1: i32 = @intCast(font.measureString(line1));
    const w2: i32 = @intCast(font.measureString(line2));
    font.drawText(surface, line1, cx - @divTrunc(w1, 2), cy - lh, 0x00ffffff);
    font.drawText(
        surface,
        line2,
        cx - @divTrunc(w2, 2),
        cy + 4,
        fb.Color.TEXT_MUTED,
    );
}

test "desktop/render: 1:1, integer upscale, and bilinear scanout blitter" {
    const testing = std.testing;
    testing.refAllDecls(@This());

    var surf_px: [20 * 20]u32 = @splat(0x00112233);
    var surf = fb.Surface.init(&surf_px, 20, 20, 20 * @sizeOf(u32));
    const src = [_]u32{ 0xffaa0000, 0xff00bb00, 0xff0000cc, 0xffddeeff };
    blitScaledScanout(&surf, fb.Box.fromPosSize(4, 4, 8, 8), &src, 2, 2);

    try testing.expectEqual(@as(u32, 0x00aa0000), surf.getPixel(5, 5));
    try testing.expectEqual(@as(u32, 0x0000bb00), surf.getPixel(9, 5));
    try testing.expectEqual(@as(u32, 0x000000cc), surf.getPixel(5, 9));
    try testing.expectEqual(@as(u32, 0x00ddeeff), surf.getPixel(9, 9));
    try testing.expectEqual(@as(u32, 0x00112233), surf.getPixel(2, 2));

    // Fractional 2x2 -> 3x3 blends midpoint smoothly via bilinear filtering.
    const grad = [_]u32{ 0xff000000, 0xffff0000, 0xff000000, 0xffff0000 };
    blitScaledScanout(&surf, fb.Box.fromPosSize(0, 0, 3, 3), &grad, 2, 2);
    try testing.expectEqual(@as(u32, 0x00000000), surf.getPixel(0, 1));
    const mid_red = (surf.getPixel(1, 1) >> 16) & 0xff;
    try testing.expect(mid_red >= 0x7e and mid_red <= 0x81);
    try testing.expectEqual(@as(u32, 0x00ff0000), surf.getPixel(2, 1));

    // Dirty-rect mapping and 64x64 ARGB cursor alpha blending.
    const mapped = mapDirtyRectToViewport(
        fb.Box.fromPosSize(10, 20, 200, 100),
        100,
        50,
        10,
        5,
        20,
        10,
    );
    try testing.expectEqual(@as(i32, 29), mapped.x0);
    try testing.expectEqual(@as(i32, 29), mapped.y0);
    try testing.expectEqual(@as(i32, 71), mapped.x1);
    try testing.expectEqual(@as(i32, 51), mapped.y1);

    var cur_px = try testing.allocator.alloc(u32, 64 * 64);
    defer testing.allocator.free(cur_px);
    @memset(cur_px, 0);
    cur_px[0] = 0xff00ff00; // opaque green at hotspot (0, 0)
    var gui = try DiosixGui.init(testing.allocator, 640, 480);
    defer gui.deinit();
    gui.desktop.fb_width = 10;
    gui.desktop.fb_height = 10;
    gui.desktop.cursor_visible = true;
    gui.desktop.cursor_w = 1;
    gui.desktop.cursor_h = 1;
    gui.desktop.cursor_x = 0;
    gui.desktop.cursor_y = 0;
    gui.desktop.cursor_pixels = cur_px;
    @memset(&surf_px, 0x00000000);
    surf.clip = fb.Box.fromPosSize(0, 0, 20, 20);
    blendCursorOverlay(&surf, fb.Box.fromPosSize(2, 2, 10, 10), &gui);
    try testing.expectEqual(@as(u32, 0x0000ff00), surf.getPixel(2, 2));
    gui.desktop.cursor_pixels = null;
}
