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
pub const WIN_GUEST_VIDEO_ID: u32 = 303;
pub const WIN_GUEST_FULLSCREEN_VIDEO_ID: u32 = 304;

pub const BASE_GUEST_ROW_ID: u32 = 3000;
pub const ICON_GUEST_ROW1_ID: u32 = BASE_GUEST_ROW_ID + 1;
pub const ICON_GUEST_ROW2_ID: u32 = BASE_GUEST_ROW_ID + 2;
pub const ICON_GUEST_ROW3_ID: u32 = BASE_GUEST_ROW_ID + 3;

pub const ICON_GUEST_ACTION_LAUNCH_ID: u32 = 3101;
pub const ICON_GUEST_ACTION_STOP_ID: u32 = 3102;
pub const ICON_GUEST_ACTION_SSH_ID: u32 = 3103;
pub const ICON_GUEST_ACTION_PAUSE_ID: u32 = 3104;
pub const ICON_GUEST_ACTION_FULLSCREEN_ID: u32 = 3105;

pub const ICON_GUEST_DETAIL_TEXT_ID: u32 = 3201;
pub const ICON_GUEST_METER_CPU_ID: u32 = 3202;
pub const ICON_GUEST_TEXT_CPU_INFO_ID: u32 = 3203;
pub const ICON_GUEST_METER_RAM_ID: u32 = 3204;
pub const ICON_GUEST_TEXT_RAM_INFO_ID: u32 = 3205;
pub const ICON_GUEST_METER_DISK_ID: u32 = 3206;
pub const ICON_GUEST_TEXT_DISK_INFO_ID: u32 = 3207;
pub const ICON_GUEST_METER_NET_ID: u32 = 3208;
pub const ICON_GUEST_TEXT_NET_INFO_ID: u32 = 3209;

pub const ICON_GUEST_VIDEO_VIEWPORT_ID: u32 = 3301;
pub const ICON_GUEST_FULLSCREEN_VIEWPORT_ID: u32 = 3401;

pub const GuestStatus = enum {
    running,
    paused,
    stopped,

    pub fn asString(self: GuestStatus) []const u8 {
        return switch (self) {
            .running => "RUNNING",
            .paused => "PAUSED",
            .stopped => "STOPPED",
        };
    }
};

pub const GuestVideoMode = enum {
    virtio_gpu,
    headless,

    pub fn asString(self: GuestVideoMode) []const u8 {
        return switch (self) {
            .virtio_gpu => "VirtIO-GPU",
            .headless => "Headless",
        };
    }
};

pub const GuestEntry = struct {
    id: u32,
    cid: u32,
    name: [32]u8,
    name_len: usize,
    status: GuestStatus,
    vcpus: u32,
    ram_mb: u32,
    ram_used_mb: u32,
    ip: [16]u8,
    ip_len: usize,
    video_mode: GuestVideoMode,

    // Live Resource Telemetry
    cpu_util_pct: u32, // 0 - 100%
    cpu_mhz: u32, // e.g. 2400
    cpu_cycles_m: u32, // Million cycles
    disk_total_mb: u32, // Datastore allocation in MB
    disk_used_mb: u32, // Committed virtual storage in MB
    disk_read_mbs_x10: u32, // 34 => 3.4 MB/s
    disk_write_mbs_x10: u32, // 12 => 1.2 MB/s
    disk_iops: u32, // e.g. 480
    net_rx_kb: u32,
    net_tx_kb: u32,

    pub fn getName(self: *const GuestEntry) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getIp(self: *const GuestEntry) []const u8 {
        return self.ip[0..self.ip_len];
    }

    pub fn setName(self: *GuestEntry, new_name: []const u8) void {
        const copy_len = @min(new_name.len, self.name.len);
        @memcpy(self.name[0..copy_len], new_name[0..copy_len]);
        self.name_len = copy_len;
    }

    pub fn setIp(self: *GuestEntry, new_ip: []const u8) void {
        const copy_len = @min(new_ip.len, self.ip.len);
        @memcpy(self.ip[0..copy_len], new_ip[0..copy_len]);
        self.ip_len = copy_len;
    }
};

