// Questrial-Regular Antialiased Typography Engine for Diosix GUI.
//
// Rendered from Questrial-Regular.ttf (SIL Open Font License).
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("framebuffer.zig");

pub const GLYPH_HEIGHT: u32 = 18;
pub const SPACE_ADVANCE: u8 = 6;
pub const TAB_SPACES: u8 = 4;
pub const TAB_ADVANCE: u8 = SPACE_ADVANCE * TAB_SPACES;
pub const FALLBACK_ADVANCE: u8 = 8;
pub const ASCII_PRINTABLE_MIN: u8 = 0x20;
pub const ASCII_PRINTABLE_MAX: u8 = 0x7e;

pub const Glyph = struct {
    advance: u8,
    width: u8,
    height: u8,
    offset_x: i8,
    offset_y: i8,
    bitmap_offset: u32,
};

fn g(adv: u8, w: u8, h: u8, ox: i8, oy: i8, off: u32) Glyph {
    return .{
        .advance = adv,
        .width = w,
        .height = h,
        .offset_x = ox,
        .offset_y = oy,
        .bitmap_offset = off,
    };
}

pub const GLYPHS = [95]Glyph{
    g(6, 0, 0, 0, 0, 0),
    g(4, 4, 10, 0, 4, 0),
    g(5, 5, 10, 0, 4, 40),
    g(9, 9, 10, 0, 4, 90),
    g(10, 10, 14, 0, 2, 180),
    g(14, 14, 10, 0, 4, 320),
    g(9, 9, 10, 0, 4, 460),
    g(3, 3, 10, 0, 4, 550),
    g(4, 4, 13, 0, 3, 580),
    g(4, 4, 13, 0, 3, 632),
    g(6, 6, 10, 0, 4, 684),
    g(9, 9, 7, 0, 7, 744),
    g(4, 4, 3, 0, 13, 807),
    g(6, 6, 5, 0, 9, 819),
    g(3, 3, 2, 0, 12, 849),
    g(6, 6, 11, 0, 4, 855),
    g(9, 9, 10, 0, 4, 921),
    g(9, 9, 10, 0, 4, 1011),
    g(9, 9, 10, 0, 4, 1101),
    g(9, 9, 10, 0, 4, 1191),
    g(9, 9, 10, 0, 4, 1281),
    g(9, 9, 10, 0, 4, 1371),
    g(9, 9, 10, 0, 4, 1461),
    g(9, 9, 10, 0, 4, 1551),
    g(9, 9, 10, 0, 4, 1641),
    g(9, 9, 10, 0, 4, 1731),
    g(3, 3, 8, 0, 6, 1821),
    g(4, 4, 9, 0, 6, 1845),
    g(9, 9, 8, 0, 6, 1881),
    g(9, 9, 6, 0, 8, 1953),
    g(9, 9, 8, 0, 6, 2007),
    g(8, 8, 10, 0, 4, 2079),
    g(14, 14, 13, 0, 4, 2159),
    g(11, 11, 10, 0, 4, 2341),
    g(11, 11, 10, 0, 4, 2451),
    g(11, 11, 10, 0, 4, 2561),
    g(11, 11, 10, 0, 4, 2671),
    g(10, 10, 10, 0, 4, 2781),
    g(9, 9, 10, 0, 4, 2881),
    g(12, 12, 10, 0, 4, 2971),
    g(11, 11, 10, 0, 4, 3091),
    g(4, 4, 10, 0, 4, 3201),
    g(8, 8, 10, 0, 4, 3241),
    g(10, 11, 10, 0, 4, 3321),
    g(9, 9, 10, 0, 4, 3431),
    g(13, 13, 10, 0, 4, 3521),
    g(12, 12, 10, 0, 4, 3651),
    g(12, 12, 10, 0, 4, 3771),
    g(10, 10, 10, 0, 4, 3891),
    g(12, 13, 13, 0, 4, 3991),
    g(11, 11, 10, 0, 4, 4160),
    g(10, 10, 10, 0, 4, 4270),
    g(9, 9, 10, 0, 4, 4370),
    g(11, 11, 10, 0, 4, 4460),
    g(10, 10, 10, 0, 4, 4570),
    g(15, 16, 10, 0, 4, 4670),
    g(10, 11, 10, -1, 4, 4830),
    g(10, 11, 10, 0, 4, 4940),
    g(9, 9, 10, 0, 4, 5050),
    g(4, 5, 14, 0, 4, 5140),
    g(6, 6, 11, 0, 4, 5210),
    g(4, 4, 14, 0, 4, 5276),
    g(8, 8, 11, 0, 3, 5332),
    g(10, 10, 3, 0, 14, 5420),
    g(5, 5, 11, 0, 3, 5450),
    g(10, 10, 8, 0, 6, 5505),
    g(10, 10, 11, 0, 3, 5585),
    g(9, 9, 8, 0, 6, 5695),
    g(10, 10, 11, 0, 3, 5767),
    g(9, 9, 8, 0, 6, 5877),
    g(5, 5, 11, 0, 3, 5949),
    g(10, 10, 11, 0, 6, 6004),
    g(9, 9, 11, 0, 3, 6114),
    g(3, 3, 11, 0, 3, 6213),
    g(3, 3, 14, 0, 3, 6246),
    g(8, 9, 11, 0, 3, 6288),
    g(3, 3, 11, 0, 3, 6387),
    g(14, 14, 8, 0, 6, 6420),
    g(9, 9, 8, 0, 6, 6532),
    g(9, 9, 8, 0, 6, 6604),
    g(10, 10, 11, 0, 6, 6676),
    g(10, 10, 11, 0, 6, 6786),
    g(6, 6, 8, 0, 6, 6896),
    g(8, 8, 8, 0, 6, 6944),
    g(5, 5, 10, 0, 4, 7008),
    g(9, 9, 8, 0, 6, 7058),
    g(8, 8, 8, 0, 6, 7130),
    g(12, 12, 8, 0, 6, 7194),
    g(8, 8, 8, 0, 6, 7290),
    g(8, 8, 11, 0, 6, 7354),
    g(7, 7, 8, 0, 6, 7442),
    g(5, 5, 14, 0, 4, 7498),
    g(3, 3, 15, 0, 2, 7568),
    g(5, 5, 14, 0, 4, 7613),
    g(8, 8, 6, 0, 8, 7683),
};

