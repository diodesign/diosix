// Framebuffer, Translucent Glass Engine & Animated Perlin Clouds for Diosix GUI
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const Color = struct {
    pub const BLACK: u32 = 0x00000000;
    pub const WHITE: u32 = 0x00FFFFFF;
    pub const TRANSPARENT: u32 = 0x00000000;
    pub const GLOVE_SHADING: u32 = 0x00B0B8C8; // Glove shading
    pub const GLOVE_CUFF: u32    = 0x00284060; // Glove cuff

    pub inline fn rgb(r: u8, g: u8, b: u8) u32 {
        return (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
    }

    // Translucent Modern Slate Glass Theme (80% opaque, 20% transparent)
    pub const GLASS_BG: u32        = 0x00141A26; // Neutral dark slate glass (uncolored)
    pub const GLASS_OPACITY: u8    = 204;        // 80% opacity (20% transparent)
    pub const GLASS_BORDER: u32    = 0x0090B0D8; // Subtle frosted glass rim highlight
    pub const GLASS_BTN_BG: u32    = 0x00243044; // Translucent button fill
    pub const GLASS_BTN_BORDER: u32= 0x00B0D0F0; // Button rim border

    // Sky Base Colors
    pub const SKY_BASE_TOP: u32    = 0x004C8BE0; // Light blue sky base top
    pub const SKY_BASE_BOT: u32    = 0x0082BEF5; // Light blue sky base bottom

    // Legacy Palette Constants (Retained for compatibility)
    pub const FF_LIGHT_BLUE: u32   = 0x001850A8;
    pub const FF_MID_BLUE: u32     = 0x000A2268;
    pub const FF_DARK_BLUE: u32    = 0x00061440;
    pub const FF_BLACK_CORNER: u32 = 0x0000020A;

    // Border Bevel Palette (Retained for backwards compatibility)
    pub const BORDER_OUTER: u32    = 0x00202838;
    pub const BORDER_HIGHLIGHT: u32= 0x00F0F4FF;
    pub const BORDER_SHADOW: u32   = 0x00506078;
    pub const BORDER_INNER: u32    = 0x00060A14;

    // UI Accent Palette
    pub const ACCENT_GOLD: u32     = 0x00F8D040; // Title / branding accent
    pub const ACCENT_CYAN: u32     = 0x0038D8E8; // Active selection / glow cyan
    pub const ACCENT_GREEN: u32    = 0x0028D060; // Success / privileged badge
    pub const ACCENT_AMBER: u32    = 0x00E0A020; // Warning / unprivileged badge
    pub const ACCENT_RED: u32      = 0x00E03838; // Power / alert
    pub const TEXT_MUTED: u32      = 0x008090A8; // Dimmed / secondary text
    pub const DESKTOP_BG: u32      = 0x004C8BE0; // Light blue base

    // Window Pane and Widget Elements
    pub const GLASS_DIVIDER: u32   = 0x003A4B62; // Divider under window titles
    pub const INPUT_BG: u32        = 0x000F1522; // Inset text / tick box background
    pub const TRACK_BG: u32        = 0x000C121D; // Slider track groove background
    pub const THUMB_BG: u32        = 0x00D0DCF0; // Slider thumb default fill
    pub const BTN_PRESS_BG: u32    = 0x003A4C68; // Button active depressed fill
    pub const BTN_HOVER_BG: u32    = 0x002C3B52; // Button hover / focused fill
    pub const BTN_NORMAL_BG: u32   = 0x001C2638; // Button normal fill

    // Tab Bar Palette
    pub const TAB_DIVIDER: u32         = 0x003A4C64; // Horizontal divider under tab bar
    pub const TAB_ACTIVE_BG: u32       = 0x002A3C54; // Active tab pill fill
    pub const TAB_INACTIVE_BG: u32     = 0x00101824; // Inactive tab pill fill
    pub const TAB_INACTIVE_BORDER: u32 = 0x0024344A; // Inactive tab pill border
    pub const GRADIENT_BOT_DEFAULT: u32= 0x000C1836; // Default backdrop bottom color
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
        return px >= self.x0 and px < self.x1 and py >= self.y0 and py < self.y1;
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

// Fast ARGB pixel alpha blend
pub fn blendPixel(bg: u32, fg: u32, alpha: u8) u32 {
    if (alpha == 255) return fg;
    if (alpha == 0) return bg;
    const inv_alpha: u32 = 255 - alpha;
    const a: u32 = alpha;
    const fg_r = (fg >> 16) & 0xFF;
    const fg_g = (fg >> 8) & 0xFF;
    const fg_b = fg & 0xFF;

    const bg_r = (bg >> 16) & 0xFF;
    const bg_g = (bg >> 8) & 0xFF;
    const bg_b = bg & 0xFF;

    const r = (fg_r * a + bg_r * inv_alpha) >> 8;
    const g = (fg_g * a + bg_g * inv_alpha) >> 8;
    const b = (fg_b * a + bg_b * inv_alpha) >> 8;
    return (r << 16) | (g << 8) | b;
}

pub const CLOUD_MAP: []const u8 = @embedFile("cloud_map.bin");

// Evaluates the deterministic background pixel at (x, y) on the screen.
// Linear vertical gradient with subtle static white cloud texture (deterministic Perlin map).
pub fn getBackdropPixel(x: i32, y: i32, width: u32, height: u32, top_color: u32, bot_color: u32) u32 {
    const cx = std.math.clamp(x, 0, @as(i32, @intCast(if (width > 0) width - 1 else 0)));
    const cy = std.math.clamp(y, 0, @as(i32, @intCast(if (height > 0) height - 1 else 0)));

    const top_r: i32 = @intCast((top_color >> 16) & 0xFF);
    const top_g: i32 = @intCast((top_color >> 8) & 0xFF);
    const top_b: i32 = @intCast(top_color & 0xFF);

    const bot_r: i32 = @intCast((bot_color >> 16) & 0xFF);
    const bot_g: i32 = @intCast((bot_color >> 8) & 0xFF);
    const bot_b: i32 = @intCast(bot_color & 0xFF);

    const den_y = @as(i32, @intCast(if (height > 1) height - 1 else 1));
    const r_base: u32 = @intCast(std.math.clamp(top_r + @divTrunc((bot_r - top_r) * cy, den_y), 0, 255));
    const g_base: u32 = @intCast(std.math.clamp(top_g + @divTrunc((bot_g - top_g) * cy, den_y), 0, 255));
    const b_base: u32 = @intCast(std.math.clamp(top_b + @divTrunc((bot_b - top_b) * cy, den_y), 0, 255));

    const ucy = @as(usize, @intCast(cy));
    const ucx = @as(usize, @intCast(cx));
    const map_y1 = (ucy & 0xFF) * 256;
    const map_y2 = ((ucy * 2) & 0xFF) * 256;
    const map_x1 = ucx & 0xFF;
    const map_x2 = (ucx * 2) & 0xFF;

    const c1 = @as(u32, CLOUD_MAP[map_y1 + map_x1]);
    const c2 = @as(u32, CLOUD_MAP[map_y2 + map_x2]);

    const cd = (c1 * 3 + c2 * 2) / 5;
    const cloud_alpha = (cd * 90) >> 8;
    const inv_alpha = 255 - cloud_alpha;

    const r = (r_base * inv_alpha + 255 * cloud_alpha) >> 8;
    const g = (g_base * inv_alpha + 255 * cloud_alpha) >> 8;
    const b = (b_base * inv_alpha + 255 * cloud_alpha) >> 8;

    return (r << 16) | (g << 8) | b;
}

pub const MAX_BLUR_RADIUS: u32 = 16;
pub const MAX_KERNEL_LEN: usize = MAX_BLUR_RADIUS * 2 + 1;
pub const FP_ONE: u32 = 1 << 16; // 65536 in 16.16 fixed point

// Precomputes fixed-point 1D Gaussian kernel weights summing to exactly FP_ONE (65536).
pub fn computeGaussianKernel(radius: u32, kernel_out: []u32) void {
    if (radius == 0 or kernel_out.len == 0) {
        if (kernel_out.len > 0) kernel_out[0] = FP_ONE;
        return;
    }
    const r_f: f32 = @floatFromInt(radius);
    const sigma: f32 = r_f * 0.5 + 0.5;
    const two_sigma_sq = 2.0 * sigma * sigma;

    var sum_f: f32 = 0.0;
    const k_len = radius * 2 + 1;
    var weights_f: [MAX_KERNEL_LEN]f32 = undefined;

    var i: usize = 0;
    while (i < k_len and i < weights_f.len) : (i += 1) {
        const d: f32 = @as(f32, @floatFromInt(i)) - r_f;
        const w = std.math.exp(-(d * d) / two_sigma_sq);
        weights_f[i] = w;
        sum_f += w;
    }

    if (sum_f <= 0.0) {
        if (radius < kernel_out.len) kernel_out[radius] = FP_ONE;
        return;
    }

    const fp_scale: f32 = @floatFromInt(FP_ONE);
    var int_sum: u32 = 0;
    i = 0;
    while (i < k_len and i < kernel_out.len) : (i += 1) {
        const norm = (weights_f[i] / sum_f) * fp_scale;
        const w_int: u32 = @intFromFloat(norm);
        kernel_out[i] = w_int;
        int_sum += w_int;
    }

    if (int_sum != FP_ONE and radius < kernel_out.len) {
        const diff: i32 = @as(i32, @intCast(FP_ONE)) - @as(i32, @intCast(int_sum));
        const center = radius;
        const new_center = @as(i32, @intCast(kernel_out[center])) + diff;
        kernel_out[center] = @intCast(@max(0, new_center));
    }
}

pub const Surface = struct {
    pixels: [*]u32,
    width: u32,
    height: u32,
    stride: usize, // Stride in bytes
    clip: Box,

    pub fn init(pixels: [*]u32, width: u32, height: u32, stride: usize) Surface {
        return .{
            .pixels = pixels,
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

    pub fn setPixel(self: *Surface, x: i32, y: i32, color: u32) void {
        if (!self.clip.contains(x, y)) return;
        const row_start = @as(usize, @intCast(y)) * self.stridePixels();
        const col = @as(usize, @intCast(x));
        self.pixels[row_start + col] = color;
    }

    pub fn getPixel(self: *const Surface, x: i32, y: i32) u32 {
        if (x < 0 or y < 0 or x >= @as(i32, @intCast(self.width)) or y >= @as(i32, @intCast(self.height))) return 0;
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
            const row_offset = @as(usize, @intCast(y)) * pixels_per_row + @as(usize, @intCast(active.x0));
            @memset(self.pixels[row_offset .. row_offset + fill_len], color);
        }
    }

    pub fn fillRect(self: *Surface, rect: Rect, color: u32) void {
        self.fillBox(Box.fromPosSize(rect.x, rect.y, rect.width, rect.height), color);
    }

    pub fn drawBoxOutline(self: *Surface, target: Box, thickness: u32, color: u32) void {
        const t = @as(i32, @intCast(thickness));
        if (t <= 0) return;

        // Top line
        self.fillBox(.{ .x0 = target.x0, .y0 = target.y0, .x1 = target.x1, .y1 = target.y0 + t }, color);
        // Bottom line
        self.fillBox(.{ .x0 = target.x0, .y0 = target.y1 - t, .x1 = target.x1, .y1 = target.y1 }, color);
        // Left line
        self.fillBox(.{ .x0 = target.x0, .y0 = target.y0 + t, .x1 = target.x0 + t, .y1 = target.y1 - t }, color);
        // Right line
        self.fillBox(.{ .x0 = target.x1 - t, .y0 = target.y0 + t, .x1 = target.x1, .y1 = target.y1 - t }, color);
    }

    // Static graduated background constrained to target box
    pub fn drawGraduatedBackgroundInBox(self: *Surface, target: Box, top_color: u32, bot_color: u32) void {
    const h = self.height;
    const w = self.width;
    if (h == 0 or w == 0 or target.isEmpty()) return;

    const clipped = target.intersect(Box.fromPosSize(0, 0, w, h));
    if (clipped.isEmpty()) return;

    const top_r: i32 = @intCast((top_color >> 16) & 0xFF);
    const top_g: i32 = @intCast((top_color >> 8) & 0xFF);
    const top_b: i32 = @intCast(top_color & 0xFF);

    const bot_r: i32 = @intCast((bot_color >> 16) & 0xFF);
    const bot_g: i32 = @intCast((bot_color >> 8) & 0xFF);
    const bot_b: i32 = @intCast(bot_color & 0xFF);

    const pixels_per_row = self.stridePixels();
    const den_y = @as(i32, @intCast(if (h > 1) h - 1 else 1));

    const x0 = @as(usize, @intCast(clipped.x0));
    const x1 = @as(usize, @intCast(clipped.x1));
    const y0 = @as(usize, @intCast(clipped.y0));
    const y1 = @as(usize, @intCast(clipped.y1));

    var y: usize = y0;
    while (y < y1) : (y += 1) {
        const vy: i32 = @intCast(y);
        const r_base: u32 = @intCast(std.math.clamp(top_r + @divTrunc((bot_r - top_r) * vy, den_y), 0, 255));
        const g_base: u32 = @intCast(std.math.clamp(top_g + @divTrunc((bot_g - top_g) * vy, den_y), 0, 255));
        const b_base: u32 = @intCast(std.math.clamp(top_b + @divTrunc((bot_b - top_b) * vy, den_y), 0, 255));

        const map_y1 = (y & 0xFF) * 256;
        const map_y2 = ((y * 2) & 0xFF) * 256;

        const row_offset = y * pixels_per_row;
        var x: usize = x0;
        while (x < x1) : (x += 1) {
            const map_x1 = x & 0xFF;
            const map_x2 = (x * 2) & 0xFF;

            const c1 = @as(u32, CLOUD_MAP[map_y1 + map_x1]);
            const c2 = @as(u32, CLOUD_MAP[map_y2 + map_x2]);

            const cd = (c1 * 3 + c2 * 2) / 5;
            const cloud_alpha = (cd * 90) >> 8;
            const inv_alpha = 255 - cloud_alpha;

            const r = (r_base * inv_alpha + 255 * cloud_alpha) >> 8;
            const g = (g_base * inv_alpha + 255 * cloud_alpha) >> 8;
            const b = (b_base * inv_alpha + 255 * cloud_alpha) >> 8;

            self.pixels[row_offset + x] = (r << 16) | (g << 8) | b;
        }
    }
}

// Deterministic 2-pass separable Gaussian blur applied to the backdrop in target box.
// window_box (optional) supplies the outer window geometry for corner_radius checking,
// ensuring that damaged sub-regions inside a window retain identical corner behavior.
pub fn drawBlurredBackdropInBox(
    self: *Surface,
    target: Box,
    window_box: ?Box,
    top_color: u32,
    bot_color: u32,
    radius: u32,
    corner_radius: u32,
    scratch: []u32,
) void {
    const h = self.height;
    const w = self.width;
    if (h == 0 or w == 0 or target.isEmpty()) return;

    const screen_box = Box.fromPosSize(0, 0, w, h);
    const clipped = target.intersect(screen_box);
    if (clipped.isEmpty()) return;

    if (radius == 0) {
        self.drawGraduatedBackgroundInBox(clipped, top_color, bot_color);
        return;
    }

    const r_blur = std.math.clamp(radius, 1, 16);
    var kernel: [33]u32 = undefined;
    computeGaussianKernel(r_blur, kernel[0 .. r_blur * 2 + 1]);
    const kernel_len = r_blur * 2 + 1;

    const x0 = clipped.x0;
    const x1 = clipped.x1;
    const y0 = clipped.y0;
    const y1 = clipped.y1;
    const width_int: usize = @intCast(x1 - x0);

    const r_int: i32 = @intCast(r_blur);
    const y_start = y0 - r_int;
    const y_end = y1 + r_int;
    const num_scratch_rows: usize = @intCast(y_end - y_start);

    if (scratch.len < width_int * num_scratch_rows) {
        // Scratch buffer insufficient, fallback to unblurred
        self.drawGraduatedBackgroundInBox(clipped, top_color, bot_color);
        return;
    }

    // Pass 1: Horizontal 1D Gaussian convolution across [y_start, y_end)
    const top_r: i32 = @intCast((top_color >> 16) & 0xFF);
    const top_g: i32 = @intCast((top_color >> 8) & 0xFF);
    const top_b: i32 = @intCast(top_color & 0xFF);

    const bot_r: i32 = @intCast((bot_color >> 16) & 0xFF);
    const bot_g: i32 = @intCast((bot_color >> 8) & 0xFF);
    const bot_b: i32 = @intCast(bot_color & 0xFF);

    const den_y = @as(i32, @intCast(if (h > 1) h - 1 else 1));
    const max_w: i32 = @intCast(if (w > 0) w - 1 else 0);

    var y_iter = y_start;
    var src_row_buf: [2048]u32 = undefined;
    const src_row_len = width_int + @as(usize, @intCast(r_blur * 2));
    if (src_row_len > src_row_buf.len) {
        self.drawGraduatedBackgroundInBox(clipped, top_color, bot_color);
        return;
    }

    while (y_iter < y_end) : (y_iter += 1) {
        const cy = std.math.clamp(y_iter, 0, @as(i32, @intCast(h - 1)));
        const scratch_row_idx = @as(usize, @intCast(y_iter - y_start)) * width_int;

        // Precompute row-invariant gradient base and Y map offsets once per row
        const r_base: u32 = @intCast(std.math.clamp(top_r + @divTrunc((bot_r - top_r) * cy, den_y), 0, 255));
        const g_base: u32 = @intCast(std.math.clamp(top_g + @divTrunc((bot_g - top_g) * cy, den_y), 0, 255));
        const b_base: u32 = @intCast(std.math.clamp(top_b + @divTrunc((bot_b - top_b) * cy, den_y), 0, 255));
        const ucy = @as(usize, @intCast(cy));
        const map_y1 = (ucy & 0xFF) * 256;
        const map_y2 = ((ucy * 2) & 0xFF) * 256;

        // Pre-sample source backdrop row for x in [x0 - r_blur, x1 + r_blur)
        var si: usize = 0;
        var sx_iter = x0 - r_int;
        const sx_end = x1 + r_int;
        while (sx_iter < sx_end and si < src_row_len and si < src_row_buf.len) : ({
            sx_iter += 1;
            si += 1;
        }) {
            const ucx = @as(usize, @intCast(std.math.clamp(sx_iter, 0, max_w)));
            const map_x1 = ucx & 0xFF;
            const map_x2 = (ucx * 2) & 0xFF;

            const c1 = @as(u32, CLOUD_MAP[map_y1 + map_x1]);
            const c2 = @as(u32, CLOUD_MAP[map_y2 + map_x2]);

            const cd = (c1 * 3 + c2 * 2) / 5;
            const cloud_alpha = (cd * 90) >> 8;
            const inv_alpha = 255 - cloud_alpha;

            const r = (r_base * inv_alpha + 255 * cloud_alpha) >> 8;
            const g = (g_base * inv_alpha + 255 * cloud_alpha) >> 8;
            const b = (b_base * inv_alpha + 255 * cloud_alpha) >> 8;

            src_row_buf[si] = (r << 16) | (g << 8) | b;
        }

        // Convolve horizontally
        var x_rel: usize = 0;
        while (x_rel < width_int) : (x_rel += 1) {
            var sum_r: u32 = 0;
            var sum_g: u32 = 0;
            var sum_b: u32 = 0;

            var k_idx: usize = 0;
            while (k_idx < kernel_len) : (k_idx += 1) {
                const p = src_row_buf[x_rel + k_idx];
                const weight = kernel[k_idx];
                sum_r += ((p >> 16) & 0xFF) * weight;
                sum_g += ((p >> 8) & 0xFF) * weight;
                sum_b += (p & 0xFF) * weight;
            }

            const hr = (sum_r >> 16);
            const hg = (sum_g >> 16);
            const hb = (sum_b >> 16);
            scratch[scratch_row_idx + x_rel] = (hr << 16) | (hg << 8) | hb;
        }
    }

    // Pass 2: Vertical 1D Gaussian convolution into self.pixels
    // Respects corner_radius geometry so outside the rounded corner stays unblurred backdrop.
    const win_geom = window_box orelse target;
    const cr: i32 = @intCast(corner_radius);
    const cr_sq = cr * cr;
    const pixels_per_row = self.stridePixels();

    var y: i32 = y0;
    while (y < y1) : (y += 1) {
        const uy: usize = @intCast(y);
        const dst_row_offset = uy * pixels_per_row;
        const is_top_corner = (cr > 0 and y < win_geom.y0 + cr);
        const is_bot_corner = (cr > 0 and y >= win_geom.y1 - cr);
        const is_corner_row = is_top_corner or is_bot_corner;
        const y_rel: usize = @intCast(y - y_start);
        const base_sample_y_rel: usize = @intCast(@as(i32, @intCast(y_rel)) - r_int);

        if (!is_corner_row) {
            // Fast path: Row has no rounded corners, convolve all pixels directly
            var x: i32 = x0;
            var x_rel: usize = 0;
            while (x < x1) : ({
                x += 1;
                x_rel += 1;
            }) {
                const dst_idx = dst_row_offset + @as(usize, @intCast(x));
                var sum_r: u32 = 0;
                var sum_g: u32 = 0;
                var sum_b: u32 = 0;

                var scratch_ptr = base_sample_y_rel * width_int + x_rel;
                var k_idx: usize = 0;
                while (k_idx < kernel_len) : (k_idx += 1) {
                    const hp = scratch[scratch_ptr];
                    scratch_ptr += width_int;
                    const weight = kernel[k_idx];
                    sum_r += ((hp >> 16) & 0xFF) * weight;
                    sum_g += ((hp >> 8) & 0xFF) * weight;
                    sum_b += (hp & 0xFF) * weight;
                }

                const vr = (sum_r >> 16);
                const vg = (sum_g >> 16);
                const vb = (sum_b >> 16);
                self.pixels[dst_idx] = (vr << 16) | (vg << 8) | vb;
            }
        } else {
            // Corner row: test rounded corner curvature
            var x: i32 = x0;
            var x_rel: usize = 0;
            while (x < x1) : ({
                x += 1;
                x_rel += 1;
            }) {
                var inside_corner = true;
                if (is_top_corner) {
                    const dy = (win_geom.y0 + cr) - y;
                    if (x < win_geom.x0 + cr) {
                        const dx = (win_geom.x0 + cr) - x;
                        if (dx * dx + dy * dy > cr_sq) inside_corner = false;
                    } else if (x >= win_geom.x1 - cr) {
                        const dx = x - (win_geom.x1 - cr - 1);
                        if (dx * dx + dy * dy > cr_sq) inside_corner = false;
                    }
                } else {
                    const dy = y - (win_geom.y1 - cr - 1);
                    if (x < win_geom.x0 + cr) {
                        const dx = (win_geom.x0 + cr) - x;
                        if (dx * dx + dy * dy > cr_sq) inside_corner = false;
                    } else if (x >= win_geom.x1 - cr) {
                        const dx = x - (win_geom.x1 - cr - 1);
                        if (dx * dx + dy * dy > cr_sq) inside_corner = false;
                    }
                }

                const dst_idx = dst_row_offset + @as(usize, @intCast(x));
                if (!inside_corner) {
                    self.pixels[dst_idx] = getBackdropPixel(x, y, w, h, top_color, bot_color);
                } else {
                    var sum_r: u32 = 0;
                    var sum_g: u32 = 0;
                    var sum_b: u32 = 0;

                    var scratch_ptr = base_sample_y_rel * width_int + x_rel;
                    var k_idx: usize = 0;
                    while (k_idx < kernel_len) : (k_idx += 1) {
                        const hp = scratch[scratch_ptr];
                        scratch_ptr += width_int;
                        const weight = kernel[k_idx];
                        sum_r += ((hp >> 16) & 0xFF) * weight;
                        sum_g += ((hp >> 8) & 0xFF) * weight;
                        sum_b += (hp & 0xFF) * weight;
                    }

                    const vr = (sum_r >> 16);
                    const vg = (sum_g >> 16);
                    const vb = (sum_b >> 16);
                    self.pixels[dst_idx] = (vr << 16) | (vg << 8) | vb;
                }
            }
        }
    }
}

// Static graduated background from top_color down to bot_color
pub fn drawGraduatedBackground(self: *Surface, top_color: u32, bot_color: u32) void {
    self.drawGraduatedBackgroundInBox(Box.fromPosSize(0, 0, self.width, self.height), top_color, bot_color);
}

    // Copy rectangular region from src surface to this surface
    pub fn copyBoxFrom(self: *Surface, src: *const Surface, box: Box) void {
        const x0 = @max(0, box.x0);
        const y0 = @max(0, box.y0);
        const x1 = @min(@as(i32, @intCast(self.width)), @min(@as(i32, @intCast(src.width)), box.x1));
        const y1 = @min(@as(i32, @intCast(self.height)), @min(@as(i32, @intCast(src.height)), box.y1));
        if (x0 >= x1 or y0 >= y1) return;

        const w: usize = @intCast(x1 - x0);
        const dst_stride_pixels = self.stridePixels();
        const src_stride_pixels = src.stridePixels();

        var y: usize = @intCast(y0);
        const end_y: usize = @intCast(y1);
        const ux0: usize = @intCast(x0);

        const max_dst_pixels = self.height * dst_stride_pixels;
        const max_src_pixels = src.height * src_stride_pixels;

        while (y < end_y) : (y += 1) {
            const dst_start = std.math.mul(usize, y, dst_stride_pixels) catch break;
            const dst_offset = std.math.add(usize, dst_start, ux0) catch break;
            const dst_end = std.math.add(usize, dst_offset, w) catch break;

            const src_start = std.math.mul(usize, y, src_stride_pixels) catch break;
            const src_offset = std.math.add(usize, src_start, ux0) catch break;
            const src_end = std.math.add(usize, src_offset, w) catch break;

            if (dst_end > max_dst_pixels or src_end > max_src_pixels) break;
            @memcpy(self.pixels[dst_offset..dst_end], src.pixels[src_offset..src_end]);
        }
    }

    // Render animated subtle white clouds on a light blue base using Perlin noise map
    pub fn drawAnimatedClouds(
        self: *Surface,
        drift1_x: i32,
        drift1_y: i32,
        drift2_x: i32,
        drift2_y: i32,
    ) void {
        const pixels_per_row = self.stridePixels();
        const h = self.height;
        const w = self.width;

        var y: u32 = 0;
        while (y < h) : (y += 1) {
            const y_int: i32 = @intCast(y);
            // Linear vertical sky gradient from SKY_BASE_TOP to SKY_BASE_BOT
            const sky_r: u32 = @intCast(76 + @divTrunc((130 - 76) * y_int, @as(i32, @intCast(h))));
            const sky_g: u32 = @intCast(139 + @divTrunc((190 - 139) * y_int, @as(i32, @intCast(h))));
            const sky_b: u32 = @intCast(224 + @divTrunc((245 - 224) * y_int, @as(i32, @intCast(h))));

            const row_offset = @as(usize, @intCast(y)) * pixels_per_row;

            const map_y1 = @as(usize, @intCast(@mod(y_int + drift1_y, 256))) * 256;
            const map_y2 = @as(usize, @intCast(@mod(y_int * 2 + drift2_y, 256))) * 256;

            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const x_int: i32 = @intCast(x);
                const map_x1 = @as(usize, @intCast(@mod(x_int + drift1_x, 256)));
                const map_x2 = @as(usize, @intCast(@mod(x_int * 2 + drift2_x, 256)));

                const c1 = @as(u32, CLOUD_MAP[map_y1 + map_x1]);
                const c2 = @as(u32, CLOUD_MAP[map_y2 + map_x2]);

                // Blend dual drifting cloud layers
                const cd = (c1 * 3 + c2 * 2) / 5;
                // Subtle white clouds (coverage ~43% max)
                const alpha = (cd * 110) >> 8;
                const inv_alpha = 255 - alpha;

                const r = (sky_r * inv_alpha + 255 * alpha) >> 8;
                const g = (sky_g * inv_alpha + 255 * alpha) >> 8;
                const b = (sky_b * inv_alpha + 255 * alpha) >> 8;

                self.pixels[row_offset + x] = (r << 16) | (g << 8) | b;
            }
        }
    }

    // Draw rounded translucent box (80% opaque, 20% transparent)
    // with subtle rounded corners (radius) and smooth frosted border
    pub fn drawRoundedTranslucentBox(
        self: *Surface,
        box: Box,
        radius: u32,
        fill_color: u32,
        alpha: u8,
        border_color: ?u32,
    ) void {
        const active = box.intersect(self.clip);
        if (active.isEmpty()) return;

        const r: i32 = @intCast(radius);
        const r_sq = r * r;
        const inner_r_sq = if (r > 1) (r - 1) * (r - 1) else 0;
        const x0 = box.x0;
        const y0 = box.y0;
        const x1 = box.x1;
        const y1 = box.y1;

        const pixels_per_row = self.stridePixels();

        var y = active.y0;
        while (y < active.y1) : (y += 1) {
            const row_offset = @as(usize, @intCast(y)) * pixels_per_row;
            const is_top_corner = (y < y0 + r);
            const is_bot_corner = (y >= y1 - r);

            var x = active.x0;
            while (x < active.x1) : (x += 1) {
                var inside = true;
                var is_border_pixel = false;

                if (is_top_corner) {
                    const dy = (y0 + r) - y;
                    if (x < x0 + r) {
                        const dx = (x0 + r) - x;
                        const dist_sq = dx * dx + dy * dy;
                        if (dist_sq > r_sq) inside = false;
                        if (dist_sq <= r_sq and dist_sq > inner_r_sq) is_border_pixel = true;
                    } else if (x >= x1 - r) {
                        const dx = x - (x1 - r - 1);
                        const dist_sq = dx * dx + dy * dy;
                        if (dist_sq > r_sq) inside = false;
                        if (dist_sq <= r_sq and dist_sq > inner_r_sq) is_border_pixel = true;
                    }
                } else if (is_bot_corner) {
                    const dy = y - (y1 - r - 1);
                    if (x < x0 + r) {
                        const dx = (x0 + r) - x;
                        const dist_sq = dx * dx + dy * dy;
                        if (dist_sq > r_sq) inside = false;
                        if (dist_sq <= r_sq and dist_sq > inner_r_sq) is_border_pixel = true;
                    } else if (x >= x1 - r) {
                        const dx = x - (x1 - r - 1);
                        const dist_sq = dx * dx + dy * dy;
                        if (dist_sq > r_sq) inside = false;
                        if (dist_sq <= r_sq and dist_sq > inner_r_sq) is_border_pixel = true;
                    }
                }

                if (!inside) continue;

                if (border_color != null) {
                    if (y == y0 or y == y1 - 1 or x == x0 or x == x1 - 1) {
                        is_border_pixel = true;
                    }
                }

                const col_idx = row_offset + @as(usize, @intCast(x));
                const bg = self.pixels[col_idx];

                if (is_border_pixel and border_color != null) {
                    self.pixels[col_idx] = blendPixel(bg, border_color.?, 160);
                } else {
                    self.pixels[col_idx] = blendPixel(bg, fill_color, alpha);
                }
            }
        }
    }

    // Complete window drawing: 80% opaque, 20% transparent neutral glass pane with subtly rounded corners
    pub fn drawWindowPane(self: *Surface, box: Box) void {
        self.drawRoundedTranslucentBox(box, 10, Color.GLASS_BG, Color.GLASS_OPACITY, Color.GLASS_BORDER);
    }
};

test "framebuffer: blendPixel" {
    const testing = std.testing;
    const bg: u32 = 0x00000000;
    const fg: u32 = 0x00FFFFFF;
    try testing.expectEqual(@as(u32, 0x00000000), blendPixel(bg, fg, 0));
    try testing.expectEqual(@as(u32, 0x00FFFFFF), blendPixel(bg, fg, 255));
    const half = blendPixel(bg, fg, 128);
    const r = (half >> 16) & 0xFF;
    try testing.expect(r >= 127 and r <= 129);
}

test "framebuffer: box geometry" {
    const testing = std.testing;
    const b1 = Box.fromPosSize(10, 10, 100, 50);
    try testing.expectEqual(@as(u32, 100), b1.width());
    try testing.expectEqual(@as(u32, 50), b1.height());
    try testing.expect(b1.contains(50, 30));
    try testing.expect(!b1.contains(5, 5));
}

test "framebuffer: gaussian kernel weights sum to 65536" {
    const testing = std.testing;
    const radii = [_]u32{ 0, 1, 2, 5, 8, 12, 16 };
    for (radii) |r| {
        var k: [33]u32 = undefined;
        const len = if (r == 0) 1 else r * 2 + 1;
        computeGaussianKernel(r, k[0..len]);
        var sum: u32 = 0;
        for (k[0..len]) |w| {
            sum += w;
        }
        try testing.expectEqual(@as(u32, 65536), sum);
    }
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

    const top_col: u32 = 0x004C8BE0;
    const bot_col: u32 = 0x000C1836;
    const win_box = Box.fromPosSize(20, 20, 160, 110);
    const sub_damage_box = Box.fromPosSize(50, 50, 60, 40);

    // 1. Render full window blur on surf1
    surf1.drawBlurredBackdropInBox(win_box, win_box, top_col, bot_col, 5, 10, scratch);

    // 2. Render only sub-damage box on surf2, with window_box geometry passed
    surf2.drawBlurredBackdropInBox(sub_damage_box, win_box, top_col, bot_col, 5, 10, scratch);

    // 3. Compare all pixels within sub_damage_box: must be BIT-FOR-BIT IDENTICAL!
    var y: i32 = sub_damage_box.y0;
    while (y < sub_damage_box.y1) : (y += 1) {
        var x: i32 = sub_damage_box.x0;
        while (x < sub_damage_box.x1) : (x += 1) {
            const idx = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
            try testing.expectEqual(mem1[idx], mem2[idx]);
        }
    }
}

