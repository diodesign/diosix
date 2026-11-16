// Welcome Onboarding Dialog and 5-Step Guided Tour Modals for Diosix GUI.
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
const welcome_mod = @import("../welcome.zig");
const text_label = @import("../label.zig");
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const modal = @import("modal.zig");

const WIN_WELCOME_ID = gui_mod.WIN_WELCOME_ID;
const WIN_TOUR_ID = gui_mod.WIN_TOUR_ID;

pub const ICON_WELCOME_TRY_DESKTOP_BTN_ID: u32 = 1458;
pub const ICON_WELCOME_TRY_CLI_BTN_ID: u32 = 1459;
pub const ICON_WELCOME_TOUR_BTN_ID: u32 = 1460;
pub const ICON_WELCOME_DISMISS_BTN_ID: u32 = 1462;
pub const ICON_WELCOME_SUBTITLE1_ID: u32 = 1463;
pub const ICON_WELCOME_SUBTITLE2_ID: u32 = 1464;
pub const ICON_TOUR_PREV_BTN_ID: u32 = 1470;
pub const ICON_TOUR_NEXT_BTN_ID: u32 = 1471;
pub const ICON_TOUR_CLOSE_BTN_ID: u32 = 1472;
pub const ICON_TOUR_SUMMARY1_ID: u32 = 1473;
pub const ICON_TOUR_SUMMARY2_ID: u32 = 1474;
pub const ICON_TOUR_CLI_HINT_ID: u32 = 1475;

fn addWelcomeBtn(
    win: *Window,
    id: u32,
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    label: []const u8,
    help: []const u8,
    cb: icon_mod.IconCallback,
) !void {
    var btn = Icon.createButton(id, x, y, w, h, label);
    btn.setHelpText(help);
    btn.callback = cb;
    _ = try win.addIcon(btn);
}