pub const GLYPH_BITMAPS: *const [7731]u8 = @embedFile("font_bitmaps.bin");

// Render antialiased Questrial text with active clipping support.
pub fn drawText(
    surface: *fb.Surface,
    text: []const u8,
    x: i32,
    y: i32,
    color: u32,
) void {
    drawTextWithAlpha(surface, text, x, y, color, 255);
}

// Draw antialiased Questrial text with 1px drop shadow.
pub fn drawTextWithShadow(
    surface: *fb.Surface,
    text: []const u8,
    x: i32,
    y: i32,
    fg_color: u32,
    shadow_color: u32,
) void {
    drawText(surface, text, x + 1, y + 1, shadow_color);
    drawText(surface, text, x, y, fg_color);
}

// Render antialiased Questrial text modulated by master alpha (0 - 255).
pub fn drawTextWithAlpha(
    surface: *fb.Surface,
    text: []const u8,
    x: i32,
    y: i32,
    color: u32,
    master_alpha: u8,
) void {
    if (master_alpha == 0 or surface.clip.isEmpty()) return;
    if (surface.width == 0 or surface.height == 0) return;
    const clip_x0 = @max(0, surface.clip.x0);
    const clip_y0 = @max(0, surface.clip.y0);
    const clip_x1 = @min(@as(i32, @intCast(surface.width)), surface.clip.x1);
    const clip_y1 = @min(@as(i32, @intCast(surface.height)), surface.clip.y1);
    if (clip_x0 >= clip_x1 or clip_y0 >= clip_y1) return;
    if (y + @as(i32, @intCast(GLYPH_HEIGHT)) <= clip_y0 or y >= clip_y1) {
        return;
    }

    var cur_x = x;
    for (text) |c| {
        if (c >= ASCII_PRINTABLE_MIN and c <= ASCII_PRINTABLE_MAX) {
            const glyph = GLYPHS[c - ASCII_PRINTABLE_MIN];
            if (glyph.width > 0 and glyph.height > 0) {
                const gx = cur_x + glyph.offset_x;
                const gy = y + glyph.offset_y;

                if (gx >= clip_x1) break;

                const g_right = gx + @as(i32, @intCast(glyph.width));
                if (g_right <= clip_x0) {
                    cur_x += glyph.advance;
                    continue;
                }

                const pixels_per_row = surface.stridePixels();
                var row: usize = 0;
                while (row < glyph.height) : (row += 1) {
                    const py = gy + @as(i32, @intCast(row));
                    if (py < clip_y0 or py >= clip_y1) continue;

                    const row_offset =
                        @as(usize, @intCast(py)) * pixels_per_row;
                    const bitmap_row_start =
                        glyph.bitmap_offset + row * glyph.width;

                    var col: usize = 0;
                    while (col < glyph.width) : (col += 1) {
                        const px = gx + @as(i32, @intCast(col));
                        if (px < clip_x0 or px >= clip_x1) {
                            continue;
                        }

                        const raw_a = GLYPH_BITMAPS[bitmap_row_start + col];
                        if (raw_a > 0) {
                            const eff_a: u8 = if (master_alpha == 255)
                                raw_a
                            else
                                @intCast(
                                    (@as(u32, raw_a) *
                                        @as(u32, master_alpha)) >> 8,
                                );
                            if (eff_a > 0) {
                                const dst_idx =
                                    row_offset + @as(usize, @intCast(px));
                                if (eff_a == 255) {
                                    surface.pixels[dst_idx] = color;
                                } else {
                                    const bg = surface.pixels[dst_idx];
                                    surface.pixels[dst_idx] =
                                        fb.blendPixel(bg, color, eff_a);
                                }
                            }
                        }
                    }
                }
            }
            cur_x += glyph.advance;
        } else if (c == ' ') {
            if (cur_x >= clip_x1) break;
            cur_x += SPACE_ADVANCE;
        } else if (c == '\t') {
            if (cur_x >= clip_x1) break;
            cur_x += TAB_ADVANCE;
        }
    }
}

