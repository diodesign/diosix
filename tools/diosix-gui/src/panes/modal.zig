// Modal Dialogs and On-Screen Keyboard Window Builders for Diosix GUI.
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
const osk_mod = @import("../osk.zig");
const welcome_mod = @import("../welcome.zig");
const text_label = @import("../label.zig");
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;

const BORDER_GAP = gui_mod.BORDER_GAP;
const WIN_POWER_MODAL_ID = gui_mod.WIN_POWER_MODAL_ID;
const WIN_WELCOME_ID = gui_mod.WIN_WELCOME_ID;
const WIN_TOUR_ID = gui_mod.WIN_TOUR_ID;

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

fn onPowerCancelClicked(g: *anyopaque, _: *anyopaque, _: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    self.closePowerModal();
}

fn onPowerConfirmClicked(g: *anyopaque, _: *anyopaque, _: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    self.confirmPowerModal();
}

fn addWrappedLabel(
    win: *Window,
    id: u32,
    x: i32,
    y: i32,
    w: u32,
    text: []const u8,
    color: u32,
) !u32 {
    const wm = font.measureWrappedText(text, w);
    const h = wm.height + 4;
    var ic = Icon.createReadOnly(id, x, y, w, h, text);
    ic.wrap_text = true;
    ic.setCustomColor(color);
    _ = try win.addIcon(ic);
    return h;
}

fn clampModalWidth(
    self: *const DiosixGui,
    min_w: u32,
    natural_w: u32,
) u32 {
    const border_4x: u32 = @intCast(BORDER_GAP * 4);
    const max_avail =
        if (self.width > border_4x) self.width - border_4x else self.width;
    return @min(max_avail, @max(min_w, natural_w));
}

fn createCenteredModal(
    self: *DiosixGui,
    id: u32,
    modal_w: u32,
    modal_h: u32,
    title: []const u8,
    help: []const u8,
) !*Window {
    const mx: i32 = @divTrunc(
        @as(i32, @intCast(self.width)) - @as(i32, @intCast(modal_w)),
        2,
    );
    const my: i32 = @divTrunc(
        @as(i32, @intCast(self.height)) - @as(i32, @intCast(modal_h)),
        2,
    );
    const win = try self.createWindow(id, mx, my, modal_w, modal_h, title);
    win.setHelpText(help);
    win.is_modal = true;
    return win;
}

