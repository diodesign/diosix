// Modal Dialogs and On-Screen Keyboard Window Builders for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("../framebuffer.zig");
const icon_mod = @import("../icon.zig");
const Icon = icon_mod.Icon;
const window_mod = @import("../window.zig");
const Window = window_mod.Window;
const osk_mod = @import("../osk.zig");
const welcome_mod = @import("../welcome.zig");
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;

const BORDER_GAP = gui_mod.BORDER_GAP;
const WIN_POWER_MODAL_ID = gui_mod.WIN_POWER_MODAL_ID;
const WIN_OSK_ID = gui_mod.WIN_OSK_ID;
const WIN_WELCOME_ID = gui_mod.WIN_WELCOME_ID;
const WIN_TOUR_ID = gui_mod.WIN_TOUR_ID;

const ICON_POWER_MSG1_ID = gui_mod.ICON_POWER_MSG1_ID;
const ICON_POWER_MSG2_ID = gui_mod.ICON_POWER_MSG2_ID;
const ICON_POWER_CANCEL_ID = gui_mod.ICON_POWER_CANCEL_ID;
const ICON_POWER_CONFIRM_ID = gui_mod.ICON_POWER_CONFIRM_ID;

const ICON_OSK_KEY_BASE_ID = gui_mod.ICON_OSK_KEY_BASE_ID;
const ICON_OSK_DISPLAY_ID = gui_mod.ICON_OSK_DISPLAY_ID;
const ICON_WELCOME_TOUR_BTN_ID = gui_mod.ICON_WELCOME_TOUR_BTN_ID;
const ICON_WELCOME_INSTALL_BTN_ID = gui_mod.ICON_WELCOME_INSTALL_BTN_ID;
const ICON_WELCOME_DISMISS_BTN_ID = gui_mod.ICON_WELCOME_DISMISS_BTN_ID;
const ICON_TOUR_PREV_BTN_ID = gui_mod.ICON_TOUR_PREV_BTN_ID;
const ICON_TOUR_NEXT_BTN_ID = gui_mod.ICON_TOUR_NEXT_BTN_ID;
const ICON_TOUR_CLOSE_BTN_ID = gui_mod.ICON_TOUR_CLOSE_BTN_ID;

fn addModalBtn(
    win: *Window,
    id: u32,
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    label: []const u8,
    cb: icon_mod.IconCallback,
) !void {
    var btn = Icon.createButton(id, x, y, w, h, label);
    btn.callback = cb;
    _ = try win.addIcon(btn);
}

fn onPowerCancelClicked(
    gui_ctx: *anyopaque,
    win_ctx: *anyopaque,
    icon: *Icon,
) void {
    _ = win_ctx;
    _ = icon;
    const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    self.closePowerModal();
}

fn onPowerConfirmClicked(
    gui_ctx: *anyopaque,
    win_ctx: *anyopaque,
    icon: *Icon,
) void {
    _ = win_ctx;
    _ = icon;
    const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    self.confirmPowerModal();
}

