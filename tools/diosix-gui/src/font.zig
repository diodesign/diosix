// Questrial-Regular Scalable Vector Typography Engine for Diosix GUI.
//
// Parses TrueType outlines from `Questrial-Regular.ttf` (SIL Open Font License)
// via `font/ttf.zig` and rasterizes antialiased glyphs on demand into the
// multi-size glyph cache (`font/cache.zig`).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("framebuffer.zig");
const vector = @import("vector.zig");
pub const ttf = @import("font/ttf.zig");
pub const cache = @import("font/cache.zig");

pub const GLYPH_HEIGHT: u32 = 18;
pub const SPACE_ADVANCE: u8 = 6;
pub const TAB_SPACES: u8 = 4;
pub const TAB_ADVANCE: u8 = SPACE_ADVANCE * TAB_SPACES;
pub const FALLBACK_ADVANCE: u8 = 8;
pub const ASCII_PRINTABLE_MIN: u8 = cache.ASCII_MIN;
pub const ASCII_PRINTABLE_MAX: u8 = cache.ASCII_MAX;

var active_line_height: u32 = GLYPH_HEIGHT;

pub fn setActiveLineHeight(height_px: u32) void {
    active_line_height = std.math.clamp(
        height_px,
        cache.MIN_LINE_HEIGHT_PX,
        cache.MAX_LINE_HEIGHT_PX,
    );
}

pub fn getActiveLineHeight() u32 {
    return active_line_height;
}

pub fn getCharAdvanceAtHeight(c: u8, line_height_px: u32) u32 {
    if (c >= ASCII_PRINTABLE_MIN and c <= ASCII_PRINTABLE_MAX) {
        return cache.getGlyph(c, line_height_px).glyph.advance;
    } else if (c == ' ') {
        return cache.getGlyph(' ', line_height_px).glyph.advance;
    } else if (c == '\t') {
        return @as(u32, cache.getGlyph(' ', line_height_px).glyph.advance) *
            TAB_SPACES;
    }
    return @max(4, @divTrunc(line_height_px * FALLBACK_ADVANCE, GLYPH_HEIGHT));
}

pub fn getCharAdvance(c: u8) u32 {
    return getCharAdvanceAtHeight(c, active_line_height);
}

/// Renders antialiased Questrial text at the active line height.
pub fn drawText(
    surface: *fb.Surface,
    text: []const u8,
    x: i32,
    y: i32,
    color: u32,
) void {
    drawTextWithAlpha(surface, text, x, y, color, 255);
}

/// Draws antialiased Questrial text with 1px drop shadow.
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

/// Renders antialiased Questrial text at explicit pixel line height `height_px`
/// modulated by `master_alpha` (0 - 255).
pub fn drawTextAtHeightWithAlpha(
    surface: *fb.Surface,
    text: []const u8,
    x: i32,
    y: i32,
    color: u32,
    master_alpha: u8,
    height_px: u32,
) void {
    if (master_alpha == 0 or surface.clip.isEmpty()) return;
    if (surface.width == 0 or surface.height == 0) return;
    const clip_x0 = @max(0, surface.clip.x0);
    const clip_y0 = @max(0, surface.clip.y0);
    const clip_x1 = @min(@as(i32, @intCast(surface.width)), surface.clip.x1);
    const clip_y1 = @min(@as(i32, @intCast(surface.height)), surface.clip.y1);
    if (clip_x0 >= clip_x1 or clip_y0 >= clip_y1) return;

    const line_h = std.math.clamp(
        height_px,
        cache.MIN_LINE_HEIGHT_PX,
        cache.MAX_LINE_HEIGHT_PX,
    );
    if (y + @as(i32, @intCast(line_h + 6)) <= clip_y0 or y - 4 >= clip_y1) {
        return;
    }

    var cur_x = x;
    for (text) |c| {
        if (c >= ASCII_PRINTABLE_MIN and c <= ASCII_PRINTABLE_MAX) {
            const view = cache.getGlyph(c, line_h);
            const g = view.glyph;
            if (g.width > 0 and g.height > 0) {
                const gx = cur_x + @as(i32, g.offset_x);
                const gy = y + @as(i32, g.offset_y);
                if (gx >= clip_x1) break;
                const g_right = gx + @as(i32, @intCast(g.width));
                if (g_right > clip_x0) {
                    vector.blendMaskOnSurface(
                        surface,
                        view.mask,
                        g.width,
                        g.height,
                        gx,
                        gy,
                        color,
                        master_alpha,
                    );
                }
            }
            cur_x += @as(i32, @intCast(g.advance));
        } else if (c == '\t') {
            if (cur_x >= clip_x1) break;
            const sp = cache.getGlyph(' ', line_h).glyph.advance;
            cur_x += @as(i32, @intCast(sp)) * TAB_SPACES;
        }
    }
}