// Draw antialiased Questrial text with 1px drop shadow modulated by alpha.
pub fn drawTextWithShadowAlpha(
    surface: *fb.Surface,
    text: []const u8,
    x: i32,
    y: i32,
    fg_color: u32,
    shadow_color: u32,
    master_alpha: u8,
) void {
    if (master_alpha == 0) return;
    drawTextWithAlpha(surface, text, x + 1, y + 1, shadow_color, master_alpha);
    drawTextWithAlpha(surface, text, x, y, fg_color, master_alpha);
}

// Measure exact rendered pixel width of string.
pub fn measureString(text: []const u8) u32 {
    var cur_w: u32 = 0;
    for (text) |c| {
        if (c >= ASCII_PRINTABLE_MIN and c <= ASCII_PRINTABLE_MAX) {
            cur_w += GLYPHS[c - ASCII_PRINTABLE_MIN].advance;
        } else if (c == ' ') {
            cur_w += SPACE_ADVANCE;
        } else if (c == '\t') {
            cur_w += TAB_ADVANCE;
        }
    }
    return cur_w;
}

// Measure exact rendered pixel width of string scaled by scale_num / scale_den.
pub fn measureStringScaled(
    text: []const u8,
    scale_num: u32,
    scale_den: u32,
) u32 {
    if (scale_den == 0) return 0;
    const base_w = measureString(text);
    return @intCast(
        @divTrunc(@as(u64, base_w) * scale_num + (scale_den - 1), scale_den),
    );
}

