// Diosix GUI Input Dispatch, Window Focus, and Semantic Control Plane.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const icon_mod = @import("../icon.zig");
const Icon = icon_mod.Icon;
const window_mod = @import("../window.zig");
const Window = window_mod.Window;
const host_info = @import("../host.zig");
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const json = @import("json.zig");

const WIN_HELP_ID = gui_mod.WIN_HELP_ID;
const WIN_POWER_MODAL_ID = gui_mod.WIN_POWER_MODAL_ID;
const WIN_GUEST_DISPLAY_ID = gui_mod.WIN_GUEST_DISPLAY_ID;

const BTN_LEFT: u16 = 0x110;
const ICON_HELP_TEXT_ID = gui_mod.ICON_HELP_TEXT_ID;
const ICON_POWER_MSG1_ID = gui_mod.ICON_POWER_MSG1_ID;
const ICON_POWER_MSG2_ID = gui_mod.ICON_POWER_MSG2_ID;
const FALLBACK_HELP_TEXT = gui_mod.DiosixGui.FALLBACK_HELP_TEXT;

pub const triggerSemanticAction = json.triggerSemanticAction;
pub const exportSemanticStateJson = json.exportSemanticStateJson;

pub fn findIconAt(self: *DiosixGui, px: i32, py: i32) ?*Icon {
    var i = self.windows.items.len;
    while (i > 0) : (i -= 1) {
        const win = &self.windows.items[i - 1];
        if (!win.is_onscreen) continue;
        if (win.id == WIN_HELP_ID) continue;
        if (win.findIconAt(px, py)) |icon| {
            return icon;
        }
    }
    return null;
}

pub fn findWindowAt(self: *DiosixGui, px: i32, py: i32) ?*Window {
    var i = self.windows.items.len;
    while (i > 0) : (i -= 1) {
        const win = &self.windows.items[i - 1];
        if (!win.is_onscreen) continue;
        if (win.id == WIN_HELP_ID) continue;
        if (win.contains(px, py)) {
            return win;
        }
    }
    return null;
}

pub fn updateActiveHelp(self: *DiosixGui) void {
    var help_str: ?[]const u8 = null;

    if (self.active_drag_win_id) |d_wid| {
        if (self.getWindow(d_wid)) |dwin| {
            if (dwin.active_drag_icon_idx) |d_idx| {
                if (d_idx < dwin.icons.items.len) {
                    if (dwin.icons.items[d_idx].getHelpText()) |ht| {
                        if (ht.len > 0) help_str = ht;
                    }
                }
            }
        }
    }

    if (help_str == null) {
        if (findIconAt(self, self.cursor.x, self.cursor.y)) |icon| {
            if (icon.getHelpText()) |ht| {
                if (ht.len > 0) help_str = ht;
            }
        }
    }
    if (help_str == null) {
        if (findWindowAt(self, self.cursor.x, self.cursor.y)) |win| {
            if (win.getHelpText()) |ht| {
                if (ht.len > 0) help_str = ht;
            }
        }
    }

    const final_text = help_str orelse FALLBACK_HELP_TEXT;

    if (self.findIcon(WIN_HELP_ID, ICON_HELP_TEXT_ID)) |help_icon| {
        const current_text = help_icon.getText();
        if (!std.mem.eql(u8, current_text, final_text)) {
            help_icon.setText(final_text);
            self.markWindowDirty(WIN_HELP_ID);
        }
    }
}

pub fn clearMouseHover(self: *DiosixGui) void {
    for (self.windows.items) |*win| {
        for (win.icons.items) |*icon| {
            if (icon.is_hovered) {
                icon.is_hovered = false;
                self.markDirty(win.getBox());
            }
        }
    }
}

pub fn handleMouseRelease(self: *DiosixGui) void {
    self.mouse_left_down = false;
    self.active_drag_win_id = null;
    _ = gui_mod.panes.handleDesktopMouseRelease(self, BTN_LEFT);
    for (self.windows.items) |*win| {
        if (win.is_onscreen) {
            if (win.handleMouseRelease()) {
                self.markDirty(win.getBox());
            }
        }
    }
}

