// Configuration Pane & Dropdown Builders (Color Scheme, Resolution, Color
// Depth, UI Scale) for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("../framebuffer.zig");
const font = @import("../font.zig");
const icon_mod = @import("../icon.zig");
const Icon = icon_mod.Icon;
const window_mod = @import("../window.zig");
const Window = window_mod.Window;
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const scale_mod = @import("../scale.zig");
const dither_mod = @import("../dither.zig");

const BORDER_GAP = gui_mod.BORDER_GAP;
const WIN_MENU_ID = gui_mod.WIN_MENU_ID;
const WIN_CONFIG_ID = gui_mod.WIN_CONFIG_ID;
const WIN_DROPDOWN_ID = gui_mod.WIN_SCHEME_DROPDOWN_ID;
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

fn onTransparencySliderChanged(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    self.setWindowTransparency(@intCast(ic.slider_val));
}

fn onBgSpeedSliderChanged(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    self.setBgAnimationSpeed(@intCast(ic.slider_val));
}

fn onSchemeDropdownClicked(g: *anyopaque, _: *anyopaque, _: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    self.toggleSchemeDropdown() catch {};
}

fn onResDropdownClicked(g: *anyopaque, _: *anyopaque, _: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    toggleResolutionDropdown(self) catch {};
}

fn onDepthDropdownClicked(g: *anyopaque, _: *anyopaque, _: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    toggleDepthDropdown(self) catch {};
}

fn onScaleDropdownClicked(g: *anyopaque, _: *anyopaque, _: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    toggleScaleDropdown(self) catch {};
}

fn onSchemeOptionSelected(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    const tag: u8 = @intCast(ic.user_tag);
    self.setBackdropScheme(@fromBackingInt(tag));
    closeSchemeDropdown(self);
}

fn onResOptionSelected(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    const preset = scale_mod.ResolutionPreset.fromIndex(ic.user_tag);
    closeSchemeDropdown(self);
    self.setResolutionPreset(preset) catch {};
}

fn onDepthOptionSelected(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    const depth = dither_mod.ColorDepth.fromIndex(ic.user_tag);
    closeSchemeDropdown(self);
    self.setColorDepth(depth);
}

fn onScaleOptionSelected(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    const mode = scale_mod.UiScaleMode.fromIndex(ic.user_tag);
    closeSchemeDropdown(self);
    self.setUiScaleMode(mode) catch {};
}

pub fn closeSchemeDropdown(self: *DiosixGui) void {
    const drop_ids = [_]u32{
        gui_mod.ICON_CONFIG_SCHEME_DROPDOWN_ID,
        gui_mod.ICON_CONFIG_RES_DROPDOWN_ID,
        gui_mod.ICON_CONFIG_DEPTH_DROPDOWN_ID,
        gui_mod.ICON_CONFIG_SCALE_DROPDOWN_ID,
    };
    for (drop_ids) |did| {
        if (self.findIcon(WIN_CONFIG_ID, did)) |ic| {
            ic.setSelected(false);
            ic.is_active_press = false;
        }
    }
    _ = self.destroyWindow(WIN_DROPDOWN_ID);
}

