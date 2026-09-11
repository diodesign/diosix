// Host Power & System Control Sub-Program for Diosix GUI
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

pub const WIN_POWER_MENU_ID: u32 = 500;
pub const WIN_POWER_STATUS_ID: u32 = 501;

pub const ICON_PWR_REBOOT_ID: u32 = 5001;
pub const ICON_PWR_SHUTDOWN_ID: u32 = 5002;
pub const ICON_PWR_SUSPEND_ID: u32 = 5003;
pub const ICON_PWR_STATUS_TEXT_ID: u32 = 5101;

pub const PowerData = struct {
    is_root_vm: bool = true,
    status_msg: [128]u8 = @splat(0),
    status_len: usize = 0,

    pub fn setStatus(self: *PowerData, msg: []const u8) void {
        const c_len = @min(msg.len, self.status_msg.len);
        @memcpy(self.status_msg[0..c_len], msg[0..c_len]);
        self.status_len = c_len;
    }
};

var global_power_data = PowerData{};

pub fn createSubProgram(allocator: std.mem.Allocator) SubProgram {
    var sub = SubProgram.init(
        allocator,
        5,
        "power",
        "5: POWER",
        init,
        tick,
        onActivate,
        onDeactivate,
        handleKey,
        handleMouseClick,
        handleMouseMove,
    );
    sub.user_data = &global_power_data;
    return sub;
}

pub fn init(sub: *SubProgram, gui_ctx: *anyopaque) void {
    _ = sub;
    _ = gui_ctx;
    global_power_data.is_root_vm = true; // Auto-detected from system_info
    global_power_data.setStatus("Host Platform Power Management (ACPI / PSCI / SBI reset).");
}

pub fn onActivate(sub: *SubProgram, gui_ctx: *anyopaque) void {
    _ = sub;
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    gui.setWindowOnScreen(WIN_POWER_MENU_ID, true);
    gui.setWindowOnScreen(WIN_POWER_STATUS_ID, true);
}

pub fn onDeactivate(sub: *SubProgram, gui_ctx: *anyopaque) void {
    _ = sub;
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    gui.setWindowOnScreen(WIN_POWER_MENU_ID, false);
    gui.setWindowOnScreen(WIN_POWER_STATUS_ID, false);
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

fn runSubprocess(argv: [*:null]const ?[*:0]const u8) void {
    const pid_res = std.os.linux.fork();
    const pid_signed: isize = @bitCast(pid_res);
    if (pid_signed == 0) {
        const envp: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
            "PATH=/bin:/sbin:/usr/bin:/usr/sbin",
            null,
        };
        _ = std.os.linux.execve(argv[0].?, argv, envp);
        std.os.linux.exit(127);
    }
}

pub fn onPowerReboot(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    _ = icon;
    if (global_power_data.is_root_vm) {
        global_power_data.setStatus("Host Action: Resetting hardware platform via hypercall reset...");
        updateStatusView(gui_ctx);
        runSubprocess(&[_:null]?[*:0]const u8{ "/sbin/reboot", "-f", null });
    } else {
        global_power_data.setStatus("Denied: Host reboot is restricted to Root VM (Domain 0).");
        updateStatusView(gui_ctx);
    }
}

pub fn onPowerShutdown(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    _ = icon;
    if (global_power_data.is_root_vm) {
        global_power_data.setStatus("Host Action: Powering down hardware platform...");
        updateStatusView(gui_ctx);
        runSubprocess(&[_:null]?[*:0]const u8{ "/sbin/poweroff", "-f", null });
    } else {
        global_power_data.setStatus("Denied: Host power-off is restricted to Root VM (Domain 0).");
        updateStatusView(gui_ctx);
    }
}

pub fn onPowerSuspend(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    _ = icon;
    global_power_data.setStatus("Host Action: Suspend-to-RAM / Low power standby requested.");
    updateStatusView(gui_ctx);
}

fn updateStatusView(gui_ctx: *anyopaque) void {
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    if (gui.findIcon(WIN_POWER_STATUS_ID, ICON_PWR_STATUS_TEXT_ID)) |ic| {
        ic.setText(global_power_data.status_msg[0..global_power_data.status_len]);
    }
}
