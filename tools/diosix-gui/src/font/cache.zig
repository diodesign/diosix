// Scalable Antialiased TrueType Glyph Cache for Diosix GUI.
//
// Lazily rasterizes glyphs from `Questrial-Regular.ttf` at any requested pixel
// line height using analytic scanline area coverage and caches the resulting
// 8-bit alpha masks and metrics in a multi-size LRU table.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const vector = @import("../vector.zig");
const ttf = @import("ttf.zig");

pub const ASCII_MIN: u8 = 0x20;
pub const ASCII_MAX: u8 = 0x7e;
pub const ASCII_COUNT: usize = ASCII_MAX - ASCII_MIN + 1;

pub const MIN_LINE_HEIGHT_PX: u32 = 8;
pub const MAX_LINE_HEIGHT_PX: u32 = 240;
pub const MAX_SIZE_SLOTS: usize = 8;
pub const SLOT_MASK_CAPACITY: usize = 131072;

pub const CachedGlyph = struct {
    advance: u16 = 0,
    width: u16 = 0,
    height: u16 = 0,
    offset_x: i16 = 0,
    offset_y: i16 = 0,
    mask_offset: u32 = 0,
};

pub const GlyphView = struct {
    glyph: CachedGlyph,
    mask: []const u8,
};

const SizeSlot = struct {
    line_height_px: u16 = 0,
    last_used_tick: u64 = 0,
    mask_used: u32 = 0,
    populated: [ASCII_COUNT]bool = @splat(false),
    glyphs: [ASCII_COUNT]CachedGlyph = @splat(.{}),
    mask_buf: [SLOT_MASK_CAPACITY]u8 = undefined,

    fn reset(self: *SizeSlot, height_px: u16, tick: u64) void {
        self.line_height_px = height_px;
        self.last_used_tick = tick;
        self.mask_used = 0;
        @memset(&self.populated, false);
    }
};

var parsed_font: ?ttf.TrueTypeFont = null;
var slots: [MAX_SIZE_SLOTS]SizeSlot = @splat(.{});
var access_tick: u64 = 1;

fn getFont() *const ttf.TrueTypeFont {
    if (parsed_font == null) {
        parsed_font = ttf.TrueTypeFont.parse(ttf.QUESTRIAL_TTF) catch
            unreachable;
    }
    return &parsed_font.?;
}

fn acquireSlot(line_height_px: u16) *SizeSlot {
    access_tick +%= 1;
    for (&slots) |*s| {
        if (s.line_height_px == line_height_px) {
            s.last_used_tick = access_tick;
            return s;
        }
    }
    var victim_idx: usize = 0;
    var oldest_tick: u64 = slots[0].last_used_tick;
    for (&slots, 0..) |*s, idx| {
        if (s.line_height_px == 0) {
            victim_idx = idx;
            break;
        }
        if (s.last_used_tick < oldest_tick) {
            oldest_tick = s.last_used_tick;
            victim_idx = idx;
        }
    }
    slots[victim_idx].reset(line_height_px, access_tick);
    return &slots[victim_idx];
}

fn populateGlyph(slot: *SizeSlot, char: u8) void {
    const idx = char - ASCII_MIN;
    slot.populated[idx] = true;

    const f = getFont();
    const h_f: f32 = @floatFromInt(slot.line_height_px);
    const em_px = h_f * (15.0 / 18.0);
    const baseline_y = @round(h_f * (14.2 / 18.0));
    const scale = em_px / @as(f32, @floatFromInt(f.units_per_em));

    const gid = f.glyphIndex(char);
    const m = f.getGlyphMetrics(gid);
    const adv_f = @round(@as(f32, @floatFromInt(m.advance_width)) * scale);
    const adv_px: u16 = @intFromFloat(@max(1.0, adv_f));

    if (!m.has_outline or char == ' ') {
        slot.glyphs[idx] = .{
            .advance = adv_px,
            .width = 0,
            .height = 0,
            .offset_x = 0,
            .offset_y = 0,
            .mask_offset = 0,
        };
        return;
    }

    const x0_f = @floor(@as(f32, @floatFromInt(m.x_min)) * scale);
    const x1_f = @ceil(@as(f32, @floatFromInt(m.x_max)) * scale) + 1.0;
    const y0_f = @floor(baseline_y - @as(f32, @floatFromInt(m.y_max)) * scale);
    const y1_f =
        @ceil(baseline_y - @as(f32, @floatFromInt(m.y_min)) * scale) + 1.0;

    const gw: u16 = @intFromFloat(@max(1.0, @min(255.0, x1_f - x0_f)));
    const gh: u16 = @intFromFloat(@max(1.0, @min(255.0, y1_f - y0_f)));
    const byte_count: u32 = @as(u32, gw) * @as(u32, gh);

    if (@as(usize, slot.mask_used) + @as(usize, byte_count) >
        slot.mask_buf.len)
    {
        // Slot arena full; reset this slot and re-populate cleanly.
        slot.reset(slot.line_height_px, access_tick);
        slot.populated[idx] = true;
    }

    const mask_off = slot.mask_used;
    slot.mask_used += byte_count;
    const out_slice = slot.mask_buf[mask_off .. mask_off + byte_count];

    var path = vector.VectorPath.init();
    f.appendGlyphPath(gid, 0, 0, &path, 0);
    path.rasterizeToMask(
        scale,
        -scale,
        -x0_f,
        baseline_y - y0_f,
        out_slice,
        gw,
        gh,
        .non_zero,
    );

    slot.glyphs[idx] = .{
        .advance = adv_px,
        .width = gw,
        .height = gh,
        .offset_x = @intFromFloat(x0_f),
        .offset_y = @intFromFloat(y0_f),
        .mask_offset = mask_off,
    };
}

/// Retrieves the cached antialiased glyph metrics and coverage mask for `char`
/// at `line_height_px`, rasterizing from the TrueType outline on first access.
pub fn getGlyph(char: u8, line_height_px: u32) GlyphView {
    const clamped_h: u16 = @intCast(
        std.math.clamp(line_height_px, MIN_LINE_HEIGHT_PX, MAX_LINE_HEIGHT_PX),
    );
    const safe_c = if (char >= ASCII_MIN and char <= ASCII_MAX)
        char
    else
        '?';
    const idx = safe_c - ASCII_MIN;
    const slot = acquireSlot(clamped_h);
    if (!slot.populated[idx]) {
        populateGlyph(slot, safe_c);
    }
    const g = slot.glyphs[idx];
    const len = @as(usize, g.width) * @as(usize, g.height);
    return .{
        .glyph = g,
        .mask = slot.mask_buf[g.mask_offset .. g.mask_offset + len],
    };
}

test "glyph cache: rasterizes and caches Questrial glyphs across sizes" {
    std.testing.refAllDecls(@This());
    const g18 = getGlyph('A', 18);
    try std.testing.expect(g18.glyph.width > 0);
    try std.testing.expect(g18.glyph.height > 0);
    try std.testing.expect(g18.glyph.advance > 0);

    var non_zero: usize = 0;
    for (g18.mask) |a| {
        if (a > 0) non_zero += 1;
    }
    try std.testing.expect(non_zero > 10);

    const g36 = getGlyph('A', 36);
    try std.testing.expect(g36.glyph.width > g18.glyph.width);
    try std.testing.expect(g36.glyph.height > g18.glyph.height);
}
