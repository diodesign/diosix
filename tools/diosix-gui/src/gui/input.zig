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

const WIN_HELP_ID = gui_mod.WIN_HELP_ID;
const WIN_VM_FLEET_ID = gui_mod.WIN_VM_FLEET_ID;
const WIN_VM_DRAWER_ID = gui_mod.WIN_VM_DRAWER_ID;
const WIN_POWER_MODAL_ID = gui_mod.WIN_POWER_MODAL_ID;
const WIN_OSK_ID = gui_mod.WIN_OSK_ID;
const WIN_WELCOME_ID = gui_mod.WIN_WELCOME_ID;
const WIN_TOUR_ID = gui_mod.WIN_TOUR_ID;

const ICON_MENU_SOFTWARE_ID = gui_mod.ICON_MENU_SOFTWARE_ID;
const ICON_MENU_HARDWARE_ID = gui_mod.ICON_MENU_HARDWARE_ID;
const ICON_MENU_ABOUT_ID = gui_mod.ICON_MENU_ABOUT_ID;
const ICON_MENU_CONFIG_ID = gui_mod.ICON_MENU_CONFIG_ID;
const ICON_HELP_TEXT_ID = gui_mod.ICON_HELP_TEXT_ID;
const ICON_POWER_MSG1_ID = gui_mod.ICON_POWER_MSG1_ID;
const ICON_POWER_MSG2_ID = gui_mod.ICON_POWER_MSG2_ID;
const FALLBACK_HELP_TEXT = gui_mod.DiosixGui.FALLBACK_HELP_TEXT;

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
        for (self.windows.items) |*win| {
            if (!win.is_onscreen) continue;
            if (win.id == drag_win_id) {
                if (win.handleMouseMove(self, px, py, left_down)) {
                    self.markDirty(win.getBox());
                }
            } else if (win.clearHover()) {
                self.markDirty(win.getBox());
            }
        }
    } else {
        var top_win_idx: ?usize = null;
        var i = self.windows.items.len;
        while (i > 0) : (i -= 1) {
            const win_idx = i - 1;
            const win = &self.windows.items[win_idx];
            if (win.is_onscreen and win.contains(px, py)) {
                top_win_idx = win_idx;
                break;
            }
        }

        for (self.windows.items, 0..) |*win, idx| {
            if (!win.is_onscreen) continue;
            if (top_win_idx != null and top_win_idx.? == idx) {
                if (win.handleMouseMove(self, px, py, left_down)) {
                    self.markDirty(win.getBox());
                }
            } else if (win.clearHover()) {
                self.markDirty(win.getBox());
            }
        }
    }

    updateActiveHelp(self);
}

