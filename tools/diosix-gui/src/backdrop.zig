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
    const r: u8 = @intCast((r_base * inv_alpha + 255 * cloud_alpha) >> 8);
    const g: u8 = @intCast((g_base * inv_alpha + 255 * cloud_alpha) >> 8);
    const b: u8 = @intCast((b_base * inv_alpha + 255 * cloud_alpha) >> 8);
    return Color.rgb(r, g, b);
}

pub const blur = @import("backdrop/blur.zig");
pub const computeGaussianKernel = blur.computeGaussianKernel;
pub const drawBlurredBackdropInBoxDrift = blur.drawBlurredBackdropInBoxDrift;
pub const drawBlurredBackdropInBox = blur.drawBlurredBackdropInBox;

pub const RgbGradient = struct {
    top_r: i32,
    top_g: i32,
    top_b: i32,
    bot_r: i32,
    bot_g: i32,
    bot_b: i32,
    den_y: i32,

    pub fn init(top_color: u32, bot_color: u32, height: u32) RgbGradient {
        return .{
            .top_r = @intCast(Color.r(top_color)),
            .top_g = @intCast(Color.g(top_color)),
            .top_b = @intCast(Color.b(top_color)),
            .bot_r = @intCast(Color.r(bot_color)),
            .bot_g = @intCast(Color.g(bot_color)),
            .bot_b = @intCast(Color.b(bot_color)),
            .den_y = @intCast(if (height > 1) height - 1 else 1),
        };
    }

    pub inline fn rowBase(self: RgbGradient, y: i32) [3]u32 {
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

pub const SIN_LUT: [256]i32 = blk: {
    @setEvalBranchQuota(4000);
    var table: [256]i32 = undefined;
    for (0..256) |i| {
        const angle =
            (@as(f64, @floatFromInt(i)) * 2.0 * std.math.pi) / 256.0;
        table[i] = @intFromFloat(@round(@sin(angle) * 256.0));
    }
    break :blk table;
};

pub const MorphField = struct {
    den_x: i32,
    den_y: i32,
    cos_t: i32,
    sin_t: i32,
    shift_u: i32,
    shift_v: i32,

    pub fn init(
        width: u32,
        height: u32,
        drift_x: i32,
        drift_y: i32,
    ) MorphField {
        const phase = mod256(drift_x, drift_y);
        const cos_t = SIN_LUT[(phase + 64) & 255];
        const sin_t = SIN_LUT[phase & 255];
        const shift_u = (SIN_LUT[(phase * 2) & 255] * 36) >> 8;
        const shift_v = (SIN_LUT[(phase * 3) & 255] * 36) >> 8;
        return .{
            .den_x = @intCast(if (width > 1) width - 1 else 1),
            .den_y = @intCast(if (height > 1) height - 1 else 1),
            .cos_t = cos_t,
            .sin_t = sin_t,
            .shift_u = shift_u,
            .shift_v = shift_v,
        };
    }

    pub inline fn samplePixel(self: MorphField, cx: i32, cy: i32) u32 {
        const base_u = @divTrunc(cx * 255, self.den_x);
        const base_v = @divTrunc(cy * 255, self.den_y);
        const du = base_u - 128;
        const dv = base_v - 128;
        const u_raw =
            128 + ((du * self.cos_t - dv * self.sin_t) >> 8) + self.shift_u;
        const v_raw =
            128 + ((du * self.sin_t + dv * self.cos_t) >> 8) + self.shift_v;
        const u: u32 = @intCast(std.math.clamp(u_raw, 0, 255));
        const v: u32 = @intCast(std.math.clamp(v_raw, 0, 255));
        const r: u8 = @intCast(u);
        const g: u8 = @intCast(v);
        const b: u8 = @intCast(255 - ((u + v) >> 1));
        return Color.rgb(r, g, b);
    }
};

pub inline fn mod256(a: i32, b: i32) usize {
    return @intCast(@mod(@as(i64, a) + @as(i64, b), 256));
}

pub inline fn sampleCloudRowPixel(
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
// morphing 2D color placement (or custom top/bottom gradient override).
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

    if (top_color == Color.SKY_BASE_TOP) {
        const morph = MorphField.init(width, height, drift_x, drift_y);
        return morph.samplePixel(cx, cy);
    }

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

// Graduated/morphing background constrained to target box with morph offset.
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

    const pixels_per_row = self.stridePixels();

    const x0: usize = @intCast(@max(0, clipped.x0));
    const x1: usize = @intCast(@max(0, clipped.x1));
    const y0: usize = @intCast(@max(0, clipped.y0));
    const y1: usize = @intCast(@max(0, clipped.y1));

    if (top_color == Color.SKY_BASE_TOP) {
        const morph = MorphField.init(w, h, drift_x, drift_y);
        var y: usize = y0;
        while (y < y1) : (y += 1) {
            const vy: i32 = @intCast(y);
            const row_offset = y * pixels_per_row;
            var x: usize = x0;
            while (x < x1) : (x += 1) {
                self.pixels[row_offset + x] =
                    morph.samplePixel(@intCast(x), vy);
            }
        }
        return;
    }

    const grad = RgbGradient.init(top_color, bot_color, h);
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

test "backdrop: morphing 2D gradient corners and phase evolution" {
    const morph0 = MorphField.init(400, 400, 0, 0);
    // Top-left (0, 0) -> Blue (0, 0, 255).
    try std.testing.expectEqual(
        Color.rgb(0, 0, 255),
        morph0.samplePixel(0, 0),
    );
    // Top-right (399, 0) -> Magenta (255, 0, 128).
    try std.testing.expectEqual(
        Color.rgb(255, 0, 128),
        morph0.samplePixel(399, 0),
    );
    // Bottom-left (0, 399) -> Mint (0, 255, 128).
    try std.testing.expectEqual(
        Color.rgb(0, 255, 128),
        morph0.samplePixel(0, 399),
    );
    // Bottom-right (399, 399) -> Yellow (255, 255, 0).
    try std.testing.expectEqual(
        Color.rgb(255, 255, 0),
        morph0.samplePixel(399, 399),
    );

    // Advancing morph phase shifts color placement across the canvas.
    const morph_shifted = MorphField.init(400, 400, 32, 0);
    try std.testing.expect(
        morph0.samplePixel(100, 100) != morph_shifted.samplePixel(100, 100),
    );
}

test {
    _ = blur;
    std.testing.refAllDecls(@This());
}
