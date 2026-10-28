// Interactive Guest SSH & Serial Console Terminal Pane for Diosix GUI.
//
// Implements per-VM SSH and serial console sessions with a full-width slide
// transition, fixed-width DM Mono rendering, color inversion, and persistent
// background SSH/local terminal state across Back navigation.
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
const host_info = @import("../host.zig");
const text_label = @import("../label.zig");
const terminal_mod = @import("../terminal.zig");
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const state_mod = @import("terminal_state.zig");

pub const WIN_TERMINAL_ID = state_mod.WIN_TERMINAL_ID;
pub const ICON_GUEST_SSH_ID: u32 = 1248;
pub const ICON_GUEST_CONSOLE_ID: u32 = 1249;
pub const ICON_TERM_STATUS_ID: u32 = 1500;
pub const ICON_TERM_MODE_BTN_ID: u32 = 1501;
pub const ICON_TERM_OSK_BTN_ID: u32 = 1502;
pub const ICON_TERM_CLEAR_BTN_ID: u32 = 1503;
pub const ICON_TERM_INVERT_BTN_ID: u32 = 1504;

pub const hasLiveSshSession = state_mod.hasLiveSshSession;
pub const discardGuestSshSession = state_mod.discardGuestSshSession;
pub const onTerminalNavigateBack = state_mod.onTerminalNavigateBack;
pub const pollTerminal = state_mod.pollTerminal;
pub const isTerminalWindowOpen = state_mod.isTerminalWindowOpen;

const BORDER_GAP = gui_mod.BORDER_GAP;

fn onOpenSshClicked(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    self.openGuestTerminal(@intCast(ic.user_tag), .ssh) catch {};
}

fn onOpenConsoleClicked(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    self.openGuestTerminal(@intCast(ic.user_tag), .console) catch {};
}

fn onSwitchModeClicked(g: *anyopaque, _: *anyopaque, _: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    if (!self.terminal.active) return;
    const next_mode: terminal_mod.TerminalMode =
        if (self.terminal.mode == .ssh) .console else .ssh;
    self.openGuestTerminal(self.terminal.target_cid, next_mode) catch {};
}

fn onToggleOskClicked(g: *anyopaque, _: *anyopaque, _: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    self.osk_state.toggle();
    buildTerminalWindow(self) catch {};
    self.buildOskWindow() catch {};
}

fn onClearTerminalClicked(g: *anyopaque, _: *anyopaque, _: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    self.terminal.clearScreen();
    self.markWindowDirty(WIN_TERMINAL_ID);
}

fn onInvertTerminalClicked(g: *anyopaque, _: *anyopaque, _: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    self.terminal.inverted = !self.terminal.inverted;
    self.markWindowDirty(WIN_TERMINAL_ID);
}

pub fn addGuestDetailTerminalButtons(
    self: *DiosixGui,
    win: *Window,
    guest: *const host_info.RunningGuest,
    item_x: i32,
    menu_w: u32,
    item_h: u32,
    cur_y: *i32,
) !void {
    const has_live = hasLiveSshSession(self, guest.cid);
    const ssh_label = if (guest.is_root)
        (if (has_live) "Reopen local terminal" else "Open new local terminal")
    else
        (if (has_live) "Reopen SSH terminal" else "Open new SSH terminal");

    var ssh_item = Icon.createMenuItem(
        ICON_GUEST_SSH_ID,
        item_x,
        cur_y.*,
        menu_w,
        item_h,
        ssh_label,
    );
    ssh_item.user_tag = @intCast(guest.cid);
    ssh_item.setHelpText(
        "Open or reopen this VM's interactive shell terminal session",
    );
    ssh_item.callback = onOpenSshClicked;
    _ = try win.addIcon(ssh_item);
    cur_y.* += @intCast(item_h + self.scalePx(4));

    if (!guest.is_root) {
        var con_item = Icon.createMenuItem(
            ICON_GUEST_CONSOLE_ID,
            item_x,
            cur_y.*,
            menu_w,
            item_h,
            "Open serial console",
        );
        con_item.user_tag = @intCast(guest.cid);
        con_item.setHelpText(
            "View guest boot logs and interact with the hvc0 serial console",
        );
        con_item.callback = onOpenConsoleClicked;
        _ = try win.addIcon(con_item);
        cur_y.* += @intCast(item_h + self.scalePx(4));
    }
}

