// Animated Perlin Cloud Backdrop & 2-Pass Separable Blur for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("framebuffer.zig");
const Box = fb.Box;
const Color = fb.Color;
const Surface = fb.Surface;

pub const CLOUD_MAP: []const u8 = @embedFile("cloud_map.bin");
pub const CLOUD_MAP_DIMENSION: usize = 256;
pub const CLOUD_MAP_MASK: usize = CLOUD_MAP_DIMENSION - 1;
// Subtle static cloud coverage (~35%).
pub const CLOUD_BASE_OPACITY: u32 = 90;
// Subtle animated cloud coverage (~43%).
pub const CLOUD_ANIMATED_OPACITY: u32 = 110;

pub const MAX_BLUR_RADIUS: u32 = 16;
pub const MAX_KERNEL_LEN: usize = MAX_BLUR_RADIUS * 2 + 1;
// 65536 in 16.16 fixed point.
pub const FP_ONE: u32 = 1 << 16;

// Blend dual cloud noise samples over base RGB colors with fixed-point math.
pub inline fn blendCloudPixel(
    r_base: u32,
    g_base: u32,
    b_base: u32,
    c1: u32,
    c2: u32,
    max_opacity: u32,
) u32 {
    const cd = (c1 * 3 + c2 * 2) / 5;
    const cloud_alpha = (cd * max_opacity) >> 8;
    const inv_alpha = 255 - cloud_alpha;
    const r = (r_base * inv_alpha + 255 * cloud_alpha) >> 8;
    const g = (g_base * inv_alpha + 255 * cloud_alpha) >> 8;
    const b = (b_base * inv_alpha + 255 * cloud_alpha) >> 8;
    return (r << 16) | (g << 8) | b;
}

const RgbGradient = struct {
    top_r: i32,
    top_g: i32,
    top_b: i32,
    bot_r: i32,
    bot_g: i32,
    bot_b: i32,
    den_y: i32,

    fn init(top_color: u32, bot_color: u32, height: u32) RgbGradient {
        return .{
            .top_r = @intCast((top_color >> 16) & 0xff),
            .top_g = @intCast((top_color >> 8) & 0xff),
            .top_b = @intCast(top_color & 0xff),
            .bot_r = @intCast((bot_color >> 16) & 0xff),
            .bot_g = @intCast((bot_color >> 8) & 0xff),
            .bot_b = @intCast(bot_color & 0xff),
            .den_y = @intCast(if (height > 1) height - 1 else 1),
        };
    }

    inline fn rowBase(self: RgbGradient, y: i32) [3]u32 {
        const dr = @divTrunc((self.bot_r - self.top_r) * y, self.den_y);
        const dg = @divTrunc((self.bot_g - self.top_g) * y, self.den_y);
        const db = @divTrunc((self.bot_b - self.top_b) * y, self.den_y);
        return .{
            @intCast(std.math.clamp(self.top_r + dr, 0, 255)),
            @intCast(std.math.clamp(self.top_g + dg, 0, 255)),
            @intCast(std.math.clamp(self.top_b + db, 0, 255)),
        };
    }
};

inline fn mod256(a: i32, b: i32) usize {
    return @intCast(@mod(@as(i64, a) + @as(i64, b), 256));
}

inline fn sampleCloudRowPixel(
    rgb: [3]u32,
    map_y1: usize,
    map_y2: usize,
    ucx: usize,
    opacity: u32,
) u32 {
    const map_x1 = ucx & CLOUD_MAP_MASK;
    const map_x2 = (ucx * 2) & CLOUD_MAP_MASK;
    const c1 = @as(u32, CLOUD_MAP[map_y1 + map_x1]);
    const c2 = @as(u32, CLOUD_MAP[map_y2 + map_x2]);
    return blendCloudPixel(rgb[0], rgb[1], rgb[2], c1, c2, opacity);
}

