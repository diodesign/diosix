// Scalable Vector Control Widget Renderers (TextField, Slider, TickBox,
// Button, Dropdown, ProgressBar) for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("../framebuffer.zig");
const font = @import("../font.zig");
const vector = @import("../vector.zig");
const icon_mod = @import("../icon.zig");
const text_label = @import("../label.zig");
const Icon = icon_mod.Icon;
const boxOf = fb.Box.fromPosSize;

inline fn drawShadowText(
    s: *fb.Surface,
    txt: []const u8,
    x: i32,
    y: i32,
    col: u32,
) void {
    font.drawText(s, txt, x, y, col);
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
    const border_col = fb.Color.GLASS_BORDER;
    surface.drawGlassPane(
        box,
        4,
        fb.Color.INPUT_BG,
        230,
        border_col,
        false,
        false,
    );

    const line_h = font.getActiveLineHeight();
    const text_y = sy + @divTrunc(
        @as(i32, @intCast(self.height)) - @as(i32, @intCast(line_h)),
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
            const sel_box = boxOf(sel_x, text_y, sel_w, line_h);
            surface.drawRoundedTranslucentBox(
                sel_box,
                2,
                fb.Color.BTN_PRESS_BG,
                200,
                null,
            );
        }
    }

    drawShadowText(surface, txt, text_start_x, text_y, fg_color);

    if (self.is_focused and is_win_active) {
        const cur_x = text_start_x + @as(i32, @intCast(cur_offset));
        const cur_box = boxOf(cur_x, text_y + 1, 2, line_h);
        surface.fillBox(cur_box, fb.Color.INK);
    }
}

pub const renderReadWriteText = renderTextField;

pub fn sliderThumbWidth(line_h: u32) u32 {
    return @max(12, (line_h * 16 + 9) / 18);
}

pub fn sliderBarWidth(self: *const Icon, line_h: u32) u32 {
    var max_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
    const max_str = if (self.slider_suffix_len > 0)
        text_label.fmtLabel(
            &max_buf,
            "{d}{s}",
            .{ self.slider_max, self.slider_suffix[0..self.slider_suffix_len] },
        )
    else
        text_label.fmtLabel(&max_buf, "{d}", .{self.slider_max});
    const max_val_w = font.measureString(max_str);
    const gap: u32 = @max(8, (line_h * 10 + 9) / 18);
    const reserve = max_val_w + gap;
    return if (self.width > reserve + 32) self.width - reserve else self.width;
}