pub fn showPowerModal(self: *DiosixGui, action: gui_mod.PowerAction) !void {
    _ = self.destroyWindow(WIN_POWER_MODAL_ID);

    self.power_modal_action = action;
    self.power_action_confirmed = false;
    const modal_w: u32 = 520;
    const modal_h: u32 = 170;
    const modal_x: i32 = @divTrunc(
        @as(i32, @intCast(self.width)) - @as(i32, @intCast(modal_w)),
        2,
    );
    const modal_y: i32 = @divTrunc(
        @as(i32, @intCast(self.height)) - @as(i32, @intCast(modal_h)),
        2,
    );

    const title = if (action == .restart)
        "Restart host system"
    else
        "Shut down host system";
    const win = try self.createWindow(
        WIN_POWER_MODAL_ID,
        modal_x,
        modal_y,
        modal_w,
        modal_h,
        title,
    );
    win.setHelpText("Confirmation dialog for host power management");
    win.is_modal = true;

    const pad_x: i32 = 24;
    const text_w: u32 = if (modal_w > 48) modal_w - 48 else 200;

    const t1 = if (action == .restart)
        "Are you sure you want to restart the physical host?"
    else
        "Are you sure you want to shut down the physical host?";
    var i_t1 = Icon.createReadOnly(
        ICON_POWER_MSG1_ID,
        pad_x,
        48,
        text_w,
        20,
        t1,
    );
    i_t1.setCustomColor(fb.Color.WHITE);
    _ = try win.addIcon(i_t1);

    const t2 = "All running guest virtual machines will be cleanly stopped.";
    var i_t2 = Icon.createReadOnly(
        ICON_POWER_MSG2_ID,
        pad_x,
        74,
        text_w,
        20,
        t2,
    );
    i_t2.setCustomColor(0x00a0b4c8);
    _ = try win.addIcon(i_t2);

    const btn_w: u32 = 140;
    const btn_h: u32 = 32;
    const btn_y: i32 = 114;

    var btn_cancel = Icon.createButton(
        ICON_POWER_CANCEL_ID,
        pad_x,
        btn_y,
        btn_w,
        btn_h,
        "Cancel",
    );
    btn_cancel.setHelpText(
        "Dismiss power dialog and return to normal operation",
    );
    btn_cancel.callback = onPowerCancelClicked;
    _ = try win.addIcon(btn_cancel);

    const confirm_label =
        if (action == .restart) "Restart now" else "Power off";
    const confirm_x =
        @as(i32, @intCast(modal_w)) - @as(i32, @intCast(btn_w)) - pad_x;
    var btn_confirm = Icon.createButton(
        ICON_POWER_CONFIRM_ID,
        confirm_x,
        btn_y,
        btn_w,
        btn_h,
        confirm_label,
    );
    btn_confirm.setHelpText(
        if (action == .restart)
            "Reboot the physical machine"
        else
            "Halt and power down the physical machine",
    );
    btn_confirm.setCustomColor(
        if (action == .restart) fb.Color.ACCENT_CYAN else fb.Color.ACCENT_RED,
    );
    btn_confirm.callback = onPowerConfirmClicked;
    _ = try win.addIcon(btn_confirm);

    self.markFullDirty();
}

pub fn handleOskAction(self: *DiosixGui, icon_id: u32) void {
    if (icon_id >= ICON_OSK_KEY_BASE_ID) {
        const offset = icon_id - ICON_OSK_KEY_BASE_ID;
        _ = self.osk_state.applyKeyOffset(offset);
        if (!self.osk_state.visible) {
            _ = self.destroyWindow(WIN_OSK_ID);
            self.markFullDirty();
        } else {
            buildOskWindow(self) catch {};
        }
    }
}

fn onOskKeyClicked(
    gui_ctx: *anyopaque,
    win_ctx: *anyopaque,
    icon: *Icon,
) void {
    _ = win_ctx;
    const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    handleOskAction(self, icon.id);
}

