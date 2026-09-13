// Cursor and Focus Marker Engine for Diosix GUI
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("framebuffer.zig");

pub const CURSOR_WIDTH: u32 = 18;
pub const CURSOR_HEIGHT: u32 = 18;

const K = fb.Color.BLACK;
const W = fb.Color.WHITE;
const G = fb.Color.GLOVE_SHADING;
const C = fb.Color.GLOVE_CUFF;
const T = fb.Color.TRANSPARENT;

// Pointing hand glove cursor (pointing horizontally right/up)
pub const POINTER_PIXELS = [_]u32{
    K, K, T, T, T, T, T, T, T, T, T, T, T, T, T, T, T, T,
    K, W, K, T, T, T, T, T, T, T, T, T, T, T, T, T, T, T,
    K, W, W, K, T, T, T, T, T, T, T, T, T, T, T, T, T, T,
    K, W, W, W, K, T, T, T, T, T, T, T, T, T, T, T, T, T,
    K, W, W, W, W, K, T, T, T, T, T, T, T, T, T, T, T, T,
    K, W, W, W, W, W, K, T, T, T, T, T, T, T, T, T, T, T,
    K, W, W, W, W, W, W, K, T, T, T, T, T, T, T, T, T, T,
    K, W, W, W, W, W, W, W, K, T, T, T, T, T, T, T, T, T,
    K, W, W, W, W, W, W, W, W, K, T, T, T, T, T, T, T, T,
    K, W, W, W, W, W, W, W, W, W, K, T, T, T, T, T, T, T,
    K, W, W, W, W, W, K, K, K, K, K, K, T, T, T, T, T, T,
    K, W, W, G, W, W, K, T, T, T, T, T, T, T, T, T, T, T,
    K, W, G, K, W, W, G, K, T, T, T, T, T, T, T, T, T, T,
    K, G, K, T, K, W, W, G, K, T, T, T, T, T, T, T, T, T,
    K, K, T, T, K, W, W, G, K, T, T, T, T, T, T, T, T, T,
    T, T, T, T, T, K, C, C, K, T, T, T, T, T, T, T, T, T,
    T, T, T, T, T, K, C, C, K, T, T, T, T, T, T, T, T, T,
    T, T, T, T, T, T, K, K, T, T, T, T, T, T, T, T, T, T,
};

// Keyboard navigation pointing hand marker (points right at active menu row)
pub const MARKER_WIDTH: u32 = 16;
pub const MARKER_HEIGHT: u32 = 12;

pub const HAND_MARKER_PIXELS = [_]u32{
    T, T, T, T, T, T, T, T, T, K, K, T, T, T, T, T,
    T, T, T, T, T, T, T, K, K, W, W, K, T, T, T, T,
    K, K, K, K, K, K, K, W, W, W, W, W, K, T, T, T,
    K, C, C, W, W, W, W, W, W, W, W, W, W, K, T, T,
    K, C, C, W, W, W, W, W, W, W, W, W, W, W, K, T,
    K, C, C, W, W, W, W, W, W, W, W, W, W, W, W, K,
    K, C, C, W, W, W, W, W, W, W, W, W, W, W, K, T,
    K, C, C, W, W, W, W, W, W, W, W, W, W, K, T, T,
    K, K, K, K, K, K, K, W, W, W, W, W, K, T, T, T,
    T, T, T, T, T, T, T, K, K, W, W, K, T, T, T, T,
    T, T, T, T, T, T, T, T, T, K, K, T, T, T, T, T,
    T, T, T, T, T, T, T, T, T, T, T, T, T, T, T, T,
};

pub const Cursor = struct {
    x: i32 = 640,
    y: i32 = 400,
    drawn: bool = false,

    pub fn getBox(self: *const Cursor) fb.Box {
        return fb.Box.fromPosSize(self.x, self.y, CURSOR_WIDTH, CURSOR_HEIGHT);
    }

    pub fn draw(self: *Cursor, screen: *fb.Surface) void {
        drawSprite(screen, self.x, self.y);
        self.drawn = true;
    }

    pub fn drawSprite(screen: *fb.Surface, x: i32, y: i32) void {
        const sprite_box = fb.Box.fromPosSize(x, y, CURSOR_WIDTH, CURSOR_HEIGHT);
        const clipped = sprite_box.intersect(screen.clip);
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

    // Draw keyboard focus hand pointing at (x, y)
    pub fn drawFocusHand(screen: *fb.Surface, x: i32, y: i32) void {
        const sprite_box = fb.Box.fromPosSize(x, y, MARKER_WIDTH, MARKER_HEIGHT);
        const clipped = sprite_box.intersect(screen.clip);
        if (clipped.isEmpty()) return;

        const pixels_per_row = screen.stridePixels();
        var py = clipped.y0;
        while (py < clipped.y1) : (py += 1) {
            const src_row = @as(usize, @intCast(py - y)) * MARKER_WIDTH;
            const dst_row = @as(usize, @intCast(py)) * pixels_per_row;
            var px = clipped.x0;
            while (px < clipped.x1) : (px += 1) {
                const src_idx = src_row + @as(usize, @intCast(px - x));
                const col = HAND_MARKER_PIXELS[src_idx];
                if (col != T) {
                    screen.pixels[dst_row + @as(usize, @intCast(px))] = col;
                }
            }
        }
    }
};
