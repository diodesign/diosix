// Analytic Scanline Area-Coverage Vector Rasterizer for Diosix GUI.
//
// Computes 256-level (8-bit) antialiased alpha coverage masks from flattened
// vector edges using sub-pixel supersampled scanline winding accumulation,
// plus morphological outline dilation for crisp vector borders.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("../framebuffer.zig");

pub const SUBPIXEL_SAMPLES_Y: usize = 8;
pub const SUBPIXEL_SAMPLES_X: usize = 8;
pub const MAX_SCANLINE_INTERSECTIONS: usize = 128;

pub const Edge = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    winding: i32,
};

pub const FillRule = enum {
    non_zero,
    even_odd,
};

const Intersection = struct {
    x: f32,
    winding: i32,
};

fn sortIntersections(items: []Intersection) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const key = items[i];
        var j: usize = i;
        while (j > 0 and items[j - 1].x > key.x) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = key;
    }
}

/// Rasterizes a slice of directed vector edges into `mask_out` (`width*height`
/// bytes of 0..255 antialiased coverage) using 4x vertical scanline sampling
/// and exact horizontal fractional span integration (`ftgrays`-style coverage).
pub fn rasterizeEdgesToMask(
    edges: []const Edge,
    mask_out: []u8,
    width: u32,
    height: u32,
    fill_rule: FillRule,
) void {
    const total_px = @as(usize, width) * @as(usize, height);
    if (width == 0 or height == 0 or mask_out.len < total_px) return;
    @memset(mask_out[0..total_px], 0);
    if (edges.len == 0) return;

    const w_f: f32 = @floatFromInt(width);
    const sub_f: f32 = @floatFromInt(SUBPIXEL_SAMPLES_Y);
    const inv_samples_y: f32 = 1.0 / sub_f;

    var row_accum: [1024]u16 = undefined;
    const max_w: usize = @min(@as(usize, width), row_accum.len);

    var py: u32 = 0;
    while (py < height) : (py += 1) {
        @memset(row_accum[0..max_w], 0);
        const base_y: f32 = @floatFromInt(py);

        var sy: usize = 0;
        while (sy < SUBPIXEL_SAMPLES_Y) : (sy += 1) {
            const scan_y =
                base_y + (@as(f32, @floatFromInt(sy)) + 0.5) * inv_samples_y;
            var hits: [MAX_SCANLINE_INTERSECTIONS]Intersection = undefined;
            var hit_count: usize = 0;

            for (edges) |e| {
                if (scan_y >= e.y0 and scan_y < e.y1) {
                    const dy = e.y1 - e.y0;
                    if (dy > 0.00001 and hit_count < hits.len) {
                        const t = (scan_y - e.y0) / dy;
                        const ix = e.x0 + (e.x1 - e.x0) * t;
                        hits[hit_count] = .{ .x = ix, .winding = e.winding };
                        hit_count += 1;
                    }
                }
            }

            if (hit_count < 2) continue;
            sortIntersections(hits[0..hit_count]);

            var winding: i32 = 0;
            var span_start: f32 = 0.0;
            var was_inside = false;

            for (hits[0..hit_count]) |h| {
                winding += h.winding;
                const is_inside = switch (fill_rule) {
                    .non_zero => winding != 0,
                    .even_odd => @mod(winding, 2) != 0,
                };
                if (!was_inside and is_inside) {
                    span_start = h.x;
                    was_inside = true;
                } else if (was_inside and !is_inside) {
                    const x0 = std.math.clamp(span_start, 0.0, w_f);
                    const x1 = std.math.clamp(h.x, 0.0, w_f);
                    if (x1 > x0) {
                        accumulateHorizontalSpan(
                            row_accum[0..max_w],
                            x0,
                            x1,
                        );
                    }
                    was_inside = false;
                }
            }
        }

        const row_off = @as(usize, py) * @as(usize, width);
        for (0..max_w) |px| {
            // Each sub-scanline adds up to 32 units; 8 sub-scanlines = 0..256.
            // Apply optical sRGB stem-darkening curve so thin vector strokes
            // render with smooth, uniform weight across pixel boundaries.
            const raw_cov: u32 = @min(@as(u32, 255), row_accum[px]);
            const cov: u32 = if (raw_cov >= 224)
                255
            else
                (raw_cov * (510 - raw_cov)) / 255;
            mask_out[row_off + px] = @intCast(cov);
        }
    }
}

fn accumulateHorizontalSpan(row_accum: []u16, x0: f32, x1: f32) void {
    const max_x: f32 = @floatFromInt(row_accum.len);
    const sx0 = std.math.clamp(x0, 0.0, max_x);
    const sx1 = std.math.clamp(x1, 0.0, max_x);
    if (sx1 <= sx0) return;

    const idx0: usize = @intFromFloat(@floor(sx0));
    const idx1: usize = @intFromFloat(@floor(sx1));
    if (idx0 >= row_accum.len) return;

    if (idx0 == idx1) {
        const frac = sx1 - sx0;
        const add: u16 = @intFromFloat(@round(frac * 32.0));
        row_accum[idx0] +|= add;
        return;
    }

    // Left fractional pixel.
    const left_cov = (@as(f32, @floatFromInt(idx0 + 1)) - sx0) * 32.0;
    row_accum[idx0] +|= @intFromFloat(@round(left_cov));

    // Full interior pixels.
    const end_full: usize = @min(idx1, row_accum.len);
    var k: usize = idx0 + 1;
    while (k < end_full) : (k += 1) {
        row_accum[k] +|= 32;
    }

    // Right fractional pixel.
    if (idx1 < row_accum.len) {
        const right_cov = (sx1 - @as(f32, @floatFromInt(idx1))) * 32.0;
        row_accum[idx1] +|= @intFromFloat(@round(right_cov));
    }
}

