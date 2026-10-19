// Questrial-Regular High-Resolution Antialiased Banner Typography (52px).
// Rendered from Questrial-Regular.ttf (SIL Open Font License).
// Eliminates pixelation by rendering native 52px antialiased glyphs.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("../framebuffer.zig");
const font = @import("../font.zig");

pub const BANNER_GLYPH_HEIGHT: u32 = 52;
pub const SPACE_ADVANCE: u32 = 24;
pub const TAB_SPACES: u32 = 4;
pub const TAB_ADVANCE: u32 = SPACE_ADVANCE * TAB_SPACES;
pub const BANNER_BITMAPS: []const u8 = @embedFile("banner_font.bin");

fn g(
    adv: u8,
    w: u8,
    h: u8,
    ox: i8,
    oy: i8,
    off: u32,
) font.Glyph {
    return .{
        .advance = adv,
        .width = w,
        .height = h,
        .offset_x = ox,
        .offset_y = oy,
        .bitmap_offset = off,
    };
}

pub const BANNER_GLYPHS = [95]font.Glyph{
    g(11, 0, 0, 0, 0, 0),
    g(11, 11, 35, 0, 8, 0),
    g(16, 16, 35, 0, 8, 385),
    g(30, 30, 31, 0, 12, 945),
    g(32, 32, 45, 0, 3, 1875),
    g(44, 44, 35, 0, 8, 3315),
    g(30, 30, 35, 0, 8, 4855),
    g(10, 10, 35, 0, 8, 5905),
    g(13, 13, 45, 0, 6, 6255),
    g(13, 13, 45, 0, 6, 6840),
    g(19, 19, 35, 0, 8, 7425),
    g(29, 29, 25, 0, 18, 8090),
    g(11, 11, 11, 0, 38, 8815),
    g(19, 19, 18, 0, 25, 8936),
    g(11, 11, 5, 0, 38, 9278),
    g(19, 19, 38, 0, 7, 9333),
    g(29, 29, 35, 0, 8, 10055),
    g(29, 29, 35, 0, 8, 11070),
    g(29, 29, 35, 0, 8, 12085),
    g(29, 29, 35, 0, 8, 13100),
    g(29, 29, 35, 0, 8, 14115),
    g(29, 29, 35, 0, 8, 15130),
    g(29, 29, 35, 0, 8, 16145),
    g(29, 29, 35, 0, 8, 17160),
    g(29, 29, 35, 0, 8, 18175),
    g(29, 29, 35, 0, 8, 19190),
    g(11, 11, 27, 0, 16, 20205),
    g(13, 13, 33, 0, 16, 20502),
    g(29, 29, 26, 0, 17, 20931),
    g(29, 29, 19, 0, 24, 21685),
    g(29, 29, 26, 0, 17, 22236),
    g(27, 27, 35, 0, 8, 22990),
    g(44, 44, 40, 0, 8, 23935),
    g(34, 35, 35, 0, 8, 25695),
    g(34, 34, 35, 0, 8, 26920),
    g(36, 36, 35, 0, 8, 28110),
    g(37, 37, 35, 0, 8, 29370),
    g(32, 32, 35, 0, 8, 30665),
    g(30, 30, 35, 0, 8, 31785),
    g(38, 38, 35, 0, 8, 32835),
    g(36, 36, 35, 0, 8, 34165),
    g(12, 12, 35, 0, 8, 35425),
    g(27, 27, 35, 0, 8, 35845),
    g(33, 34, 35, 0, 8, 36790),
    g(28, 28, 35, 0, 8, 37980),
    g(42, 42, 35, 0, 8, 38960),
    g(38, 38, 35, 0, 8, 40430),
    g(39, 39, 35, 0, 8, 41760),
    g(33, 33, 35, 0, 8, 43125),
    g(39, 40, 43, 0, 8, 44280),
    g(35, 35, 35, 0, 8, 46000),
    g(32, 32, 35, 0, 8, 47225),
    g(29, 29, 35, 0, 8, 48345),
    g(37, 37, 35, 0, 8, 49360),
    g(33, 33, 35, 0, 8, 50655),
    g(50, 50, 35, 0, 8, 51810),
    g(32, 34, 35, -1, 8, 53560),
    g(33, 33, 35, 0, 8, 54750),
    g(30, 30, 35, 0, 8, 55905),
    g(15, 15, 43, 0, 7, 56955),
    g(19, 19, 38, 0, 7, 57600),
    g(15, 15, 43, 0, 7, 58322),
    g(26, 26, 36, 0, 7, 58967),
    g(31, 31, 7, 0, 43, 59903),
    g(18, 18, 36, 0, 7, 60120),
    g(31, 31, 27, 0, 16, 60768),
    g(31, 31, 37, 0, 6, 61605),
    g(28, 28, 27, 0, 16, 62752),
    g(31, 31, 37, 0, 6, 63508),
    g(29, 29, 27, 0, 16, 64655),
    g(16, 16, 37, 0, 6, 65438),
    g(31, 31, 38, 0, 16, 66030),
    g(29, 29, 37, 0, 6, 67208),
    g(11, 11, 36, 0, 7, 68281),
    g(11, 11, 47, 0, 7, 68677),
    g(26, 27, 37, 0, 6, 69194),
    g(11, 11, 37, 0, 6, 70193),
    g(45, 45, 27, 0, 16, 70600),
    g(29, 29, 27, 0, 16, 71815),
    g(29, 29, 27, 0, 16, 72598),
    g(31, 31, 38, 0, 16, 73381),
    g(31, 31, 38, 0, 16, 74559),
    g(18, 18, 27, 0, 16, 75737),
    g(25, 25, 27, 0, 16, 76223),
    g(17, 17, 36, 0, 7, 76898),
    g(29, 29, 27, 0, 16, 77510),
    g(25, 26, 27, 0, 16, 78293),
    g(39, 39, 27, 0, 16, 78995),
    g(25, 25, 27, 0, 16, 80048),
    g(26, 26, 38, 0, 16, 80723),
    g(24, 24, 27, 0, 16, 81711),
    g(15, 15, 43, 0, 8, 82359),
    g(10, 10, 49, 0, 3, 83004),
    g(15, 15, 43, 0, 8, 83494),
    g(27, 27, 19, 0, 24, 84139),
};

