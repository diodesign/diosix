// Interactive Guest VirtIO-GPU Desktop Display Pane for Diosix GUI.
//
// Streams guest 2D framebuffer scanouts via /dev/diosix, renders an
// aspect-ratio-preserving viewport inside a full-width slide-in pane, and
// delegates keyboard, mouse, tablet, and OSK input to desktop/input.zig.
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
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const state_mod = @import("terminal_state.zig");
const sbi = @import("interface").sbi;
pub const input = @import("desktop/input.zig");
pub const render = @import("desktop/render.zig");
pub const poll = @import("desktop/poll.zig");

pub const WIN_GUEST_DISPLAY_ID: u32 = 204;
pub const ICON_GUEST_DISPLAY_ID: u32 = 1247;
pub const ICON_DISP_STATUS_ID: u32 = 1510;
pub const ICON_DISP_SSH_BTN_ID: u32 = 1511;
pub const ICON_DISP_CON_BTN_ID: u32 = 1512;
pub const ICON_DISP_OSK_BTN_ID: u32 = 1513;

pub const renderDesktopOverlay = render.renderDesktopOverlay;
pub const pollDesktop = poll.pollDesktop;
pub const pollDesktopScanout = poll.pollDesktopScanout;
pub const handleDesktopPointerMove = input.handleDesktopPointerMove;
pub const handleDesktopMouseButton = input.handleDesktopMouseButton;
pub const handleDesktopMouseRelease = input.handleDesktopMouseRelease;
pub const handleDesktopScroll = input.handleDesktopScroll;
pub const handleDesktopEvdevKey = input.handleDesktopEvdevKey;
pub const sendAsciiToDesktop = input.sendAsciiToDesktop;
pub const sendSpecialToDesktop = input.sendSpecialToDesktop;

const BORDER_GAP = gui_mod.BORDER_GAP;

pub const DesktopSession = struct {
    active: bool = false,
    target_cid: u64 = 0,
    guest_name: [host_info.GUEST_NAME_BYTES]u8 = @splat(0),
    guest_name_len: usize = 0,
    frame_buf: ?[]u32 = null,
    zero_copy_pixels: ?[]const u32 = null,
    cursor_pixels: ?[]u32 = null,
    fb_width: u32 = 0,
    fb_height: u32 = 0,
    scanout_active: bool = false,
    frame_seq: u64 = 0,
    cursor_seq: u64 = 0,
    cursor_visible: bool = false,
    cursor_x: i32 = 0,
    cursor_y: i32 = 0,
    cursor_hot_x: u32 = 0,
    cursor_hot_y: u32 = 0,
    cursor_w: u32 = 0,
    cursor_h: u32 = 0,
    last_dirty_box: fb.Box = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 },
    has_dirty_rect: bool = false,
    viewport_box: fb.Box = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 },
    pointer_buttons: u8 = 0,
    pressed_keys: [32]u8 = @splat(0),

    pub fn getGuestName(self: *const DesktopSession) []const u8 {
        return self.guest_name[0..self.guest_name_len];
    }

    pub fn setGuestName(self: *DesktopSession, name: []const u8) void {
        const s = text_label.fmtLabel(&self.guest_name, "{s}", .{name});
        self.guest_name_len = s.len;
    }

    pub fn close(self: *DesktopSession, allocator: std.mem.Allocator) void {
        if (self.active and self.target_cid >= sbi.CID_FIRST_CHILD) {
            host_info.desktop.unmapGuestScanout(self.target_cid);
        }
        if (self.cursor_pixels) |cb| allocator.free(cb);
        if (self.frame_buf) |buf| allocator.free(buf);
        self.* = .{};
    }
};

fn onOpenDisplayClicked(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    openGuestDesktop(self, @intCast(ic.user_tag)) catch {};
}

fn onSwitchToSshClicked(g: *anyopaque, _: *anyopaque, _: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    if (!self.desktop.active) return;
    const cid = self.desktop.target_cid;
    self.openGuestTerminal(cid, .ssh) catch {};
}

fn onSwitchToConsoleClicked(g: *anyopaque, _: *anyopaque, _: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    if (!self.desktop.active) return;
    const cid = self.desktop.target_cid;
    self.openGuestTerminal(cid, .console) catch {};
}

