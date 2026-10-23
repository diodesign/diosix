// Color Depth Quantization & 4x4 Bayer Ordered Dithering Engine for Diosix GUI.
//
// Supports 8-bit (RGB332), 16-bit (RGB565), 24-bit (RGB888), and 32-bit
// (XRGB8888) color depths with 4x4 Bayer ordered spatial dithering so smooth
// gradients and glass panes remain free of severe banding at 8-bit and 16-bit
// color depths across both native bit-depth framebuffers and 32-bit virtual
// GPU scanout buffers.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("framebuffer.zig");

pub const ColorDepth = enum(u8) {
    bpp8 = 0,
    bpp16 = 1,
    bpp24 = 2,
    bpp32 = 3,

    pub const COUNT: usize = 4;

    pub fn bitsPerPixel(self: ColorDepth) u32 {
        return switch (self) {
            .bpp8 => 8,
            .bpp16 => 16,
            .bpp24 => 24,
            .bpp32 => 32,
        };
    }

    pub fn drmDepth(self: ColorDepth) u32 {
        return switch (self) {
            .bpp8 => 8,
            .bpp16 => 16,
            .bpp24 => 24,
            .bpp32 => 24,
        };
    }

    pub fn label(self: ColorDepth) []const u8 {
        return switch (self) {
            .bpp8 => "8-bit (256 Colors, RGB332)",
            .bpp16 => "16-bit (65K Colors, RGB565)",
            .bpp24 => "24-bit (16.7M Colors, RGB888)",
            .bpp32 => "32-bit (TrueColor, XRGB8888)",
        };
    }

    pub fn fromIndex(idx: usize) ColorDepth {
        return switch (idx) {
            0 => .bpp8,
            1 => .bpp16,
            2 => .bpp24,
            else => .bpp32,
        };
    }

    pub fn fromBpp(bpp: u32) ColorDepth {
        if (bpp <= 8) return .bpp8;
        if (bpp <= 16) return .bpp16;
        if (bpp == 24) return .bpp24;
        return .bpp32;
    }
};

// Standard 4x4 Bayer ordered threshold matrix (values 0..15).
pub const BAYER_4X4 = [4][4]i32{
    .{ 0, 8, 2, 10 },
    .{ 12, 4, 14, 6 },
    .{ 3, 11, 1, 9 },
    .{ 15, 7, 13, 5 },
};

