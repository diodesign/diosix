// Framebuffer & Translucent Glass Engine for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
pub const noise = @import("noise.zig");
pub const backdrop = @import("backdrop.zig");
pub const glass = @import("glass.zig");

pub const CLOUD_MAP = backdrop.CLOUD_MAP;
pub const CLOUD_MAP_DIMENSION = backdrop.CLOUD_MAP_DIMENSION;
pub const CLOUD_MAP_MASK = backdrop.CLOUD_MAP_MASK;
pub const CLOUD_BASE_OPACITY = backdrop.CLOUD_BASE_OPACITY;
pub const CLOUD_ANIMATED_OPACITY = backdrop.CLOUD_ANIMATED_OPACITY;
pub const MAX_BLUR_RADIUS = backdrop.MAX_BLUR_RADIUS;
pub const MAX_KERNEL_LEN = backdrop.MAX_KERNEL_LEN;
pub const FP_ONE = backdrop.FP_ONE;
pub const blendCloudPixel = backdrop.blendCloudPixel;
pub const getBackdropPixelDrift = backdrop.getBackdropPixelDrift;
pub const getBackdropPixel = backdrop.getBackdropPixel;
pub const computeGaussianKernel = backdrop.computeGaussianKernel;
pub const cornerDistMetric = glass.cornerDistMetric;

pub const Color = struct {
    pub const BLACK: u32 = 0x00000000;
    pub const WHITE: u32 = 0x00ffffff;
    pub const TRANSPARENT: u32 = 0xff000000;
    pub const GLOVE_SHADING: u32 = 0x00b0b8c8;
    pub const GLOVE_CUFF: u32 = 0x00284060;
    pub const SHIFT_R: u5 = 16;
    pub const SHIFT_G: u5 = 8;

    pub inline fn r(c: u32) u8 {
        return @truncate(c >> SHIFT_R);
    }

    pub inline fn g(c: u32) u8 {
        return @truncate(c >> SHIFT_G);
    }

    pub inline fn b(c: u32) u8 {
        return @truncate(c);
    }

    pub inline fn rgb(red: u8, green: u8, blue: u8) u32 {
        return (@as(u32, red) << SHIFT_R) |
            (@as(u32, green) << SHIFT_G) |
            @as(u32, blue);
    }

    // Structural Monochrome Ink & Paper Palette.
    pub const INK: u32 = 0x00111111;
    pub const INK_SECONDARY: u32 = 0x004a4a48;
    pub const GLASS_BG: u32 = 0x00f8f7f2;
    pub const GLASS_OPACITY: u8 = 242;
    pub const GLASS_BORDER: u32 = 0x00111111;
    pub const GLASS_BTN_BG: u32 = 0x00f2f0e8;
    pub const GLASS_BTN_BORDER: u32 = 0x00111111;

    // Archival White & Warm Paper Canvas Colors.
    pub const SKY_BASE_TOP: u32 = 0x00ffffff;
    pub const SKY_BASE_BOT: u32 = 0x00f5f4ef;

    // Border Bevel Palette.
    pub const BORDER_OUTER: u32 = 0x00111111;
    pub const BORDER_HIGHLIGHT: u32 = 0x00ffffff;
    pub const BORDER_SHADOW: u32 = 0x004a4a48;
    pub const BORDER_INNER: u32 = 0x00111111;

    // Monochrome Structural Accents (no color highlights in GUI).
    pub const ACCENT_GOLD: u32 = 0x00111111;
    pub const ACCENT_CYAN: u32 = 0x00111111;
    pub const ACCENT_GREEN: u32 = 0x00111111;
    pub const ACCENT_AMBER: u32 = 0x004a4a48;
    pub const ACCENT_RED: u32 = 0x00111111;
    pub const ACCENT_BLUE: u32 = 0x00111111;
    pub const ACCENT_VIOLET: u32 = 0x00111111;
    pub const TEXT_MUTED: u32 = 0x006e6d68;
    pub const DESKTOP_BG: u32 = 0x00ffffff;

    // Reserved exclusively for the DIOSIX boot logo character interior fill.
    pub const RAINBOW = [6]u32{
        0x00e63946, // Vermilion red.
        0x00f48c06, // Cadmium orange.
        0x00e9b824, // Golden ochre.
        0x002a9d8f, // Viridian emerald.
        0x001d6fd8, // Cobalt blue.
        0x007209b7, // Ultramarine violet.
    };

    // Window Pane and Widget Elements.
    pub const GLASS_DIVIDER: u32 = 0x00111111;
    pub const INPUT_BG: u32 = 0x00ffffff;
    pub const TRACK_BG: u32 = 0x00e4e2da;
    pub const THUMB_BG: u32 = 0x00111111;
    pub const BTN_PRESS_BG: u32 = 0x00dad8ce;
    pub const BTN_HOVER_BG: u32 = 0x00e8e6de;
    pub const BTN_NORMAL_BG: u32 = 0x00f4f3ee;

    // Tab Bar Palette.
    pub const TAB_DIVIDER: u32 = 0x00111111;
    pub const TAB_ACTIVE_BG: u32 = 0x00e8e6de;
    pub const TAB_INACTIVE_BG: u32 = 0x00f4f3ee;
    pub const TAB_INACTIVE_BORDER: u32 = 0x00111111;
    pub const GRADIENT_BOT_DEFAULT: u32 = 0x00f2f0e8;
};