// Render antialiased Questrial text scaled by scale_num / scale_den ratio.
pub fn drawTextScaled(
    surface: *fb.Surface,
    text: []const u8,
    x: i32,
    y: i32,
    color: u32,
    scale_num: u32,
    scale_den: u32,
) void {
    if (surface.clip.isEmpty()) return;
    if (surface.width == 0 or surface.height == 0) return;
    if (scale_num == 0 or scale_den == 0) return;
    if (scale_num == scale_den) {
        drawText(surface, text, x, y, color);
        return;
    }

    const clip_x0 = @max(0, surface.clip.x0);
    const clip_y0 = @max(0, surface.clip.y0);
    const clip_x1 = @min(@as(i32, @intCast(surface.width)), surface.clip.x1);
    const clip_y1 = @min(@as(i32, @intCast(surface.height)), surface.clip.y1);
    if (clip_x0 >= clip_x1 or clip_y0 >= clip_y1) return;

    const scaled_h = @divTrunc(GLYPH_HEIGHT * scale_num, scale_den);
    if (y + @as(i32, @intCast(scaled_h)) <= clip_y0 or y >= clip_y1) {
        return;
    }

    const s_num_i: i32 = @intCast(scale_num);
    const s_den_i: i32 = @intCast(scale_den);
    var cur_x = x;
    for (text) |c| {
        if (c >= ASCII_PRINTABLE_MIN and c <= ASCII_PRINTABLE_MAX) {
            const glyph = GLYPHS[c - ASCII_PRINTABLE_MIN];
            const scaled_advance =
                @divTrunc(@as(i32, @intCast(glyph.advance)) * s_num_i, s_den_i);
            if (glyph.width > 0 and glyph.height > 0) {
                const scaled_off_x = @divTrunc(
                    @as(i32, @intCast(glyph.offset_x)) * s_num_i,
                    s_den_i,
                );
                const scaled_off_y = @divTrunc(
                    @as(i32, @intCast(glyph.offset_y)) * s_num_i,
                    s_den_i,
                );
                const scaled_gw = @divTrunc(
                    @as(u32, @intCast(glyph.width)) * scale_num +
                        (scale_den - 1),
                    scale_den,
                );
                const scaled_gh = @divTrunc(
                    @as(u32, @intCast(glyph.height)) * scale_num +
                        (scale_den - 1),
                    scale_den,
                );

                const gx = cur_x + scaled_off_x;
                const gy = y + scaled_off_y;

                if (gx >= clip_x1) break;

                const g_right = gx + @as(i32, @intCast(scaled_gw));
                if (g_right <= clip_x0) {
                    cur_x += scaled_advance;
                    continue;
                }

                const pixels_per_row = surface.stridePixels();
                var row: usize = 0;
                while (row < scaled_gh) : (row += 1) {
                    const py = gy + @as(i32, @intCast(row));
                    if (py < clip_y0 or py >= clip_y1) continue;

                    const src_row = @divTrunc(row * scale_den, scale_num);
                    if (src_row >= glyph.height) continue;

                    const row_offset =
                        @as(usize, @intCast(py)) * pixels_per_row;
                    const bitmap_row_start =
                        glyph.bitmap_offset + src_row * glyph.width;

                    var col: usize = 0;
                    while (col < scaled_gw) : (col += 1) {
                        const px = gx + @as(i32, @intCast(col));
                        if (px < clip_x0 or px >= clip_x1) {
                            continue;
                        }

                        const src_col = @divTrunc(col * scale_den, scale_num);
                        if (src_col >= glyph.width) continue;

                        const alpha = GLYPH_BITMAPS[bitmap_row_start + src_col];
                        if (alpha > 0) {
                            const dst_idx =
                                row_offset + @as(usize, @intCast(px));
                            if (alpha == 255) {
                                surface.pixels[dst_idx] = color;
                            } else {
                                const bg = surface.pixels[dst_idx];
                                surface.pixels[dst_idx] =
                                    fb.blendPixel(bg, color, alpha);
                            }
                        }
                    }
                }
            }
            cur_x += scaled_advance;
        } else if (c == ' ') {
            if (cur_x >= clip_x1) break;
            cur_x += @divTrunc(
                @as(i32, @intCast(SPACE_ADVANCE)) * s_num_i,
                s_den_i,
            );
        } else if (c == '\t') {
            if (cur_x >= clip_x1) break;
            cur_x += @divTrunc(
                @as(i32, @intCast(TAB_ADVANCE)) * s_num_i,
                s_den_i,
            );
        }
    }
}

// Draw antialiased scaled Questrial text with 1px drop shadow.
pub fn drawTextScaledWithShadow(
    surface: *fb.Surface,
    text: []const u8,
    x: i32,
    y: i32,
    fg_color: u32,
    shadow_color: u32,
    scale_num: u32,
    scale_den: u32,
) void {
    drawTextScaled(
        surface,
        text,
        x + 1,
        y + 1,
        shadow_color,
        scale_num,
        scale_den,
    );
    drawTextScaled(surface, text, x, y, fg_color, scale_num, scale_den);
}

test {
    std.testing.refAllDecls(@This());
}