pub fn handleMouseMove(
    self: *DiosixGui,
    px: i32,
    py: i32,
    left_down: bool,
) void {
    self.cursor.visible = true;
    self.cursor.x = px;
    self.cursor.y = py;
    self.mouse_left_down = left_down;

    if (!left_down) {
        self.active_drag_win_id = null;
    }

    if (self.active_drag_win_id) |drag_win_id| {
        var idx: usize = 0;
        while (idx < self.windows.items.len) : (idx += 1) {
            const wid = self.windows.items[idx].id;
            if (!self.windows.items[idx].is_onscreen) continue;
            if (wid == drag_win_id) {
                const moved = self.windows.items[idx].handleMouseMove(
                    self,
                    px,
                    py,
                    left_down,
                );
                if (moved) {
                    if (self.getWindow(wid)) |w| self.markDirty(w.getBox());
                }
            } else if (self.windows.items[idx].clearHover()) {
                self.markDirty(self.windows.items[idx].getBox());
            }
        }
    } else {
        const top_win_id = if (findWindowAt(self, px, py)) |w| w.id else null;
        var idx: usize = 0;
        while (idx < self.windows.items.len) : (idx += 1) {
            const wid = self.windows.items[idx].id;
            if (!self.windows.items[idx].is_onscreen) continue;
            if (top_win_id != null and top_win_id.? == wid) {
                const moved = self.windows.items[idx].handleMouseMove(
                    self,
                    px,
                    py,
                    left_down,
                );
                if (moved) {
                    if (self.getWindow(wid)) |w| self.markDirty(w.getBox());
                }
            } else if (self.windows.items[idx].clearHover()) {
                self.markDirty(self.windows.items[idx].getBox());
            }
        }
        if (top_win_id == WIN_GUEST_DISPLAY_ID or
            self.desktop.pointer_buttons != 0)
        {
            gui_mod.panes.handleDesktopPointerMove(self, px, py);
        }
    }

    updateActiveHelp(self);
}

pub fn handleMouseClick(self: *DiosixGui, px: i32, py: i32) void {
    self.cursor.visible = true;
    self.cursor.x = px;
    self.cursor.y = py;

    if (self.getWindow(gui_mod.WIN_SCHEME_DROPDOWN_ID)) |drop_win| {
        if (!drop_win.contains(px, py)) {
            var hit_trigger = false;
            if (self.getWindow(gui_mod.WIN_CONFIG_ID)) |cfg_win| {
                const wy = cfg_win.y - cfg_win.scroll_y;
                const drop_ids = [_]u32{
                    gui_mod.ICON_CONFIG_SCHEME_DROPDOWN_ID,
                    gui_mod.ICON_CONFIG_RES_DROPDOWN_ID,
                    gui_mod.ICON_CONFIG_DEPTH_DROPDOWN_ID,
                    gui_mod.ICON_CONFIG_SCALE_DROPDOWN_ID,
                };
                for (drop_ids) |did| {
                    if (cfg_win.getIconById(did)) |ic| {
                        if (ic.hitTest(cfg_win.x, wy, px, py)) {
                            hit_trigger = true;
                            break;
                        }
                    }
                }
            }
            if (!hit_trigger) {
                self.closeSchemeDropdown();
            }
        }
    }

    if (findWindowAt(self, px, py)) |top_win| {
        if (top_win.id == WIN_GUEST_DISPLAY_ID and
            top_win.findIconAt(px, py) == null and
            gui_mod.panes.handleDesktopMouseButton(
                self,
                px,
                py,
                BTN_LEFT,
                true,
            ))
        {
            focusWindowById(self, WIN_GUEST_DISPLAY_ID);
            if (self.getWindow(WIN_GUEST_DISPLAY_ID)) |dw| {
                dw.setFocusedIndex(null);
            }
            for (self.windows.items) |*other| {
                if (other.id != WIN_GUEST_DISPLAY_ID) {
                    if (other.handleMouseRelease()) {
                        self.markDirty(other.getBox());
                    }
                    if (other.clearHover()) {
                        self.markDirty(other.getBox());
                    }
                }
            }
            updateActiveHelp(self);
            return;
        }
    }

    var hit_any_win = false;
    var i = self.windows.items.len;
    while (i > 0) : (i -= 1) {
        const win_idx = i - 1;
        const win = &self.windows.items[win_idx];
        if (win.is_onscreen and win.contains(px, py)) {
            hit_any_win = true;
            const clicked_win_id = win.id;
            const old_box = win.getBox();
            if (win.hasInteractiveIcons() or win.isScrollable()) {
                focusWindow(self, win_idx);
            }
            if (self.getWindow(clicked_win_id)) |target_win| {
                _ = target_win.handleMouseClick(self, px, py);
            }
            if (self.getWindow(clicked_win_id)) |after_win| {
                if (after_win.active_drag_icon_idx != null or
                    after_win.is_dragging_scrollbar)
                {
                    self.active_drag_win_id = after_win.id;
                } else {
                    self.active_drag_win_id = null;
                }
                self.markDirty(after_win.getBox());
            } else {
                self.active_drag_win_id = null;
                self.markDirty(old_box);
            }

            for (self.windows.items) |*other| {
                if (other.id != clicked_win_id) {
                    if (other.handleMouseRelease()) {
                        self.markDirty(other.getBox());
                    }
                    if (other.clearHover()) {
                        self.markDirty(other.getBox());
                    }
                }
            }
            break;
        }
    }

    if (!hit_any_win) {
        self.active_drag_win_id = null;
        for (self.windows.items) |*win| {
            if (win.handleMouseRelease()) {
                self.markDirty(win.getBox());
            }
            if (win.clearHover()) {
                self.markDirty(win.getBox());
            }
        }
    }
    updateActiveHelp(self);
}