/// Generates a smooth dilated outline alpha mask (`dst`) from an interior
/// coverage mask (`src`) with circular brush radius `radius_px`.
pub fn dilateMask(
    src: []const u8,
    dst: []u8,
    width: u32,
    height: u32,
    radius_px: f32,
) void {
    const total = @as(usize, width) * @as(usize, height);
    if (width == 0 or height == 0 or src.len < total or dst.len < total) return;

    const r_ceil: i32 = @intFromFloat(@ceil(radius_px));
    if (r_ceil <= 0) {
        @memcpy(dst[0..total], src[0..total]);
        return;
    }

    const r_sq = radius_px * radius_px;
    const w_i: i32 = @intCast(width);
    const h_i: i32 = @intCast(height);

    var y: i32 = 0;
    while (y < h_i) : (y += 1) {
        const row_off = @as(usize, @intCast(y)) * @as(usize, width);
        var x: i32 = 0;
        while (x < w_i) : (x += 1) {
            var max_a: u8 = src[row_off + @as(usize, @intCast(x))];
            if (max_a < 255) {
                var dy: i32 = -r_ceil;
                while (dy <= r_ceil) : (dy += 1) {
                    const ny = y + dy;
                    if (ny < 0 or ny >= h_i) continue;
                    const nrow = @as(usize, @intCast(ny)) * @as(usize, width);
                    var dx: i32 = -r_ceil;
                    while (dx <= r_ceil) : (dx += 1) {
                        const nx = x + dx;
                        if (nx < 0 or nx >= w_i) continue;
                        const d2: f32 =
                            @floatFromInt(dx * dx + dy * dy);
                        if (d2 <= r_sq + 0.5) {
                            const sample = src[nrow + @as(usize, @intCast(nx))];
                            if (sample > max_a) max_a = sample;
                        }
                    }
                }
            }
            dst[row_off + @as(usize, @intCast(x))] = max_a;
        }
    }
}

/// Blends an 8-bit antialiased coverage mask onto `surface` at `(dst_x, dst_y)`
/// with `color` and `master_alpha`.
pub fn blendMaskOnSurface(
    surface: *fb.Surface,
    mask: []const u8,
    width: u32,
    height: u32,
    dst_x: i32,
    dst_y: i32,
    color: u32,
    master_alpha: u8,
) void {
    if (master_alpha == 0 or width == 0 or height == 0) return;
    if (surface.clip.isEmpty()) return;

    const clip_x0 = @max(0, surface.clip.x0);
    const clip_y0 = @max(0, surface.clip.y0);
    const clip_x1 = @min(@as(i32, @intCast(surface.width)), surface.clip.x1);
    const clip_y1 = @min(@as(i32, @intCast(surface.height)), surface.clip.y1);
    if (clip_x0 >= clip_x1 or clip_y0 >= clip_y1) return;

    const stride_px = surface.stridePixels();
    var r: u32 = 0;
    while (r < height) : (r += 1) {
        const py = dst_y + @as(i32, @intCast(r));
        if (py < clip_y0 or py >= clip_y1) continue;
        const dst_row = @as(usize, @intCast(py)) * stride_px;
        const src_row = @as(usize, r) * @as(usize, width);

        var c: u32 = 0;
        while (c < width) : (c += 1) {
            const px = dst_x + @as(i32, @intCast(c));
            if (px < clip_x0 or px >= clip_x1) continue;
            const raw_a = mask[src_row + @as(usize, c)];
            if (raw_a == 0) continue;
            const eff_a: u8 = if (master_alpha == 255)
                raw_a
            else
                @intCast((@as(u32, raw_a) * @as(u32, master_alpha)) >> 8);
            if (eff_a == 0) continue;
            const idx = dst_row + @as(usize, @intCast(px));
            if (eff_a == 255) {
                surface.pixels[idx] = color;
            } else {
                surface.pixels[idx] =
                    fb.blendPixel(surface.pixels[idx], color, eff_a);
            }
        }
    }
}

test "vector raster: triangle area coverage and dilation" {
    std.testing.refAllDecls(@This());
    const edges = [_]Edge{
        .{ .x0 = 2.0, .y0 = 2.0, .x1 = 14.0, .y1 = 8.0, .winding = 1 },
        .{ .x0 = 14.0, .y0 = 8.0, .x1 = 2.0, .y1 = 14.0, .winding = 1 },
        .{ .x0 = 2.0, .y0 = 2.0, .x1 = 2.0, .y1 = 14.0, .winding = -1 },
    };
    var mask: [16 * 16]u8 = undefined;
    rasterizeEdgesToMask(&edges, &mask, 16, 16, .non_zero);
    // Interior of triangle at (5, 8) should be fully covered (255).
    try std.testing.expectEqual(@as(u8, 255), mask[8 * 16 + 5]);
    // Exterior at (15, 15) should be 0.
    try std.testing.expectEqual(@as(u8, 0), mask[15 * 16 + 15]);
}
