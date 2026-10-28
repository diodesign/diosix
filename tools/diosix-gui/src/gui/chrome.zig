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

const ICON_MENU_CREATE_VM_ID = gui_mod.ICON_MENU_CREATE_VM_ID;
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
        .id = ICON_MENU_CREATE_VM_ID,
        .label = "Create VM",
        .help = "Select an available VM image and configure a new guest VM",
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
        .help = "Configure window transparency, color scheme, " ++
            "and display settings",
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
    if (mid == gui_mod.ICON_MENU_TERMINAL_ID) return "Terminal";
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
    const pad_x = self.scalePx(@intCast(MENU_PAD_X));
    const item_w = maxMenuLabelWidth() + self.scalePx(16);
    const menu_w = pad_x * 2 + item_w;
    const border_2x = @as(u32, @intCast(BORDER_GAP * 2));
    const max_avail_h =
        if (self.height > border_2x) self.height - border_2x else self.height;
    const win_h = @min(self.scalePx(MENU_FULL_H), max_avail_h);

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
    win.scroll_y = 0;
    win.scrollbar_alpha = 0;
    win.focused_icon_idx = null;
    win.active_drag_icon_idx = null;

    const pad_x = self.scalePx(@intCast(MENU_PAD_X));
    const item_w_calc = maxMenuLabelWidth() + self.scalePx(16);
    win.width = pad_x * 2 + item_w_calc;

    const border_2x = @as(u32, @intCast(BORDER_GAP * 2));
    const max_avail_h =
        if (self.height > border_2x) self.height - border_2x else self.height;
    win.height = @min(self.scalePx(MENU_FULL_H), max_avail_h);
    win.natural_height = win.height;
    win.setHelpText("Main menu");

    const pad_2x = pad_x * 2;
    const item_w = if (win.width > pad_2x)
        win.width - pad_2x
    else
        item_w_calc;
    const item_h = self.scalePx(MENU_ITEM_HEIGHT);

    var cur_y: i32 = @intCast(self.scalePx(@intCast(MENU_TOP_PAD)));
    for (MENU_ITEMS) |spec| {
        var icon = Icon.createMenuItem(
            spec.id,
            @intCast(pad_x),
            cur_y,
            item_w,
            item_h,
            spec.label,
        );
        icon.setHelpText(spec.help);
        icon.callback = onMenuItemActivated;
        _ = try win.addIcon(icon);
        const gap: i32 = @intCast(self.scalePx(@intCast(spec.gap_after)));
        cur_y += @as(i32, @intCast(item_h)) + gap;
    }
}

pub fn contractMainMenu(self: *DiosixGui, selected_menu_id: u32) !void {
    const win = self.getWindow(WIN_MENU_ID) orelse return;
    win.icons.clearRetainingCapacity();
    win.scroll_y = 0;
    win.scrollbar_alpha = 0;
    win.focused_icon_idx = null;
    win.active_drag_icon_idx = null;

    const name = getContextTitle(selected_menu_id);
    const is_term = (selected_menu_id == gui_mod.ICON_MENU_TERMINAL_ID);
    var help: []const u8 = if (is_term)
        "Interactive guest VM terminal session"
    else
        "Selected menu item";
    for (MENU_ITEMS) |spec| {
        if (spec.id == selected_menu_id) {
            help = spec.help;
            break;
        }
    }

    const pad_x = self.scalePx(@intCast(MENU_PAD_X));
    const pad_2x = pad_x * 2;
    const item_w = if (win.width > pad_2x) win.width - pad_2x else 80;
    const item_h = self.scalePx(MENU_ITEM_HEIGHT);
    const contracted_h = self.scalePx(gui_mod.MENU_CONTRACTED_H);
    win.height = contracted_h;
    win.natural_height = contracted_h;
    const single_y: i32 = @divTrunc(
        @as(i32, @intCast(contracted_h)) - @as(i32, @intCast(item_h)),
        2,
    );
    var icon = Icon.createMenuItem(
        selected_menu_id,
        @intCast(pad_x),
        single_y,
        item_w,
        item_h,
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
    const back_w: u32 = if (menu_win) |mw| mw.width else self.scalePx(112);
    const contracted_h = self.scalePx(gui_mod.MENU_CONTRACTED_H);
    const back_gap: i32 = @intCast(
        self.scalePx(@intCast(gui_mod.BACK_PANE_GAP)),
    );
    const back_y: i32 = BORDER_GAP +
        @as(i32, @intCast(contracted_h)) + back_gap;
    const back_h = self.scalePx(gui_mod.BACK_PANE_H);

    const win = try self.createWindow(
        WIN_BACK_ID,
        BORDER_GAP,
        back_y,
        back_w,
        back_h,
        null,
    );
    win.setHelpText("Return to the main menu");
    win.parent_window_id = WIN_MENU_ID;

    const pad_x = self.scalePx(@intCast(MENU_PAD_X));
    const pad_2x = pad_x * 2;
    const item_w: u32 = if (back_w > pad_2x) back_w - pad_2x else 80;
    const item_h = self.scalePx(MENU_ITEM_HEIGHT);
    const back_item_y: i32 = @divTrunc(
        @as(i32, @intCast(back_h)) - @as(i32, @intCast(item_h)),
        2,
    );
    var back_item = Icon.createBackMenuItem(
        gui_mod.ICON_BACK_BTN_ID,
        @intCast(pad_x),
        back_item_y,
        item_w,
        item_h,
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

    const ver_h: u32 = self.scalePx(40);
    const ver_pad_h: u32 = self.scalePx(14);
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
    const icon_h = self.scalePx(24);
    const icon_y: i32 = @divTrunc(
        @as(i32, @intCast(ver_h)) - @as(i32, @intCast(icon_h)),
        2,
    );
    var ver_icon = Icon.createReadOnly(
        gui_mod.ICON_VERSION_TEXT_ID,
        @intCast(ver_pad_h),
        icon_y,
        ver_text_w + 4,
        icon_h,
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
    const help_pad_h: u32 = self.scalePx(14);
    const help_text_w: u32 =
        if (help_w > help_pad_h * 2) help_w - help_pad_h * 2 else 0;
    var help_icon = Icon.createReadOnly(
        gui_mod.ICON_HELP_TEXT_ID,
        @intCast(help_pad_h),
        icon_y,
        help_text_w,
        icon_h,
        DiosixGui.FALLBACK_HELP_TEXT,
    );
    help_icon.setCustomColor(fb.Color.INK);
    _ = try win_help.addIcon(help_icon);
}

test {
    std.testing.refAllDecls(@This());
}