fn openDropdownPopupForTrigger(
    self: *DiosixGui,
    trigger_id: u32,
    item_count: usize,
    help_text: []const u8,
) !?*Window {
    if (self.getWindow(WIN_DROPDOWN_ID) != null) {
        const was_sel = if (self.findIcon(WIN_CONFIG_ID, trigger_id)) |ic|
            ic.is_selected
        else
            false;
        closeSchemeDropdown(self);
        if (was_sel) return null;
    }

    const cfg_win = self.getWindow(WIN_CONFIG_ID) orelse return null;
    const trig = cfg_win.getIconById(trigger_id) orelse return null;
    trig.setSelected(true);

    const item_h = self.scalePx(28);
    const min_opt_w = font.measureString("3840x2160 (4K UHD)") +
        self.scalePx(28);
    const popup_w = @max(trig.width, min_opt_w);
    const popup_h: u32 =
        @as(u32, @intCast(item_count)) * item_h + self.scalePx(12);
    const raw_x = cfg_win.x + trig.rel_x;
    const max_x = @as(i32, @intCast(self.width)) -
        @as(i32, @intCast(popup_w)) - BORDER_GAP;
    const popup_x = @max(BORDER_GAP, @min(raw_x, max_x));
    const raw_y = cfg_win.y - cfg_win.scroll_y + trig.rel_y +
        @as(i32, @intCast(trig.height)) + 4;
    const max_y = @as(i32, @intCast(self.height)) -
        @as(i32, @intCast(popup_h)) - BORDER_GAP;
    const popup_y = @max(BORDER_GAP, @min(raw_y, max_y));

    const win = try self.createWindow(
        WIN_DROPDOWN_ID,
        popup_x,
        popup_y,
        popup_w,
        popup_h,
        null,
    );
    win.setHelpText(help_text);
    win.parent_window_id = WIN_CONFIG_ID;
    return win;
}

fn addPopupItem(
    self: *const DiosixGui,
    win: *Window,
    base_id: u32,
    idx: usize,
    tag: usize,
    label: []const u8,
    help: []const u8,
    cb: icon_mod.IconCallback,
) !void {
    const item_h = self.scalePx(28);
    const pad_y: i32 = @intCast(self.scalePx(6));
    var item = Icon.createMenuItem(
        base_id + @as(u32, @intCast(idx)),
        8,
        pad_y + @as(i32, @intCast(idx)) * @as(i32, @intCast(item_h)),
        win.width - 16,
        item_h,
        label,
    );
    item.user_tag = tag;
    item.setHelpText(help);
    item.callback = cb;
    _ = try win.addIcon(item);
}

pub fn toggleSchemeDropdown(self: *DiosixGui) !void {
    const schemes = [_]fb.BackdropScheme{
        .spring, .summer, .autumn, .winter, .rainbow,
    };
    const win = (try openDropdownPopupForTrigger(
        self,
        gui_mod.ICON_CONFIG_SCHEME_DROPDOWN_ID,
        schemes.len,
        "Select a backdrop color scheme",
    )) orelse return;
    for (schemes, 0..) |s, idx| {
        try addPopupItem(
            self,
            win,
            gui_mod.ICON_SCHEME_OPT_BASE_ID,
            idx,
            @backingInt(s),
            s.label(),
            "Select seasonal or rainbow backdrop color scheme",
            onSchemeOptionSelected,
        );
    }
}

pub fn toggleResolutionDropdown(self: *DiosixGui) !void {
    const win = (try openDropdownPopupForTrigger(
        self,
        gui_mod.ICON_CONFIG_RES_DROPDOWN_ID,
        scale_mod.ResolutionPreset.COUNT,
        "Select display screen resolution (800x600 up to 4K 3840x2160)",
    )) orelse return;
    for (0..scale_mod.ResolutionPreset.COUNT) |idx| {
        const preset = scale_mod.ResolutionPreset.fromIndex(idx);
        try addPopupItem(
            self,
            win,
            gui_mod.ICON_RES_OPT_BASE_ID,
            idx,
            idx,
            preset.label(),
            "Switch display resolution and re-layout vector GUI",
            onResOptionSelected,
        );
    }
}

pub fn toggleDepthDropdown(self: *DiosixGui) !void {
    const win = (try openDropdownPopupForTrigger(
        self,
        gui_mod.ICON_CONFIG_DEPTH_DROPDOWN_ID,
        dither_mod.ColorDepth.COUNT,
        "Select framebuffer color depth (8-bit RGB332 to 32-bit TrueColor)",
    )) orelse return;
    for (0..dither_mod.ColorDepth.COUNT) |idx| {
        const depth = dither_mod.ColorDepth.fromIndex(idx);
        try addPopupItem(
            self,
            win,
            gui_mod.ICON_DEPTH_OPT_BASE_ID,
            idx,
            idx,
            depth.label(),
            "Set display color depth and Bayer dithering mode",
            onDepthOptionSelected,
        );
    }
}

