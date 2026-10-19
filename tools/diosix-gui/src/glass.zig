// Translucent Glass Pane Shader, Superellipse Curvature & Optical Lens Engine.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("framebuffer.zig");
const Box = fb.Box;
const Color = fb.Color;
const Surface = fb.Surface;
const blendPixel = fb.blendPixel;

// Evaluates rounded / superellipse corner distance metric if (x, y) is inside
// one of the four r x r corner quadrants of box; returns null otherwise.
pub inline fn cornerDistMetric(
    x: i32,
    y: i32,
    box: Box,
    r: i32,
    r_sq: i32,
    is_superellipse: bool,
) ?i32 {
    if (r <= 0) return null;
    const dy: i32 = if (y < box.y0 + r)
        (box.y0 + r) - y
    else if (y >= box.y1 - r)
        y - (box.y1 - r - 1)
    else
        return null;

    const dx: i32 = if (x < box.x0 + r)
        (box.x0 + r) - x
    else if (x >= box.x1 - r)
        x - (box.x1 - r - 1)
    else
        return null;

    const dx_sq = dx * dx;
    const dy_sq = dy * dy;
    const super_term = if (is_superellipse and r_sq > 0)
        @divTrunc(dx_sq * dy_sq, 2 * r_sq)
    else
        0;
    return dx_sq + dy_sq - super_term;
}

inline fn applyLensEdge(
    pix: u32,
    dx: i32,
    dy: i32,
    r: i32,
    span: i32,
    is_border: bool,
    is_inner: bool,
    color: u32,
    rim_max: i32,
    inner_max: i32,
    c_span: i32,
    c_max: i32,
) u32 {
    const d = dx + dy;
    if (d >= span) return pix;
    const rem = span - d;
    const in_corner = dx < r and dy < r;
    if (is_border and (dx == 0 or dy == 0 or in_corner)) {
        const rim_a: u8 = @intCast(@divTrunc(rem * rim_max, span));
        return blendPixel(pix, color, rim_a);
    }
    if (is_inner and (dx <= 1 or dy <= 1 or in_corner)) {
        const inner_a: u8 = @intCast(@divTrunc(rem * inner_max, span));
        return blendPixel(pix, color, inner_a);
    }
    if (in_corner and d < c_span) {
        const c_a: u8 = @intCast(@divTrunc((c_span - d) * c_max, c_span));
        return blendPixel(pix, color, c_a);
    }
    return pix;
}

// Draw translucent glass pane with optional subtle optical lens highlights
// and optional superellipse (squircle) corner curvature.
pub fn drawGlassPane(
    self: *Surface,
    box: Box,
    radius: u32,
    fill_color: u32,
    alpha: u8,
    border_color: ?u32,
    lens_effect: bool,
    is_superellipse: bool,
) void {
    const active = box.intersect(self.clip);
    if (active.isEmpty()) return;

    const x0 = box.x0;
    const y0 = box.y0;
    const x1 = box.x1;
    const y1 = box.y1;
    const w = x1 - x0;
    const h = y1 - y0;
    if (w <= 0 or h <= 0) return;

    const max_r = @divTrunc(@min(w, h), 2);
    const r: i32 = @min(@as(i32, @intCast(radius)), max_r);
    const r_sq = r * r;
    const inner_r_sq = if (r > 1) (r - 1) * (r - 1) else 0;
    const inner2_r_sq = if (r > 2) (r - 2) * (r - 2) else 0;

    const tl_span: i32 = @max(1, @min(200, @divTrunc(w + h, 4)));
    const br_span: i32 = @max(1, @min(150, @divTrunc(w + h, 5)));
    const pixels_per_row = self.stridePixels();

    var y = active.y0;
    while (y < active.y1) : (y += 1) {
        const row_offset = @as(usize, @intCast(y)) * pixels_per_row;
        const is_corner_y = (r > 0 and (y < y0 + r or y >= y1 - r));

        var x = active.x0;
        while (x < active.x1) : (x += 1) {
            var is_corner_rim = false;
            var is_corner_inner2 = false;

            if (cornerDistMetric(x, y, box, r, r_sq, is_superellipse)) |dm| {
                if (dm > r_sq) continue;
                is_corner_rim = (dm > inner_r_sq);
                is_corner_inner2 = (dm <= inner_r_sq and dm > inner2_r_sq);
            }

            const mid_x = x >= x0 + r and x < x1 - r;
            const on_lr_rim = !is_corner_y and (x == x0 or x == x1 - 1);
            const on_tb_rim = (y == y0 or y == y1 - 1) and mid_x;
            const is_border = on_lr_rim or on_tb_rim or is_corner_rim;

            const on_lr_in2 = !is_corner_y and (x == x0 + 1 or x == x1 - 2);
            const on_tb_in2 = (y == y0 + 1 or y == y1 - 2) and mid_x;
            const is_inner = (!is_border) and
                (on_lr_in2 or on_tb_in2 or is_corner_inner2);

            const px = x - x0;
            const py = y - y0;
            const col_idx = row_offset + @as(usize, @intCast(x));
            const bg = self.pixels[col_idx];
            var pix = blendPixel(bg, fill_color, alpha);

            if (lens_effect) {
                pix = applyLensEdge(
                    pix,
                    px,
                    py,
                    r,
                    tl_span,
                    is_border,
                    is_inner,
                    Color.WHITE,
                    55,
                    22,
                    24,
                    10,
                );
                pix = applyLensEdge(
                    pix,
                    (w - 1) - px,
                    (h - 1) - py,
                    r,
                    br_span,
                    is_border,
                    is_inner,
                    0x00e4f0ff,
                    35,
                    14,
                    20,
                    8,
                );
            }

            if (border_color) |b_col| {
                if (is_border) pix = blendPixel(bg, b_col, 140);
            }
            self.pixels[col_idx] = pix;
        }
    }
}

pub fn drawRoundedTranslucentBox(
    self: *Surface,
    box: Box,
    r: u32,
    fill: u32,
    alpha: u8,
    bdr: ?u32,
) void {
    drawGlassPane(self, box, r, fill, alpha, bdr, false, false);
}

pub fn drawWindowPane(self: *Surface, box: Box) void {
    const bg = Color.GLASS_BG;
    const op = Color.GLASS_OPACITY;
    const bdr = Color.GLASS_BORDER;
    drawGlassPane(self, box, 12, bg, op, bdr, true, true);
}

test {
    std.testing.refAllDecls(@This());
}