pub const MAX_GUESTS_CATALOG: usize = 3;

pub const GuestsData = struct {
    guests: [MAX_GUESTS_CATALOG]GuestEntry = undefined,
    selected_idx: usize = 0,
    selected_guest: u32 = ICON_GUEST_ROW1_ID,
    detail_msg: [160]u8 = @splat(0),
    detail_len: usize = 0,
    is_fullscreen: bool = false,
    anim_tick: u32 = 0,

    pub fn setDetail(self: *GuestsData, msg: []const u8) void {
        const c_len = @min(msg.len, self.detail_msg.len);
        @memcpy(self.detail_msg[0..c_len], msg[0..c_len]);
        self.detail_len = c_len;
    }

    pub fn getSelectedEntry(self: *GuestsData) *GuestEntry {
        return &self.guests[self.selected_idx];
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

    // Initialize domain catalog
    // Guest 1: second-vm (Active with VirtIO-GPU video output)
    var g1 = GuestEntry{
        .id = ICON_GUEST_ROW1_ID,
        .cid = 2,
        .name = undefined,
        .name_len = 0,
        .status = .running,
        .vcpus = 2,
        .ram_mb = 256,
        .ram_used_mb = 141,
        .ip = undefined,
        .ip_len = 0,
        .video_mode = .virtio_gpu,
        .cpu_util_pct = 42,
        .cpu_mhz = 2400,
        .cpu_cycles_m = 14820,
        .disk_total_mb = 512,
        .disk_used_mb = 184,
        .disk_read_mbs_x10 = 34,
        .disk_write_mbs_x10 = 12,
        .disk_iops = 480,
        .net_rx_kb = 1840,
        .net_tx_kb = 920,
    };
    g1.setName("second-vm");
    g1.setIp("10.0.3.2");
    global_guests_data.guests[0] = g1;

    // Guest 2: debian-vm (Active with VirtIO-GPU video output, higher disk load)
    var g2 = GuestEntry{
        .id = ICON_GUEST_ROW2_ID,
        .cid = 3,
        .name = undefined,
        .name_len = 0,
        .status = .running,
        .vcpus = 2,
        .ram_mb = 1024,
        .ram_used_mb = 614,
        .ip = undefined,
        .ip_len = 0,
        .video_mode = .virtio_gpu,
        .cpu_util_pct = 68,
        .cpu_mhz = 2400,
        .cpu_cycles_m = 42100,
        .disk_total_mb = 4096,
        .disk_used_mb = 1540,
        .disk_read_mbs_x10 = 128,
        .disk_write_mbs_x10 = 45,
        .disk_iops = 1240,
        .net_rx_kb = 6420,
        .net_tx_kb = 3180,
    };
    g2.setName("debian-vm");
    g2.setIp("10.0.3.3");
    global_guests_data.guests[1] = g2;

    // Guest 3: micro-guest (Headless domain with serial UART & SSH console)
    var g3 = GuestEntry{
        .id = ICON_GUEST_ROW3_ID,
        .cid = 4,
        .name = undefined,
        .name_len = 0,
        .status = .running,
        .vcpus = 1,
        .ram_mb = 64,
        .ram_used_mb = 18,
        .ip = undefined,
        .ip_len = 0,
        .video_mode = .headless,
        .cpu_util_pct = 14,
        .cpu_mhz = 2400,
        .cpu_cycles_m = 3890,
        .disk_total_mb = 64,
        .disk_used_mb = 18,
        .disk_read_mbs_x10 = 2,
        .disk_write_mbs_x10 = 1,
        .disk_iops = 35,
        .net_rx_kb = 340,
        .net_tx_kb = 180,
    };
    g3.setName("micro-guest");
    g3.setIp("10.0.3.4");
    global_guests_data.guests[2] = g3;

    global_guests_data.selected_idx = 0;
    global_guests_data.selected_guest = ICON_GUEST_ROW1_ID;
    global_guests_data.setDetail("Select a guest domain to inspect video display, live telemetry, and control secondary virtual machines.");
}

pub fn onActivate(sub: *SubProgram, gui_ctx: *anyopaque) void {
    _ = sub;
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    if (global_guests_data.is_fullscreen) {
        gui.setWindowOnScreen(WIN_GUEST_FULLSCREEN_VIDEO_ID, true);
        gui.setWindowOnScreen(WIN_GUEST_LIST_ID, false);
        gui.setWindowOnScreen(WIN_GUEST_ACTIONS_ID, false);
        gui.setWindowOnScreen(WIN_GUEST_DETAILS_ID, false);
        gui.setWindowOnScreen(WIN_GUEST_VIDEO_ID, false);
    } else {
        gui.setWindowOnScreen(WIN_GUEST_LIST_ID, true);
        gui.setWindowOnScreen(WIN_GUEST_ACTIONS_ID, true);
        gui.setWindowOnScreen(WIN_GUEST_DETAILS_ID, true);
        gui.setWindowOnScreen(WIN_GUEST_VIDEO_ID, true);
        gui.setWindowOnScreen(WIN_GUEST_FULLSCREEN_VIDEO_ID, false);
    }
    updateSelectedGuestView(gui_ctx);
}

pub fn onDeactivate(sub: *SubProgram, gui_ctx: *anyopaque) void {
    _ = sub;
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    gui.setWindowOnScreen(WIN_GUEST_LIST_ID, false);
    gui.setWindowOnScreen(WIN_GUEST_ACTIONS_ID, false);
    gui.setWindowOnScreen(WIN_GUEST_DETAILS_ID, false);
    gui.setWindowOnScreen(WIN_GUEST_VIDEO_ID, false);
    gui.setWindowOnScreen(WIN_GUEST_FULLSCREEN_VIDEO_ID, false);
}

pub fn tick(sub: *SubProgram, gui_ctx: *anyopaque, dt_ms: u32, is_active: bool) void {
    _ = sub;
    _ = dt_ms;
    global_guests_data.anim_tick +%= 1;

    // Simulate realistic undulation of CPU activity and cycle counters for running guests
    if (global_guests_data.anim_tick % 10 == 0) {
        for (&global_guests_data.guests) |*g| {
            if (g.status == .running) {
                g.cpu_cycles_m +%= 1;
                const step = @as(i32, @intCast(global_guests_data.anim_tick % 5)) - 2;
                const new_pct = @as(i32, @intCast(g.cpu_util_pct)) + step;
                g.cpu_util_pct = @intCast(std.math.clamp(new_pct, 5, 95));
            }
        }
        if (is_active) {
            updateSelectedGuestView(gui_ctx);
        }
    }
}

pub fn handleKey(sub: *SubProgram, gui_ctx: *anyopaque, key_code: u16, key_char: ?u8, pressed: bool) bool {
    _ = sub;
    if (!pressed) return false;
    const Key = gui_mod.Key;

    if (key_code == Key.ESC) {
        if (global_guests_data.is_fullscreen) {
            exitFullscreen(gui_ctx);
            return true;
        }
    }

    if (key_char == 'f' or key_char == 'F') {
        toggleFullscreen(gui_ctx);
        return true;
    }

    return false;
}

pub fn handleMouseClick(sub: *SubProgram, gui_ctx: *anyopaque, px: i32, py: i32) bool {
    _ = sub;
    _ = px;
    _ = py;
    if (global_guests_data.is_fullscreen) {
        exitFullscreen(gui_ctx);
        return true;
    }
    return false;
}

pub fn handleMouseMove(sub: *SubProgram, gui_ctx: *anyopaque, px: i32, py: i32, left_down: bool) void {
    _ = sub;
    _ = gui_ctx;
    _ = px;
    _ = py;
    _ = left_down;
}

pub fn isFullscreen() bool {
    return global_guests_data.is_fullscreen;
}

pub fn enterFullscreen(gui_ctx: *anyopaque) void {
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    global_guests_data.is_fullscreen = true;
    gui.setWindowOnScreen(WIN_GUEST_LIST_ID, false);
    gui.setWindowOnScreen(WIN_GUEST_ACTIONS_ID, false);
    gui.setWindowOnScreen(WIN_GUEST_DETAILS_ID, false);
    gui.setWindowOnScreen(WIN_GUEST_VIDEO_ID, false);
    gui.setWindowOnScreen(WIN_GUEST_FULLSCREEN_VIDEO_ID, true);

    for (gui.windows.items, 0..) |*win, idx| {
        if (win.id == WIN_GUEST_FULLSCREEN_VIDEO_ID) {
            gui.focusWindow(idx);
            break;
        }
    }
    updateSelectedGuestView(gui_ctx);
    gui.markFullDirty();
}

pub fn exitFullscreen(gui_ctx: *anyopaque) void {
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    global_guests_data.is_fullscreen = false;
    gui.setWindowOnScreen(WIN_GUEST_FULLSCREEN_VIDEO_ID, false);
    gui.setWindowOnScreen(WIN_GUEST_LIST_ID, true);
    gui.setWindowOnScreen(WIN_GUEST_ACTIONS_ID, true);
    gui.setWindowOnScreen(WIN_GUEST_DETAILS_ID, true);
    gui.setWindowOnScreen(WIN_GUEST_VIDEO_ID, true);

    for (gui.windows.items, 0..) |*win, idx| {
        if (win.id == WIN_GUEST_LIST_ID) {
            gui.focusWindow(idx);
            break;
        }
    }
    updateSelectedGuestView(gui_ctx);
    gui.markFullDirty();
}

pub fn toggleFullscreen(gui_ctx: *anyopaque) void {
    if (global_guests_data.is_fullscreen) {
        exitFullscreen(gui_ctx);
    } else {
        enterFullscreen(gui_ctx);
    }
}

pub fn onGuestRowClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    global_guests_data.selected_guest = icon.id;

    for (global_guests_data.guests, 0..) |g, idx| {
        if (g.id == icon.id) {
            global_guests_data.selected_idx = idx;
            break;
        }
    }

    const sel = global_guests_data.getSelectedEntry();
    var buf: [160]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Selected Domain: '{s}' (Virtual IP: {s}, Status: {s})", .{
        sel.getName(),
        sel.getIp(),
        sel.status.asString(),
    }) catch "";
    global_guests_data.setDetail(msg);
    updateSelectedGuestView(gui_ctx);
}

