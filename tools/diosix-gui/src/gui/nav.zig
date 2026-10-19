// Diosix GUI Menu Navigation, Animation, and Frame Tick Coordinator.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const fb = @import("../framebuffer.zig");
const font = @import("../font.zig");
const icon_mod = @import("../icon.zig");
const Icon = icon_mod.Icon;
const host_info = @import("../host.zig");
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;

const BORDER_GAP = gui_mod.BORDER_GAP;
const WIN_MENU_ID = gui_mod.WIN_MENU_ID;
const WIN_VERSION_ID = gui_mod.WIN_VERSION_ID;
const WIN_BACK_ID = gui_mod.WIN_BACK_ID;
const WIN_HELP_ID = gui_mod.WIN_HELP_ID;
const WIN_STATUS_ID = gui_mod.WIN_STATUS_ID;

const ICON_MENU_SOFTWARE_ID = gui_mod.ICON_MENU_SOFTWARE_ID;
const ICON_MENU_HARDWARE_ID = gui_mod.ICON_MENU_HARDWARE_ID;
const ICON_MENU_ABOUT_ID = gui_mod.ICON_MENU_ABOUT_ID;
const ICON_MENU_CONFIG_ID = gui_mod.ICON_MENU_CONFIG_ID;
const ICON_MENU_RESTART_ID = gui_mod.ICON_MENU_RESTART_ID;
const ICON_MENU_SHUTDOWN_ID = gui_mod.ICON_MENU_SHUTDOWN_ID;

const MENU_ITEM_HEIGHT = gui_mod.MENU_ITEM_HEIGHT;
const MENU_PAD_X = gui_mod.MENU_PAD_X;
const MENU_TOP_PAD = gui_mod.MENU_TOP_PAD;
const MENU_FULL_H = gui_mod.MENU_FULL_H;
const MENU_CONTRACTED_H = gui_mod.MENU_CONTRACTED_H;

pub const MenuItemSpec = struct {
    id: u32,
    label: []const u8,
    help: []const u8,
    gap_after: i32,
};

pub const MENU_ITEMS = [_]MenuItemSpec{
    .{
        .id = ICON_MENU_SOFTWARE_ID,
        .label = "Software",
        .help = "Manage VM images, virtual disks, and machine manifests",
        .gap_after = 6,
    },
    .{
        .id = ICON_MENU_HARDWARE_ID,
        .label = "Hardware",
        .help = "Manage peripherals, network bridges, and physical devices",
        .gap_after = 14,
    },
    .{
        .id = ICON_MENU_ABOUT_ID,
        .label = "About",
        .help = "View hypervisor footprint, host telemetry, " ++
            "and build information",
        .gap_after = 6,
    },
    .{
        .id = ICON_MENU_CONFIG_ID,
        .label = "Config",
        .help = "Configure window appearance and desktop background themes",
        .gap_after = 14,
    },
    .{
        .id = ICON_MENU_RESTART_ID,
        .label = "Restart",
        .help = "Restart the physical host computer",
        .gap_after = 6,
    },
    .{
        .id = ICON_MENU_SHUTDOWN_ID,
        .label = "Shutdown",
        .help = "Safely power down and halt the physical host computer",
        .gap_after = 6,
    },
};

fn maxMenuLabelWidth() u32 {
    var max_w: u32 = 0;
    for (MENU_ITEMS) |spec| {
        const w = font.measureStringScaled(spec.label, 6, 5);
        if (w > max_w) max_w = w;
    }
    return max_w;
}

fn onBackButtonClicked(
    gui_ctx: *anyopaque,
    win_ctx: *anyopaque,
    icon: *Icon,
) void {
    _ = win_ctx;
    _ = icon;
    const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    self.navigateBack() catch {};
}

fn onMenuItemActivated(
    gui_ctx: *anyopaque,
    win_ctx: *anyopaque,
    icon: *Icon,
) void {
    _ = win_ctx;
    const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    self.activateMenuItem(icon.id) catch {};
}

pub fn buildMainMenu(self: *DiosixGui) !void {
    const item_w = maxMenuLabelWidth() + 16;
    const menu_w = @as(u32, @intCast(MENU_PAD_X * 2)) + item_w;
    const border_2x = @as(u32, @intCast(BORDER_GAP * 2));
    const max_avail_h =
        if (self.height > border_2x) self.height - border_2x else self.height;
    const win_h = @min(MENU_FULL_H, max_avail_h);

    const win = try self.createWindow(
        WIN_MENU_ID,
        BORDER_GAP,
        BORDER_GAP,
        menu_w,
        win_h,
        null,
    );
    win.setHelpText("Main menu");

    try repopulateMainMenu(self);
}

