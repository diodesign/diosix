// Questrial-Regular High-Resolution Antialiased Banner Typography Engine (52px)
// Rendered from Questrial-Regular.ttf (SIL Open Font License)
// Eliminates pixelation by rendering native 52px glyphs with true 8-bit sub-pixel antialiasing.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("framebuffer.zig");
const font = @import("font.zig");

pub const BANNER_GLYPH_HEIGHT: u32 = 52;
pub const BANNER_BITMAPS: []const u8 = @embedFile("banner_font.bin");

pub const BANNER_GLYPHS = [95]font.Glyph{
.{ .advance = 11, .width = 0, .height = 0, .offset_x = 0, .offset_y = 0, .bitmap_offset = 0 },
    .{ .advance = 11, .width = 11, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 0 },
    .{ .advance = 16, .width = 16, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 385 },
    .{ .advance = 30, .width = 30, .height = 31, .offset_x = 0, .offset_y = 12, .bitmap_offset = 945 },
    .{ .advance = 32, .width = 32, .height = 45, .offset_x = 0, .offset_y = 3, .bitmap_offset = 1875 },
    .{ .advance = 44, .width = 44, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 3315 },
    .{ .advance = 30, .width = 30, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 4855 },
    .{ .advance = 10, .width = 10, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 5905 },
    .{ .advance = 13, .width = 13, .height = 45, .offset_x = 0, .offset_y = 6, .bitmap_offset = 6255 },
    .{ .advance = 13, .width = 13, .height = 45, .offset_x = 0, .offset_y = 6, .bitmap_offset = 6840 },
    .{ .advance = 19, .width = 19, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 7425 },
    .{ .advance = 29, .width = 29, .height = 25, .offset_x = 0, .offset_y = 18, .bitmap_offset = 8090 },
    .{ .advance = 11, .width = 11, .height = 11, .offset_x = 0, .offset_y = 38, .bitmap_offset = 8815 },
    .{ .advance = 19, .width = 19, .height = 18, .offset_x = 0, .offset_y = 25, .bitmap_offset = 8936 },
    .{ .advance = 11, .width = 11, .height = 5, .offset_x = 0, .offset_y = 38, .bitmap_offset = 9278 },
    .{ .advance = 19, .width = 19, .height = 38, .offset_x = 0, .offset_y = 7, .bitmap_offset = 9333 },
    .{ .advance = 29, .width = 29, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 10055 },
    .{ .advance = 29, .width = 29, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 11070 },
    .{ .advance = 29, .width = 29, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 12085 },
    .{ .advance = 29, .width = 29, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 13100 },
    .{ .advance = 29, .width = 29, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 14115 },
    .{ .advance = 29, .width = 29, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 15130 },
    .{ .advance = 29, .width = 29, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 16145 },
    .{ .advance = 29, .width = 29, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 17160 },
    .{ .advance = 29, .width = 29, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 18175 },
    .{ .advance = 29, .width = 29, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 19190 },
    .{ .advance = 11, .width = 11, .height = 27, .offset_x = 0, .offset_y = 16, .bitmap_offset = 20205 },
    .{ .advance = 13, .width = 13, .height = 33, .offset_x = 0, .offset_y = 16, .bitmap_offset = 20502 },
    .{ .advance = 29, .width = 29, .height = 26, .offset_x = 0, .offset_y = 17, .bitmap_offset = 20931 },
    .{ .advance = 29, .width = 29, .height = 19, .offset_x = 0, .offset_y = 24, .bitmap_offset = 21685 },
    .{ .advance = 29, .width = 29, .height = 26, .offset_x = 0, .offset_y = 17, .bitmap_offset = 22236 },
    .{ .advance = 27, .width = 27, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 22990 },
    .{ .advance = 44, .width = 44, .height = 40, .offset_x = 0, .offset_y = 8, .bitmap_offset = 23935 },
    .{ .advance = 34, .width = 35, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 25695 },
    .{ .advance = 34, .width = 34, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 26920 },
    .{ .advance = 36, .width = 36, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 28110 },
    .{ .advance = 37, .width = 37, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 29370 },
    .{ .advance = 32, .width = 32, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 30665 },
    .{ .advance = 30, .width = 30, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 31785 },
    .{ .advance = 38, .width = 38, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 32835 },
    .{ .advance = 36, .width = 36, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 34165 },
    .{ .advance = 12, .width = 12, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 35425 },
    .{ .advance = 27, .width = 27, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 35845 },
    .{ .advance = 33, .width = 34, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 36790 },
    .{ .advance = 28, .width = 28, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 37980 },
    .{ .advance = 42, .width = 42, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 38960 },
    .{ .advance = 38, .width = 38, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 40430 },
    .{ .advance = 39, .width = 39, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 41760 },
    .{ .advance = 33, .width = 33, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 43125 },
    .{ .advance = 39, .width = 40, .height = 43, .offset_x = 0, .offset_y = 8, .bitmap_offset = 44280 },
    .{ .advance = 35, .width = 35, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 46000 },
    .{ .advance = 32, .width = 32, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 47225 },
    .{ .advance = 29, .width = 29, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 48345 },
    .{ .advance = 37, .width = 37, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 49360 },
    .{ .advance = 33, .width = 33, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 50655 },
    .{ .advance = 50, .width = 50, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 51810 },
    .{ .advance = 32, .width = 34, .height = 35, .offset_x = -1, .offset_y = 8, .bitmap_offset = 53560 },
    .{ .advance = 33, .width = 33, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 54750 },
    .{ .advance = 30, .width = 30, .height = 35, .offset_x = 0, .offset_y = 8, .bitmap_offset = 55905 },
    .{ .advance = 15, .width = 15, .height = 43, .offset_x = 0, .offset_y = 7, .bitmap_offset = 56955 },
    .{ .advance = 19, .width = 19, .height = 38, .offset_x = 0, .offset_y = 7, .bitmap_offset = 57600 },
    .{ .advance = 15, .width = 15, .height = 43, .offset_x = 0, .offset_y = 7, .bitmap_offset = 58322 },
    .{ .advance = 26, .width = 26, .height = 36, .offset_x = 0, .offset_y = 7, .bitmap_offset = 58967 },
    .{ .advance = 31, .width = 31, .height = 7, .offset_x = 0, .offset_y = 43, .bitmap_offset = 59903 },
    .{ .advance = 18, .width = 18, .height = 36, .offset_x = 0, .offset_y = 7, .bitmap_offset = 60120 },
    .{ .advance = 31, .width = 31, .height = 27, .offset_x = 0, .offset_y = 16, .bitmap_offset = 60768 },
    .{ .advance = 31, .width = 31, .height = 37, .offset_x = 0, .offset_y = 6, .bitmap_offset = 61605 },
    .{ .advance = 28, .width = 28, .height = 27, .offset_x = 0, .offset_y = 16, .bitmap_offset = 62752 },
    .{ .advance = 31, .width = 31, .height = 37, .offset_x = 0, .offset_y = 6, .bitmap_offset = 63508 },
    .{ .advance = 29, .width = 29, .height = 27, .offset_x = 0, .offset_y = 16, .bitmap_offset = 64655 },
    .{ .advance = 16, .width = 16, .height = 37, .offset_x = 0, .offset_y = 6, .bitmap_offset = 65438 },
    .{ .advance = 31, .width = 31, .height = 38, .offset_x = 0, .offset_y = 16, .bitmap_offset = 66030 },
    .{ .advance = 29, .width = 29, .height = 37, .offset_x = 0, .offset_y = 6, .bitmap_offset = 67208 },
    .{ .advance = 11, .width = 11, .height = 36, .offset_x = 0, .offset_y = 7, .bitmap_offset = 68281 },
    .{ .advance = 11, .width = 11, .height = 47, .offset_x = 0, .offset_y = 7, .bitmap_offset = 68677 },
    .{ .advance = 26, .width = 27, .height = 37, .offset_x = 0, .offset_y = 6, .bitmap_offset = 69194 },
    .{ .advance = 11, .width = 11, .height = 37, .offset_x = 0, .offset_y = 6, .bitmap_offset = 70193 },
    .{ .advance = 45, .width = 45, .height = 27, .offset_x = 0, .offset_y = 16, .bitmap_offset = 70600 },
    .{ .advance = 29, .width = 29, .height = 27, .offset_x = 0, .offset_y = 16, .bitmap_offset = 71815 },
    .{ .advance = 29, .width = 29, .height = 27, .offset_x = 0, .offset_y = 16, .bitmap_offset = 72598 },
    .{ .advance = 31, .width = 31, .height = 38, .offset_x = 0, .offset_y = 16, .bitmap_offset = 73381 },
    .{ .advance = 31, .width = 31, .height = 38, .offset_x = 0, .offset_y = 16, .bitmap_offset = 74559 },
    .{ .advance = 18, .width = 18, .height = 27, .offset_x = 0, .offset_y = 16, .bitmap_offset = 75737 },
    .{ .advance = 25, .width = 25, .height = 27, .offset_x = 0, .offset_y = 16, .bitmap_offset = 76223 },
    .{ .advance = 17, .width = 17, .height = 36, .offset_x = 0, .offset_y = 7, .bitmap_offset = 76898 },
    .{ .advance = 29, .width = 29, .height = 27, .offset_x = 0, .offset_y = 16, .bitmap_offset = 77510 },
    .{ .advance = 25, .width = 26, .height = 27, .offset_x = 0, .offset_y = 16, .bitmap_offset = 78293 },
    .{ .advance = 39, .width = 39, .height = 27, .offset_x = 0, .offset_y = 16, .bitmap_offset = 78995 },
    .{ .advance = 25, .width = 25, .height = 27, .offset_x = 0, .offset_y = 16, .bitmap_offset = 80048 },
    .{ .advance = 26, .width = 26, .height = 38, .offset_x = 0, .offset_y = 16, .bitmap_offset = 80723 },
    .{ .advance = 24, .width = 24, .height = 27, .offset_x = 0, .offset_y = 16, .bitmap_offset = 81711 },
    .{ .advance = 15, .width = 15, .height = 43, .offset_x = 0, .offset_y = 8, .bitmap_offset = 82359 },
    .{ .advance = 10, .width = 10, .height = 49, .offset_x = 0, .offset_y = 3, .bitmap_offset = 83004 },
    .{ .advance = 15, .width = 15, .height = 43, .offset_x = 0, .offset_y = 8, .bitmap_offset = 83494 },
    .{ .advance = 27, .width = 27, .height = 19, .offset_x = 0, .offset_y = 24, .bitmap_offset = 84139 },
};

