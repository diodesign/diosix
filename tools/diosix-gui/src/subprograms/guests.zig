// Guest VM Domain Manager Sub-Program for Diosix GUI
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("../framebuffer.zig");
const icon_mod = @import("../icon.zig");
const Icon = icon_mod.Icon;
const window_mod = @import("../window.zig");
const Window = window_mod.Window;
const sub_mod = @import("../subprogram.zig");
const SubProgram = sub_mod.SubProgram;
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;

pub const WIN_GUEST_LIST_ID: u32 = 300;
pub const WIN_GUEST_ACTIONS_ID: u32 = 301;
pub const WIN_GUEST_DETAILS_ID: u32 = 302;

pub const ICON_GUEST_ROW1_ID: u32 = 3001;
pub const ICON_GUEST_ROW2_ID: u32 = 3002;
pub const ICON_GUEST_ROW3_ID: u32 = 3003;
pub const ICON_GUEST_ACTION_LAUNCH_ID: u32 = 3101;
pub const ICON_GUEST_ACTION_STOP_ID: u32 = 3102;
pub const ICON_GUEST_ACTION_SSH_ID: u32 = 3103;
pub const ICON_GUEST_DETAIL_TEXT_ID: u32 = 3201;

pub const GuestsData = struct {
    selected_guest: u32 = 1,
    detail_msg: [128]u8 = @splat(0),
    detail_len: usize = 0,

    pub fn setDetail(self: *GuestsData, msg: []const u8) void {
        const c_len = @min(msg.len, self.detail_msg.len);
        @memcpy(self.detail_msg[0..c_len], msg[0..c_len]);
        self.detail_len = c_len;
    }
};

var global_guests_data = GuestsData{};

pub fn createSubProgram(allocator: std.mem.Allocator) SubProgram {
    var sub = SubProgram.init(
        allocator,
        3,
        "guest_vms",
        "3: GUEST VMS",
        init,
        tick,
        onActivate,
        onDeactivate,
        handleKey,
        handleMouseClick,
        handleMouseMove,
    );
    sub.user_data = &global_guests_data;
    return sub;
}

pub fn init(sub: *SubProgram, gui_ctx: *anyopaque) void {
    _ = sub;
    _ = gui_ctx;
    global_guests_data.setDetail("Select a guest domain to inspect or control secondary virtual machines.");
}

pub fn onActivate(sub: *SubProgram, gui_ctx: *anyopaque) void {
    _ = sub;
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    gui.setWindowOnScreen(WIN_GUEST_LIST_ID, true);
    gui.setWindowOnScreen(WIN_GUEST_ACTIONS_ID, true);
    gui.setWindowOnScreen(WIN_GUEST_DETAILS_ID, true);
}

pub fn onDeactivate(sub: *SubProgram, gui_ctx: *anyopaque) void {
    _ = sub;
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    gui.setWindowOnScreen(WIN_GUEST_LIST_ID, false);
    gui.setWindowOnScreen(WIN_GUEST_ACTIONS_ID, false);
    gui.setWindowOnScreen(WIN_GUEST_DETAILS_ID, false);
}

pub fn tick(sub: *SubProgram, gui_ctx: *anyopaque, dt_ms: u32, is_active: bool) void {
    _ = sub;
    _ = gui_ctx;
    _ = dt_ms;
    _ = is_active;
}

pub fn handleKey(sub: *SubProgram, gui_ctx: *anyopaque, key_code: u16, key_char: ?u8, pressed: bool) bool {
    _ = sub;
    _ = gui_ctx;
    _ = key_code;
    _ = key_char;
    _ = pressed;
    return false;
}

pub fn handleMouseClick(sub: *SubProgram, gui_ctx: *anyopaque, px: i32, py: i32) bool {
    _ = sub;
    _ = gui_ctx;
    _ = px;
    _ = py;
    return false;
}

pub fn handleMouseMove(sub: *SubProgram, gui_ctx: *anyopaque, px: i32, py: i32, left_down: bool) void {
    _ = sub;
    _ = gui_ctx;
    _ = px;
    _ = py;
    _ = left_down;
}

pub fn onGuestRowClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    global_guests_data.selected_guest = icon.id;
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Selected Domain: '{s}' (Virtual IP: 10.0.3.{d}, Status: RUNNING)", .{ icon.getText(), icon.id - 3000 }) catch "";
    global_guests_data.setDetail(msg);
    updateDetailView(gui_ctx);
}

pub fn onLaunchGuestClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    _ = icon;
    global_guests_data.setDetail("Spawn Command: dsx run default --name guest-vm --ram 512M --vcpus 2");
    updateDetailView(gui_ctx);
}

pub fn onStopGuestClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    _ = icon;
    global_guests_data.setDetail("Terminate Command: Sending hypercall stop request to target child domain.");
    updateDetailView(gui_ctx);
}

pub fn onSshGuestClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    _ = icon;
    global_guests_data.setDetail("SSH Connect: Connecting via Dropbear to 10.0.3.2:22 (Virtual Bridge)...");
    updateDetailView(gui_ctx);
}

fn updateDetailView(gui_ctx: *anyopaque) void {
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    if (gui.findIcon(WIN_GUEST_DETAILS_ID, ICON_GUEST_DETAIL_TEXT_ID)) |ic| {
        ic.setText(global_guests_data.detail_msg[0..global_guests_data.detail_len]);
    }
}