fn blendAlphaBitmap(
    surface: *fb.Surface,
    bitmaps: []const u8,
    bitmap_offset: u32,
    width: u8,
    height: u8,
    gx: i32,
    gy: i32,
    color: u32,
    alpha: u8,
) void {
    if (width == 0 or height == 0 or surface.clip.isEmpty()) return;

    var row: usize = 0;
    while (row < height) : (row += 1) {
        const py = gy + @as(i32, @intCast(row));
        if (py < surface.clip.y0 or py >= surface.clip.y1) continue;
        if (py < 0 or py >= @as(i32, @intCast(surface.height))) continue;

        var col: usize = 0;
        while (col < width) : (col += 1) {
            const px = gx + @as(i32, @intCast(col));
            if (px < surface.clip.x0 or px >= surface.clip.x1) continue;
            if (px < 0 or px >= @as(i32, @intCast(surface.width))) continue;

            const raw_a = bitmaps[bitmap_offset + row * width + col];
            const eff_a: u8 =
                @intCast((@as(u32, raw_a) * @as(u32, alpha)) >> 8);
            if (eff_a > 0) {
                const bg = surface.getPixel(px, py);
                surface.setPixel(px, py, fb.blendPixel(bg, color, eff_a));
            }
        }
    }
}

// Draws a high-resolution antialiased banner glyph with master alpha.
pub fn drawBannerGlyph(
    surface: *fb.Surface,
    char: u8,
    x: i32,
    y: i32,
    color: u32,
    alpha: u8,
) void {
    if (alpha == 0 or
        char < font.ASCII_PRINTABLE_MIN or
        char > font.ASCII_PRINTABLE_MAX) return;
    const glyph = BANNER_GLYPHS[char - font.ASCII_PRINTABLE_MIN];
    const gx = x + @as(i32, glyph.offset_x);
    const gy = y + @as(i32, glyph.offset_y);
    blendAlphaBitmap(
        surface,
        BANNER_BITMAPS,
        glyph.bitmap_offset,
        glyph.width,
        glyph.height,
        gx,
        gy,
        color,
        alpha,
    );
}

pub const GlowGlyph = struct {
    width: u8,
    height: u8,
    offset_x: i8,
    offset_y: i8,
    bitmap_offset: u32,
};

fn gg(w: u8, h: u8, ox: i8, oy: i8, off: u32) GlowGlyph {
    return .{
        .width = w,
        .height = h,
        .offset_x = ox,
        .offset_y = oy,
        .bitmap_offset = off,
    };
}

