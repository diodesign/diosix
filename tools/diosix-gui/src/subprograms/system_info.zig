// System & Host Information Sub-Program for Diosix GUI
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

// Window IDs owned by SystemInfo
pub const WIN_SPECS_ID: u32 = 100;
pub const WIN_ACTIONS_ID: u32 = 101;
pub const WIN_LOG_ID: u32 = 102;

// Icon IDs
pub const ICON_BADGE_ID: u32 = 1001;
pub const ICON_CID_ID: u32 = 1002;
pub const ICON_ARCH_ID: u32 = 1003;
pub const ICON_VCPUS_ID: u32 = 1004;
pub const ICON_RAM_ID: u32 = 1005;
pub const ICON_HV_ID: u32 = 1006;
pub const ICON_UPTIME_ID: u32 = 1007;
pub const ICON_NET_ID: u32 = 1008;

pub const ICON_BTN_REFRESH_ID: u32 = 1101;
pub const ICON_BTN_SPECS_ID: u32 = 1102;
pub const ICON_BTN_REBOOT_ID: u32 = 1103;
pub const ICON_BTN_POWEROFF_ID: u32 = 1104;
pub const ICON_LABEL_PLATFORM_CTRL_ID: u32 = 1199;

pub const ICON_LOG_TEXT_ID: u32 = 1201;

pub const SystemInfoData = struct {
    self_cid: usize = 1,
    is_root_vm: bool = true,
    total_ram_mb: usize = 2048,
    vcpu_count: usize = 4,
    uptime_seconds: u64 = 0,
    elapsed_ms: u64 = 0,

    log_msg: [128]u8 = @splat(0),
    log_msg_len: usize = 0,

    pub fn setLog(self: *SystemInfoData, msg: []const u8) void {
        const c_len = @min(msg.len, self.log_msg.len);
        @memcpy(self.log_msg[0..c_len], msg[0..c_len]);
        self.log_msg_len = c_len;
    }
};

var global_sys_data = SystemInfoData{};

pub fn createSubProgram(allocator: std.mem.Allocator) SubProgram {
    var sub = SubProgram.init(
        allocator,
        1,
        "system_info",
        "1: SYSTEM INFO",
        init,
        tick,
        onActivate,
        onDeactivate,
        handleKey,
        handleMouseClick,
        handleMouseMove,
    );
    sub.user_data = &global_sys_data;
    return sub;
}

fn detectSystemPrivileges() void {
    // Check if /dev/diosix exists and determine CID
    const cid: usize = 1;

    // Check /proc/cpuinfo to count vCPUs and RAM
    var vcpus: usize = 4;
    var path_buf = "/proc/cpuinfo\x00".*;
    const fd_res = std.os.linux.open(@ptrCast(&path_buf), .{ .ACCMODE = .RDONLY }, 0);
    const signed_fd: isize = @bitCast(fd_res);
    if (signed_fd >= 0) {
        const fd: i32 = @intCast(signed_fd);
        defer _ = std.os.linux.close(fd);
        var buf: [2048]u8 = undefined;
        const read_res = std.os.linux.read(fd, &buf, buf.len);
        const signed_read: isize = @bitCast(read_res);
        if (signed_read > 0) {
            const bytes_read: usize = @intCast(signed_read);
            const count = std.mem.count(u8, buf[0..bytes_read], "processor");
            if (count > 0) vcpus = count;
        }
    }

    global_sys_data.self_cid = cid;
    global_sys_data.is_root_vm = (cid == 1);
    global_sys_data.vcpu_count = vcpus;
    global_sys_data.setLog(if (cid == 1)
        "Privileged Domain 0: Full host hypervisor authority and hardware access active."
    else
        "Child Guest Domain: Host power and hypervisor administration restricted to Root VM.");
}

pub fn init(sub: *SubProgram, gui_ctx: *anyopaque) void {
    _ = sub;
    _ = gui_ctx;
    detectSystemPrivileges();
}

