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
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;

const BORDER_GAP = gui_mod.BORDER_GAP;
const WIN_POWER_MODAL_ID = gui_mod.WIN_POWER_MODAL_ID;

pub fn addModalBtn(
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

pub fn addWrappedLabel(
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

pub fn clampModalWidth(
    self: *const DiosixGui,
    min_w: u32,
    natural_w: u32,
) u32 {
    const border_4x: u32 = @intCast(BORDER_GAP * 4);
    const max_avail =
        if (self.width > border_4x) self.width - border_4x else self.width;
    const desired: u32 = @max(min_w, natural_w);
    return @min(max_avail, desired);
}

pub fn createCenteredModal(
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
    const max_btn_lbl: u32 = @max(
        font.measureString("Cancel"),
        font.measureString(confirm_label),
    );
    const btn_w: u32 = @max(
        self.scalePx(140),
        max_btn_lbl + self.scalePx(36),
    );
    const btn_h: u32 = @max(self.scalePx(32), line_h + self.scalePx(14));

    const max_body_w: u32 = @max(
        font.measureString(t1),
        font.measureString(t2),
    );
    const max_line_w: u32 = @max(font.measureString(title), max_body_w);
    const min_modal_w: u32 = @max(self.scalePx(420), btn_w * 2 + pad_u * 3);
    const modal_w = clampModalWidth(
        self,
        min_modal_w,
        max_line_w + pad_u * 2 + self.scalePx(12),
    );
    const text_w: u32 =
        if (modal_w > pad_u * 2) modal_w - pad_u * 2 else 200;

    const m1 = font.measureWrappedText(t1, text_w);
    const m2 = font.measureWrappedText(t2, text_w);
    const hdr_h: u32 = @max(@as(u32, 36), line_h + 18);
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

pub const panes_welcome = @import("welcome.zig");
pub const showWelcomeModal = panes_welcome.showWelcomeModal;
pub const showTourModal = panes_welcome.showTourModal;

test {
    _ = panes_osk;
    _ = panes_welcome;
    std.testing.refAllDecls(@This());
}