pub const BANNER_GLOW_BITMAPS: []const u8 = @embedFile("banner_glow.bin");

pub const BANNER_GLOW_GLYPHS = [95]GlowGlyph{
    gg(0, 0, 0, 0, 0), // 32 space.
    gg(39, 63, -14, -6, 0), // 33 !.
    gg(44, 63, -14, -6, 2457), // 34 ".
    gg(58, 59, -14, -2, 5229), // 35 #.
    gg(60, 73, -14, -11, 8651), // 36 $.
    gg(72, 63, -14, -6, 13031), // 37 %.
    gg(58, 63, -14, -6, 17567), // 38 &.
    gg(38, 63, -14, -6, 21221), // 39 '.
    gg(41, 73, -14, -8, 23615), // 40 (.
    gg(41, 73, -14, -8, 26608), // 41 ).
    gg(47, 63, -14, -6, 29601), // 42 *.
    gg(57, 53, -14, 4, 32562), // 43 +.
    gg(39, 39, -14, 24, 35583), // 44 ,.
    gg(47, 46, -14, 11, 37104), // 45 -.
    gg(39, 33, -14, 24, 39266), // 46 ..
    gg(47, 66, -14, -7, 40553), // 47 /.
    gg(57, 63, -14, -6, 43655), // 48 0.
    gg(57, 63, -14, -6, 47246), // 49 1.
    gg(57, 63, -14, -6, 50837), // 50 2.
    gg(57, 63, -14, -6, 54428), // 51 3.
    gg(57, 63, -14, -6, 58019), // 52 4.
    gg(57, 63, -14, -6, 61610), // 53 5.
    gg(57, 63, -14, -6, 65201), // 54 6.
    gg(57, 63, -14, -6, 68792), // 55 7.
    gg(57, 63, -14, -6, 72383), // 56 8.
    gg(57, 63, -14, -6, 75974), // 57 9.
    gg(39, 55, -14, 2, 79565), // 58 :.
    gg(41, 61, -14, 2, 81710), // 59 ;.
    gg(57, 54, -14, 3, 84211), // 60 <.
    gg(57, 47, -14, 10, 87289), // 61 =.
    gg(57, 54, -14, 3, 89968), // 62 >.
    gg(55, 63, -14, -6, 93046), // 63 ?.
    gg(72, 68, -14, -6, 96511), // 64 @.
    gg(63, 63, -14, -6, 101407), // 65 A.
    gg(62, 63, -14, -6, 105376), // 66 B.
    gg(64, 63, -14, -6, 109282), // 67 C.
    gg(65, 63, -14, -6, 113314), // 68 D.
    gg(60, 63, -14, -6, 117409), // 69 E.
    gg(58, 63, -14, -6, 121189), // 70 F.
    gg(66, 63, -14, -6, 124843), // 71 G.
    gg(64, 63, -14, -6, 129001), // 72 H.
    gg(40, 63, -14, -6, 133033), // 73 I.
    gg(55, 63, -14, -6, 135553), // 74 J.
    gg(62, 63, -14, -6, 139018), // 75 K.
    gg(56, 63, -14, -6, 142924), // 76 L.
    gg(70, 63, -14, -6, 146452), // 77 M.
    gg(66, 63, -14, -6, 150862), // 78 N.
    gg(67, 63, -14, -6, 155020), // 79 O.
    gg(61, 63, -14, -6, 159241), // 80 P.
    gg(68, 71, -14, -6, 163084), // 81 Q.
    gg(63, 63, -14, -6, 167912), // 82 R.
    gg(60, 63, -14, -6, 171881), // 83 S.
    gg(57, 63, -14, -6, 175661), // 84 T.
    gg(65, 63, -14, -6, 179252), // 85 U.
    gg(61, 63, -14, -6, 183347), // 86 V.
    gg(78, 63, -14, -6, 187190), // 87 W.
    gg(62, 63, -15, -6, 192104), // 88 X.
    gg(61, 63, -14, -6, 196010), // 89 Y.
    gg(58, 63, -14, -6, 199853), // 90 Z.
    gg(43, 71, -14, -7, 203507), // 91 [.
    gg(47, 66, -14, -7, 206560), // 92 \.
    gg(43, 71, -14, -7, 209662), // 93 ].
    gg(54, 64, -14, -7, 212715), // 94 ^.
    gg(59, 35, -14, 29, 216171), // 95 _.
    gg(46, 64, -14, -7, 218236), // 96 `.
    gg(59, 55, -14, 2, 221180), // 97 a.
    gg(59, 65, -14, -8, 224425), // 98 b.
    gg(56, 55, -14, 2, 228260), // 99 c.
    gg(59, 65, -14, -8, 231340), // 100 d.
    gg(57, 55, -14, 2, 235175), // 101 e.
    gg(44, 65, -14, -8, 238310), // 102 f.
    gg(59, 66, -14, 2, 241170), // 103 g.
    gg(57, 65, -14, -8, 245064), // 104 h.
    gg(39, 64, -14, -7, 248769), // 105 i.
    gg(39, 75, -14, -7, 251265), // 106 j.
    gg(55, 65, -14, -8, 254190), // 107 k.
    gg(39, 65, -14, -8, 257765), // 108 l.
    gg(73, 55, -14, 2, 260300), // 109 m.
    gg(57, 55, -14, 2, 264315), // 110 n.
    gg(57, 55, -14, 2, 267450), // 111 o.
    gg(59, 66, -14, 2, 270585), // 112 p.
    gg(59, 66, -14, 2, 274479), // 113 q.
    gg(46, 55, -14, 2, 278373), // 114 r.
    gg(53, 55, -14, 2, 280903), // 115 s.
    gg(45, 64, -14, -7, 283818), // 116 t.
    gg(57, 55, -14, 2, 286698), // 117 u.
    gg(54, 55, -14, 2, 289833), // 118 v.
    gg(67, 55, -14, 2, 292803), // 119 w.
    gg(53, 55, -14, 2, 296488), // 120 x.
    gg(54, 66, -14, 2, 299403), // 121 y.
    gg(52, 55, -14, 2, 302967), // 122 z.
    gg(43, 71, -14, -6, 305827), // 123 {.
    gg(38, 77, -14, -11, 308880), // 124 |.
    gg(43, 71, -14, -6, 311806), // 125 }.
    gg(55, 47, -14, 10, 314859), // 126 ~.
};

