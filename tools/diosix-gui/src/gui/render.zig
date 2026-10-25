// Diosix GUI Window Lifecycle, Queries, and Damage-Tracked Render Pipeline.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("../framebuffer.zig");
const icon_mod = @import("../icon.zig");
const Icon = icon_mod.Icon;
const window_mod = @import("../window.zig");
const Window = window_mod.Window;
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;

const WIN_MENU_ID = gui_mod.WIN_MENU_ID;
const WIN_STATUS_ID = gui_mod.WIN_STATUS_ID;
const ICON_MENU_STATUS_ID = gui_mod.ICON_MENU_STATUS_ID;

pub fn createWindow(
    self: *DiosixGui,
    id: u32,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    title: ?[]const u8,
) !*Window {
    _ = destroyWindow(self, id);

    var win = Window.init(self.allocator, id, x, y, width, height, title);
    win.setOnScreen(true);
    gui_mod.panes.clampWindowToTaskStack(self, &win);
    try self.windows.append(self.allocator, win);
    const idx = self.windows.items.len - 1;
    self.markDirty(self.windows.items[idx].getBox());
    return &self.windows.items[idx];
}

pub fn destroyWindow(self: *DiosixGui, id: u32) bool {
    for (self.windows.items, 0..) |*win, idx| {
        if (win.id == id) {
            if (win.linked_menu_item_id) |mid| {
                setMenuItemSelected(self, mid, false);
            }
            if (win.parent_window_id) |pid| {
                if (getWindow(self, pid)) |pwin| {
                    if (pwin.child_window_id == id) {
                        pwin.child_window_id = null;
                    }
                }
            }
            if (win.is_onscreen) {
                self.markDirty(win.getBox());
            }
            win.deinit();
            _ = self.windows.orderedRemove(idx);
            if (self.active_drag_win_id == id) {
                self.active_drag_win_id = null;
            }
            if (self.active_win_idx) |act_idx| {
                if (act_idx == idx) {
                    self.active_win_idx = null;
                    if (self.windows.items.len > 0) {
                        self.focusWindow(
                            @min(idx, self.windows.items.len - 1),
                        );
                    }
                } else if (act_idx > idx) {
                    self.active_win_idx = act_idx - 1;
                }
            }
            return true;
        }
    }
    return false;
}

pub fn destroyAllWindows(self: *DiosixGui) void {
    for (self.windows.items) |*win| {
        win.deinit();
    }
    self.windows.clearRetainingCapacity();
    self.active_win_idx = null;
    self.active_drag_win_id = null;
    self.markFullDirty();
}

pub fn getWindow(self: *DiosixGui, id: u32) ?*Window {
    for (self.windows.items) |*win| {
        if (win.id == id) return win;
    }
    return null;
}

pub fn setWindowOnScreen(self: *DiosixGui, win_id: u32, on: bool) void {
    for (self.windows.items) |*win| {
        if (win.id == win_id) {
            const was_on = win.is_onscreen;
            win.setOnScreen(on);
            if (was_on != on) {
                self.markDirty(fb.Box.fromPosSize(
                    win.onscreen_x,
                    win.onscreen_y,
                    win.width,
                    win.height,
                ));
                if (win.linked_menu_item_id) |m_id| {
                    setMenuItemSelected(self, m_id, on);
                } else if (win_id == WIN_STATUS_ID) {
                    setStatusMenuSelected(self, on);
                }
            }
            break;
        }
    }
}

pub fn setMenuItemSelected(
    self: *DiosixGui,
    menu_item_id: u32,
    selected: bool,
) void {
    if (getWindow(self, WIN_MENU_ID)) |mw| {
        if (mw.getIconById(menu_item_id)) |icon| {
            if (icon.is_selected != selected) {
                icon.setSelected(selected);
                self.markDirty(mw.getBox());
            }
        }
    }
}

pub fn setStatusMenuSelected(self: *DiosixGui, selected: bool) void {
    setMenuItemSelected(self, ICON_MENU_STATUS_ID, selected);
}