fn onToggleOskClicked(g: *anyopaque, _: *anyopaque, _: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    self.osk_state.toggle();
    buildDesktopWindow(self) catch {};
    self.buildOskWindow() catch {};
}

pub fn addGuestDetailDisplayButton(
    self: *DiosixGui,
    win: *Window,
    guest: *const host_info.RunningGuest,
    item_x: i32,
    menu_w: u32,
    item_h: u32,
    cur_y: *i32,
) !void {
    if (guest.isSelf()) return;
    var disp_item = Icon.createButton(
        ICON_GUEST_DISPLAY_ID,
        item_x,
        cur_y.*,
        menu_w,
        item_h,
        "Open guest display",
    );
    disp_item.user_tag = @intCast(guest.cid);
    disp_item.setHelpText(
        "View and interact with this VM's VirtIO-GPU graphical desktop",
    );
    disp_item.callback = onOpenDisplayClicked;
    _ = try win.addIcon(disp_item);
    cur_y.* += @intCast(item_h + self.scalePx(6));
}

pub fn openGuestDesktop(self: *DiosixGui, cid: u64) !void {
    if (cid < 2) return;
    if (self.desktop.active and self.desktop.target_cid != cid) {
        onDesktopNavigateBack(self);
    }
    if (!self.desktop.active) {
        var name_buf: [host_info.GUEST_NAME_BYTES]u8 = undefined;
        const guest_name = state_mod.findGuestNameByCid(cid, &name_buf);
        self.desktop.active = true;
        self.desktop.target_cid = cid;
        self.desktop.setGuestName(guest_name);
        self.desktop.frame_seq = 0;
        self.desktop.cursor_seq = 0;
        self.desktop.cursor_visible = false;
        self.desktop.cursor_w = 0;
        self.desktop.cursor_h = 0;
        self.desktop.zero_copy_pixels = null;
        self.desktop.has_dirty_rect = false;
        self.desktop.scanout_active = false;
        self.desktop.fb_width = 0;
        self.desktop.fb_height = 0;
        self.desktop.viewport_box = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
        self.desktop.pointer_buttons = 0;
        self.desktop.pressed_keys = @splat(0);
    }

    self.selected_guest_cid = cid;
    if (self.active_menu_id != gui_mod.ICON_MENU_DISPLAY_ID) {
        try self.activateMenuItem(gui_mod.ICON_MENU_DISPLAY_ID);
    } else {
        try buildDesktopWindow(self);
    }
    if (self.osk_state.visible) try self.buildOskWindow();
    if (pollDesktopScanout(self).updated) {
        if (self.findIcon(WIN_GUEST_DISPLAY_ID, ICON_DISP_STATUS_ID)) |ic| {
            var status_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
            ic.setText(formatStatusText(self, &status_buf));
        }
        self.markWindowDirty(WIN_GUEST_DISPLAY_ID);
    }
    self.focusWindowById(WIN_GUEST_DISPLAY_ID);
}

pub fn onDesktopNavigateBack(self: *DiosixGui) void {
    if (!self.desktop.active) return;
    input.releaseAllButtons(self);
    self.desktop.close(self.allocator);
}

pub fn isDesktopWindowOpen(self: *DiosixGui) bool {
    if (!self.desktop.active) return false;
    const win = self.getWindow(WIN_GUEST_DISPLAY_ID) orelse return false;
    return win.is_onscreen;
}

pub fn formatStatusText(
    self: *const DiosixGui,
    buf: *[text_label.LABEL_BUF_BYTES]u8,
) []const u8 {
    if (self.desktop.scanout_active and
        self.desktop.fb_width > 0 and self.desktop.fb_height > 0)
    {
        return text_label.fmtLabel(
            buf,
            "{s} (CID {d} - {d}x{d} VirtIO-GPU)",
            .{
                self.desktop.getGuestName(),
                self.desktop.target_cid,
                self.desktop.fb_width,
                self.desktop.fb_height,
            },
        );
    }
    return text_label.fmtLabel(
        buf,
        "{s} (CID {d} - waiting for guest display)",
        .{ self.desktop.getGuestName(), self.desktop.target_cid },
    );
}