inline fn clampByte(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

/// Applies 4x4 Bayer ordered dithering and quantizes a 32-bit `0x00RRGGBB`
/// pixel to `depth`, returning the quantized color expanded back to 32-bit
/// `0x00RRGGBB`.
pub fn quantizeAndDitherXrgb(
    xrgb: u32,
    x: u32,
    y: u32,
    depth: ColorDepth,
) u32 {
    switch (depth) {
        .bpp32, .bpp24 => return xrgb & 0x00ff_ffff,
        .bpp16 => {
            const bayer = BAYER_4X4[y & 3][x & 3];
            const d_rb = (bayer >> 1) - 4; // -4 .. +3
            const d_g = (bayer >> 2) - 2; // -2 .. +1
            const r8 = clampByte(
                @as(i32, @intCast((xrgb >> 16) & 0xff)) + d_rb,
            );
            const g8 = clampByte(
                @as(i32, @intCast((xrgb >> 8) & 0xff)) + d_g,
            );
            const b8 = clampByte(@as(i32, @intCast(xrgb & 0xff)) + d_rb);

            const r5: u32 = r8 >> 3;
            const g6: u32 = g8 >> 2;
            const b5: u32 = b8 >> 3;

            const qr: u32 = (r5 << 3) | (r5 >> 2);
            const qg: u32 = (g6 << 2) | (g6 >> 4);
            const qb: u32 = (b5 << 3) | (b5 >> 2);
            return (qr << 16) | (qg << 8) | qb;
        },
        .bpp8 => {
            const bayer = BAYER_4X4[y & 3][x & 3];
            const d_rg = (bayer * 2) - 15; // -15 .. +15
            const d_b = (bayer * 4) - 30; // -30 .. +30
            const r8 = clampByte(
                @as(i32, @intCast((xrgb >> 16) & 0xff)) + d_rg,
            );
            const g8 = clampByte(
                @as(i32, @intCast((xrgb >> 8) & 0xff)) + d_rg,
            );
            const b8 = clampByte(@as(i32, @intCast(xrgb & 0xff)) + d_b);

            const r3: u32 = r8 >> 5;
            const g3: u32 = g8 >> 5;
            const b2: u32 = b8 >> 6;

            const qr: u32 = (r3 * 255 + 3) / 7;
            const qg: u32 = (g3 * 255 + 3) / 7;
            const qb: u32 = b2 * 85;
            return (qr << 16) | (qg << 8) | qb;
        },
    }
}

pub inline fn packRgb565(xrgb: u32, x: u32, y: u32) u16 {
    const q = quantizeAndDitherXrgb(xrgb, x, y, .bpp16);
    const r5: u16 = @intCast((q >> 19) & 0x1f);
    const g6: u16 = @intCast((q >> 10) & 0x3f);
    const b5: u16 = @intCast((q >> 3) & 0x1f);
    return (r5 << 11) | (g6 << 5) | b5;
}

pub inline fn packRgb332(xrgb: u32, x: u32, y: u32) u8 {
    const q = quantizeAndDitherXrgb(xrgb, x, y, .bpp8);
    const r3: u8 = @intCast((q >> 21) & 0x07);
    const g3: u8 = @intCast((q >> 13) & 0x07);
    const b2: u8 = @intCast((q >> 6) & 0x03);
    return (r3 << 5) | (g3 << 2) | b2;
}

/// Flushes a damaged rectangle from the 32-bit compositor surface `src_pixels`
/// into the hardware scanout byte slice `dst_bytes`, applying `target_depth`
/// quantization/dithering and packing into `hw_bpp` (`8`, `16`, `24`, or `32`).
pub fn flushRectWithDepth(
    src_pixels: []const u32,
    src_stride_px: usize,
    dst_bytes: []u8,
    dst_stride_bytes: usize,
    hw_bpp: u32,
    target_depth: ColorDepth,
    x0: usize,
    y0: usize,
    x1: usize,
    y1: usize,
) void {
    var py: usize = y0;
    while (py < y1) : (py += 1) {
        const src_row = py * src_stride_px;
        const dst_row_byte = py * dst_stride_bytes;

        if (hw_bpp == 32) {
            const dst_u32: [*]u32 = @ptrCast(@alignCast(dst_bytes.ptr));
            const dst_stride_u32 = dst_stride_bytes / @sizeOf(u32);
            const dst_row = py * dst_stride_u32;
            if (target_depth == .bpp32 or target_depth == .bpp24) {
                @memcpy(
                    dst_u32[dst_row + x0 .. dst_row + x1],
                    src_pixels[src_row + x0 .. src_row + x1],
                );
            } else {
                var px: usize = x0;
                while (px < x1) : (px += 1) {
                    dst_u32[dst_row + px] = quantizeAndDitherXrgb(
                        src_pixels[src_row + px],
                        @intCast(px),
                        @intCast(py),
                        target_depth,
                    );
                }
            }
        } else if (hw_bpp == 24) {
            var px: usize = x0;
            while (px < x1) : (px += 1) {
                const q = quantizeAndDitherXrgb(
                    src_pixels[src_row + px],
                    @intCast(px),
                    @intCast(py),
                    target_depth,
                );
                const off = dst_row_byte + px * 3;
                if (off + 3 <= dst_bytes.len) {
                    dst_bytes[off + 0] = @intCast(q & 0xff);
                    dst_bytes[off + 1] = @intCast((q >> 8) & 0xff);
                    dst_bytes[off + 2] = @intCast((q >> 16) & 0xff);
                }
            }
        } else if (hw_bpp == 16) {
            var px: usize = x0;
            while (px < x1) : (px += 1) {
                const q = quantizeAndDitherXrgb(
                    src_pixels[src_row + px],
                    @intCast(px),
                    @intCast(py),
                    target_depth,
                );
                const packed16 = packRgb565(q, @intCast(px), @intCast(py));
                const off = dst_row_byte + px * 2;
                if (off + 2 <= dst_bytes.len) {
                    std.mem.writeInt(
                        u16,
                        dst_bytes[off..][0..2],
                        packed16,
                        .little,
                    );
                }
            }
        } else if (hw_bpp == 8) {
            var px: usize = x0;
            while (px < x1) : (px += 1) {
                const off = dst_row_byte + px;
                if (off < dst_bytes.len) {
                    dst_bytes[off] = packRgb332(
                        src_pixels[src_row + px],
                        @intCast(px),
                        @intCast(py),
                    );
                }
            }
        }
    }
}

test "dither: 8-bit RGB332 and 16-bit RGB565 quantization and Bayer dithering" {
    std.testing.refAllDecls(@This());
    const white = fb.Color.WHITE;
    try std.testing.expectEqual(
        white,
        quantizeAndDitherXrgb(white, 0, 0, .bpp8),
    );
    try std.testing.expectEqual(
        white,
        quantizeAndDitherXrgb(white, 0, 0, .bpp16),
    );
    try std.testing.expectEqual(@as(u16, 0xffff), packRgb565(white, 0, 0));
    try std.testing.expectEqual(@as(u8, 0xff), packRgb332(white, 0, 0));
}