pub fn handleAuxMouseButton(
    self: *DiosixGui,
    px: i32,
    py: i32,
    btn_code: u16,
    pressed: bool,
) void {
    self.cursor.visible = true;
    self.cursor.x = px;
    self.cursor.y = py;
    if (!pressed) {
        _ = gui_mod.panes.handleDesktopMouseRelease(self, btn_code);
        return;
    }
    if (findWindowAt(self, px, py)) |top_win| {
        if (top_win.id == WIN_GUEST_DISPLAY_ID and
            top_win.findIconAt(px, py) == null)
        {
            if (gui_mod.panes.handleDesktopMouseButton(
                self,
                px,
                py,
                btn_code,
                true,
            )) {
                focusWindowById(self, WIN_GUEST_DISPLAY_ID);
            }
        }
    }
}

pub fn handleMouseScroll(
    self: *DiosixGui,
    px: i32,
    py: i32,
    delta: i32,
) void {
    self.cursor.visible = true;
    self.cursor.x = px;
    self.cursor.y = py;
    if (findWindowAt(self, px, py)) |top_win| {
        if (top_win.id == WIN_GUEST_DISPLAY_ID and
            gui_mod.panes.handleDesktopScroll(self, px, py, delta))
        {
            return;
        }
    }
    var i = self.windows.items.len;
    while (i > 0) : (i -= 1) {
        const win = &self.windows.items[i - 1];
        if (win.is_onscreen and win.contains(px, py)) {
            if (win.handleScroll(delta * 30)) {
                self.markDirty(win.getBox());
            }
            return;
        }
    }
    if (getActiveWindow(self)) |win| {
        if (win.handleScroll(delta * 30)) {
            self.markDirty(win.getBox());
        }
    }
}

pub fn focusWindow(self: *DiosixGui, target_idx: usize) void {
    if (self.active_win_idx) |old_idx| {
        if (old_idx < self.windows.items.len) {
            const old_win = &self.windows.items[old_idx];
            old_win.is_active = false;
            if (old_win.is_onscreen) self.markDirty(old_win.getBox());
        }
    }
    for (self.windows.items, 0..) |*win, idx| {
        win.is_active = (idx == target_idx);
        if (idx == target_idx and win.is_onscreen) {
            self.markDirty(win.getBox());
        }
    }
    self.active_win_idx = target_idx;
}

pub fn focusWindowById(self: *DiosixGui, win_id: u32) void {
    for (self.windows.items, 0..) |*win, idx| {
        if (win.id == win_id) {
            focusWindow(self, idx);
            break;
        }
    }
}

pub fn getActiveWindow(self: *DiosixGui) ?*Window {
    if (self.active_win_idx) |idx| {
        if (idx < self.windows.items.len) return &self.windows.items[idx];
    }
    return null;
}

pub fn confirmPowerModal(self: *DiosixGui) void {
    self.power_action_confirmed = true;
    const action = self.power_modal_action orelse return;
    if (self.findIcon(WIN_POWER_MODAL_ID, ICON_POWER_MSG1_ID)) |msg| {
        const txt = if (action == .restart)
            "Restarting host system..."
        else
            "Shutting down host system...";
        msg.setText(txt);
    }
    if (self.findIcon(WIN_POWER_MODAL_ID, ICON_POWER_MSG2_ID)) |msg| {
        msg.setText("Halting guest domains and flushing buffers.");
    }
    self.markWindowDirty(WIN_POWER_MODAL_ID);
    host_info.executePowerAction(action);
}

test {
    std.testing.refAllDecls(@This());
    _ = json;
}