pub fn findIcon(self: *DiosixGui, win_id: u32, icon_id: u32) ?*Icon {
    for (self.windows.items) |*win| {
        if (win.id == win_id) {
            if (win.is_onscreen) self.markDirty(win.getBox());
            return win.getIconById(icon_id);
        }
    }
    return null;
}

fn renderWindowOnSurface(
    self: *DiosixGui,
    surface: *fb.Surface,
    win: *Window,
    win_alpha: u8,
) void {
    if (win.id == gui_mod.WIN_SCHEME_DROPDOWN_ID) {
        win.render(surface, getPopupOpacityAlpha(self));
        return;
    }
    win.render(surface, win_alpha);
}

pub fn renderDamaged(self: *DiosixGui, clean_surface: *fb.Surface) fb.Box {
    const empty = fb.Box{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
    if (self.dirty_box.isEmpty()) return empty;

    const screen_box = fb.Box.fromPosSize(0, 0, self.width, self.height);
    const damage = self.dirty_box.intersect(screen_box);
    self.dirty_box = empty;

    if (damage.isEmpty()) return empty;

    const win_alpha = self.getWindowOpacityAlpha();

    const is_full_screen = (damage.x0 == 0 and damage.y0 == 0 and
        damage.x1 == @as(i32, @intCast(self.width)) and
        damage.y1 == @as(i32, @intCast(self.height)));

    const is_accel = (self.render_mode == .accelerated);
    const dx = if (is_accel) self.drift_x else 0;
    const dy = if (is_accel) self.drift_y else 0;

    if (is_full_screen) {
        clean_surface.drawGraduatedBackgroundDrift(
            self.bg_top_color,
            self.bg_bot_color,
            dx,
            dy,
        );
        for (self.windows.items) |*win| {
            if (win.is_onscreen) {
                renderWindowOnSurface(
                    self,
                    clean_surface,
                    win,
                    win_alpha,
                );
            }
        }
    } else {
        clean_surface.drawGraduatedBackgroundInBoxDrift(
            damage,
            self.bg_top_color,
            self.bg_bot_color,
            dx,
            dy,
        );
        for (self.windows.items) |*win| {
            if (win.is_onscreen and win.intersectsBox(damage)) {
                renderWindowOnSurface(
                    self,
                    clean_surface,
                    win,
                    win_alpha,
                );
            }
        }
    }

    return damage;
}

pub fn render(self: *DiosixGui, surface: *fb.Surface) void {
    self.markFullDirty();
    _ = renderDamaged(self, surface);
    if (self.cursor.visible) {
        self.cursor.draw(surface);
    }
}

pub fn drawWindowsWithAlpha(
    self: *DiosixGui,
    surface: *fb.Surface,
    alpha_factor: f32,
) void {
    const base_f = @as(f32, @floatFromInt(getWindowOpacityAlpha(self)));
    const win_alpha: u8 =
        @intFromFloat(base_f * std.math.clamp(alpha_factor, 0.0, 1.0));
    for (self.windows.items) |*win| {
        if (win.is_onscreen) {
            renderWindowOnSurface(
                self,
                surface,
                win,
                win_alpha,
            );
        }
    }
}

pub fn setWindowTransparency(self: *DiosixGui, pct: u32) void {
    const clamped = std.math.clamp(pct, 0, 100);
    if (self.window_transparency != clamped) {
        self.window_transparency = clamped;
        self.markFullDirty();
    }
}

pub fn getWindowOpacityAlpha(self: *const DiosixGui) u8 {
    const opacity_pct: u32 = if (self.window_transparency >= 100)
        0
    else
        (100 - self.window_transparency);
    return @intCast((opacity_pct * 255) / 100);
}

/// Returns the opacity alpha for context/dropdown popup menus, which are
/// 20% as transparent as normal window panes (`window_transparency / 5`).
pub fn getPopupOpacityAlpha(self: *const DiosixGui) u8 {
    const popup_trans = @min(@as(u32, 100), self.window_transparency / 5);
    const opacity_pct: u32 = 100 - popup_trans;
    return @intCast((opacity_pct * 255) / 100);
}

pub fn setBackdropTopColor(self: *DiosixGui, col: u32) void {
    if (self.bg_top_color != col) {
        self.bg_top_color = col;
        if (fb.BackdropScheme.fromTopColor(col)) |s| {
            self.bg_scheme = s;
        }
        self.markFullDirty();
    }
}

pub fn setBackdropBotColor(self: *DiosixGui, col: u32) void {
    if (self.bg_bot_color != col) {
        self.bg_bot_color = col;
        self.markFullDirty();
    }
}

pub fn setBackdropScheme(self: *DiosixGui, scheme: fb.BackdropScheme) void {
    self.bg_scheme = scheme;
    self.bg_top_color = scheme.topColor();
    if (findIcon(
        self,
        gui_mod.WIN_CONFIG_ID,
        gui_mod.ICON_CONFIG_SCHEME_DROPDOWN_ID,
    )) |ic| {
        ic.setText(scheme.label());
    }
    self.markFullDirty();
}

pub fn getBackdropScheme(self: *const DiosixGui) fb.BackdropScheme {
    return self.bg_scheme;
}

pub fn setPhysicalDimensions(
    self: *DiosixGui,
    mm_w: u32,
    mm_h: u32,
) !void {
    self.mm_width = mm_w;
    self.mm_height = mm_h;
    if (self.ui_scale_mode == .auto) {
        try relayoutAllWindows(self);
    }
}

pub fn setResolutionPreset(
    self: *DiosixGui,
    preset: gui_mod.ResolutionPreset,
) !void {
    const new_w = preset.width();
    const new_h = preset.height();

    self.resolution_preset = preset;
    self.width = new_w;
    self.height = new_h;
    self.cursor.x = std.math.clamp(
        self.cursor.x,
        0,
        @as(i32, @intCast(new_w -| 1)),
    );
    self.cursor.y = std.math.clamp(
        self.cursor.y,
        0,
        @as(i32, @intCast(new_h -| 1)),
    );
    self.display_reconfig_pending = true;
    try relayoutAllWindows(self);
}

pub fn setColorDepth(self: *DiosixGui, depth: gui_mod.ColorDepth) void {
    self.color_depth = depth;
    self.display_reconfig_pending = true;
    if (findIcon(
        self,
        gui_mod.WIN_CONFIG_ID,
        gui_mod.ICON_CONFIG_DEPTH_DROPDOWN_ID,
    )) |ic| {
        ic.setText(depth.label());
    }
    self.markFullDirty();
}

pub fn setUiScaleMode(self: *DiosixGui, mode: gui_mod.UiScaleMode) !void {
    self.ui_scale_mode = mode;
    try relayoutAllWindows(self);
}

pub fn relayoutAllWindows(self: *DiosixGui) !void {
    self.syncVectorScaleState();
    const saved_menu = self.active_menu_id;
    const saved_power = self.power_modal_action;
    const saved_welcome = self.welcome_state.welcome_visible;
    const saved_tour = self.welcome_state.tour_visible;
    const saved_osk = self.osk_state.visible;
    destroyAllWindows(self);
    self.active_menu_id = null;
    self.nav_anim_state = .idle;
    self.nav_anim_progress = 0.0;

    try self.buildMainMenu();
    try self.buildBottomPanes();
    try self.buildGuestsPane();
    if (saved_menu) |mid| {
        try self.activateMenuItem(mid);
        self.completeNavAnimation();
    }
    if (saved_power) |act| try self.showPowerModal(act);
    if (saved_welcome) try self.showWelcomeModal();
    if (saved_tour) try self.showTourModal();
    if (saved_osk) try self.buildOskWindow();
    self.syncTaskPanes();
    self.updateActiveHelp();
    self.markFullDirty();
}

test {
    std.testing.refAllDecls(@This());
}
