// Native TrueType (.ttf) Outline Parser for Diosix GUI.
//
// Parses TrueType binary tables (`head`, `hhea`, `maxp`, `cmap`, `loca`,
// `glyf`, `hmtx`) directly from embedded `Questrial-Regular.ttf` and extracts
// scalable quadratic Bezier glyph outlines into `vector.VectorPath`.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const vector = @import("../vector.zig");

pub const QUESTRIAL_TTF: []const u8 = @embedFile("Questrial-Regular.ttf");

const ON_CURVE_POINT: u8 = 0x01;
const X_SHORT_VECTOR: u8 = 0x02;
const Y_SHORT_VECTOR: u8 = 0x04;
const REPEAT_FLAG: u8 = 0x08;
const X_SAME_OR_POS: u8 = 0x10;
const Y_SAME_OR_POS: u8 = 0x20;

const COMP_ARGS_ARE_WORDS: u16 = 0x0001;
const COMP_ARGS_ARE_XY: u16 = 0x0002;
const COMP_HAVE_SCALE: u16 = 0x0008;
const COMP_MORE_COMPONENTS: u16 = 0x0020;
const COMP_HAVE_XY_SCALE: u16 = 0x0040;
const COMP_HAVE_2X2: u16 = 0x0080;

const MAX_GLYPH_POINTS: usize = 256;
const MAX_GLYPH_CONTOURS: usize = 32;

pub const GlyphMetrics = struct {
    glyph_id: u16,
    advance_width: u16,
    lsb: i16,
    x_min: i16 = 0,
    y_min: i16 = 0,
    x_max: i16 = 0,
    y_max: i16 = 0,
    has_outline: bool = false,
};