/// Renders antialiased Questrial text modulated by `master_alpha` (0 - 255).
pub fn drawTextWithAlpha(
    surface: *fb.Surface,
    text: []const u8,
    x: i32,
    y: i32,
    color: u32,
    master_alpha: u8,
) void {
    drawTextAtHeightWithAlpha(
        surface,
        text,
        x,
        y,
        color,
        master_alpha,
        active_line_height,
    );
}

/// Draws antialiased Questrial text with 1px drop shadow modulated by alpha.
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

/// Measures exact rendered pixel width of `text` at `height_px`.
pub fn measureStringAtHeight(text: []const u8, height_px: u32) u32 {
    var cur_w: u32 = 0;
    for (text) |c| {
        cur_w += getCharAdvanceAtHeight(c, height_px);
    }
    return cur_w;
}

/// Measures exact rendered pixel width of `text` at the active line height.
pub fn measureString(text: []const u8) u32 {
    return measureStringAtHeight(text, active_line_height);
}

/// Measures exact rendered pixel width of `text` scaled by `scale_num` /
/// `scale_den` using native vector glyph metrics at the scaled height.
pub fn measureStringScaled(
    text: []const u8,
    scale_num: u32,
    scale_den: u32,
) u32 {
    if (scale_num == 0 or scale_den == 0) return 0;
    const target_h = @max(
        cache.MIN_LINE_HEIGHT_PX,
        @divTrunc(active_line_height * scale_num + (scale_den / 2), scale_den),
    );
    return measureStringAtHeight(text, target_h);
}

/// Renders antialiased Questrial text scaled by `scale_num / scale_den` using
/// native vector outline rasterization at the target pixel height.
pub fn drawTextScaled(
    surface: *fb.Surface,
    text: []const u8,
    x: i32,
    y: i32,
    color: u32,
    scale_num: u32,
    scale_den: u32,
) void {
    if (scale_num == 0 or scale_den == 0) return;
    const target_h = @max(
        cache.MIN_LINE_HEIGHT_PX,
        @divTrunc(active_line_height * scale_num + (scale_den / 2), scale_den),
    );
    drawTextAtHeightWithAlpha(surface, text, x, y, color, 255, target_h);
}

/// Draws antialiased scaled Questrial text with 1px drop shadow.
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

pub const MAX_WRAPPED_LINES: usize = 16;

pub const LineSpan = struct {
    start: usize,
    end: usize,
};

pub const WrappedMetrics = struct {
    width: u32,
    height: u32,
    lines: usize,
};

