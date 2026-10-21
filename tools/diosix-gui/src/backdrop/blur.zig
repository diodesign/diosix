// 2-Pass Separable Gaussian Blur Engine for Diosix GUI Backdrop.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("../framebuffer.zig");
const backdrop = @import("../backdrop.zig");
const Box = fb.Box;
const Color = fb.Color;
const Surface = fb.Surface;
const RgbGradient = backdrop.RgbGradient;

pub const MAX_BLUR_RADIUS = backdrop.MAX_BLUR_RADIUS;
pub const MAX_KERNEL_LEN = backdrop.MAX_KERNEL_LEN;
pub const FP_ONE = backdrop.FP_ONE;
pub const CLOUD_MAP_MASK = backdrop.CLOUD_MAP_MASK;
pub const CLOUD_MAP_DIMENSION = backdrop.CLOUD_MAP_DIMENSION;
pub const CLOUD_BASE_OPACITY = backdrop.CLOUD_BASE_OPACITY;

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

    const r_blur = std.math.clamp(radius, 1, MAX_BLUR_RADIUS);
    const x0 = clipped.x0;
    const x1 = clipped.x1;
    const y0 = clipped.y0;
    const y1 = clipped.y1;
    const width_int: usize = @intCast(x1 - x0);
    const r_int: i32 = @intCast(r_blur);
    const y_start = y0 - r_int;
    const y_end = y1 + r_int;
    const n_rows: usize = @intCast(y_end - y_start);

    const src_row_len = width_int + @as(usize, @intCast(r_blur * 2));
    const scratch_used = width_int * n_rows;
    if (radius == 0 or scratch.len < scratch_used + src_row_len) {
        backdrop.drawGraduatedBackgroundInBoxDrift(
            self,
            clipped,
            top_col,
            bot_col,
            dx,
            dy,
        );
        return;
    }
    const src_row_buf = scratch[scratch_used..][0..src_row_len];

    var kernel: [MAX_KERNEL_LEN]u32 = undefined;
    computeGaussianKernel(r_blur, kernel[0 .. r_blur * 2 + 1]);
    const kernel_len = r_blur * 2 + 1;

    // Pass 1: Horizontal 1D Gaussian convolution across [y_start, y_end).
    const is_morph = (top_col == Color.SKY_BASE_TOP);
    const morph = backdrop.MorphField.init(w, h, dx, dy);
    const grad = RgbGradient.init(top_col, bot_col, h);
    const max_w: i32 = @intCast(if (w > 0) w - 1 else 0);

    var y_iter = y_start;
    while (y_iter < y_end) : (y_iter += 1) {
        const cy = std.math.clamp(y_iter, 0, @as(i32, @intCast(h - 1)));
        const row_idx = @as(usize, @intCast(y_iter - y_start)) * width_int;

        if (is_morph) {
            var si: usize = 0;
            var sx_iter = x0 - r_int;
            const sx_end = x1 + r_int;
            while (sx_iter < sx_end and si < src_row_len) : ({
                sx_iter += 1;
                si += 1;
            }) {
                const cx_c = std.math.clamp(sx_iter, 0, max_w);
                src_row_buf[si] = morph.samplePixel(cx_c, cy);
            }
        } else {
            const rgb = grad.rowBase(cy);
            const ucy = backdrop.mod256(cy, dy);
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
                const ucx = backdrop.mod256(cx_c, dx);
                const op = CLOUD_BASE_OPACITY;
                src_row_buf[si] =
                    backdrop.sampleCloudRowPixel(rgb, map_y1, map_y2, ucx, op);
            }
        }

        for (0..width_int) |x_rel| {
            var sum_r: u32 = 0;
            var sum_g: u32 = 0;
            var sum_b: u32 = 0;
            for (0..kernel_len) |k_idx| {
                const p = src_row_buf[x_rel + k_idx];
                const weight = kernel[k_idx];
                sum_r += @as(u32, Color.r(p)) * weight;
                sum_g += @as(u32, Color.g(p)) * weight;
                sum_b += @as(u32, Color.b(p)) * weight;
            }
            scratch[row_idx + x_rel] = Color.rgb(
                @intCast(sum_r >> 16),
                @intCast(sum_g >> 16),
                @intCast(sum_b >> 16),
            );
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
                    self.pixels[dst_idx] = backdrop.getBackdropPixelDrift(
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
                sum_r += @as(u32, Color.r(hp)) * weight;
                sum_g += @as(u32, Color.g(hp)) * weight;
                sum_b += @as(u32, Color.b(hp)) * weight;
            }
            self.pixels[dst_idx] = Color.rgb(
                @intCast(sum_r >> 16),
                @intCast(sum_g >> 16),
                @intCast(sum_b >> 16),
            );
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

test {
    std.testing.refAllDecls(@This());
}