pub fn openGuestTerminal(
    self: *DiosixGui,
    cid: u64,
    mode: terminal_mod.TerminalMode,
) !void {
    const grid_sz = state_mod.computeViewportGrid(self);
    if (self.terminal.active) {
        if (mode == .ssh and self.terminal.mode == .ssh and
            !self.terminal.exited and self.terminal.target_cid == cid)
        {
            self.terminal.resizeGrid(grid_sz.cols, grid_sz.rows);
        } else {
            onTerminalNavigateBack(self);
        }
    }

    if (!self.terminal.active) {
        if (mode == .ssh and state_mod.restoreBgSshSession(self, cid)) {
            self.terminal.resizeGrid(grid_sz.cols, grid_sz.rows);
        } else {
            if (mode == .ssh) discardGuestSshSession(self, cid);
            var name_buf: [host_info.GUEST_NAME_BYTES]u8 = undefined;
            const guest_name = state_mod.findGuestNameByCid(cid, &name_buf);
            self.terminal.cols = grid_sz.cols;
            self.terminal.rows = grid_sz.rows;
            self.terminal.openSession(cid, guest_name, mode);
        }
    }

    self.selected_guest_cid = cid;
    if (self.active_menu_id != gui_mod.ICON_MENU_TERMINAL_ID) {
        try self.activateMenuItem(gui_mod.ICON_MENU_TERMINAL_ID);
    } else {
        try buildTerminalWindow(self);
    }
    if (self.osk_state.visible) try self.buildOskWindow();
    self.focusWindowById(WIN_TERMINAL_ID);
}

pub fn closeTerminalWindow(self: *DiosixGui) void {
    onTerminalNavigateBack(self);
    if (self.active_menu_id == gui_mod.ICON_MENU_TERMINAL_ID) {
        self.navigateBack() catch {};
    } else {
        _ = self.destroyWindow(WIN_TERMINAL_ID);
        self.markFullDirty();
    }
}

fn measureBtnW(self: *const DiosixGui, base_px: u32, lbl: []const u8) u32 {
    return @max(
        self.scalePx(base_px),
        font.measureString(lbl) + self.scalePx(24),
    );
}

fn addToolbarBtn(
    win: *Window,
    id: u32,
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    lbl: []const u8,
    help: []const u8,
    cb: icon_mod.IconCallback,
) !void {
    var btn = Icon.createButton(id, x, y, w, h, lbl);
    btn.setHelpText(help);
    btn.callback = cb;
    _ = try win.addIcon(btn);
}

pub fn buildTerminalWindow(self: *DiosixGui) !void {
    if (!self.terminal.active) {
        _ = self.destroyWindow(WIN_TERMINAL_ID);
        return;
    }

    const rect = state_mod.computeTermRect(self);
    const grid_sz = state_mod.computeViewportGrid(self);
    self.terminal.resizeGrid(grid_sz.cols, grid_sz.rows);

    const win = try self.createWindow(
        WIN_TERMINAL_ID,
        rect.x,
        BORDER_GAP,
        rect.w,
        rect.h,
        "Guest VM terminal",
    );
    win.natural_height = rect.h;
    win.parent_window_id = gui_mod.WIN_MENU_ID;
    win.linked_menu_item_id = gui_mod.ICON_MENU_TERMINAL_ID;
    if (self.getWindow(gui_mod.WIN_MENU_ID)) |mw| {
        mw.child_window_id = WIN_TERMINAL_ID;
    }
    win.setHelpText(
        "Interactive guest VM terminal (use Back on the left to return)",
    );

    const pad_x: i32 = @intCast(self.scalePx(14));
    const toolbar_y: i32 = @intCast(self.scalePx(40));
    const btn_h: u32 = @max(
        self.scalePx(26),
        font.getActiveLineHeight() + self.scalePx(8),
    );
    const btn_gap: i32 = @intCast(self.scalePx(6));

    const clear_w = measureBtnW(self, 68, "Clear");
    const invert_w = measureBtnW(self, 72, "Invert");
    const osk_w = measureBtnW(self, 92, "Keyboard");

    var right_x: i32 = @as(i32, @intCast(rect.w)) - pad_x -
        @as(i32, @intCast(clear_w));
    try addToolbarBtn(
        win,
        ICON_TERM_CLEAR_BTN_ID,
        right_x,
        toolbar_y,
        clear_w,
        btn_h,
        "Clear",
        "Clear the terminal screen buffer",
        onClearTerminalClicked,
    );

    right_x -= @as(i32, @intCast(invert_w)) + btn_gap;
    try addToolbarBtn(
        win,
        ICON_TERM_INVERT_BTN_ID,
        right_x,
        toolbar_y,
        invert_w,
        btn_h,
        "Invert",
        "Invert terminal colors between black-on-white and white-on-black",
        onInvertTerminalClicked,
    );

    right_x -= @as(i32, @intCast(osk_w)) + btn_gap;
    try addToolbarBtn(
        win,
        ICON_TERM_OSK_BTN_ID,
        right_x,
        toolbar_y,
        osk_w,
        btn_h,
        "Keyboard",
        "Toggle the dockable on-screen keyboard",
        onToggleOskClicked,
    );

    if (self.terminal.target_cid >= 2) {
        const switch_lbl = if (self.terminal.mode == .ssh)
            "Serial console"
        else
            "SSH shell";
        const mode_w = measureBtnW(self, 124, switch_lbl);
        right_x -= @as(i32, @intCast(mode_w)) + btn_gap;
        try addToolbarBtn(
            win,
            ICON_TERM_MODE_BTN_ID,
            right_x,
            toolbar_y,
            mode_w,
            btn_h,
            switch_lbl,
            "Switch between this VM's SSH terminal and hvc0 serial console",
            onSwitchModeClicked,
        );
    }

    var status_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
    const status_str = if (self.terminal.target_cid <= 1)
        text_label.fmtLabel(&status_buf, "Root VM (local shell)", .{})
    else if (self.terminal.mode == .ssh)
        text_label.fmtLabel(
            &status_buf,
            "{s} (root@10.0.3.{d} via SSH)",
            .{ self.terminal.getGuestName(), self.terminal.target_cid },
        )
    else
        text_label.fmtLabel(
            &status_buf,
            "{s} (CID {d} hvc0 serial console)",
            .{ self.terminal.getGuestName(), self.terminal.target_cid },
        );

    const status_w: u32 = if (right_x > pad_x + 24)
        @intCast(right_x - pad_x - btn_gap)
    else
        self.scalePx(160);
    var status_ic = Icon.createReadOnly(
        ICON_TERM_STATUS_ID,
        pad_x,
        toolbar_y,
        status_w,
        btn_h,
        status_str,
    );
    status_ic.setCustomColor(fb.Color.INK);
    _ = try win.addIcon(status_ic);

    self.focusWindowById(WIN_TERMINAL_ID);
    self.markFullDirty();
}