/// Splits `text` into word-wrapped lines that fit within `max_width_px` at the
/// active line height, populating `out_spans` and returning the line count.
pub fn wrapTextLines(
    text: []const u8,
    max_width_px: u32,
    out_spans: []LineSpan,
) usize {
    if (out_spans.len == 0) return 0;
    if (text.len == 0) {
        out_spans[0] = .{ .start = 0, .end = 0 };
        return 1;
    }
    const limit_w = @max(@as(u32, 24), max_width_px);
    var line_count: usize = 0;
    var i: usize = 0;

    while (i < text.len and line_count < out_spans.len) {
        while (i < text.len and text[i] == ' ') : (i += 1) {}
        if (i >= text.len) break;
        if (text[i] == '\n') {
            out_spans[line_count] = .{ .start = i, .end = i };
            line_count += 1;
            i += 1;
            continue;
        }

        const line_start = i;
        var cur_end = i;
        var last_space: ?usize = null;
        var cur_w: u32 = 0;

        while (cur_end < text.len and text[cur_end] != '\n') {
            const ch = text[cur_end];
            const adv = getCharAdvance(ch);
            if (cur_w + adv > limit_w and cur_end > line_start) {
                if (last_space) |sp| {
                    out_spans[line_count] = .{ .start = line_start, .end = sp };
                    line_count += 1;
                    i = sp + 1;
                } else {
                    out_spans[line_count] = .{
                        .start = line_start,
                        .end = cur_end,
                    };
                    line_count += 1;
                    i = cur_end;
                }
                break;
            }
            if (ch == ' ') last_space = cur_end;
            cur_w += adv;
            cur_end += 1;
        } else {
            out_spans[line_count] = .{ .start = line_start, .end = cur_end };
            line_count += 1;
            i = if (cur_end < text.len and text[cur_end] == '\n')
                cur_end + 1
            else
                cur_end;
        }
    }

    if (line_count == 0) {
        out_spans[0] = .{ .start = 0, .end = text.len };
        return 1;
    }
    return line_count;
}

/// Measures the bounding box and line count of `text` when word-wrapped to
/// `max_width_px` at the active line height.
pub fn measureWrappedText(text: []const u8, max_width_px: u32) WrappedMetrics {
    var spans: [MAX_WRAPPED_LINES]LineSpan = undefined;
    const count = wrapTextLines(text, max_width_px, &spans);
    const lh = active_line_height;
    const gap: u32 = @max(2, lh / 5);
    var max_w: u32 = 0;
    for (spans[0..count]) |sp| {
        const w = measureString(text[sp.start..sp.end]);
        if (w > max_w) max_w = w;
    }
    const n_u32: u32 = @intCast(count);
    const total_h = if (n_u32 > 1)
        n_u32 * lh + (n_u32 - 1) * gap
    else
        lh;
    return .{
        .width = max_w,
        .height = total_h,
        .lines = count,
    };
}

/// Draws `text` word-wrapped within `max_width_px` starting at `(x, y)` and
/// returns the total vertical pixel height consumed.
pub fn drawTextWrapped(
    surface: *fb.Surface,
    text: []const u8,
    x: i32,
    y: i32,
    max_width_px: u32,
    color: u32,
) u32 {
    var spans: [MAX_WRAPPED_LINES]LineSpan = undefined;
    const count = wrapTextLines(text, max_width_px, &spans);
    const lh = active_line_height;
    const gap: u32 = @max(2, lh / 5);
    const step_y: i32 = @intCast(lh + gap);

    var cur_y = y;
    for (spans[0..count]) |sp| {
        drawText(surface, text[sp.start..sp.end], x, cur_y, color);
        cur_y += step_y;
    }
    const n_u32: u32 = @intCast(count);
    return if (n_u32 > 1) n_u32 * lh + (n_u32 - 1) * gap else lh;
}

test "font: vector TrueType measurement and rendering" {
    _ = ttf;
    _ = cache;
    std.testing.refAllDecls(@This());

    const w1 = measureString("Diosix");
    const w2 = measureStringScaled("Diosix", 2, 1);
    try std.testing.expect(w1 > 20);
    try std.testing.expect(w2 > w1);

    const wm = measureWrappedText(
        "All running guest virtual machines will be cleanly stopped.",
        180,
    );
    try std.testing.expect(wm.lines >= 2);
    try std.testing.expect(wm.width <= 180);
    try std.testing.expect(wm.height > active_line_height);
}