// Draws a high-resolution antialiased banner glyph directly to surface with master alpha
pub fn drawBannerGlyph(
    surface: *fb.Surface,
    char: u8,
    x: i32,
    y: i32,
    color: u32,
    alpha: u8,
) void {
    if (alpha == 0 or char < 32 or char > 126) return;
    const g = BANNER_GLYPHS[char - 32];
    if (g.width == 0 or g.height == 0) return;

    const gx = x + @as(i32, g.offset_x);
    const gy = y + @as(i32, g.offset_y);

    var row: usize = 0;
    while (row < g.height) : (row += 1) {
        const py = gy + @as(i32, @intCast(row));
        if (py < 0 or py >= @as(i32, @intCast(surface.height))) continue;

        var col: usize = 0;
        while (col < g.width) : (col += 1) {
            const px = gx + @as(i32, @intCast(col));
            if (px < 0 or px >= @as(i32, @intCast(surface.width))) continue;

            const raw_a = BANNER_BITMAPS[g.bitmap_offset + row * g.width + col];
            const eff_a: u8 = @intCast((@as(u32, raw_a) * @as(u32, alpha)) >> 8);
            if (eff_a > 0) {
                const bg = surface.getPixel(px, py);
                surface.setPixel(px, py, fb.blendPixel(bg, color, eff_a));
            }
        }
    }
}


