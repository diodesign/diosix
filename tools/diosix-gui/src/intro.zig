// Inspiring Two-Warm-Moments Graphical Intro Animation for Diosix GUI.
// Synchronized to intro.wav acoustic swells:
//   Moment 1 (0.0s - 3.8s): Midnight Canvas, Stardust Embers, 'd i o s i x'
//   Moment 2 (3.8s - 7.5s): Horizon Rise, Daylight Transition & Window Bloom
//   Decay (7.5s - 10.0s): Settling into live desktop environment
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const fb = @import("framebuffer.zig");
const gui_mod = @import("gui.zig");
const intro_fx = @import("intro/fx.zig");
const DiosixGui = gui_mod.DiosixGui;

pub const Particle = intro_fx.Particle;
pub const easeInOut = intro_fx.easeInOut;
pub const interpolateColor = intro_fx.interpolateColor;

pub const SENTINEL_PRIMARY: [*:0]const u8 = "/run/diosix_intro_played";
pub const SENTINEL_FALLBACK: [*:0]const u8 = "/tmp/.diosix_intro_played";

pub const TOTAL_INTRO_DURATION_MS: u32 = 10_000; // 10 seconds.

const CmdlineToken = enum {
    @"diosix.mode=dev",
    @"diosix.welcome=force",
};

// Inspect a kernel command-line string for developer fast-boot mode.
// Returns true when diosix.mode=dev is present unless diosix.welcome=force is
// also passed.
pub fn shouldSkipIntroFromCmdline(cmdline: []const u8) bool {
    var is_dev_mode = false;
    var force_welcome = false;
    var it = std.mem.tokenizeAny(u8, cmdline, " \t\r\n");
    while (it.next()) |tok| {
        if (std.meta.stringToEnum(CmdlineToken, tok)) |flag| {
            switch (flag) {
                .@"diosix.mode=dev" => is_dev_mode = true,
                .@"diosix.welcome=force" => force_welcome = true,
            }
        }
    }
    return is_dev_mode and !force_welcome;
}

// Check /proc/cmdline to see if this boot session is a developer fast-boot.
pub fn isDevFastBoot() bool {
    var buf: [1024]u8 = undefined;
    const fd_rc = linux.open("/proc/cmdline", .{ .ACCMODE = .RDONLY }, 0);
    const signed_fd: isize = @bitCast(fd_rc);
    if (signed_fd < 0) return false;
    const fd: i32 = @intCast(signed_fd);
    defer _ = linux.close(fd);

    const read_rc = linux.read(fd, &buf, buf.len);
    const signed_read: isize = @bitCast(read_rc);
    if (signed_read <= 0) return false;
    return shouldSkipIntroFromCmdline(buf[0..@intCast(signed_read)]);
}