// Draws a radiant photographic bloom/glow for a banner glyph to surface.
pub fn drawBannerGlyphGlow(
    surface: *fb.Surface,
    char: u8,
    x: i32,
    y: i32,
    color: u32,
    alpha: u8,
) void {
    if (alpha == 0 or
        char < font.ASCII_PRINTABLE_MIN or
        char > font.ASCII_PRINTABLE_MAX) return;
    const glyph = BANNER_GLOW_GLYPHS[char - font.ASCII_PRINTABLE_MIN];
    const gx = x + @as(i32, glyph.offset_x);
    const gy = y + @as(i32, glyph.offset_y);
    blendAlphaBitmap(
        surface,
        BANNER_GLOW_BITMAPS,
        glyph.bitmap_offset,
        glyph.width,
        glyph.height,
        gx,
        gy,
        color,
        alpha,
    );
}

test "banner_font: verify ascii glyph array and bitmap mapping" {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(@as(usize, 95), BANNER_GLYPHS.len);
    try std.testing.expect(BANNER_BITMAPS.len > 80_000);
    // Verify "diosix" letters.
    for ("diosix") |c| {
        const glyph = BANNER_GLYPHS[c - font.ASCII_PRINTABLE_MIN];
        try std.testing.expect(glyph.width > 0);
        try std.testing.expect(glyph.height > 0);
        const end = glyph.bitmap_offset +
            @as(u32, glyph.width) * @as(u32, glyph.height);
        try std.testing.expect(end <= BANNER_BITMAPS.len);
    }
}

test "banner_font: verify glow ascii glyph array and bitmap mapping" {
    try std.testing.expectEqual(@as(usize, 95), BANNER_GLOW_GLYPHS.len);
    try std.testing.expect(BANNER_GLOW_BITMAPS.len > 200_000);
    // Verify "diosix" letters in glow table.
    for ("diosix") |c| {
        const glyph = BANNER_GLOW_GLYPHS[c - font.ASCII_PRINTABLE_MIN];
        try std.testing.expect(glyph.width > 0);
        try std.testing.expect(glyph.height > 0);
        const end = glyph.bitmap_offset +
            @as(u32, glyph.width) * @as(u32, glyph.height);
        try std.testing.expect(end <= BANNER_GLOW_BITMAPS.len);
    }
}