// Evaluates the deterministic background pixel at (x, y) on the screen with
// horizontal/vertical drift using a linear vertical gradient and Perlin map.
pub fn getBackdropPixelDrift(
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    top_color: u32,
    bot_color: u32,
    drift_x: i32,
    drift_y: i32,
) u32 {
    const max_x: i32 = @intCast(if (width > 0) width - 1 else 0);
    const max_y: i32 = @intCast(if (height > 0) height - 1 else 0);
    const cx = std.math.clamp(x, 0, max_x);
    const cy = std.math.clamp(y, 0, max_y);

    const grad = RgbGradient.init(top_color, bot_color, height);
    const rgb = grad.rowBase(cy);

    const ucy = mod256(cy, drift_y);
    const ucx = mod256(cx, drift_x);
    const map_y1 = (ucy & CLOUD_MAP_MASK) * CLOUD_MAP_DIMENSION;
    const map_y2 = ((ucy * 2) & CLOUD_MAP_MASK) * CLOUD_MAP_DIMENSION;

    return sampleCloudRowPixel(rgb, map_y1, map_y2, ucx, CLOUD_BASE_OPACITY);
}

pub fn getBackdropPixel(
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    top_col: u32,
    bot_col: u32,
) u32 {
    return getBackdropPixelDrift(x, y, w, h, top_col, bot_col, 0, 0);
}

// Precomputes fixed-point 1D Gaussian kernel weights summing to FP_ONE (65536).
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
        const fp_i32: i32 = @intCast(FP_ONE);
        const diff: i32 = fp_i32 - @as(i32, @intCast(int_sum));
        const center = radius;
        const new_center = @as(i32, @intCast(kernel_out[center])) + diff;
        kernel_out[center] = @intCast(@max(0, new_center));
    }
}

// Graduated background constrained to target box with drift.
pub fn drawGraduatedBackgroundInBoxDrift(
    self: *Surface,
    target: Box,
    top_color: u32,
    bot_color: u32,
    drift_x: i32,
    drift_y: i32,
) void {
    const h = self.height;
    const w = self.width;
    if (h == 0 or w == 0 or target.isEmpty()) return;

    const clipped = target.intersect(self.clip);
    if (clipped.isEmpty()) return;

    const grad = RgbGradient.init(top_color, bot_color, h);
    const pixels_per_row = self.stridePixels();

    const x0: usize = @intCast(@max(0, clipped.x0));
    const x1: usize = @intCast(@max(0, clipped.x1));
    const y0: usize = @intCast(@max(0, clipped.y0));
    const y1: usize = @intCast(@max(0, clipped.y1));

    var y: usize = y0;
    while (y < y1) : (y += 1) {
        const vy: i32 = @intCast(y);
        const rgb = grad.rowBase(vy);
        const vy_drift = mod256(vy, drift_y);
        const map_y1 = (vy_drift & CLOUD_MAP_MASK) * CLOUD_MAP_DIMENSION;
        const map_y2 = ((vy_drift * 2) & CLOUD_MAP_MASK) * CLOUD_MAP_DIMENSION;

        const row_offset = y * pixels_per_row;
        var x: usize = x0;
        while (x < x1) : (x += 1) {
            const vx_drift = mod256(@intCast(x), drift_x);
            self.pixels[row_offset + x] = sampleCloudRowPixel(
                rgb,
                map_y1,
                map_y2,
                vx_drift,
                CLOUD_BASE_OPACITY,
            );
        }
    }
}

pub fn drawGraduatedBackgroundInBox(
    self: *Surface,
    target: Box,
    top_color: u32,
    bot_color: u32,
) void {
    drawGraduatedBackgroundInBoxDrift(self, target, top_color, bot_color, 0, 0);
}

pub fn drawGraduatedBackgroundDrift(
    self: *Surface,
    top_col: u32,
    bot_col: u32,
    dx: i32,
    dy: i32,
) void {
    const full = Box.fromPosSize(0, 0, self.width, self.height);
    drawGraduatedBackgroundInBoxDrift(self, full, top_col, bot_col, dx, dy);
}

pub fn drawGraduatedBackground(self: *Surface, top: u32, bot: u32) void {
    drawGraduatedBackgroundDrift(self, top, bot, 0, 0);
}