pub fn onLaunchGuestClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    _ = icon;
    const sel = global_guests_data.getSelectedEntry();
    sel.status = .running;
    if (sel.cpu_util_pct == 0) {
        sel.cpu_util_pct = 35;
        sel.ram_used_mb = sel.ram_mb / 2;
        sel.disk_read_mbs_x10 = 24;
        sel.disk_write_mbs_x10 = 8;
        sel.disk_iops = 320;
    }
    global_guests_data.setDetail("Spawn Command: dsx run default --name guest-vm --ram 512M --vcpus 2");
    updateSelectedGuestView(gui_ctx);
}

pub fn onStopGuestClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    _ = icon;
    const sel = global_guests_data.getSelectedEntry();
    sel.status = .stopped;
    sel.cpu_util_pct = 0;
    sel.ram_used_mb = 0;
    sel.disk_read_mbs_x10 = 0;
    sel.disk_write_mbs_x10 = 0;
    sel.disk_iops = 0;
    global_guests_data.setDetail("Terminate Command: Sending hypercall stop request to target child domain.");
    updateSelectedGuestView(gui_ctx);
}

pub fn onPauseGuestClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    _ = icon;
    const sel = global_guests_data.getSelectedEntry();
    if (sel.status == .running) {
        sel.status = .paused;
        global_guests_data.setDetail("Pause Command: Pausing vCPU execution on selected domain.");
    } else if (sel.status == .paused) {
        sel.status = .running;
        global_guests_data.setDetail("Resume Command: Resumed vCPU execution on selected domain.");
    }
    updateSelectedGuestView(gui_ctx);
}

