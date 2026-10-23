// Utopian Scholastic Pencil-Sketch & Rainbow-Fill Intro Choreography.
//
// Draws uppercase 'DIOSIX' on a stark white background using scalable TrueType
// vector outlines rasterized at the active display resolution:
//   1. A black pencil line progressively sketches the character outlines
//      (300ms - 3350ms).
//   2. A vibrant rainbow spectrum fills the interior of the characters,
//      framed by solid black lines (1800ms - 4950ms), holding until 5900ms.
//   3. The logo fades out cleanly (5900ms - 6900ms) before the GUI fades in.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("../framebuffer.zig");
const banner_font = @import("../font/banner.zig");

pub const LOGO_START_MS: u32 = 150;
pub const LOGO_FADEOUT_START_MS: u32 = 5900;
pub const LOGO_FADEOUT_DURATION_MS: u32 = 1000;
pub const LOGO_END_MS: u32 = LOGO_FADEOUT_START_MS + LOGO_FADEOUT_DURATION_MS;

/// Standard smoothstep (clamped before polynomial to guarantee monotonic
/// stability and prevent unwinding).
pub fn easeInOut(val: f32) f32 {
    const t = std.math.clamp(val, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// Interpolates smoothly between two 24-bit RGB colors.
pub fn interpolateColor(c1: u32, c2: u32, factor: f32) u32 {
    const f = std.math.clamp(factor, 0.0, 1.0);
    const r1: f32 = @floatFromInt((c1 >> 16) & 0xff);
    const g1: f32 = @floatFromInt((c1 >> 8) & 0xff);
    const b1: f32 = @floatFromInt(c1 & 0xff);

    const r2: f32 = @floatFromInt((c2 >> 16) & 0xff);
    const g2: f32 = @floatFromInt((c2 >> 8) & 0xff);
    const b2: f32 = @floatFromInt(c2 & 0xff);

    const r = @as(u32, @intFromFloat(r1 + (r2 - r1) * f));
    const g = @as(u32, @intFromFloat(g1 + (g2 - g1) * f));
    const b = @as(u32, @intFromFloat(b1 + (b2 - b1) * f));

    return (r << 16) | (g << 8) | b;
}

/// Evaluates the continuous 6-band Utopian Scholastic rainbow spectrum for
/// normalized horizontal coordinate u in [0.0, 1.0].
pub fn sampleRainbowSpectrum(u: f32) u32 {
    const clamped = std.math.clamp(u, 0.0, 1.0);
    const scaled = clamped * 5.0;
    const idx: usize = @min(@as(usize, @intFromFloat(@floor(scaled))), 4);
    const frac = scaled - @as(f32, @floatFromInt(idx));
    return interpolateColor(
        fb.Color.RAINBOW[idx],
        fb.Color.RAINBOW[idx + 1],
        frac,
    );
}

fn sampleMaskAt(mask: []const u8, gw: u16, gh: u16, x: i32, y: i32) u8 {
    if (x < 0 or y < 0 or x >= @as(i32, gw) or y >= @as(i32, gh)) return 0;
    const idx = @as(usize, @intCast(y)) * @as(usize, gw) +
        @as(usize, @intCast(x));
    return mask[idx];
}

fn sampleDilatedMask(
    mask: []const u8,
    gw: u16,
    gh: u16,
    x: i32,
    y: i32,
    radius: i32,
) u8 {
    var max_a: u8 = sampleMaskAt(mask, gw, gh, x, y);
    if (max_a == 255) return 255;
    const r2 = radius * radius + 1;
    var dy: i32 = -radius;
    while (dy <= radius) : (dy += 1) {
        var dx: i32 = -radius;
        while (dx <= radius) : (dx += 1) {
            if (dx * dx + dy * dy <= r2) {
                const a = sampleMaskAt(mask, gw, gh, x + dx, y + dy);
                if (a > max_a) max_a = a;
            }
        }
    }
    return max_a;
}

/// Draws minimalist scholastic drafting rules and registration ticks around
/// the 'DIOSIX' wordmark, scaled to the active display dimensions.
pub fn drawHorizonBeam(surface: *fb.Surface, t: u32, w: u32, h: u32) void {
    if (t < LOGO_START_MS or t >= LOGO_END_MS or w < 64 or h < 64) return;

    var alpha_f: f32 = 1.0;
    if (t < 900) {
        alpha_f = easeInOut(
            @as(f32, @floatFromInt(t - LOGO_START_MS)) / 750.0,
        );
    } else if (t >= LOGO_FADEOUT_START_MS) {
        const fade_t = @as(f32, @floatFromInt(t - LOGO_FADEOUT_START_MS)) /
            @as(f32, @floatFromInt(LOGO_FADEOUT_DURATION_MS));
        alpha_f = 1.0 - easeInOut(fade_t);
    }
    const line_alpha: u8 = @intFromFloat(alpha_f * 255.0);
    if (line_alpha == 0) return;

    const line_col = fb.blendPixel(fb.Color.WHITE, fb.Color.INK, line_alpha);
    const guide_col = fb.blendPixel(
        fb.Color.WHITE,
        0x00d8d6ce,
        @intFromFloat(alpha_f * 180.0),
    );

    const w_i: i32 = @intCast(w);
    const h_i: i32 = @intCast(h);
    const scale_f: f32 = @as(f32, @floatFromInt(h)) / 800.0;
    const target_span: i32 = @intFromFloat(520.0 * scale_f);
    const max_span: i32 = @min(w_i - 64, @max(240, target_span));
    const span_w: i32 = @intFromFloat(
        @as(f32, @floatFromInt(max_span)) * alpha_f,
    );
    const center_x = @divTrunc(w_i, 2);
    const center_y = @divTrunc(h_i, 2);
    const cap_off: i32 = @intFromFloat(38.0 * scale_f);
    const base_off: i32 = @intFromFloat(32.0 * scale_f);
    const rule_off: i32 = @intFromFloat(48.0 * scale_f);
    const cap_y = center_y - cap_off;
    const base_y = center_y + base_off;
    const rule_y = center_y + rule_off;

    if (span_w > 0) {
        const x0 = center_x - @divTrunc(span_w, 2);
        const x1 = center_x + @divTrunc(span_w, 2);
        surface.drawHorizontalLine(x0, x1, cap_y, guide_col);
        surface.drawHorizontalLine(x0, x1, base_y, guide_col);

        surface.drawHorizontalLine(x0, x1, rule_y, line_col);
        surface.fillBox(fb.Box.fromPosSize(x0, rule_y - 4, 1, 9), line_col);
        surface.fillBox(fb.Box.fromPosSize(x1, rule_y - 4, 1, 9), line_col);
    }
}

fn drawPencilNib(surface: *fb.Surface, px: i32, py: i32, alpha: u8) void {
    if (alpha == 0) return;
    const ink_col = fb.blendPixel(fb.Color.WHITE, fb.Color.INK, alpha);
    const wood_col = fb.blendPixel(fb.Color.WHITE, 0x00e0b080, alpha);
    const body_col = fb.blendPixel(fb.Color.WHITE, 0x00e9b824, alpha);

    surface.fillBox(fb.Box.fromPosSize(px - 1, py - 1, 3, 3), ink_col);
    var s: i32 = 2;
    while (s <= 14) : (s += 1) {
        const half_w: i32 = if (s < 6) 1 else 2;
        const fill = if (s < 4) ink_col else if (s < 7) wood_col else body_col;
        var d: i32 = -half_w;
        while (d <= half_w) : (d += 1) {
            const col = if (d == -half_w or d == half_w) ink_col else fill;
            surface.setPixel(px + s + d, py - s, col);
        }
    }
}

/// Draws uppercase 'DIOSIX' rasterized directly from scalable TrueType
/// outlines at the target display resolution.
pub fn drawBrandingAnimation(
    surface: *fb.Surface,
    t: u32,
    w: u32,
    h: u32,
) void {
    if (t < 250 or t >= LOGO_END_MS or w == 0 or h == 0) return;

    const letters = "DIOSIX";
    const logo_h: u32 = std.math.clamp((h * 104) / 800, 64, 220);
    const outline_r: i32 = @max(2, @as(i32, @intCast(logo_h / 32)));
    const pad_px: i32 = outline_r + 1;
    const letter_gap: i32 = @max(10, @as(i32, @intCast((logo_h * 18) / 104)));

    var total_w: i32 = 0;
    for (letters, 0..) |ch, idx| {
        const view = banner_font.getBannerGlyphAtHeight(ch, logo_h);
        total_w += @as(i32, view.glyph.width);
        if (idx + 1 < letters.len) total_w += letter_gap;
    }

    const start_x: i32 = @as(i32, @intCast(w / 2)) - @divTrunc(total_w, 2);
    const base_y: i32 =
        @as(i32, @intCast(h / 2)) - @as(i32, @intCast(logo_h / 2));

    var master_alpha: f32 = 1.0;
    if (t >= LOGO_FADEOUT_START_MS) {
        const out_t = @as(f32, @floatFromInt(t - LOGO_FADEOUT_START_MS)) /
            @as(f32, @floatFromInt(LOGO_FADEOUT_DURATION_MS));
        master_alpha = 1.0 - easeInOut(out_t);
    }
    if (master_alpha <= 0.005) return;

    var cur_x: i32 = start_x;
    var active_nib_x: ?i32 = null;
    var active_nib_y: ?i32 = null;

    for (letters, 0..) |ch, idx| {
        const u_idx: u32 = @intCast(idx);
        const view = banner_font.getBannerGlyphAtHeight(ch, logo_h);
        const glyph = view.glyph;
        const gw_i: i32 = @as(i32, glyph.width);
        const gh_i: i32 = @as(i32, glyph.height);
        const gx0 = cur_x;
        const gy0 = base_y + @as(i32, glyph.offset_y);
        cur_x += gw_i + letter_gap;

        const sketch_start: u32 = 300 + u_idx * 450;
        const sketch_dur: u32 = 800;
        if (t <= sketch_start) continue;

        const sketch_prog = easeInOut(
            @as(f32, @floatFromInt(t - sketch_start)) /
                @as(f32, @floatFromInt(sketch_dur)),
        );

        const fill_start: u32 = 1800 + u_idx * 420;
        const fill_dur: u32 = 1050;
        const fill_prog: f32 = if (t > fill_start)
            easeInOut(
                @as(f32, @floatFromInt(t - fill_start)) /
                    @as(f32, @floatFromInt(fill_dur)),
            )
        else
            0.0;

        const box_w = gw_i + pad_px * 2;
        const box_h = gh_i + pad_px * 2;
        const den_x: f32 = @floatFromInt(@max(1, box_w - 1));
        const den_y: f32 = @floatFromInt(@max(1, box_h - 1));

        var dy: i32 = -pad_px;
        while (dy < gh_i + pad_px) : (dy += 1) {
            const py = gy0 + dy;
            const norm_y = @as(f32, @floatFromInt(dy + pad_px)) / den_y;

            var dx: i32 = -pad_px;
            while (dx < gw_i + pad_px) : (dx += 1) {
                const px = gx0 + dx;
                const norm_x = @as(f32, @floatFromInt(dx + pad_px)) / den_x;
                const stroke_pos = norm_y * 0.65 + norm_x * 0.35;
                if (stroke_pos > sketch_prog) continue;

                const dilated_a = sampleDilatedMask(
                    view.mask,
                    glyph.width,
                    glyph.height,
                    dx,
                    dy,
                    outline_r,
                );
                if (dilated_a < 64) continue;

                const center_a = sampleMaskAt(
                    view.mask,
                    glyph.width,
                    glyph.height,
                    dx,
                    dy,
                );
                const global_u = @as(f32, @floatFromInt(px - start_x)) /
                    @as(f32, @floatFromInt(@max(1, total_w)));
                const rainbow_col = sampleRainbowSpectrum(global_u);

                const fill_sweep = (1.0 - norm_y) * 0.70 + norm_x * 0.30;
                var interior_col: u32 = fb.Color.WHITE;
                if (fill_prog > 0.0 and fill_sweep <= fill_prog) {
                    const edge_dist = fill_prog - fill_sweep;
                    if (edge_dist < 0.12 and fill_prog < 0.99) {
                        const hatch = @mod(px + py, 4);
                        const hatch_f: f32 = if (hatch < 2) 0.9 else 0.45;
                        interior_col = interpolateColor(
                            fb.Color.WHITE,
                            rainbow_col,
                            hatch_f,
                        );
                    } else {
                        interior_col = rainbow_col;
                    }
                } else if (sketch_prog < 0.99) {
                    if (@mod(px - py, 7) == 0) {
                        interior_col = 0x00eceae2;
                    }
                }

                const inner_t = std.math.clamp(
                    (@as(f32, @floatFromInt(center_a)) - 96.0) / 68.0,
                    0.0,
                    1.0,
                );
                const char_col = interpolateColor(
                    fb.Color.INK,
                    interior_col,
                    inner_t,
                );

                const outer_t = std.math.clamp(
                    (@as(f32, @floatFromInt(dilated_a)) - 64.0) / 80.0,
                    0.0,
                    1.0,
                );
                const final_a: u8 = @intFromFloat(
                    outer_t * master_alpha * 255.0,
                );
                if (final_a > 0) {
                    const bg = surface.getPixel(px, py);
                    const blended = fb.blendPixel(bg, char_col, final_a);
                    surface.setPixel(px, py, blended);
                }

                if (sketch_prog < 0.98 and
                    @abs(stroke_pos - sketch_prog) < 0.02 and
                    center_a < 120)
                {
                    active_nib_x = px;
                    active_nib_y = py;
                }
            }
        }
    }

    if (active_nib_x) |nx| {
        if (active_nib_y) |ny| {
            drawPencilNib(
                surface,
                nx,
                ny,
                @intFromFloat(master_alpha * 255.0),
            );
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
