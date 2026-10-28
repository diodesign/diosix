// Diosix GUI Menu Navigation, Animation, and Frame Tick Coordinator.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;
pub const chrome = @import("chrome.zig");

const BORDER_GAP = gui_mod.BORDER_GAP;
const WIN_MENU_ID = gui_mod.WIN_MENU_ID;
const WIN_BACK_ID = gui_mod.WIN_BACK_ID;
const WIN_STATUS_ID = gui_mod.WIN_STATUS_ID;

const ICON_MENU_CREATE_VM_ID = gui_mod.ICON_MENU_CREATE_VM_ID;
const ICON_MENU_ABOUT_ID = gui_mod.ICON_MENU_ABOUT_ID;
const ICON_MENU_CONFIG_ID = gui_mod.ICON_MENU_CONFIG_ID;
const ICON_MENU_RESTART_ID = gui_mod.ICON_MENU_RESTART_ID;
const ICON_MENU_SHUTDOWN_ID = gui_mod.ICON_MENU_SHUTDOWN_ID;

const MENU_FULL_H = gui_mod.MENU_FULL_H;
const MENU_CONTRACTED_H = gui_mod.MENU_CONTRACTED_H;

pub const MenuItemSpec = chrome.MenuItemSpec;
pub const MENU_ITEMS = chrome.MENU_ITEMS;
pub const getContextTitle = chrome.getContextTitle;
pub const buildMainMenu = chrome.buildMainMenu;
pub const repopulateMainMenu = chrome.repopulateMainMenu;
pub const contractMainMenu = chrome.contractMainMenu;
pub const buildBackPane = chrome.buildBackPane;
pub const buildBottomPanes = chrome.buildBottomPanes;

pub fn getChildTargetX(self: *DiosixGui) i32 {
    const menu_win = self.getWindow(WIN_MENU_ID);
    return if (menu_win) |mw|
        mw.x + @as(i32, @intCast(mw.width)) + BORDER_GAP
    else
        144;
}

pub fn getChildWindowId(self: *DiosixGui) ?u32 {
    const menu_win = self.getWindow(WIN_MENU_ID) orelse return null;
    return menu_win.child_window_id;
}

pub fn activateMenuItem(self: *DiosixGui, menu_item_id: u32) !void {
    _ = self.getWindow(WIN_MENU_ID) orelse return;

    if (menu_item_id == ICON_MENU_RESTART_ID) {
        try self.showPowerModal(.restart);
        return;
    }
    if (menu_item_id == ICON_MENU_SHUTDOWN_ID) {
        try self.showPowerModal(.shutdown);
        return;
    }

    if (self.nav_anim_state == .closing) {
        finishClosing(self);
    }

    if (self.active_menu_id == menu_item_id) return;

    if (self.active_menu_id != null) {
        teardownChildPanes(self);
    }

    const had_guests = self.getWindow(gui_mod.WIN_GUESTS_ID) != null;
    _ = self.destroyWindow(gui_mod.WIN_GUEST_DETAIL_ID);
    _ = self.destroyWindow(gui_mod.WIN_GUESTS_ID);

    switch (menu_item_id) {
        ICON_MENU_CREATE_VM_ID => try self.buildCreateVmPane(),
        ICON_MENU_ABOUT_ID => try self.buildStatusPane(),
        ICON_MENU_CONFIG_ID => try self.buildConfigPane(),
        gui_mod.ICON_MENU_TERMINAL_ID => try self.buildTerminalWindow(),
        else => {},
    }

    try buildBackPane(self);
    try contractMainMenu(self, menu_item_id);
    self.active_menu_id = menu_item_id;

    if (had_guests and menu_item_id == gui_mod.ICON_MENU_TERMINAL_ID) {
        try self.buildGuestsPane();
    }

    self.nav_anim_state = .opening;
    self.nav_anim_progress = 0.0;
    applyNavAnimation(self);
    self.updateActiveHelp();
}

pub fn navigateBack(self: *DiosixGui) !void {
    if (self.nav_anim_state == .closing) return;
    if (self.active_menu_id == null and self.nav_anim_state == .idle) return;

    if (self.active_menu_id == gui_mod.ICON_MENU_TERMINAL_ID) {
        gui_mod.panes.onTerminalNavigateBack(self);
    }

    try repopulateMainMenu(self);
    if (self.getWindow(gui_mod.WIN_GUESTS_ID) == null) {
        try self.buildGuestsPane();
    }

    self.nav_anim_state = .closing;
    self.nav_anim_progress = 1.0;
    applyNavAnimation(self);
    self.updateActiveHelp();
}

pub fn finishOpening(self: *DiosixGui) void {
    _ = self.destroyWindow(gui_mod.WIN_GUEST_DETAIL_ID);
    _ = self.destroyWindow(gui_mod.WIN_GUESTS_ID);
    self.nav_anim_state = .idle;
}

pub fn finishClosing(self: *DiosixGui) void {
    teardownChildPanes(self);
    if (self.getWindow(gui_mod.WIN_GUESTS_ID) == null) {
        self.buildGuestsPane() catch {};
    }
}