pub fn buildOskWindow(self: *DiosixGui) !void {
    if (!self.osk_state.visible) {
        _ = self.destroyWindow(WIN_OSK_ID);
        return;
    }
    const avail_w = self.width -| @as(u32, @intCast(BORDER_GAP * 2));
    const osk_w: u32 = @max(120, @min(avail_w, 760));
    const osk_h: u32 = 216;
    const dx = @as(i32, @intCast(self.width)) - @as(i32, @intCast(osk_w));
    const osk_x: i32 = @max(0, @divTrunc(dx, 2));
    const osk_y: i32 = @max(
        0,
        @as(i32, @intCast(self.height)) - 40 - BORDER_GAP * 2 -
            @as(i32, @intCast(osk_h)),
    );

    const win = try self.createWindow(
        WIN_OSK_ID,
        osk_x,
        osk_y,
        osk_w,
        osk_h,
        "On-screen keyboard",
    );
    win.setHelpText("Touchscreen and pointer virtual keyboard (dockable)");

    var disp_buf: [160]u8 = undefined;
    const disp_str = std.fmt.bufPrint(&disp_buf, "Input [{s}]: {s}_", .{
        self.osk_state.layout.label(),
        self.osk_state.getInputText(),
    }) catch "Input: _";
    var disp_icon = Icon.createReadOnly(
        ICON_OSK_DISPLAY_ID,
        16,
        36,
        osk_w -| 32,
        22,
        disp_str,
    );
    disp_icon.setCustomColor(fb.Color.ACCENT_CYAN);
    _ = try win.addIcon(disp_icon);

    const key_unit_w: u32 = 58;
    const key_h: u32 = 30;
    const gap_x: i32 = 6;
    var row_y: i32 = 64;

    const rows = [_]struct { start_x: i32, keys: []const osk_mod.KeyCap }{
        .{ .start_x = 16, .keys = &osk_mod.ROW1_LOWER },
        .{ .start_x = 34, .keys = &osk_mod.ROW2_LOWER },
        .{ .start_x = 16, .keys = &osk_mod.ROW3_LOWER },
        .{ .start_x = 16, .keys = &osk_mod.ROW4_COMMON },
    };

    for (rows) |row| {
        var rx: i32 = row.start_x;
        for (row.keys) |k| {
            const kw = key_unit_w * k.width_units;
            const lbl = self.osk_state.keyLabel(k);
            const btn_id = ICON_OSK_KEY_BASE_ID + k.id_offset;
            const cb = onOskKeyClicked;
            try addModalBtn(win, btn_id, rx, row_y, kw, key_h, lbl, cb);
            rx += @as(i32, @intCast(kw)) + gap_x;
        }
        row_y += @as(i32, @intCast(key_h)) + 6;
    }

    self.markFullDirty();
}

fn onWelcomeActionClicked(
    gui_ctx: *anyopaque,
    win_ctx: *anyopaque,
    icon: *Icon,
) void {
    _ = win_ctx;
    const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    switch (icon.id) {
        ICON_WELCOME_TOUR_BTN_ID => {
            _ = self.destroyWindow(WIN_WELCOME_ID);
            self.welcome_state.startTour();
            showTourModal(self) catch {};
        },
        ICON_WELCOME_INSTALL_BTN_ID => {
            self.welcome_state.install_requested = true;
            self.welcome_state.closeWelcome();
            _ = self.destroyWindow(WIN_WELCOME_ID);
            self.markFullDirty();
        },
        ICON_WELCOME_DISMISS_BTN_ID => {
            self.welcome_state.closeWelcome();
            _ = self.destroyWindow(WIN_WELCOME_ID);
            self.markFullDirty();
        },
        else => {},
    }
}

pub fn showWelcomeModal(self: *DiosixGui) !void {
    _ = self.destroyWindow(WIN_TOUR_ID);
    self.welcome_state.openWelcome();

    const modal_w: u32 = 580;
    const modal_h: u32 = 210;
    const modal_x: i32 = @divTrunc(
        @as(i32, @intCast(self.width)) - @as(i32, @intCast(modal_w)),
        2,
    );
    const modal_y: i32 = @divTrunc(
        @as(i32, @intCast(self.height)) - @as(i32, @intCast(modal_h)),
        2,
    );

    const win = try self.createWindow(
        WIN_WELCOME_ID,
        modal_x,
        modal_y,
        modal_w,
        modal_h,
        "Welcome to Diosix",
    );
    win.setHelpText(
        "Choose Live Test-Drive, Guided Tour, or Persistent Host Installation",
    );
    win.is_modal = true;

    const l1_str = "Diosix Type-1 Partitioning Hypervisor & Root VM Supervisor";
    var l1 = Icon.createReadOnly(1463, 24, 48, modal_w - 48, 20, l1_str);
    l1.setCustomColor(fb.Color.ACCENT_CYAN);
    _ = try win.addIcon(l1);

    const l2_str = "Explore in Live RAM mode, take the 5-step Guided Tour, " ++
        "or install to disk.";
    var l2 = Icon.createReadOnly(1464, 24, 76, modal_w - 48, 20, l2_str);
    l2.setCustomColor(fb.Color.WHITE);
    _ = try win.addIcon(l2);

    try addModalBtn(
        win,
        ICON_WELCOME_TOUR_BTN_ID,
        24,
        146,
        165,
        34,
        "Start guided tour",
        onWelcomeActionClicked,
    );
    try addModalBtn(
        win,
        ICON_WELCOME_INSTALL_BTN_ID,
        205,
        146,
        170,
        34,
        "Install to host disk",
        onWelcomeActionClicked,
    );
    try addModalBtn(
        win,
        ICON_WELCOME_DISMISS_BTN_ID,
        390,
        146,
        165,
        34,
        "Live test-drive",
        onWelcomeActionClicked,
    );

    self.markFullDirty();
}