pub fn repopulateMainMenu(self: *DiosixGui) !void {
    const win = self.getWindow(WIN_MENU_ID) orelse return;
    win.icons.clearRetainingCapacity();
    const border_2x = @as(u32, @intCast(BORDER_GAP * 2));
    const max_avail_h =
        if (self.height > border_2x) self.height - border_2x else self.height;
    win.height = @min(MENU_FULL_H, max_avail_h);
    win.setHelpText("Main menu");

    const pad_2x = @as(u32, @intCast(MENU_PAD_X * 2));
    const item_w = if (win.width > pad_2x)
        win.width - pad_2x
    else
        maxMenuLabelWidth() + 16;

    var cur_y: i32 = MENU_TOP_PAD;
    for (MENU_ITEMS) |spec| {
        var icon = Icon.createMenuItem(
            spec.id,
            MENU_PAD_X,
            cur_y,
            item_w,
            MENU_ITEM_HEIGHT,
            spec.label,
        );
        icon.setHelpText(spec.help);
        icon.callback = onMenuItemActivated;
        _ = try win.addIcon(icon);
        cur_y += @as(i32, @intCast(MENU_ITEM_HEIGHT)) + spec.gap_after;
    }
}

pub fn contractMainMenu(self: *DiosixGui, selected_menu_id: u32) !void {
    const win = self.getWindow(WIN_MENU_ID) orelse return;
    win.icons.clearRetainingCapacity();

    var name: []const u8 = "Menu";
    var help: []const u8 = "Selected menu item";
    for (MENU_ITEMS) |spec| {
        if (spec.id == selected_menu_id) {
            name = spec.label;
            help = spec.help;
            break;
        }
    }

    const pad_2x = @as(u32, @intCast(MENU_PAD_X * 2));
    const item_w = if (win.width > pad_2x) win.width - pad_2x else 80;
    var icon = Icon.createMenuItem(
        selected_menu_id,
        MENU_PAD_X,
        MENU_TOP_PAD,
        item_w,
        MENU_ITEM_HEIGHT,
        name,
    );
    icon.setHelpText(help);
    icon.callback = null;
    icon.setSelected(true);
    _ = try win.addIcon(icon);
    win.setHelpText(help);
}

pub fn buildBackPane(self: *DiosixGui) !void {
    if (self.getWindow(WIN_BACK_ID) != null) return;
    const menu_win = self.getWindow(WIN_MENU_ID);
    const back_w: u32 = if (menu_win) |mw| mw.width else 112;

    const win = try self.createWindow(
        WIN_BACK_ID,
        BORDER_GAP,
        gui_mod.BACK_PANE_Y,
        back_w,
        gui_mod.BACK_PANE_H,
        null,
    );
    win.setHelpText("Return to the main menu");
    win.parent_window_id = WIN_MENU_ID;

    const pad_2x = @as(u32, @intCast(MENU_PAD_X * 2));
    const item_w: u32 = if (back_w > pad_2x) back_w - pad_2x else 80;
    var back_item = Icon.createBackMenuItem(
        gui_mod.ICON_BACK_BTN_ID,
        MENU_PAD_X,
        MENU_TOP_PAD,
        item_w,
        MENU_ITEM_HEIGHT,
        "Back",
    );
    back_item.setHelpText("Return to the main menu");
    back_item.callback = onBackButtonClicked;
    _ = try win.addIcon(back_item);
}