pub const Box = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    pub fn fromPosSize(x: i32, y: i32, w: u32, h: u32) Box {
        const iw: i32 = std.math.cast(i32, w) orelse std.math.maxInt(i32);
        const ih: i32 = std.math.cast(i32, h) orelse std.math.maxInt(i32);
        return .{
            .x0 = x,
            .y0 = y,
            .x1 = std.math.add(i32, x, iw) catch std.math.maxInt(i32),
            .y1 = std.math.add(i32, y, ih) catch std.math.maxInt(i32),
        };
    }

    pub fn width(self: Box) u32 {
        return if (self.x1 > self.x0) @intCast(self.x1 - self.x0) else 0;
    }

    pub fn height(self: Box) u32 {
        return if (self.y1 > self.y0) @intCast(self.y1 - self.y0) else 0;
    }

    pub fn isEmpty(self: Box) bool {
        return self.x0 >= self.x1 or self.y0 >= self.y1;
    }

    pub fn contains(self: Box, px: i32, py: i32) bool {
        return px >= self.x0 and px < self.x1 and
            py >= self.y0 and py < self.y1;
    }

    pub fn intersects(self: Box, other: Box) bool {
        return self.x0 < other.x1 and self.x1 > other.x0 and
            self.y0 < other.y1 and self.y1 > other.y0;
    }

    pub fn intersect(self: Box, other: Box) Box {
        return .{
            .x0 = @max(self.x0, other.x0),
            .y0 = @max(self.y0, other.y0),
            .x1 = @min(self.x1, other.x1),
            .y1 = @min(self.y1, other.y1),
        };
    }

    pub fn merge(self: Box, other: Box) Box {
        if (self.isEmpty()) return other;
        if (other.isEmpty()) return self;
        return .{
            .x0 = @min(self.x0, other.x0),
            .y0 = @min(self.y0, other.y0),
            .x1 = @max(self.x1, other.x1),
            .y1 = @max(self.y1, other.y1),
        };
    }
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

// Fast ARGB pixel alpha blend.
pub fn blendPixel(bg: u32, fg: u32, alpha: u8) u32 {
    if (alpha == 255) return fg;
    if (alpha == 0) return bg;
    const inv_alpha: u32 = 255 - alpha;
    const a: u32 = alpha;
    const fg_r: u32 = Color.r(fg);
    const fg_g: u32 = Color.g(fg);
    const fg_b: u32 = Color.b(fg);

    const bg_r: u32 = Color.r(bg);
    const bg_g: u32 = Color.g(bg);
    const bg_b: u32 = Color.b(bg);

    const out_r: u8 = @intCast((fg_r * a + bg_r * inv_alpha) >> 8);
    const out_g: u8 = @intCast((fg_g * a + bg_g * inv_alpha) >> 8);
    const out_b: u8 = @intCast((fg_b * a + bg_b * inv_alpha) >> 8);
    return Color.rgb(out_r, out_g, out_b);
}