pub fn renderSlider(
    self: *const Icon,
    surface: *fb.Surface,
    sx: i32,
    sy: i32,
    fg_color: u32,
) void {
    _ = fg_color;
    var val_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
    const val_str = if (self.slider_suffix_len > 0)
        text_label.fmtLabel(
            &val_buf,
            "{d}{s}",
            .{ self.slider_val, self.slider_suffix[0..self.slider_suffix_len] },
        )
    else
        text_label.fmtLabel(&val_buf, "{d}", .{self.slider_val});

    const line_h = font.getActiveLineHeight();
    const val_w = font.measureString(val_str);
    const val_x = sx + @as(i32, @intCast(self.width)) -
        @as(i32, @intCast(val_w));
    const text_y = sy + @divTrunc(
        @as(i32, @intCast(self.height)) - @as(i32, @intCast(line_h)),
        2,
    );
    drawShadowText(surface, val_str, val_x, text_y, fb.Color.INK_SECONDARY);

    const bar_w = sliderBarWidth(self, line_h);
    const track_h: u32 = @max(4, (line_h * 6 + 9) / 18);
    const thumb_w: u32 = sliderThumbWidth(line_h);
    const thumb_h: u32 = @max(10, (line_h * 14 + 9) / 18);
    const track_y = sy + @divTrunc(
        @as(i32, @intCast(self.height)) - @as(i32, @intCast(track_h)),
        2,
    );
    const thumb_y = sy + @divTrunc(
        @as(i32, @intCast(self.height)) - @as(i32, @intCast(thumb_h)),
        2,
    );
    const track_box = boxOf(sx, track_y, bar_w, track_h);
    surface.drawRoundedTranslucentBox(
        track_box,
        @intCast(track_h / 2),
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
    const track_w = if (bar_w > thumb_w) bar_w - thumb_w else 1;
    const thumb_offset = @divTrunc(
        progress * @as(i32, @intCast(track_w)),
        span,
    );
    const thumb_box = boxOf(
        sx + thumb_offset,
        thumb_y,
        thumb_w,
        thumb_h,
    );
    surface.drawRoundedTranslucentBox(
        thumb_box,
        @intCast(@max(3, thumb_h / 3)),
        fb.Color.THUMB_BG,
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
    const line_h = font.getActiveLineHeight();
    const box_size: u32 = @max(12, (line_h * 16 + 9) / 18);
    const box_y = sy + @divTrunc(
        @as(i32, @intCast(self.height)) - @as(i32, @intCast(box_size)),
        2,
    );
    const tick_box = boxOf(sx, box_y, box_size, box_size);

    const radius: u32 = if (is_radio) box_size / 2 else @max(2, box_size / 5);
    const border_col: u32 = fb.Color.GLASS_BORDER;

    surface.drawRoundedTranslucentBox(
        tick_box,
        radius,
        fb.Color.INPUT_BG,
        230,
        border_col,
    );

    if (self.is_ticked) {
        const inset: u32 = @max(3, box_size / 4);
        const dot_sz: u32 = box_size -| (inset * 2);
        const ins_i: i32 = @intCast(inset);
        if (is_radio) {
            surface.drawRoundedTranslucentBox(
                boxOf(sx + ins_i, box_y + ins_i, dot_sz, dot_sz),
                dot_sz / 2,
                fb.Color.INK,
                255,
                null,
            );
        } else {
            surface.drawRoundedTranslucentBox(
                boxOf(sx + ins_i, box_y + ins_i, dot_sz, dot_sz),
                2,
                fb.Color.INK,
                255,
                null,
            );
        }
    }

    const gap: i32 = @intCast(@max(8, (line_h * 10 + 9) / 18));
    const text_x = sx + @as(i32, @intCast(box_size)) + gap;
    const text_y = sy + @divTrunc(
        @as(i32, @intCast(self.height)) - @as(i32, @intCast(line_h)),
        2,
    );
    const reserve: u32 = box_size + @as(u32, @intCast(gap + 2));
    const label_w: u32 = if (self.width > reserve)
        self.width - reserve
    else
        0;
    const label_clip = surface.pushClip(
        boxOf(text_x, sy, label_w, self.height),
    );
    drawShadowText(surface, self.getText(), text_x, text_y, fg_color);
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

    surface.drawGlassPane(
        box,
        6,
        btn_bg,
        220,
        fb.Color.GLASS_BTN_BORDER,
        false,
        false,
    );

    const line_h = font.getActiveLineHeight();
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
        @as(i32, @intCast(self.height)) - @as(i32, @intCast(line_h)),
        2,
    );

    const inner_w: u32 = if (self.width > 24) self.width - 24 else 0;
    const btn_text_clip = surface.pushClip(
        boxOf(sx + pad_x, sy, inner_w, self.height),
    );
    drawShadowText(surface, txt, text_x, text_y, fg_color);
    surface.popClip(btn_text_clip);
}

pub fn renderDropdown(
    self: *const Icon,
    surface: *fb.Surface,
    sx: i32,
    sy: i32,
    box: fb.Box,
    fg_color: u32,
) void {
    const bg_col: u32 = if (self.is_active_press or self.is_selected)
        fb.Color.BTN_PRESS_BG
    else if (self.is_hovered)
        fb.Color.BTN_HOVER_BG
    else
        fb.Color.INPUT_BG;

    surface.drawGlassPane(
        box,
        6,
        bg_col,
        235,
        fb.Color.GLASS_BORDER,
        false,
        false,
    );

    const line_h = font.getActiveLineHeight();
    const cw: u32 = std.math.clamp((line_h * 10 + 9) / 18, 10, 28);
    const ch: u32 = std.math.clamp((line_h * 6 + 9) / 18, 6, 18);
    const pad_x: i32 = @intCast(@max(10, (line_h * 12) / 18));
    const right_reserve: u32 = cw + @as(u32, @intCast(pad_x * 2));
    const text_y = sy + @divTrunc(
        @as(i32, @intCast(self.height)) - @as(i32, @intCast(line_h)),
        2,
    );
    const inner_w: u32 = if (self.width > right_reserve)
        self.width - right_reserve
    else
        0;
    const text_clip = surface.pushClip(
        boxOf(sx + pad_x, sy, inner_w, self.height),
    );
    drawShadowText(surface, self.getText(), sx + pad_x, text_y, fg_color);
    surface.popClip(text_clip);

    // Rasterize antialiased scalable vector chevron indicator at UI scale.
    var chevron_mask: [28 * 18]u8 = undefined;
    const path = vector.buildChevronPath(self.is_selected);
    const sx_f = @as(f32, @floatFromInt(cw)) / 10.0;
    const sy_f = @as(f32, @floatFromInt(ch)) / 6.0;
    const total_px = @as(usize, cw) * @as(usize, ch);
    path.rasterizeToMask(
        sx_f,
        sy_f,
        0.0,
        0.0,
        chevron_mask[0..total_px],
        cw,
        ch,
        .non_zero,
    );
    const cx = sx + @as(i32, @intCast(self.width)) -
        @as(i32, @intCast(cw)) - pad_x;
    const cy = sy + @divTrunc(
        @as(i32, @intCast(self.height)) - @as(i32, @intCast(ch)),
        2,
    );
    vector.blendMaskOnSurface(
        surface,
        chevron_mask[0..total_px],
        cw,
        ch,
        cx,
        cy,
        fg_color,
        255,
    );
}

pub fn renderProgressBar(
    self: *const Icon,
    surface: *fb.Surface,
    sx: i32,
    sy: i32,
    fg_color: u32,
) void {
    const line_h = font.getActiveLineHeight();
    const pct: u8 = @intCast(std.math.clamp(self.slider_val, 0, 100));
    var pct_buf: [16]u8 = undefined;
    const pct_str = std.fmt.bufPrint(&pct_buf, "{d}%", .{pct}) catch "0%";
    const max_pct_w = font.measureString("100%");
    const gap: u32 = @max(6, (line_h * 6) / 18);
    const label_reserve: u32 = max_pct_w + gap;

    const bar_w: u32 = if (self.width > label_reserve + 16)
        self.width - label_reserve
    else
        @max(12, self.width);
    const bar_h: u32 = @max(8, (line_h * 10 + 9) / 18);
    const bar_y = sy + @divTrunc(
        @as(i32, @intCast(self.height)) - @as(i32, @intCast(bar_h)),
        2,
    );
    const radius: u32 = @max(3, bar_h / 2);

    surface.drawRoundedTranslucentBox(
        boxOf(sx, bar_y, bar_w, bar_h),
        radius,
        fb.Color.TRACK_BG,
        240,
        fb.Color.GLASS_BORDER,
    );

    if (pct > 0) {
        const fill_w: u32 = @max(
            radius * 2,
            (bar_w * @as(u32, pct)) / 100,
        );
        const clamped_fill: u32 = @min(bar_w, fill_w);
        surface.drawRoundedTranslucentBox(
            boxOf(sx, bar_y, clamped_fill, bar_h),
            radius,
            fb.Color.THUMB_BG,
            255,
            null,
        );
    }

    if (self.width > label_reserve + 16) {
        const text_x = sx + @as(i32, @intCast(bar_w + gap));
        const text_y = sy + @divTrunc(
            @as(i32, @intCast(self.height)) - @as(i32, @intCast(line_h)),
            2,
        );
        drawShadowText(surface, pct_str, text_x, text_y, fg_color);
    }
}

test {
    std.testing.refAllDecls(@This());
}
