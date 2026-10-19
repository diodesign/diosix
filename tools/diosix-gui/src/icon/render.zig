// Widget & Icon Rendering Engine for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("../framebuffer.zig");
const font = @import("../font.zig");
const icon_mod = @import("../icon.zig");
const Icon = icon_mod.Icon;
pub const icon_viewport = @import("viewport.zig");
pub const icon_widgets = @import("widgets.zig");
const boxOf = fb.Box.fromPosSize;

pub const renderTextField = icon_widgets.renderTextField;
pub const renderReadWriteText = icon_widgets.renderReadWriteText;
pub const renderSlider = icon_widgets.renderSlider;
pub const renderTickBox = icon_widgets.renderTickBox;
pub const renderButton = icon_widgets.renderButton;
pub const renderProgressBar = icon_widgets.renderProgressBar;
pub const renderScrollbar = icon_widgets.renderScrollbar;

// Antialiased Back Arrow Bitmap (14x10) - elegant back-pointing arrow.
pub const BACK_ARROW_WIDTH: u32 = 14;
pub const BACK_ARROW_HEIGHT: u32 = 10;
pub const BACK_ARROW_BITMAP = [BACK_ARROW_WIDTH * BACK_ARROW_HEIGHT]u8{
    0,   0,   0,   41,  183, 253, 244, 66,  0,   0,   0,   0,   0,   0,
    0,   0,   52,  198, 254, 252, 167, 21,  0,   0,   0,   0,   0,   0,
    1,   67,  210, 255, 248, 150, 21,  0,   0,   0,   0,   0,   0,   0,
    86,  222, 255, 245, 170, 101, 91,  91,  91,  91,  91,  91,  91,  69,
    237, 255, 255, 253, 253, 253, 253, 253, 253, 253, 253, 253, 253, 237,
    237, 255, 255, 253, 253, 253, 253, 253, 253, 253, 253, 253, 253, 237,
    86,  222, 255, 245, 170, 101, 91,  91,  91,  91,  91,  91,  91,  69,
    1,   67,  210, 255, 248, 150, 21,  0,   0,   0,   0,   0,   0,   0,
    0,   0,   52,  198, 254, 252, 167, 21,  0,   0,   0,   0,   0,   0,
    0,   0,   0,   41,  183, 253, 244, 66,  0,   0,   0,   0,   0,   0,
};

inline fn drawShadowText(
    s: *fb.Surface,
    txt: []const u8,
    x: i32,
    y: i32,
    col: u32,
) void {
    font.drawTextWithShadow(s, txt, x, y, col, fb.Color.BLACK);
}

pub fn drawBackArrow(surface: *fb.Surface, x: i32, y: i32, color: u32) void {
    var r: usize = 0;
    while (r < BACK_ARROW_HEIGHT) : (r += 1) {
        const py = y + @as(i32, @intCast(r));
        var c: usize = 0;
        while (c < BACK_ARROW_WIDTH) : (c += 1) {
            const px = x + @as(i32, @intCast(c));
            const alpha = BACK_ARROW_BITMAP[r * BACK_ARROW_WIDTH + c];
            if (alpha > 0) {
                const bg = surface.getPixel(px, py);
                surface.setPixel(px, py, fb.blendPixel(bg, color, alpha));
            }
        }
    }
}

pub fn drawBackArrowWithShadow(
    surface: *fb.Surface,
    x: i32,
    y: i32,
    fg_color: u32,
    shadow_color: u32,
) void {
    drawBackArrow(surface, x + 1, y + 1, shadow_color);
    drawBackArrow(surface, x, y, fg_color);
}

pub fn renderIcon(
    self: *const Icon,
    surface: *fb.Surface,
    win_x: i32,
    win_y: i32,
    is_win_active: bool,
) void {
    const sx = win_x + self.rel_x;
    const sy = win_y + self.rel_y;
    const box = boxOf(sx, sy, self.width, self.height);

    const prev_icon_clip = surface.pushClip(box);
    defer surface.popClip(prev_icon_clip);

    if (surface.clip.isEmpty()) return;

    const is_highlighted = (self.is_selectable and self.is_hovered);
    const fg_color: u32 = if (!self.is_enabled)
        fb.Color.TEXT_MUTED
    else if (is_highlighted)
        fb.Color.ACCENT_CYAN
    else if (self.custom_color) |c|
        c
    else
        fb.Color.WHITE;

    switch (self.icon_type) {
        .read_only_text => {
            const text_y = sy + @divTrunc(
                @as(i32, @intCast(self.height)) -
                    @as(i32, @intCast(font.GLYPH_HEIGHT)),
                2,
            );
            drawShadowText(surface, self.getText(), sx, text_y, fg_color);
        },
        .read_write_text => renderTextField(
            self,
            surface,
            sx,
            sy,
            box,
            fg_color,
            is_win_active,
        ),
        .slider => renderSlider(self, surface, sx, sy, fg_color),
        .tick_box => renderTickBox(self, surface, sx, sy, fg_color),
        .button => renderButton(self, surface, sx, sy, box, fg_color),
        .progress_bar => renderProgressBar(self, surface, sx, sy, fg_color),
        .video_viewport => icon_viewport.renderVideoViewport(
            self,
            surface,
            sx,
            sy,
            box,
            is_win_active,
        ),
        .menu_item => renderMenuItem(self, surface, sx, sy),
        .slate_card => icon_viewport.renderSlateCard(
            self,
            surface,
            sx,
            sy,
            box,
        ),
    }
}

pub fn renderMenuItem(
    self: *const Icon,
    surface: *fb.Surface,
    sx: i32,
    sy: i32,
) void {
    const item_color: u32 = if (!self.is_enabled)
        fb.Color.TEXT_MUTED
    else if (self.is_hovered or self.is_selected)
        fb.Color.ACCENT_CYAN
    else
        fb.Color.WHITE;

    const text_y = sy + @divTrunc(
        @as(i32, @intCast(self.height)) -
            @as(i32, @intCast(font.GLYPH_HEIGHT)),
        2,
    );

    if (self.has_back_arrow) {
        drawBackArrowWithShadow(
            surface,
            sx,
            text_y + 4,
            item_color,
            fb.Color.BLACK,
        );

        const raw_text = self.getText();
        const display_text = if (std.mem.startsWith(u8, raw_text, "< "))
            raw_text[2..]
        else if (std.mem.startsWith(u8, raw_text, "<"))
            raw_text[1..]
        else
            raw_text;

        const label_x = sx + @as(i32, @intCast(BACK_ARROW_WIDTH + 8));
        drawShadowText(surface, display_text, label_x, text_y, item_color);
    } else {
        drawShadowText(surface, self.getText(), sx, text_y, item_color);
    }
}

test {
    _ = icon_viewport;
    _ = icon_widgets;
    std.testing.refAllDecls(@This());
}
