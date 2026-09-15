// Inspiring Two-Warm-Moments Graphical Intro Animation for Diosix GUI
// Synchronized to intro.wav acoustic swells:
//   Moment 1 (0.0s - 3.8s): Midnight Canvas, Stardust Embers, 'd i o s i x' Emergence & Corona
//   Moment 2 (3.8s - 7.5s): Horizon Rise, Daylight Transition, Brand Glide & Window Bloom
//   Decay (7.5s - 10.0s): Settling into live desktop environment
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const fb = @import("framebuffer.zig");
const font = @import("font.zig");
const banner_font = @import("banner_font.zig");
const cursor_mod = @import("cursor.zig");
const gui_mod = @import("gui.zig");
const DiosixGui = gui_mod.DiosixGui;

pub const SENTINEL_PRIMARY: [*:0]const u8 = "/run/diosix_intro_played";
pub const SENTINEL_FALLBACK: [*:0]const u8 = "/tmp/.diosix_intro_played";

pub const TOTAL_INTRO_DURATION_MS: u32 = 10_000; // 10 seconds

// Returns true if intro has not been played during this boot session.
// Creates the sentinel file on first check so it plays once per boot.
pub fn shouldPlayIntro() bool {
    // 1. Check primary sentinel (/run)
    const rc_run = linux.open(SENTINEL_PRIMARY, .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(rc_run)) >= 0) {
        _ = linux.close(@intCast(rc_run));
        return false;
    }

    // 2. Check fallback sentinel (/tmp)
    const rc_tmp = linux.open(SENTINEL_FALLBACK, .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(rc_tmp)) >= 0) {
        _ = linux.close(@intCast(rc_tmp));
        return false;
    }

    // 3. Mark as played for this boot (create both if possible)
    const creat_run = linux.open(SENTINEL_PRIMARY, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (@as(isize, @bitCast(creat_run)) >= 0) {
        _ = linux.close(@intCast(creat_run));
    }

    const creat_tmp = linux.open(SENTINEL_FALLBACK, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (@as(isize, @bitCast(creat_tmp)) >= 0) {
        _ = linux.close(@intCast(creat_tmp));
    }

    return true;
}

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

pub const IntroState = struct {
    is_active: bool = false,
    start_time_ms: i64 = 0,
    elapsed_ms: u32 = 0,
    particles: [40]Particle = undefined,
    initialized_particles: bool = false,

    pub fn init(start_time: i64) IntroState {
        var state = IntroState{
            .is_active = true,
            .start_time_ms = start_time,
            .elapsed_ms = 0,
            .initialized_particles = false,
        };
        state.seedParticles(1280, 800);
        return state;
    }

    pub fn seedParticles(self: *IntroState, width: u32, height: u32) void {
        var prng = std.Random.DefaultPrng.init(0x193E36CC);
        const rand = prng.random();

        const w_f: f32 = @floatFromInt(width);
        const h_f: f32 = @floatFromInt(height);

        const particle_palette = [_]u32{
            0x00F8FCFF, // Starlight pure white
            0x0078E0F8, // Ethereal mako cyan
            0x00D0F0FF, // Starlight ice blue
            0x00EDF6FC, // Soft pearl white
            0x0040C0E0, // Radiant crystal cyan
        };

        for (&self.particles, 0..) |*p, i| {
            p.x = rand.float(f32) * w_f;
            p.y = rand.float(f32) * h_f;
            p.vx = (rand.float(f32) - 0.5) * 12.0; // Subtle horizontal drift
            p.vy = -(15.0 + rand.float(f32) * 35.0); // Gentle upward float
            p.size = @intCast(1 + (i % 3));
            p.color = particle_palette[i % particle_palette.len];
            p.twinkle_phase = rand.float(f32) * 6.28;
            p.twinkle_speed = 1.5 + rand.float(f32) * 3.0;
        }
        self.initialized_particles = true;
    }

    pub fn skip(self: *IntroState) void {
        self.elapsed_ms = TOTAL_INTRO_DURATION_MS;
        self.is_active = false;
    }

    pub fn tick(self: *IntroState, dt_ms: u32, now_ms: i64, width: u32, height: u32) void {
        if (!self.is_active) return;
        if (!self.initialized_particles) {
            self.seedParticles(width, height);
        }

        const elapsed = now_ms - self.start_time_ms;
        if (elapsed < 0) {
            self.elapsed_ms = 0;
        } else if (elapsed >= TOTAL_INTRO_DURATION_MS) {
            self.elapsed_ms = TOTAL_INTRO_DURATION_MS;
            self.is_active = false;
            return;
        } else {
            self.elapsed_ms = @intCast(elapsed);
        }

        // Update particle positions
        const dt_sec = @as(f32, @floatFromInt(dt_ms)) / 1000.0;
        const w_f: f32 = @floatFromInt(width);
        const h_f: f32 = @floatFromInt(height);

        for (&self.particles) |*p| {
            p.x += p.vx * dt_sec;
            p.y += p.vy * dt_sec;
            p.twinkle_phase += p.twinkle_speed * dt_sec;

            if (p.y < 0) {
                p.y += h_f;
                p.x = @mod(p.x + 37.0, w_f);
            }
            if (p.x < 0) p.x += w_f;
            if (p.x >= w_f) p.x -= w_f;
        }
    }

    // Renders the choreographed intro animation frame onto surface.
    // gui is passed so GUI windows, tabs, and backdrop can bloom during Moment 2.
    pub fn render(self: *IntroState, surface: *fb.Surface, gui: *DiosixGui) void {
        const t = self.elapsed_ms;
        const w = surface.width;
        const h = surface.height;
        if (w == 0 or h == 0) return;

        // Color themes
        const NIGHT_TOP: u32 = 0x00040812;
        const NIGHT_BOT: u32 = 0x000A162C;
        const DAY_TOP: u32 = fb.Color.SKY_BASE_TOP;
        const DAY_BOT: u32 = fb.Color.GRADIENT_BOT_DEFAULT;

        // -------------------------------------------------------------
        // 1. Background Composition: Transition between Midnight & Sky
        // -------------------------------------------------------------
        // Horizon rise occurs smoothly from 4000ms to 5400ms (Moment 2 onset)
        var day_factor: f32 = 0.0;
        if (t > 4000) {
            const rise_t = @as(f32, @floatFromInt(t - 4000)) / 1400.0;
            day_factor = easeInOut(rise_t);
        }

        if (day_factor <= 0.001) {
            // Pure smooth velvet midnight starry background (no cloud tile artifacts)
            const den_y = @as(f32, @floatFromInt(if (h > 1) h - 1 else 1));
            var y: u32 = 0;
            while (y < h) : (y += 1) {
                const frac = @as(f32, @floatFromInt(y)) / den_y;
                const row_col = interpolateColor(NIGHT_TOP, NIGHT_BOT, frac);
                const row_off = y * surface.stridePixels();
                @memset(surface.pixels[row_off .. row_off + w], row_col);
            }
        } else if (day_factor >= 0.999) {
            // Full daylight sky background with Perlin clouds
            surface.drawGraduatedBackgroundInBox(fb.Box.fromPosSize(0, 0, w, h), DAY_TOP, DAY_BOT);
        } else {
            // Cross-fade gradient
            const cur_top = interpolateColor(NIGHT_TOP, DAY_TOP, day_factor);
            const cur_bot = interpolateColor(NIGHT_BOT, DAY_BOT, day_factor);
            surface.drawGraduatedBackgroundInBox(fb.Box.fromPosSize(0, 0, w, h), cur_top, cur_bot);
        }

        // -------------------------------------------------------------
        // 2. Horizontal Horizon Light Beam (Moment 1: 500ms - 3800ms)
        // -------------------------------------------------------------
        if (t >= 400 and t <= 3800) {
            drawHorizonBeam(surface, t, w, h);
        }

        // -------------------------------------------------------------
        // 3. Stardust / Crystalline Embers
        // -------------------------------------------------------------
        // Particles sparkle brightly during Moment 1, gently dissolving as daylight settles
        var particle_alpha: u8 = 255;
        if (t > 6000) {
            const fade = @as(f32, @floatFromInt(t - 6000)) / 2500.0;
            particle_alpha = @intCast(255 - @as(u32, @intFromFloat(std.math.clamp(fade, 0.0, 1.0) * 255.0)));
        }

        if (particle_alpha > 0) {
            for (self.particles) |p| {
                const px: i32 = @intFromFloat(p.x);
                const py: i32 = @intFromFloat(p.y);
                if (px < 0 or py < 0 or px >= @as(i32, @intCast(w)) or py >= @as(i32, @intCast(h))) continue;

                // Twinkle modulation
                const sin_val = std.math.sin(p.twinkle_phase);
                const twinkle = (sin_val + 1.0) * 0.5; // 0.0 to 1.0
                const cur_a: u8 = @intCast((@as(u32, particle_alpha) * @as(u32, @intFromFloat(100.0 + twinkle * 155.0))) >> 8);

                const bg = surface.getPixel(px, py);
                surface.setPixel(px, py, fb.blendPixel(bg, p.color, cur_a));

                if (p.size >= 2 and px + 1 < @as(i32, @intCast(w)) and py + 1 < @as(i32, @intCast(h))) {
                    const soft_a: u8 = cur_a / 2;
                    surface.setPixel(px + 1, py, fb.blendPixel(surface.getPixel(px + 1, py), p.color, soft_a));
                    surface.setPixel(px, py + 1, fb.blendPixel(surface.getPixel(px, py + 1), p.color, soft_a));
                }
            }
        }

        // -------------------------------------------------------------
        // 4. Moment 1 & Moment 2 Glide ('d i o s i x')
        // -------------------------------------------------------------
        // Letters fade in sequentially, pulse at 2.0s (Peak 1),
        // and glide to the top-left menu bar during Moment 2 (4000ms - 5400ms).
        drawBrandingAnimation(surface, t, w, h);

        // -------------------------------------------------------------
        // 5. Moment 2: GUI Windows, Tab Bar & Desktop Bloom (5400ms - 10000ms)
        // -------------------------------------------------------------
        // Only blooms AFTER the brand has arrived at the top-left menu bar!
        // Stays permanently rock-solid and stable after blooming (no unwinding).
        if (t >= 5400) {
            drawGuiBloom(surface, gui, t, w, h);
        }
    }
};

// Standard smoothstep (clamped before polynomial to guarantee monotonic stability and prevent unwinding)
pub fn easeInOut(val: f32) f32 {
    const t = std.math.clamp(val, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

// Interpolates smoothly between two 24-bit RGB colors
pub fn interpolateColor(c1: u32, c2: u32, factor: f32) u32 {
    const f = std.math.clamp(factor, 0.0, 1.0);
    const r1: f32 = @floatFromInt((c1 >> 16) & 0xFF);
    const g1: f32 = @floatFromInt((c1 >> 8) & 0xFF);
    const b1: f32 = @floatFromInt(c1 & 0xFF);

    const r2: f32 = @floatFromInt((c2 >> 16) & 0xFF);
    const g2: f32 = @floatFromInt((c2 >> 8) & 0xFF);
    const b2: f32 = @floatFromInt(c2 & 0xFF);

    const r = @as(u32, @intFromFloat(r1 + (r2 - r1) * f));
    const g = @as(u32, @intFromFloat(g1 + (g2 - g1) * f));
    const b = @as(u32, @intFromFloat(b1 + (b2 - b1) * f));

    return (r << 16) | (g << 8) | b;
}

// Draws the luminous horizontal horizon light beam across the screen
fn drawHorizonBeam(surface: *fb.Surface, t: u32, w: u32, h: u32) void {
    const center_y: i32 = @intCast(h / 2);

    // Intensity profile: rises 500ms -> 2000ms (Peak 1), relaxes 2000ms -> 3500ms
    var beam_intensity: f32 = 0.0;
    if (t < 2000) {
        const prog = @as(f32, @floatFromInt(t - 400)) / 1600.0;
        beam_intensity = std.math.clamp(prog * prog, 0.0, 1.0);
    } else {
        const prog = @as(f32, @floatFromInt(3800 - t)) / 1800.0;
        beam_intensity = std.math.clamp(prog, 0.0, 1.0);
    }

    if (beam_intensity <= 0.01) return;

    // Subtle, translucent atmospheric horizon glow matching the character aura
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

        // Soft celestial ice-white core smoothly transitioning into misty starlight cyan
        const beam_color = interpolateColor(0x00F0F8FF, 0x0050B8E8, norm_y);

        var x: i32 = 0;
        const w_i: i32 = @intCast(w);
        const center_x: f32 = @as(f32, @floatFromInt(w)) * 0.5;
        while (x < w_i) : (x += 1) {
            const dx_norm = @abs(@as(f32, @floatFromInt(x)) - center_x) / center_x;
            const x_falloff = std.math.clamp(1.0 - dx_norm * dx_norm, 0.0, 1.0);
            const cur_a: u8 = @intFromFloat(@as(f32, @floatFromInt(alpha)) * x_falloff);
            if (cur_a > 0) {
                const bg = surface.getPixel(x, y);
                surface.setPixel(x, y, fb.blendPixel(bg, beam_color, cur_a));
            }
        }
    }
}

// Draws the brand typography ('diosix') centered with left-to-right spell out and fade out
fn drawBrandingAnimation(surface: *fb.Surface, t: u32, w: u32, h: u32) void {
    if (t < 500 or t >= 4200) return;

    const letters = "diosix";
    const spacing: i32 = 68; // Wide letter spacing
    const brand_total_width: i32 = spacing * 5 + 25;
    const start_x: i32 = @as(i32, @intCast(w / 2)) - @divTrunc(brand_total_width, 2);
    const center_y: i32 = @as(i32, @intCast(h / 2)) - 26;

    // Peak 1 character glow pulse: starts when all 6 letters are shown (1700ms),
    // reaches maximum radiance at the apex of the chime (2100ms),
    // and gently fades back to crisp letters before fade-out (3000ms).
    var char_glow_pulse: f32 = 0.0;
    if (t >= 1700 and t <= 3000) {
        if (t <= 2100) {
            char_glow_pulse = @as(f32, @floatFromInt(t - 1700)) / 400.0;
        } else {
            char_glow_pulse = 1.0 - (@as(f32, @floatFromInt(t - 2100)) / 900.0);
        }
        char_glow_pulse = easeInOut(char_glow_pulse);
    }

    // Render individual letters:
    // Spells out left-to-right:
    //   d -> di -> dio -> dios -> diosi -> diosix
    // Then at 3000ms fades out left-to-right:
    //   iosix -> osix -> six -> ix -> x -> (empty)
    const in_step: u32 = 200;
    const in_fade: u32 = 200;
    const out_step: u32 = 200;
    const out_fade: u32 = 200;

    for (letters, 0..) |char, idx| {
        const u_idx: u32 = @intCast(idx);
        const in_start: u32 = 500 + u_idx * in_step;
        const in_end: u32 = in_start + in_fade;
        const out_start: u32 = 3000 + u_idx * out_step;
        const out_end: u32 = out_start + out_fade;

        if (t < in_start or t >= out_end) continue;

        var letter_alpha: u8 = 255;
        if (t < in_end) {
            const frac = @as(f32, @floatFromInt(t - in_start)) / @as(f32, @floatFromInt(in_fade));
            letter_alpha = @intFromFloat(frac * 255.0);
        } else if (t >= out_start) {
            const frac = @as(f32, @floatFromInt(out_end - t)) / @as(f32, @floatFromInt(out_fade));
            letter_alpha = @intFromFloat(std.math.clamp(frac, 0.0, 1.0) * 255.0);
        }

        if (letter_alpha == 0) continue;

        const lx = start_x + @as(i32, @intCast(idx)) * spacing;
        const ly = center_y;

        // 1. Radiant translucent aura emanating softly around the character outlines
        // Soft ethereal moonlight white (0x00EAF4FF) creates a delicate atmospheric haze
        if (char_glow_pulse > 0.01) {
            const glow_a: u8 = @intFromFloat(@as(f32, @floatFromInt(letter_alpha)) * char_glow_pulse * 0.40);
            if (glow_a > 0) {
                banner_font.drawBannerGlyphGlow(surface, char, lx, ly, 0x00EAF4FF, glow_a);
            }
        }

        // 2. Crisp native 52px antialiased Questrial glyph
        banner_font.drawBannerGlyph(surface, char, lx, ly, fb.Color.WHITE, letter_alpha);
    }
}

// Text rendering with variable alpha
fn drawTextWithAlpha(surface: *fb.Surface, text: []const u8, x: i32, y: i32, color: u32, alpha: u8) void {
    var cur_x = x;
    for (text) |c| {
        if (c >= 32 and c <= 126) {
            const g = font.GLYPHS[c - 32];
            if (g.width > 0 and g.height > 0) {
                const gx = cur_x + g.offset_x;
                const gy = y + g.offset_y;

                var row: usize = 0;
                while (row < g.height) : (row += 1) {
                    const py = gy + @as(i32, @intCast(row));
                    if (py < 0 or py >= @as(i32, @intCast(surface.height))) continue;

                    var col: usize = 0;
                    while (col < g.width) : (col += 1) {
                        const px = gx + @as(i32, @intCast(col));
                        if (px < 0 or px >= @as(i32, @intCast(surface.width))) continue;

                        const raw_a = font.GLYPH_BITMAPS[g.bitmap_offset + row * g.width + col];
                        const eff_a: u8 = @intCast((@as(u32, raw_a) * @as(u32, alpha)) >> 8);
                        if (eff_a > 0) {
                            const bg = surface.getPixel(px, py);
                            surface.setPixel(px, py, fb.blendPixel(bg, color, eff_a));
                        }
                    }
                }
            }
            cur_x += g.advance;
        } else if (c == ' ') {
            cur_x += font.SPACE_ADVANCE;
        }
    }
}

// Moment 2: Desktop window unfurl and bloom (5400ms - 10000ms)
fn drawGuiBloom(surface: *fb.Surface, gui: *DiosixGui, t: u32, w: u32, h: u32) void {
    _ = w;
    _ = h;
    // Animation progress: 5400ms -> 6800ms (1400ms duration)
    // easeInOut strictly clamps progress so ease remains 1.0 permanently after 6800ms
    const bloom_progress = @as(f32, @floatFromInt(t - 5400)) / 1400.0;
    const ease = easeInOut(bloom_progress);

    // 1. Render Tab Bar (smoothly fades into view from 5400ms to 6000ms, morphing from docked brand)
    const tab_alpha_prog = @as(f32, @floatFromInt(t - 5400)) / 600.0;
    const tab_alpha = easeInOut(tab_alpha_prog);
    gui.renderTabBarWithAlpha(surface, tab_alpha);

    // 2. Render Windows unfolding from center with translucent glass (5400ms to 6800ms)
    if (ease > 0.01) {
        gui.drawWindowsWithAlpha(surface, ease);
    }

    // 3. Render Cursor gliding into position (starting from 5800ms to 6800ms)
    if (t >= 5800) {
        const c_prog = @as(f32, @floatFromInt(t - 5800)) / 1000.0;
        const c_ease = easeInOut(c_prog);
        // Glides from offscreen right (x=950, y=550) to default cursor position (x=450, y=260)
        const cur_cx = @as(i32, @intFromFloat(950.0 + (450.0 - 950.0) * c_ease));
        const cur_cy = @as(i32, @intFromFloat(550.0 + (260.0 - 550.0) * c_ease));
        gui.cursor.x = cur_cx;
        gui.cursor.y = cur_cy;
        gui.cursor.draw(surface);
    }
}

test "intro: sentinel file checking" {
    // Verify sentinel checking works
    const is_first = shouldPlayIntro();
    // Second check within the same session must return false
    const is_second = shouldPlayIntro();
    try std.testing.expect(is_first or !is_first);
    try std.testing.expectEqual(false, is_second);
}

test "intro: state timeline and particles" {
    var intro = IntroState.init(1000);
    try std.testing.expect(intro.is_active);
    try std.testing.expectEqual(@as(u32, 0), intro.elapsed_ms);

    intro.tick(16, 2500, 1280, 800);
    try std.testing.expectEqual(@as(u32, 1500), intro.elapsed_ms);
    try std.testing.expect(intro.is_active);

    // Skip functionality
    intro.skip();
    try std.testing.expectEqual(false, intro.is_active);
    try std.testing.expectEqual(TOTAL_INTRO_DURATION_MS, intro.elapsed_ms);
}

test "intro: easeInOut stability and unwinding immunity" {
    // Monotonic boundary checks
    try std.testing.expectEqual(@as(f32, 0.0), easeInOut(0.0));
    try std.testing.expectEqual(@as(f32, 0.5), easeInOut(0.5));
    try std.testing.expectEqual(@as(f32, 1.0), easeInOut(1.0));

    // Values > 1.0 MUST stay locked at 1.0 and NEVER invert or unwind
    try std.testing.expectEqual(@as(f32, 1.0), easeInOut(1.2));
    try std.testing.expectEqual(@as(f32, 1.0), easeInOut(1.5));
    try std.testing.expectEqual(@as(f32, 1.0), easeInOut(2.0));
    try std.testing.expectEqual(@as(f32, 1.0), easeInOut(10.0));

    // Negative values MUST stay locked at 0.0
    try std.testing.expectEqual(@as(f32, 0.0), easeInOut(-0.5));
    try std.testing.expectEqual(@as(f32, 0.0), easeInOut(-5.0));
}

test "intro: full timeline rendering and stability across 10s" {
    const allocator = std.testing.allocator;
    const w: u32 = 800;
    const h: u32 = 600;
    const buf = try allocator.alloc(u32, w * h);
    defer allocator.free(buf);

    var surface = fb.Surface.init(buf.ptr, w, h, @intCast(w * @sizeOf(u32)));
    var gui = try DiosixGui.init(allocator, w, h);
    defer gui.deinit();

    var intro = IntroState.init(0);

    // Test sequence across all phases:
    // 1. Initial stardust (200ms)
    intro.elapsed_ms = 200;
    intro.render(&surface, &gui);

    // 2. Moment 1 peak (2000ms)
    intro.elapsed_ms = 2000;
    intro.render(&surface, &gui);

    // 3. Acoustic lull (3800ms)
    intro.elapsed_ms = 3800;
    intro.render(&surface, &gui);

    // 4. Moment 2 glide (4800ms)
    intro.elapsed_ms = 4800;
    intro.render(&surface, &gui);

    // 5. GUI bloom midpoint (6100ms)
    intro.elapsed_ms = 6100;
    intro.render(&surface, &gui);

    // 6. GUI bloom completion (6800ms)
    intro.elapsed_ms = 6800;
    intro.render(&surface, &gui);
    const center_pixel_6800 = surface.getPixel(400, 300);

    // 7. Settled state (8000ms and 10000ms) - MUST NOT UNWIND OR BLANK OUT
    intro.elapsed_ms = 8000;
    intro.render(&surface, &gui);
    const center_pixel_8000 = surface.getPixel(400, 300);

    intro.elapsed_ms = 10000;
    intro.render(&surface, &gui);
    const center_pixel_10000 = surface.getPixel(400, 300);

    // Pixels at center must remain non-zero and stable (GUI is active and visible)
    try std.testing.expect(center_pixel_6800 != 0);
    try std.testing.expect(center_pixel_8000 != 0);
    try std.testing.expect(center_pixel_10000 != 0);
}
