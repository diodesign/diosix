// Widget & Icon Rendering Engine for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("../framebuffer.zig");
const font = @import("../font.zig");
const icon_mod = @import("../icon.zig");
const Icon = icon_mod.Icon;
const icon_viewport = @import("viewport.zig");
const boxOf = fb.Box.fromPosSize;

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
        .read_write_text => renderReadWriteText(
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

fn renderReadWriteText(
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

fn renderSlider(
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

fn renderTickBox(
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

fn renderButton(
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

fn renderProgressBar(
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

fn renderMenuItem(
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
