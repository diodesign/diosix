// On-Screen Keyboard (OSK) Window Builder and Action Handlers for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("../framebuffer.zig");
const icon_mod = @import("../icon.zig");
const Icon = icon_mod.Icon;
const window_mod = @import("../window.zig");
const Window = window_mod.Window;
const osk_mod = @import("../osk.zig");
const text_label = @import("../label.zig");
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;

const BORDER_GAP = gui_mod.BORDER_GAP;
const WIN_OSK_ID = gui_mod.WIN_OSK_ID;
const ICON_OSK_KEY_BASE_ID = gui_mod.ICON_OSK_KEY_BASE_ID;
const ICON_OSK_DISPLAY_ID = gui_mod.ICON_OSK_DISPLAY_ID;

fn addOskBtn(
    win: *Window,
    id: u32,
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    label: []const u8,
    cb: icon_mod.IconCallback,
) !void {
    var btn = Icon.createButton(id, x, y, w, h, label);
    btn.callback = cb;
    _ = try win.addIcon(btn);
}

pub const KeyCommand = enum {
    backspace,
    delete,
    left,
    right,
    home,
    end,
};

var shift_held: bool = false;

fn findFocusedInput(
    self: *DiosixGui,
) ?struct { win_id: u32, icon: *Icon } {
    if (self.active_win_idx) |widx| {
        if (widx < self.windows.items.len) {
            const win = &self.windows.items[widx];
            if (win.is_onscreen) {
                if (win.getFocusedIcon()) |ic| {
                    if (ic.icon_type == .read_write_text) {
                        return .{ .win_id = win.id, .icon = ic };
                    }
                }
            }
        }
    }
    var i = self.windows.items.len;
    while (i > 0) : (i -= 1) {
        const win = &self.windows.items[i - 1];
        if (!win.is_onscreen) continue;
        if (win.getFocusedIcon()) |ic| {
            if (ic.icon_type == .read_write_text) {
                return .{ .win_id = win.id, .icon = ic };
            }
        }
    }
    return null;
}

fn syncInputField(self: *DiosixGui, win_id: u32, ic: *Icon) void {
    if (ic.id == gui_mod.ICON_CREATE_VM_NAME_INPUT_ID) {
        self.setCreateVmName(ic.getText());
    }
    self.markWindowDirty(win_id);
}

pub fn handleKeyChar(self: *DiosixGui, ch: u8) void {
    if (findFocusedInput(self)) |target| {
        _ = target.icon.deleteSelection();
        target.icon.insertChar(ch);
        syncInputField(self, target.win_id, target.icon);
    }
}

pub fn handleKeySpecial(self: *DiosixGui, cmd: KeyCommand) void {
    if (findFocusedInput(self)) |target| {
        const ic = target.icon;
        switch (cmd) {
            .backspace => {
                if (!ic.deleteSelection()) ic.deleteBackward();
            },
            .delete => {
                if (!ic.deleteSelection()) ic.deleteForward();
            },
            .left => {
                ic.clearSelection();
                if (ic.cursor_pos > 0) ic.cursor_pos -= 1;
            },
            .right => {
                ic.clearSelection();
                if (ic.cursor_pos < ic.text_len) ic.cursor_pos += 1;
            },
            .home => {
                ic.clearSelection();
                ic.cursor_pos = 0;
            },
            .end => {
                ic.clearSelection();
                ic.cursor_pos = ic.text_len;
            },
        }
        syncInputField(self, target.win_id, ic);
    }
}

pub fn handleEvdevKey(self: *DiosixGui, code: u16, value: i32) void {
    if (code == 42 or code == 54) {
        shift_held = (value != 0);
        return;
    }
    if (value == 0) return;

    switch (code) {
        14 => handleKeySpecial(self, .backspace),
        111 => handleKeySpecial(self, .delete),
        105 => handleKeySpecial(self, .left),
        106 => handleKeySpecial(self, .right),
        102 => handleKeySpecial(self, .home),
        107 => handleKeySpecial(self, .end),
        57 => handleKeyChar(self, '-'),
        12 => handleKeyChar(self, if (shift_held) '_' else '-'),
        52 => handleKeyChar(self, '.'),
        2...11 => {
            const digits = "1234567890";
            handleKeyChar(self, digits[code - 2]);
        },
        16...25 => {
            const row1 = "qwertyuiop";
            const ch = row1[code - 16];
            handleKeyChar(self, if (shift_held) std.ascii.toUpper(ch) else ch);
        },
        30...38 => {
            const row2 = "asdfghjkl";
            const ch = row2[code - 30];
            handleKeyChar(self, if (shift_held) std.ascii.toUpper(ch) else ch);
        },
        44...50 => {
            const row3 = "zxcvbnm";
            const ch = row3[code - 44];
            handleKeyChar(self, if (shift_held) std.ascii.toUpper(ch) else ch);
        },
        else => {},
    }
}

