// Diosix GUI Chrome, Main Menu, Header, and Footer Pane Builders.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("../framebuffer.zig");
const font = @import("../font.zig");
const icon_mod = @import("../icon.zig");
const Icon = icon_mod.Icon;
const host_info = @import("../host.zig");
const text_label = @import("../label.zig");
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;

const BORDER_GAP = gui_mod.BORDER_GAP;
const WIN_MENU_ID = gui_mod.WIN_MENU_ID;
const WIN_VERSION_ID = gui_mod.WIN_VERSION_ID;
const WIN_BACK_ID = gui_mod.WIN_BACK_ID;
const WIN_HELP_ID = gui_mod.WIN_HELP_ID;

const ICON_MENU_ABOUT_ID = gui_mod.ICON_MENU_ABOUT_ID;
const ICON_MENU_CONFIG_ID = gui_mod.ICON_MENU_CONFIG_ID;
const ICON_MENU_RESTART_ID = gui_mod.ICON_MENU_RESTART_ID;
const ICON_MENU_SHUTDOWN_ID = gui_mod.ICON_MENU_SHUTDOWN_ID;

const MENU_ITEM_HEIGHT = gui_mod.MENU_ITEM_HEIGHT;
const MENU_PAD_X = gui_mod.MENU_PAD_X;
const MENU_TOP_PAD = gui_mod.MENU_TOP_PAD;
const MENU_FULL_H = gui_mod.MENU_FULL_H;

pub const MenuItemSpec = struct {
    id: u32,
    label: []const u8,
    help: []const u8,
    gap_after: i32,
};

pub const MENU_ITEMS = [_]MenuItemSpec{
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
        .help = "Configure window transparency, glass blur, " ++
            "and background morph",
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

pub fn maxMenuLabelWidth() u32 {
    var max_w: u32 = 0;
    for (MENU_ITEMS) |spec| {
        const w = font.measureStringScaled(spec.label, 6, 5);
        if (w > max_w) max_w = w;
    }
    return max_w;
}

pub fn getContextTitle(selected_menu_id: ?u32) []const u8 {
    const mid = selected_menu_id orelse return "Menu";
    for (MENU_ITEMS) |spec| {
        if (spec.id == mid) return spec.label;
    }
    return "Menu";
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

pub const repopulateTitleBar = contractMainMenu;

pub fn contractMainMenu(self: *DiosixGui, selected_menu_id: u32) !void {
    const win = self.getWindow(WIN_MENU_ID) orelse return;
    win.icons.clearRetainingCapacity();

    const name = getContextTitle(selected_menu_id);
    var help: []const u8 = "Selected menu item";
    for (MENU_ITEMS) |spec| {
        if (spec.id == selected_menu_id) {
            help = spec.help;
            break;
        }
    }

    const pad_2x = @as(u32, @intCast(MENU_PAD_X * 2));
    const item_w = if (win.width > pad_2x) win.width - pad_2x else 80;
    const single_y: i32 = @divTrunc(
        @as(i32, @intCast(gui_mod.MENU_CONTRACTED_H)) -
            @as(i32, @intCast(MENU_ITEM_HEIGHT)),
        2,
    );
    var icon = Icon.createMenuItem(
        selected_menu_id,
        MENU_PAD_X,
        single_y,
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
    const back_item_y: i32 = @divTrunc(
        @as(i32, @intCast(gui_mod.BACK_PANE_H)) -
            @as(i32, @intCast(MENU_ITEM_HEIGHT)),
        2,
    );
    var back_item = Icon.createBackMenuItem(
        gui_mod.ICON_BACK_BTN_ID,
        MENU_PAD_X,
        back_item_y,
        item_w,
        MENU_ITEM_HEIGHT,
        "Back",
    );
    back_item.setHelpText("Return to the main menu");
    back_item.callback = onBackButtonClicked;
    _ = try win.addIcon(back_item);
}

pub fn buildBottomPanes(self: *DiosixGui) !void {
    var ver_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
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
    help_icon.setCustomColor(fb.Color.INK);
    _ = try win_help.addIcon(help_icon);
}

pub const repopulateFooter = buildBottomPanes;

test {
    std.testing.refAllDecls(@This());
}
