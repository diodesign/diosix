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
pub const renderProgressBar = icon_widgets.renderProgressBar;

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
        .line_graph => renderLineGraph(self, surface, sx, sy, fg_color),
        .progress_bar => renderProgressBar(self, surface, sx, sy, fg_color),
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
    } else if (std.mem.indexOfScalar(u8, self.getText(), '\n')) |nl_idx| {
        if (self.is_selected or self.is_hovered) {
            const box = boxOf(sx, sy, self.width, self.height);
            const alpha: u8 = if (self.is_selected) 85 else 45;
            surface.drawGlassPane(
                box,
                6,
                fb.Color.WHITE,
                alpha,
                null,
                false,
                false,
            );
        }
        const raw = self.getText();
        const line1 = raw[0..nl_idx];
        const line2 = raw[nl_idx + 1 ..];
        const gap: i32 = 2;
        const total_h = line_h * 2 + gap;
        const top_y = sy + @max(
            0,
            @divTrunc(@as(i32, @intCast(self.height)) - total_h, 2),
        );
        drawShadowText(surface, line1, sx + pad_x, top_y, item_color);
        const sub_color: u32 = if (!self.is_enabled)
            fb.Color.TEXT_MUTED
        else
            fb.Color.INK_SECONDARY;
        drawShadowText(
            surface,
            line2,
            sx + pad_x,
            top_y + line_h + gap,
            sub_color,
        );
    } else {
        drawShadowText(surface, self.getText(), sx + pad_x, text_y, item_color);
    }
}

fn distToSegment(
    px: f32,
    py: f32,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
) f32 {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len_sq = dx * dx + dy * dy;
    if (len_sq <= 0.0001) {
        return @sqrt((px - x0) * (px - x0) + (py - y0) * (py - y0));
    }
    const t = std.math.clamp(
        ((px - x0) * dx + (py - y0) * dy) / len_sq,
        0.0,
        1.0,
    );
    const vx = px - (x0 + t * dx);
    const vy = py - (y0 + t * dy);
    return @sqrt(vx * vx + vy * vy);
}

