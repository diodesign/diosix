// Cursor and Focus Marker Engine for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("framebuffer.zig");

pub const CURSOR_WIDTH: u32 = 18;
pub const CURSOR_HEIGHT: u32 = 18;

const K = fb.Color.BLACK;
const W = fb.Color.WHITE;
const T = fb.Color.TRANSPARENT;

// Clean all-white mouse pointer arrow with solid 2px black contrast border.
pub const POINTER_PIXELS = [_]u32{
    K, K, T, T, T, T, T, T, T, T, T, T, T, T, T, T, T, T,
    K, K, K, T, T, T, T, T, T, T, T, T, T, T, T, T, T, T,
    K, K, W, K, K, T, T, T, T, T, T, T, T, T, T, T, T, T,
    K, K, W, W, K, K, T, T, T, T, T, T, T, T, T, T, T, T,
    K, K, W, W, W, K, K, T, T, T, T, T, T, T, T, T, T, T,
    K, K, W, W, W, W, K, K, T, T, T, T, T, T, T, T, T, T,
    K, K, W, W, W, W, W, K, K, T, T, T, T, T, T, T, T, T,
    K, K, W, W, W, W, W, W, K, K, T, T, T, T, T, T, T, T,
    K, K, W, W, W, W, W, W, W, K, K, T, T, T, T, T, T, T,
    K, K, W, W, W, W, W, W, W, W, K, K, T, T, T, T, T, T,
    K, K, W, W, W, W, W, K, K, K, K, K, T, T, T, T, T, T,
    K, K, W, W, K, W, W, K, K, T, T, T, T, T, T, T, T, T,
    K, K, W, K, K, K, W, W, K, K, T, T, T, T, T, T, T, T,
    K, K, K, T, T, K, K, W, W, K, K, T, T, T, T, T, T, T,
    K, K, T, T, T, T, K, K, W, W, K, K, T, T, T, T, T, T,
    T, T, T, T, T, T, T, K, K, W, W, K, T, T, T, T, T, T,
    T, T, T, T, T, T, T, T, K, K, K, K, T, T, T, T, T, T,
    T, T, T, T, T, T, T, T, T, K, K, T, T, T, T, T, T, T,
};

pub const Cursor = struct {
    x: i32 = 640,
    y: i32 = 400,
    drawn: bool = false,
    visible: bool = true,

    pub fn getBox(self: *const Cursor) fb.Box {
        return fb.Box.fromPosSize(self.x, self.y, CURSOR_WIDTH, CURSOR_HEIGHT);
    }

    pub fn draw(self: *Cursor, screen: *fb.Surface) void {
        if (!self.visible) return;
        drawSprite(screen, self.x, self.y);
        self.drawn = true;
    }

    pub fn drawSprite(screen: *fb.Surface, x: i32, y: i32) void {
        const sprite_box =
            fb.Box.fromPosSize(x, y, CURSOR_WIDTH, CURSOR_HEIGHT);
        const bounds = fb.Box.fromPosSize(0, 0, screen.width, screen.height);
        const clipped = sprite_box.intersect(screen.clip).intersect(bounds);
        if (clipped.isEmpty()) return;

        const pixels_per_row = screen.stridePixels();
        var py = clipped.y0;
        while (py < clipped.y1) : (py += 1) {
            const src_row = @as(usize, @intCast(py - y)) * CURSOR_WIDTH;
            const dst_row = @as(usize, @intCast(py)) * pixels_per_row;
            var px = clipped.x0;
            while (px < clipped.x1) : (px += 1) {
                const src_idx = src_row + @as(usize, @intCast(px - x));
                const col = POINTER_PIXELS[src_idx];
                if (col != T) {
                    screen.pixels[dst_row + @as(usize, @intCast(px))] = col;
                }
            }
        }
    }
};

test "cursor: verify pointer sprite dimensions and pure white interior" {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(
        @as(usize, CURSOR_WIDTH * CURSOR_HEIGHT),
        POINTER_PIXELS.len,
    );
    // Hotspot at (0,0) is black point.
    try std.testing.expectEqual(K, POINTER_PIXELS[0]);

    var white_count: usize = 0;
    var black_count: usize = 0;
    for (POINTER_PIXELS) |p| {
        if (p == W) {
            white_count += 1;
        } else if (p == K) {
            black_count += 1;
        } else {
            // Every other pixel must be transparent.
            try std.testing.expectEqual(T, p);
        }
    }

    try std.testing.expect(K != T);
    try std.testing.expect(W != T);
    try std.testing.expect(white_count > 0);
    try std.testing.expect(black_count > 0);

    var buf: [24 * 24]u32 = undefined;
    @memset(&buf, 0x00808080);
    var surf = fb.Surface.init(&buf, 24, 24, 24 * @sizeOf(u32));
    Cursor.drawSprite(&surf, 2, 2);

    var drawn_black: usize = 0;
    var drawn_white: usize = 0;
    for (buf) |px| {
        if (px == K) drawn_black += 1;
        if (px == W) drawn_white += 1;
    }
    try std.testing.expectEqual(black_count, drawn_black);
    try std.testing.expectEqual(white_count, drawn_white);
}