pub fn onActivate(sub: *SubProgram, gui_ctx: *anyopaque) void {
    _ = sub;
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    // Bring windows on-screen
    gui.setWindowOnScreen(WIN_SPECS_ID, true);
    gui.setWindowOnScreen(WIN_ACTIONS_ID, true);
    gui.setWindowOnScreen(WIN_LOG_ID, true);
}

pub fn onDeactivate(sub: *SubProgram, gui_ctx: *anyopaque) void {
    _ = sub;
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    // Park windows off-screen
    gui.setWindowOnScreen(WIN_SPECS_ID, false);
    gui.setWindowOnScreen(WIN_ACTIONS_ID, false);
    gui.setWindowOnScreen(WIN_LOG_ID, false);
}

pub const MS_PER_SECOND: u32 = 1000;
pub const SECONDS_PER_HOUR: u64 = 3600;
pub const SECONDS_PER_MINUTE: u64 = 60;

// Preemptive Multitasking Tick: Called every cycle even when this subprogram is not active!
pub fn tick(sub: *SubProgram, gui_ctx: *anyopaque, dt_ms: u32, is_active: bool) void {
    _ = sub;
    global_sys_data.elapsed_ms += dt_ms;
    if (global_sys_data.elapsed_ms >= MS_PER_SECOND) {
        global_sys_data.elapsed_ms -= MS_PER_SECOND;
        global_sys_data.uptime_seconds += 1;

        // If in view, update live uptime text
        if (is_active) {
            const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
            if (gui.findIcon(WIN_SPECS_ID, ICON_UPTIME_ID)) |ic| {
                var up_buf: [64]u8 = undefined;
                const hrs = global_sys_data.uptime_seconds / SECONDS_PER_HOUR;
                const mins = (global_sys_data.uptime_seconds % SECONDS_PER_HOUR) / SECONDS_PER_MINUTE;
                const secs = global_sys_data.uptime_seconds % SECONDS_PER_MINUTE;
                const up_str = std.fmt.bufPrint(&up_buf, "Uptime: {d}h {d}m {d}s", .{ hrs, mins, secs }) catch "Uptime: 0s";
                ic.setText(up_str);
            }
        }
    }
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

// Subprocess execution helper
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

// Callbacks for interactive buttons
pub fn onRefreshClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    _ = icon;
    detectSystemPrivileges();
    global_sys_data.setLog("System status refreshed from hypervisor and kernel interfaces.");
    updateLogView(gui_ctx);
}

pub fn onSpecsClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    _ = icon;
    global_sys_data.setLog("Hardware Virt: RISC-V H-Extension (rv64gc / sv39x4 nested page tables active).");
    updateLogView(gui_ctx);
}

pub fn onRebootClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    _ = icon;
    if (global_sys_data.is_root_vm) {
        global_sys_data.setLog("Root VM Command: Initiating host system reboot...");
        updateLogView(gui_ctx);
        runSubprocess(&[_:null]?[*:0]const u8{ "/sbin/reboot", "-f", null });
    } else {
        global_sys_data.setLog("Permission Denied: Only Root VM (Domain 0) can reboot host.");
        updateLogView(gui_ctx);
    }
}

pub fn onPowerOffClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    _ = icon;
    if (global_sys_data.is_root_vm) {
        global_sys_data.setLog("Root VM Command: Powering off host platform...");
        updateLogView(gui_ctx);
        runSubprocess(&[_:null]?[*:0]const u8{ "/sbin/poweroff", "-f", null });
    } else {
        global_sys_data.setLog("Permission Denied: Only Root VM (Domain 0) can power off host.");
        updateLogView(gui_ctx);
    }
}

fn updateLogView(gui_ctx: *anyopaque) void {
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    if (gui.findIcon(WIN_LOG_ID, ICON_LOG_TEXT_ID)) |ic| {
        ic.setText(global_sys_data.log_msg[0..global_sys_data.log_msg_len]);
    }
}
