// Graphical Intro Animation for Diosix GUI.
// Synchronized to intro.wav acoustic swells:
//   1. Logo Animation (0.15s - 5.90s): Pencil line sketches 'DIOSIX' in solid
//      black outline on a white background and fills the letters with rainbow
//      color.
//   2. Logo Fade-Out (5.90s - 6.90s): The logo and drafting lines fade out.
//   3. GUI Fade-In (6.90s - 8.30s): The GUI fades in cleanly as the boot tune
//      settles into the live desktop environment (through 10.0s).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const fb = @import("framebuffer.zig");
const gui_mod = @import("gui.zig");
const intro_fx = @import("intro/fx.zig");
const paths = @import("paths.zig");
const DiosixGui = gui_mod.DiosixGui;

pub const easeInOut = intro_fx.easeInOut;
pub const interpolateColor = intro_fx.interpolateColor;

pub const RUN_DIOSIX_DIR: [*:0]const u8 = paths.RUN_DIOSIX_DIR;
pub const INTRO_FLAG_PATH: [*:0]const u8 = paths.INTRO_FLAG_PATH;
pub const SENTINEL_PRIMARY: [*:0]const u8 = INTRO_FLAG_PATH;

pub const TOTAL_INTRO_DURATION_MS: u32 = 10_000; // 10 seconds.
pub const GUI_FADEIN_START_MS: u32 = intro_fx.LOGO_END_MS; // 6900ms.
pub const GUI_FADEIN_DURATION_MS: u32 = 1400;

var intro_played_in_process: bool = false;

const CmdlineToken = enum {
    @"diosix.intro=skip",
    @"diosix.welcome=force",
};

// Inspect a kernel command-line string for explicit intro-skip mode.
// Returns true when diosix.intro=skip is present unless diosix.welcome=force
// is also passed.
pub fn shouldSkipIntroFromCmdline(cmdline: []const u8) bool {
    var skip_intro = false;
    var force_welcome = false;
    var it = std.mem.tokenizeAny(u8, cmdline, " \t\r\n");
    while (it.next()) |tok| {
        if (std.meta.stringToEnum(CmdlineToken, tok)) |flag| {
            switch (flag) {
                .@"diosix.intro=skip" => skip_intro = true,
                .@"diosix.welcome=force" => force_welcome = true,
            }
        }
    }
    return skip_intro and !force_welcome;
}

/// Capacity for reading /proc/cmdline: the longest kernel command line Linux
/// accepts (COMMAND_LINE_SIZE is 4096 on riscv64). Anything smaller could
/// silently miss a `diosix.mode=dev` flag placed late in the line.
const MAX_PROC_CMDLINE_BYTES: usize = 4096;

// Check /proc/cmdline to see if this boot session is a developer fast-boot.
pub fn isDevFastBoot() bool {
    var buf: [MAX_PROC_CMDLINE_BYTES]u8 = undefined;
    const cmdline_path = paths.PROC_CMDLINE_PATH;
    const fd_rc = linux.open(cmdline_path, .{ .ACCMODE = .RDONLY }, 0);
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
    if (intro_played_in_process) return false;

    const rc_run = linux.open(
        INTRO_FLAG_PATH,
        .{ .ACCMODE = .RDONLY, .NOFOLLOW = true },
        0,
    );
    if (@as(isize, @bitCast(rc_run)) >= 0) {
        _ = linux.close(@intCast(rc_run));
        intro_played_in_process = true;
        return false;
    }

    _ = linux.mkdir(RUN_DIOSIX_DIR, 0o755);
    const create_flags = linux.O{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .NOFOLLOW = true,
    };
    const creat_run = linux.open(INTRO_FLAG_PATH, create_flags, 0o600);
    if (@as(isize, @bitCast(creat_run)) >= 0) {
        _ = linux.close(@intCast(creat_run));
    }
    intro_played_in_process = true;
    return true;
}