// Deterministic 2-pass separable Gaussian blur applied to the backdrop in
// target box with drift. window_box (optional) supplies the outer window
// geometry for corner_radius checking so damaged sub-regions retain corners.
pub fn drawBlurredBackdropInBoxDrift(
    self: *Surface,
    target: Box,
    window_box: ?Box,
    top_col: u32,
    bot_col: u32,
    radius: u32,
    corner_radius: u32,
    scratch: []u32,
    dx: i32,
    dy: i32,
) void {
    const h = self.height;
    const w = self.width;
    if (h == 0 or w == 0 or target.isEmpty()) return;

    const screen_box = Box.fromPosSize(0, 0, w, h);
    const clipped = target.intersect(screen_box);
    if (clipped.isEmpty()) return;

    const r_blur = std.math.clamp(radius, 1, 16);
    const x0 = clipped.x0;
    const x1 = clipped.x1;
    const y0 = clipped.y0;
    const y1 = clipped.y1;
    const width_int: usize = @intCast(x1 - x0);
    const r_int: i32 = @intCast(r_blur);
    const y_start = y0 - r_int;
    const y_end = y1 + r_int;
    const n_rows: usize = @intCast(y_end - y_start);

    var src_row_buf: [4096]u32 = undefined;
    const src_row_len = width_int + @as(usize, @intCast(r_blur * 2));
    if (radius == 0 or scratch.len < width_int * n_rows or
        src_row_len > src_row_buf.len)
    {
        drawGraduatedBackgroundInBoxDrift(
            self,
            clipped,
            top_col,
            bot_col,
            dx,
            dy,
        );
        return;
    }

    var kernel: [33]u32 = undefined;
    computeGaussianKernel(r_blur, kernel[0 .. r_blur * 2 + 1]);
    const kernel_len = r_blur * 2 + 1;

    // Pass 1: Horizontal 1D Gaussian convolution across [y_start, y_end).
    const grad = RgbGradient.init(top_col, bot_col, h);
    const max_w: i32 = @intCast(if (w > 0) w - 1 else 0);

    var y_iter = y_start;
    while (y_iter < y_end) : (y_iter += 1) {
        const cy = std.math.clamp(y_iter, 0, @as(i32, @intCast(h - 1)));
        const row_idx = @as(usize, @intCast(y_iter - y_start)) * width_int;
        const rgb = grad.rowBase(cy);
        const ucy = mod256(cy, dy);
        const map_y1 = (ucy & CLOUD_MAP_MASK) * CLOUD_MAP_DIMENSION;
        const map_y2 = ((ucy * 2) & CLOUD_MAP_MASK) * CLOUD_MAP_DIMENSION;

        var si: usize = 0;
        var sx_iter = x0 - r_int;
        const sx_end = x1 + r_int;
        while (sx_iter < sx_end and si < src_row_len) : ({
            sx_iter += 1;
            si += 1;
        }) {
            const cx_c = std.math.clamp(sx_iter, 0, max_w);
            const ucx = mod256(cx_c, dx);
            const op = CLOUD_BASE_OPACITY;
            src_row_buf[si] = sampleCloudRowPixel(rgb, map_y1, map_y2, ucx, op);
        }

        for (0..width_int) |x_rel| {
            var sum_r: u32 = 0;
            var sum_g: u32 = 0;
            var sum_b: u32 = 0;
            for (0..kernel_len) |k_idx| {
                const p = src_row_buf[x_rel + k_idx];
                const weight = kernel[k_idx];
                sum_r += ((p >> 16) & 0xff) * weight;
                sum_g += ((p >> 8) & 0xff) * weight;
                sum_b += (p & 0xff) * weight;
            }
            scratch[row_idx + x_rel] =
                ((sum_r >> 16) << 16) | ((sum_g >> 16) << 8) | (sum_b >> 16);
        }
    }

    // Pass 2: Vertical 1D Gaussian convolution into self.pixels.
    const win_geom = window_box orelse target;
    const cr: i32 = @intCast(corner_radius);
    const cr_sq = cr * cr;
    const pixels_per_row = self.stridePixels();

    var y: i32 = y0;
    while (y < y1) : (y += 1) {
        const dst_row_offset = @as(usize, @intCast(y)) * pixels_per_row;
        const base_y_rel: usize = @intCast((y - y_start) - r_int);

        for (0..width_int) |x_rel| {
            const x = x0 + @as(i32, @intCast(x_rel));
            const dst_idx = dst_row_offset + @as(usize, @intCast(x));
            if (fb.cornerDistMetric(x, y, win_geom, cr, cr_sq, true)) |dist_m| {
                if (dist_m > cr_sq) {
                    self.pixels[dst_idx] = getBackdropPixelDrift(
                        x,
                        y,
                        w,
                        h,
                        top_col,
                        bot_col,
                        dx,
                        dy,
                    );
                    continue;
                }
            }

            var sum_r: u32 = 0;
            var sum_g: u32 = 0;
            var sum_b: u32 = 0;
            var scratch_ptr = base_y_rel * width_int + x_rel;
            for (0..kernel_len) |k_idx| {
                const hp = scratch[scratch_ptr];
                scratch_ptr += width_int;
                const weight = kernel[k_idx];
                sum_r += ((hp >> 16) & 0xff) * weight;
                sum_g += ((hp >> 8) & 0xff) * weight;
                sum_b += (hp & 0xff) * weight;
            }
            self.pixels[dst_idx] =
                ((sum_r >> 16) << 16) | ((sum_g >> 16) << 8) | (sum_b >> 16);
        }
    }
}

