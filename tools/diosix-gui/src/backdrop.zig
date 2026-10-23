// Computed Morphing 2D Color Backdrop Engine for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("framebuffer.zig");
const Box = fb.Box;
const Color = fb.Color;
const Surface = fb.Surface;

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

    pub inline fn rowColor(self: RgbGradient, y: i32) u32 {
        const rgb = self.rowBase(y);
        return Color.rgb(
            @intCast(rgb[0]),
            @intCast(rgb[1]),
            @intCast(rgb[2]),
        );
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

pub const BackdropScheme = enum(u8) {
    spring = 0,
    summer = 1,
    autumn = 2,
    winter = 3,
    rainbow = 4,

    pub fn label(self: BackdropScheme) []const u8 {
        return switch (self) {
            .spring => "Spring",
            .summer => "Summer",
            .autumn => "Autumn",
            .winter => "Winter",
            .rainbow => "Rainbow",
        };
    }

    pub fn topColor(self: BackdropScheme) u32 {
        return switch (self) {
            .spring => Color.SCHEME_SPRING_TOP,
            .summer => Color.SCHEME_SUMMER_TOP,
            .autumn => Color.SCHEME_AUTUMN_TOP,
            .winter => Color.SCHEME_WINTER_TOP,
            .rainbow => Color.SKY_BASE_TOP,
        };
    }

    pub fn fromTopColor(top_color: u32) ?BackdropScheme {
        return switch (top_color) {
            Color.SKY_BASE_TOP => .rainbow,
            Color.SCHEME_SPRING_TOP => .spring,
            Color.SCHEME_SUMMER_TOP => .summer,
            Color.SCHEME_AUTUMN_TOP => .autumn,
            Color.SCHEME_WINTER_TOP => .winter,
            else => null,
        };
    }
};

pub const MorphField = struct {
    den_x: i32,
    den_y: i32,
    cos_t: i32,
    sin_t: i32,
    shift_u: i32,
    shift_v: i32,
    scheme: BackdropScheme = .rainbow,

    pub fn init(
        width: u32,
        height: u32,
        drift_x: i32,
        drift_y: i32,
    ) MorphField {
        return initScheme(width, height, drift_x, drift_y, .rainbow);
    }

    pub fn initScheme(
        width: u32,
        height: u32,
        drift_x: i32,
        drift_y: i32,
        scheme: BackdropScheme,
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
            .scheme = scheme,
        };
    }

    inline fn lerpCh(c0: u32, c1: u32, t: u32) u32 {
        return (c0 * (255 - t) + c1 * t) / 255;
    }

    inline fn blendTriad(
        c0: [3]u32,
        c1: [3]u32,
        c2: [3]u32,
        u: u32,
        v: u32,
    ) u32 {
        const mr = lerpCh(c0[0], c1[0], u);
        const mg = lerpCh(c0[1], c1[1], u);
        const mb = lerpCh(c0[2], c1[2], u);
        const vw = (v * 3) >> 2;
        const r: u8 = @intCast(lerpCh(mr, c2[0], vw));
        const g: u8 = @intCast(lerpCh(mg, c2[1], vw));
        const b: u8 = @intCast(lerpCh(mb, c2[2], vw));
        return Color.rgb(r, g, b);
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
        return switch (self.scheme) {
            .spring => blendTriad(
                .{ 206, 245, 212 },
                .{ 126, 214, 146 },
                .{ 236, 248, 198 },
                u,
                v,
            ),
            .summer => blendTriad(
                .{ 255, 232, 132 },
                .{ 244, 118, 114 },
                .{ 252, 194, 136 },
                u,
                v,
            ),
            .autumn => blendTriad(
                .{ 208, 92, 24 },
                .{ 230, 0, 0 },
                .{ 52, 22, 12 },
                u,
                v,
            ),
            .winter => blendTriad(
                .{ 28, 68, 124 },
                .{ 12, 26, 52 },
                .{ 54, 102, 152 },
                u,
                v,
            ),
            .rainbow => Color.rgb(
                @intCast(u),
                @intCast(v),
                @intCast(255 - ((u + v) >> 1)),
            ),
        };
    }
};

pub inline fn mod256(a: i32, b: i32) usize {
    return @intCast(@mod(@as(i64, a) + @as(i64, b), 256));
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

    if (BackdropScheme.fromTopColor(top_color)) |scheme| {
        const morph = MorphField.initScheme(
            width,
            height,
            drift_x,
            drift_y,
            scheme,
        );
        return morph.samplePixel(cx, cy);
    }

    const grad = RgbGradient.init(top_color, bot_color, height);
    return grad.rowColor(cy);
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

    if (BackdropScheme.fromTopColor(top_color)) |scheme| {
        const morph = MorphField.initScheme(w, h, drift_x, drift_y, scheme);
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
        const row_col = grad.rowColor(@intCast(y));
        const row_offset = y * pixels_per_row;
        @memset(self.pixels[row_offset + x0 .. row_offset + x1], row_col);
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
    std.testing.refAllDecls(@This());
}
