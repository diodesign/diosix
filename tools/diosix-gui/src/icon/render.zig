// Scalable Vector Widget & Icon Rendering Engine for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("../framebuffer.zig");
const font = @import("../font.zig");
const vector = @import("../vector.zig");
const icon_mod = @import("../icon.zig");
const Icon = icon_mod.Icon;
pub const icon_widgets = @import("widgets.zig");
const boxOf = fb.Box.fromPosSize;

pub const renderTextField = icon_widgets.renderTextField;
pub const renderReadWriteText = icon_widgets.renderReadWriteText;
pub const renderSlider = icon_widgets.renderSlider;
pub const renderTickBox = icon_widgets.renderTickBox;
pub const renderButton = icon_widgets.renderButton;
pub const renderDropdown = icon_widgets.renderDropdown;

pub const BACK_ARROW_WIDTH: u32 = 14;
pub const BACK_ARROW_HEIGHT: u32 = 10;

var cached_arrow_line_h: u32 = 0;
var cached_arrow_w: u32 = BACK_ARROW_WIDTH;
var cached_arrow_h: u32 = BACK_ARROW_HEIGHT;
var cached_arrow_mask: [48 * 36]u8 = undefined;

fn ensureBackArrowMask() struct { w: u32, h: u32, mask: []const u8 } {
    const line_h = font.getActiveLineHeight();
    if (cached_arrow_line_h != line_h) {
        cached_arrow_line_h = line_h;
        const scale = @as(f32, @floatFromInt(line_h)) /
            @as(f32, @floatFromInt(font.GLYPH_HEIGHT));
        const aw: u32 = std.math.clamp(
            @as(u32, @intFromFloat(@round(14.0 * scale))),
            10,
            48,
        );
        const ah: u32 = std.math.clamp(
            @as(u32, @intFromFloat(@round(10.0 * scale))),
            7,
            36,
        );
        cached_arrow_w = aw;
        cached_arrow_h = ah;
        const path = vector.buildBackArrowPath();
        const total = @as(usize, aw) * @as(usize, ah);
        path.rasterizeToMask(
            @as(f32, @floatFromInt(aw)) / 14.0,
            @as(f32, @floatFromInt(ah)) / 10.0,
            0.0,
            0.0,
            cached_arrow_mask[0..total],
            aw,
            ah,
            .non_zero,
        );
    }
    const total = @as(usize, cached_arrow_w) * @as(usize, cached_arrow_h);
    return .{
        .w = cached_arrow_w,
        .h = cached_arrow_h,
        .mask = cached_arrow_mask[0..total],
    };
}

inline fn drawShadowText(
    s: *fb.Surface,
    txt: []const u8,
    x: i32,
    y: i32,
    col: u32,
) void {
    font.drawText(s, txt, x, y, col);
}

pub fn drawBackArrow(surface: *fb.Surface, x: i32, y: i32, color: u32) void {
    const a = ensureBackArrowMask();
    vector.blendMaskOnSurface(surface, a.mask, a.w, a.h, x, y, color, 255);
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
        fb.Color.INK
    else if (self.custom_color) |c|
        (if (c == fb.Color.WHITE) fb.Color.INK else c)
    else
        fb.Color.INK;

    const line_h: i32 = @intCast(font.getActiveLineHeight());

    switch (self.icon_type) {
        .read_only_text => {
            const txt = self.getText();
            if (self.wrap_text or
                (self.height >= @as(u32, @intCast(line_h * 2)) and
                    font.measureString(txt) > self.width))
            {
                const wm = font.measureWrappedText(txt, self.width);
                const text_y = sy + @max(
                    0,
                    @divTrunc(
                        @as(i32, @intCast(self.height)) -
                            @as(i32, @intCast(wm.height)),
                        2,
                    ),
                );
                _ = font.drawTextWrapped(
                    surface,
                    txt,
                    sx,
                    text_y,
                    self.width,
                    fg_color,
                );
            } else {
                const text_y = sy + @divTrunc(
                    @as(i32, @intCast(self.height)) - line_h,
                    2,
                );
                drawShadowText(surface, txt, sx, text_y, fg_color);
            }
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
        .dropdown => renderDropdown(self, surface, sx, sy, box, fg_color),
        .menu_item => renderMenuItem(self, surface, sx, sy),
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
    else
        fb.Color.INK;

    const line_h: i32 = @intCast(font.getActiveLineHeight());
    const text_y = sy + @divTrunc(
        @as(i32, @intCast(self.height)) - line_h + 2,
        2,
    );
    const pad_x: i32 = 6;

    if (self.has_back_arrow) {
        const a = ensureBackArrowMask();
        const arrow_y = sy + @divTrunc(
            @as(i32, @intCast(self.height)) - @as(i32, @intCast(a.h)),
            2,
        );
        drawBackArrow(
            surface,
            sx + pad_x,
            arrow_y,
            item_color,
        );

        const raw_text = self.getText();
        const display_text = if (std.mem.startsWith(u8, raw_text, "< "))
            raw_text[2..]
        else if (std.mem.startsWith(u8, raw_text, "<"))
            raw_text[1..]
        else
            raw_text;

        const label_x =
            sx + pad_x + @as(i32, @intCast(a.w + 6));
        drawShadowText(surface, display_text, label_x, text_y, item_color);
    } else {
        drawShadowText(surface, self.getText(), sx + pad_x, text_y, item_color);
    }
}

test {
    _ = icon_widgets;
    std.testing.refAllDecls(@This());
}