pub const Surface = struct {
    pixels: [*]u32,
    width: u32,
    height: u32,
    // Stride in bytes.
    stride: usize,
    clip: Box,

    pub fn init(px: [*]u32, width: u32, height: u32, stride: usize) Surface {
        return .{
            .pixels = px,
            .width = width,
            .height = height,
            .stride = stride,
            .clip = Box.fromPosSize(0, 0, width, height),
        };
    }

    pub inline fn stridePixels(self: Surface) usize {
        return self.stride / @sizeOf(u32);
    }

    pub fn setClip(self: *Surface, box: Box) void {
        const screen_box = Box.fromPosSize(0, 0, self.width, self.height);
        self.clip = box.intersect(screen_box);
    }

    pub fn resetClip(self: *Surface) void {
        self.clip = Box.fromPosSize(0, 0, self.width, self.height);
    }

    pub fn pushClip(self: *Surface, box: Box) Box {
        const prev = self.clip;
        self.clip = prev.intersect(box);
        return prev;
    }

    pub fn popClip(self: *Surface, prev_clip: Box) void {
        self.clip = prev_clip;
    }

    pub fn setPixel(self: *Surface, x: i32, y: i32, color: u32) void {
        if (!self.clip.contains(x, y)) return;
        const row_start = @as(usize, @intCast(y)) * self.stridePixels();
        const col = @as(usize, @intCast(x));
        self.pixels[row_start + col] = color;
    }

    pub fn getPixel(self: *const Surface, x: i32, y: i32) u32 {
        if (x < 0 or y < 0 or
            x >= @as(i32, @intCast(self.width)) or
            y >= @as(i32, @intCast(self.height))) return 0;
        const row_start = @as(usize, @intCast(y)) * self.stridePixels();
        const col = @as(usize, @intCast(x));
        return self.pixels[row_start + col];
    }

    pub fn fillBox(self: *Surface, target: Box, color: u32) void {
        const active = target.intersect(self.clip);
        if (active.isEmpty()) return;

        const pixels_per_row = self.stridePixels();
        const fill_len = active.width();
        var y = active.y0;
        while (y < active.y1) : (y += 1) {
            const row_offset = @as(usize, @intCast(y)) * pixels_per_row +
                @as(usize, @intCast(active.x0));
            @memset(self.pixels[row_offset .. row_offset + fill_len], color);
        }
    }

    pub fn fillRect(self: *Surface, rect: Rect, color: u32) void {
        const box = Box.fromPosSize(rect.x, rect.y, rect.width, rect.height);
        self.fillBox(box, color);
    }

    pub fn drawBoxOutline(
        self: *Surface,
        box: Box,
        thick: u32,
        color: u32,
    ) void {
        const t = @as(i32, @intCast(thick));
        if (t <= 0) return;
        const x0 = box.x0;
        const x1 = box.x1;
        const top = Box{ .x0 = x0, .y0 = box.y0, .x1 = x1, .y1 = box.y0 + t };
        const bot = Box{ .x0 = x0, .y0 = box.y1 - t, .x1 = x1, .y1 = box.y1 };
        self.fillBox(top, color);
        self.fillBox(bot, color);
        const y0 = box.y0 + t;
        const y1 = box.y1 - t;
        const left = Box{ .x0 = x0, .y0 = y0, .x1 = x0 + t, .y1 = y1 };
        const right = Box{ .x0 = x1 - t, .y0 = y0, .x1 = x1, .y1 = y1 };
        self.fillBox(left, color);
        self.fillBox(right, color);
    }

    pub fn drawFilledCircle(
        self: *Surface,
        cx: i32,
        cy: i32,
        r: i32,
        color: u32,
    ) void {
        if (r <= 0) {
            self.setPixel(cx, cy, color);
            return;
        }
        var dy = -r;
        while (dy <= r) : (dy += 1) {
            var dx = -r;
            while (dx <= r) : (dx += 1) {
                if (dx * dx + dy * dy <= r * r) {
                    self.setPixel(cx + dx, cy + dy, color);
                }
            }
        }
    }

    pub fn drawHorizontalLine(
        self: *Surface,
        x0: i32,
        x1: i32,
        y: i32,
        color: u32,
    ) void {
        const left = @min(x0, x1);
        const right = @max(x0, x1);
        const line = Box{ .x0 = left, .y0 = y, .x1 = right + 1, .y1 = y + 1 };
        self.fillBox(line, color);
    }

    pub const drawGraduatedBackgroundInBoxDrift =
        backdrop.drawGraduatedBackgroundInBoxDrift;
    pub const drawGraduatedBackgroundInBox =
        backdrop.drawGraduatedBackgroundInBox;
    pub const drawBlurredBackdropInBoxDrift =
        backdrop.drawBlurredBackdropInBoxDrift;
    pub const drawBlurredBackdropInBox = backdrop.drawBlurredBackdropInBox;
    pub const drawGraduatedBackgroundDrift =
        backdrop.drawGraduatedBackgroundDrift;
    pub const drawGraduatedBackground = backdrop.drawGraduatedBackground;
    pub const drawAnimatedClouds = backdrop.drawAnimatedClouds;
    pub const drawGlassPane = glass.drawGlassPane;
    pub const drawRoundedTranslucentBox = glass.drawRoundedTranslucentBox;
    pub const drawWindowPane = glass.drawWindowPane;

    // Copy rectangular region from src surface to this surface.
    pub fn copyBoxFrom(self: *Surface, src: *const Surface, box: Box) void {
        const x0 = @max(0, box.x0);
        const y0 = @max(0, box.y0);
        const self_w: i32 = @intCast(self.width);
        const src_w: i32 = @intCast(src.width);
        const self_h: i32 = @intCast(self.height);
        const src_h: i32 = @intCast(src.height);
        const x1 = @min(@min(self_w, src_w), box.x1);
        const y1 = @min(@min(self_h, src_h), box.y1);
        if (x0 >= x1 or y0 >= y1) return;

        const w: usize = @intCast(x1 - x0);
        const dst_stride = self.stridePixels();
        const src_stride = src.stridePixels();

        var y: usize = @intCast(y0);
        const end_y: usize = @intCast(y1);
        const ux0: usize = @intCast(x0);
        const max_dst = self.height * dst_stride;
        const max_src = src.height * src_stride;

        while (y < end_y) : (y += 1) {
            const dst_start = std.math.mul(usize, y, dst_stride) catch break;
            const dst_off = std.math.add(usize, dst_start, ux0) catch break;
            const dst_end = std.math.add(usize, dst_off, w) catch break;

            const src_start = std.math.mul(usize, y, src_stride) catch break;
            const src_off = std.math.add(usize, src_start, ux0) catch break;
            const src_end = std.math.add(usize, src_off, w) catch break;

            if (dst_end > max_dst or src_end > max_src) break;
            @memcpy(
                self.pixels[dst_off..dst_end],
                src.pixels[src_off..src_end],
            );
        }
    }
};