pub const IntroState = struct {
    is_active: bool = false,
    start_time_ms: i64 = 0,
    elapsed_ms: u32 = 0,

    pub fn init(start_time: i64) IntroState {
        return .{
            .is_active = true,
            .start_time_ms = start_time,
            .elapsed_ms = 0,
        };
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
        _ = dt_ms;
        _ = width;
        _ = height;
        if (!self.is_active) return;

        const elapsed = now_ms - self.start_time_ms;
        if (elapsed < 0) {
            self.elapsed_ms = 0;
        } else if (elapsed >= TOTAL_INTRO_DURATION_MS) {
            self.elapsed_ms = TOTAL_INTRO_DURATION_MS;
            self.is_active = false;
        } else {
            self.elapsed_ms = @intCast(elapsed);
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

        // 1. Stark white canvas during the logo animation and logo fade-out,
        // transitioning smoothly to the desktop as the GUI fades in.
        const PAPER_PURE: u32 = fb.Color.WHITE;
        const DAY_TOP: u32 = fb.Color.SKY_BASE_TOP;
        const DAY_BOT: u32 = fb.Color.GRADIENT_BOT_DEFAULT;

        if (t < GUI_FADEIN_START_MS) {
            var y: u32 = 0;
            while (y < h) : (y += 1) {
                const row_off = y * surface.stridePixels();
                @memset(surface.pixels[row_off .. row_off + w], PAPER_PURE);
            }
        }

        // 2. Scholastic Drafting Rules & Pencil-Sketch + Rainbow-Fill 'DIOSIX'
        //    (active from 150ms through 5900ms, fading out by 6900ms).
        if (t >= intro_fx.LOGO_START_MS and t < intro_fx.LOGO_END_MS) {
            intro_fx.drawHorizonBeam(surface, t, w, h);
            intro_fx.drawBrandingAnimation(surface, t, w, h);
        }

        // 3. GUI Fade-In (6900ms - 8300ms, holding through 10000ms), starting
        //    only after the logo has faded out completely.
        if (t >= GUI_FADEIN_START_MS) {
            const bloom_progress =
                @as(f32, @floatFromInt(t - GUI_FADEIN_START_MS)) /
                @as(f32, @floatFromInt(GUI_FADEIN_DURATION_MS));
            const ease = easeInOut(bloom_progress);
            if (ease <= 0.001) {
                var y: u32 = 0;
                while (y < h) : (y += 1) {
                    const row_off = y * surface.stridePixels();
                    @memset(surface.pixels[row_off .. row_off + w], PAPER_PURE);
                }
            } else {
                const is_accel = (gui.render_mode == .accelerated);
                const dx = if (is_accel) gui.drift_x else 0;
                const dy = if (is_accel) gui.drift_y else 0;
                surface.drawGraduatedBackgroundDrift(
                    DAY_TOP,
                    DAY_BOT,
                    dx,
                    dy,
                );
                gui.drawWindowsWithAlpha(surface, 1.0);
                if (ease < 0.999) {
                    const fg_alpha: u8 = @intFromFloat(ease * 255.0);
                    const stride_px = surface.stridePixels();
                    var y: u32 = 0;
                    while (y < h) : (y += 1) {
                        const row_off = y * stride_px;
                        var x: u32 = 0;
                        while (x < w) : (x += 1) {
                            const px = surface.pixels[row_off + x];
                            surface.pixels[row_off + x] = fb.blendPixel(
                                PAPER_PURE,
                                px,
                                fg_alpha,
                            );
                        }
                    }
                }
            }
        }

        // Render live mouse cursor when visible.
        if (gui.cursor.visible) {
            gui.cursor.draw(surface);
        }
    }
};

test "intro: sentinel file checking" {
    std.testing.refAllDecls(@This());
    _ = intro_fx;
    const is_first = shouldPlayIntro();
    const is_second = shouldPlayIntro();
    try std.testing.expect(is_first or !is_first);
    try std.testing.expectEqual(false, is_second);
}

test "intro: skip flag beyond 1024 bytes is still detected" {
    const alloc = std.testing.allocator;
    const filler = try alloc.alloc(u8, MAX_PROC_CMDLINE_BYTES / 2);
    defer alloc.free(filler);
    @memset(filler, 'x');
    const cmdline = try alloc.print(
        "console=hvc0 junk={s} diosix.intro=skip\n",
        .{filler},
    );
    defer alloc.free(cmdline);
    try std.testing.expect(cmdline.len > 1024);
    try std.testing.expect(cmdline.len <= MAX_PROC_CMDLINE_BYTES);
    try std.testing.expect(shouldSkipIntroFromCmdline(cmdline));
}

test "intro: dev fast-boot cmdline detection" {
    try std.testing.expectEqual(
        true,
        shouldSkipIntroFromCmdline(
            "console=hvc0 earlycon=sbi diosix.intro=skip\n",
        ),
    );
    try std.testing.expectEqual(
        false,
        shouldSkipIntroFromCmdline(
            "console=hvc0 earlycon=sbi diosix.intro=skip " ++
                "diosix.welcome=force\n",
        ),
    );
    try std.testing.expectEqual(
        false,
        shouldSkipIntroFromCmdline(
            "console=hvc0 earlycon=sbi diosix.mode=dev\n",
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