pub fn desiredGuestDisplaySize(
    self: *DiosixGui,
) struct { width: u32, height: u32 } {
    if (self.getWindow(WIN_GUEST_DISPLAY_ID)) |win| {
        const layout = render.computeViewportLayout(
            self,
            win.x,
            win.y,
            win.width,
            win.height,
        );
        return .{
            .width = layout.inner_box.width(),
            .height = layout.inner_box.height(),
        };
    }
    const rect = state_mod.computeTermRect(self);
    const layout = render.computeViewportLayout(
        self,
        rect.x,
        BORDER_GAP,
        rect.w,
        rect.h,
    );
    return .{
        .width = layout.inner_box.width(),
        .height = layout.inner_box.height(),
    };
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

pub fn buildDesktopWindow(self: *DiosixGui) !void {
    if (!self.desktop.active) {
        _ = self.destroyWindow(WIN_GUEST_DISPLAY_ID);
        return;
    }

    const rect = state_mod.computeTermRect(self);
    const win = try self.createWindow(
        WIN_GUEST_DISPLAY_ID,
        rect.x,
        BORDER_GAP,
        rect.w,
        rect.h,
        "Guest VM display",
    );
    win.natural_height = rect.h;
    win.parent_window_id = gui_mod.WIN_MENU_ID;
    win.linked_menu_item_id = gui_mod.ICON_MENU_DISPLAY_ID;
    if (self.getWindow(gui_mod.WIN_MENU_ID)) |mw| {
        mw.child_window_id = WIN_GUEST_DISPLAY_ID;
    }
    win.setHelpText(
        "Interactive guest VM desktop (use Back on the left to return)",
    );

    const pad_x: i32 = @intCast(self.scalePx(render.VIEWPORT_PAD_X_BASE));
    const toolbar_y: i32 = @intCast(self.scalePx(38));
    const btn_h: u32 = @max(
        self.scalePx(26),
        font.getActiveLineHeight() + self.scalePx(8),
    );
    const btn_gap: i32 = @intCast(self.scalePx(6));

    const osk_w = measureBtnW(self, 92, "Keyboard");
    const con_w = measureBtnW(self, 120, "Serial console");
    const ssh_w = measureBtnW(self, 96, "SSH shell");

    var right_x: i32 = @as(i32, @intCast(rect.w)) - pad_x -
        @as(i32, @intCast(osk_w));
    try addToolbarBtn(
        win,
        ICON_DISP_OSK_BTN_ID,
        right_x,
        toolbar_y,
        osk_w,
        btn_h,
        "Keyboard",
        "Toggle the dockable on-screen keyboard",
        onToggleOskClicked,
    );

    right_x -= @as(i32, @intCast(con_w)) + btn_gap;
    try addToolbarBtn(
        win,
        ICON_DISP_CON_BTN_ID,
        right_x,
        toolbar_y,
        con_w,
        btn_h,
        "Serial console",
        "Switch to this VM's hvc0 serial console",
        onSwitchToConsoleClicked,
    );

    right_x -= @as(i32, @intCast(ssh_w)) + btn_gap;
    try addToolbarBtn(
        win,
        ICON_DISP_SSH_BTN_ID,
        right_x,
        toolbar_y,
        ssh_w,
        btn_h,
        "SSH shell",
        "Switch to this VM's interactive SSH shell",
        onSwitchToSshClicked,
    );

    var status_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
    const status_str = formatStatusText(self, &status_buf);
    const status_w: u32 = if (right_x > pad_x + 24)
        @intCast(right_x - pad_x - btn_gap)
    else
        self.scalePx(160);
    var status_ic = Icon.createReadOnly(
        ICON_DISP_STATUS_ID,
        pad_x,
        toolbar_y,
        status_w,
        btn_h,
        status_str,
    );
    status_ic.setCustomColor(fb.Color.INK);
    _ = try win.addIcon(status_ic);

    self.focusWindowById(WIN_GUEST_DISPLAY_ID);
    self.markFullDirty();
}

test {
    _ = input;
    _ = render;
    _ = poll;
    std.testing.refAllDecls(@This());
}