pub const TrueTypeFont = struct {
    data: []const u8,
    units_per_em: u16,
    index_to_loc_format: i16,
    ascent: i16,
    descent: i16,
    line_gap: i16,
    num_hmetrics: u16,
    num_glyphs: u16,
    cmap_subtable: u32,
    loca_offset: u32,
    glyf_offset: u32,
    hmtx_offset: u32,

    pub fn parse(data: []const u8) !TrueTypeFont {
        if (data.len < 12) return error.InvalidFontData;
        const num_tables = readU16(data, 4);
        if (data.len < 12 + @as(usize, num_tables) * 16) {
            return error.InvalidFontData;
        }

        var head_off: ?u32 = null;
        var hhea_off: ?u32 = null;
        var maxp_off: ?u32 = null;
        var cmap_off: ?u32 = null;
        var loca_off: ?u32 = null;
        var glyf_off: ?u32 = null;
        var hmtx_off: ?u32 = null;

        for (0..num_tables) |i| {
            const rec = 12 + i * 16;
            const tag = data[rec .. rec + 4];
            const off = readU32(data, rec + 8);
            const len = readU32(data, rec + 12);
            if (@as(u64, off) + @as(u64, len) > data.len) {
                return error.InvalidFontData;
            }
            if (std.mem.eql(u8, tag, "head")) head_off = off;
            if (std.mem.eql(u8, tag, "hhea")) hhea_off = off;
            if (std.mem.eql(u8, tag, "maxp")) maxp_off = off;
            if (std.mem.eql(u8, tag, "cmap")) cmap_off = off;
            if (std.mem.eql(u8, tag, "loca")) loca_off = off;
            if (std.mem.eql(u8, tag, "glyf")) glyf_off = off;
            if (std.mem.eql(u8, tag, "hmtx")) hmtx_off = off;
        }

        const head = head_off orelse return error.MissingTable;
        const hhea = hhea_off orelse return error.MissingTable;
        const maxp = maxp_off orelse return error.MissingTable;
        const cmap = cmap_off orelse return error.MissingTable;
        const loca = loca_off orelse return error.MissingTable;
        const glyf = glyf_off orelse return error.MissingTable;
        const hmtx = hmtx_off orelse return error.MissingTable;

        const units_per_em = readU16(data, head + 18);
        return .{
            .data = data,
            .units_per_em = if (units_per_em == 0) 1000 else units_per_em,
            .index_to_loc_format = readI16(data, head + 50),
            .ascent = readI16(data, hhea + 4),
            .descent = readI16(data, hhea + 6),
            .line_gap = readI16(data, hhea + 8),
            .num_hmetrics = readU16(data, hhea + 34),
            .num_glyphs = readU16(data, maxp + 4),
            .cmap_subtable = try findFormat4Cmap(data, cmap),
            .loca_offset = loca,
            .glyf_offset = glyf,
            .hmtx_offset = hmtx,
        };
    }

    fn findFormat4Cmap(data: []const u8, cmap_off: u32) !u32 {
        const num_sub = readU16(data, cmap_off + 2);
        for (0..num_sub) |i| {
            const rec = cmap_off + 4 + @as(u32, @intCast(i * 8));
            const sub = cmap_off + readU32(data, rec + 4);
            if (sub + 14 <= data.len and readU16(data, sub) == 4) return sub;
        }
        return error.UnsupportedCmap;
    }

    pub fn glyphIndex(self: *const TrueTypeFont, codepoint: u21) u16 {
        if (codepoint > 0xffff) return 0;
        const cp: u16 = @intCast(codepoint);
        const sub = self.cmap_subtable;
        const seg_count_x2 = readU16(self.data, sub + 6);
        const seg_count = seg_count_x2 / 2;
        const end_counts = sub + 14;
        const start_counts = end_counts + seg_count_x2 + 2;
        const id_deltas = start_counts + seg_count_x2;
        const id_range_offsets = id_deltas + seg_count_x2;

        var i: u32 = 0;
        while (i < seg_count) : (i += 1) {
            const end_c = readU16(self.data, end_counts + i * 2);
            if (cp <= end_c) {
                const start_c = readU16(self.data, start_counts + i * 2);
                if (cp < start_c) return 0;
                const delta = readI16(self.data, id_deltas + i * 2);
                const ro_pos = id_range_offsets + i * 2;
                const ro = readU16(self.data, ro_pos);
                if (ro == 0) return (cp +% @as(u16, @bitCast(delta)));
                const idx_off = ro_pos + ro + @as(u32, cp - start_c) * 2;
                if (idx_off + 2 > self.data.len) return 0;
                const raw_gid = readU16(self.data, idx_off);
                if (raw_gid == 0) return 0;
                return (raw_gid +% @as(u16, @bitCast(delta)));
            }
        }
        return 0;
    }

    fn glyphDataRange(
        self: *const TrueTypeFont,
        glyph_id: u16,
    ) ?struct { start: u32, end: u32 } {
        if (glyph_id >= self.num_glyphs) return null;
        var off0: u32 = 0;
        var off1: u32 = 0;
        if (self.index_to_loc_format == 0) {
            const p = self.loca_offset + @as(u32, glyph_id) * 2;
            if (p + 4 > self.data.len) return null;
            off0 = @as(u32, readU16(self.data, p)) * 2;
            off1 = @as(u32, readU16(self.data, p + 2)) * 2;
        } else {
            const p = self.loca_offset + @as(u32, glyph_id) * 4;
            if (p + 8 > self.data.len) return null;
            off0 = readU32(self.data, p);
            off1 = readU32(self.data, p + 4);
        }
        if (off0 >= off1) return null;
        const start = self.glyf_offset + off0;
        const end = self.glyf_offset + off1;
        if (end > self.data.len or start + 10 > end) return null;
        return .{ .start = start, .end = end };
    }

    pub fn getGlyphMetrics(
        self: *const TrueTypeFont,
        glyph_id: u16,
    ) GlyphMetrics {
        const hm_idx: u32 = if (glyph_id < self.num_hmetrics)
            glyph_id
        else
            self.num_hmetrics -| 1;
        const hm_pos = self.hmtx_offset + hm_idx * 4;
        const d = self.data;
        const adv = if (hm_pos + 2 <= d.len) readU16(d, hm_pos) else 0;
        const lsb = if (hm_pos + 4 <= d.len) readI16(d, hm_pos + 2) else 0;
        if (self.glyphDataRange(glyph_id)) |r| {
            return .{
                .glyph_id = glyph_id,
                .advance_width = adv,
                .lsb = lsb,
                .x_min = readI16(d, r.start + 2),
                .y_min = readI16(d, r.start + 4),
                .x_max = readI16(d, r.start + 6),
                .y_max = readI16(d, r.start + 8),
                .has_outline = true,
            };
        }
        return .{ .glyph_id = glyph_id, .advance_width = adv, .lsb = lsb };
    }

    pub fn appendGlyphPath(
        self: *const TrueTypeFont,
        glyph_id: u16,
        offset_x: f32,
        offset_y: f32,
        path: *vector.VectorPath,
        depth: u8,
    ) void {
        if (depth > 4) return;
        const range = self.glyphDataRange(glyph_id) orelse return;
        const num_contours = readI16(self.data, range.start);
        if (num_contours > 0) {
            self.appendSimpleGlyph(
                range.start,
                range.end,
                @intCast(num_contours),
                offset_x,
                offset_y,
                path,
            );
        } else if (num_contours < 0) {
            self.appendCompositeGlyph(
                range.start,
                range.end,
                offset_x,
                offset_y,
                path,
                depth + 1,
            );
        }
    }

    fn appendSimpleGlyph(
        self: *const TrueTypeFont,
        g_start: u32,
        g_end: u32,
        num_contours: u16,
        offset_x: f32,
        offset_y: f32,
        path: *vector.VectorPath,
    ) void {
        const contours_n: usize =
            @min(@as(usize, num_contours), MAX_GLYPH_CONTOURS);
        if (contours_n == 0) return;
        const end_pts_pos = g_start + 10;
        if (end_pts_pos + contours_n * 2 + 2 > g_end) return;

        var end_pts: [MAX_GLYPH_CONTOURS]u16 = undefined;
        for (0..contours_n) |c| {
            end_pts[c] = readU16(
                self.data,
                end_pts_pos + @as(u32, @intCast(c * 2)),
            );
        }
        const num_pts: usize = @as(usize, end_pts[contours_n - 1]) + 1;
        if (num_pts == 0 or num_pts > MAX_GLYPH_POINTS) return;

        const insn_len_pos = end_pts_pos + @as(u32, @intCast(num_contours)) * 2;
        if (insn_len_pos + 2 > g_end) return;
        var pos = insn_len_pos + 2 + readU16(self.data, insn_len_pos);
        if (pos > g_end) return;

        var flags: [MAX_GLYPH_POINTS]u8 = undefined;
        var pt_idx: usize = 0;
        while (pt_idx < num_pts) {
            if (pos >= g_end) return;
            const f = self.data[pos];
            pos += 1;
            flags[pt_idx] = f;
            pt_idx += 1;
            if ((f & REPEAT_FLAG) != 0) {
                if (pos >= g_end) return;
                const repeat_count = self.data[pos];
                pos += 1;
                var r: usize = 0;
                while (r < repeat_count and pt_idx < num_pts) : (r += 1) {
                    flags[pt_idx] = f;
                    pt_idx += 1;
                }
            }
        }

        var xs: [MAX_GLYPH_POINTS]f32 = undefined;
        var ys: [MAX_GLYPH_POINTS]f32 = undefined;
        if (!unpackCoords(
            self.data,
            &pos,
            g_end,
            flags[0..num_pts],
            X_SHORT_VECTOR,
            X_SAME_OR_POS,
            offset_x,
            xs[0..num_pts],
        )) return;
        if (!unpackCoords(
            self.data,
            &pos,
            g_end,
            flags[0..num_pts],
            Y_SHORT_VECTOR,
            Y_SAME_OR_POS,
            offset_y,
            ys[0..num_pts],
        )) return;

        var c_start: usize = 0;
        for (0..contours_n) |c| {
            const c_end: usize = end_pts[c];
            if (c_end >= num_pts or c_end < c_start) break;
            emitContour(
                xs[c_start .. c_end + 1],
                ys[c_start .. c_end + 1],
                flags[c_start .. c_end + 1],
                path,
            );
            c_start = c_end + 1;
        }
    }

    fn appendCompositeGlyph(
        self: *const TrueTypeFont,
        g_start: u32,
        g_end: u32,
        offset_x: f32,
        offset_y: f32,
        path: *vector.VectorPath,
        depth: u8,
    ) void {
        var pos = g_start + 10;
        while (pos + 4 <= g_end) {
            const comp_flags = readU16(self.data, pos);
            const sub_gid = readU16(self.data, pos + 2);
            pos += 4;

            var dx: f32 = 0;
            var dy: f32 = 0;
            if ((comp_flags & COMP_ARGS_ARE_WORDS) != 0) {
                if (pos + 4 > g_end) return;
                if ((comp_flags & COMP_ARGS_ARE_XY) != 0) {
                    dx = @floatFromInt(readI16(self.data, pos));
                    dy = @floatFromInt(readI16(self.data, pos + 2));
                }
                pos += 4;
            } else {
                if (pos + 2 > g_end) return;
                if ((comp_flags & COMP_ARGS_ARE_XY) != 0) {
                    const b0: i8 = @bitCast(self.data[pos]);
                    const b1: i8 = @bitCast(self.data[pos + 1]);
                    dx = @floatFromInt(b0);
                    dy = @floatFromInt(b1);
                }
                pos += 2;
            }

            if ((comp_flags & COMP_HAVE_SCALE) != 0) {
                pos += 2;
            } else if ((comp_flags & COMP_HAVE_XY_SCALE) != 0) {
                pos += 4;
            } else if ((comp_flags & COMP_HAVE_2X2) != 0) {
                pos += 8;
            }

            self.appendGlyphPath(
                sub_gid,
                offset_x + dx,
                offset_y + dy,
                path,
                depth,
            );
            if ((comp_flags & COMP_MORE_COMPONENTS) == 0) break;
        }
    }
};