pub fn onSshGuestClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    _ = icon;
    global_guests_data.setDetail("SSH Connect: Connecting via Dropbear to 10.0.3.2:22 (Virtual Bridge)...");
    updateDetailView(gui_ctx);
}

pub fn onToggleFullscreenClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    _ = icon;
    toggleFullscreen(gui_ctx);
}

pub fn onExitFullscreenClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    _ = icon;
    exitFullscreen(gui_ctx);
}

pub fn onVideoViewportClicked(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    _ = icon;
    enterFullscreen(gui_ctx);
}

pub fn updateSelectedGuestView(gui_ctx: *anyopaque) void {
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    const sel = global_guests_data.getSelectedEntry();
    const has_video = (sel.status == .running and sel.video_mode == .virtio_gpu);

    // 1. Update Video Viewport (normal window)
    if (gui.findIcon(WIN_GUEST_VIDEO_ID, ICON_GUEST_VIDEO_VIEWPORT_ID)) |ic| {
        ic.setText(sel.getName());
        ic.setVideoSignal(has_video);
        ic.video_anim_tick = global_guests_data.anim_tick;
    }

    // 2. Update Fullscreen Video Viewport
    if (gui.findIcon(WIN_GUEST_FULLSCREEN_VIDEO_ID, ICON_GUEST_FULLSCREEN_VIEWPORT_ID)) |ic| {
        ic.setText(sel.getName());
        ic.setVideoSignal(has_video);
        ic.video_anim_tick = global_guests_data.anim_tick;
    }

    // 3. Update Status Details Text Banner
    if (gui.findIcon(WIN_GUEST_DETAILS_ID, ICON_GUEST_DETAIL_TEXT_ID)) |ic| {
        ic.setText(global_guests_data.detail_msg[0..global_guests_data.detail_len]);
    }

    // 4. Update vCPU Utilization Progress Bar & Telemetry Text
    if (gui.findIcon(WIN_GUEST_DETAILS_ID, ICON_GUEST_METER_CPU_ID)) |ic| {
        ic.setProgress(sel.cpu_util_pct);
        var buf: [64]u8 = undefined;
        const mips = (sel.cpu_util_pct * 30) / 100;
        const label = std.fmt.bufPrint(&buf, "vCPU Utilization: {d}% [{d} MHz | {d} MIPS]", .{
            sel.cpu_util_pct,
            sel.cpu_mhz,
            mips,
        }) catch "";
        ic.setText(label);
    }
    if (gui.findIcon(WIN_GUEST_DETAILS_ID, ICON_GUEST_TEXT_CPU_INFO_ID)) |ic| {
        var buf: [96]u8 = undefined;
        const csw = sel.cpu_util_pct * 44;
        const info = std.fmt.bufPrint(&buf, "vCPUs: {d} | Sched: Preemptive 10ms | Cycles: {d}M | Ctx Sw: {d}/s", .{
            sel.vcpus,
            sel.cpu_cycles_m,
            csw,
        }) catch "";
        ic.setText(info);
    }

    // 5. Update Memory Commitment Progress Bar & Telemetry Text
    const ram_pct = if (sel.ram_mb > 0) (sel.ram_used_mb * 100) / sel.ram_mb else 0;
    if (gui.findIcon(WIN_GUEST_DETAILS_ID, ICON_GUEST_METER_RAM_ID)) |ic| {
        ic.setProgress(ram_pct);
        var buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "Guest RAM Committed: {d} MB / {d} MB ({d}%)", .{
            sel.ram_used_mb,
            sel.ram_mb,
            ram_pct,
        }) catch "";
        ic.setText(label);
    }
    if (gui.findIcon(WIN_GUEST_DETAILS_ID, ICON_GUEST_TEXT_RAM_INFO_ID)) |ic| {
        var buf: [96]u8 = undefined;
        const faults = if (sel.status == .running) @as(u32, 14) else 0;
        const info = std.fmt.bufPrint(&buf, "PMP Guard: Active (4 Regions) | Page Faults: {d}/s | Memory Isolation: Enforced", .{faults}) catch "";
        ic.setText(info);
    }

    // 6. Update Virtual Disk Allocation Progress Bar & Telemetry Text
    const disk_pct = if (sel.disk_total_mb > 0) (sel.disk_used_mb * 100) / sel.disk_total_mb else 0;
    if (gui.findIcon(WIN_GUEST_DETAILS_ID, ICON_GUEST_METER_DISK_ID)) |ic| {
        ic.setProgress(disk_pct);
        var buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "Virtual Disk Usage: {d} MB / {d} MB ({d}%)", .{
            sel.disk_used_mb,
            sel.disk_total_mb,
            disk_pct,
        }) catch "";
        ic.setText(label);
    }
    if (gui.findIcon(WIN_GUEST_DETAILS_ID, ICON_GUEST_TEXT_DISK_INFO_ID)) |ic| {
        var buf: [96]u8 = undefined;
        const r_int = sel.disk_read_mbs_x10 / 10;
        const r_frac = sel.disk_read_mbs_x10 % 10;
        const w_int = sel.disk_write_mbs_x10 / 10;
        const w_frac = sel.disk_write_mbs_x10 % 10;
        const info = std.fmt.bufPrint(&buf, "Disk I/O: {d}.{d} MB/s Read, {d}.{d} MB/s Write | IOPS: {d} | VirtIO-Blk", .{
            r_int,
            r_frac,
            w_int,
            w_frac,
            sel.disk_iops,
        }) catch "";
        ic.setText(info);
    }

    // 7. Update Virtual Network Progress Bar & Telemetry Text
    const net_pct: u32 = if (sel.status == .running) 24 else 0;
    if (gui.findIcon(WIN_GUEST_DETAILS_ID, ICON_GUEST_METER_NET_ID)) |ic| {
        ic.setProgress(net_pct);
        var buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "Virtual NIC Bandwidth: {d}.0 Mbps / 100 Mbps ({d}%)", .{ net_pct, net_pct }) catch "";
        ic.setText(label);
    }
    if (gui.findIcon(WIN_GUEST_DETAILS_ID, ICON_GUEST_TEXT_NET_INFO_ID)) |ic| {
        var buf: [96]u8 = undefined;
        const info = std.fmt.bufPrint(&buf, "VirtIO-Net TAP: tap0 | MAC: 52:54:00:12:34:0{d} | Traffic: {d} KB rx / {d} KB tx", .{
            sel.cid,
            sel.net_rx_kb,
            sel.net_tx_kb,
        }) catch "";
        ic.setText(info);
    }

    // 8. Update Inventory Row Buttons
    for (global_guests_data.guests) |g| {
        if (gui.findIcon(WIN_GUEST_LIST_ID, g.id)) |ic| {
            var buf: [64]u8 = undefined;
            const dmode = if (g.video_mode == .virtio_gpu) "GPU" else "TTY";
            const rlabel = std.fmt.bufPrint(&buf, "{s:<11} [CID {d}]  {d} vCPU {d:>4}M   {s:<3}   {s:<7}", .{
                g.getName(),
                g.cid,
                g.vcpus,
                g.ram_mb,
                dmode,
                g.status.asString(),
            }) catch "";
            ic.setText(rlabel);
        }
    }

    gui.markWindowDirty(WIN_GUEST_VIDEO_ID);
    gui.markWindowDirty(WIN_GUEST_DETAILS_ID);
    gui.markWindowDirty(WIN_GUEST_FULLSCREEN_VIDEO_ID);
}

fn updateDetailView(gui_ctx: *anyopaque) void {
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    if (gui.findIcon(WIN_GUEST_DETAILS_ID, ICON_GUEST_DETAIL_TEXT_ID)) |ic| {
        ic.setText(global_guests_data.detail_msg[0..global_guests_data.detail_len]);
        gui.markWindowDirty(WIN_GUEST_DETAILS_ID);
    }
}