pub fn renderLineGraph(
    self: *const Icon,
    surface: *fb.Surface,
    sx: i32,
    sy: i32,
    fg_color: u32,
) void {
    const line_h = font.getActiveLineHeight();
    const axis_w: u32 = @max(1, line_h / 18);
    const chart_w: u32 = axis_w * 2;
    const axis_i: i32 = @intCast(axis_w);
    const tick_w: u32 = axis_w * 3;
    const tick_gap: i32 = @intCast(axis_w * 2);

    const w_100 = font.measureString("100%");
    const w_0 = font.measureString("0%");
    const lbl_col_w: i32 = @intCast(@max(w_100, w_0));

    const top_pad: i32 = @intCast(@max(2, line_h / 6));
    const bot_pad: i32 = @intCast(@max(4, line_h / 4));
    const right_pad: i32 = @intCast(@max(4, line_h / 4));
    const axis_x: i32 = sx + lbl_col_w + tick_gap + @as(i32, @intCast(tick_w));
    const plot_right: i32 = sx + @as(i32, @intCast(self.width)) - right_pad;
    const plot_top: i32 = sy + top_pad;
    const plot_bot: i32 = sy + @as(i32, @intCast(self.height)) - bot_pad;
    if (plot_right <= axis_x + axis_i or plot_bot <= plot_top + axis_i) return;

    drawShadowText(
        surface,
        "100%",
        sx + lbl_col_w - @as(i32, @intCast(w_100)),
        sy,
        fg_color,
    );
    const y_0 = @max(
        sy + @as(i32, @intCast(line_h)),
        plot_bot - @as(i32, @intCast(line_h)) + top_pad,
    );
    drawShadowText(
        surface,
        "0%",
        sx + lbl_col_w - @as(i32, @intCast(w_0)),
        y_0,
        fg_color,
    );

    const plot_h: i32 = plot_bot - plot_top;
    const plot_w: i32 = plot_right - axis_x;
    surface.fillBox(
        boxOf(axis_x, plot_top, axis_w, @intCast(plot_h + axis_i)),
        fg_color,
    );
    surface.fillBox(
        boxOf(axis_x, plot_bot, @intCast(plot_w), axis_w),
        fg_color,
    );
    const tick_x: i32 = axis_x - @as(i32, @intCast(tick_w));
    surface.fillBox(boxOf(tick_x, plot_top, tick_w, axis_w), fg_color);
    surface.fillBox(
        boxOf(tick_x, plot_top + @divTrunc(plot_h, 2), tick_w, axis_w),
        fg_color,
    );
    surface.fillBox(boxOf(tick_x, plot_bot, tick_w, axis_w), fg_color);

    const samples = self.getGraphSamples();
    if (samples.len == 0) return;

    const x_left: f32 = @floatFromInt(axis_x + axis_i);
    const x_span: f32 = @floatFromInt(
        @max(1, plot_right - (axis_x + axis_i) - 1),
    );
    const y_top_f: f32 = @floatFromInt(plot_top);
    const y_bot_f: f32 = @floatFromInt(plot_bot);
    const y_span: f32 = @max(1.0, y_bot_f - y_top_f);
    const max_slot_f: f32 = @floatFromInt(icon_mod.GRAPH_HISTORY_CAP - 1);

    var pts_x: [icon_mod.GRAPH_HISTORY_CAP]f32 = undefined;
    var pts_y: [icon_mod.GRAPH_HISTORY_CAP]f32 = undefined;
    var pt_count: usize = samples.len;

    if (samples.len == 1) {
        const v: f32 = @floatFromInt(@min(@as(u8, 100), samples[0]));
        const y_val = @round(y_bot_f - (v / 100.0) * y_span);
        pts_x[0] = x_left + ((max_slot_f - 1.0) / max_slot_f) * x_span;
        pts_y[0] = y_val;
        pts_x[1] = x_left + x_span;
        pts_y[1] = y_val;
        pt_count = 2;
    } else {
        const start_slot = icon_mod.GRAPH_HISTORY_CAP - samples.len;
        for (samples, 0..) |raw_v, i| {
            const slot_f: f32 = @floatFromInt(start_slot + i);
            const v: f32 = @floatFromInt(@min(@as(u8, 100), raw_v));
            pts_x[i] = x_left + (slot_f / max_slot_f) * x_span;
            pts_y[i] = @round(y_bot_f - (v / 100.0) * y_span);
        }
    }

    const half_w: f32 = @as(f32, @floatFromInt(chart_w)) * 0.5;
    const aa_rad: f32 = half_w + 0.75;
    const pad_px: i32 = @intCast(chart_w + 1);
    const raw_min_x: i32 = @intFromFloat(@floor(pts_x[0] - aa_rad));
    const raw_max_x: i32 = @intFromFloat(@ceil(pts_x[pt_count - 1] + aa_rad));
    const min_px: i32 = @max(axis_x + axis_i, raw_min_x);
    const max_px: i32 = @min(plot_right, raw_max_x);

    var px: i32 = min_px;
    while (px <= max_px) : (px += 1) {
        const px_f: f32 = @as(f32, @floatFromInt(px)) + 0.5;
        var y_lo: f32 = y_bot_f;
        var y_hi: f32 = y_top_f;
        var has_seg = false;
        for (0..pt_count - 1) |k| {
            if (px_f >= pts_x[k] - aa_rad and px_f <= pts_x[k + 1] + aa_rad) {
                y_lo = @min(y_lo, @min(pts_y[k], pts_y[k + 1]) - aa_rad);
                y_hi = @max(y_hi, @max(pts_y[k], pts_y[k + 1]) + aa_rad);
                has_seg = true;
            }
        }
        if (!has_seg) continue;

        const raw_y0: i32 = @intFromFloat(@floor(y_lo));
        const raw_y1: i32 = @intFromFloat(@ceil(y_hi));
        const py_start: i32 = @max(plot_top - pad_px, raw_y0);
        const py_end: i32 = @min(plot_bot + pad_px, raw_y1);
        var py: i32 = py_start;
        while (py <= py_end) : (py += 1) {
            const py_f: f32 = @as(f32, @floatFromInt(py)) + 0.5;
            var min_d: f32 = 1000.0;
            for (0..pt_count - 1) |k| {
                if (px_f >= pts_x[k] - aa_rad and
                    px_f <= pts_x[k + 1] + aa_rad)
                {
                    const d = distToSegment(
                        px_f,
                        py_f,
                        pts_x[k],
                        pts_y[k],
                        pts_x[k + 1],
                        pts_y[k + 1],
                    );
                    if (d < min_d) min_d = d;
                }
            }
            if (min_d <= half_w - 0.5) {
                surface.setPixel(px, py, fg_color);
            } else if (min_d < half_w + 0.5) {
                const cov = std.math.clamp(
                    (half_w + 0.5 - min_d) * 255.0,
                    0.0,
                    255.0,
                );
                const alpha: u8 = @intFromFloat(@round(cov));
                if (alpha > 0) {
                    const bg = surface.getPixel(px, py);
                    surface.setPixel(
                        px,
                        py,
                        fb.blendPixel(bg, fg_color, alpha),
                    );
                }
            }
        }
    }
}

test {
    _ = icon_widgets;
    std.testing.refAllDecls(@This());
}
