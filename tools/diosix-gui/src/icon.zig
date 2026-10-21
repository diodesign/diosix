// Interactive Icon and Widget System for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("framebuffer.zig");
const font = @import("font.zig");
pub const icon_render = @import("icon/render.zig");
pub const icon_text = @import("icon/text.zig");
const text_label = @import("label.zig");

pub const BACK_ARROW_WIDTH = icon_render.BACK_ARROW_WIDTH;
pub const BACK_ARROW_HEIGHT = icon_render.BACK_ARROW_HEIGHT;
pub const BACK_ARROW_BITMAP = icon_render.BACK_ARROW_BITMAP;
pub const drawBackArrow = icon_render.drawBackArrow;
pub const drawBackArrowWithShadow = icon_render.drawBackArrowWithShadow;
pub const ASCII_PRINTABLE_MIN: u8 = font.ASCII_PRINTABLE_MIN;
pub const ASCII_PRINTABLE_MAX: u8 = font.ASCII_PRINTABLE_MAX;
const Str = []const u8;

// Capacity of Icon.text_buf, the true limit of any displayed label (the last
// byte is a NUL terminator). Defined in label.zig so scratch buffers can share
// it without depending on the rendering code.
pub const TEXT_CAP: usize = text_label.TEXT_CAP;
// Capacity of Icon.slider_suffix: a short unit such as "%", "px" or "ms".
pub const SLIDER_SUFFIX_CAP: usize = 16;
// Default limit on characters typed into a read-write text field.
pub const DEFAULT_MAX_INPUT_LEN: usize = 64;

pub const IconType = enum {
    read_only_text,
    read_write_text,
    slider,
    tick_box,
    button,
    progress_bar,
    menu_item,
};

pub const GroupMode = enum {
    // Independent toggling (checkbox behavior).
    inclusive,
    // Only one can be ticked at a time in this group (radio button behavior).
    exclusive,
};

pub const IconCallback = *const fn (
    gui_ctx: *anyopaque,
    win_ctx: *anyopaque,
    icon: *Icon,
) void;

