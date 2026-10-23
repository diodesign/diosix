// Pane, Drawer & Modal Layout Builders for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("framebuffer.zig");
const font = @import("font.zig");
const icon_mod = @import("icon.zig");
const Icon = icon_mod.Icon;
const window_mod = @import("window.zig");
const Window = window_mod.Window;
const host_info = @import("host.zig");
const text_label = @import("label.zig");
const gui_mod = @import("gui.zig");
const DiosixGui = gui_mod.DiosixGui;
pub const panes_modal = @import("panes/modal.zig");
pub const panes_config = @import("panes/config.zig");

pub const showPowerModal = panes_modal.showPowerModal;
pub const buildOskWindow = panes_modal.buildOskWindow;
pub const handleOskAction = panes_modal.handleOskAction;
pub const showWelcomeModal = panes_modal.showWelcomeModal;
pub const showTourModal = panes_modal.showTourModal;

pub const buildConfigPane = panes_config.buildConfigPane;
pub const toggleSchemeDropdown = panes_config.toggleSchemeDropdown;
pub const toggleResolutionDropdown = panes_config.toggleResolutionDropdown;
pub const toggleDepthDropdown = panes_config.toggleDepthDropdown;
pub const toggleScaleDropdown = panes_config.toggleScaleDropdown;
pub const closeSchemeDropdown = panes_config.closeSchemeDropdown;

const BORDER_GAP = gui_mod.BORDER_GAP;
const WIN_MENU_ID = gui_mod.WIN_MENU_ID;
const WIN_STATUS_ID = gui_mod.WIN_STATUS_ID;
const LABEL_COLOR: u32 = fb.Color.INK_SECONDARY;

fn addRightAlignedLabel(
    win: *Window,
    id: u32,
    col1_right: i32,
    y: i32,
    row_h: u32,
    label_str: []const u8,
) !void {
    const w = font.measureString(label_str);
    const lx = @max(8, col1_right - @as(i32, @intCast(w)));
    var lbl = Icon.createReadOnly(id, lx, y, w + 2, row_h, label_str);
    lbl.setCustomColor(LABEL_COLOR);
    _ = try win.addIcon(lbl);
}

fn addStatusRow(
    self: *const DiosixGui,
    win: *Window,
    lbl_id: u32,
    val_id: u32,
    col2_w: u32,
    y_base: u32,
    lbl_str: []const u8,
    val_str: []const u8,
) !void {
    const y: i32 = @intCast(self.scalePx(y_base));
    const col1_right: i32 = @intCast(self.scalePx(140));
    const col2_x: i32 = @intCast(self.scalePx(160));
    const row_h = self.scalePx(20);
    try addRightAlignedLabel(win, lbl_id, col1_right, y, row_h, lbl_str);
    var val = Icon.createReadOnly(val_id, col2_x, y, col2_w, row_h, val_str);
    val.wrap_text = true;
    _ = try win.addIcon(val);
}

fn measureRowValueHeight(row_h: u32, text: []const u8, width: u32) u32 {
    const line_h = font.getActiveLineHeight();
    const row_pad = row_h -| line_h;
    const wm = font.measureWrappedText(text, width);
    return @max(row_h, wm.height + row_pad);
}

fn placeStatusPair(
    self: *DiosixGui,
    row_h: u32,
    lbl_id: u32,
    val_id: u32,
    cur_y: *i32,
) void {
    if (self.findIcon(WIN_STATUS_ID, lbl_id)) |lbl| {
        lbl.rel_y = cur_y.*;
        lbl.height = row_h;
    }
    if (self.findIcon(WIN_STATUS_ID, val_id)) |val| {
        val.rel_y = cur_y.*;
        val.wrap_text = true;
        val.height = measureRowValueHeight(row_h, val.getText(), val.width);
        cur_y.* += @intCast(val.height);
    } else {
        cur_y.* += @intCast(row_h);
    }
}