pub const GlowGlyph = struct {
    width: u8,
    height: u8,
    offset_x: i8,
    offset_y: i8,
    bitmap_offset: u32,
};

pub const BANNER_GLOW_BITMAPS: []const u8 = @embedFile("banner_glow.bin");

pub const BANNER_GLOW_GLYPHS = [95]GlowGlyph{
    .{ .width = 0, .height = 0, .offset_x = 0, .offset_y = 0, .bitmap_offset = 0 }, // 32 space
    .{ .width = 39, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 0 }, // 33 !
    .{ .width = 44, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 2457 }, // 34 "
    .{ .width = 58, .height = 59, .offset_x = -14, .offset_y = -2, .bitmap_offset = 5229 }, // 35 #
    .{ .width = 60, .height = 73, .offset_x = -14, .offset_y = -11, .bitmap_offset = 8651 }, // 36 $
    .{ .width = 72, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 13031 }, // 37 %
    .{ .width = 58, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 17567 }, // 38 &
    .{ .width = 38, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 21221 }, // 39 '
    .{ .width = 41, .height = 73, .offset_x = -14, .offset_y = -8, .bitmap_offset = 23615 }, // 40 (
    .{ .width = 41, .height = 73, .offset_x = -14, .offset_y = -8, .bitmap_offset = 26608 }, // 41 )
    .{ .width = 47, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 29601 }, // 42 *
    .{ .width = 57, .height = 53, .offset_x = -14, .offset_y = 4, .bitmap_offset = 32562 }, // 43 +
    .{ .width = 39, .height = 39, .offset_x = -14, .offset_y = 24, .bitmap_offset = 35583 }, // 44 ,
    .{ .width = 47, .height = 46, .offset_x = -14, .offset_y = 11, .bitmap_offset = 37104 }, // 45 -
    .{ .width = 39, .height = 33, .offset_x = -14, .offset_y = 24, .bitmap_offset = 39266 }, // 46 .
    .{ .width = 47, .height = 66, .offset_x = -14, .offset_y = -7, .bitmap_offset = 40553 }, // 47 /
    .{ .width = 57, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 43655 }, // 48 0
    .{ .width = 57, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 47246 }, // 49 1
    .{ .width = 57, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 50837 }, // 50 2
    .{ .width = 57, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 54428 }, // 51 3
    .{ .width = 57, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 58019 }, // 52 4
    .{ .width = 57, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 61610 }, // 53 5
    .{ .width = 57, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 65201 }, // 54 6
    .{ .width = 57, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 68792 }, // 55 7
    .{ .width = 57, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 72383 }, // 56 8
    .{ .width = 57, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 75974 }, // 57 9
    .{ .width = 39, .height = 55, .offset_x = -14, .offset_y = 2, .bitmap_offset = 79565 }, // 58 :
    .{ .width = 41, .height = 61, .offset_x = -14, .offset_y = 2, .bitmap_offset = 81710 }, // 59 ;
    .{ .width = 57, .height = 54, .offset_x = -14, .offset_y = 3, .bitmap_offset = 84211 }, // 60 <
    .{ .width = 57, .height = 47, .offset_x = -14, .offset_y = 10, .bitmap_offset = 87289 }, // 61 =
    .{ .width = 57, .height = 54, .offset_x = -14, .offset_y = 3, .bitmap_offset = 89968 }, // 62 >
    .{ .width = 55, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 93046 }, // 63 ?
    .{ .width = 72, .height = 68, .offset_x = -14, .offset_y = -6, .bitmap_offset = 96511 }, // 64 @
    .{ .width = 63, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 101407 }, // 65 A
    .{ .width = 62, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 105376 }, // 66 B
    .{ .width = 64, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 109282 }, // 67 C
    .{ .width = 65, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 113314 }, // 68 D
    .{ .width = 60, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 117409 }, // 69 E
    .{ .width = 58, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 121189 }, // 70 F
    .{ .width = 66, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 124843 }, // 71 G
    .{ .width = 64, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 129001 }, // 72 H
    .{ .width = 40, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 133033 }, // 73 I
    .{ .width = 55, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 135553 }, // 74 J
    .{ .width = 62, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 139018 }, // 75 K
    .{ .width = 56, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 142924 }, // 76 L
    .{ .width = 70, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 146452 }, // 77 M
    .{ .width = 66, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 150862 }, // 78 N
    .{ .width = 67, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 155020 }, // 79 O
    .{ .width = 61, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 159241 }, // 80 P
    .{ .width = 68, .height = 71, .offset_x = -14, .offset_y = -6, .bitmap_offset = 163084 }, // 81 Q
    .{ .width = 63, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 167912 }, // 82 R
    .{ .width = 60, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 171881 }, // 83 S
    .{ .width = 57, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 175661 }, // 84 T
    .{ .width = 65, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 179252 }, // 85 U
    .{ .width = 61, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 183347 }, // 86 V
    .{ .width = 78, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 187190 }, // 87 W
    .{ .width = 62, .height = 63, .offset_x = -15, .offset_y = -6, .bitmap_offset = 192104 }, // 88 X
    .{ .width = 61, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 196010 }, // 89 Y
    .{ .width = 58, .height = 63, .offset_x = -14, .offset_y = -6, .bitmap_offset = 199853 }, // 90 Z
    .{ .width = 43, .height = 71, .offset_x = -14, .offset_y = -7, .bitmap_offset = 203507 }, // 91 [
    .{ .width = 47, .height = 66, .offset_x = -14, .offset_y = -7, .bitmap_offset = 206560 }, // 92 \
    .{ .width = 43, .height = 71, .offset_x = -14, .offset_y = -7, .bitmap_offset = 209662 }, // 93 ]
    .{ .width = 54, .height = 64, .offset_x = -14, .offset_y = -7, .bitmap_offset = 212715 }, // 94 ^
    .{ .width = 59, .height = 35, .offset_x = -14, .offset_y = 29, .bitmap_offset = 216171 }, // 95 _
    .{ .width = 46, .height = 64, .offset_x = -14, .offset_y = -7, .bitmap_offset = 218236 }, // 96 `
    .{ .width = 59, .height = 55, .offset_x = -14, .offset_y = 2, .bitmap_offset = 221180 }, // 97 a
    .{ .width = 59, .height = 65, .offset_x = -14, .offset_y = -8, .bitmap_offset = 224425 }, // 98 b
    .{ .width = 56, .height = 55, .offset_x = -14, .offset_y = 2, .bitmap_offset = 228260 }, // 99 c
    .{ .width = 59, .height = 65, .offset_x = -14, .offset_y = -8, .bitmap_offset = 231340 }, // 100 d
    .{ .width = 57, .height = 55, .offset_x = -14, .offset_y = 2, .bitmap_offset = 235175 }, // 101 e
    .{ .width = 44, .height = 65, .offset_x = -14, .offset_y = -8, .bitmap_offset = 238310 }, // 102 f
    .{ .width = 59, .height = 66, .offset_x = -14, .offset_y = 2, .bitmap_offset = 241170 }, // 103 g
    .{ .width = 57, .height = 65, .offset_x = -14, .offset_y = -8, .bitmap_offset = 245064 }, // 104 h
    .{ .width = 39, .height = 64, .offset_x = -14, .offset_y = -7, .bitmap_offset = 248769 }, // 105 i
    .{ .width = 39, .height = 75, .offset_x = -14, .offset_y = -7, .bitmap_offset = 251265 }, // 106 j
    .{ .width = 55, .height = 65, .offset_x = -14, .offset_y = -8, .bitmap_offset = 254190 }, // 107 k
    .{ .width = 39, .height = 65, .offset_x = -14, .offset_y = -8, .bitmap_offset = 257765 }, // 108 l
    .{ .width = 73, .height = 55, .offset_x = -14, .offset_y = 2, .bitmap_offset = 260300 }, // 109 m
    .{ .width = 57, .height = 55, .offset_x = -14, .offset_y = 2, .bitmap_offset = 264315 }, // 110 n
    .{ .width = 57, .height = 55, .offset_x = -14, .offset_y = 2, .bitmap_offset = 267450 }, // 111 o
    .{ .width = 59, .height = 66, .offset_x = -14, .offset_y = 2, .bitmap_offset = 270585 }, // 112 p
    .{ .width = 59, .height = 66, .offset_x = -14, .offset_y = 2, .bitmap_offset = 274479 }, // 113 q
    .{ .width = 46, .height = 55, .offset_x = -14, .offset_y = 2, .bitmap_offset = 278373 }, // 114 r
    .{ .width = 53, .height = 55, .offset_x = -14, .offset_y = 2, .bitmap_offset = 280903 }, // 115 s
    .{ .width = 45, .height = 64, .offset_x = -14, .offset_y = -7, .bitmap_offset = 283818 }, // 116 t
    .{ .width = 57, .height = 55, .offset_x = -14, .offset_y = 2, .bitmap_offset = 286698 }, // 117 u
    .{ .width = 54, .height = 55, .offset_x = -14, .offset_y = 2, .bitmap_offset = 289833 }, // 118 v
    .{ .width = 67, .height = 55, .offset_x = -14, .offset_y = 2, .bitmap_offset = 292803 }, // 119 w
    .{ .width = 53, .height = 55, .offset_x = -14, .offset_y = 2, .bitmap_offset = 296488 }, // 120 x
    .{ .width = 54, .height = 66, .offset_x = -14, .offset_y = 2, .bitmap_offset = 299403 }, // 121 y
    .{ .width = 52, .height = 55, .offset_x = -14, .offset_y = 2, .bitmap_offset = 302967 }, // 122 z
    .{ .width = 43, .height = 71, .offset_x = -14, .offset_y = -6, .bitmap_offset = 305827 }, // 123 {
    .{ .width = 38, .height = 77, .offset_x = -14, .offset_y = -11, .bitmap_offset = 308880 }, // 124 |
    .{ .width = 43, .height = 71, .offset_x = -14, .offset_y = -6, .bitmap_offset = 311806 }, // 125 }
    .{ .width = 55, .height = 47, .offset_x = -14, .offset_y = 10, .bitmap_offset = 314859 }, // 126 ~
};