fn unpackCoords(
    data: []const u8,
    pos: *u32,
    g_end: u32,
    flags: []const u8,
    short_bit: u8,
    same_bit: u8,
    offset: f32,
    out: []f32,
) bool {
    var cur: i32 = 0;
    for (flags, 0..) |f, i| {
        if ((f & short_bit) != 0) {
            if (pos.* >= g_end) return false;
            const d: i32 = data[pos.*];
            pos.* += 1;
            cur += if ((f & same_bit) != 0) d else -d;
        } else if ((f & same_bit) == 0) {
            if (pos.* + 2 > g_end) return false;
            cur += readI16(data, pos.*);
            pos.* += 2;
        }
        out[i] = @as(f32, @floatFromInt(cur)) + offset;
    }
    return true;
}

fn emitContour(
    xs: []const f32,
    ys: []const f32,
    flags: []const u8,
    path: *vector.VectorPath,
) void {
    const n = xs.len;
    if (n < 2) return;

    const first_on = (flags[0] & ON_CURVE_POINT) != 0;
    const last_on = (flags[n - 1] & ON_CURVE_POINT) != 0;

    var start_x: f32 = undefined;
    var start_y: f32 = undefined;
    var idx: usize = 0;

    if (first_on) {
        start_x = xs[0];
        start_y = ys[0];
        idx = 1;
    } else if (last_on) {
        start_x = xs[n - 1];
        start_y = ys[n - 1];
    } else {
        start_x = (xs[n - 1] + xs[0]) * 0.5;
        start_y = (ys[n - 1] + ys[0]) * 0.5;
    }
    path.moveTo(start_x, start_y);

    var have_ctrl = false;
    var ctrl_x: f32 = 0;
    var ctrl_y: f32 = 0;
    while (idx < n) : (idx += 1) {
        const px = xs[idx];
        const py = ys[idx];
        if ((flags[idx] & ON_CURVE_POINT) != 0) {
            if (have_ctrl)
                path.quadTo(ctrl_x, ctrl_y, px, py)
            else
                path.lineTo(px, py);
            have_ctrl = false;
        } else {
            if (have_ctrl) {
                const mx = (ctrl_x + px) * 0.5;
                const my = (ctrl_y + py) * 0.5;
                path.quadTo(ctrl_x, ctrl_y, mx, my);
            }
            ctrl_x = px;
            ctrl_y = py;
            have_ctrl = true;
        }
    }
    if (have_ctrl)
        path.quadTo(ctrl_x, ctrl_y, start_x, start_y)
    else
        path.lineTo(start_x, start_y);
    path.close();
}

fn readU16(data: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, data[off..][0..2], .big);
}

fn readI16(data: []const u8, off: usize) i16 {
    return std.mem.readInt(i16, data[off..][0..2], .big);
}

fn readU32(data: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, data[off..][0..4], .big);
}

test "ttf parser: parse Questrial-Regular.ttf and extract glyph outlines" {
    std.testing.refAllDecls(@This());
    const ttf = try TrueTypeFont.parse(QUESTRIAL_TTF);
    try std.testing.expectEqual(@as(u16, 1000), ttf.units_per_em);
    try std.testing.expect(ttf.num_glyphs > 100);

    const gid_a = ttf.glyphIndex('A');
    try std.testing.expect(gid_a != 0);
    const metrics_a = ttf.getGlyphMetrics(gid_a);
    try std.testing.expect(metrics_a.has_outline);
    try std.testing.expect(metrics_a.advance_width > 500);

    var path = vector.VectorPath.init();
    ttf.appendGlyphPath(gid_a, 0, 0, &path, 0);
    try std.testing.expect(path.len > 4);
}