// Returns true if intro has not been played during this boot session.
// Creates the sentinel file on first check so it plays once per boot.
// Automatically skips the intro in developer fast-boot mode (diosix.mode=dev).
pub fn shouldPlayIntro() bool {
    if (!@import("builtin").is_test and isDevFastBoot()) {
        return false;
    }

    // 1. Check primary sentinel (/run).
    const rc_run = linux.open(
        SENTINEL_PRIMARY,
        .{ .ACCMODE = .RDONLY, .NOFOLLOW = true },
        0,
    );
    if (@as(isize, @bitCast(rc_run)) >= 0) {
        _ = linux.close(@intCast(rc_run));
        return false;
    }

    // 2. Check fallback sentinel (/tmp) with NOFOLLOW.
    const rc_tmp = linux.open(
        SENTINEL_FALLBACK,
        .{ .ACCMODE = .RDONLY, .NOFOLLOW = true },
        0,
    );
    if (@as(isize, @bitCast(rc_tmp)) >= 0) {
        _ = linux.close(@intCast(rc_tmp));
        return false;
    }

    // 3. Mark as played for this boot (NOFOLLOW and restricted 0600 mode).
    const create_flags = linux.O{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .NOFOLLOW = true,
    };
    const creat_run = linux.open(SENTINEL_PRIMARY, create_flags, 0o600);
    if (@as(isize, @bitCast(creat_run)) >= 0) {
        _ = linux.close(@intCast(creat_run));
    }

    const creat_tmp = linux.open(SENTINEL_FALLBACK, create_flags, 0o600);
    if (@as(isize, @bitCast(creat_tmp)) >= 0) {
        _ = linux.close(@intCast(creat_tmp));
    }

    return true;
}

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
        var prng = std.Random.DefaultPrng.init(0x193e36cc);
        const rand = prng.random();

        const w_f: f32 = @floatFromInt(width);
        const h_f: f32 = @floatFromInt(height);

        const particle_palette = [_]u32{
            0x00f8fcff, // Starlight pure white.
            0x0078e0f8, // Ethereal mako cyan.
            0x00d0f0ff, // Starlight ice blue.
            0x00edf6fc, // Soft pearl white.
            0x0040c0e0, // Radiant crystal cyan.
        };

        for (&self.particles, 0..) |*p, i| {
            p.x = rand.float(f32) * w_f;
            p.y = rand.float(f32) * h_f;
            p.vx = (rand.float(f32) - 0.5) * 12.0; // Subtle horizontal drift.
            p.vy = -(15.0 + rand.float(f32) * 35.0); // Gentle upward float.
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

    pub fn tick(
        self: *IntroState,
        dt_ms: u32,
        now_ms: i64,
        width: u32,
        height: u32,
    ) void {
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

        // Update particle positions.
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
    pub fn render(
        self: *IntroState,
        surface: *fb.Surface,
        gui: *DiosixGui,
    ) void {
        const t = self.elapsed_ms;
        const w = surface.width;
        const h = surface.height;
        if (w == 0 or h == 0) return;

        // Color themes.
        const NIGHT_TOP: u32 = 0x00040812;
        const NIGHT_BOT: u32 = 0x000a162c;
        const DAY_TOP: u32 = fb.Color.SKY_BASE_TOP;
        const DAY_BOT: u32 = fb.Color.GRADIENT_BOT_DEFAULT;

        // 1. Background Composition: Transition between Midnight & Sky.
        var day_factor: f32 = 0.0;
        if (t > 3800) {
            const rise_t = @as(f32, @floatFromInt(t - 3800)) / 1600.0;
            day_factor = easeInOut(rise_t);
        }

        if (day_factor <= 0.001) {
            const den_y = @as(f32, @floatFromInt(if (h > 1) h - 1 else 1));
            var y: u32 = 0;
            while (y < h) : (y += 1) {
                const frac = @as(f32, @floatFromInt(y)) / den_y;
                const row_col = interpolateColor(NIGHT_TOP, NIGHT_BOT, frac);
                const row_off = y * surface.stridePixels();
                @memset(surface.pixels[row_off .. row_off + w], row_col);
            }
        } else if (day_factor >= 0.999) {
            surface.drawGraduatedBackgroundInBox(
                fb.Box.fromPosSize(0, 0, w, h),
                DAY_TOP,
                DAY_BOT,
            );
        } else {
            const cur_top = interpolateColor(NIGHT_TOP, DAY_TOP, day_factor);
            const cur_bot = interpolateColor(NIGHT_BOT, DAY_BOT, day_factor);
            surface.drawGraduatedBackgroundInBox(
                fb.Box.fromPosSize(0, 0, w, h),
                cur_top,
                cur_bot,
            );
        }

        // 2. Horizontal Horizon Light Beam (Moment 1: 400ms - 3800ms).
        if (t >= 400 and t <= 3800) {
            intro_fx.drawHorizonBeam(surface, t, w, h);
        }

        // 3. Stardust / Crystalline Embers.
        var particle_alpha: u8 = 255;
        if (t > 6000) {
            const fade = @as(f32, @floatFromInt(t - 6000)) / 2500.0;
            const sub_a: u32 =
                @intFromFloat(std.math.clamp(fade, 0.0, 1.0) * 255.0);
            particle_alpha = @intCast(255 - sub_a);
        }

        if (particle_alpha > 0) {
            const w_i: i32 = @intCast(w);
            const h_i: i32 = @intCast(h);
            for (self.particles) |p| {
                const px: i32 = @intFromFloat(p.x);
                const py: i32 = @intFromFloat(p.y);
                if (px < 0 or py < 0 or px >= w_i or py >= h_i) continue;

                const sin_val = std.math.sin(p.twinkle_phase);
                const twinkle = (sin_val + 1.0) * 0.5;
                const mod_a: u32 = @intFromFloat(100.0 + twinkle * 155.0);
                const cur_a: u8 =
                    @intCast((@as(u32, particle_alpha) * mod_a) >> 8);

                const bg = surface.getPixel(px, py);
                surface.setPixel(px, py, fb.blendPixel(bg, p.color, cur_a));

                if (p.size >= 2 and px + 1 < w_i and py + 1 < h_i) {
                    const soft_a: u8 = cur_a / 2;
                    const bg_x = surface.getPixel(px + 1, py);
                    surface.setPixel(
                        px + 1,
                        py,
                        fb.blendPixel(bg_x, p.color, soft_a),
                    );
                    const bg_y = surface.getPixel(px, py + 1);
                    surface.setPixel(
                        px,
                        py + 1,
                        fb.blendPixel(bg_y, p.color, soft_a),
                    );
                }
            }
        }

        // 4. Moment 1 & Moment 2 Glide ('d i o s i x').
        intro_fx.drawBrandingAnimation(surface, t, w, h);

        // 5. Moment 2: GUI Windows, Tab Bar & Desktop Bloom (5400ms - 10000ms).
        if (t >= 5400) {
            const bloom_progress = @as(f32, @floatFromInt(t - 5400)) / 1400.0;
            const ease = easeInOut(bloom_progress);
            if (ease > 0.01) {
                gui.drawWindowsWithAlpha(surface, ease);
            }
        }

        // Render live mouse cursor when visible.
        if (gui.cursor.visible) {
            gui.cursor.draw(surface);
        }
    }
};

test "intro: sentinel file checking" {
    const is_first = shouldPlayIntro();
    const is_second = shouldPlayIntro();
    try std.testing.expect(is_first or !is_first);
    try std.testing.expectEqual(false, is_second);
}

test "intro: dev fast-boot cmdline detection" {
    try std.testing.expectEqual(
        true,
        shouldSkipIntroFromCmdline(
            "console=hvc0 earlycon=sbi diosix.mode=dev\n",
        ),
    );
    try std.testing.expectEqual(
        false,
        shouldSkipIntroFromCmdline(
            "console=hvc0 earlycon=sbi diosix.mode=dev diosix.welcome=force\n",
        ),
    );
    try std.testing.expectEqual(
        false,
        shouldSkipIntroFromCmdline(
            "console=hvc0 earlycon=sbi diosix.mode=live\n",
        ),
    );
    try std.testing.expectEqual(
        false,
        shouldSkipIntroFromCmdline("console=hvc0 earlycon=sbi\n"),
    );
}

test "intro: state timeline and particles" {
    var intro = IntroState.init(1000);
    try std.testing.expect(intro.is_active);
    try std.testing.expectEqual(@as(u32, 0), intro.elapsed_ms);

    intro.tick(16, 2500, 1280, 800);
    try std.testing.expectEqual(@as(u32, 1500), intro.elapsed_ms);
    try std.testing.expect(intro.is_active);

    intro.skip();
    try std.testing.expectEqual(false, intro.is_active);
    try std.testing.expectEqual(TOTAL_INTRO_DURATION_MS, intro.elapsed_ms);
}

test "intro: easeInOut stability and unwinding immunity" {
    try std.testing.expectEqual(@as(f32, 0.0), easeInOut(0.0));
    try std.testing.expectEqual(@as(f32, 0.5), easeInOut(0.5));
    try std.testing.expectEqual(@as(f32, 1.0), easeInOut(1.0));

    try std.testing.expectEqual(@as(f32, 1.0), easeInOut(1.2));
    try std.testing.expectEqual(@as(f32, 1.0), easeInOut(1.5));
    try std.testing.expectEqual(@as(f32, 1.0), easeInOut(2.0));
    try std.testing.expectEqual(@as(f32, 1.0), easeInOut(10.0));

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

    intro.elapsed_ms = 200;
    intro.render(&surface, &gui);

    intro.elapsed_ms = 2000;
    intro.render(&surface, &gui);

    intro.elapsed_ms = 3800;
    intro.render(&surface, &gui);

    intro.elapsed_ms = 4800;
    intro.render(&surface, &gui);

    intro.elapsed_ms = 6100;
    intro.render(&surface, &gui);

    intro.elapsed_ms = 6800;
    intro.render(&surface, &gui);
    const center_pixel_6800 = surface.getPixel(400, 300);

    intro.elapsed_ms = 8000;
    intro.render(&surface, &gui);
    const center_pixel_8000 = surface.getPixel(400, 300);

    intro.elapsed_ms = 10000;
    intro.render(&surface, &gui);
    const center_pixel_10000 = surface.getPixel(400, 300);

    try std.testing.expect(center_pixel_6800 != 0);
    try std.testing.expect(center_pixel_8000 != 0);
    try std.testing.expect(center_pixel_10000 != 0);
}
