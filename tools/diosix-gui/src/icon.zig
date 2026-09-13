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
    progress_bar,
    video_viewport,
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
    selection_start: ?usize = null,
    selection_end: ?usize = null,
    is_dragging_select: bool = false,

    // For slider
    slider_min: i32 = 0,
    slider_max: i32 = 100,
    slider_val: i32 = 50,
    slider_step: i32 = 1,
    slider_suffix: [16]u8 = @splat(0),
    slider_suffix_len: usize = 0,

    // For progress_bar
    progress_val: u32 = 0,
    progress_color: u32 = fb.Color.ACCENT_CYAN,

    // For video_viewport
    video_has_signal: bool = true,
    video_width: u32 = 1024,
    video_height: u32 = 768,
    video_anim_tick: u32 = 0,

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
        const s_len = if (icon.slider_suffix.len > 1) @min(suffix.len, icon.slider_suffix.len - 1) else 0;
        @memcpy(icon.slider_suffix[0..s_len], suffix[0..s_len]);
        icon.slider_suffix[s_len] = 0;
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

    pub fn createProgressBar(id: u32, rel_x: i32, rel_y: i32, width: u32, height: u32, label: []const u8, initial_pct: u32, color: u32) Icon {
        var icon = Icon{
            .id = id,
            .icon_type = .progress_bar,
            .rel_x = rel_x,
            .rel_y = rel_y,
            .width = width,
            .height = height,
            .progress_val = std.math.clamp(initial_pct, 0, 100),
            .progress_color = color,
        };
        icon.setText(label);
        return icon;
    }

    pub fn setProgress(self: *Icon, val: u32) void {
        self.progress_val = std.math.clamp(val, 0, 100);
    }

    pub fn createVideoViewport(id: u32, rel_x: i32, rel_y: i32, width: u32, height: u32, vm_name: []const u8, has_signal: bool) Icon {
        var icon = Icon{
            .id = id,
            .icon_type = .video_viewport,
            .rel_x = rel_x,
            .rel_y = rel_y,
            .width = width,
            .height = height,
            .video_has_signal = has_signal,
        };
        icon.setText(vm_name);
        return icon;
    }

    pub fn setVideoSignal(self: *Icon, has_signal: bool) void {
        self.video_has_signal = has_signal;
    }

    pub fn setText(self: *Icon, text: []const u8) void {
        const max_limit = if (self.icon_type == .read_write_text)
            (if (self.text_buf.len > 1) @min(self.text_buf.len - 1, self.max_input_len) else 0)
        else
            (if (self.text_buf.len > 1) self.text_buf.len - 1 else 0);
        const copy_len = @min(text.len, max_limit);
        @memcpy(self.text_buf[0..copy_len], text[0..copy_len]);
        self.text_buf[copy_len] = 0;
        self.text_len = copy_len;
        self.cursor_pos = copy_len;
        self.clearSelection();
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

    pub const SelectionBounds = struct {
        min: usize,
        max: usize,
    };

    pub fn hasSelection(self: *const Icon) bool {
        if (self.selection_start) |s| {
            if (self.selection_end) |e| {
                return s != e;
            }
        }
        return false;
    }

    pub fn getSelectionBounds(self: *const Icon) ?SelectionBounds {
        if (self.selection_start) |s| {
            if (self.selection_end) |e| {
                if (s == e) return null;
                return .{
                    .min = @min(s, e),
                    .max = @min(@max(s, e), self.text_len),
                };
            }
        }
        return null;
    }

    pub fn clearSelection(self: *Icon) void {
        self.selection_start = null;
        self.selection_end = null;
        self.is_dragging_select = false;
    }

    pub fn selectAll(self: *Icon) void {
        if (self.icon_type != .read_write_text) return;
        self.selection_start = 0;
        self.selection_end = self.text_len;
        self.cursor_pos = self.text_len;
    }

    pub fn clearField(self: *Icon) void {
        if (self.icon_type != .read_write_text) return;
        self.text_len = 0;
        self.cursor_pos = 0;
        self.clearSelection();
        if (self.text_buf.len > 0) self.text_buf[0] = 0;
    }

    pub fn getSelectedText(self: *const Icon) []const u8 {
        if (self.getSelectionBounds()) |b| {
            return self.text_buf[b.min..b.max];
        }
        return "";
    }

    pub fn deleteSelection(self: *Icon) bool {
        if (self.icon_type != .read_write_text) return false;
        const bounds = self.getSelectionBounds() orelse return false;
        const min = bounds.min;
        const max = bounds.max;
        const count = max - min;
        if (count == 0) return false;

        var i = max;
        while (i < self.text_len) : (i += 1) {
            self.text_buf[i - count] = self.text_buf[i];
        }
        self.text_len -= count;
        if (self.text_len < self.text_buf.len) {
            self.text_buf[self.text_len] = 0;
        }
        self.cursor_pos = min;
        self.clearSelection();
        return true;
    }

    // Handles character insertion for read-write text box with strict bounds check and null termination
    pub fn insertChar(self: *Icon, c: u8) void {
        if (self.icon_type != .read_write_text) return;
        if (self.text_len >= self.max_input_len or self.text_len + 1 >= self.text_buf.len) return;
        if (c < 32 or c > 126) return;

        self.cursor_pos = @min(self.cursor_pos, self.text_len);

        // Shift right
        var i = self.text_len;
        while (i > self.cursor_pos) : (i -= 1) {
            self.text_buf[i] = self.text_buf[i - 1];
        }
        self.text_buf[self.cursor_pos] = c;
        self.text_len += 1;
        self.text_buf[self.text_len] = 0;
        self.cursor_pos += 1;
    }

    // Handles backspace deletion
    pub fn deleteBackward(self: *Icon) void {
        if (self.icon_type != .read_write_text) return;
        if (self.cursor_pos == 0 or self.text_len == 0) return;

        self.cursor_pos = @min(self.cursor_pos, self.text_len);
        var i = self.cursor_pos - 1;
        while (i + 1 < self.text_len) : (i += 1) {
            self.text_buf[i] = self.text_buf[i + 1];
        }
        self.text_len -= 1;
        self.text_buf[self.text_len] = 0;
        self.cursor_pos -= 1;
    }

    // Handles delete key forward deletion
    pub fn deleteForward(self: *Icon) void {
        if (self.icon_type != .read_write_text) return;
        if (self.cursor_pos >= self.text_len or self.text_len == 0) return;

        var i = self.cursor_pos;
        while (i + 1 < self.text_len) : (i += 1) {
            self.text_buf[i] = self.text_buf[i + 1];
        }
        self.text_len -= 1;
        self.text_buf[self.text_len] = 0;
    }

    // Inserts a string at current cursor position (replacing any active selection) without overflowing capacity
    pub fn insertString(self: *Icon, str: []const u8) void {
        if (self.icon_type != .read_write_text) return;
        _ = self.deleteSelection();
        for (str) |c| {
            if (self.text_len >= self.max_input_len or self.text_len + 1 >= self.text_buf.len) break;
            if (c >= 32 and c <= 126) {
                self.insertChar(c);
            }
        }
    }

    // Calculate nearest character index from mouse X position (respecting field scroll offset)
    pub fn getCharIndexAtX(self: *const Icon, win_x: i32, px: i32) usize {
        const pad_x: i32 = 8;
        const inner_w: u32 = if (self.width > 16) self.width - 16 else 0;
        const txt = self.getText();
        const safe_cur = @min(self.cursor_pos, txt.len);
        const cur_offset = font.measureString(txt[0..safe_cur]);
        const scroll_x: i32 = if (inner_w > 8 and cur_offset + 8 > inner_w)
            @intCast(cur_offset + 8 - inner_w)
        else
            0;
        const text_start_x = win_x + self.rel_x + pad_x - scroll_x;
        if (px <= text_start_x) return 0;

        const rel_px = px - text_start_x;
        var cur_x: i32 = 0;

        for (txt, 0..) |c, i| {
            const char_w: i32 = if (c >= 32 and c <= 126)
                @intCast(font.GLYPHS[c - 32].advance)
            else if (c == ' ')
                6
            else if (c == '\t')
                24
            else
                8;

            const mid_x = cur_x + @divTrunc(char_w, 2);
            if (rel_px < mid_x) {
                return i;
            }
            cur_x += char_w;
        }
        return self.text_len;
    }

    pub fn hitTest(self: *const Icon, win_x: i32, win_y: i32, px: i32, py: i32) bool {
        if (!self.is_enabled) return false;
        const box = fb.Box.fromPosSize(win_x + self.rel_x, win_y + self.rel_y, self.width, self.height);
        return box.contains(px, py);
    }

    // Render this icon onto the framebuffer surface with strict bounding box clipping
    pub fn render(self: *Icon, surface: *fb.Surface, win_x: i32, win_y: i32, is_win_active: bool) void {
        const sx = win_x + self.rel_x;
        const sy = win_y + self.rel_y;
        const box = fb.Box.fromPosSize(sx, sy, self.width, self.height);

        // If this icon is focused and window is active, render keyboard focus hand marker
        // (drawn before establishing icon content clipping so the hand can point in the outer margin)
        if (self.is_focused and is_win_active) {
            cursor_mod.Cursor.drawFocusHand(surface, sx - 20, sy + @divTrunc(@as(i32, @intCast(self.height)) - 12, 2));
        }

        // Establish icon bounding box clipping
        const prev_icon_clip = surface.pushClip(box);
        defer surface.popClip(prev_icon_clip);

        // If icon bounding box is completely clipped out by parent, return early
        if (surface.clip.isEmpty()) return;

        const fg_color: u32 = if (!self.is_enabled)
            fb.Color.TEXT_MUTED
        else if (self.is_focused and is_win_active)
            fb.Color.ACCENT_CYAN
        else
            fb.Color.WHITE;

        switch (self.icon_type) {
            .read_only_text => {
                // Read-only text label with drop shadow, clipped strictly to icon bounding box
                const text_y = sy + @divTrunc(@as(i32, @intCast(self.height)) - @as(i32, @intCast(font.GLYPH_HEIGHT)), 2);
                font.drawTextWithShadow(surface, self.getText(), sx, text_y, fg_color, fb.Color.BLACK);
            },

            .read_write_text => {
                // Inset editable field box
                const border_col = if (self.is_focused) fb.Color.ACCENT_CYAN else fb.Color.GLASS_BORDER;
                surface.drawRoundedTranslucentBox(box, 4, fb.Color.INPUT_BG, 230, border_col);

                const text_y = sy + @divTrunc(@as(i32, @intCast(self.height)) - @as(i32, @intCast(font.GLYPH_HEIGHT)), 2);
                const txt = self.getText();

                // Inner clipping box so text, selection, and cursor never bleed over input border
                const pad_x: i32 = 8;
                const inner_w: u32 = if (self.width > 16) self.width - 16 else 0;
                const inner_clip = surface.pushClip(fb.Box.fromPosSize(sx + pad_x, sy + 2, inner_w, if (self.height > 4) self.height - 4 else 0));
                defer surface.popClip(inner_clip);

                // Calculate horizontal scroll offset so cursor always remains visible inside field
                const safe_cur = @min(self.cursor_pos, txt.len);
                const cur_offset = font.measureString(txt[0..safe_cur]);
                const scroll_x: i32 = if (inner_w > 8 and cur_offset + 8 > inner_w)
                    @intCast(cur_offset + 8 - inner_w)
                else
                    0;
                const text_start_x = sx + pad_x - scroll_x;

                // 1. Draw selection highlight box behind characters if selection active
                if (self.getSelectionBounds()) |b| {
                    const sel_start_x = text_start_x + @as(i32, @intCast(font.measureString(txt[0..b.min])));
                    const sel_w = font.measureString(txt[b.min..b.max]);
                    if (sel_w > 0) {
                        const sel_box = fb.Box.fromPosSize(sel_start_x, text_y, sel_w, font.GLYPH_HEIGHT);
                        surface.drawRoundedTranslucentBox(sel_box, 2, fb.Color.ACCENT_CYAN, 140, null);
                    }
                }

                // 2. Draw text with drop shadow
                font.drawTextWithShadow(surface, txt, text_start_x, text_y, fg_color, fb.Color.BLACK);

                // 3. Draw blinking or static insertion cursor if focused
                if (self.is_focused and is_win_active) {
                    const cur_x = text_start_x + @as(i32, @intCast(cur_offset));
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
                const val_w = font.measureString(val_str);
                const val_x = sx + @as(i32, @intCast(self.width)) - @as(i32, @intCast(val_w));

                // Clip title label so it never collides with or overwrites the value string
                const label_w: u32 = if (val_x > sx + 8) @intCast(val_x - sx - 8) else 0;
                const label_clip = surface.pushClip(fb.Box.fromPosSize(sx, sy, label_w, font.GLYPH_HEIGHT + 4));
                font.drawTextWithShadow(surface, self.getText(), sx, text_y, fg_color, fb.Color.BLACK);
                surface.popClip(label_clip);

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

                // 2. Adjacent Label Text clipped to remaining box width
                const text_x = sx + @as(i32, @intCast(box_size)) + 10;
                const text_y = sy + @divTrunc(@as(i32, @intCast(self.height)) - @as(i32, @intCast(font.GLYPH_HEIGHT)), 2);
                const label_w: u32 = if (self.width > box_size + 12) self.width - (box_size + 12) else 0;
                const label_clip = surface.pushClip(fb.Box.fromPosSize(text_x, sy, label_w, self.height));
                font.drawTextWithShadow(surface, self.getText(), text_x, text_y, fg_color, fb.Color.BLACK);
                surface.popClip(label_clip);
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
                const pad_x: i32 = 12;
                const text_x = if (text_w + 24 >= self.width)
                    sx + pad_x
                else
                    sx + @divTrunc(@as(i32, @intCast(self.width)) - @as(i32, @intCast(text_w)), 2);
                const text_y = sy + @divTrunc(@as(i32, @intCast(self.height)) - @as(i32, @intCast(font.GLYPH_HEIGHT)), 2);

                const inner_w: u32 = if (self.width > 24) self.width - 24 else 0;
                const btn_text_clip = surface.pushClip(fb.Box.fromPosSize(sx + pad_x, sy, inner_w, self.height));
                font.drawTextWithShadow(surface, txt, text_x, text_y, fg_color, fb.Color.BLACK);
                surface.popClip(btn_text_clip);
            },

            .progress_bar => {
                // 1. Label and Percentage value
                const text_y = sy + 2;
                var pct_buf: [32]u8 = undefined;
                const pct_str = std.fmt.bufPrint(&pct_buf, "{d}%", .{self.progress_val}) catch "";
                const pct_w = font.measureString(pct_str);
                const pct_x = sx + @as(i32, @intCast(self.width)) - @as(i32, @intCast(pct_w));

                // Clip title label so it never collides with or overwrites the percentage readout
                const label_w: u32 = if (pct_x > sx + 8) @intCast(pct_x - sx - 8) else 0;
                const label_clip = surface.pushClip(fb.Box.fromPosSize(sx, sy, label_w, font.GLYPH_HEIGHT + 4));
                font.drawTextWithShadow(surface, self.getText(), sx, text_y, fg_color, fb.Color.BLACK);
                surface.popClip(label_clip);

                font.drawTextWithShadow(surface, pct_str, pct_x, text_y, fb.Color.ACCENT_GOLD, fb.Color.BLACK);

                // 2. Track Groove
                const track_y = sy + 22;
                const track_h: u32 = 8;
                const track_box = fb.Box.fromPosSize(sx, track_y, self.width, track_h);
                surface.drawRoundedTranslucentBox(track_box, 3, fb.Color.TRACK_BG, 240, fb.Color.GLASS_BORDER);

                // 3. Filled Progress Bar
                const clamped_pct = std.math.clamp(self.progress_val, 0, 100);
                if (clamped_pct > 0) {
                    const bar_w = @divTrunc(@as(i32, @intCast(self.width)) * @as(i32, @intCast(clamped_pct)), 100);
                    if (bar_w > 0) {
                        const bar_box = fb.Box.fromPosSize(sx + 1, track_y + 1, @intCast(@max(1, bar_w - 2)), track_h - 2);
                        surface.drawRoundedTranslucentBox(bar_box, 2, self.progress_color, 255, null);
                    }
                }
            },

            .video_viewport => {
                // 1. Monitor Bezel Frame
                const border_col = if (self.is_focused and is_win_active) fb.Color.ACCENT_CYAN else fb.Color.GLASS_BORDER;
                surface.drawRoundedTranslucentBox(box, 6, fb.Color.INPUT_BG, 240, border_col);

                // 2. Top Monitor Banner Bar (LED status dot + display controller title)
                const header_h: u32 = 24;
                const header_box = fb.Box.fromPosSize(sx, sy, self.width, header_h);
                surface.drawRoundedTranslucentBox(header_box, 4, fb.Color.BTN_NORMAL_BG, 220, null);

                // LED status light
                const led_color = if (self.video_has_signal) fb.Color.ACCENT_GREEN else fb.Color.ACCENT_RED;
                const led_box = fb.Box.fromPosSize(sx + 10, sy + 7, 10, 10);
                surface.drawRoundedTranslucentBox(led_box, 5, led_color, 255, fb.Color.WHITE);

                // Header title text clipped inside header bar
                var hdr_buf: [96]u8 = undefined;
                const hdr_text = if (self.video_has_signal)
                    (if (self.width >= 600)
                        std.fmt.bufPrint(&hdr_buf, "VIRTUAL DISPLAY 0: {s} (VirtIO-GPU 2D 1024x768 @ 60Hz)", .{self.getText()}) catch "VIRTUAL DISPLAY (VirtIO-GPU)"
                    else
                        std.fmt.bufPrint(&hdr_buf, "DISPLAY: {s} (VirtIO-GPU 60Hz)", .{self.getText()}) catch "DISPLAY (VirtIO-GPU)")
                else
                    (if (self.width >= 600)
                        std.fmt.bufPrint(&hdr_buf, "VIRTUAL DISPLAY 0: {s} (HEADLESS / SERIAL CONSOLE ONLY)", .{self.getText()}) catch "VIRTUAL DISPLAY (HEADLESS)"
                    else
                        std.fmt.bufPrint(&hdr_buf, "DISPLAY: {s} (HEADLESS / SERIAL)", .{self.getText()}) catch "DISPLAY (HEADLESS)");
                const hdr_w: u32 = if (self.width > 36) self.width - 36 else 0;
                const hdr_clip = surface.pushClip(fb.Box.fromPosSize(sx + 28, sy, hdr_w, header_h));
                font.drawTextWithShadow(surface, hdr_text, sx + 28, sy + 4, if (self.video_has_signal) fb.Color.ACCENT_CYAN else fb.Color.ACCENT_AMBER, fb.Color.BLACK);
                surface.popClip(hdr_clip);

                // 3. Screen Viewport Box
                const screen_x = sx + 8;
                const screen_y = sy + @as(i32, @intCast(header_h)) + 4;
                const screen_w = if (self.width > 16) self.width - 16 else 1;
                const screen_h = if (self.height > header_h + 12) self.height - header_h - 12 else 1;
                const screen_box = fb.Box.fromPosSize(screen_x, screen_y, screen_w, screen_h);

                // Push screen viewport clip to guarantee inner graphics never leak out
                const screen_clip = surface.pushClip(screen_box);
                defer surface.popClip(screen_clip);

                if (self.video_has_signal) {
                    // Guest desktop twilight background
                    surface.drawGraduatedBackgroundInBox(screen_box, fb.Color.VIEWPORT_DESKTOP_TOP, fb.Color.VIEWPORT_DESKTOP_BOT);

                    // Guest OS top system bar
                    const bar_h: u32 = 18;
                    const bar_box = fb.Box.fromPosSize(screen_x, screen_y, screen_w, bar_h);
                    surface.fillBox(bar_box, fb.Color.VIEWPORT_BAR);
                    if (screen_w >= 600) {
                        font.drawText(surface, "Diosix Guest OS", screen_x + 8, screen_y + 2, fb.Color.WHITE);
                        font.drawText(surface, "riscv64 | IP: 10.0.3.2 | GPU: VirtIO-GPU", screen_x + @divTrunc(@as(i32, @intCast(screen_w)), 2) - 110, screen_y + 2, fb.Color.TEXT_MUTED);
                        font.drawText(surface, "15:48:22", screen_x + @as(i32, @intCast(screen_w)) - 60, screen_y + 2, fb.Color.ACCENT_GOLD);
                    } else {
                        font.drawText(surface, "Guest OS", screen_x + 8, screen_y + 2, fb.Color.WHITE);
                        font.drawText(surface, "10.0.3.2", screen_x + @divTrunc(@as(i32, @intCast(screen_w)), 2) - 28, screen_y + 2, fb.Color.TEXT_MUTED);
                        font.drawText(surface, "15:48", screen_x + @as(i32, @intCast(screen_w)) - 46, screen_y + 2, fb.Color.ACCENT_GOLD);
                    }

                    // Virtual terminal window on guest desktop
                    if (screen_w > 140 and screen_h > 120) {
                        const term_x = screen_x + 24;
                        const term_y = screen_y + 28;
                        const term_w = if (screen_w > 48) screen_w - 48 else screen_w;
                        const term_h = if (screen_h > 68) screen_h - 68 else screen_h;
                        const term_box = fb.Box.fromPosSize(term_x, term_y, term_w, term_h);
                        surface.drawRoundedTranslucentBox(term_box, 4, fb.Color.VIEWPORT_TERM_BG, 240, fb.Color.VIEWPORT_TERM_BORDER);

                        // Terminal title bar
                        const ttitle_box = fb.Box.fromPosSize(term_x, term_y, term_w, 20);
                        surface.drawRoundedTranslucentBox(ttitle_box, 4, fb.Color.VIEWPORT_TERM_HDR, 255, null);
                        // Window control buttons
                        surface.fillBox(fb.Box.fromPosSize(term_x + 8, term_y + 6, 8, 8), fb.Color.ACCENT_RED);
                        surface.fillBox(fb.Box.fromPosSize(term_x + 20, term_y + 6, 8, 8), fb.Color.ACCENT_AMBER);
                        surface.fillBox(fb.Box.fromPosSize(term_x + 32, term_y + 6, 8, 8), fb.Color.ACCENT_GREEN);

                        var term_title_buf: [64]u8 = undefined;
                        const ttitle = std.fmt.bufPrint(&term_title_buf, "Console: root@{s}:~", .{self.getText()}) catch "Console: root@guest:~";
                        font.drawText(surface, ttitle, term_x + 50, term_y + 3, fb.Color.WHITE);

                        // Terminal output lines
                        const l1_y = term_y + 26;
                        if (term_w >= 500) {
                            font.drawText(surface, "Linux 7.0.10-diosix (riscv64) #1 SMP PREEMPT_DYNAMIC", term_x + 10, l1_y, fb.Color.VIEWPORT_TEXT_DIM);
                        } else {
                            font.drawText(surface, "Linux 7.0.10-diosix (riscv64)", term_x + 10, l1_y, fb.Color.VIEWPORT_TEXT_DIM);
                        }
                        if (term_h > 50) {
                            font.drawText(surface, "root@guest:~# dsx ps", term_x + 10, l1_y + 16, fb.Color.ACCENT_GREEN);
                        }
                        if (term_h > 70) {
                            font.drawText(surface, "CID  NAME       STATUS   VCPUS  RAM    IP", term_x + 10, l1_y + 32, fb.Color.TEXT_MUTED);
                        }
                        if (term_h > 90) {
                            var ps_buf: [64]u8 = undefined;
                            const ps_str = std.fmt.bufPrint(&ps_buf, "2    {s:<10} RUNNING  2      256MB  10.0.3.2", .{self.getText()}) catch "";
                            font.drawText(surface, ps_str, term_x + 10, l1_y + 48, fb.Color.WHITE);
                        }
                        if (term_h > 110) {
                            font.drawText(surface, "root@guest:~# _", term_x + 10, l1_y + 64, fb.Color.ACCENT_GREEN);
                        }
                    }

                    // Lower desktop taskbar
                    const bbar_y = screen_y + @as(i32, @intCast(screen_h)) - 18;
                    const bbar_box = fb.Box.fromPosSize(screen_x, bbar_y, screen_w, 18);
                    surface.fillBox(bbar_box, fb.Color.VIEWPORT_BOTTOM_BAR);
                    if (screen_w >= 600) {
                        font.drawText(surface, "Format: X8R8G8B8 | DRM: /dev/dri/card0 | Scanout 0 (60.0 FPS)", screen_x + 8, bbar_y + 2, fb.Color.TEXT_MUTED);
                    } else {
                        font.drawText(surface, "DRM: /dev/dri/card0 | Scanout 60 FPS", screen_x + 8, bbar_y + 2, fb.Color.TEXT_MUTED);
                    }
                } else {
                    // Headless Domain Display: Dark phosphor CRT with retro diagnostic screen
                    surface.fillBox(screen_box, fb.Color.VIEWPORT_HEADLESS_BG);

                    // Scanlines
                    var gy: i32 = screen_y + 4;
                    while (gy < screen_y + @as(i32, @intCast(screen_h))) : (gy += 8) {
                        surface.fillBox(fb.Box.fromPosSize(screen_x, gy, screen_w, 1), fb.Color.VIEWPORT_GRID_LINE);
                    }

                    // Centered diagnostic warning box
                    const warn_w: u32 = if (screen_w > 40) screen_w - 40 else screen_w;
                    const warn_h: u32 = if (screen_h > 60) screen_h - 60 else screen_h;
                    const warn_x = screen_x + 20;
                    const warn_y = screen_y + 20;
                    const warn_box = fb.Box.fromPosSize(warn_x, warn_y, warn_w, warn_h);
                    surface.drawRoundedTranslucentBox(warn_box, 4, fb.Color.INPUT_BG, 240, fb.Color.ACCENT_AMBER);

                    if (warn_w >= 500) {
                        font.drawTextWithShadow(surface, "[ HEADLESS DOMAIN - NO VIDEO OUTPUT DEVICE ]", warn_x + 20, warn_y + 16, fb.Color.ACCENT_AMBER, fb.Color.BLACK);
                        font.drawText(surface, "The selected virtual machine has no VirtIO-GPU display adapter.", warn_x + 20, warn_y + 40, fb.Color.WHITE);
                        font.drawText(surface, "Primary Console : 16550 UART Serial (/dev/ttyS0 @ 115200 baud)", warn_x + 20, warn_y + 64, fb.Color.TEXT_MUTED);
                        font.drawText(surface, "Remote Console  : Dropbear SSH Bridge (port 22 active)", warn_x + 20, warn_y + 84, fb.Color.TEXT_MUTED);
                        font.drawText(surface, "Use 'Open Virtual SSH Console' to interact with this domain.", warn_x + 20, warn_y + 110, fb.Color.ACCENT_CYAN);
                    } else {
                        font.drawTextWithShadow(surface, "[ HEADLESS DOMAIN - NO VIDEO ]", warn_x + 14, warn_y + 16, fb.Color.ACCENT_AMBER, fb.Color.BLACK);
                        font.drawText(surface, "Virtual machine has no VirtIO-GPU display.", warn_x + 14, warn_y + 40, fb.Color.WHITE);
                        font.drawText(surface, "Primary: 16550 UART (/dev/ttyS0)", warn_x + 14, warn_y + 64, fb.Color.TEXT_MUTED);
                        font.drawText(surface, "Remote : Dropbear SSH Bridge (port 22)", warn_x + 14, warn_y + 84, fb.Color.TEXT_MUTED);
                        font.drawText(surface, "Use 'Open Virtual SSH' to interact.", warn_x + 14, warn_y + 110, fb.Color.ACCENT_CYAN);
                    }
                }
            },
        }
    }
};
