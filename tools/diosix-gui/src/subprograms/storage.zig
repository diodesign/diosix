// Storage & Disk Manager Sub-Program for Diosix GUI
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

pub const WIN_STORAGE_LIST_ID: u32 = 400;
pub const WIN_STORAGE_ACTIONS_ID: u32 = 401;
pub const WIN_STORAGE_DETAILS_ID: u32 = 402;

pub const ICON_DISK_ITEM1_ID: u32 = 4001;
pub const ICON_DISK_ITEM2_ID: u32 = 4002;
pub const ICON_DISK_ITEM3_ID: u32 = 4003;
pub const ICON_DISK_CREATE_ID: u32 = 4101;
pub const ICON_DISK_RESIZE_ID: u32 = 4102;
pub const ICON_DISK_DELETE_ID: u32 = 4103;
pub const ICON_STORAGE_DETAIL_ID: u32 = 4201;

pub const StorageData = struct {
    detail_msg: [128]u8 = @splat(0),
    detail_len: usize = 0,

    pub fn setDetail(self: *StorageData, msg: []const u8) void {
        const c_len = @min(msg.len, self.detail_msg.len);
        @memcpy(self.detail_msg[0..c_len], msg[0..c_len]);
        self.detail_len = c_len;
    }
};

var global_storage_data = StorageData{};

pub fn createSubProgram(allocator: std.mem.Allocator) SubProgram {
    var sub = SubProgram.init(
        allocator,
        4,
        "storage",
        "4: STORAGE",
        init,
        tick,
        onActivate,
        onDeactivate,
        handleKey,
        handleMouseClick,
        handleMouseMove,
    );
    sub.user_data = &global_storage_data;
    return sub;
}

pub fn init(sub: *SubProgram, gui_ctx: *anyopaque) void {
    _ = sub;
    _ = gui_ctx;
    global_storage_data.setDetail("Datastore volume mounted at /var/lib/diosix/disks (ext4).");
}

pub fn onActivate(sub: *SubProgram, gui_ctx: *anyopaque) void {
    _ = sub;
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    gui.setWindowOnScreen(WIN_STORAGE_LIST_ID, true);
    gui.setWindowOnScreen(WIN_STORAGE_ACTIONS_ID, true);
    gui.setWindowOnScreen(WIN_STORAGE_DETAILS_ID, true);
}

pub fn onDeactivate(sub: *SubProgram, gui_ctx: *anyopaque) void {
    _ = sub;
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    gui.setWindowOnScreen(WIN_STORAGE_LIST_ID, false);
    gui.setWindowOnScreen(WIN_STORAGE_ACTIONS_ID, false);
    gui.setWindowOnScreen(WIN_STORAGE_DETAILS_ID, false);
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

pub fn onDiskItemClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Selected Disk: '{s}' (Format: ext4, Location: /var/lib/diosix/disks/)", .{icon.getText()}) catch "";
    global_storage_data.setDetail(msg);
    updateDetailView(gui_ctx);
}

pub fn onCreateDiskClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    _ = icon;
    global_storage_data.setDetail("Create Disk: dsx disk create <name> --size <size_mb>");
    updateDetailView(gui_ctx);
}

pub fn onResizeDiskClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    _ = icon;
    global_storage_data.setDetail("Resize Disk: dsx disk resize <name> --size <new_size>");
    updateDetailView(gui_ctx);
}

pub fn onDeleteDiskClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    _ = icon;
    global_storage_data.setDetail("Delete Disk: dsx disk delete <name>");
    updateDetailView(gui_ctx);
}

fn updateDetailView(gui_ctx: *anyopaque) void {
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    if (gui.findIcon(WIN_STORAGE_DETAILS_ID, ICON_STORAGE_DETAIL_ID)) |ic| {
        ic.setText(global_storage_data.detail_msg[0..global_storage_data.detail_len]);
    }
}