pub fn toggleScaleDropdown(self: *DiosixGui) !void {
    const win = (try openDropdownPopupForTrigger(
        self,
        gui_mod.ICON_CONFIG_SCALE_DROPDOWN_ID,
        scale_mod.UiScaleMode.COUNT,
        "Select vector UI scaling factor or Auto EDID physical size detection",
    )) orelse return;
    for (0..scale_mod.UiScaleMode.COUNT) |idx| {
        const mode = scale_mod.UiScaleMode.fromIndex(idx);
        try addPopupItem(
            self,
            win,
            gui_mod.ICON_SCALE_OPT_BASE_ID,
            idx,
            idx,
            mode.label(),
            "Scale vector typography, icons, and window chrome",
            onScaleOptionSelected,
        );
    }
}

pub fn buildConfigPane(self: *DiosixGui) !void {
    const menu_win = self.getWindow(WIN_MENU_ID);
    const config_x: i32 = if (menu_win) |mw|
        mw.x + @as(i32, @intCast(mw.width)) + BORDER_GAP
    else
        172;
    const config_y: i32 = BORDER_GAP;
    const max_w = @as(i32, @intCast(self.width)) - BORDER_GAP - config_x;
    const config_w: u32 = if (max_w > 0) @intCast(max_w) else 600;
    const footer_reserve =
        self.scalePx(40) + @as(u32, @intCast(BORDER_GAP * 3));
    const max_h = if (self.height > footer_reserve)
        self.height - footer_reserve
    else
        self.height;
    const bottom_pad = self.scalePx(32);
    const config_h: u32 = @min(self.scalePx(284) + bottom_pad, max_h);

    const win = try self.createWindow(
        WIN_CONFIG_ID,
        config_x,
        config_y,
        config_w,
        config_h,
        null,
    );
    win.content_bottom_pad = bottom_pad;
    win.setHelpText("System configuration, display resolution, and appearance");
    win.parent_window_id = WIN_MENU_ID;
    win.linked_menu_item_id = gui_mod.ICON_MENU_CONFIG_ID;
    if (self.getWindow(WIN_MENU_ID)) |mw| {
        mw.child_window_id = WIN_CONFIG_ID;
    }
    self.setMenuItemSelected(gui_mod.ICON_MENU_CONFIG_ID, true);

    const pad_x: i32 = @intCast(self.scalePx(20));
    const col1_right: i32 = @intCast(self.scalePx(216));
    const col2_x: i32 = @intCast(self.scalePx(236));
    const min_r: u32 = @intCast(col2_x + 20);
    const avail_w: u32 = if (config_w > min_r) config_w - min_r else 200;
    const ctrl_w: u32 = @min(self.scalePx(260), avail_w);
    const row_h = self.scalePx(22);
    const ctrl_h = self.scalePx(28);

    var app_hdr = Icon.createReadOnly(
        gui_mod.ICON_CONFIG_HDR_ID,
        pad_x,
        @intCast(self.scalePx(14)),
        self.scalePx(200),
        row_h,
        "Appearance",
    );
    app_hdr.setCustomColor(fb.Color.INK);
    _ = try win.addIcon(app_hdr);

    const sliders = [_]struct {
        lbl_id: u32,
        sld_id: u32,
        y_base: u32,
        max: i32,
        val: i32,
        label: []const u8,
        help: []const u8,
        cb: icon_mod.IconCallback,
    }{
        .{
            .lbl_id = gui_mod.ICON_CONFIG_TRANSPARENCY_LBL_ID,
            .sld_id = gui_mod.ICON_CONFIG_TRANSPARENCY_SLIDER_ID,
            .y_base = 42,
            .max = 90,
            .val = @intCast(self.window_transparency),
            .label = "Transparency",
            .help = "Adjust window pane background transparency (0% to 90%)",
            .cb = onTransparencySliderChanged,
        },
        .{
            .lbl_id = gui_mod.ICON_CONFIG_SPEED_LBL_ID,
            .sld_id = gui_mod.ICON_CONFIG_SPEED_SLIDER_ID,
            .y_base = 78,
            .max = 100,
            .val = @intCast(self.bg_animation_speed),
            .label = "Background morph speed",
            .help = "Adjust background color morphing speed (0% to 100%)",
            .cb = onBgSpeedSliderChanged,
        },
    };

    for (sliders) |sl| {
        const y_px: i32 = @intCast(self.scalePx(sl.y_base));
        try addRightAlignedLabel(
            win,
            sl.lbl_id,
            col1_right,
            y_px,
            ctrl_h,
            sl.label,
        );
        var s = Icon.createSlider(
            sl.sld_id,
            col2_x,
            y_px,
            ctrl_w,
            ctrl_h,
            0,
            sl.max,
            sl.val,
            "%",
        );
        s.setHelpText(sl.help);
        s.callback = sl.cb;
        _ = try win.addIcon(s);
    }

    var disp_hdr = Icon.createReadOnly(
        gui_mod.ICON_CONFIG_DISPLAY_HDR_ID,
        pad_x,
        @intCast(self.scalePx(156)),
        self.scalePx(200),
        row_h,
        "Display",
    );
    disp_hdr.setCustomColor(fb.Color.INK);
    _ = try win.addIcon(disp_hdr);

    const dropdowns = [_]struct {
        lbl_id: u32,
        drop_id: u32,
        y_base: u32,
        lbl_str: []const u8,
        val_str: []const u8,
        help: []const u8,
        cb: icon_mod.IconCallback,
    }{
        .{
            .lbl_id = gui_mod.ICON_CONFIG_SCHEME_LBL_ID,
            .drop_id = gui_mod.ICON_CONFIG_SCHEME_DROPDOWN_ID,
            .y_base = 114,
            .lbl_str = "Color scheme",
            .val_str = self.bg_scheme.label(),
            .help = "Select the seasonal or rainbow backdrop color scheme",
            .cb = onSchemeDropdownClicked,
        },
        .{
            .lbl_id = gui_mod.ICON_CONFIG_RES_LBL_ID,
            .drop_id = gui_mod.ICON_CONFIG_RES_DROPDOWN_ID,
            .y_base = 184,
            .lbl_str = "Resolution",
            .val_str = self.resolution_preset.label(),
            .help = "Select screen resolution from 800x600 up to 4K 3840x2160",
            .cb = onResDropdownClicked,
        },
        .{
            .lbl_id = gui_mod.ICON_CONFIG_DEPTH_LBL_ID,
            .drop_id = gui_mod.ICON_CONFIG_DEPTH_DROPDOWN_ID,
            .y_base = 220,
            .lbl_str = "Color depth",
            .val_str = self.color_depth.label(),
            .help = "Select display color depth from 8-bit to 32-bit TrueColor",
            .cb = onDepthDropdownClicked,
        },
        .{
            .lbl_id = gui_mod.ICON_CONFIG_SCALE_LBL_ID,
            .drop_id = gui_mod.ICON_CONFIG_SCALE_DROPDOWN_ID,
            .y_base = 256,
            .lbl_str = "UI scale",
            .val_str = self.ui_scale_mode.label(),
            .help = "Select UI vector scale override or Auto EDID detection",
            .cb = onScaleDropdownClicked,
        },
    };

    for (dropdowns) |d| {
        const dy: i32 = @intCast(self.scalePx(d.y_base));
        try addRightAlignedLabel(
            win,
            d.lbl_id,
            col1_right,
            dy,
            ctrl_h,
            d.lbl_str,
        );
        var dd = Icon.createDropdown(
            d.drop_id,
            col2_x,
            dy,
            ctrl_w,
            ctrl_h,
            d.val_str,
        );
        dd.setHelpText(d.help);
        dd.callback = d.cb;
        _ = try win.addIcon(dd);
    }
}

test {
    std.testing.refAllDecls(@This());
}
