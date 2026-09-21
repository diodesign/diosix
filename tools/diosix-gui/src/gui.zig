// Monolithic Final Fantasy 7/8 Themed Dynamic GUI Coordinator for Diosix
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("framebuffer.zig");
const font = @import("font.zig");
const cursor_mod = @import("cursor.zig");
const icon_mod = @import("icon.zig");
const Icon = icon_mod.Icon;
const window_mod = @import("window.zig");
const Window = window_mod.Window;
const host_info = @import("host_info.zig");
const linux = std.os.linux;

pub const TAB_BAR_HEIGHT: u32 = 0;
pub const BORDER_GAP: i32 = 16;

// Standard Window & Icon IDs
pub const WIN_MENU_ID: u32 = 100;
pub const WIN_VERSION_ID: u32 = 101;
pub const WIN_BACK_ID: u32 = 102;
pub const WIN_HELP_ID: u32 = 103;
pub const WIN_STATUS_ID: u32 = 104;
pub const WIN_CONFIG_ID: u32 = 105;

pub const ICON_MENU_GUESTS_ID: u32 = 1001;
pub const ICON_MENU_STATUS_ID: u32 = 1002;
pub const ICON_MENU_CONFIG_ID: u32 = 1003;
pub const ICON_VERSION_TEXT_ID: u32 = 1011;
pub const ICON_BACK_BTN_ID: u32 = 1021;
pub const ICON_HELP_TEXT_ID: u32 = 1031;

pub const MENU_ITEM_HEIGHT: u32 = 28;
pub const MENU_ITEM_SPACING: u32 = 8;
pub const MENU_PAD_X: i32 = 16;
pub const MENU_TOP_PAD: i32 = 14;
pub const MENU_BOT_PAD: i32 = 14;
pub const MENU_FULL_H: u32 = 128;
pub const MENU_CONTRACTED_H: u32 = 56;
pub const BACK_PANE_H: u32 = 56;
pub const BACK_PANE_GAP: i32 = 12;
pub const BACK_PANE_Y: i32 = BORDER_GAP + @as(i32, @intCast(MENU_CONTRACTED_H)) + BACK_PANE_GAP;

pub const NavAnimState = enum {
    idle,
    opening,
    closing,
};

pub const DriftDirection = enum(u2) {
    left = 0,
    right = 1,
    up = 2,
    down = 3,
};

pub const DRIFT_INTERVAL_MS: u32 = 60; // Shift background texture by 1 pixel every 60ms (~16.6 px/sec)

pub fn easeOutCubic(t: f32) f32 {
    const clamped = std.math.clamp(t, 0.0, 1.0);
    const inv = 1.0 - clamped;
    return 1.0 - inv * inv * inv;
}

pub const ICON_STATUS_HOST_HDR_ID: u32 = 1040;
pub const ICON_STATUS_HOST_UPTIME_LABEL_ID: u32 = 1041;
pub const ICON_STATUS_HOST_UPTIME_ID: u32 = 1042;
pub const ICON_STATUS_HOST_CPU_LABEL_ID: u32 = 1043;
pub const ICON_STATUS_HOST_CPU_ID: u32 = 1044;
pub const ICON_STATUS_HOST_RAM_LABEL_ID: u32 = 1045;
pub const ICON_STATUS_HOST_RAM_ID: u32 = 1046;
pub const ICON_STATUS_HOST_TIME_LABEL_ID: u32 = 1047;
pub const ICON_STATUS_HOST_TIME_ID: u32 = 1048;
pub const ICON_STATUS_HV_HDR_ID: u32 = 1049;
pub const ICON_STATUS_HV_BUILD_LABEL_ID: u32 = 1050;
pub const ICON_STATUS_HV_BUILD1_ID: u32 = 1051;
pub const ICON_STATUS_HV_BUILD2_ID: u32 = 1052;
pub const ICON_STATUS_HV_FOOTPRINT_LABEL_ID: u32 = 1053;
pub const ICON_STATUS_HV_FOOTPRINT_ID: u32 = 1054;

pub const ICON_CONFIG_HDR_ID: u32 = 1060;
pub const ICON_CONFIG_TRANSPARENCY_LBL_ID: u32 = 1061;
pub const ICON_CONFIG_TRANSPARENCY_SLIDER_ID: u32 = 1062;
pub const ICON_CONFIG_BLUR_LBL_ID: u32 = 1063;
pub const ICON_CONFIG_BLUR_SLIDER_ID: u32 = 1064;
pub const ICON_CONFIG_THEME_LBL_ID: u32 = 1065;
pub const ICON_CONFIG_THEME_DAY_ID: u32 = 1066;
pub const ICON_CONFIG_THEME_MIDNIGHT_ID: u32 = 1067;
pub const ICON_CONFIG_THEME_SUNSET_ID: u32 = 1068;
pub const ICON_CONFIG_THEME_EMERALD_ID: u32 = 1069;
pub const ICON_CONFIG_ADMIN_LBL_ID: u32 = 1070;
pub const ICON_CONFIG_ADMIN_BTN_ID: u32 = 1071;
pub const ICON_CONFIG_SPEED_LBL_ID: u32 = 1072;
pub const ICON_CONFIG_SPEED_SLIDER_ID: u32 = 1073;

// Touch PIN Keypad Authentication Modal IDs
pub const WIN_PIN_MODAL_ID: u32 = 110;
pub const ICON_PIN_TITLE_ID: u32 = 1101;
pub const ICON_PIN_DISPLAY_ID: u32 = 1102;
pub const ICON_PIN_STATUS_ID: u32 = 1103;
pub const ICON_PIN_KEY_BASE_ID: u32 = 1110; // 1110..1119 for digits 0..9
pub const ICON_PIN_CLEAR_ID: u32 = 1120;
pub const ICON_PIN_SUBMIT_ID: u32 = 1121;
pub const ICON_PIN_CANCEL_ID: u32 = 1122;

pub const PrivilegeMode = enum {
    root_console,
    guest_diagnostic,
};

pub const AuthState = enum {
    locked,
    unlocked,
};

