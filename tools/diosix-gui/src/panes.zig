// Pane, Drawer & Modal Layout Builders for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const fb = @import("framebuffer.zig");
const font = @import("font.zig");
const icon_mod = @import("icon.zig");
const Icon = icon_mod.Icon;
const window_mod = @import("window.zig");
const Window = window_mod.Window;
const host_info = @import("host.zig");
const gui_mod = @import("gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const panes_catalog = @import("panes/catalog.zig");
const panes_vm = @import("panes/vm.zig");
const panes_modal = @import("panes/modal.zig");

pub const buildSoftwarePane = panes_catalog.buildSoftwarePane;
pub const buildHardwarePane = panes_catalog.buildHardwarePane;
pub const buildVmFleetOverview = panes_vm.buildVmFleetOverview;
pub const buildVmActionDrawer = panes_vm.buildVmActionDrawer;
pub const showPowerModal = panes_modal.showPowerModal;
pub const buildOskWindow = panes_modal.buildOskWindow;
pub const handleOskAction = panes_modal.handleOskAction;
pub const showWelcomeModal = panes_modal.showWelcomeModal;
pub const showTourModal = panes_modal.showTourModal;

const BORDER_GAP = gui_mod.BORDER_GAP;
const WIN_MENU_ID = gui_mod.WIN_MENU_ID;
const WIN_STATUS_ID = gui_mod.WIN_STATUS_ID;
const WIN_CONFIG_ID = gui_mod.WIN_CONFIG_ID;
const LABEL_COLOR: u32 = 0x00a0b4c8;

fn addRightAlignedLabel(
    win: *Window,
    id: u32,
    col1_right: i32,
    y: i32,
    label_str: []const u8,
) !void {
    const w = font.measureString(label_str);
    const lx = col1_right - @as(i32, @intCast(w));
    var lbl = Icon.createReadOnly(id, lx, y, w, 20, label_str);
    lbl.setCustomColor(LABEL_COLOR);
    _ = try win.addIcon(lbl);
}

fn addStatusRow(
    win: *Window,
    lbl_id: u32,
    val_id: u32,
    col2_w: u32,
    y: i32,
    lbl_str: []const u8,
    val_str: []const u8,
) !void {
    try addRightAlignedLabel(win, lbl_id, 140, y, lbl_str);
    const val = Icon.createReadOnly(val_id, 160, y, col2_w, 20, val_str);
    _ = try win.addIcon(val);
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
    const status_h: u32 = 224;

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

    const pad_x: i32 = 20;
    const col2_x: i32 = 160;
    const col2_w: u32 = status_w - @as(u32, @intCast(col2_x)) - 20;

    const hdr_id = gui_mod.ICON_STATUS_HOST_HDR_ID;
    var host_hdr = Icon.createReadOnly(hdr_id, pad_x, 14, 200, 20, "Host");
    host_hdr.setCustomColor(fb.Color.ACCENT_CYAN);
    _ = try win.addIcon(host_hdr);

    var uptime_buf: [64]u8 = undefined;
    try addStatusRow(
        win,
        gui_mod.ICON_STATUS_HOST_UPTIME_LABEL_ID,
        gui_mod.ICON_STATUS_HOST_UPTIME_ID,
        col2_w,
        34,
        "Uptime",
        host_info.formatUptime(&uptime_buf),
    );

    var cpu_buf: [64]u8 = undefined;
    try addStatusRow(
        win,
        gui_mod.ICON_STATUS_HOST_CPU_LABEL_ID,
        gui_mod.ICON_STATUS_HOST_CPU_ID,
        col2_w,
        54,
        "CPU cores",
        host_info.getHostCpuString(&cpu_buf),
    );

    var ram_buf: [80]u8 = undefined;
    try addStatusRow(
        win,
        gui_mod.ICON_STATUS_HOST_RAM_LABEL_ID,
        gui_mod.ICON_STATUS_HOST_RAM_ID,
        col2_w,
        74,
        "RAM",
        host_info.getHostRamString(&ram_buf),
    );

    var dt_buf: [80]u8 = undefined;
    try addStatusRow(
        win,
        gui_mod.ICON_STATUS_HOST_TIME_LABEL_ID,
        gui_mod.ICON_STATUS_HOST_TIME_ID,
        col2_w,
        94,
        "Time and date",
        host_info.getHostDateTimeString(&dt_buf),
    );

    const hv_id = gui_mod.ICON_STATUS_HV_HDR_ID;
    var hv_hdr = Icon.createReadOnly(hv_id, pad_x, 120, 200, 20, "Hypervisor");
    hv_hdr.setCustomColor(fb.Color.ACCENT_CYAN);
    _ = try win.addIcon(hv_hdr);

    var b1_buf: [160]u8 = undefined;
    var b2_buf: [160]u8 = undefined;
    const split = host_info.getHvBuildSplit(&b1_buf, &b2_buf);
    try addStatusRow(
        win,
        gui_mod.ICON_STATUS_HV_BUILD_LABEL_ID,
        gui_mod.ICON_STATUS_HV_BUILD1_ID,
        col2_w,
        140,
        "Build",
        split.line1,
    );

    const b2_id = gui_mod.ICON_STATUS_HV_BUILD2_ID;
    const icon_b2 = Icon.createReadOnly(
        b2_id,
        col2_x,
        158,
        col2_w,
        20,
        split.line2,
    );
    _ = try win.addIcon(icon_b2);

    var foot_buf: [80]u8 = undefined;
    try addStatusRow(
        win,
        gui_mod.ICON_STATUS_HV_FOOTPRINT_LABEL_ID,
        gui_mod.ICON_STATUS_HV_FOOTPRINT_ID,
        col2_w,
        180,
        "Footprint",
        host_info.getHvFootprintString(&foot_buf),
    );
}

pub fn updateStatusPaneData(self: *DiosixGui) void {
    const secs = host_info.getHostUptimeSeconds();
    self.last_uptime_sec = secs orelse 0;

    var uptime_buf: [64]u8 = undefined;
    const uptime_str = host_info.formatUptime(&uptime_buf);
    if (self.findIcon(WIN_STATUS_ID, gui_mod.ICON_STATUS_HOST_UPTIME_ID)) |ic| {
        ic.setText(uptime_str);
    }

    var cpu_buf: [64]u8 = undefined;
    const cpu_str = host_info.getHostCpuString(&cpu_buf);
    if (self.findIcon(WIN_STATUS_ID, gui_mod.ICON_STATUS_HOST_CPU_ID)) |ic| {
        ic.setText(cpu_str);
    }

    var ram_buf: [80]u8 = undefined;
    const ram_str = host_info.getHostRamString(&ram_buf);
    if (self.findIcon(WIN_STATUS_ID, gui_mod.ICON_STATUS_HOST_RAM_ID)) |ic| {
        ic.setText(ram_str);
    }

    var dt_buf: [80]u8 = undefined;
    const dt_str = host_info.getHostDateTimeString(&dt_buf);
    if (self.findIcon(WIN_STATUS_ID, gui_mod.ICON_STATUS_HOST_TIME_ID)) |ic| {
        ic.setText(dt_str);
    }

    var b1_buf: [160]u8 = undefined;
    var b2_buf: [160]u8 = undefined;
    const split = host_info.getHvBuildSplit(&b1_buf, &b2_buf);
    if (self.findIcon(WIN_STATUS_ID, gui_mod.ICON_STATUS_HV_BUILD1_ID)) |ic| {
        ic.setText(split.line1);
    }
    if (self.findIcon(WIN_STATUS_ID, gui_mod.ICON_STATUS_HV_BUILD2_ID)) |ic| {
        ic.setText(split.line2);
    }

    var foot_buf: [80]u8 = undefined;
    const foot_str = host_info.getHvFootprintString(&foot_buf);
    const foot_id = gui_mod.ICON_STATUS_HV_FOOTPRINT_ID;
    if (self.findIcon(WIN_STATUS_ID, foot_id)) |ic| {
        ic.setText(foot_str);
    }

    self.markWindowDirty(WIN_STATUS_ID);
}

fn onTransparencySliderChanged(
    gui_ctx: *anyopaque,
    win_ctx: *anyopaque,
    icon: *Icon,
) void {
    _ = win_ctx;
    const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    self.setWindowTransparency(@intCast(icon.slider_val));
}

fn onBlurSliderChanged(
    gui_ctx: *anyopaque,
    win_ctx: *anyopaque,
    icon: *Icon,
) void {
    _ = win_ctx;
    const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    self.setBlurStrength(@intCast(icon.slider_val));
}

fn onBgSpeedSliderChanged(
    gui_ctx: *anyopaque,
    win_ctx: *anyopaque,
    icon: *Icon,
) void {
    _ = win_ctx;
    const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    self.setBgAnimationSpeed(@intCast(icon.slider_val));
}

fn onThemeButtonClicked(
    gui_ctx: *anyopaque,
    win_ctx: *anyopaque,
    icon: *Icon,
) void {
    const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    const win: *Window = @ptrCast(@alignCast(win_ctx));
    if (icon.group_id) |gid| {
        for (win.icons.items) |*other| {
            if (other.group_id == gid and other.group_mode == .exclusive) {
                other.is_ticked = (other.id == icon.id);
            }
        }
    }
    icon.is_ticked = true;
    self.selected_theme_id = icon.id;

    switch (icon.id) {
        gui_mod.ICON_CONFIG_THEME_DAY_ID => {
            self.setBackdropTopColor(fb.Color.SKY_BASE_TOP);
            self.setBackdropBotColor(fb.Color.GRADIENT_BOT_DEFAULT);
        },
        gui_mod.ICON_CONFIG_THEME_MIDNIGHT_ID => {
            self.setBackdropTopColor(fb.Color.rgb(16, 24, 48));
            self.setBackdropBotColor(fb.Color.rgb(4, 6, 16));
        },
        gui_mod.ICON_CONFIG_THEME_SUNSET_ID => {
            self.setBackdropTopColor(fb.Color.rgb(180, 70, 60));
            self.setBackdropBotColor(fb.Color.rgb(40, 20, 50));
        },
        gui_mod.ICON_CONFIG_THEME_EMERALD_ID => {
            self.setBackdropTopColor(fb.Color.rgb(32, 120, 90));
            self.setBackdropBotColor(fb.Color.rgb(10, 36, 30));
        },
        else => {},
    }
    self.markFullDirty();
}

pub fn buildConfigPane(self: *DiosixGui) !void {
    const menu_win = self.getWindow(WIN_MENU_ID);
    const config_x: i32 = if (menu_win) |mw|
        mw.x + @as(i32, @intCast(mw.width)) + BORDER_GAP
    else
        172;
    const config_y: i32 = BORDER_GAP;
    const max_w = @as(i32, @intCast(self.width)) - BORDER_GAP - config_x;
    const config_w: u32 = if (max_w > 0) @intCast(max_w) else 780;
    const config_h: u32 = 216;

    const win = try self.createWindow(
        WIN_CONFIG_ID,
        config_x,
        config_y,
        config_w,
        config_h,
        null,
    );
    win.setHelpText("System configuration and appearance settings");
    win.parent_window_id = WIN_MENU_ID;
    win.linked_menu_item_id = gui_mod.ICON_MENU_CONFIG_ID;
    if (self.getWindow(WIN_MENU_ID)) |mw| {
        mw.child_window_id = WIN_CONFIG_ID;
    }
    self.setMenuItemSelected(gui_mod.ICON_MENU_CONFIG_ID, true);

    const pad_x: i32 = 20;
    const col1_right: i32 = 205;
    const col2_x: i32 = 225;

    const hdr_id = gui_mod.ICON_CONFIG_HDR_ID;
    var app_hdr = Icon.createReadOnly(
        hdr_id,
        pad_x,
        14,
        200,
        20,
        "Appearance",
    );
    app_hdr.setCustomColor(fb.Color.ACCENT_CYAN);
    _ = try win.addIcon(app_hdr);

    const h_trans =
        "Adjust window pane background transparency " ++
        "(0% opaque to 90% transparent)";
    const h_blur =
        "Adjust Gaussian glass blur radius on background " ++
        "under window panes";
    const h_speed =
        "Adjust background drift animation speed " ++
        "(0% static to 100% full speed)";

    const sliders = [_]struct {
        lbl_id: u32,
        sld_id: u32,
        y: i32,
        max: i32,
        val: i32,
        label: []const u8,
        help: []const u8,
        cb: icon_mod.IconCallback,
    }{
        .{
            .lbl_id = gui_mod.ICON_CONFIG_TRANSPARENCY_LBL_ID,
            .sld_id = gui_mod.ICON_CONFIG_TRANSPARENCY_SLIDER_ID,
            .y = 34,
            .max = 90,
            .val = @intCast(self.window_transparency),
            .label = "Transparency",
            .help = h_trans,
            .cb = onTransparencySliderChanged,
        },
        .{
            .lbl_id = gui_mod.ICON_CONFIG_BLUR_LBL_ID,
            .sld_id = gui_mod.ICON_CONFIG_BLUR_SLIDER_ID,
            .y = 78,
            .max = 100,
            .val = @intCast(self.blur_strength),
            .label = "Glass blur",
            .help = h_blur,
            .cb = onBlurSliderChanged,
        },
        .{
            .lbl_id = gui_mod.ICON_CONFIG_SPEED_LBL_ID,
            .sld_id = gui_mod.ICON_CONFIG_SPEED_SLIDER_ID,
            .y = 122,
            .max = 100,
            .val = @intCast(self.bg_animation_speed),
            .label = "Background drift speed",
            .help = h_speed,
            .cb = onBgSpeedSliderChanged,
        },
    };

    for (sliders) |sl| {
        try addRightAlignedLabel(win, sl.lbl_id, col1_right, sl.y, sl.label);
        var s = Icon.createSlider(
            sl.sld_id,
            col2_x,
            sl.y,
            240,
            36,
            0,
            sl.max,
            sl.val,
            "%",
        );
        s.setHelpText(sl.help);
        s.callback = sl.cb;
        _ = try win.addIcon(s);
    }

    try addRightAlignedLabel(
        win,
        gui_mod.ICON_CONFIG_THEME_LBL_ID,
        col1_right,
        168,
        "Color theme",
    );

    const themes = [_]struct {
        id: u32,
        w: u32,
        label: []const u8,
        help: []const u8,
    }{
        .{
            .id = gui_mod.ICON_CONFIG_THEME_DAY_ID,
            .w = 95,
            .label = "Day sky",
            .help = "Classic light blue daytime sky gradient",
        },
        .{
            .id = gui_mod.ICON_CONFIG_THEME_MIDNIGHT_ID,
            .w = 95,
            .label = "Midnight",
            .help = "Deep dark navy night sky gradient",
        },
        .{
            .id = gui_mod.ICON_CONFIG_THEME_SUNSET_ID,
            .w = 90,
            .label = "Sunset",
            .help = "Warm crimson dusk sunset gradient",
        },
        .{
            .id = gui_mod.ICON_CONFIG_THEME_EMERALD_ID,
            .w = 95,
            .label = "Emerald",
            .help = "Forest aurora green gradient",
        },
    };

    var radio_x: i32 = col2_x;
    for (themes) |th| {
        const is_sel = (self.selected_theme_id == th.id);
        var r = Icon.createTickBox(
            th.id,
            radio_x,
            166,
            th.w,
            24,
            th.label,
            is_sel,
            gui_mod.GROUP_CONFIG_THEME,
            .exclusive,
        );
        r.setHelpText(th.help);
        r.callback = onThemeButtonClicked;
        _ = try win.addIcon(r);
        radio_x += @as(i32, @intCast(th.w)) + 14;
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