test "framebuffer: blendPixel and box geometry" {
    const testing = std.testing;
    testing.refAllDecls(@This());
    try testing.expectEqual(@as(u32, 0x00000000), blendPixel(0, 0x00ffffff, 0));
    try testing.expectEqual(
        @as(u32, 0x00ffffff),
        blendPixel(0, 0x00ffffff, 255),
    );
    const half = blendPixel(0, 0x00ffffff, 128);
    const r = (half >> 16) & 0xff;
    try testing.expect(r >= 127 and r <= 129);

    const b1 = Box.fromPosSize(10, 10, 100, 50);
    try testing.expectEqual(@as(u32, 100), b1.width());
    try testing.expectEqual(@as(u32, 50), b1.height());
    try testing.expect(b1.contains(50, 30));
    try testing.expect(!b1.contains(5, 5));
}

test "framebuffer: deterministic backdrop blur between full box and sub-box" {
    const testing = std.testing;
    const width: u32 = 200;
    const height: u32 = 150;
    const mem1 = try testing.allocator.alloc(u32, width * height);
    defer testing.allocator.free(mem1);
    const mem2 = try testing.allocator.alloc(u32, width * height);
    defer testing.allocator.free(mem2);
    const scratch = try testing.allocator.alloc(u32, width * (height + 64));
    defer testing.allocator.free(scratch);

    var surf1 = Surface.init(mem1.ptr, width, height, width * 4);
    var surf2 = Surface.init(mem2.ptr, width, height, width * 4);

    const top_col: u32 = 0x004c8be0;
    const bot_col: u32 = 0x000c1836;
    const win_box = Box.fromPosSize(20, 20, 160, 110);
    const sub_box = Box.fromPosSize(50, 50, 60, 40);

    surf1.drawBlurredBackdropInBox(
        win_box,
        win_box,
        top_col,
        bot_col,
        5,
        10,
        scratch,
    );
    surf2.drawBlurredBackdropInBox(
        sub_box,
        win_box,
        top_col,
        bot_col,
        5,
        10,
        scratch,
    );

    var y: i32 = sub_box.y0;
    while (y < sub_box.y1) : (y += 1) {
        var x: i32 = sub_box.x0;
        while (x < sub_box.x1) : (x += 1) {
            const uy: usize = @intCast(y);
            const ux: usize = @intCast(x);
            const idx = uy * width + ux;
            try testing.expectEqual(mem1[idx], mem2[idx]);
        }
    }
}
