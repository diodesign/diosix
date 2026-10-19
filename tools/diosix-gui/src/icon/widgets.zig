// Control Widget Renderers (TextField, Slider, TickBox, Button, ProgressBar)
// for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("../framebuffer.zig");
const font = @import("../font.zig");
const icon_mod = @import("../icon.zig");
const Icon = icon_mod.Icon;
const boxOf = fb.Box.fromPosSize;

inline fn drawShadowText(
    s: *fb.Surface,
    txt: []const u8,
    x: i32,
    y: i32,
    col: u32,
) void {
    font.drawTextWithShadow(s, txt, x, y, col, fb.Color.BLACK);
}

pub fn renderTextField(
    self: *const Icon,
    surface: *fb.Surface,
    sx: i32,
    sy: i32,
    box: fb.Box,
    fg_color: u32,
    is_win_active: bool,
) void {
    const border_col = if (self.is_focused)
        fb.Color.ACCENT_CYAN
    else
        fb.Color.GLASS_BORDER;
    surface.drawGlassPane(
        box,
        4,
        fb.Color.INPUT_BG,
        230,
        border_col,
        false,
        false,
    );

    const text_y = sy + @divTrunc(
        @as(i32, @intCast(self.height)) -
            @as(i32, @intCast(font.GLYPH_HEIGHT)),
        2,
    );
    const txt = self.getText();

    const pad_x: i32 = 8;
    const inner_w: u32 = if (self.width > 16) self.width - 16 else 0;
    const inner_h: u32 = if (self.height > 4) self.height - 4 else 0;
    const inner_clip = surface.pushClip(
        boxOf(sx + pad_x, sy + 2, inner_w, inner_h),
    );
    defer surface.popClip(inner_clip);

    const safe_cur = @min(self.cursor_pos, txt.len);
    const cur_offset = font.measureString(txt[0..safe_cur]);
    const scroll_x: i32 = if (inner_w > 8 and cur_offset + 8 > inner_w)
        @intCast(cur_offset + 8 - inner_w)
    else
        0;
    const text_start_x = sx + pad_x - scroll_x;

    if (self.getSelectionBounds()) |b| {
        const sel_x = text_start_x +
            @as(i32, @intCast(font.measureString(txt[0..b.min])));
        const sel_w = font.measureString(txt[b.min..b.max]);
        if (sel_w > 0) {
            const sel_box = boxOf(sel_x, text_y, sel_w, font.GLYPH_HEIGHT);
            surface.drawRoundedTranslucentBox(
                sel_box,
                2,
                fb.Color.ACCENT_CYAN,
                140,
                null,
            );
        }
    }

    drawShadowText(surface, txt, text_start_x, text_y, fg_color);

    if (self.is_focused and is_win_active) {
        const cur_x = text_start_x + @as(i32, @intCast(cur_offset));
        const cur_box = boxOf(cur_x, text_y + 1, 2, font.GLYPH_HEIGHT);
        surface.fillBox(cur_box, fb.Color.ACCENT_CYAN);
    }
}

pub const renderReadWriteText = renderTextField;

pub fn renderSlider(
    self: *const Icon,
    surface: *fb.Surface,
    sx: i32,
    sy: i32,
    fg_color: u32,
) void {
    var val_buf: [32]u8 = undefined;
    const val_str = if (self.slider_suffix_len > 0)
        std.fmt.bufPrint(
            &val_buf,
            "{d}{s}",
            .{ self.slider_val, self.slider_suffix[0..self.slider_suffix_len] },
        ) catch ""
    else
        std.fmt.bufPrint(&val_buf, "{d}", .{self.slider_val}) catch "";

    const val_w = font.measureString(val_str);
    const val_x = sx + @as(i32, @intCast(self.width)) -
        @as(i32, @intCast(val_w));

    const label_w: u32 = if (val_x > sx + 8) @intCast(val_x - sx - 8) else 0;
    const label_clip = surface.pushClip(
        boxOf(sx, sy, label_w, font.GLYPH_HEIGHT + 4),
    );
    drawShadowText(surface, self.getText(), sx, sy, fg_color);
    surface.popClip(label_clip);

    drawShadowText(surface, val_str, val_x, sy, fb.Color.ACCENT_GOLD);

    const track_y = sy + 24;
    const track_box = boxOf(sx, track_y, self.width, 6);
    surface.drawRoundedTranslucentBox(
        track_box,
        3,
        fb.Color.TRACK_BG,
        240,
        fb.Color.GLASS_BORDER,
    );

    const span = if (self.slider_max > self.slider_min)
        self.slider_max - self.slider_min
    else
        1;
    const progress: i32 = std.math.clamp(
        self.slider_val - self.slider_min,
        0,
        span,
    );
    const track_w = if (self.width > 16) self.width - 16 else 1;
    const thumb_offset = @divTrunc(
        progress * @as(i32, @intCast(track_w)),
        span,
    );
    const thumb_box = boxOf(sx + thumb_offset, track_y - 4, 16, 14);
    const thumb_col = if (self.is_focused)
        fb.Color.ACCENT_CYAN
    else
        fb.Color.THUMB_BG;
    surface.drawRoundedTranslucentBox(
        thumb_box,
        4,
        thumb_col,
        255,
        fb.Color.WHITE,
    );
}