pub const DiosixGui = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,

    windows: std.ArrayList(Window),
    active_win_idx: ?usize = null,

    cursor: cursor_mod.Cursor,
    mouse_left_down: bool = false,

    // Real-time window transparency percentage (0 = fully opaque, 100 = invisible; default 30%)
    window_transparency: u32 = 30,

    // Real-time backdrop Gaussian blur strength (0 = no blur, 100 = max blur; default 50%)
    blur_strength: u32 = 50,

    // Graduated background colors (default light blue top, dark blue bottom)
    bg_top_color: u32 = fb.Color.SKY_BASE_TOP,
    bg_bot_color: u32 = fb.Color.GRADIENT_BOT_DEFAULT,

    // Gradual background texture drift state (random direction decided at runtime)
    drift_dir: DriftDirection = .right,
    drift_x: i32 = 0,
    drift_y: i32 = 0,
    drift_accum_ms: u32 = 0,
    // Background animation speed (0 = 0 movement/static, 100 = full/original speed; default 50%)
    bg_animation_speed: u32 = 50,

    // Privilege separation & Touch PIN Authentication state
    privilege_mode: PrivilegeMode = .root_console,
    auth_state: AuthState = .locked,
    pin_buf: [16]u8 = @splat(0),
    pin_len: usize = 0,

    // Damage tracking: dirty bounding box needing redraw
    dirty_box: fb.Box = fb.Box{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 },

    // Scratch buffer for deterministic separable Gaussian blur passes
    blur_scratch: []u32,

    // Live host telemetry tracking
    uptime_accum_ms: u32 = 0,
    last_uptime_sec: u64 = 0,

    // Navigation roll-up/roll-down and pane sliding animation state
    nav_anim_state: NavAnimState = .idle,
    nav_anim_progress: f32 = 0.0,
    nav_anim_duration_ms: f32 = 200.0,
    active_menu_id: ?u32 = null,

    // Active mouse drag capture window ID (e.g. while dragging a slider)
    active_drag_win_id: ?u32 = null,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !DiosixGui {
        const total_h = std.math.add(usize, height, 64) catch return error.InvalidDimensions;
        const scratch_len = std.math.mul(usize, width, total_h) catch return error.InvalidDimensions;
        const scratch_mem = try allocator.alloc(u32, scratch_len);

        // Decide background drift direction randomly at runtime: left, right, up, or down
        var ts: linux.timespec = undefined;
        const clk_rc = linux.clock_gettime(linux.CLOCK.REALTIME, &ts);
        const seed: u64 = if (@as(isize, @bitCast(clk_rc)) == 0)
            (@as(u64, @bitCast(ts.sec)) *% 31) ^ (@as(u64, @bitCast(ts.nsec)) << 16)
        else
            0x12345678_9ABCDEF0;

        var prng = std.Random.DefaultPrng.init(seed);
        const dir_num = prng.random().uintLessThan(u32, 4);
        const chosen_dir: DriftDirection = @enumFromInt(dir_num);

        var gui = DiosixGui{
            .allocator = allocator,
            .width = width,
            .height = height,
            .windows = .empty,
            .cursor = cursor_mod.Cursor{
                .x = @as(i32, @intCast(width / 2)),
                .y = @as(i32, @intCast(height / 2)),
                .visible = false,
            },
            .window_transparency = 30,
            .blur_scratch = scratch_mem,
            .drift_dir = chosen_dir,
            .bg_animation_speed = 50,
        };

        // 1. Build left menu
        try gui.buildMainMenu();

        // 2. Build bottom panes (Active Help pane on left, Version pane on right)
        try gui.buildBottomPanes();

        // Focus main menu
        if (gui.windows.items.len > 0) {
            gui.focusWindow(0);
        }

        // Initialize active help
        gui.updateActiveHelp();

        // Initial state is full-screen damage
        gui.markFullDirty();

        return gui;
    }

    pub fn deinit(self: *DiosixGui) void {
        for (self.windows.items) |*win| {
            win.deinit();
        }
        self.windows.deinit(self.allocator);
        self.allocator.free(self.blur_scratch);
    }

    // --- Dynamic Window Lifecycle Management ---

    // Dynamically create a new window pane
    pub fn createWindow(self: *DiosixGui, id: u32, x: i32, y: i32, width: u32, height: u32, title: ?[]const u8) !*Window {
        _ = self.destroyWindow(id);

        var win = Window.init(self.allocator, id, x, y, width, height, title);
        win.setOnScreen(true);
        try self.windows.append(self.allocator, win);
        const idx = self.windows.items.len - 1;
        self.markDirty(self.windows.items[idx].getBox());
        return &self.windows.items[idx];
    }

    // Dynamically destroy a window pane by ID
    pub fn destroyWindow(self: *DiosixGui, id: u32) bool {
        for (self.windows.items, 0..) |*win, idx| {
            if (win.id == id) {
                if (win.linked_menu_item_id) |mid| {
                    self.setMenuItemSelected(mid, false);
                }
                if (win.parent_window_id) |pid| {
                    if (self.getWindow(pid)) |pwin| {
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
                            self.focusWindow(@min(idx, self.windows.items.len - 1));
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
            if (win.linked_menu_item_id) |mid| {
                self.setMenuItemSelected(mid, false);
            }
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

    // --- Dynamic Layout Builders ---

    // Back button activation callback
    fn onBackButtonClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
        _ = win_ctx;
        _ = icon;
        const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
        self.navigateBack() catch {};
    }

    // Menu item activation callback
    fn onMenuItemActivated(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
        _ = win_ctx;
        const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
        self.activateMenuItem(icon.id) catch {};
    }

    // Dynamically sized menu on left-hand side with border gap
    pub fn buildMainMenu(self: *DiosixGui) !void {
        const menu_items = [_][]const u8{ "Guests", "Status", "Config" };
        var max_w: u32 = 0;
        for (menu_items) |item_str| {
            const w = font.measureStringScaled(item_str, 6, 5);
            if (w > max_w) max_w = w;
        }

        const item_w = max_w + 16;
        const menu_w = @as(u32, @intCast(MENU_PAD_X * 2)) + item_w;
        const max_avail_h = if (self.height > @as(u32, @intCast(BORDER_GAP * 2)))
            self.height - @as(u32, @intCast(BORDER_GAP * 2))
        else
            self.height;
        const win_h = @min(MENU_FULL_H, max_avail_h);

        const win = try self.createWindow(WIN_MENU_ID, BORDER_GAP, BORDER_GAP, menu_w, win_h, null);
        win.setHelpText("Main menu");

        try self.repopulateMainMenu();
    }

    // Repopulate Main Menu with all items (Guests, Status, Config) and restore full height
    pub fn repopulateMainMenu(self: *DiosixGui) !void {
        const win = self.getWindow(WIN_MENU_ID) orelse return;
        win.icons.clearRetainingCapacity();
        const max_avail_h = if (self.height > @as(u32, @intCast(BORDER_GAP * 2)))
            self.height - @as(u32, @intCast(BORDER_GAP * 2))
        else
            self.height;
        win.height = @min(MENU_FULL_H, max_avail_h);
        win.setHelpText("Main menu");

        const menu_items = [_][]const u8{ "Guests", "Status", "Config" };
        const menu_ids = [_]u32{ ICON_MENU_GUESTS_ID, ICON_MENU_STATUS_ID, ICON_MENU_CONFIG_ID };
        const menu_helps = [_][]const u8{
            "View and manage guest virtual machines",
            "View real-time system information",
            "Configure window appearance and desktop background themes",
        };

        var max_w: u32 = 0;
        for (menu_items) |item_str| {
            const w = font.measureStringScaled(item_str, 6, 5);
            if (w > max_w) max_w = w;
        }
        const item_w = if (win.width > @as(u32, @intCast(MENU_PAD_X * 2)))
            win.width - @as(u32, @intCast(MENU_PAD_X * 2))
        else
            max_w + 16;

        var cur_y: i32 = MENU_TOP_PAD;
        for (menu_items, 0..) |item_str, idx| {
            var icon = Icon.createMenuItem(menu_ids[idx], MENU_PAD_X, cur_y, item_w, MENU_ITEM_HEIGHT, item_str);
            icon.setHelpText(menu_helps[idx]);
            icon.callback = onMenuItemActivated;
            _ = try win.addIcon(icon);
            cur_y += @as(i32, @intCast(MENU_ITEM_HEIGHT + MENU_ITEM_SPACING));
        }
    }

    // Contract Main Menu to show just the selected item
    pub fn contractMainMenu(self: *DiosixGui, selected_menu_id: u32) !void {
        const win = self.getWindow(WIN_MENU_ID) orelse return;
        win.icons.clearRetainingCapacity();

        const name: []const u8 = switch (selected_menu_id) {
            ICON_MENU_GUESTS_ID => "Guests",
            ICON_MENU_STATUS_ID => "Status",
            ICON_MENU_CONFIG_ID => "Config",
            else => "Menu",
        };
        const help: []const u8 = switch (selected_menu_id) {
            ICON_MENU_GUESTS_ID => "View and manage guest virtual machines",
            ICON_MENU_STATUS_ID => "View real-time system information",
            ICON_MENU_CONFIG_ID => "Configure window appearance and desktop background themes",
            else => "Selected menu item",
        };

        const item_w = if (win.width > @as(u32, @intCast(MENU_PAD_X * 2)))
            win.width - @as(u32, @intCast(MENU_PAD_X * 2))
        else
            80;
        var icon = Icon.createMenuItem(selected_menu_id, MENU_PAD_X, MENU_TOP_PAD, item_w, MENU_ITEM_HEIGHT, name);
        icon.setHelpText(help);
        icon.callback = onMenuItemActivated;
        icon.setSelected(true);
        _ = try win.addIcon(icon);
        win.setHelpText(help);
    }

    // Build the separate Back menu pane positioned under the contracted menu pane
    pub fn buildBackPane(self: *DiosixGui) !void {
        if (self.getWindow(WIN_BACK_ID) != null) return;
        const menu_win = self.getWindow(WIN_MENU_ID);
        const menu_w = if (menu_win) |mw| mw.width else 112;
        const back_w: u32 = menu_w;
        const back_h: u32 = BACK_PANE_H;

        const win = try self.createWindow(WIN_BACK_ID, BORDER_GAP, BACK_PANE_Y, back_w, back_h, null);
        win.setHelpText("Return to the main menu");
        win.parent_window_id = WIN_MENU_ID;

        const item_w: u32 = if (back_w > @as(u32, @intCast(MENU_PAD_X * 2))) back_w - @as(u32, @intCast(MENU_PAD_X * 2)) else 80;
        var back_item = Icon.createBackMenuItem(ICON_BACK_BTN_ID, MENU_PAD_X, MENU_TOP_PAD, item_w, MENU_ITEM_HEIGHT, "Back");
        back_item.setHelpText("Return to the main menu");
        back_item.callback = onBackButtonClicked;
        _ = try win.addIcon(back_item);
    }

    // Build bottom panes: Active Help pane on bottom-left, Version pane on bottom-right
    pub fn buildBottomPanes(self: *DiosixGui) !void {
        var ver_buf: [64]u8 = undefined;
        const ver_base = host_info.getVersionString(&ver_buf);
        var badge_buf: [128]u8 = undefined;
        const ver_str = std.fmt.bufPrint(&badge_buf, "{s} {s}", .{ ver_base, self.getSecurityBadge() }) catch ver_base;
        const ver_text_w = font.measureString(ver_str);

        // Version Pane sizing (bottom-right)
        const ver_h: u32 = 40;
        const ver_pad_h: u32 = 14;
        const ver_w = ver_text_w + ver_pad_h * 2;
        const ver_x = @as(i32, @intCast(self.width)) - @as(i32, @intCast(ver_w)) - BORDER_GAP;
        const ver_y = @as(i32, @intCast(self.height)) - @as(i32, @intCast(ver_h)) - BORDER_GAP;

        const win_ver = try self.createWindow(WIN_VERSION_ID, ver_x, ver_y, ver_w, ver_h, null);
        win_ver.setHelpText("Hypervisor build information and security console privilege state");
        var ver_icon = Icon.createReadOnly(ICON_VERSION_TEXT_ID, @intCast(ver_pad_h), 8, ver_text_w + 4, 24, ver_str);
        ver_icon.setHelpText("Hypervisor name, version number, build branch, commit hash, and security lock mode");
        _ = try win_ver.addIcon(ver_icon);

        // Active Help Pane: same vertical position (ver_y), same height (ver_h = 40),
        // width fills remaining length of screen with even spacing (BORDER_GAP = 16)
        // between left screen edge, active help pane, version pane, and right screen edge.
        const help_x: i32 = BORDER_GAP;
        const help_y: i32 = ver_y;
        const help_h: u32 = ver_h;
        const available_w = @as(i32, @intCast(ver_x)) - help_x - BORDER_GAP;
        const help_w: u32 = if (available_w > 0) @intCast(available_w) else 0;

        const win_help = try self.createWindow(WIN_HELP_ID, help_x, help_y, help_w, help_h, null);
        const help_pad_h: u32 = 14;
        const help_text_w: u32 = if (help_w > help_pad_h * 2) help_w - help_pad_h * 2 else 0;
        var help_icon = Icon.createReadOnly(ICON_HELP_TEXT_ID, @intCast(help_pad_h), 8, help_text_w, 24, FALLBACK_HELP_TEXT);
        help_icon.setCustomColor(fb.Color.WHITE);
        _ = try win_help.addIcon(help_icon);
    }

    pub const FALLBACK_HELP_TEXT = "Welcome to diosix";

    // Search top-to-bottom among onscreen windows for an icon containing (px, py)
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

    // Search top-to-bottom among onscreen windows for a window containing (px, py)
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

    // Update active contextual help text based on Priority 1 (Icon), Priority 2 (Pane), Priority 3 (Fallback)
    pub fn updateActiveHelp(self: *DiosixGui) void {
        var help_str: ?[]const u8 = null;

        // Priority 1: Actively dragged icon help text, or icon under mouse cursor with help text
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
            if (self.findIconAt(self.cursor.x, self.cursor.y)) |icon| {
                if (icon.getHelpText()) |ht| {
                    if (ht.len > 0) help_str = ht;
                }
            }
        }
        // Priority 2: Pane under mouse cursor with help text
        if (help_str == null) {
            if (self.findWindowAt(self.cursor.x, self.cursor.y)) |win| {
                if (win.getHelpText()) |ht| {
                    if (ht.len > 0) help_str = ht;
                }
            }
        }

        // Priority 3: Fallback text ("Welcome to diosix")
        const final_text = help_str orelse FALLBACK_HELP_TEXT;

        if (self.findIcon(WIN_HELP_ID, ICON_HELP_TEXT_ID)) |help_icon| {
            const current_text = help_icon.getText();
            if (!std.mem.eql(u8, current_text, final_text)) {
                help_icon.setText(final_text);
                self.markWindowDirty(WIN_HELP_ID);
            }
        }
    }

    // Build the Status pane displaying Host and Hypervisor telemetry in table format
    pub fn buildStatusPane(self: *DiosixGui) !void {
        const menu_win = self.getWindow(WIN_MENU_ID);
        const status_x: i32 = if (menu_win) |mw| mw.x + @as(i32, @intCast(mw.width)) + BORDER_GAP else 172;
        const status_y: i32 = BORDER_GAP;
        const max_w = @as(i32, @intCast(self.width)) - BORDER_GAP - status_x;
        const status_w: u32 = if (max_w > 0) @intCast(max_w) else 780;
        const status_h: u32 = 224;

        const win = try self.createWindow(WIN_STATUS_ID, status_x, status_y, status_w, status_h, null);
        win.setHelpText("Information about this host system and hypervisor");
        win.parent_window_id = WIN_MENU_ID;
        win.linked_menu_item_id = ICON_MENU_STATUS_ID;
        if (menu_win) |mw| {
            mw.child_window_id = WIN_STATUS_ID;
        }
        self.setMenuItemSelected(ICON_MENU_STATUS_ID, true);

        const pad_x: i32 = 20;
        const col1_right: i32 = 140;
        const col2_x: i32 = 160;
        const col2_w: u32 = status_w - @as(u32, @intCast(col2_x)) - 20;
        const line_h: u32 = 20;
        const label_color: u32 = 0x00A0B4C8; // Clean table label styling

        // --- Host Heading ---
        var host_hdr = Icon.createReadOnly(ICON_STATUS_HOST_HDR_ID, pad_x, 14, 200, line_h, "Host");
        host_hdr.setCustomColor(fb.Color.ACCENT_CYAN);
        _ = try win.addIcon(host_hdr);

        // Row 1: Uptime
        const lbl_uptime_str = "Uptime";
        const lbl_uptime_w = font.measureString(lbl_uptime_str);
        var lbl_uptime = Icon.createReadOnly(ICON_STATUS_HOST_UPTIME_LABEL_ID, col1_right - @as(i32, @intCast(lbl_uptime_w)), 34, lbl_uptime_w, line_h, lbl_uptime_str);
        lbl_uptime.setCustomColor(label_color);
        _ = try win.addIcon(lbl_uptime);

        var uptime_buf: [64]u8 = undefined;
        const uptime_str = host_info.formatUptime(&uptime_buf);
        const icon_uptime = Icon.createReadOnly(ICON_STATUS_HOST_UPTIME_ID, col2_x, 34, col2_w, line_h, uptime_str);
        _ = try win.addIcon(icon_uptime);

        // Row 2: CPU Cores
        const lbl_cpu_str = "CPU cores";
        const lbl_cpu_w = font.measureString(lbl_cpu_str);
        var lbl_cpu = Icon.createReadOnly(ICON_STATUS_HOST_CPU_LABEL_ID, col1_right - @as(i32, @intCast(lbl_cpu_w)), 54, lbl_cpu_w, line_h, lbl_cpu_str);
        lbl_cpu.setCustomColor(label_color);
        _ = try win.addIcon(lbl_cpu);

        var cpu_buf: [64]u8 = undefined;
        const cpu_str = host_info.getHostCpuString(&cpu_buf);
        const icon_cpu = Icon.createReadOnly(ICON_STATUS_HOST_CPU_ID, col2_x, 54, col2_w, line_h, cpu_str);
        _ = try win.addIcon(icon_cpu);

        // Row 3: RAM
        const lbl_ram_str = "RAM";
        const lbl_ram_w = font.measureString(lbl_ram_str);
        var lbl_ram = Icon.createReadOnly(ICON_STATUS_HOST_RAM_LABEL_ID, col1_right - @as(i32, @intCast(lbl_ram_w)), 74, lbl_ram_w, line_h, lbl_ram_str);
        lbl_ram.setCustomColor(label_color);
        _ = try win.addIcon(lbl_ram);

        var ram_buf: [80]u8 = undefined;
        const ram_str = host_info.getHostRamString(&ram_buf);
        const icon_ram = Icon.createReadOnly(ICON_STATUS_HOST_RAM_ID, col2_x, 74, col2_w, line_h, ram_str);
        _ = try win.addIcon(icon_ram);

        // Row 4: Time and Date
        const lbl_time_str = "Time and date";
        const lbl_time_w = font.measureString(lbl_time_str);
        var lbl_time = Icon.createReadOnly(ICON_STATUS_HOST_TIME_LABEL_ID, col1_right - @as(i32, @intCast(lbl_time_w)), 94, lbl_time_w, line_h, lbl_time_str);
        lbl_time.setCustomColor(label_color);
        _ = try win.addIcon(lbl_time);

        var dt_buf: [80]u8 = undefined;
        const dt_str = host_info.getHostDateTimeString(&dt_buf);
        const icon_time = Icon.createReadOnly(ICON_STATUS_HOST_TIME_ID, col2_x, 94, col2_w, line_h, dt_str);
        _ = try win.addIcon(icon_time);

        // --- Hypervisor Heading ---
        var hv_hdr = Icon.createReadOnly(ICON_STATUS_HV_HDR_ID, pad_x, 120, 200, line_h, "Hypervisor");
        hv_hdr.setCustomColor(fb.Color.ACCENT_CYAN);
        _ = try win.addIcon(hv_hdr);

        // Row 5: Hypervisor Build
        const lbl_build_str = "Build";
        const lbl_build_w = font.measureString(lbl_build_str);
        var lbl_build = Icon.createReadOnly(ICON_STATUS_HV_BUILD_LABEL_ID, col1_right - @as(i32, @intCast(lbl_build_w)), 140, lbl_build_w, line_h, lbl_build_str);
        lbl_build.setCustomColor(label_color);
        _ = try win.addIcon(lbl_build);

        var b1_buf: [160]u8 = undefined;
        var b2_buf: [160]u8 = undefined;
        const split = host_info.getHvBuildSplit(&b1_buf, &b2_buf);

        const icon_b1 = Icon.createReadOnly(ICON_STATUS_HV_BUILD1_ID, col2_x, 140, col2_w, line_h, split.line1);
        _ = try win.addIcon(icon_b1);

        const icon_b2 = Icon.createReadOnly(ICON_STATUS_HV_BUILD2_ID, col2_x, 158, col2_w, line_h, split.line2);
        _ = try win.addIcon(icon_b2);

        // Row 6: Hypervisor Footprint
        const lbl_foot_str = "Footprint";
        const lbl_foot_w = font.measureString(lbl_foot_str);
        var lbl_foot = Icon.createReadOnly(ICON_STATUS_HV_FOOTPRINT_LABEL_ID, col1_right - @as(i32, @intCast(lbl_foot_w)), 180, lbl_foot_w, line_h, lbl_foot_str);
        lbl_foot.setCustomColor(label_color);
        _ = try win.addIcon(lbl_foot);

        var foot_buf: [80]u8 = undefined;
        const foot_str = host_info.getHvFootprintString(&foot_buf);
        const icon_foot = Icon.createReadOnly(ICON_STATUS_HV_FOOTPRINT_ID, col2_x, 180, col2_w, line_h, foot_str);
        _ = try win.addIcon(icon_foot);
    }

    // Config Pane slider / button callbacks
    fn onTransparencySliderChanged(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
        _ = win_ctx;
        const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
        self.setWindowTransparency(@intCast(icon.slider_val));
    }

    fn onBlurSliderChanged(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
        _ = win_ctx;
        const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
        self.setBlurStrength(@intCast(icon.slider_val));
    }

    fn onBgSpeedSliderChanged(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
        _ = win_ctx;
        const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
        self.setBgAnimationSpeed(@intCast(icon.slider_val));
    }

    fn onThemeButtonClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
        _ = win_ctx;
        const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
        switch (icon.id) {
            ICON_CONFIG_THEME_DAY_ID => {
                self.setBackdropTopColor(fb.Color.SKY_BASE_TOP);
                self.setBackdropBotColor(fb.Color.GRADIENT_BOT_DEFAULT);
            },
            ICON_CONFIG_THEME_MIDNIGHT_ID => {
                self.setBackdropTopColor(fb.Color.rgb(16, 24, 48));
                self.setBackdropBotColor(fb.Color.rgb(4, 6, 16));
            },
            ICON_CONFIG_THEME_SUNSET_ID => {
                self.setBackdropTopColor(fb.Color.rgb(180, 70, 60));
                self.setBackdropBotColor(fb.Color.rgb(40, 20, 50));
            },
            ICON_CONFIG_THEME_EMERALD_ID => {
                self.setBackdropTopColor(fb.Color.rgb(32, 120, 90));
                self.setBackdropBotColor(fb.Color.rgb(10, 36, 30));
            },
            else => {},
        }
    }

    fn onConfigAdminClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
        _ = win_ctx;
        _ = icon;
        const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
        if (self.auth_state == .locked) {
            self.openPinModal() catch {};
        } else {
            self.lockConsole();
        }
    }

    fn onPinKeyClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
        _ = win_ctx;
        const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
        if (icon.id >= ICON_PIN_KEY_BASE_ID and icon.id <= ICON_PIN_KEY_BASE_ID + 9) {
            const digit: u8 = @intCast('0' + (icon.id - ICON_PIN_KEY_BASE_ID));
            self.handlePinDigit(digit);
        }
    }

    fn onPinClearClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
        _ = win_ctx;
        _ = icon;
        const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
        self.handlePinClear();
    }

    fn onPinCancelClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
        _ = win_ctx;
        _ = icon;
        const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
        self.closePinModal();
    }

    fn onPinSubmitClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
        _ = win_ctx;
        _ = icon;
        const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
        self.handlePinSubmit();
    }

    pub const DEFAULT_PIN = "1234";

    pub fn lockConsole(self: *DiosixGui) void {
        self.auth_state = .locked;
        @memset(&self.pin_buf, 0);
        self.pin_len = 0;
        self.updateSecurityBadgeText();
        self.updateConfigAdminButtonText();
        self.markFullDirty();
    }

    pub fn openPinModal(self: *DiosixGui) !void {
        if (self.getWindow(WIN_PIN_MODAL_ID) != null) return;

        @memset(&self.pin_buf, 0);
        self.pin_len = 0;

        const modal_w: u32 = 320;
        const modal_h: u32 = 390;
        const mx: i32 = @divTrunc(@as(i32, @intCast(self.width)) - @as(i32, @intCast(modal_w)), 2);
        const my: i32 = @divTrunc(@as(i32, @intCast(self.height)) - @as(i32, @intCast(modal_h)), 2);

        const win = try self.createWindow(WIN_PIN_MODAL_ID, mx, my, modal_w, modal_h, "ADMINISTRATIVE UNLOCK");
        win.setHelpText("Enter administrative PIN to unlock full console access");

        // Subtitle / Prompt
        const prompt_str = "Enter Root Console PIN:";
        var prompt_icon = Icon.createReadOnly(ICON_PIN_TITLE_ID, 20, 40, modal_w - 40, 20, prompt_str);
        prompt_icon.setCustomColor(fb.Color.ACCENT_CYAN);
        _ = try win.addIcon(prompt_icon);

        // Masked PIN display box
        var pin_display = Icon.createReadOnly(ICON_PIN_DISPLAY_ID, 20, 64, modal_w - 40, 28, "_ _ _ _");
        pin_display.setCustomColor(fb.Color.WHITE);
        _ = try win.addIcon(pin_display);

        // Touch Keypad: 3 columns x 4 rows
        const key_w: u32 = 70;
        const key_h: u32 = 36;
        const col_gap: i32 = 15;
        const row_gap: i32 = 10;
        const start_x: i32 = 40;
        const start_y: i32 = 100;

        // Digits 1..9
        const digits = [_]u8{ '1', '2', '3', '4', '5', '6', '7', '8', '9' };
        for (digits, 0..) |d, i| {
            const row: i32 = @intCast(i / 3);
            const col: i32 = @intCast(i % 3);
            const kx = start_x + col * @as(i32, @intCast(key_w + col_gap));
            const ky = start_y + row * @as(i32, @intCast(key_h + row_gap));
            const d_str = [_]u8{d};
            const kid = ICON_PIN_KEY_BASE_ID + @as(u32, d - '0');
            var k_btn = Icon.createButton(kid, kx, ky, key_w, key_h, &d_str);
            k_btn.callback = onPinKeyClicked;
            _ = try win.addIcon(k_btn);
        }

        // Row 3: Clear, 0, Enter
        const row3_y = start_y + 3 * @as(i32, @intCast(key_h + row_gap));
        const kclear_x = start_x;
        var kclear_btn = Icon.createButton(ICON_PIN_CLEAR_ID, kclear_x, row3_y, key_w, key_h, "Clear");
        kclear_btn.callback = onPinClearClicked;
        _ = try win.addIcon(kclear_btn);

        const k0_x = start_x + 1 * @as(i32, @intCast(key_w + col_gap));
        var k0_btn = Icon.createButton(ICON_PIN_KEY_BASE_ID, k0_x, row3_y, key_w, key_h, "0");
        k0_btn.callback = onPinKeyClicked;
        _ = try win.addIcon(k0_btn);

        const kenter_x = start_x + 2 * @as(i32, @intCast(key_w + col_gap));
        var kenter_btn = Icon.createButton(ICON_PIN_SUBMIT_ID, kenter_x, row3_y, key_w, key_h, "Enter");
        kenter_btn.callback = onPinSubmitClicked;
        _ = try win.addIcon(kenter_btn);

        // Row 4: Cancel button spans full keypad width
        const row4_y = start_y + 4 * @as(i32, @intCast(key_h + row_gap));
        const total_pad_w = 3 * key_w + 2 * @as(u32, @intCast(col_gap));
        var btn_cancel = Icon.createButton(ICON_PIN_CANCEL_ID, start_x, row4_y, total_pad_w, key_h, "Cancel");
        btn_cancel.setHelpText("Cancel authentication and dismiss modal");
        btn_cancel.callback = onPinCancelClicked;
        _ = try win.addIcon(btn_cancel);

        // Status text / validation feedback at bottom
        const status_icon = Icon.createReadOnly(ICON_PIN_STATUS_ID, 20, row4_y + @as(i32, @intCast(key_h)) + 8, modal_w - 40, 20, "");
        _ = try win.addIcon(status_icon);

        self.focusWindowById(WIN_PIN_MODAL_ID);
        self.markDirty(win.getBox());
    }

    pub fn closePinModal(self: *DiosixGui) void {
        @memset(&self.pin_buf, 0);
        self.pin_len = 0;
        _ = self.destroyWindow(WIN_PIN_MODAL_ID);
        self.markFullDirty();
    }

    pub fn handlePinDigit(self: *DiosixGui, digit: u8) void {
        if (self.pin_len < 8) {
            self.pin_buf[self.pin_len] = digit;
            self.pin_len += 1;
            self.updatePinDisplay();
        }
    }

    pub fn handlePinClear(self: *DiosixGui) void {
        @memset(&self.pin_buf, 0);
        self.pin_len = 0;
        self.updatePinDisplay();
        if (self.findIcon(WIN_PIN_MODAL_ID, ICON_PIN_STATUS_ID)) |st| {
            st.setText("");
        }
    }

    pub fn handlePinSubmit(self: *DiosixGui) void {
        const entered = self.pin_buf[0..self.pin_len];
        const is_correct = std.mem.eql(u8, entered, DEFAULT_PIN);

        // Security Hygiene: Zero PIN memory immediately after verification
        @memset(&self.pin_buf, 0);
        self.pin_len = 0;

        if (is_correct) {
            self.auth_state = .unlocked;
            _ = self.destroyWindow(WIN_PIN_MODAL_ID);
            self.updateSecurityBadgeText();
            self.updateConfigAdminButtonText();
            self.markFullDirty();
        } else {
            self.updatePinDisplay();
            if (self.findIcon(WIN_PIN_MODAL_ID, ICON_PIN_STATUS_ID)) |st| {
                st.setText("Invalid PIN. Try again.");
                st.setCustomColor(fb.Color.rgb(240, 70, 70));
            }
            if (self.getWindow(WIN_PIN_MODAL_ID)) |win| {
                self.markDirty(win.getBox());
            }
        }
    }

    pub fn updatePinDisplay(self: *DiosixGui) void {
        if (self.findIcon(WIN_PIN_MODAL_ID, ICON_PIN_DISPLAY_ID)) |disp| {
            if (self.pin_len == 0) {
                disp.setText("_ _ _ _");
            } else {
                var buf: [32]u8 = undefined;
                var b_idx: usize = 0;
                var i: usize = 0;
                while (i < self.pin_len and b_idx + 2 < buf.len) : (i += 1) {
                    if (b_idx > 0) {
                        buf[b_idx] = ' ';
                        b_idx += 1;
                    }
                    buf[b_idx] = '*';
                    b_idx += 1;
                }
                disp.setText(buf[0..b_idx]);
            }
            if (self.getWindow(WIN_PIN_MODAL_ID)) |win| {
                self.markDirty(win.getBox());
            }
        }
    }

    pub fn updateSecurityBadgeText(self: *DiosixGui) void {
        if (self.findIcon(WIN_VERSION_ID, ICON_VERSION_TEXT_ID)) |vicon| {
            var ver_buf: [64]u8 = undefined;
            const ver_base = host_info.getVersionString(&ver_buf);
            var badge_buf: [128]u8 = undefined;
            const full_badge = std.fmt.bufPrint(&badge_buf, "{s} {s}", .{ ver_base, self.getSecurityBadge() }) catch ver_base;
            vicon.setText(full_badge);

            const ver_text_w = font.measureString(full_badge);
            const ver_pad_h: u32 = 14;
            const new_ver_w = ver_text_w + ver_pad_h * 2;
            const new_ver_x = @as(i32, @intCast(self.width)) - @as(i32, @intCast(new_ver_w)) - BORDER_GAP;

            if (self.getWindow(WIN_VERSION_ID)) |win| {
                self.markDirty(win.getBox());
                win.x = new_ver_x;
                win.width = new_ver_w;
                vicon.width = ver_text_w + 4;
                self.markDirty(win.getBox());
            }

            if (self.getWindow(WIN_HELP_ID)) |hwin| {
                const help_x: i32 = BORDER_GAP;
                const avail_w = @as(i32, @intCast(new_ver_x)) - help_x - BORDER_GAP;
                if (avail_w > 0) {
                    self.markDirty(hwin.getBox());
                    hwin.width = @intCast(avail_w);
                    if (self.findIcon(WIN_HELP_ID, ICON_HELP_TEXT_ID)) |hicon| {
                        hicon.width = if (hwin.width > ver_pad_h * 2) hwin.width - ver_pad_h * 2 else 0;
                    }
                    self.markDirty(hwin.getBox());
                }
            }
        }
    }

    pub fn updateConfigAdminButtonText(self: *DiosixGui) void {
        if (self.findIcon(WIN_CONFIG_ID, ICON_CONFIG_ADMIN_BTN_ID)) |abtn| {
            if (self.auth_state == .unlocked) {
                abtn.setText("Lock Console");
                abtn.setHelpText("Lock the administrative console and revoke elevated session");
            } else {
                abtn.setText("Admin Unlock");
                abtn.setHelpText("Enter PIN to unlock privileged root hypervisor management");
            }
            if (self.getWindow(WIN_CONFIG_ID)) |win| {
                self.markDirty(win.getBox());
            }
        }
    }

    pub fn isConsoleUnlocked(self: *const DiosixGui) bool {
        if (self.privilege_mode == .guest_diagnostic) return false;
        return self.auth_state == .unlocked;
    }

    pub fn getSecurityBadge(self: *const DiosixGui) []const u8 {
        return switch (self.privilege_mode) {
            .root_console => switch (self.auth_state) {
                .locked => "[Root: Locked]",
                .unlocked => "[Root: Unlocked]",
            },
            .guest_diagnostic => "[Guest: Diagnostic]",
        };
    }

    pub fn focusWindowById(self: *DiosixGui, win_id: u32) void {
        for (self.windows.items, 0..) |*win, idx| {
            if (win.id == win_id) {
                self.focusWindow(idx);
                break;
            }
        }
    }

    // Build the Config pane allowing user configuration of transparency, blur, and theme colors
    pub fn buildConfigPane(self: *DiosixGui) !void {
        const menu_win = self.getWindow(WIN_MENU_ID);
        const config_x: i32 = if (menu_win) |mw| mw.x + @as(i32, @intCast(mw.width)) + BORDER_GAP else 172;
        const config_y: i32 = BORDER_GAP;
        const max_w = @as(i32, @intCast(self.width)) - BORDER_GAP - config_x;
        const config_w: u32 = if (max_w > 0) @intCast(max_w) else 780;
        const config_h: u32 = 264;

        const win = try self.createWindow(WIN_CONFIG_ID, config_x, config_y, config_w, config_h, null);
        win.setHelpText("System configuration and appearance settings");
        win.parent_window_id = WIN_MENU_ID;
        win.linked_menu_item_id = ICON_MENU_CONFIG_ID;
        if (menu_win) |mw| {
            mw.child_window_id = WIN_CONFIG_ID;
        }
        self.setMenuItemSelected(ICON_MENU_CONFIG_ID, true);

        const pad_x: i32 = 20;
        const col1_right: i32 = 140;
        const col2_x: i32 = 160;
        const line_h: u32 = 20;
        const label_color: u32 = 0x00A0B4C8;

        // Heading: Appearance
        var app_hdr = Icon.createReadOnly(ICON_CONFIG_HDR_ID, pad_x, 14, 200, line_h, "Appearance");
        app_hdr.setCustomColor(fb.Color.ACCENT_CYAN);
        _ = try win.addIcon(app_hdr);

        // Row 1: Transparency Slider
        const lbl_trans_str = "Transparency";
        const lbl_trans_w = font.measureString(lbl_trans_str);
        var lbl_trans = Icon.createReadOnly(ICON_CONFIG_TRANSPARENCY_LBL_ID, col1_right - @as(i32, @intCast(lbl_trans_w)), 38, lbl_trans_w, line_h, lbl_trans_str);
        lbl_trans.setCustomColor(label_color);
        _ = try win.addIcon(lbl_trans);

        var slider_trans = Icon.createSlider(
            ICON_CONFIG_TRANSPARENCY_SLIDER_ID,
            col2_x,
            34,
            240,
            28,
            0,
            90,
            @intCast(self.window_transparency),
            "%",
        );
        slider_trans.setHelpText("Adjust window pane background transparency (0% opaque to 90% transparent)");
        slider_trans.callback = onTransparencySliderChanged;
        _ = try win.addIcon(slider_trans);

        // Row 2: Blur Strength Slider
        const lbl_blur_str = "Glass blur";
        const lbl_blur_w = font.measureString(lbl_blur_str);
        var lbl_blur = Icon.createReadOnly(ICON_CONFIG_BLUR_LBL_ID, col1_right - @as(i32, @intCast(lbl_blur_w)), 78, lbl_blur_w, line_h, lbl_blur_str);
        lbl_blur.setCustomColor(label_color);
        _ = try win.addIcon(lbl_blur);

        var slider_blur = Icon.createSlider(
            ICON_CONFIG_BLUR_SLIDER_ID,
            col2_x,
            74,
            240,
            28,
            0,
            100,
            @intCast(self.blur_strength),
            "%",
        );
        slider_blur.setHelpText("Adjust Gaussian glass blur radius on background under window panes");
        slider_blur.callback = onBlurSliderChanged;
        _ = try win.addIcon(slider_blur);

        // Row 3: Background Animation Speed Slider
        const lbl_speed_str = "Anim speed";
        const lbl_speed_w = font.measureString(lbl_speed_str);
        var lbl_speed = Icon.createReadOnly(ICON_CONFIG_SPEED_LBL_ID, col1_right - @as(i32, @intCast(lbl_speed_w)), 118, lbl_speed_w, line_h, lbl_speed_str);
        lbl_speed.setCustomColor(label_color);
        _ = try win.addIcon(lbl_speed);

        var slider_speed = Icon.createSlider(
            ICON_CONFIG_SPEED_SLIDER_ID,
            col2_x,
            114,
            240,
            28,
            0,
            100,
            @intCast(self.bg_animation_speed),
            "%",
        );
        slider_speed.setHelpText("Adjust background drift animation speed (0% static to 100% full speed)");
        slider_speed.callback = onBgSpeedSliderChanged;
        _ = try win.addIcon(slider_speed);

        // Heading: Desktop Theme
        var theme_hdr = Icon.createReadOnly(ICON_CONFIG_THEME_LBL_ID, pad_x, 156, 200, line_h, "Color Themes");
        theme_hdr.setCustomColor(fb.Color.ACCENT_CYAN);
        _ = try win.addIcon(theme_hdr);

        // Row 4: Theme Buttons
        const btn_w: u32 = 110;
        const btn_h: u32 = 28;
        const btn_spacing: i32 = 16;
        var btn_x: i32 = col2_x;

        var btn_day = Icon.createButton(ICON_CONFIG_THEME_DAY_ID, btn_x, 178, btn_w, btn_h, "Day Sky");
        btn_day.setHelpText("Classic light blue daytime sky gradient");
        btn_day.callback = onThemeButtonClicked;
        _ = try win.addIcon(btn_day);
        btn_x += @as(i32, @intCast(btn_w)) + btn_spacing;

        var btn_mid = Icon.createButton(ICON_CONFIG_THEME_MIDNIGHT_ID, btn_x, 178, btn_w, btn_h, "Midnight");
        btn_mid.setHelpText("Deep dark navy night sky gradient");
        btn_mid.callback = onThemeButtonClicked;
        _ = try win.addIcon(btn_mid);
        btn_x += @as(i32, @intCast(btn_w)) + btn_spacing;

        var btn_sun = Icon.createButton(ICON_CONFIG_THEME_SUNSET_ID, btn_x, 178, btn_w, btn_h, "Sunset");
        btn_sun.setHelpText("Warm crimson dusk sunset gradient");
        btn_sun.callback = onThemeButtonClicked;
        _ = try win.addIcon(btn_sun);
        btn_x += @as(i32, @intCast(btn_w)) + btn_spacing;

        var btn_emr = Icon.createButton(ICON_CONFIG_THEME_EMERALD_ID, btn_x, 178, btn_w, btn_h, "Emerald");
        btn_emr.setHelpText("Forest aurora green gradient");
        btn_emr.callback = onThemeButtonClicked;
        _ = try win.addIcon(btn_emr);

        // Row 5: Console Security
        const sec_lbl_str = "Console access";
        const sec_lbl_w = font.measureString(sec_lbl_str);
        var sec_lbl = Icon.createReadOnly(ICON_CONFIG_ADMIN_LBL_ID, col1_right - @as(i32, @intCast(sec_lbl_w)), 222, sec_lbl_w, line_h, sec_lbl_str);
        sec_lbl.setCustomColor(label_color);
        _ = try win.addIcon(sec_lbl);

        const admin_btn_label = if (self.auth_state == .unlocked) "Lock Console" else "Admin Unlock";
        var btn_admin = Icon.createButton(ICON_CONFIG_ADMIN_BTN_ID, col2_x, 218, 140, 28, admin_btn_label);
        btn_admin.setHelpText(if (self.auth_state == .unlocked) "Lock administrative console and revoke elevated session" else "Enter PIN to unlock privileged root hypervisor management");
        btn_admin.callback = onConfigAdminClicked;
        _ = try win.addIcon(btn_admin);
    }

    pub fn getChildTargetX(self: *DiosixGui) i32 {
        const menu_win = self.getWindow(WIN_MENU_ID);
        return if (menu_win) |mw| mw.x + @as(i32, @intCast(mw.width)) + BORDER_GAP else 144;
    }

    pub fn getChildWindowId(self: *DiosixGui) ?u32 {
        const menu_win = self.getWindow(WIN_MENU_ID) orelse return null;
        return menu_win.child_window_id;
    }

    // Activate a menu item: rolls up the menu to show just the selected item,
    // slides in its child collection of panes, and slides in the Back button pane.
    pub fn activateMenuItem(self: *DiosixGui, menu_item_id: u32) !void {
        _ = self.getWindow(WIN_MENU_ID) orelse return;

        // If clicking the already selected menu item: toggle it back
        if (self.active_menu_id == menu_item_id and self.nav_anim_state != .closing) {
            try self.navigateBack();
            return;
        }

        // If another item was open: teardown previous child panes immediately
        if (self.active_menu_id != null) {
            self.teardownChildPanes();
        }

        // 1. Build the child pane for the selected menu item
        switch (menu_item_id) {
            ICON_MENU_STATUS_ID => {
                try self.buildStatusPane();
            },
            ICON_MENU_CONFIG_ID => {
                try self.buildConfigPane();
            },
            ICON_MENU_GUESTS_ID => {
                if (self.auth_state == .locked) {
                    try self.openPinModal();
                    return;
                }
            },
            else => {},
        }

        // 2. Build the separate Back button pane under the contracted menu pane
        try self.buildBackPane();

        // 3. Contract Main Menu to show just the selected item
        try self.contractMainMenu(menu_item_id);
        self.active_menu_id = menu_item_id;

        // 4. Start opening animation: menu rolls up from full to contracted,
        // while child pane slides in from right and back pane slides in from left
        self.nav_anim_state = .opening;
        self.nav_anim_progress = 0.0;
        self.applyNavAnimation();

        self.updateActiveHelp();
    }

    // Restore the Main Menu pane: Back pane and child panes slide back,
    // and the Main Menu grows down and repopulates with all items.
    pub fn navigateBack(self: *DiosixGui) !void {
        if (self.nav_anim_state == .closing) return;
        if (self.active_menu_id == null and self.nav_anim_state == .idle) return;

        // Immediately repopulate full menu items in WIN_MENU_ID so that
        // as the menu pane grows down, items are progressively revealed
        try self.repopulateMainMenu();

        self.nav_anim_state = .closing;
        self.nav_anim_progress = 1.0;
        self.applyNavAnimation();

        self.updateActiveHelp();
    }

    // Finalize closing transition once animation progress reaches 0.0
    pub fn finishClosing(self: *DiosixGui) void {
        const head = self.getWindow(WIN_MENU_ID);
        if (head) |h| {
            if (h.child_window_id) |cid| {
                if (self.getWindow(cid)) |cwin| {
                    self.markDirty(cwin.getBox());
                }
                _ = self.destroyWindow(cid);
                h.child_window_id = null;
            }
            h.height = MENU_FULL_H;
        }

        if (self.getWindow(WIN_BACK_ID)) |wb| {
            self.markDirty(wb.getBox());
            _ = self.destroyWindow(WIN_BACK_ID);
        }

        self.repopulateMainMenu() catch {};
        self.active_menu_id = null;
        self.nav_anim_state = .idle;
        self.nav_anim_progress = 0.0;
        self.updateActiveHelp();
        self.markFullDirty();
    }

    // Immediately complete any in-flight navigation animation
    pub fn completeNavAnimation(self: *DiosixGui) void {
        if (self.nav_anim_state == .idle) return;
        if (self.nav_anim_state == .opening) {
            self.nav_anim_progress = 1.0;
            self.applyNavAnimation();
            self.nav_anim_state = .idle;
        } else if (self.nav_anim_state == .closing) {
            self.nav_anim_progress = 0.0;
            self.applyNavAnimation();
            self.finishClosing();
        }
        self.updateActiveHelp();
    }

    // Apply interpolated positions and sizes for current animation progress
    pub fn applyNavAnimation(self: *DiosixGui) void {
        const factor = easeOutCubic(self.nav_anim_progress);

        // 1. Menu pane height: rolls up (opening) or grows down (closing)
        if (self.getWindow(WIN_MENU_ID)) |win_menu| {
            const old_box = win_menu.getBox();
            const target_h: u32 = @intFromFloat(@as(f32, @floatFromInt(MENU_FULL_H)) - @as(f32, @floatFromInt(MENU_FULL_H - MENU_CONTRACTED_H)) * factor);
            win_menu.height = target_h;
            const new_box = win_menu.getBox();
            self.markDirty(old_box.merge(new_box));
        }

        // 2. Back pane: slides in under menu pane from left (-132 -> 16)
        if (self.getWindow(WIN_BACK_ID)) |win_back| {
            const old_box = win_back.getBox();
            const offscreen_x: i32 = -@as(i32, @intCast(win_back.width)) - 20;
            const onscreen_x: i32 = BORDER_GAP;
            const cur_x: i32 = @intFromFloat(@as(f32, @floatFromInt(offscreen_x)) + @as(f32, @floatFromInt(onscreen_x - offscreen_x)) * factor);
            win_back.x = cur_x;
            win_back.onscreen_x = cur_x;
            const new_box = win_back.getBox();
            self.markDirty(old_box.merge(new_box));
        }

        // 3. Child pane: slides in from right (target_x + 80 -> target_x)
        if (self.getChildWindowId()) |cid| {
            if (self.getWindow(cid)) |cwin| {
                const old_box = cwin.getBox();
                const target_x = self.getChildTargetX();
                const offset: f32 = 80.0 * (1.0 - factor);
                const cur_x: i32 = @intFromFloat(@as(f32, @floatFromInt(target_x)) + offset);
                cwin.x = cur_x;
                cwin.onscreen_x = cur_x;
                const new_box = cwin.getBox();
                self.markDirty(old_box.merge(new_box));
            }
        }
    }

    // Teardown child panes and Back pane, restoring full Main Menu
    pub fn teardownChildPanes(self: *DiosixGui) void {
        const head = self.getWindow(WIN_MENU_ID) orelse return;
        if (head.child_window_id) |cid| {
            if (self.getWindow(cid)) |cwin| {
                self.markDirty(cwin.getBox());
            }
            _ = self.destroyWindow(cid);
            head.child_window_id = null;
        }

        if (self.getWindow(WIN_BACK_ID)) |wb| {
            self.markDirty(wb.getBox());
            _ = self.destroyWindow(WIN_BACK_ID);
        }

        self.repopulateMainMenu() catch {};
        self.active_menu_id = null;
        self.nav_anim_state = .idle;
        self.nav_anim_progress = 0.0;
        self.updateActiveHelp();
        self.markFullDirty();
    }

    // Toggle Status pane open or closed
    pub fn toggleStatusPane(self: *DiosixGui) !void {
        try self.activateMenuItem(ICON_MENU_STATUS_ID);
    }

    // Toggle Config pane open or closed
    pub fn toggleConfigPane(self: *DiosixGui) !void {
        try self.activateMenuItem(ICON_MENU_CONFIG_ID);
    }

    // Refresh live telemetry inside Status pane
    pub fn updateStatusPaneData(self: *DiosixGui) void {
        const secs = host_info.getHostUptimeSeconds();
        self.last_uptime_sec = secs orelse 0;

        var uptime_buf: [64]u8 = undefined;
        const uptime_str = host_info.formatUptime(&uptime_buf);
        if (self.findIcon(WIN_STATUS_ID, ICON_STATUS_HOST_UPTIME_ID)) |icon| {
            icon.setText(uptime_str);
        }

        var cpu_buf: [64]u8 = undefined;
        const cpu_str = host_info.getHostCpuString(&cpu_buf);
        if (self.findIcon(WIN_STATUS_ID, ICON_STATUS_HOST_CPU_ID)) |icon| {
            icon.setText(cpu_str);
        }

        var ram_buf: [80]u8 = undefined;
        const ram_str = host_info.getHostRamString(&ram_buf);
        if (self.findIcon(WIN_STATUS_ID, ICON_STATUS_HOST_RAM_ID)) |icon| {
            icon.setText(ram_str);
        }

        var dt_buf: [80]u8 = undefined;
        const dt_str = host_info.getHostDateTimeString(&dt_buf);
        if (self.findIcon(WIN_STATUS_ID, ICON_STATUS_HOST_TIME_ID)) |icon| {
            icon.setText(dt_str);
        }

        var b1_buf: [160]u8 = undefined;
        var b2_buf: [160]u8 = undefined;
        const split = host_info.getHvBuildSplit(&b1_buf, &b2_buf);
        if (self.findIcon(WIN_STATUS_ID, ICON_STATUS_HV_BUILD1_ID)) |icon| {
            icon.setText(split.line1);
        }
        if (self.findIcon(WIN_STATUS_ID, ICON_STATUS_HV_BUILD2_ID)) |icon| {
            icon.setText(split.line2);
        }

        var foot_buf: [80]u8 = undefined;
        const foot_str = host_info.getHvFootprintString(&foot_buf);
        if (self.findIcon(WIN_STATUS_ID, ICON_STATUS_HV_FOOTPRINT_ID)) |icon| {
            icon.setText(foot_str);
        }

        self.markWindowDirty(WIN_STATUS_ID);
    }

    pub fn hasActiveAnimation(self: *const DiosixGui) bool {
        return self.nav_anim_state != .idle;
    }

    // Called every frame with delta time in milliseconds
    pub fn tick(self: *DiosixGui, dt_ms: u32) void {
        // Animate menu roll-up / grow-down and pane sliding
        if (self.nav_anim_state != .idle) {
            const step = @as(f32, @floatFromInt(dt_ms)) / self.nav_anim_duration_ms;
            if (self.nav_anim_state == .opening) {
                self.nav_anim_progress += step;
                if (self.nav_anim_progress >= 1.0) {
                    self.nav_anim_progress = 1.0;
                    self.applyNavAnimation();
                    self.nav_anim_state = .idle;
                } else {
                    self.applyNavAnimation();
                }
            } else if (self.nav_anim_state == .closing) {
                self.nav_anim_progress -= step;
                if (self.nav_anim_progress <= 0.0) {
                    self.nav_anim_progress = 0.0;
                    self.applyNavAnimation();
                    self.finishClosing();
                } else {
                    self.applyNavAnimation();
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

        // Gradual background texture drift
        if (self.bg_animation_speed > 0) {
            self.drift_accum_ms += dt_ms * self.bg_animation_speed;
            const threshold = DRIFT_INTERVAL_MS * 100;
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

    pub fn setBgAnimationSpeed(self: *DiosixGui, speed: u32) void {
        const clamped = std.math.clamp(speed, 0, 100);
        if (clamped == 0) {
            self.drift_accum_ms = 0;
        }
        self.bg_animation_speed = clamped;
    }

    pub fn getBgAnimationSpeed(self: *const DiosixGui) u32 {
        return self.bg_animation_speed;
    }

    pub fn setDriftDirection(self: *DiosixGui, dir: DriftDirection) void {
        self.drift_dir = dir;
    }

    pub fn getDriftDirection(self: *const DiosixGui) DriftDirection {
        return self.drift_dir;
    }

    // --- Damage Tracking ---

    pub fn markDirty(self: *DiosixGui, box: fb.Box) void {
        self.dirty_box = self.dirty_box.merge(box);
    }

    pub fn markFullDirty(self: *DiosixGui) void {
        self.dirty_box = fb.Box.fromPosSize(0, 0, self.width, self.height);
    }

    pub fn markWindowDirty(self: *DiosixGui, win_id: u32) void {
        for (self.windows.items) |*win| {
            if (win.id == win_id and win.is_onscreen) {
                self.markDirty(win.getBox());
                break;
            }
        }
    }

    pub fn isDirty(self: *const DiosixGui) bool {
        return !self.dirty_box.isEmpty();
    }

    // --- Window and Icon Queries ---

    pub fn setWindowOnScreen(self: *DiosixGui, win_id: u32, on: bool) void {
        for (self.windows.items) |*win| {
            if (win.id == win_id) {
                const was_on = win.is_onscreen;
                win.setOnScreen(on);
                if (was_on != on) {
                    self.markDirty(fb.Box.fromPosSize(win.onscreen_x, win.onscreen_y, win.width, win.height));
                    if (win.linked_menu_item_id) |m_id| {
                        self.setMenuItemSelected(m_id, on);
                    } else if (win_id == WIN_STATUS_ID) {
                        self.setStatusMenuSelected(on);
                    }
                }
                break;
            }
        }
    }

    // Update selected state of a menu item in Main Menu
    pub fn setMenuItemSelected(self: *DiosixGui, menu_item_id: u32, selected: bool) void {
        if (self.getWindow(WIN_MENU_ID)) |mw| {
            if (mw.getIconById(menu_item_id)) |icon| {
                if (icon.is_selected != selected) {
                    icon.setSelected(selected);
                    self.markDirty(mw.getBox());
                }
            }
        }
    }

    // Update selected state of Status item in Main Menu
    pub fn setStatusMenuSelected(self: *DiosixGui, selected: bool) void {
        self.setMenuItemSelected(ICON_MENU_STATUS_ID, selected);
    }

    pub fn findIcon(self: *DiosixGui, win_id: u32, icon_id: u32) ?*Icon {
        for (self.windows.items) |*win| {
            if (win.id == win_id) {
                if (win.is_onscreen) {
                    self.markDirty(win.getBox());
                }
                return win.getIconById(icon_id);
            }
        }
        return null;
    }

    pub fn setWindowTransparency(self: *DiosixGui, pct: u32) void {
        const clamped = std.math.clamp(pct, 0, 100);
        if (self.window_transparency != clamped) {
            self.window_transparency = clamped;
            self.markFullDirty();
        }
    }

    pub fn getWindowOpacityAlpha(self: *const DiosixGui) u8 {
        const opacity_pct: u32 = if (self.window_transparency >= 100) 0 else (100 - self.window_transparency);
        return @intCast((opacity_pct * 255) / 100);
    }

    pub fn setBlurStrength(self: *DiosixGui, pct: u32) void {
        const clamped = std.math.clamp(pct, 0, 100);
        if (self.blur_strength != clamped) {
            self.blur_strength = clamped;
            self.markFullDirty();
        }
    }

    pub fn getBlurStrength(self: *const DiosixGui) u32 {
        return self.blur_strength;
    }

    pub fn getBlurRadius(self: *const DiosixGui) u32 {
        return @divTrunc(self.blur_strength * 10, 100);
    }

    pub fn setBackdropTopColor(self: *DiosixGui, col: u32) void {
        if (self.bg_top_color != col) {
            self.bg_top_color = col;
            self.markFullDirty();
        }
    }

    pub fn setBackdropBotColor(self: *DiosixGui, col: u32) void {
        if (self.bg_bot_color != col) {
            self.bg_bot_color = col;
            self.markFullDirty();
        }
    }

    // --- Input Dispatch & Mouse Management ---

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
                const changed = win.handleMouseRelease();
                if (changed) {
                    self.markDirty(win.getBox());
                }
            }
        }
    }

    pub fn handleMouseMove(self: *DiosixGui, px: i32, py: i32, left_down: bool) void {
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
                } else {
                    if (win.clearHover()) {
                        self.markDirty(win.getBox());
                    }
                }
            }
        } else {
            // Find strictly the ONE topmost window containing (px, py)
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
                } else {
                    if (win.clearHover()) {
                        self.markDirty(win.getBox());
                    }
                }
            }
        }

        self.updateActiveHelp();
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
                    self.focusWindow(win_idx);
                }
                _ = win.handleMouseClick(self, px, py);
                if (win.active_drag_icon_idx != null or win.is_dragging_scrollbar) {
                    self.active_drag_win_id = win.id;
                } else {
                    self.active_drag_win_id = null;
                }
                self.markDirty(win.getBox());

                // Reset active press and dragging on all other windows
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
        self.updateActiveHelp();
    }

    pub fn handleMouseScroll(self: *DiosixGui, px: i32, py: i32, delta: i32) void {
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
        if (self.getActiveWindow()) |win| {
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

    pub fn getActiveWindow(self: *DiosixGui) ?*Window {
        if (self.active_win_idx) |idx| {
            if (idx < self.windows.items.len) return &self.windows.items[idx];
        }
        return null;
    }

    // --- Render Pipeline ---

    // Intelligent damage-aware redraw into clean_surface (without cursor)
    // Returns the damaged bounding box that was redrawn (empty if nothing changed)
    pub fn renderDamaged(self: *DiosixGui, clean_surface: *fb.Surface) fb.Box {
        if (self.dirty_box.isEmpty()) return fb.Box{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };

        const screen_box = fb.Box.fromPosSize(0, 0, self.width, self.height);
        const damage = self.dirty_box.intersect(screen_box);
        self.dirty_box = fb.Box{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };

        if (damage.isEmpty()) return fb.Box{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };

        const win_alpha = self.getWindowOpacityAlpha();
        const blur_radius = self.getBlurRadius();

        const is_full_screen = (damage.x0 == 0 and damage.y0 == 0 and
            damage.x1 == @as(i32, @intCast(self.width)) and
            damage.y1 == @as(i32, @intCast(self.height)));

        if (is_full_screen) {
            clean_surface.drawGraduatedBackgroundDrift(self.bg_top_color, self.bg_bot_color, self.drift_x, self.drift_y);
            for (self.windows.items) |*win| {
                if (win.is_onscreen) {
                    const win_box = win.getBox();
                    clean_surface.drawBlurredBackdropInBoxDrift(win_box, win_box, self.bg_top_color, self.bg_bot_color, blur_radius, Window.CORNER_RADIUS, self.blur_scratch, self.drift_x, self.drift_y);
                    win.render(clean_surface, win_alpha);
                }
            }
        } else {
            clean_surface.drawGraduatedBackgroundInBoxDrift(damage, self.bg_top_color, self.bg_bot_color, self.drift_x, self.drift_y);
            // Redraw any on-screen window intersecting damage
            for (self.windows.items) |*win| {
                if (win.is_onscreen and win.intersectsBox(damage)) {
                    const win_box = win.getBox();
                    clean_surface.drawBlurredBackdropInBoxDrift(win_box, win_box, self.bg_top_color, self.bg_bot_color, blur_radius, Window.CORNER_RADIUS, self.blur_scratch, self.drift_x, self.drift_y);
                    win.render(clean_surface, win_alpha);
                }
            }
        }

        return damage;
    }

    pub fn render(self: *DiosixGui, surface: *fb.Surface) void {
        self.markFullDirty();
        _ = self.renderDamaged(surface);
        if (self.cursor.visible) {
            self.cursor.draw(surface);
        }
    }

    pub fn drawWindowsWithAlpha(self: *DiosixGui, surface: *fb.Surface, alpha_factor: f32) void {
        const base_win_alpha = self.getWindowOpacityAlpha();
        const win_alpha: u8 = @intFromFloat(@as(f32, @floatFromInt(base_win_alpha)) * std.math.clamp(alpha_factor, 0.0, 1.0));
        const blur_radius = self.getBlurRadius();
        for (self.windows.items) |*win| {
            if (win.is_onscreen) {
                const win_box = win.getBox();
                surface.drawBlurredBackdropInBoxDrift(win_box, win_box, self.bg_top_color, self.bg_bot_color, blur_radius, Window.CORNER_RADIUS, self.blur_scratch, self.drift_x, self.drift_y);
                win.render(surface, win_alpha);
            }
        }
    }
};