pub fn drawBlurredBackdropInBox(
    self: *Surface,
    target: Box,
    win_box: ?Box,
    top: u32,
    bot: u32,
    r: u32,
    cr: u32,
    scratch: []u32,
) void {
    drawBlurredBackdropInBoxDrift(
        self,
        target,
        win_box,
        top,
        bot,
        r,
        cr,
        scratch,
        0,
        0,
    );
}

// Render animated subtle white clouds on a light blue base using Perlin map.
pub fn drawAnimatedClouds(
    self: *Surface,
    d1x: i32,
    d1y: i32,
    d2x: i32,
    d2y: i32,
) void {
    const pixels_per_row = self.stridePixels();
    const h = self.height;
    const w = self.width;
    if (h == 0 or w == 0) return;

    const grad = RgbGradient.init(Color.SKY_BASE_TOP, Color.SKY_BASE_BOT, h);
    const dim: i32 = @intCast(CLOUD_MAP_DIMENSION);

    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const y_int: i32 = @intCast(y);
        const rgb = grad.rowBase(y_int);
        const row_offset = @as(usize, @intCast(y)) * pixels_per_row;
        const my1: usize = @intCast(@mod(y_int + d1y, dim));
        const my2: usize = @intCast(@mod(y_int * 2 + d2y, dim));
        const map_y1 = my1 * CLOUD_MAP_DIMENSION;
        const map_y2 = my2 * CLOUD_MAP_DIMENSION;

        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const x_int: i32 = @intCast(x);
            const map_x1: usize = @intCast(@mod(x_int + d1x, dim));
            const map_x2: usize = @intCast(@mod(x_int * 2 + d2x, dim));
            const c1 = @as(u32, CLOUD_MAP[map_y1 + map_x1]);
            const c2 = @as(u32, CLOUD_MAP[map_y2 + map_x2]);
            const op = CLOUD_ANIMATED_OPACITY;
            self.pixels[row_offset + x] =
                blendCloudPixel(rgb[0], rgb[1], rgb[2], c1, c2, op);
        }
    }
}

test "backdrop: gaussian kernel weights sum to 65536" {
    const testing = std.testing;
    const radii = [_]u32{ 0, 1, 2, 5, 8, 12, 16 };
    for (radii) |r| {
        var k: [33]u32 = undefined;
        const len = if (r == 0) 1 else r * 2 + 1;
        computeGaussianKernel(r, k[0..len]);
        var sum: u32 = 0;
        for (k[0..len]) |w| sum += w;
        try testing.expectEqual(@as(u32, 65536), sum);
    }
}

test "backdrop: cloud map tessellation and periodic continuity" {
    try std.testing.expectEqual(@as(usize, 65536), CLOUD_MAP.len);
    var max_seam_x: u32 = 0;
    var max_seam_y: u32 = 0;
    for (0..256) |y| {
        const left = @as(i32, CLOUD_MAP[y * 256 + 0]);
        const right = @as(i32, CLOUD_MAP[y * 256 + 255]);
        const d: u32 = @intCast(@abs(left - right));
        if (d > max_seam_x) max_seam_x = d;
    }
    for (0..256) |x| {
        const top = @as(i32, CLOUD_MAP[0 * 256 + x]);
        const bot = @as(i32, CLOUD_MAP[255 * 256 + x]);
        const d: u32 = @intCast(@abs(top - bot));
        if (d > max_seam_y) max_seam_y = d;
    }
    try std.testing.expect(max_seam_x <= 20);
    try std.testing.expect(max_seam_y <= 20);
}