pub fn renderTickBox(
    self: *const Icon,
    surface: *fb.Surface,
    sx: i32,
    sy: i32,
    fg_color: u32,
) void {
    const is_radio = (self.group_mode == .exclusive);
    const box_size: u32 = 16;
    const box_y = sy + @divTrunc(
        @as(i32, @intCast(self.height)) - @as(i32, @intCast(box_size)),
        2,
    );
    const tick_box = boxOf(sx, box_y, box_size, box_size);

    const radius: u32 = if (is_radio) 8 else 3;
    const border_col: u32 = if (self.is_focused or self.is_hovered or
        (is_radio and self.is_ticked))
        fb.Color.ACCENT_CYAN
    else
        fb.Color.GLASS_BORDER;

    surface.drawRoundedTranslucentBox(
        tick_box,
        radius,
        fb.Color.INPUT_BG,
        230,
        border_col,
    );

    if (self.is_ticked) {
        if (is_radio) {
            surface.drawRoundedTranslucentBox(
                boxOf(sx + 4, box_y + 4, 8, 8),
                4,
                fb.Color.ACCENT_CYAN,
                255,
                null,
            );
            surface.drawRoundedTranslucentBox(
                boxOf(sx + 6, box_y + 6, 4, 4),
                2,
                fb.Color.WHITE,
                255,
                null,
            );
        } else {
            surface.drawRoundedTranslucentBox(
                boxOf(sx + 3, box_y + 3, 10, 10),
                2,
                fb.Color.ACCENT_CYAN,
                255,
                null,
            );
            surface.fillBox(boxOf(sx + 5, box_y + 5, 6, 6), fb.Color.WHITE);
        }
    }

    const text_x = sx + @as(i32, @intCast(box_size)) + 10;
    const text_y = sy + @divTrunc(
        @as(i32, @intCast(self.height)) -
            @as(i32, @intCast(font.GLYPH_HEIGHT)),
        2,
    );
    const label_w: u32 = if (self.width > box_size + 12)
        self.width - (box_size + 12)
    else
        0;
    const label_clip = surface.pushClip(
        boxOf(text_x, sy, label_w, self.height),
    );
    const text_col = if (self.is_ticked and is_radio)
        fb.Color.ACCENT_CYAN
    else
        fg_color;
    drawShadowText(surface, self.getText(), text_x, text_y, text_col);
    surface.popClip(label_clip);
}

pub fn renderButton(
    self: *const Icon,
    surface: *fb.Surface,
    sx: i32,
    sy: i32,
    box: fb.Box,
    fg_color: u32,
) void {
    const btn_bg: u32 = if (self.is_active_press)
        fb.Color.BTN_PRESS_BG
    else if (self.is_hovered)
        fb.Color.BTN_HOVER_BG
    else
        fb.Color.BTN_NORMAL_BG;

    const border_col: u32 = if (self.is_hovered)
        fb.Color.ACCENT_CYAN
    else
        fb.Color.GLASS_BTN_BORDER;
    surface.drawGlassPane(box, 6, btn_bg, 220, border_col, false, false);

    const txt = self.getText();
    const text_w = font.measureString(txt);
    const pad_x: i32 = 12;
    const text_x = if (text_w + 24 >= self.width)
        sx + pad_x
    else
        sx + @divTrunc(
            @as(i32, @intCast(self.width)) - @as(i32, @intCast(text_w)),
            2,
        );
    const text_y = sy + @divTrunc(
        @as(i32, @intCast(self.height)) -
            @as(i32, @intCast(font.GLYPH_HEIGHT)),
        2,
    );

    const inner_w: u32 = if (self.width > 24) self.width - 24 else 0;
    const btn_text_clip = surface.pushClip(
        boxOf(sx + pad_x, sy, inner_w, self.height),
    );
    drawShadowText(surface, txt, text_x, text_y, fg_color);
    surface.popClip(btn_text_clip);
}

pub fn renderProgressBar(
    self: *const Icon,
    surface: *fb.Surface,
    sx: i32,
    sy: i32,
    fg_color: u32,
) void {
    const text_y = sy + 2;
    var pct_buf: [32]u8 = undefined;
    const pct_str = std.fmt.bufPrint(
        &pct_buf,
        "{d}%",
        .{self.progress_val},
    ) catch "";
    const pct_w = font.measureString(pct_str);
    const pct_x = sx + @as(i32, @intCast(self.width)) -
        @as(i32, @intCast(pct_w));

    const label_w: u32 = if (pct_x > sx + 8) @intCast(pct_x - sx - 8) else 0;
    const label_clip = surface.pushClip(
        boxOf(sx, sy, label_w, font.GLYPH_HEIGHT + 4),
    );
    drawShadowText(surface, self.getText(), sx, text_y, fg_color);
    surface.popClip(label_clip);

    drawShadowText(surface, pct_str, pct_x, text_y, fb.Color.ACCENT_GOLD);

    const track_y = sy + 22;
    surface.drawRoundedTranslucentBox(
        boxOf(sx, track_y, self.width, 8),
        3,
        fb.Color.TRACK_BG,
        240,
        fb.Color.GLASS_BORDER,
    );

    const clamped_pct = std.math.clamp(self.progress_val, 0, 100);
    if (clamped_pct > 0) {
        const bar_w = @divTrunc(
            @as(i32, @intCast(self.width)) * @as(i32, @intCast(clamped_pct)),
            100,
        );
        if (bar_w > 0) {
            const bar_box = boxOf(
                sx + 1,
                track_y + 1,
                @intCast(@max(1, bar_w - 2)),
                6,
            );
            surface.drawRoundedTranslucentBox(
                bar_box,
                2,
                self.progress_color,
                255,
                null,
            );
        }
    }
}

pub const renderScrollbar = renderProgressBar;

test {
    std.testing.refAllDecls(@This());
}
