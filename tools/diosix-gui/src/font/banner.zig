// Questrial-Regular Scalable Vector Banner Typography for Diosix GUI.
//
// Rasterizes high-resolution banner glyphs on demand from
// `Questrial-Regular.ttf` via `font/cache.zig`.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const font = @import("../font.zig");

pub const BANNER_GLYPH_HEIGHT: u32 = 52;

pub fn getBannerGlyph(char: u8) font.cache.GlyphView {
    return font.cache.getGlyph(char, BANNER_GLYPH_HEIGHT);
}

pub fn getBannerGlyphAtHeight(char: u8, height_px: u32) font.cache.GlyphView {
    return font.cache.getGlyph(char, height_px);
}

test "banner_font: verify vector-rasterized banner glyphs" {
    std.testing.refAllDecls(@This());
    for ("DIOSIXdiosix") |c| {
        const view = getBannerGlyph(c);
        try std.testing.expect(view.glyph.width > 0);
        try std.testing.expect(view.glyph.height > 0);
        try std.testing.expectEqual(
            @as(usize, view.glyph.width) * @as(usize, view.glyph.height),
            view.mask.len,
        );
    }
}