fn onTourActionClicked(
    gui_ctx: *anyopaque,
    win_ctx: *anyopaque,
    icon: *Icon,
) void {
    _ = win_ctx;
    const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    switch (icon.id) {
        ICON_TOUR_PREV_BTN_ID => {
            self.welcome_state.prevStep();
            showTourModal(self) catch {};
        },
        ICON_TOUR_NEXT_BTN_ID => {
            self.welcome_state.nextStep();
            if (self.welcome_state.tour_visible) {
                showTourModal(self) catch {};
            } else {
                _ = self.destroyWindow(WIN_TOUR_ID);
                self.markFullDirty();
            }
        },
        ICON_TOUR_CLOSE_BTN_ID => {
            self.welcome_state.closeTour();
            _ = self.destroyWindow(WIN_TOUR_ID);
            self.markFullDirty();
        },
        else => {},
    }
}

pub fn showTourModal(self: *DiosixGui) !void {
    _ = self.destroyWindow(WIN_WELCOME_ID);
    _ = self.destroyWindow(WIN_TOUR_ID);
    self.welcome_state.tour_visible = true;

    const step = self.welcome_state.activeTourStep();
    const modal_w: u32 = 640;
    const modal_h: u32 = 220;
    const modal_x: i32 = @divTrunc(
        @as(i32, @intCast(self.width)) - @as(i32, @intCast(modal_w)),
        2,
    );
    const modal_y: i32 = @divTrunc(
        @as(i32, @intCast(self.height)) - @as(i32, @intCast(modal_h)),
        2,
    );

    const win = try self.createWindow(
        WIN_TOUR_ID,
        modal_x,
        modal_y,
        modal_w,
        modal_h,
        step.title,
    );
    win.setHelpText("Interactive 5-step Diosix architectural guided tour");
    win.is_modal = true;

    const tw = modal_w - 48;
    var s1 = Icon.createReadOnly(1473, 24, 50, tw, 20, step.summary_line1);
    s1.setCustomColor(fb.Color.WHITE);
    _ = try win.addIcon(s1);

    var s2 = Icon.createReadOnly(1474, 24, 74, tw, 20, step.summary_line2);
    s2.setCustomColor(0x00a0b4c8);
    _ = try win.addIcon(s2);

    var hint_buf: [128]u8 = undefined;
    const hint_str = std.fmt.bufPrint(
        &hint_buf,
        "CLI equivalent: {s}",
        .{step.cli_hint},
    ) catch step.cli_hint;
    var s3 = Icon.createReadOnly(1475, 24, 108, tw, 20, hint_str);
    s3.setCustomColor(fb.Color.ACCENT_GOLD);
    _ = try win.addIcon(s3);

    try addModalBtn(
        win,
        ICON_TOUR_PREV_BTN_ID,
        24,
        160,
        130,
        32,
        "Previous",
        onTourActionClicked,
    );

    const is_last =
        (self.welcome_state.current_step + 1 == welcome_mod.TOUR_STEP_COUNT);
    const next_lbl = if (is_last) "Finish" else "Next";
    try addModalBtn(
        win,
        ICON_TOUR_NEXT_BTN_ID,
        170,
        160,
        130,
        32,
        next_lbl,
        onTourActionClicked,
    );

    try addModalBtn(
        win,
        ICON_TOUR_CLOSE_BTN_ID,
        @as(i32, @intCast(modal_w)) - 154,
        160,
        130,
        32,
        "Close tour",
        onTourActionClicked,
    );

    self.markFullDirty();
}