pub fn completeNavAnimation(self: *DiosixGui) void {
    if (self.nav_anim_state == .idle) return;
    if (self.nav_anim_state == .opening) {
        self.nav_anim_progress = 1.0;
        applyNavAnimation(self);
        finishOpening(self);
    } else if (self.nav_anim_state == .closing) {
        self.nav_anim_progress = 0.0;
        applyNavAnimation(self);
        finishClosing(self);
    }
    self.updateActiveHelp();
}

pub fn applyNavAnimation(self: *DiosixGui) void {
    const factor = gui_mod.easeOutCubic(self.nav_anim_progress);

    if (self.getWindow(WIN_MENU_ID)) |win_menu| {
        const old_box = win_menu.getBox();
        const full_h = self.scalePx(MENU_FULL_H);
        const contracted_h = self.scalePx(MENU_CONTRACTED_H);
        const span = @as(f32, @floatFromInt(full_h -| contracted_h));
        const full_f = @as(f32, @floatFromInt(full_h));
        const border_2x = @as(u32, @intCast(BORDER_GAP * 2));
        const max_avail_h = if (self.height > border_2x)
            self.height - border_2x
        else
            self.height;
        const raw_h: u32 = @intFromFloat(full_f - span * factor);
        win_menu.height = @min(raw_h, max_avail_h);
        win_menu.natural_height = win_menu.height;
        win_menu.scroll_y = 0;
        win_menu.scrollbar_alpha = 0;
        const new_box = win_menu.getBox();
        self.markDirty(old_box.merge(new_box));
    }

    if (self.getWindow(WIN_BACK_ID)) |win_back| {
        const old_box = win_back.getBox();
        const off_x: i32 = -@as(i32, @intCast(win_back.width)) - 20;
        const on_x: i32 = BORDER_GAP;
        const cur_x: i32 = @intFromFloat(
            @as(f32, @floatFromInt(off_x)) +
                @as(f32, @floatFromInt(on_x - off_x)) * factor,
        );
        win_back.x = cur_x;
        win_back.onscreen_x = cur_x;
        const new_box = win_back.getBox();
        self.markDirty(old_box.merge(new_box));
    }

    if (getChildWindowId(self)) |cid| {
        if (self.getWindow(cid)) |cwin| {
            const old_box = cwin.getBox();
            const target_x = getChildTargetX(self);
            const offset: f32 = 80.0 * (1.0 - factor);
            const cur_x: i32 = @intFromFloat(
                @as(f32, @floatFromInt(target_x)) + offset,
            );
            cwin.x = cur_x;
            cwin.onscreen_x = cur_x;
            const new_box = cwin.getBox();
            self.markDirty(old_box.merge(new_box));
        }
    }

    const geom = gui_mod.panes.computeGuestPaneGeometry(self);
    if (self.getWindow(gui_mod.WIN_CREATE_VM_DETAIL_ID)) |cdwin| {
        const old_box = cdwin.getBox();
        const offset: f32 = 80.0 * (1.0 - factor);
        const cur_x: i32 = @intFromFloat(
            @as(f32, @floatFromInt(geom.detail_x)) + offset,
        );
        cdwin.x = cur_x;
        cdwin.onscreen_x = cur_x;
        self.markDirty(old_box.merge(cdwin.getBox()));
    }
    const slide_out: i32 = @intFromFloat(
        @as(f32, @floatFromInt(self.width)) * factor,
    );
    if (self.getWindow(gui_mod.WIN_GUESTS_ID)) |gwin| {
        const old_box = gwin.getBox();
        const cur_x = geom.guests_x + slide_out;
        gwin.x = cur_x;
        gwin.onscreen_x = cur_x;
        self.markDirty(old_box.merge(gwin.getBox()));
    }
    if (self.getWindow(gui_mod.WIN_GUEST_DETAIL_ID)) |dwin| {
        const old_box = dwin.getBox();
        const cur_x = geom.detail_x + slide_out;
        dwin.x = cur_x;
        dwin.onscreen_x = cur_x;
        self.markDirty(old_box.merge(dwin.getBox()));
    }
}

