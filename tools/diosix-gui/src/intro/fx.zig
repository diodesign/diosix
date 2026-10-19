// Visual Effects & Choreography Helpers for Diosix GUI Intro Animation.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("../framebuffer.zig");
const banner_font = @import("../font/banner.zig");

pub const Particle = struct {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    size: u8,
    color: u32,
    twinkle_phase: f32,
    twinkle_speed: f32,
};

// Standard smoothstep (clamped before polynomial to guarantee monotonic
// stability and prevent unwinding).
pub fn easeInOut(val: f32) f32 {
    const t = std.math.clamp(val, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

// Interpolates smoothly between two 24-bit RGB colors.
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

// Draws the luminous horizontal horizon light beam across the screen.
pub fn drawHorizonBeam(surface: *fb.Surface, t: u32, w: u32, h: u32) void {
    const center_y: i32 = @intCast(h / 2);

    // Intensity profile: rises 500ms -> 2000ms (Peak 1), relaxes -> 3500ms.
    var beam_intensity: f32 = 0.0;
    if (t < 2000) {
        const prog = @as(f32, @floatFromInt(t - 400)) / 1600.0;
        beam_intensity = std.math.clamp(prog * prog, 0.0, 1.0);
    } else {
        const prog = @as(f32, @floatFromInt(3800 - t)) / 1800.0;
        beam_intensity = std.math.clamp(prog, 0.0, 1.0);
    }

    if (beam_intensity <= 0.01) return;

    // Subtle, translucent atmospheric horizon glow matching the character aura.
    const max_alpha: f32 = 60.0 * beam_intensity;
    const beam_half_h: i32 = 28;
    const y0 = @max(0, center_y - beam_half_h);
    const y1 = @min(@as(i32, @intCast(h)), center_y + beam_half_h);

    var y = y0;
    while (y < y1) : (y += 1) {
        const dy: f32 = @floatFromInt(@abs(y - center_y));
        const norm_y = dy / @as(f32, @floatFromInt(beam_half_h));
        const falloff = std.math.clamp(1.0 - norm_y, 0.0, 1.0);
        const alpha: u8 = @intFromFloat(max_alpha * falloff * falloff);
        if (alpha == 0) continue;

        // Soft celestial ice-white core transitioning into starlight cyan.
        const beam_color = interpolateColor(0x00f0f8ff, 0x0050b8e8, norm_y);

        var x: i32 = 0;
        const w_i: i32 = @intCast(w);
        const center_x: f32 = @as(f32, @floatFromInt(w)) * 0.5;
        while (x < w_i) : (x += 1) {
            const dx_norm =
                @abs(@as(f32, @floatFromInt(x)) - center_x) / center_x;
            const x_falloff = std.math.clamp(1.0 - dx_norm * dx_norm, 0.0, 1.0);
            const cur_a: u8 =
                @intFromFloat(@as(f32, @floatFromInt(alpha)) * x_falloff);
            if (cur_a > 0) {
                const bg = surface.getPixel(x, y);
                surface.setPixel(x, y, fb.blendPixel(bg, beam_color, cur_a));
            }
        }
    }
}

// Draws the brand typography ('diosix') centered with left-to-right spell out
// and graceful wave fade out.
pub fn drawBrandingAnimation(
    surface: *fb.Surface,
    t: u32,
    w: u32,
    h: u32,
) void {
    if (t < 500 or t >= 4250) return;

    const letters = "diosix";
    const spacing: i32 = 68; // Wide letter spacing.
    const brand_total_width: i32 = spacing * 5 + 25;
    const start_x: i32 =
        @as(i32, @intCast(w / 2)) - @divTrunc(brand_total_width, 2);
    const center_y: i32 = @as(i32, @intCast(h / 2)) - 26;

    // Peak 1 character glow pulse: starts when all 6 letters appear (1700ms),
    // reaches maximum radiance at the apex of the chime (2100ms),
    // and gently fades back to crisp letters before fade-out (3000ms).
    var char_glow_pulse: f32 = 0.0;
    if (t >= 1700 and t <= 3000) {
        if (t <= 2100) {
            char_glow_pulse = @as(f32, @floatFromInt(t - 1700)) / 400.0;
        } else {
            char_glow_pulse =
                1.0 - (@as(f32, @floatFromInt(t - 2100)) / 900.0);
        }
        char_glow_pulse = easeInOut(char_glow_pulse);
    }

    // Spells out left-to-right to the first chime swell:
    //   d -> di -> dio -> dios -> diosi -> diosix
    // Then fades out in a tight harmonic wave into the emerging daylight sky.
    const in_step: u32 = 200;
    const in_fade: u32 = 200;
    const out_step: u32 = 35;
    const out_fade: u32 = 600;

    for (letters, 0..) |char, idx| {
        const u_idx: u32 = @intCast(idx);
        const in_start: u32 = 500 + u_idx * in_step;
        const in_end: u32 = in_start + in_fade;
        const out_start: u32 = 3450 + u_idx * out_step;
        const out_end: u32 = out_start + out_fade;

        if (t < in_start or t >= out_end) continue;

        var letter_alpha: u8 = 255;
        if (t < in_end) {
            const frac = @as(f32, @floatFromInt(t - in_start)) /
                @as(f32, @floatFromInt(in_fade));
            letter_alpha = @intFromFloat(frac * 255.0);
        } else if (t >= out_start) {
            const frac = @as(f32, @floatFromInt(out_end - t)) /
                @as(f32, @floatFromInt(out_fade));
            const eased = easeInOut(frac);
            letter_alpha = @intFromFloat(eased * 255.0);
        }

        if (letter_alpha == 0) continue;

        const lx = start_x + @as(i32, @intCast(idx)) * spacing;
        const ly = center_y;

        // 1. Radiant translucent aura around the character outlines.
        if (char_glow_pulse > 0.01) {
            const glow_f =
                @as(f32, @floatFromInt(letter_alpha)) * char_glow_pulse * 0.40;
            const glow_a: u8 = @intFromFloat(glow_f);
            if (glow_a > 0) {
                banner_font.drawBannerGlyphGlow(
                    surface,
                    char,
                    lx,
                    ly,
                    0x00eaf4ff,
                    glow_a,
                );
            }
        }

        // 2. Crisp native 52px antialiased Questrial glyph.
        banner_font.drawBannerGlyph(
            surface,
            char,
            lx,
            ly,
            fb.Color.WHITE,
            letter_alpha,
        );
    }
}