pub fn layoutStatusPane(self: *DiosixGui) void {
    const win = self.getWindow(WIN_STATUS_ID) orelse return;
    const row_h = self.scalePx(20);
    var cur_y: i32 = @intCast(self.scalePx(34));

    placeStatusPair(
        self,
        row_h,
        gui_mod.ICON_STATUS_HOST_UPTIME_LABEL_ID,
        gui_mod.ICON_STATUS_HOST_UPTIME_ID,
        &cur_y,
    );
    placeStatusPair(
        self,
        row_h,
        gui_mod.ICON_STATUS_HOST_CPU_LABEL_ID,
        gui_mod.ICON_STATUS_HOST_CPU_ID,
        &cur_y,
    );
    placeStatusPair(
        self,
        row_h,
        gui_mod.ICON_STATUS_HOST_RAM_LABEL_ID,
        gui_mod.ICON_STATUS_HOST_RAM_ID,
        &cur_y,
    );
    placeStatusPair(
        self,
        row_h,
        gui_mod.ICON_STATUS_HOST_TIME_LABEL_ID,
        gui_mod.ICON_STATUS_HOST_TIME_ID,
        &cur_y,
    );

    cur_y += @intCast(self.scalePx(6));
    if (self.findIcon(WIN_STATUS_ID, gui_mod.ICON_STATUS_HV_HDR_ID)) |hdr| {
        hdr.rel_y = cur_y;
        hdr.height = row_h;
    }
    cur_y += @intCast(row_h);

    placeStatusPair(
        self,
        row_h,
        gui_mod.ICON_STATUS_HV_BUILD_LABEL_ID,
        gui_mod.ICON_STATUS_HV_BUILD1_ID,
        &cur_y,
    );

    if (self.findIcon(WIN_STATUS_ID, gui_mod.ICON_STATUS_HV_BUILD2_ID)) |b2| {
        b2.rel_y = cur_y;
        b2.wrap_text = true;
        if (b2.getText().len > 0) {
            b2.height = measureRowValueHeight(row_h, b2.getText(), b2.width);
            cur_y += @intCast(b2.height);
        } else {
            b2.height = 0;
        }
    }

    cur_y += @intCast(self.scalePx(2));
    placeStatusPair(
        self,
        row_h,
        gui_mod.ICON_STATUS_HV_FOOTPRINT_LABEL_ID,
        gui_mod.ICON_STATUS_HV_FOOTPRINT_ID,
        &cur_y,
    );

    const bot_pad = self.scalePx(20);
    win.content_bottom_pad = bot_pad;
    const footer_reserve =
        self.scalePx(40) + @as(u32, @intCast(BORDER_GAP * 3));
    const max_h = if (self.height > footer_reserve)
        self.height - footer_reserve
    else
        self.height;
    const needed_h: u32 = @as(u32, @intCast(@max(0, cur_y))) + bot_pad;
    win.height = @min(@max(self.scalePx(224), needed_h), max_h);
}

