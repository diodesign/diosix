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

pub const TAB_BAR_HEIGHT: u32 = 0;
pub const BORDER_GAP: i32 = 16;

// Standard Window & Icon IDs
pub const WIN_MENU_ID: u32 = 100;
pub const WIN_VERSION_ID: u32 = 101;
pub const WIN_HELP_ID: u32 = 103;
pub const WIN_STATUS_ID: u32 = 104;
pub const WIN_CONFIG_ID: u32 = 105;

pub const ICON_MENU_GUESTS_ID: u32 = 1001;
pub const ICON_MENU_STATUS_ID: u32 = 1002;
pub const ICON_MENU_CONFIG_ID: u32 = 1003;
pub const ICON_VERSION_TEXT_ID: u32 = 1011;
pub const ICON_HELP_TEXT_ID: u32 = 1031;

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

pub const Key = struct {
    pub const ESC: u16 = 1;
    pub const BACKSPACE: u16 = 14;
    pub const TAB: u16 = 15;
    pub const U: u16 = 22;
    pub const ENTER: u16 = 28;
    pub const LEFT_CTRL: u16 = 29;
    pub const A: u16 = 30;
    pub const F: u16 = 33;
    pub const LEFT_SHIFT: u16 = 42;
    pub const Z: u16 = 44;
    pub const X: u16 = 45;
    pub const C: u16 = 46;
    pub const V: u16 = 47;
    pub const RIGHT_SHIFT: u16 = 54;
    pub const SPACE: u16 = 57;
    pub const F6: u16 = 64;
    pub const RIGHT_CTRL: u16 = 97;
    pub const HOME: u16 = 102;
    pub const UP: u16 = 103;
    pub const PAGE_UP: u16 = 104;
    pub const LEFT: u16 = 105;
    pub const RIGHT: u16 = 106;
    pub const END: u16 = 107;
    pub const DOWN: u16 = 108;
    pub const PAGE_DOWN: u16 = 109;
    pub const DELETE: u16 = 111;
};

pub const CLIPBOARD_CAPACITY: usize = 256;

pub const InputMode = enum {
    mouse,
    keyboard,
};