pub fn buildBottomPanes(self: *DiosixGui) !void {
    var ver_buf: [64]u8 = undefined;
    const ver_str = host_info.getVersionString(&ver_buf);
    const ver_text_w = font.measureString(ver_str);

    const ver_h: u32 = 40;
    const ver_pad_h: u32 = 14;
    const ver_w = ver_text_w + ver_pad_h * 2;
    const ver_x =
        @as(i32, @intCast(self.width)) - @as(i32, @intCast(ver_w)) - BORDER_GAP;
    const ver_y = @as(i32, @intCast(self.height)) -
        @as(i32, @intCast(ver_h)) - BORDER_GAP;

    const win_ver = try self.createWindow(
        WIN_VERSION_ID,
        ver_x,
        ver_y,
        ver_w,
        ver_h,
        null,
    );
    win_ver.setHelpText("Hypervisor build and version information");
    var ver_icon = Icon.createReadOnly(
        gui_mod.ICON_VERSION_TEXT_ID,
        @intCast(ver_pad_h),
        8,
        ver_text_w + 4,
        24,
        ver_str,
    );
    ver_icon.setHelpText(
        "Hypervisor name, version number, build branch, and commit hash",
    );
    _ = try win_ver.addIcon(ver_icon);

    const help_x: i32 = BORDER_GAP;
    const available_w = @as(i32, @intCast(ver_x)) - help_x - BORDER_GAP;
    const help_w: u32 = if (available_w > 0) @intCast(available_w) else 0;

    const win_help = try self.createWindow(
        WIN_HELP_ID,
        help_x,
        ver_y,
        help_w,
        ver_h,
        null,
    );
    const help_pad_h: u32 = 14;
    const help_text_w: u32 =
        if (help_w > help_pad_h * 2) help_w - help_pad_h * 2 else 0;
    var help_icon = Icon.createReadOnly(
        gui_mod.ICON_HELP_TEXT_ID,
        @intCast(help_pad_h),
        8,
        help_text_w,
        24,
        DiosixGui.FALLBACK_HELP_TEXT,
    );
    help_icon.setCustomColor(fb.Color.WHITE);
    _ = try win_help.addIcon(help_icon);
}

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

    if (self.active_menu_id == menu_item_id) return;

    self.teardownVmFleetOverview();

    if (self.active_menu_id != null) {
        teardownChildPanes(self);
    }

    switch (menu_item_id) {
        ICON_MENU_SOFTWARE_ID => try self.buildSoftwarePane(),
        ICON_MENU_HARDWARE_ID => try self.buildHardwarePane(),
        ICON_MENU_ABOUT_ID => try self.buildStatusPane(),
        ICON_MENU_CONFIG_ID => try self.buildConfigPane(),
        else => {},
    }

    try buildBackPane(self);
    try contractMainMenu(self, menu_item_id);
    self.active_menu_id = menu_item_id;

    self.nav_anim_state = .opening;
    self.nav_anim_progress = 0.0;
    applyNavAnimation(self);
    self.updateActiveHelp();
}

pub fn navigateBack(self: *DiosixGui) !void {
    if (self.nav_anim_state == .closing) return;
    if (self.active_menu_id == null and self.nav_anim_state == .idle) return;

    try repopulateMainMenu(self);

    self.nav_anim_state = .closing;
    self.nav_anim_progress = 1.0;
    applyNavAnimation(self);
    self.updateActiveHelp();
}

pub fn finishClosing(self: *DiosixGui) void {
    teardownChildPanes(self);
}

pub fn completeNavAnimation(self: *DiosixGui) void {
    if (self.nav_anim_state == .idle) return;
    if (self.nav_anim_state == .opening) {
        self.nav_anim_progress = 1.0;
        applyNavAnimation(self);
        self.nav_anim_state = .idle;
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
        const span = @as(f32, @floatFromInt(MENU_FULL_H - MENU_CONTRACTED_H));
        const full_f = @as(f32, @floatFromInt(MENU_FULL_H));
        win_menu.height = @intFromFloat(full_f - span * factor);
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
}

pub fn teardownChildPanes(self: *DiosixGui) void {
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

    if (self.getWindow(WIN_BACK_ID)) |wb| {
        self.markDirty(wb.getBox());
        _ = self.destroyWindow(WIN_BACK_ID);
    }

    if (self.getWindow(WIN_MENU_ID)) |head| {
        head.child_window_id = null;
        head.height = MENU_FULL_H;
    }

    repopulateMainMenu(self) catch {};
    self.active_menu_id = null;
    self.nav_anim_state = .idle;
    self.nav_anim_progress = 0.0;
    self.buildVmFleetOverview() catch {};
    self.updateActiveHelp();
    self.markFullDirty();
}

pub fn tick(self: *DiosixGui, dt_ms: u32) void {
    if (self.nav_anim_state != .idle) {
        const step =
            @as(f32, @floatFromInt(dt_ms)) / self.nav_anim_duration_ms;
        if (self.nav_anim_state == .opening) {
            self.nav_anim_progress += step;
            if (self.nav_anim_progress >= 1.0) {
                self.nav_anim_progress = 1.0;
                applyNavAnimation(self);
                self.nav_anim_state = .idle;
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