pub fn teardownChildPanes(self: *DiosixGui) void {
    if (self.active_menu_id == gui_mod.ICON_MENU_TERMINAL_ID) {
        gui_mod.panes.onTerminalNavigateBack(self);
    }
    var child_id: ?u32 = null;
    if (self.getWindow(WIN_MENU_ID)) |head| {
        child_id = head.child_window_id;
    }

    if (child_id) |cid| {
        if (self.getWindow(cid)) |cwin| {
            self.markDirty(cwin.getBox());
        }
        _ = self.destroyWindow(cid);
    }

    if (self.getWindow(gui_mod.WIN_CREATE_VM_DETAIL_ID)) |cdw| {
        self.markDirty(cdw.getBox());
        _ = self.destroyWindow(gui_mod.WIN_CREATE_VM_DETAIL_ID);
    }
    self.selected_create_image_idx = null;

    if (self.getWindow(gui_mod.WIN_SCHEME_DROPDOWN_ID)) |wd| {
        self.markDirty(wd.getBox());
        _ = self.destroyWindow(gui_mod.WIN_SCHEME_DROPDOWN_ID);
    }

    if (self.getWindow(WIN_BACK_ID)) |wb| {
        self.markDirty(wb.getBox());
        _ = self.destroyWindow(WIN_BACK_ID);
    }

    if (self.getWindow(WIN_MENU_ID)) |head| {
        head.child_window_id = null;
        head.height = self.scalePx(MENU_FULL_H);
    }

    repopulateMainMenu(self) catch {};
    self.active_menu_id = null;
    self.nav_anim_state = .idle;
    self.nav_anim_progress = 0.0;
    self.syncTaskPanes();
    self.updateActiveHelp();
    self.markFullDirty();
}

pub fn tick(self: *DiosixGui, dt_ms: u32) void {
    self.pollBackgroundTasks();
    self.pollTerminal();
    if (self.nav_anim_state != .idle) {
        const step =
            @as(f32, @floatFromInt(dt_ms)) / self.nav_anim_duration_ms;
        if (self.nav_anim_state == .opening) {
            self.nav_anim_progress += step;
            if (self.nav_anim_progress >= 1.0) {
                self.nav_anim_progress = 1.0;
                applyNavAnimation(self);
                finishOpening(self);
            } else {
                applyNavAnimation(self);
            }
        } else if (self.nav_anim_state == .closing) {
            self.nav_anim_progress -= step;
            if (self.nav_anim_progress <= 0.0) {
                self.nav_anim_progress = 0.0;
                applyNavAnimation(self);
                finishClosing(self);
            } else {
                applyNavAnimation(self);
            }
        }
    }

    self.uptime_accum_ms += dt_ms;
    if (self.uptime_accum_ms >= 1000) {
        self.uptime_accum_ms = 0;
        for (self.windows.items) |*win| {
            if (win.id == WIN_STATUS_ID and win.is_onscreen) {
                self.updateStatusPaneData();
                break;
            }
        }
    }

    self.guest_update_accum_ms += dt_ms;
    if (self.guest_update_accum_ms >= self.guest_update_interval_ms) {
        self.guest_update_accum_ms = 0;
        self.updateGuestsPaneData();
    }

    if (self.render_mode == .accelerated and self.bg_animation_speed > 0) {
        self.drift_accum_ms += dt_ms * self.bg_animation_speed;
        const threshold = gui_mod.DRIFT_INTERVAL_MS * 100;
        if (self.drift_accum_ms >= threshold) {
            const steps: i32 = @intCast(self.drift_accum_ms / threshold);
            self.drift_accum_ms %= threshold;
            switch (self.drift_dir) {
                .left => self.drift_x -%= steps,
                .right => self.drift_x +%= steps,
                .up => self.drift_y -%= steps,
                .down => self.drift_y +%= steps,
            }
            self.markFullDirty();
        }
    }
}

pub fn closePowerModal(self: *DiosixGui) void {
    _ = self.destroyWindow(gui_mod.WIN_POWER_MODAL_ID);
    self.power_modal_action = null;
    self.markFullDirty();
}

pub fn toggleStatusPane(self: *DiosixGui) !void {
    try self.activateMenuItem(gui_mod.ICON_MENU_STATUS_ID);
}

pub fn toggleConfigPane(self: *DiosixGui) !void {
    try self.activateMenuItem(ICON_MENU_CONFIG_ID);
}

pub fn toggleOsk(self: *DiosixGui) !void {
    self.osk_state.toggle();
    try self.buildOskWindow();
}

pub fn hasActiveAnimation(self: *const DiosixGui) bool {
    return self.nav_anim_state != .idle;
}

pub fn setBgAnimationSpeed(self: *DiosixGui, speed: u32) void {
    const clamped = std.math.clamp(speed, 0, 100);
    if (clamped == 0) self.drift_accum_ms = 0;
    self.bg_animation_speed = clamped;
}

pub fn getBgAnimationSpeed(self: *const DiosixGui) u32 {
    return self.bg_animation_speed;
}

pub fn setGuestUpdateIntervalSeconds(self: *DiosixGui, secs: u32) void {
    const clamped = std.math.clamp(secs, 1, 10);
    self.guest_update_interval_ms = clamped * 1000;
    self.guest_update_accum_ms = 0;
}

pub fn getGuestUpdateIntervalSeconds(self: *const DiosixGui) u32 {
    return @max(1, self.guest_update_interval_ms / 1000);
}

pub fn setDriftDirection(self: *DiosixGui, dir: gui_mod.DriftDirection) void {
    self.drift_dir = dir;
}

pub fn getDriftDirection(self: *const DiosixGui) gui_mod.DriftDirection {
    return self.drift_dir;
}

test {
    _ = @import("chrome.zig");
    std.testing.refAllDecls(@This());
}