pub fn buildStatusPane(self: *DiosixGui) !void {
    const menu_win = self.getWindow(WIN_MENU_ID);
    const status_x: i32 = if (menu_win) |mw|
        mw.x + @as(i32, @intCast(mw.width)) + BORDER_GAP
    else
        172;
    const status_y: i32 = BORDER_GAP;
    const max_w = @as(i32, @intCast(self.width)) - BORDER_GAP - status_x;
    const status_w: u32 = if (max_w > 0) @intCast(max_w) else 780;
    const status_h: u32 = self.scalePx(224);

    const win = try self.createWindow(
        WIN_STATUS_ID,
        status_x,
        status_y,
        status_w,
        status_h,
        null,
    );
    win.setHelpText("Information about this host system and hypervisor");
    win.parent_window_id = WIN_MENU_ID;
    win.linked_menu_item_id = gui_mod.ICON_MENU_STATUS_ID;
    if (self.getWindow(WIN_MENU_ID)) |mw| {
        mw.child_window_id = WIN_STATUS_ID;
    }
    self.setMenuItemSelected(gui_mod.ICON_MENU_STATUS_ID, true);

    const pad_x: i32 = @intCast(self.scalePx(20));
    const col2_x: i32 = @intCast(self.scalePx(160));
    const col2_w: u32 = if (status_w > @as(u32, @intCast(col2_x + 20)))
        status_w - @as(u32, @intCast(col2_x + 20))
    else
        200;
    const row_h = self.scalePx(20);

    var host_hdr = Icon.createReadOnly(
        gui_mod.ICON_STATUS_HOST_HDR_ID,
        pad_x,
        @intCast(self.scalePx(14)),
        self.scalePx(200),
        row_h,
        "Host",
    );
    host_hdr.setCustomColor(fb.Color.INK);
    _ = try win.addIcon(host_hdr);

    var label_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
    try addStatusRow(
        self,
        win,
        gui_mod.ICON_STATUS_HOST_UPTIME_LABEL_ID,
        gui_mod.ICON_STATUS_HOST_UPTIME_ID,
        col2_w,
        34,
        "Uptime",
        host_info.formatUptime(&label_buf),
    );

    try addStatusRow(
        self,
        win,
        gui_mod.ICON_STATUS_HOST_CPU_LABEL_ID,
        gui_mod.ICON_STATUS_HOST_CPU_ID,
        col2_w,
        54,
        "CPU cores",
        host_info.getHostCpuString(&label_buf),
    );

    try addStatusRow(
        self,
        win,
        gui_mod.ICON_STATUS_HOST_RAM_LABEL_ID,
        gui_mod.ICON_STATUS_HOST_RAM_ID,
        col2_w,
        74,
        "RAM",
        host_info.getHostRamString(&label_buf),
    );

    try addStatusRow(
        self,
        win,
        gui_mod.ICON_STATUS_HOST_TIME_LABEL_ID,
        gui_mod.ICON_STATUS_HOST_TIME_ID,
        col2_w,
        94,
        "Time and date",
        host_info.getHostDateTimeString(&label_buf),
    );

    var hv_hdr = Icon.createReadOnly(
        gui_mod.ICON_STATUS_HV_HDR_ID,
        pad_x,
        @intCast(self.scalePx(120)),
        self.scalePx(200),
        row_h,
        "Hypervisor",
    );
    hv_hdr.setCustomColor(fb.Color.INK);
    _ = try win.addIcon(hv_hdr);

    var b1_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
    var b2_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
    const split = host_info.getHvBuildSplit(&b1_buf, &b2_buf);
    try addStatusRow(
        self,
        win,
        gui_mod.ICON_STATUS_HV_BUILD_LABEL_ID,
        gui_mod.ICON_STATUS_HV_BUILD1_ID,
        col2_w,
        140,
        "Build",
        split.line1,
    );

    var icon_b2 = Icon.createReadOnly(
        gui_mod.ICON_STATUS_HV_BUILD2_ID,
        col2_x,
        @intCast(self.scalePx(158)),
        col2_w,
        row_h,
        split.line2,
    );
    icon_b2.wrap_text = true;
    _ = try win.addIcon(icon_b2);

    try addStatusRow(
        self,
        win,
        gui_mod.ICON_STATUS_HV_FOOTPRINT_LABEL_ID,
        gui_mod.ICON_STATUS_HV_FOOTPRINT_ID,
        col2_w,
        180,
        "Footprint",
        host_info.getHvFootprintString(&label_buf),
    );
    layoutStatusPane(self);
}

pub fn updateStatusPaneData(self: *DiosixGui) void {
    const secs = host_info.getHostUptimeSeconds();
    self.last_uptime_sec = secs orelse 0;

    var label_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
    const uptime_str = host_info.formatUptime(&label_buf);
    if (self.findIcon(WIN_STATUS_ID, gui_mod.ICON_STATUS_HOST_UPTIME_ID)) |ic| {
        ic.setText(uptime_str);
    }

    const cpu_str = host_info.getHostCpuString(&label_buf);
    if (self.findIcon(WIN_STATUS_ID, gui_mod.ICON_STATUS_HOST_CPU_ID)) |ic| {
        ic.setText(cpu_str);
    }

    const ram_str = host_info.getHostRamString(&label_buf);
    if (self.findIcon(WIN_STATUS_ID, gui_mod.ICON_STATUS_HOST_RAM_ID)) |ic| {
        ic.setText(ram_str);
    }

    const dt_str = host_info.getHostDateTimeString(&label_buf);
    if (self.findIcon(WIN_STATUS_ID, gui_mod.ICON_STATUS_HOST_TIME_ID)) |ic| {
        ic.setText(dt_str);
    }

    var b1_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
    var b2_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
    const split = host_info.getHvBuildSplit(&b1_buf, &b2_buf);
    if (self.findIcon(WIN_STATUS_ID, gui_mod.ICON_STATUS_HV_BUILD1_ID)) |ic| {
        ic.setText(split.line1);
    }
    if (self.findIcon(WIN_STATUS_ID, gui_mod.ICON_STATUS_HV_BUILD2_ID)) |ic| {
        ic.setText(split.line2);
    }

    const foot_str = host_info.getHvFootprintString(&label_buf);
    const foot_id = gui_mod.ICON_STATUS_HV_FOOTPRINT_ID;
    if (self.findIcon(WIN_STATUS_ID, foot_id)) |ic| {
        ic.setText(foot_str);
    }

    layoutStatusPane(self);
    self.markWindowDirty(WIN_STATUS_ID);
}

test {
    _ = panes_modal;
    _ = panes_config;
    std.testing.refAllDecls(@This());
}