pub fn handleMouseClick(self: *DiosixGui, px: i32, py: i32) void {
    self.cursor.visible = true;
    self.cursor.x = px;
    self.cursor.y = py;
    var hit_any_win = false;
    var i = self.windows.items.len;
    while (i > 0) : (i -= 1) {
        const win_idx = i - 1;
        const win = &self.windows.items[win_idx];
        if (win.is_onscreen and win.contains(px, py)) {
            hit_any_win = true;
            if (win.hasInteractiveIcons() or win.isScrollable()) {
                focusWindow(self, win_idx);
            }
            _ = win.handleMouseClick(self, px, py);
            if (win.active_drag_icon_idx != null or
                win.is_dragging_scrollbar)
            {
                self.active_drag_win_id = win.id;
            } else {
                self.active_drag_win_id = null;
            }
            self.markDirty(win.getBox());

            for (self.windows.items, 0..) |*other, other_idx| {
                if (other_idx != win_idx) {
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

pub fn handleMouseScroll(
    self: *DiosixGui,
    px: i32,
    py: i32,
    delta: i32,
) void {
    self.cursor.visible = true;
    self.cursor.x = px;
    self.cursor.y = py;
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

pub fn selectVm(self: *DiosixGui, vm_id: u32) void {
    self.selected_vm_id = vm_id;

    if (self.getWindow(WIN_VM_FLEET_ID)) |win_fleet| {
        for (win_fleet.icons.items) |*icon| {
            if (icon.icon_type == .slate_card) {
                icon.setSelected(icon.id == vm_id);
            }
        }
        self.markDirty(win_fleet.getBox());
    }

    if (self.getWindow(WIN_VM_DRAWER_ID)) |win_drawer| {
        const x = win_drawer.x;
        const y = win_drawer.y;
        const w = win_drawer.width;
        const h = win_drawer.height;
        self.buildVmActionDrawer(x, y, w, h) catch {};
        self.markWindowDirty(WIN_VM_DRAWER_ID);
    }
}

pub fn handleVmAction(self: *DiosixGui, action_icon_id: u32) void {
    const msg: ?[]const u8 = switch (action_icon_id) {
        gui_mod.ICON_VM_CREATE_NEW_ID =>
        // Create VM wizard help message.
        "Launch Create VM Wizard: Select a manifest or image",
        gui_mod.ICON_DRAWER_BTN_STOP_ID =>
        // ACPI stop help message.
        "ACPI shutdown signal dispatched to guest",
        gui_mod.ICON_DRAWER_BTN_PAUSE_ID =>
        // Pause VM help message.
        "Guest virtual CPU execution paused",
        gui_mod.ICON_DRAWER_BTN_SNAP_ID =>
        // Snapshot help message.
        "Snapshot taken: RAM and disk checkpoint saved",
        gui_mod.ICON_DRAWER_BTN_CONSOLE_ID =>
        // Serial console help message.
        "Virtual serial console bridge connected",
        gui_mod.ICON_DRAWER_BTN_KILL_ID => "SIGKILL sent to guest VM container",
        gui_mod.ICON_DRAWER_BTN_START_ID => "Guest virtual machine booted",
        gui_mod.ICON_DRAWER_BTN_RESTORE_ID =>
        // Restore snapshot help message.
        "Snapshot restored to running state",
        gui_mod.ICON_DRAWER_BTN_CLONE_ID =>
        // Clone snapshot help message.
        "Cloned snapshot to new VM instance",
        gui_mod.ICON_DRAWER_BTN_DELETE_ID =>
        // Delete snapshot help message.
        "Item removed and storage reclaimed",
        else => null,
    };
    if (msg) |m| {
        if (self.findIcon(WIN_HELP_ID, ICON_HELP_TEXT_ID)) |h| {
            h.setText(m);
            self.markWindowDirty(WIN_HELP_ID);
        }
    }
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

pub fn triggerSemanticAction(self: *DiosixGui, action: []const u8) !bool {
    const SemAct = gui_mod.SemanticAction;
    const act = std.meta.stringToEnum(SemAct, action) orelse return false;
    switch (act) {
        .@"menu.software" => {
            try self.activateMenuItem(ICON_MENU_SOFTWARE_ID);
            self.completeNavAnimation();
        },
        .@"menu.hardware" => {
            try self.activateMenuItem(ICON_MENU_HARDWARE_ID);
            self.completeNavAnimation();
        },
        .@"menu.about", .@"menu.status" => {
            try self.activateMenuItem(ICON_MENU_ABOUT_ID);
            self.completeNavAnimation();
        },
        .@"menu.config" => {
            try self.activateMenuItem(ICON_MENU_CONFIG_ID);
            self.completeNavAnimation();
        },
        .@"menu.back" => {
            try self.navigateBack();
            self.completeNavAnimation();
        },
        .@"osk.toggle" => try self.toggleOsk(),
        .@"osk.show" => {
            self.osk_state.visible = true;
            try self.buildOskWindow();
        },
        .@"osk.hide" => {
            self.osk_state.visible = false;
            _ = self.destroyWindow(WIN_OSK_ID);
            self.markFullDirty();
        },
        .@"welcome.open" => try self.showWelcomeModal(),
        .@"welcome.close" => {
            self.welcome_state.closeWelcome();
            _ = self.destroyWindow(WIN_WELCOME_ID);
            self.markFullDirty();
        },
        .@"tour.start" => {
            self.welcome_state.startTour();
            try self.showTourModal();
        },
        .@"tour.next" => {
            self.welcome_state.nextStep();
            if (self.welcome_state.tour_visible) {
                try self.showTourModal();
            } else {
                _ = self.destroyWindow(WIN_TOUR_ID);
                self.markFullDirty();
            }
        },
        .@"tour.prev" => {
            self.welcome_state.prevStep();
            if (self.welcome_state.tour_visible) {
                try self.showTourModal();
            }
        },
        .@"tour.close" => {
            self.welcome_state.closeTour();
            _ = self.destroyWindow(WIN_TOUR_ID);
            self.markFullDirty();
        },
    }
    return true;
}

/// Escape '"' and '\' in an OSK input string for safe JSON emission.
fn escapeJsonStr(raw: []const u8, out: []u8) []const u8 {
    var pos: usize = 0;
    for (raw) |c| {
        if (c == '"' or c == '\\') {
            if (pos + 2 > out.len) break;
            out[pos] = '\\';
            out[pos + 1] = c;
            pos += 2;
        } else if (c >= 0x20 and c <= 0x7e) {
            if (pos + 1 > out.len) break;
            out[pos] = c;
            pos += 1;
        }
    }
    return out[0..pos];
}

pub fn exportSemanticStateJson(self: *const DiosixGui, buf: []u8) []const u8 {
    const active_pane: []const u8 = if (self.active_menu_id) |mid|
        switch (mid) {
            ICON_MENU_SOFTWARE_ID => "software",
            ICON_MENU_HARDWARE_ID => "hardware",
            ICON_MENU_ABOUT_ID => "about",
            ICON_MENU_CONFIG_ID => "config",
            else => "submenu",
        }
    else
        "fleet";

    var esc_buf: [256]u8 = undefined;
    const esc_osk = escapeJsonStr(self.osk_state.getInputText(), &esc_buf);
    const fmt =
        "{{\"width\":{d},\"height\":{d},\"render_mode\":\"{s}\"," ++
        "\"active_pane\":\"{s}\",\"window_count\":{d}," ++
        "\"selected_vm_id\":{d},\"osk_visible\":{s}," ++
        "\"osk_layout\":\"{s}\",\"osk_input\":\"{s}\"," ++
        "\"welcome_visible\":{s},\"tour_visible\":{s},\"tour_step\":{d}}}\n";

    return std.fmt.bufPrint(buf, fmt, .{
        self.width,
        self.height,
        if (self.render_mode == .accelerated) "accelerated" else "degraded",
        active_pane,
        self.windows.items.len,
        self.selected_vm_id,
        if (self.osk_state.visible) "true" else "false",
        self.osk_state.layout.label(),
        esc_osk,
        if (self.welcome_state.welcome_visible) "true" else "false",
        if (self.welcome_state.tour_visible) "true" else "false",
        self.welcome_state.current_step + 1,
    }) catch "";
}