pub fn showPowerModal(self: *DiosixGui, action: gui_mod.PowerAction) !void {
    _ = self.destroyWindow(WIN_POWER_MODAL_ID);

    self.power_modal_action = action;
    self.power_action_confirmed = false;

    const title = if (action == .restart)
        "Restart host system"
    else
        "Shut down host system";
    const t1 = if (action == .restart)
        "Are you sure you want to restart the physical host?"
    else
        "Are you sure you want to shut down the physical host?";
    const t2 = "All running guest virtual machines will be cleanly stopped.";
    const confirm_label =
        if (action == .restart) "Restart now" else "Power off";

    const pad_u = self.scalePx(24);
    const pad_x: i32 = @intCast(pad_u);
    const line_h = font.getActiveLineHeight();
    const btn_w: u32 = @max(
        self.scalePx(140),
        @max(font.measureString("Cancel"), font.measureString(confirm_label)) +
            self.scalePx(36),
    );
    const btn_h: u32 = @max(self.scalePx(32), line_h + self.scalePx(14));

    const max_line_w = @max(
        font.measureString(title),
        @max(font.measureString(t1), font.measureString(t2)),
    );
    const modal_w = clampModalWidth(
        self,
        @max(self.scalePx(420), btn_w * 2 + pad_u * 3),
        max_line_w + pad_u * 2 + self.scalePx(12),
    );
    const text_w: u32 =
        if (modal_w > pad_u * 2) modal_w - pad_u * 2 else 200;

    const m1 = font.measureWrappedText(t1, text_w);
    const m2 = font.measureWrappedText(t2, text_w);
    const hdr_h: u32 = @max(36, line_h + 18);
    const y1: i32 = @intCast(hdr_h + self.scalePx(14));
    const y2: i32 = y1 + @as(i32, @intCast(m1.height + 4 + self.scalePx(8)));
    const btn_y: i32 =
        y2 + @as(i32, @intCast(m2.height + 4 + self.scalePx(20)));
    const modal_h: u32 = @as(u32, @intCast(btn_y)) + btn_h + self.scalePx(20);

    const win = try createCenteredModal(
        self,
        WIN_POWER_MODAL_ID,
        modal_w,
        modal_h,
        title,
        "Confirmation dialog for host power management",
    );

    _ = try addWrappedLabel(
        win,
        gui_mod.ICON_POWER_MSG1_ID,
        pad_x,
        y1,
        text_w,
        t1,
        fb.Color.INK,
    );
    _ = try addWrappedLabel(
        win,
        gui_mod.ICON_POWER_MSG2_ID,
        pad_x,
        y2,
        text_w,
        t2,
        fb.Color.INK_SECONDARY,
    );

    var btn_cancel = Icon.createButton(
        gui_mod.ICON_POWER_CANCEL_ID,
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

    const confirm_x =
        @as(i32, @intCast(modal_w)) - @as(i32, @intCast(btn_w)) - pad_x;
    var btn_confirm = Icon.createButton(
        gui_mod.ICON_POWER_CONFIRM_ID,
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
    btn_confirm.setCustomColor(fb.Color.INK);
    btn_confirm.callback = onPowerConfirmClicked;
    _ = try win.addIcon(btn_confirm);

    self.markFullDirty();
}

pub const panes_osk = @import("osk.zig");
pub const handleOskAction = panes_osk.handleOskAction;
pub const onOskKeyClicked = panes_osk.onOskKeyClicked;
pub const buildOskWindow = panes_osk.buildOskWindow;

fn onWelcomeActionClicked(g: *anyopaque, _: *anyopaque, icon: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    switch (icon.id) {
        gui_mod.ICON_WELCOME_TOUR_BTN_ID => {
            _ = self.destroyWindow(WIN_WELCOME_ID);
            self.welcome_state.startTour();
            showTourModal(self) catch {};
        },
        gui_mod.ICON_WELCOME_DISMISS_BTN_ID => {
            self.welcome_state.closeWelcome();
            _ = self.destroyWindow(WIN_WELCOME_ID);
            self.markFullDirty();
        },
        else => {},
    }
}

pub fn showWelcomeModal(self: *DiosixGui) !void {
    _ = self.destroyWindow(WIN_TOUR_ID);
    _ = self.destroyWindow(WIN_WELCOME_ID);
    self.welcome_state.openWelcome();

    const l1_str = "Diosix Type-1 Partitioning Hypervisor & Root VM Supervisor";
    const l2_str =
        "Take the 5-step Guided Tour or continue to the live desktop.";
    const pad_u = self.scalePx(24);
    const pad_x: i32 = @intCast(pad_u);
    const line_h = font.getActiveLineHeight();
    const btn_w = @max(
        self.scalePx(180),
        font.measureString("Start guided tour") + self.scalePx(36),
    );
    const btn_h = @max(self.scalePx(34), line_h + self.scalePx(14));

    const modal_w = clampModalWidth(
        self,
        @max(self.scalePx(540), btn_w * 2 + pad_u * 3),
        @max(font.measureString(l1_str), font.measureString(l2_str)) +
            pad_u * 2 + self.scalePx(12),
    );
    const text_w: u32 =
        if (modal_w > pad_u * 2) modal_w - pad_u * 2 else 200;

    const m1 = font.measureWrappedText(l1_str, text_w);
    const m2 = font.measureWrappedText(l2_str, text_w);
    const hdr_h: u32 = @max(36, line_h + 18);
    const y1: i32 = @intCast(hdr_h + self.scalePx(14));
    const y2: i32 = y1 + @as(i32, @intCast(m1.height + 4 + self.scalePx(8)));
    const btn_y: i32 =
        y2 + @as(i32, @intCast(m2.height + 4 + self.scalePx(22)));
    const modal_h: u32 = @as(u32, @intCast(btn_y)) + btn_h + self.scalePx(20);

    const win = try createCenteredModal(
        self,
        WIN_WELCOME_ID,
        modal_w,
        modal_h,
        "Welcome to Diosix",
        "Choose the 5-step Guided Tour or Live Test-Drive",
    );

    _ = try addWrappedLabel(
        win,
        gui_mod.ICON_WELCOME_SUBTITLE1_ID,
        pad_x,
        y1,
        text_w,
        l1_str,
        fb.Color.INK,
    );
    _ = try addWrappedLabel(
        win,
        gui_mod.ICON_WELCOME_SUBTITLE2_ID,
        pad_x,
        y2,
        text_w,
        l2_str,
        fb.Color.INK_SECONDARY,
    );

    try addModalBtn(
        win,
        gui_mod.ICON_WELCOME_TOUR_BTN_ID,
        pad_x,
        btn_y,
        btn_w,
        btn_h,
        "Start guided tour",
        onWelcomeActionClicked,
    );
    try addModalBtn(
        win,
        gui_mod.ICON_WELCOME_DISMISS_BTN_ID,
        @as(i32, @intCast(modal_w)) - @as(i32, @intCast(btn_w)) - pad_x,
        btn_y,
        btn_w,
        btn_h,
        "Close",
        onWelcomeActionClicked,
    );

    self.markFullDirty();
}

fn onTourActionClicked(g: *anyopaque, _: *anyopaque, icon: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    switch (icon.id) {
        gui_mod.ICON_TOUR_PREV_BTN_ID => {
            self.welcome_state.prevStep();
            showTourModal(self) catch {};
        },
        gui_mod.ICON_TOUR_NEXT_BTN_ID => {
            self.welcome_state.nextStep();
            if (self.welcome_state.tour_visible) {
                showTourModal(self) catch {};
            } else {
                _ = self.destroyWindow(WIN_TOUR_ID);
                self.markFullDirty();
            }
        },
        gui_mod.ICON_TOUR_CLOSE_BTN_ID => {
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
    var hint_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
    const hint_str = text_label.fmtLabel(
        &hint_buf,
        "CLI equivalent: {s}",
        .{step.cli_hint},
    );

    const pad_u = self.scalePx(24);
    const pad_x: i32 = @intCast(pad_u);
    const line_h = font.getActiveLineHeight();
    const btn_w = @max(
        self.scalePx(130),
        font.measureString("Close tour") + self.scalePx(32),
    );
    const btn_h = @max(self.scalePx(32), line_h + self.scalePx(14));

    const max_line = @max(
        font.measureString(step.title),
        @max(
            font.measureString(step.summary_line1),
            @max(
                font.measureString(step.summary_line2),
                font.measureString(hint_str),
            ),
        ),
    );
    const modal_w = clampModalWidth(
        self,
        @max(self.scalePx(640), btn_w * 3 + pad_u * 4),
        max_line + pad_u * 2 + self.scalePx(12),
    );
    const tw: u32 = if (modal_w > pad_u * 2) modal_w - pad_u * 2 else 200;

    const m1 = font.measureWrappedText(step.summary_line1, tw);
    const m2 = font.measureWrappedText(step.summary_line2, tw);
    const m3 = font.measureWrappedText(hint_str, tw);
    const hdr_h: u32 = @max(36, line_h + 18);
    const y1: i32 = @intCast(hdr_h + self.scalePx(14));
    const y2: i32 = y1 + @as(i32, @intCast(m1.height + 4 + self.scalePx(6)));
    const y3: i32 = y2 + @as(i32, @intCast(m2.height + 4 + self.scalePx(12)));
    const btn_y: i32 =
        y3 + @as(i32, @intCast(m3.height + 4 + self.scalePx(20)));
    const modal_h: u32 = @as(u32, @intCast(btn_y)) + btn_h + self.scalePx(20);

    const win = try createCenteredModal(
        self,
        WIN_TOUR_ID,
        modal_w,
        modal_h,
        step.title,
        "Interactive 5-step Diosix architectural guided tour",
    );

    _ = try addWrappedLabel(
        win,
        gui_mod.ICON_TOUR_SUMMARY1_ID,
        pad_x,
        y1,
        tw,
        step.summary_line1,
        fb.Color.INK,
    );
    _ = try addWrappedLabel(
        win,
        gui_mod.ICON_TOUR_SUMMARY2_ID,
        pad_x,
        y2,
        tw,
        step.summary_line2,
        fb.Color.INK_SECONDARY,
    );
    _ = try addWrappedLabel(
        win,
        gui_mod.ICON_TOUR_CLI_HINT_ID,
        pad_x,
        y3,
        tw,
        hint_str,
        fb.Color.INK_SECONDARY,
    );

    try addModalBtn(
        win,
        gui_mod.ICON_TOUR_PREV_BTN_ID,
        pad_x,
        btn_y,
        btn_w,
        btn_h,
        "Previous",
        onTourActionClicked,
    );

    const is_last =
        (self.welcome_state.current_step + 1 == welcome_mod.TOUR_STEP_COUNT);
    const next_lbl = if (is_last) "Finish" else "Next";
    try addModalBtn(
        win,
        gui_mod.ICON_TOUR_NEXT_BTN_ID,
        pad_x + @as(i32, @intCast(btn_w + self.scalePx(16))),
        btn_y,
        btn_w,
        btn_h,
        next_lbl,
        onTourActionClicked,
    );

    try addModalBtn(
        win,
        gui_mod.ICON_TOUR_CLOSE_BTN_ID,
        @as(i32, @intCast(modal_w)) - @as(i32, @intCast(btn_w)) - pad_x,
        btn_y,
        btn_w,
        btn_h,
        "Close tour",
        onTourActionClicked,
    );

    self.markFullDirty();
}

test {
    _ = panes_osk;
    std.testing.refAllDecls(@This());
}