pub const Icon = struct {
    id: u32,
    icon_type: IconType,
    rel_x: i32,
    rel_y: i32,
    width: u32,
    height: u32,

    text_buf: [TEXT_CAP]u8 = @splat(0),
    text_len: usize = 0,
    custom_color: ?u32 = null,
    help_text: ?[]const u8 = null,
    has_back_arrow: bool = false,

    // Read-write text field state.
    cursor_pos: usize = 0,
    max_input_len: usize = DEFAULT_MAX_INPUT_LEN,
    selection_start: ?usize = null,
    selection_end: ?usize = null,
    is_dragging_select: bool = false,

    // Slider state.
    slider_min: i32 = 0,
    slider_max: i32 = 100,
    slider_val: i32 = 50,
    slider_step: i32 = 1,
    slider_suffix: [SLIDER_SUFFIX_CAP]u8 = @splat(0),
    slider_suffix_len: usize = 0,

    // Progress bar state.
    progress_val: u32 = 0,
    progress_color: u32 = fb.Color.INK,

    // Tick box, grouping & callback state.
    is_ticked: bool = false,
    group_id: ?u16 = null,
    group_mode: GroupMode = .inclusive,
    callback: ?IconCallback = null,
    user_tag: usize = 0,

    // Interactive states.
    is_focused: bool = false,
    is_hovered: bool = false,
    is_enabled: bool = true,
    is_selectable: bool = true,
    is_selected: bool = false,
    is_active_press: bool = false,
    is_dragging_slider: bool = false,

    pub fn setSelected(self: *Icon, selected: bool) void {
        self.is_selected = selected;
    }

    pub fn setHelpText(self: *Icon, text: ?[]const u8) void {
        self.help_text = text;
    }

    pub fn getHelpText(self: *const Icon) ?[]const u8 {
        return self.help_text;
    }

    pub fn setCustomColor(self: *Icon, color: ?u32) void {
        self.custom_color = color;
    }

    pub fn containsPoint(s: *const Icon, u: i32, v: i32, x: i32, y: i32) bool {
        if (!s.is_enabled) return false;
        const bx = u + s.rel_x;
        const by = v + s.rel_y;
        return fb.Box.fromPosSize(bx, by, s.width, s.height).contains(x, y);
    }

    pub fn setSelectable(self: *Icon, selectable: bool) void {
        self.is_selectable = selectable;
        if (!selectable) {
            self.is_focused = false;
            self.is_hovered = false;
        }
    }

    fn base(id: u32, k: IconType, x: i32, y: i32, w: u32, h: u32, t: Str) Icon {
        var icon = Icon{
            .id = id,
            .icon_type = k,
            .rel_x = x,
            .rel_y = y,
            .width = w,
            .height = h,
        };
        if (t.len > 0) icon.setText(t);
        return icon;
    }

    pub fn createReadOnly(i: u32, x: i32, y: i32, w: u32, h: u32, t: Str) Icon {
        var icon = base(i, .read_only_text, x, y, w, h, t);
        icon.is_selectable = false;
        return icon;
    }

    pub fn createReadWrite(
        i: u32,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        t: Str,
    ) Icon {
        return base(i, .read_write_text, x, y, w, h, t);
    }

    pub fn createSlider(
        id: u32,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        min: i32,
        max: i32,
        initial: i32,
        suffix: Str,
    ) Icon {
        var icon = base(id, .slider, x, y, w, h, "");
        icon.slider_min = min;
        icon.slider_max = max;
        icon.slider_val = initial;
        const s_len = @min(suffix.len, icon.slider_suffix.len - 1);
        @memcpy(icon.slider_suffix[0..s_len], suffix[0..s_len]);
        icon.slider_suffix[s_len] = 0;
        icon.slider_suffix_len = s_len;
        return icon;
    }

    pub fn createTickBox(
        id: u32,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        label: Str,
        initial_ticked: bool,
        group_id: ?u16,
        group_mode: GroupMode,
    ) Icon {
        var icon = base(id, .tick_box, x, y, w, h, label);
        icon.is_ticked = initial_ticked;
        icon.group_id = group_id;
        icon.group_mode = group_mode;
        return icon;
    }

    pub fn createButton(id: u32, x: i32, y: i32, w: u32, h: u32, t: Str) Icon {
        return base(id, .button, x, y, w, h, t);
    }

    pub fn createProgressBar(
        id: u32,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        label: Str,
        initial_pct: u32,
        color: u32,
    ) Icon {
        var icon = base(id, .progress_bar, x, y, w, h, label);
        icon.progress_val = std.math.clamp(initial_pct, 0, 100);
        icon.progress_color = color;
        return icon;
    }

    pub fn setProgress(self: *Icon, val: u32) void {
        self.progress_val = std.math.clamp(val, 0, 100);
    }

    pub fn createMenuItem(i: u32, x: i32, y: i32, w: u32, h: u32, t: Str) Icon {
        return base(i, .menu_item, x, y, w, h, t);
    }

    pub fn createBackMenuItem(
        id: u32,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        t: Str,
    ) Icon {
        var icon = base(id, .menu_item, x, y, w, h, t);
        icon.has_back_arrow = true;
        return icon;
    }

    pub fn isTicked(self: *const Icon) bool {
        return self.is_ticked;
    }

    pub fn setTicked(self: *Icon, ticked: bool) void {
        self.is_ticked = ticked;
    }

    pub fn setText(self: *Icon, text: []const u8) void {
        const max_limit = if (self.icon_type == .read_write_text)
            (if (self.text_buf.len > 1)
                @min(self.text_buf.len - 1, self.max_input_len)
            else
                0)
        else if (self.text_buf.len > 1)
            self.text_buf.len - 1
        else
            0;
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

    pub const SelectionBounds = icon_text.SelectionBounds;
    pub const hasSelection = icon_text.hasSelection;
    pub const getSelectionBounds = icon_text.getSelectionBounds;
    pub const clearSelection = icon_text.clearSelection;
    pub const selectAll = icon_text.selectAll;
    pub const clearField = icon_text.clearField;
    pub const getSelectedText = icon_text.getSelectedText;
    pub const deleteSelection = icon_text.deleteSelection;
    pub const insertChar = icon_text.insertChar;
    pub const deleteBackward = icon_text.deleteBackward;
    pub const deleteForward = icon_text.deleteForward;
    pub const insertString = icon_text.insertString;
    pub const getCharIndexAtX = icon_text.getCharIndexAtX;

    pub fn hitTest(self: *const Icon, wx: i32, wy: i32, px: i32, py: i32) bool {
        return self.is_selectable and self.containsPoint(wx, wy, px, py);
    }

    pub const render = icon_render.renderIcon;
};

test {
    _ = text_label;
    _ = icon_render;
    _ = icon_text;
    std.testing.refAllDecls(@This());
}