// Draws a radiant photographic bloom/glow for a banner glyph directly to surface
pub fn drawBannerGlyphGlow(
    surface: *fb.Surface,
    char: u8,
    x: i32,
    y: i32,
    color: u32,
    alpha: u8,
) void {
    if (alpha == 0 or char < 32 or char > 126) return;
    const g = BANNER_GLOW_GLYPHS[char - 32];
    if (g.width == 0 or g.height == 0) return;

    const gx = x + @as(i32, g.offset_x);
    const gy = y + @as(i32, g.offset_y);

    var row: usize = 0;
    while (row < g.height) : (row += 1) {
        const py = gy + @as(i32, @intCast(row));
        if (py < 0 or py >= @as(i32, @intCast(surface.height))) continue;

        var col: usize = 0;
        while (col < g.width) : (col += 1) {
            const px = gx + @as(i32, @intCast(col));
            if (px < 0 or px >= @as(i32, @intCast(surface.width))) continue;

            const raw_a = BANNER_GLOW_BITMAPS[g.bitmap_offset + row * g.width + col];
            const eff_a: u8 = @intCast((@as(u32, raw_a) * @as(u32, alpha)) >> 8);
            if (eff_a > 0) {
                const bg = surface.getPixel(px, py);
                surface.setPixel(px, py, fb.blendPixel(bg, color, eff_a));
            }
        }
    }
}
test "banner_font: verify ascii glyph array and bitmap mapping" {
    try std.testing.expectEqual(@as(usize, 95), BANNER_GLYPHS.len);
    try std.testing.expect(BANNER_BITMAPS.len > 80_000);
    // Verify "diosix" letters
    for ("diosix") |c| {
        const g = BANNER_GLYPHS[c - 32];
        try std.testing.expect(g.width > 0);
        try std.testing.expect(g.height > 0);
        try std.testing.expect(g.bitmap_offset + @as(u32, g.width) * @as(u32, g.height) <= BANNER_BITMAPS.len);
    }
}

test "banner_font: verify glow ascii glyph array and bitmap mapping" {
    try std.testing.expectEqual(@as(usize, 95), BANNER_GLOW_GLYPHS.len);
    try std.testing.expect(BANNER_GLOW_BITMAPS.len > 200_000);
    // Verify "diosix" letters in glow table
    for ("diosix") |c| {
        const g = BANNER_GLOW_GLYPHS[c - 32];
        try std.testing.expect(g.width > 0);
        try std.testing.expect(g.height > 0);
        try std.testing.expect(g.bitmap_offset + @as(u32, g.width) * @as(u32, g.height) <= BANNER_GLOW_BITMAPS.len);
    }
}