fn onWelcomeActionClicked(g: *anyopaque, _: *anyopaque, icon: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    switch (icon.id) {
        ICON_WELCOME_TRY_DESKTOP_BTN_ID => {
            gui_mod.demo_mod.launchDemoVm(self, .desktop);
        },
        ICON_WELCOME_TRY_CLI_BTN_ID => {
            gui_mod.demo_mod.launchDemoVm(self, .cli);
        },
        ICON_WELCOME_TOUR_BTN_ID => {
            _ = self.destroyWindow(WIN_WELCOME_ID);
            self.welcome_state.startTour();
            showTourModal(self) catch {};
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
    _ = self.destroyWindow(WIN_WELCOME_ID);
    self.welcome_state.openWelcome();

    const l1_str = "Diosix Type-1 Partitioning Hypervisor & Root VM Supervisor";
    const l2_str =
        "Launch an instant RISC-V guest VM, take the 5-step tour, or explore.";
    const pad_u = self.scalePx(24);
    const pad_x: i32 = @intCast(pad_u);
    const line_h = font.getActiveLineHeight();
    const max_btn_lbl: u32 = @max(
        font.measureString("Start guided tour"),
        font.measureString("Try Desktop VM"),
    );
    const btn_w: u32 = @max(
        self.scalePx(190),
        max_btn_lbl + self.scalePx(36),
    );
    const btn_h: u32 = @max(self.scalePx(34), line_h + self.scalePx(14));
    const row_gap: u32 = self.scalePx(12);

    const min_modal_w: u32 = @max(self.scalePx(540), btn_w * 2 + pad_u * 3);
    const max_txt_w: u32 = @max(
        font.measureString(l1_str),
        font.measureString(l2_str),
    );
    const modal_w = modal.clampModalWidth(
        self,
        min_modal_w,
        max_txt_w + pad_u * 2 + self.scalePx(12),
    );
    const text_w: u32 =
        if (modal_w > pad_u * 2) modal_w - pad_u * 2 else 200;

    const m1 = font.measureWrappedText(l1_str, text_w);
    const m2 = font.measureWrappedText(l2_str, text_w);
    const hdr_h: u32 = @max(@as(u32, 36), line_h + 18);
    const y1: i32 = @intCast(hdr_h + self.scalePx(14));
    const y2: i32 = y1 + @as(i32, @intCast(m1.height + 4 + self.scalePx(8)));
    const row1_y: i32 =
        y2 + @as(i32, @intCast(m2.height + 4 + self.scalePx(20)));
    const row2_y: i32 = row1_y + @as(i32, @intCast(btn_h + row_gap));
    const modal_h: u32 = @as(u32, @intCast(row2_y)) + btn_h + self.scalePx(20);
    const right_x: i32 =
        @as(i32, @intCast(modal_w)) - @as(i32, @intCast(btn_w)) - pad_x;

    const win = try modal.createCenteredModal(
        self,
        WIN_WELCOME_ID,
        modal_w,
        modal_h,
        "Welcome to Diosix",
        "Launch an instant Desktop or CLI RISC-V VM, or take the Guided Tour",
    );

    _ = try modal.addWrappedLabel(
        win,
        ICON_WELCOME_SUBTITLE1_ID,
        pad_x,
        y1,
        text_w,
        l1_str,
        fb.Color.INK,
    );
    _ = try modal.addWrappedLabel(
        win,
        ICON_WELCOME_SUBTITLE2_ID,
        pad_x,
        y2,
        text_w,
        l2_str,
        fb.Color.INK_SECONDARY,
    );

    try addWelcomeBtn(
        win,
        ICON_WELCOME_TRY_DESKTOP_BTN_ID,
        pad_x,
        row1_y,
        btn_w,
        btn_h,
        "Try Desktop VM",
        "Launch the Weston Wayland desktop RISC-V VM and open its display",
        onWelcomeActionClicked,
    );
    try addWelcomeBtn(
        win,
        ICON_WELCOME_TRY_CLI_BTN_ID,
        right_x,
        row1_y,
        btn_w,
        btn_h,
        "Try CLI VM",
        "Launch the fast CLI RISC-V VM and attach to its serial console",
        onWelcomeActionClicked,
    );
    try addWelcomeBtn(
        win,
        ICON_WELCOME_TOUR_BTN_ID,
        pad_x,
        row2_y,
        btn_w,
        btn_h,
        "Start guided tour",
        "Walk through the 5-step interactive Diosix architectural tour",
        onWelcomeActionClicked,
    );
    try addWelcomeBtn(
        win,
        ICON_WELCOME_DISMISS_BTN_ID,
        right_x,
        row2_y,
        btn_w,
        btn_h,
        "Close",
        "Dismiss the welcome dialog and explore the Root VM supervisor",
        onWelcomeActionClicked,
    );

    self.markFullDirty();
}

fn onTourActionClicked(g: *anyopaque, _: *anyopaque, icon: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
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
    var hint_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
    const hint_str = text_label.fmtLabel(
        &hint_buf,
        "CLI equivalent: {s}",
        .{step.cli_hint},
    );

    const pad_u = self.scalePx(24);
    const pad_x: i32 = @intCast(pad_u);
    const line_h = font.getActiveLineHeight();
    const btn_w: u32 = @max(
        self.scalePx(130),
        font.measureString("Close tour") + self.scalePx(32),
    );
    const btn_h: u32 = @max(self.scalePx(32), line_h + self.scalePx(14));

    const max_body: u32 = @max(
        font.measureString(step.summary_line2),
        font.measureString(hint_str),
    );
    const max_sub: u32 = @max(font.measureString(step.summary_line1), max_body);
    const max_line: u32 = @max(font.measureString(step.title), max_sub);
    const min_tour_w: u32 = @max(self.scalePx(640), btn_w * 3 + pad_u * 4);
    const modal_w = modal.clampModalWidth(
        self,
        min_tour_w,
        max_line + pad_u * 2 + self.scalePx(12),
    );
    const tw: u32 = if (modal_w > pad_u * 2) modal_w - pad_u * 2 else 200;

    const m1 = font.measureWrappedText(step.summary_line1, tw);
    const m2 = font.measureWrappedText(step.summary_line2, tw);
    const m3 = font.measureWrappedText(hint_str, tw);
    const hdr_h: u32 = @max(@as(u32, 36), line_h + 18);
    const y1: i32 = @intCast(hdr_h + self.scalePx(14));
    const y2: i32 = y1 + @as(i32, @intCast(m1.height + 4 + self.scalePx(6)));
    const y3: i32 = y2 + @as(i32, @intCast(m2.height + 4 + self.scalePx(12)));
    const btn_y: i32 =
        y3 + @as(i32, @intCast(m3.height + 4 + self.scalePx(20)));
    const modal_h: u32 = @as(u32, @intCast(btn_y)) + btn_h + self.scalePx(20);

    const win = try modal.createCenteredModal(
        self,
        WIN_TOUR_ID,
        modal_w,
        modal_h,
        step.title,
        "Interactive 5-step Diosix architectural guided tour",
    );

    _ = try modal.addWrappedLabel(
        win,
        ICON_TOUR_SUMMARY1_ID,
        pad_x,
        y1,
        tw,
        step.summary_line1,
        fb.Color.INK,
    );
    _ = try modal.addWrappedLabel(
        win,
        ICON_TOUR_SUMMARY2_ID,
        pad_x,
        y2,
        tw,
        step.summary_line2,
        fb.Color.INK_SECONDARY,
    );
    _ = try modal.addWrappedLabel(
        win,
        ICON_TOUR_CLI_HINT_ID,
        pad_x,
        y3,
        tw,
        hint_str,
        fb.Color.INK_SECONDARY,
    );

    try modal.addModalBtn(
        win,
        ICON_TOUR_PREV_BTN_ID,
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
    try modal.addModalBtn(
        win,
        ICON_TOUR_NEXT_BTN_ID,
        pad_x + @as(i32, @intCast(btn_w + self.scalePx(16))),
        btn_y,
        btn_w,
        btn_h,
        next_lbl,
        onTourActionClicked,
    );

    try modal.addModalBtn(
        win,
        ICON_TOUR_CLOSE_BTN_ID,
        @as(i32, @intCast(modal_w)) - @as(i32, @intCast(btn_w)) - pad_x,
        btn_y,
        btn_w,
        btn_h,
        "Close tour",
        onTourActionClicked,
    );

    self.markFullDirty();
}

test "welcome modal: renders dual-guest buttons and triggers demo launch" {
    std.testing.refAllDecls(@This());
    var gui = try DiosixGui.init(std.testing.allocator, 1280, 800);
    defer gui.deinit();

    try showWelcomeModal(&gui);
    const win = gui.getWindow(WIN_WELCOME_ID).?;
    const desk_btn = win.getIconById(ICON_WELCOME_TRY_DESKTOP_BTN_ID).?;
    const cli_btn = win.getIconById(ICON_WELCOME_TRY_CLI_BTN_ID).?;
    try std.testing.expectEqualStrings("Try Desktop VM", desk_btn.getText());
    try std.testing.expectEqualStrings("Try CLI VM", cli_btn.getText());

    gui.handleMouseClick(
        win.x + desk_btn.rel_x + 4,
        win.y + desk_btn.rel_y + 4,
    );
    gui.handleMouseRelease();
    try std.testing.expect(gui.getWindow(WIN_WELCOME_ID) == null);
    try std.testing.expectEqual(
        gui_mod.demo_mod.DemoKind.desktop,
        gui.demo_state.pending.?,
    );
}
