// Read-Write Text Field Editing & Selection Logic for Diosix GUI Icons.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const font = @import("../font.zig");
const icon_mod = @import("../icon.zig");
const Icon = icon_mod.Icon;

pub const ASCII_PRINTABLE_MIN: u8 = font.ASCII_PRINTABLE_MIN;
pub const ASCII_PRINTABLE_MAX: u8 = font.ASCII_PRINTABLE_MAX;

pub const SelectionBounds = struct {
    min: usize,
    max: usize,
};

pub fn hasSelection(self: *const Icon) bool {
    if (self.selection_start) |s| {
        if (self.selection_end) |e| return s != e;
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
    clearSelection(self);
    if (self.text_buf.len > 0) self.text_buf[0] = 0;
}

pub fn getSelectedText(self: *const Icon) []const u8 {
    if (getSelectionBounds(self)) |b| {
        return self.text_buf[b.min..b.max];
    }
    return "";
}

pub fn deleteRange(self: *Icon, min: usize, max: usize) bool {
    if (self.icon_type != .read_write_text or max <= min) return false;
    const count = max - min;
    var i = max;
    while (i < self.text_len) : (i += 1) {
        self.text_buf[i - count] = self.text_buf[i];
    }
    self.text_len -= count;
    if (self.text_len < self.text_buf.len) {
        self.text_buf[self.text_len] = 0;
    }
    self.cursor_pos = min;
    return true;
}

pub fn deleteSelection(self: *Icon) bool {
    const bounds = getSelectionBounds(self) orelse return false;
    const deleted = deleteRange(self, bounds.min, bounds.max);
    if (deleted) clearSelection(self);
    return deleted;
}

pub fn insertChar(self: *Icon, c: u8) void {
    if (self.icon_type != .read_write_text) return;
    if (self.text_len >= self.max_input_len or
        self.text_len + 1 >= self.text_buf.len) return;
    if (c < ASCII_PRINTABLE_MIN or c > ASCII_PRINTABLE_MAX) return;

    self.cursor_pos = @min(self.cursor_pos, self.text_len);
    var i = self.text_len;
    while (i > self.cursor_pos) : (i -= 1) {
        self.text_buf[i] = self.text_buf[i - 1];
    }
    self.text_buf[self.cursor_pos] = c;
    self.text_len += 1;
    self.text_buf[self.text_len] = 0;
    self.cursor_pos += 1;
}

pub fn deleteBackward(self: *Icon) void {
    if (self.icon_type != .read_write_text) return;
    if (self.cursor_pos == 0 or self.text_len == 0) return;
    const end = @min(self.cursor_pos, self.text_len);
    _ = deleteRange(self, end - 1, end);
}

pub fn deleteForward(self: *Icon) void {
    if (self.icon_type != .read_write_text) return;
    if (self.cursor_pos >= self.text_len or self.text_len == 0) return;
    _ = deleteRange(self, self.cursor_pos, self.cursor_pos + 1);
}

pub fn insertString(self: *Icon, str: []const u8) void {
    if (self.icon_type != .read_write_text) return;
    _ = deleteSelection(self);
    for (str) |c| {
        if (self.text_len >= self.max_input_len or
            self.text_len + 1 >= self.text_buf.len) break;
        if (c >= ASCII_PRINTABLE_MIN and c <= ASCII_PRINTABLE_MAX) {
            insertChar(self, c);
        }
    }
}

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
        const char_w: i32 = if (c >= ASCII_PRINTABLE_MIN and
            c <= ASCII_PRINTABLE_MAX)
            @intCast(font.GLYPHS[c - ASCII_PRINTABLE_MIN].advance)
        else if (c == ' ')
            @as(i32, font.SPACE_ADVANCE)
        else if (c == '\t')
            @as(i32, font.TAB_ADVANCE)
        else
            @as(i32, font.FALLBACK_ADVANCE);

        if (rel_px < cur_x + @divTrunc(char_w, 2)) return i;
        cur_x += char_w;
    }
    return self.text_len;
}

test {
    std.testing.refAllDecls(@This());
}