pub const DiosixGui = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,

    windows: std.ArrayList(Window),
    active_win_idx: ?usize = null,

    // Dynamic input mode: mouse pointer vs keyboard pointer
    input_mode: InputMode = .keyboard,

    cursor: cursor_mod.Cursor,
    mouse_left_down: bool = false,

    // Keyboard modifier states tracked from input events
    ctrl_down: bool = false,
    shift_down: bool = false,

    // System clipboard for text copy / cut / paste (guaranteed null-terminated)
    clipboard_buf: [CLIPBOARD_CAPACITY + 1]u8 = @splat(0),
    clipboard_len: usize = 0,

    // Real-time window transparency percentage (0 = fully opaque, 100 = invisible; default 50%)
    window_transparency: u32 = 50,

    // Real-time backdrop Gaussian blur strength (0 = no blur, 100 = max blur; default 50%)
    blur_strength: u32 = 50,

    // Static graduated background colors (default light blue top, dark blue bottom)
    bg_top_color: u32 = fb.Color.SKY_BASE_TOP,
    bg_bot_color: u32 = fb.Color.GRADIENT_BOT_DEFAULT,

    // Damage tracking: dirty bounding box needing redraw
    dirty_box: fb.Box = fb.Box{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 },

    // Scratch buffer for deterministic separable Gaussian blur passes
    blur_scratch: []u32,

    // Live host telemetry tracking
    uptime_accum_ms: u32 = 0,
    last_uptime_sec: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !DiosixGui {
        const total_h = std.math.add(usize, height, 64) catch return error.InvalidDimensions;
        const scratch_len = std.math.mul(usize, width, total_h) catch return error.InvalidDimensions;
        const scratch_mem = try allocator.alloc(u32, scratch_len);

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
            .blur_scratch = scratch_mem,
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
                self.markConnectorDirty();
                if (win.is_onscreen) {
                    self.markDirty(win.getBox());
                }
                win.deinit();
                _ = self.windows.orderedRemove(idx);
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
        self.markFullDirty();
    }

    pub fn getWindow(self: *DiosixGui, id: u32) ?*Window {
        for (self.windows.items) |*win| {
            if (win.id == id) return win;
        }
        return null;
    }

    // --- Dynamic Layout Builders ---

    // Menu item activation callback
    fn onMenuItemActivated(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
        _ = win_ctx;
        const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
        self.activateMenuItem(icon.id) catch {};
    }

    // Dynamically sized menu on left-hand side with border gap
    pub fn buildMainMenu(self: *DiosixGui) !void {
        const menu_items = [_][]const u8{ "Guests", "Status", "Config" };
        const menu_ids = [_]u32{ ICON_MENU_GUESTS_ID, ICON_MENU_STATUS_ID, ICON_MENU_CONFIG_ID };
        const menu_helps = [_][]const u8{
            "View and manage guest virtual machines",
            "View real-time system information",
            "Configure window appearance and desktop background themes",
        };

        // 1. Determine dynamic width based on longest item scaled 1.2x (6:5)
        var max_w: u32 = 0;
        for (menu_items) |item_str| {
            const w = font.measureStringScaled(item_str, 6, 5);
            if (w > max_w) max_w = w;
        }

        const hand_marker_space: i32 = 28; // space on left for keyboard pointer hand marker
        const right_pad: u32 = 24;
        const item_w = max_w + 8;
        const menu_w = @as(u32, @intCast(hand_marker_space)) + item_w + right_pad;

        // 2. Determine dynamic height based on vertical layout
        const item_h: u32 = 28;
        const item_spacing: u32 = 8;
        const top_pad: i32 = 14;
        const bot_pad: i32 = 14;
        const total_content_h: u32 = @intCast(top_pad + bot_pad + @as(i32, @intCast(menu_items.len * item_h + (menu_items.len - 1) * item_spacing)));

        const max_avail_h = if (self.height > @as(u32, @intCast(BORDER_GAP * 2)))
            self.height - @as(u32, @intCast(BORDER_GAP * 2))
        else
            self.height;

        // If content exceeds screen height, clamp window height so it turns scrollable
        const win_h = @min(total_content_h, max_avail_h);

        const win = try self.createWindow(WIN_MENU_ID, BORDER_GAP, BORDER_GAP, menu_w, win_h, null);
        win.setHelpText("Main menu");

        var cur_y: i32 = top_pad;
        for (menu_items, 0..) |item_str, idx| {
            var icon = Icon.createMenuItem(menu_ids[idx], hand_marker_space, cur_y, item_w, item_h, item_str);
            icon.setHelpText(menu_helps[idx]);
            icon.callback = onMenuItemActivated;
            if (idx == 0) icon.is_focused = true;
            _ = try win.addIcon(icon);
            cur_y += @as(i32, @intCast(item_h + item_spacing));
        }
        win.focused_icon_idx = 0;
    }

    // Build bottom panes: Active Help pane on bottom-left, Version pane on bottom-right
    pub fn buildBottomPanes(self: *DiosixGui) !void {
        var ver_buf: [64]u8 = undefined;
        const ver_str = host_info.getVersionString(&ver_buf);
        const ver_text_w = font.measureString(ver_str);

        // Version Pane sizing (bottom-right)
        const ver_h: u32 = 40;
        const ver_pad_h: u32 = 14;
        const ver_w = ver_text_w + ver_pad_h * 2;
        const ver_x = @as(i32, @intCast(self.width)) - @as(i32, @intCast(ver_w)) - BORDER_GAP;
        const ver_y = @as(i32, @intCast(self.height)) - @as(i32, @intCast(ver_h)) - BORDER_GAP;

        const win_ver = try self.createWindow(WIN_VERSION_ID, ver_x, ver_y, ver_w, ver_h, null);
        win_ver.setHelpText("Hypervisor build information");
        var ver_icon = Icon.createReadOnly(ICON_VERSION_TEXT_ID, @intCast(ver_pad_h), 8, ver_text_w + 4, 24, ver_str);
        ver_icon.setHelpText("Hypervisor name, version number, build branch, and commit hash");
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

        switch (self.input_mode) {
            .mouse => {
                // Priority 1: Icon under mouse cursor with help text
                if (self.findIconAt(self.cursor.x, self.cursor.y)) |icon| {
                    if (icon.getHelpText()) |ht| {
                        if (ht.len > 0) help_str = ht;
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
            },
            .keyboard => {
                const act_win = self.getActiveWindow();
                if (act_win) |win| {
                    // Priority 1: Focused icon with help text
                    if (win.getFocusedIcon()) |icon| {
                        if (icon.getHelpText()) |ht| {
                            if (ht.len > 0) help_str = ht;
                        }
                    }
                    // Priority 2: Active pane with help text
                    if (help_str == null) {
                        if (win.getHelpText()) |ht| {
                            if (ht.len > 0) help_str = ht;
                        }
                    }
                }
            },
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
        self.markConnectorDirty();

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

    // Build the Config pane allowing user configuration of transparency, blur, and theme colors
    pub fn buildConfigPane(self: *DiosixGui) !void {
        const menu_win = self.getWindow(WIN_MENU_ID);
        const config_x: i32 = if (menu_win) |mw| mw.x + @as(i32, @intCast(mw.width)) + BORDER_GAP else 172;
        const config_y: i32 = BORDER_GAP;
        const max_w = @as(i32, @intCast(self.width)) - BORDER_GAP - config_x;
        const config_w: u32 = if (max_w > 0) @intCast(max_w) else 780;
        const config_h: u32 = 224;

        const win = try self.createWindow(WIN_CONFIG_ID, config_x, config_y, config_w, config_h, null);
        win.setHelpText("System configuration and appearance settings");
        win.parent_window_id = WIN_MENU_ID;
        win.linked_menu_item_id = ICON_MENU_CONFIG_ID;
        if (menu_win) |mw| {
            mw.child_window_id = WIN_CONFIG_ID;
        }
        self.setMenuItemSelected(ICON_MENU_CONFIG_ID, true);
        self.markConnectorDirty();

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

        // Heading: Desktop Theme
        var theme_hdr = Icon.createReadOnly(ICON_CONFIG_THEME_LBL_ID, pad_x, 120, 200, line_h, "Color Themes");
        theme_hdr.setCustomColor(fb.Color.ACCENT_CYAN);
        _ = try win.addIcon(theme_hdr);

        // Row 3: Theme Buttons
        const btn_w: u32 = 110;
        const btn_h: u32 = 28;
        const btn_spacing: i32 = 16;
        var btn_x: i32 = col2_x;

        var btn_day = Icon.createButton(ICON_CONFIG_THEME_DAY_ID, btn_x, 142, btn_w, btn_h, "Day Sky");
        btn_day.setHelpText("Classic light blue daytime sky gradient");
        btn_day.callback = onThemeButtonClicked;
        _ = try win.addIcon(btn_day);
        btn_x += @as(i32, @intCast(btn_w)) + btn_spacing;

        var btn_mid = Icon.createButton(ICON_CONFIG_THEME_MIDNIGHT_ID, btn_x, 142, btn_w, btn_h, "Midnight");
        btn_mid.setHelpText("Deep dark navy night sky gradient");
        btn_mid.callback = onThemeButtonClicked;
        _ = try win.addIcon(btn_mid);
        btn_x += @as(i32, @intCast(btn_w)) + btn_spacing;

        var btn_sun = Icon.createButton(ICON_CONFIG_THEME_SUNSET_ID, btn_x, 142, btn_w, btn_h, "Sunset");
        btn_sun.setHelpText("Warm crimson dusk sunset gradient");
        btn_sun.callback = onThemeButtonClicked;
        _ = try win.addIcon(btn_sun);
        btn_x += @as(i32, @intCast(btn_w)) + btn_spacing;

        var btn_emr = Icon.createButton(ICON_CONFIG_THEME_EMERALD_ID, btn_x, 142, btn_w, btn_h, "Emerald");
        btn_emr.setHelpText("Forest aurora green gradient");
        btn_emr.callback = onThemeButtonClicked;
        _ = try win.addIcon(btn_emr);
    }

    // Activate a menu item: closes any previous child pane and opens the selected one
    pub fn activateMenuItem(self: *DiosixGui, menu_item_id: u32) !void {
        const head = self.getWindow(WIN_MENU_ID) orelse return;
        const curr_child_id = head.child_window_id;

        if (curr_child_id) |cid| {
            if (self.getWindow(cid)) |cwin| {
                if (cwin.linked_menu_item_id == menu_item_id) {
                    // Clicking the already-open menu item toggles it closed
                    self.teardownChildPanes();
                    self.updateActiveHelp();
                    return;
                }
            }
            // Different menu item was clicked: teardown previous pane chain from tail to head
            self.teardownChildPanes();
        }

        // Open the pane for the selected menu item
        switch (menu_item_id) {
            ICON_MENU_STATUS_ID => {
                try self.buildStatusPane();
            },
            ICON_MENU_CONFIG_ID => {
                try self.buildConfigPane();
            },
            ICON_MENU_GUESTS_ID => {},
            else => {},
        }

        self.updateActiveHelp();
    }

    // Teardown linked list of child panes starting from the tail back to head
    pub fn teardownChildPanes(self: *DiosixGui) void {
        const head = self.getWindow(WIN_MENU_ID) orelse return;
        const first_child_id = head.child_window_id orelse return;

        // Find the tail of the chain
        var curr_id: u32 = first_child_id;
        while (true) {
            if (self.getWindow(curr_id)) |w| {
                if (w.child_window_id) |cid| {
                    curr_id = cid;
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        // Teardown from tail back to first child
        while (true) {
            const curr_win = self.getWindow(curr_id) orelse break;
            const parent_id = curr_win.parent_window_id;

            // If this child pane was linked to a menu item, unselect that menu item
            if (curr_win.linked_menu_item_id) |m_id| {
                self.setMenuItemSelected(m_id, false);
            }

            // Mark connector dirty before destroying window
            self.markConnectorDirty();

            // Destroy window
            _ = self.destroyWindow(curr_id);

            if (parent_id) |pid| {
                if (self.getWindow(pid)) |pwin| {
                    pwin.child_window_id = null;
                }
                if (pid == WIN_MENU_ID) {
                    break;
                }
                curr_id = pid;
            } else {
                break;
            }
        }

        head.child_window_id = null;
        self.markConnectorDirty();
        self.updateActiveHelp();
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

    // Called every frame with delta time in milliseconds
    pub fn tick(self: *DiosixGui, dt_ms: u32) void {
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
                        self.markConnectorDirty();
                    } else if (win_id == WIN_STATUS_ID) {
                        self.setStatusMenuSelected(on);
                        self.markConnectorDirty();
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

    // Returns the bounding box of the visual bridge connecting Main Menu and its active child pane
    pub fn getActiveChildConnectorBox(self: *DiosixGui) ?fb.Box {
        const mw = self.getWindow(WIN_MENU_ID) orelse return null;
        const first_child_id = mw.child_window_id orelse return null;
        const child = self.getWindow(first_child_id) orelse return null;
        if (!child.is_onscreen) return null;

        const linked_menu_id = child.linked_menu_item_id orelse return null;
        const icon = mw.getIconById(linked_menu_id) orelse return null;

        const x_start = mw.x + @as(i32, @intCast(mw.width));
        const x_end = child.x;
        const cy = mw.y + icon.rel_y + @as(i32, @intCast(icon.height / 2));

        const pad: i32 = 5; // cover radius 3 + 1px drop-shadow + 1px boundary margin
        return fb.Box{
            .x0 = x_start - pad,
            .y0 = cy - pad,
            .x1 = x_end + pad + 1,
            .y1 = cy + pad + 2,
        };
    }

    pub fn getMenuStatusConnectorBox(self: *DiosixGui) ?fb.Box {
        return self.getActiveChildConnectorBox();
    }

    // Mark the connector region dirty for redrawing or erasing
    pub fn markConnectorDirty(self: *DiosixGui) void {
        if (self.getActiveChildConnectorBox()) |box| {
            self.markDirty(box);
        }
    }

    // Render elegant connecting link between Main Menu item and the active child pane
    pub fn drawActiveChildConnector(self: *DiosixGui, surface: *fb.Surface) void {
        const mw = self.getWindow(WIN_MENU_ID) orelse return;
        const first_child_id = mw.child_window_id orelse return;
        const child = self.getWindow(first_child_id) orelse return;
        if (!child.is_onscreen) return;

        const linked_menu_id = child.linked_menu_item_id orelse return;
        const icon = mw.getIconById(linked_menu_id) orelse return;

        const x_start = mw.x + @as(i32, @intCast(mw.width));
        const x_end = child.x;
        const cy = mw.y + icon.rel_y + @as(i32, @intCast(icon.height / 2));

        if (x_end <= x_start) return;

        const shadow_color = fb.Color.rgb(10, 16, 26);

        // 1. Subtle drop-shadow offset at (0, 1) for contrast against clouds
        surface.drawHorizontalLine(x_start, x_end, cy + 1, shadow_color);
        surface.drawFilledCircle(x_start, cy + 1, 3, shadow_color);
        surface.drawFilledCircle(x_end, cy + 1, 3, shadow_color);

        // 2. Connecting line between the panes (ACCENT_CYAN)
        surface.drawHorizontalLine(x_start, x_end, cy, fb.Color.ACCENT_CYAN);

        // 3. Small filled circular nodes at each end of the line (radius 3)
        surface.drawFilledCircle(x_start, cy, 3, fb.Color.ACCENT_CYAN);
        surface.drawFilledCircle(x_end, cy, 3, fb.Color.ACCENT_CYAN);

        // 4. Subtle luminous white core pip (1px center dot)
        surface.setPixel(x_start, cy, fb.Color.WHITE);
        surface.setPixel(x_end, cy, fb.Color.WHITE);
    }

    pub fn drawMenuStatusConnector(self: *DiosixGui, surface: *fb.Surface) void {
        self.drawActiveChildConnector(surface);
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

    pub fn setClipboard(self: *DiosixGui, text: []const u8) void {
        var safe_len = @min(text.len, CLIPBOARD_CAPACITY);
        if (safe_len < text.len) {
            var i = safe_len;
            while (i > 0 and (text[i - 1] & 0xC0) == 0x80) {
                i -= 1;
            }
            if (i > 0 and text[i - 1] >= 0x80) {
                const lead = text[i - 1];
                const expected_len: usize = if ((lead & 0xE0) == 0xC0)
                    2
                else if ((lead & 0xF0) == 0xE0)
                    3
                else if ((lead & 0xF8) == 0xF0)
                    4
                else
                    1;
                if (safe_len - (i - 1) < expected_len) {
                    safe_len = i - 1;
                }
            }
        }
        @memcpy(self.clipboard_buf[0..safe_len], text[0..safe_len]);
        self.clipboard_buf[safe_len] = 0;
        self.clipboard_len = safe_len;
    }

    pub fn getClipboard(self: *const DiosixGui) []const u8 {
        const safe_len = @min(self.clipboard_len, CLIPBOARD_CAPACITY);
        return self.clipboard_buf[0..safe_len];
    }

    // --- Input Dispatch & Mode Management ---

    pub fn setInputMode(self: *DiosixGui, mode: InputMode) void {
        if (self.input_mode != mode) {
            self.input_mode = mode;
            if (mode == .keyboard) {
                self.cursor.visible = false;
                self.clearMouseHover();
            } else {
                self.cursor.visible = true;
            }
            self.markFullDirty();
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
        self.setInputMode(.mouse);
        self.cursor.x = px;
        self.cursor.y = py;
        self.mouse_left_down = left_down;

        for (self.windows.items) |*win| {
            if (win.is_onscreen) {
                const changed = win.handleMouseMove(self, px, py, left_down);
                if (changed) {
                    self.markDirty(win.getBox());
                }
            }
        }

        self.updateActiveHelp();
    }

    pub fn handleMouseClick(self: *DiosixGui, px: i32, py: i32) void {
        self.setInputMode(.mouse);
        var i = self.windows.items.len;
        while (i > 0) : (i -= 1) {
            const win = &self.windows.items[i - 1];
            if (win.is_onscreen and win.contains(px, py)) {
                if (win.hasInteractiveIcons() or win.isScrollable()) {
                    self.focusWindow(i - 1);
                }
                _ = win.handleMouseClick(self, px, py);
                self.markDirty(win.getBox());
                break;
            }
        }
        self.updateActiveHelp();
    }

    pub fn handleMouseScroll(self: *DiosixGui, px: i32, py: i32, delta: i32) void {
        self.setInputMode(.mouse);
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

    pub fn focusNextPane(self: *DiosixGui) void {
        const total = self.windows.items.len;
        if (total == 0) return;
        const cur_idx = self.active_win_idx orelse 0;

        var i: usize = 1;
        while (i <= total) : (i += 1) {
            const check = (cur_idx + i) % total;
            const win = &self.windows.items[check];
            if (win.is_onscreen and win.hasInteractiveIcons()) {
                self.focusWindow(check);
                if (win.focused_icon_idx == null) {
                    _ = win.focusFirstInteractiveIcon();
                }
                self.markDirty(win.getBox());
                return;
            }
        }
    }

    pub fn focusPrevPane(self: *DiosixGui) void {
        const total = self.windows.items.len;
        if (total == 0) return;
        const cur_idx = self.active_win_idx orelse 0;

        var i: usize = 1;
        while (i <= total) : (i += 1) {
            const check = (cur_idx + total * total - i) % total;
            const win = &self.windows.items[check];
            if (win.is_onscreen and win.hasInteractiveIcons()) {
                self.focusWindow(check);
                if (win.focused_icon_idx == null) {
                    _ = win.focusLastInteractiveIcon();
                }
                self.markDirty(win.getBox());
                return;
            }
        }
    }

    pub fn focusNextPaneFirst(self: *DiosixGui) void {
        const total = self.windows.items.len;
        if (total == 0) return;
        const cur_idx = self.active_win_idx orelse 0;

        var i: usize = 1;
        while (i <= total) : (i += 1) {
            const check = (cur_idx + i) % total;
            const win = &self.windows.items[check];
            if (win.is_onscreen and win.hasInteractiveIcons()) {
                self.focusWindow(check);
                _ = win.focusFirstInteractiveIcon();
                self.markDirty(win.getBox());
                return;
            }
        }
        if (self.getActiveWindow()) |cur_win| {
            _ = cur_win.focusFirstInteractiveIcon();
            self.markDirty(cur_win.getBox());
        }
    }

    pub fn focusPrevPaneLast(self: *DiosixGui) void {
        const total = self.windows.items.len;
        if (total == 0) return;
        const cur_idx = self.active_win_idx orelse 0;

        var i: usize = 1;
        while (i <= total) : (i += 1) {
            const check = (cur_idx + total * total - i) % total;
            const win = &self.windows.items[check];
            if (win.is_onscreen and win.hasInteractiveIcons()) {
                self.focusWindow(check);
                _ = win.focusLastInteractiveIcon();
                self.markDirty(win.getBox());
                return;
            }
        }
        if (self.getActiveWindow()) |cur_win| {
            _ = cur_win.focusLastInteractiveIcon();
            self.markDirty(cur_win.getBox());
        }
    }

    pub fn focusNextWindow(self: *DiosixGui) void {
        self.focusNextPane();
    }

    pub fn handleKey(self: *DiosixGui, key_code: u16, key_char: ?u8, pressed: bool) void {
        self.handleKeyWithModifiers(key_code, key_char, pressed, self.ctrl_down, self.shift_down);
    }

    pub fn handleKeyWithModifiers(self: *DiosixGui, key_code: u16, key_char: ?u8, pressed: bool, ctrl: bool, shift: bool) void {
        if (!pressed) {
            if (key_code == Key.ENTER or key_code == Key.SPACE) {
                if (self.getActiveWindow()) |win| {
                    if (win.focused_icon_idx) |idx| {
                        if (idx < win.icons.items.len) {
                            const icon = &win.icons.items[idx];
                            if (icon.is_active_press) {
                                icon.is_active_press = false;
                                self.markDirty(win.getBox());
                            }
                        }
                    }
                }
            }
            return;
        }

        // Ignore mouse button codes (0x110..0x11f) so mouse clicks never trigger keyboard mode
        if (key_code >= 0x110 and key_code <= 0x11f) return;

        self.setInputMode(.keyboard);
        defer self.updateActiveHelp();

        // Escape closes any open child pane chain
        if (key_code == Key.ESC) {
            const head = self.getWindow(WIN_MENU_ID);
            if (head != null and head.?.child_window_id != null) {
                self.teardownChildPanes();
                return;
            }
            for (self.windows.items) |*win| {
                if (win.id == WIN_STATUS_ID and win.is_onscreen) {
                    self.setWindowOnScreen(WIN_STATUS_ID, false);
                    return;
                }
            }
        }

        const active_win = self.getActiveWindow();
        if (active_win) |win| {
            if (win.focused_icon_idx == null) {
                _ = win.focusFirstInteractiveIcon();
            }
        }
        const focused_icon: ?*Icon = if (active_win) |win|
            if (win.focused_icon_idx) |idx|
                if (idx < win.icons.items.len) &win.icons.items[idx] else null
            else
                null
        else
            null;
        const is_in_text_field = if (focused_icon) |ic| (ic.icon_type == .read_write_text) else false;

        // 1. Direct Pane Navigation via F6 / Shift-F6
        if (key_code == Key.F6) {
            if (shift) {
                self.focusPrevPane();
            } else {
                self.focusNextPane();
            }
            return;
        }

        // 2. Tab Navigation: moves focus to next/prev item; transitions across panes on boundary
        // Ctrl-Tab switches directly between panes
        if (key_code == Key.TAB) {
            if (ctrl) {
                if (shift) {
                    self.focusPrevPane();
                } else {
                    self.focusNextPane();
                }
                return;
            }
            if (active_win) |win| {
                if (shift) {
                    if (!win.focusPrevIcon()) {
                        self.focusPrevPaneLast();
                    }
                } else {
                    if (!win.focusNextIcon()) {
                        self.focusNextPaneFirst();
                    }
                }
                self.markDirty(win.getBox());
                return;
            } else {
                self.focusNextPaneFirst();
                return;
            }
        }

        // Page Up / Page Down / Ctrl-Home / Ctrl-End scroll the active window pane
        if (key_code == Key.PAGE_UP) {
            if (active_win) |win| {
                if (win.scrollBy(-win.getViewportHeight())) {
                    self.markDirty(win.getBox());
                }
                return;
            }
        } else if (key_code == Key.PAGE_DOWN) {
            if (active_win) |win| {
                if (win.scrollBy(win.getViewportHeight())) {
                    self.markDirty(win.getBox());
                }
                return;
            }
        } else if (ctrl and key_code == Key.HOME) {
            if (active_win) |win| {
                if (win.scrollTo(0)) {
                    self.markDirty(win.getBox());
                }
                return;
            }
        } else if (ctrl and key_code == Key.END) {
            if (active_win) |win| {
                if (win.scrollTo(win.getMaxScroll())) {
                    self.markDirty(win.getBox());
                }
                return;
            }
        }

        // 3. Control Codes recognition (both keycode+ctrl and raw ASCII control bytes)
        const is_ctrl_a = (ctrl and (key_code == Key.A or (key_char != null and (key_char.? == 'a' or key_char.? == 'A')))) or (key_char != null and key_char.? == 1);
        const is_ctrl_c = (ctrl and (key_code == Key.C or (key_char != null and (key_char.? == 'c' or key_char.? == 'C')))) or (key_char != null and key_char.? == 3);
        const is_ctrl_v = (ctrl and (key_code == Key.V or (key_char != null and (key_char.? == 'v' or key_char.? == 'V')))) or (key_char != null and key_char.? == 22);
        const is_ctrl_x = (ctrl and (key_code == Key.X or (key_char != null and (key_char.? == 'x' or key_char.? == 'X')))) or (key_char != null and key_char.? == 24);
        const is_ctrl_u = (ctrl and (key_code == Key.U or (key_char != null and (key_char.? == 'u' or key_char.? == 'U')))) or (key_char != null and key_char.? == 21);

        // 4. If focused on a read_write_text icon, handle text field actions
        if (is_in_text_field) {
            const icon = focused_icon.?;
            const win = active_win.?;

            if (is_ctrl_a) {
                icon.selectAll();
                self.markDirty(win.getBox());
                return;
            } else if (is_ctrl_c) {
                if (icon.hasSelection()) {
                    self.setClipboard(icon.getSelectedText());
                }
                return;
            } else if (is_ctrl_x) {
                if (icon.hasSelection()) {
                    self.setClipboard(icon.getSelectedText());
                    _ = icon.deleteSelection();
                    if (icon.callback) |cb| cb(self, @ptrCast(win), icon);
                    self.markDirty(win.getBox());
                }
                return;
            } else if (is_ctrl_v) {
                const clip = self.getClipboard();
                if (clip.len > 0) {
                    _ = icon.deleteSelection();
                    icon.insertString(clip);
                    if (icon.callback) |cb| cb(self, @ptrCast(win), icon);
                    self.markDirty(win.getBox());
                }
                return;
            } else if (is_ctrl_u) {
                icon.clearField();
                if (icon.callback) |cb| cb(self, @ptrCast(win), icon);
                self.markDirty(win.getBox());
                return;
            }

            if (ctrl) return;

            if (key_code == Key.LEFT) {
                if (shift) {
                    if (icon.selection_start == null) {
                        icon.selection_start = icon.cursor_pos;
                    }
                    if (icon.cursor_pos > 0) {
                        icon.cursor_pos -= 1;
                    }
                    icon.selection_end = icon.cursor_pos;
                } else {
                    if (icon.getSelectionBounds()) |b| {
                        icon.cursor_pos = b.min;
                        icon.clearSelection();
                    } else if (icon.cursor_pos > 0) {
                        icon.cursor_pos -= 1;
                    }
                }
                self.markDirty(win.getBox());
                return;
            } else if (key_code == Key.RIGHT) {
                if (shift) {
                    if (icon.selection_start == null) {
                        icon.selection_start = icon.cursor_pos;
                    }
                    if (icon.cursor_pos < icon.text_len) {
                        icon.cursor_pos += 1;
                    }
                    icon.selection_end = icon.cursor_pos;
                } else {
                    if (icon.getSelectionBounds()) |b| {
                        icon.cursor_pos = b.max;
                        icon.clearSelection();
                    } else if (icon.cursor_pos < icon.text_len) {
                        icon.cursor_pos += 1;
                    }
                }
                self.markDirty(win.getBox());
                return;
            } else if (key_code == Key.HOME) {
                if (shift) {
                    if (icon.selection_start == null) {
                        icon.selection_start = icon.cursor_pos;
                    }
                    icon.cursor_pos = 0;
                    icon.selection_end = 0;
                } else {
                    icon.cursor_pos = 0;
                    icon.clearSelection();
                }
                self.markDirty(win.getBox());
                return;
            } else if (key_code == Key.END) {
                if (shift) {
                    if (icon.selection_start == null) {
                        icon.selection_start = icon.cursor_pos;
                    }
                    icon.cursor_pos = icon.text_len;
                    icon.selection_end = icon.text_len;
                } else {
                    icon.cursor_pos = icon.text_len;
                    icon.clearSelection();
                }
                self.markDirty(win.getBox());
                return;
            } else if (key_code == Key.BACKSPACE) {
                if (icon.hasSelection()) {
                    _ = icon.deleteSelection();
                } else {
                    icon.deleteBackward();
                }
                if (icon.callback) |cb| cb(self, @ptrCast(win), icon);
                self.markDirty(win.getBox());
                return;
            } else if (key_code == Key.DELETE) {
                if (icon.hasSelection()) {
                    _ = icon.deleteSelection();
                } else {
                    icon.deleteForward();
                }
                if (icon.callback) |cb| cb(self, @ptrCast(win), icon);
                self.markDirty(win.getBox());
                return;
            } else if (key_char) |c| {
                if (c >= 32 and c <= 126) {
                    _ = icon.deleteSelection();
                    icon.insertChar(c);
                    if (icon.callback) |cb| cb(self, @ptrCast(win), icon);
                    self.markDirty(win.getBox());
                    return;
                }
            }
        }

        // 5. Non-text field handling (Menu Items, Sliders, Action Buttons, Checkboxes, Pane Navigation)
        if (active_win) |win| {
            if (focused_icon) |icon| {
                if (icon.icon_type == .slider) {
                    if (key_code == Key.LEFT) {
                        icon.adjustSlider(-5);
                        if (icon.callback) |cb| cb(self, @ptrCast(win), icon);
                        self.markDirty(win.getBox());
                        return;
                    } else if (key_code == Key.RIGHT) {
                        icon.adjustSlider(5);
                        if (icon.callback) |cb| cb(self, @ptrCast(win), icon);
                        self.markDirty(win.getBox());
                        return;
                    } else if (key_code == Key.UP) {
                        win.focusPrevIconWrap();
                        self.markDirty(win.getBox());
                        return;
                    } else if (key_code == Key.DOWN) {
                        win.focusNextIconWrap();
                        self.markDirty(win.getBox());
                        return;
                    }
                }
            }

            // Up / Down arrow navigates vertically within the pane (wrapping around)
            if (key_code == Key.UP) {
                win.focusPrevIconWrap();
                self.markDirty(win.getBox());
                return;
            } else if (key_code == Key.DOWN) {
                win.focusNextIconWrap();
                self.markDirty(win.getBox());
                return;
            }

            // Home / End scroll to top / bottom of scrollable pane
            if (key_code == Key.HOME) {
                if (win.scrollTo(0)) {
                    self.markDirty(win.getBox());
                }
                return;
            } else if (key_code == Key.END) {
                if (win.scrollTo(win.getMaxScroll())) {
                    self.markDirty(win.getBox());
                }
                return;
            }

            // Left / Right arrow moves keyboard focus between panes
            if (key_code == Key.RIGHT) {
                self.focusNextPane();
                return;
            } else if (key_code == Key.LEFT) {
                self.focusPrevPane();
                return;
            }

            // Enter or Space activates the focused action button or toggles tickbox or triggers menu item
            if (key_code == Key.ENTER or key_code == Key.SPACE) {
                if (win.focused_icon_idx) |f_idx| {
                    if (f_idx < win.icons.items.len) {
                        win.triggerIcon(self, &win.icons.items[f_idx]);
                        self.markDirty(win.getBox());
                    }
                }
                return;
            }
        }
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

        const is_keyboard_active = (self.input_mode == .keyboard);

        if (is_full_screen) {
            clean_surface.drawGraduatedBackground(self.bg_top_color, self.bg_bot_color);
            for (self.windows.items) |*win| {
                if (win.is_onscreen) {
                    const win_box = win.getBox();
                    clean_surface.drawBlurredBackdropInBox(win_box, win_box, self.bg_top_color, self.bg_bot_color, blur_radius, Window.CORNER_RADIUS, self.blur_scratch);
                    win.render(clean_surface, win_alpha, is_keyboard_active);
                }
            }
        } else {
            clean_surface.drawGraduatedBackgroundInBox(damage, self.bg_top_color, self.bg_bot_color);
            // Redraw any on-screen window intersecting damage
            for (self.windows.items) |*win| {
                if (win.is_onscreen and win.intersectsBox(damage)) {
                    const win_box = win.getBox();
                    clean_surface.drawBlurredBackdropInBox(win_box, win_box, self.bg_top_color, self.bg_bot_color, blur_radius, Window.CORNER_RADIUS, self.blur_scratch);
                    win.render(clean_surface, win_alpha, is_keyboard_active);
                }
            }
        }

        // Draw visual bridge connecting Menu pane and active child pane if onscreen
        if (self.getActiveChildConnectorBox()) |cbox| {
            if (is_full_screen or damage.intersects(cbox)) {
                self.drawActiveChildConnector(clean_surface);
            }
        }

        return damage;
    }

    pub fn render(self: *DiosixGui, surface: *fb.Surface) void {
        self.markFullDirty();
        _ = self.renderDamaged(surface);
        if (self.input_mode == .mouse and self.cursor.visible) {
            self.cursor.draw(surface);
        }
    }

    pub fn drawWindowsWithAlpha(self: *DiosixGui, surface: *fb.Surface, alpha_factor: f32) void {
        const base_win_alpha = self.getWindowOpacityAlpha();
        const win_alpha: u8 = @intFromFloat(@as(f32, @floatFromInt(base_win_alpha)) * std.math.clamp(alpha_factor, 0.0, 1.0));
        const blur_radius = self.getBlurRadius();
        const is_keyboard_active = (self.input_mode == .keyboard);
        for (self.windows.items) |*win| {
            if (win.is_onscreen) {
                const win_box = win.getBox();
                surface.drawBlurredBackdropInBox(win_box, win_box, self.bg_top_color, self.bg_bot_color, blur_radius, Window.CORNER_RADIUS, self.blur_scratch);
                win.render(surface, win_alpha, is_keyboard_active);
            }
        }
        self.drawActiveChildConnector(surface);
    }
};
