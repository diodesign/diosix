// Interactive Icon and Widget System for Diosix GUI
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("framebuffer.zig");
const font = @import("font.zig");
const cursor_mod = @import("cursor.zig");

// Forward declaration of GUI coordinator and Window
pub const DiosixGui = struct {
    pub const opaque_ptr = *anyopaque;
};
pub const Window = struct {
    pub const opaque_ptr = *anyopaque;
};

pub const IconType = enum {
    read_only_text,
    read_write_text,
    slider,
    tick_box,
    button,
};

pub const GroupMode = enum {
    inclusive, // Independent toggling (checkbox behavior)
    exclusive, // Only one can be ticked at a time in this group (radio button behavior)
};

pub const IconCallback = *const fn (gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void;

pub const Icon = struct {
    id: u32,
    icon_type: IconType,
    rel_x: i32,
    rel_y: i32,
    width: u32,
    height: u32,

    // Text label or content buffer
    text_buf: [128]u8 = @splat(0),
    text_len: usize = 0,

    // For read_write_text
    cursor_pos: usize = 0,
    max_input_len: usize = 64,

    // For slider
    slider_min: i32 = 0,
    slider_max: i32 = 100,
    slider_val: i32 = 50,
    slider_step: i32 = 1,
    slider_suffix: [16]u8 = @splat(0),
    slider_suffix_len: usize = 0,

    // For tick_box
    is_ticked: bool = false,

    // Grouping
    group_id: ?u16 = null,
    group_mode: GroupMode = .inclusive,

    // Scriptability & Callback
    callback: ?IconCallback = null,
    user_tag: usize = 0,

    // Interactive states
    is_focused: bool = false,
    is_hovered: bool = false,
    is_enabled: bool = true,
    is_active_press: bool = false,

    pub fn createReadOnly(id: u32, rel_x: i32, rel_y: i32, width: u32, height: u32, text: []const u8) Icon {
        var icon = Icon{
            .id = id,
            .icon_type = .read_only_text,
            .rel_x = rel_x,
            .rel_y = rel_y,
            .width = width,
            .height = height,
        };
        icon.setText(text);
        return icon;
    }

    pub fn createReadWrite(id: u32, rel_x: i32, rel_y: i32, width: u32, height: u32, initial_text: []const u8) Icon {
        var icon = Icon{
            .id = id,
            .icon_type = .read_write_text,
            .rel_x = rel_x,
            .rel_y = rel_y,
            .width = width,
            .height = height,
        };
        icon.setText(initial_text);
        return icon;
    }

    pub fn createSlider(
        id: u32,
        rel_x: i32,
        rel_y: i32,
        width: u32,
        height: u32,
        min: i32,
        max: i32,
        initial: i32,
        suffix: []const u8,
    ) Icon {
        var icon = Icon{
            .id = id,
            .icon_type = .slider,
            .rel_x = rel_x,
            .rel_y = rel_y,
            .width = width,
            .height = height,
            .slider_min = min,
            .slider_max = max,
            .slider_val = initial,
        };
        const s_len = @min(suffix.len, icon.slider_suffix.len);
        @memcpy(icon.slider_suffix[0..s_len], suffix[0..s_len]);
        icon.slider_suffix_len = s_len;
        return icon;
    }

    pub fn createTickBox(
        id: u32,
        rel_x: i32,
        rel_y: i32,
        width: u32,
        height: u32,
        label: []const u8,
        initial_ticked: bool,
        group_id: ?u16,
        group_mode: GroupMode,
    ) Icon {
        var icon = Icon{
            .id = id,
            .icon_type = .tick_box,
            .rel_x = rel_x,
            .rel_y = rel_y,
            .width = width,
            .height = height,
            .is_ticked = initial_ticked,
            .group_id = group_id,
            .group_mode = group_mode,
        };
        icon.setText(label);
        return icon;
    }

    pub fn createButton(id: u32, rel_x: i32, rel_y: i32, width: u32, height: u32, label: []const u8) Icon {
        var icon = Icon{
            .id = id,
            .icon_type = .button,
            .rel_x = rel_x,
            .rel_y = rel_y,
            .width = width,
            .height = height,
        };
        icon.setText(label);
        return icon;
    }

    pub fn setText(self: *Icon, text: []const u8) void {
        const copy_len = @min(text.len, self.text_buf.len);
        @memcpy(self.text_buf[0..copy_len], text[0..copy_len]);
        self.text_len = copy_len;
        self.cursor_pos = copy_len;
    }

    pub fn getText(self: *const Icon) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    pub fn setSliderValue(self: *Icon, val: i32) void {
        self.slider_val = std.math.clamp(val, self.slider_min, self.slider_max);
    }

    pub fn adjustSlider(self: *Icon, delta: i32) void {
        self.setSliderValue(self.slider_val + delta * self.slider_step);
    }

    // Handles character insertion for read-write text box
    pub fn insertChar(self: *Icon, c: u8) void {
        if (self.icon_type != .read_write_text) return;
        if (self.text_len >= self.max_input_len or self.text_len >= self.text_buf.len) return;
        if (c < 32 or c > 126) return;

        // Shift right
        var i = self.text_len;
        while (i > self.cursor_pos) : (i -= 1) {
            self.text_buf[i] = self.text_buf[i - 1];
        }
        self.text_buf[self.cursor_pos] = c;
        self.text_len += 1;
        self.cursor_pos += 1;
    }

    // Handles backspace deletion
    pub fn deleteBackward(self: *Icon) void {
        if (self.icon_type != .read_write_text) return;
        if (self.cursor_pos == 0 or self.text_len == 0) return;

        var i = self.cursor_pos - 1;
        while (i + 1 < self.text_len) : (i += 1) {
            self.text_buf[i] = self.text_buf[i + 1];
        }
        self.text_len -= 1;
        self.cursor_pos -= 1;
    }

    pub fn hitTest(self: *const Icon, win_x: i32, win_y: i32, px: i32, py: i32) bool {
        if (!self.is_enabled) return false;
        const box = fb.Box.fromPosSize(win_x + self.rel_x, win_y + self.rel_y, self.width, self.height);
        return box.contains(px, py);
    }

    // Render this icon onto the framebuffer surface
    pub fn render(self: *Icon, surface: *fb.Surface, win_x: i32, win_y: i32, is_win_active: bool) void {
        const sx = win_x + self.rel_x;
        const sy = win_y + self.rel_y;
        const box = fb.Box.fromPosSize(sx, sy, self.width, self.height);

        // If this icon is focused and window is active, render keyboard focus hand marker
        if (self.is_focused and is_win_active) {
            cursor_mod.Cursor.drawFocusHand(surface, sx - 20, sy + @divTrunc(@as(i32, @intCast(self.height)) - 12, 2));
        }

        const fg_color: u32 = if (!self.is_enabled)
            fb.Color.TEXT_MUTED
        else if (self.is_focused and is_win_active)
            fb.Color.ACCENT_CYAN
        else
            fb.Color.WHITE;

        switch (self.icon_type) {
            .read_only_text => {
                // Read-only text label with drop shadow
                const text_y = sy + @divTrunc(@as(i32, @intCast(self.height)) - @as(i32, @intCast(font.GLYPH_HEIGHT)), 2);
                font.drawTextWithShadow(surface, self.getText(), sx, text_y, fg_color, fb.Color.BLACK);
            },

            .read_write_text => {
                // Inset editable field box
                const border_col = if (self.is_focused) fb.Color.ACCENT_CYAN else fb.Color.GLASS_BORDER;
                surface.drawRoundedTranslucentBox(box, 4, fb.Color.INPUT_BG, 230, border_col);

                const text_y = sy + @divTrunc(@as(i32, @intCast(self.height)) - @as(i32, @intCast(font.GLYPH_HEIGHT)), 2);
                const txt = self.getText();
                font.drawTextWithShadow(surface, txt, sx + 8, text_y, fg_color, fb.Color.BLACK);

                // Draw blinking or static insertion cursor if focused
                if (self.is_focused and is_win_active) {
                    const before_cursor = txt[0..self.cursor_pos];
                    const cur_offset = font.measureString(before_cursor);
                    const cur_x = sx + 8 + @as(i32, @intCast(cur_offset));
                    const cur_box = fb.Box.fromPosSize(cur_x, text_y + 1, 2, font.GLYPH_HEIGHT);
                    surface.fillBox(cur_box, fb.Color.ACCENT_CYAN);
                }
            },

            .slider => {
                // 1. Label and Value string
                var val_buf: [32]u8 = undefined;
                const val_str = if (self.slider_suffix_len > 0)
                    std.fmt.bufPrint(&val_buf, "{d}{s}", .{ self.slider_val, self.slider_suffix[0..self.slider_suffix_len] }) catch ""
                else
                    std.fmt.bufPrint(&val_buf, "{d}", .{self.slider_val}) catch "";

                const text_y = sy + 2;
                font.drawTextWithShadow(surface, self.getText(), sx, text_y, fg_color, fb.Color.BLACK);

                const val_w = font.measureString(val_str);
                const val_x = sx + @as(i32, @intCast(self.width)) - @as(i32, @intCast(val_w));
                font.drawTextWithShadow(surface, val_str, val_x, text_y, fb.Color.ACCENT_GOLD, fb.Color.BLACK);

                // 2. Slider Track Groove
                const track_y = sy + 24;
                const track_h: u32 = 6;
                const track_box = fb.Box.fromPosSize(sx, track_y, self.width, track_h);
                surface.drawRoundedTranslucentBox(track_box, 3, fb.Color.TRACK_BG, 240, fb.Color.GLASS_BORDER);

                // 3. Slider Thumb Marker
                const span = if (self.slider_max > self.slider_min) self.slider_max - self.slider_min else 1;
                const progress: i32 = std.math.clamp(self.slider_val - self.slider_min, 0, span);
                const track_w = if (self.width > 16) self.width - 16 else 1;
                const thumb_offset = @divTrunc(progress * @as(i32, @intCast(track_w)), span);
                const thumb_x = sx + thumb_offset;
                const thumb_y = track_y - 4;
                const thumb_box = fb.Box.fromPosSize(thumb_x, thumb_y, 16, 14);

                surface.drawRoundedTranslucentBox(thumb_box, 4, if (self.is_focused) fb.Color.ACCENT_CYAN else fb.Color.THUMB_BG, 255, fb.Color.WHITE);
            },

            .tick_box => {
                // 1. Sleek 16x16 Tick Box
                const box_size: u32 = 16;
                const box_y = sy + @divTrunc(@as(i32, @intCast(self.height)) - @as(i32, @intCast(box_size)), 2);
                const tick_box = fb.Box.fromPosSize(sx, box_y, box_size, box_size);

                surface.drawRoundedTranslucentBox(tick_box, 3, fb.Color.INPUT_BG, 230, if (self.is_focused) fb.Color.ACCENT_CYAN else fb.Color.GLASS_BORDER);

                // If ticked, draw glowing check mark
                if (self.is_ticked) {
                    const inner_tick = fb.Box.fromPosSize(sx + 3, box_y + 3, box_size - 6, box_size - 6);
                    surface.drawRoundedTranslucentBox(inner_tick, 2, fb.Color.ACCENT_CYAN, 255, null);
                    // Core highlight
                    const core_tick = fb.Box.fromPosSize(sx + 5, box_y + 5, box_size - 10, box_size - 10);
                    surface.fillBox(core_tick, fb.Color.WHITE);
                }

                // 2. Adjacent Label Text
                const text_x = sx + @as(i32, @intCast(box_size)) + 10;
                const text_y = sy + @divTrunc(@as(i32, @intCast(self.height)) - @as(i32, @intCast(font.GLYPH_HEIGHT)), 2);
                font.drawTextWithShadow(surface, self.getText(), text_x, text_y, fg_color, fb.Color.BLACK);
            },

            .button => {
                // Sleek pushable button
                const btn_bg: u32 = if (self.is_active_press)
                    fb.Color.BTN_PRESS_BG
                else if (self.is_hovered or (self.is_focused and is_win_active))
                    fb.Color.BTN_HOVER_BG
                else
                    fb.Color.BTN_NORMAL_BG;

                const border_col: u32 = if (self.is_focused and is_win_active) fb.Color.ACCENT_CYAN else fb.Color.GLASS_BTN_BORDER;
                surface.drawRoundedTranslucentBox(box, 6, btn_bg, 220, border_col);

                const txt = self.getText();
                const text_w = font.measureString(txt);
                const text_x = sx + @divTrunc(@as(i32, @intCast(self.width)) - @as(i32, @intCast(text_w)), 2);
                const text_y = sy + @divTrunc(@as(i32, @intCast(self.height)) - @as(i32, @intCast(font.GLYPH_HEIGHT)), 2);
                font.drawTextWithShadow(surface, txt, text_x, text_y, fg_color, fb.Color.BLACK);
            },
        }
    }
};