pub fn handleOskAction(self: *DiosixGui, icon_id: u32) void {
    if (icon_id >= ICON_OSK_KEY_BASE_ID) {
        const offset = icon_id - ICON_OSK_KEY_BASE_ID;
        const prev_len = self.osk_state.input_len;
        _ = self.osk_state.applyKeyOffset(offset);
        if (self.osk_state.input_len > prev_len) {
            const ch = self.osk_state.input_buf[self.osk_state.input_len - 1];
            handleKeyChar(self, ch);
        } else if (offset == 27) {
            handleKeySpecial(self, .backspace);
        }
        if (!self.osk_state.visible) {
            _ = self.destroyWindow(WIN_OSK_ID);
            self.markFullDirty();
        } else {
            buildOskWindow(self) catch {};
        }
    }
}

pub fn onOskKeyClicked(
    gui_ctx: *anyopaque,
    win_ctx: *anyopaque,
    icon: *Icon,
) void {
    _ = win_ctx;
    const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    handleOskAction(self, icon.id);
}

pub fn buildOskWindow(self: *DiosixGui) !void {
    if (!self.osk_state.visible) {
        _ = self.destroyWindow(WIN_OSK_ID);
        return;
    }
    const avail_w = self.width -| @as(u32, @intCast(BORDER_GAP * 2));
    const osk_w: u32 = @max(120, @min(avail_w, 760));
    const osk_h: u32 = 216;
    const dx = @as(i32, @intCast(self.width)) - @as(i32, @intCast(osk_w));
    const osk_x: i32 = @max(0, @divTrunc(dx, 2));
    const osk_y: i32 = @max(
        0,
        @as(i32, @intCast(self.height)) - 40 - BORDER_GAP * 2 -
            @as(i32, @intCast(osk_h)),
    );

    const win = try self.createWindow(
        WIN_OSK_ID,
        osk_x,
        osk_y,
        osk_w,
        osk_h,
        "On-screen keyboard",
    );
    win.setHelpText("Touchscreen and pointer virtual keyboard (dockable)");

    var disp_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
    const disp_str = text_label.fmtLabel(
        &disp_buf,
        "Input [{s}]: {s}_",
        .{
            self.osk_state.layout.label(),
            self.osk_state.getInputText(),
        },
    );
    var disp_icon = Icon.createReadOnly(
        ICON_OSK_DISPLAY_ID,
        16,
        36,
        osk_w -| 32,
        22,
        disp_str,
    );
    disp_icon.setCustomColor(fb.Color.INK);
    _ = try win.addIcon(disp_icon);

    const key_unit_w: u32 = 58;
    const key_h: u32 = 30;
    const gap_x: i32 = 6;
    var row_y: i32 = 64;

    const rows = [_]struct { start_x: i32, keys: []const osk_mod.KeyCap }{
        .{ .start_x = 16, .keys = &osk_mod.ROW1_LOWER },
        .{ .start_x = 34, .keys = &osk_mod.ROW2_LOWER },
        .{ .start_x = 16, .keys = &osk_mod.ROW3_LOWER },
        .{ .start_x = 16, .keys = &osk_mod.ROW4_COMMON },
    };

    for (rows) |row| {
        var rx: i32 = row.start_x;
        for (row.keys) |k| {
            const kw = key_unit_w * k.width_units;
            const lbl = self.osk_state.keyLabel(k);
            const btn_id = ICON_OSK_KEY_BASE_ID + k.id_offset;
            const cb = onOskKeyClicked;
            try addOskBtn(win, btn_id, rx, row_y, kw, key_h, lbl, cb);
            rx += @as(i32, @intCast(kw)) + gap_x;
        }
        row_y += @as(i32, @intCast(key_h)) + 6;
    }

    self.markFullDirty();
}

test {
    std.testing.refAllDecls(@This());
}