pub fn renderTerminalOverlay(
    self: *DiosixGui,
    surface: *fb.Surface,
    win: *Window,
) void {
    if (!self.terminal.active or !win.is_onscreen) return;

    const pad_x: i32 = @intCast(self.scalePx(14));
    const top_y: i32 = win.y + @as(i32, @intCast(self.scalePx(74)));
    const bot_y: i32 = win.y + @as(i32, @intCast(win.height)) -
        @as(i32, @intCast(self.scalePx(12)));
    const well_w: u32 = win.width -| @as(u32, @intCast(pad_x * 2));
    const well_h: u32 = if (bot_y > top_y + 16) @intCast(bot_y - top_y) else 0;
    if (well_w == 0 or well_h == 0) return;

    const well_bg = if (self.terminal.inverted)
        fb.Color.INK
    else
        fb.Color.INPUT_BG;
    const fg_col = if (self.terminal.inverted)
        fb.Color.WHITE
    else
        fb.Color.INK;

    const well_box = fb.Box.fromPosSize(win.x + pad_x, top_y, well_w, well_h);
    surface.drawGlassPane(
        well_box,
        6,
        well_bg,
        245,
        fb.Color.GLASS_BORDER,
        false,
        false,
    );

    const inner_pad: i32 = @intCast(self.scalePx(8));
    const clip_box = fb.Box.fromPosSize(
        well_box.x0 + inner_pad,
        well_box.y0 + inner_pad,
        well_w -| @as(u32, @intCast(inner_pad * 2)),
        well_h -| @as(u32, @intCast(inner_pad * 2)),
    );
    const prev_clip = surface.pushClip(clip_box);
    defer surface.popClip(prev_clip);
    if (surface.clip.isEmpty()) return;

    const inner_w: u32 = @intCast(@max(0, clip_box.x1 - clip_box.x0));
    const inner_h: u32 = @intCast(@max(0, clip_box.y1 - clip_box.y0));
    const font_h: u32 = font.getActiveLineHeight();
    const cell_w: u32 = @max(4, font.getMonoCharAdvanceAtHeight(font_h));
    const row_step: u32 = font_h + @max(2, font_h / 6);

    if (inner_w >= cell_w * 20 and inner_h >= row_step * 6) {
        self.terminal.resizeGrid(inner_w / cell_w, inner_h / row_step);
    }

    const step_y: i32 = @intCast(row_step);
    const eff_rows = @min(self.terminal.rows, terminal_mod.MAX_TERM_ROWS);
    const eff_cols = @min(self.terminal.cols, terminal_mod.MAX_TERM_COLS);

    for (0..eff_rows) |r| {
        const ry: i32 = clip_box.y0 + @as(i32, @intCast(r)) * step_y;
        const row_trimmed = self.terminal.getRowTrimmed(r);
        if (row_trimmed.len > 0) {
            font.drawMonoTextAtHeight(
                surface,
                row_trimmed,
                clip_box.x0,
                ry,
                fg_col,
                font_h,
            );
        }
    }

    const cur_r = @min(self.terminal.cursor_row, eff_rows -| 1);
    const cur_c = @min(self.terminal.cursor_col, eff_cols -| 1);
    const cur_x = clip_box.x0 +
        @as(i32, @intCast(cur_c)) * @as(i32, @intCast(cell_w));
    const cur_y = clip_box.y0 + @as(i32, @intCast(cur_r)) * step_y;
    surface.fillBox(
        fb.Box.fromPosSize(cur_x, cur_y + 1, cell_w, font_h),
        fg_col,
    );
}

test {
    _ = state_mod;
    std.testing.refAllDecls(@This());
}
