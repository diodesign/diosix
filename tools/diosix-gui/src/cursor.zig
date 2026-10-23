// Scalable Vector Cursor Engine for Diosix GUI.
//
// Rasterizes the mouse pointer arrow from `vector.buildCursorArrowPath()` and
// generates a high-contrast black border via morphological mask dilation
// (`vector.dilateMask`), caching the antialiased sprite masks at the active UI
// scale factor.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("framebuffer.zig");
const vector = @import("vector.zig");

pub const CURSOR_WIDTH: u32 = 18;
pub const CURSOR_HEIGHT: u32 = 18;
pub const MAX_CURSOR_DIM: u32 = 48;

const CachedCursor = struct {
    size_px: u32 = 0,
    interior_mask: [MAX_CURSOR_DIM * MAX_CURSOR_DIM]u8 = undefined,
    border_mask: [MAX_CURSOR_DIM * MAX_CURSOR_DIM]u8 = undefined,
};

var cached_cursor: CachedCursor = .{};
var active_scale_pct: u32 = 100;

pub fn setScalePercent(scale_pct: u32) void {
    active_scale_pct = std.math.clamp(scale_pct, 50, 250);
}

pub fn getActiveDimension() u32 {
    return std.math.clamp(
        (CURSOR_WIDTH * active_scale_pct + 50) / 100,
        12,
        MAX_CURSOR_DIM,
    );
}

fn ensureCached(size_px: u32) *const CachedCursor {
    const dim = std.math.clamp(size_px, 12, MAX_CURSOR_DIM);
    if (cached_cursor.size_px != dim) {
        cached_cursor.size_px = dim;
        const scale = @as(f32, @floatFromInt(dim)) /
            @as(f32, @floatFromInt(CURSOR_WIDTH));
        const total = @as(usize, dim) * @as(usize, dim);
        const path = vector.buildCursorArrowPath();
        path.rasterizeToMask(
            scale,
            scale,
            0.0,
            0.0,
            cached_cursor.interior_mask[0..total],
            dim,
            dim,
            .non_zero,
        );
        const border_radius = @max(1.5, 1.8 * scale);
        vector.dilateMask(
            cached_cursor.interior_mask[0..total],
            cached_cursor.border_mask[0..total],
            dim,
            dim,
            border_radius,
        );
    }
    return &cached_cursor;
}

pub const Cursor = struct {
    x: i32 = 640,
    y: i32 = 400,
    drawn: bool = false,
    visible: bool = true,

    pub fn getBox(self: *const Cursor) fb.Box {
        const dim = getActiveDimension();
        return fb.Box.fromPosSize(self.x, self.y, dim, dim);
    }

    pub fn draw(self: *Cursor, screen: *fb.Surface) void {
        if (!self.visible) return;
        drawSprite(screen, self.x, self.y);
        self.drawn = true;
    }

    pub fn drawSprite(screen: *fb.Surface, x: i32, y: i32) void {
        drawSpriteAtSize(screen, x, y, getActiveDimension());
    }

    pub fn drawSpriteAtSize(
        screen: *fb.Surface,
        x: i32,
        y: i32,
        size_px: u32,
    ) void {
        const c = ensureCached(size_px);
        const dim = c.size_px;
        const total = @as(usize, dim) * @as(usize, dim);
        // 1. Solid black contrast outline.
        vector.blendMaskOnSurface(
            screen,
            c.border_mask[0..total],
            dim,
            dim,
            x,
            y,
            fb.Color.BLACK,
            255,
        );
        // 2. Crisp white arrow interior.
        vector.blendMaskOnSurface(
            screen,
            c.interior_mask[0..total],
            dim,
            dim,
            x,
            y,
            fb.Color.WHITE,
            255,
        );
    }
};

test "cursor: vector pointer rasterization with black border and white fill" {
    std.testing.refAllDecls(@This());
    var buf: [24 * 24]u32 = undefined;
    @memset(&buf, 0x00808080);
    var surf = fb.Surface.init(&buf, 24, 24, 24 * @sizeOf(u32));
    Cursor.drawSprite(&surf, 2, 2);

    var drawn_black: usize = 0;
    var drawn_white: usize = 0;
    for (buf) |px| {
        if (px == fb.Color.BLACK) drawn_black += 1;
        if (px == fb.Color.WHITE) drawn_white += 1;
    }
    try std.testing.expect(drawn_black > 0);
    try std.testing.expect(drawn_white > 0);
}
