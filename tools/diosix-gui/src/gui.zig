// Monolithic Final Fantasy 7/8 Themed GUI Coordinator for Diosix
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("framebuffer.zig");
const font = @import("font.zig");
const cursor_mod = @import("cursor.zig");
const icon_mod = @import("icon.zig");
const Icon = icon_mod.Icon;
const window_mod = @import("window.zig");
const Window = window_mod.Window;
const sub_mod = @import("subprogram.zig");
const SubProgram = sub_mod.SubProgram;

const sys_sub = @import("subprograms/system_info.zig");
const icon_sub = @import("subprograms/icon_test.zig");
const guests_sub = @import("subprograms/guests.zig");
const storage_sub = @import("subprograms/storage.zig");
const power_sub = @import("subprograms/power.zig");

pub const TAB_BAR_HEIGHT: u32 = 42;
pub const TAB_START_X: i32 = 230;
pub const TAB_STRIDE: i32 = 204;
pub const TAB_WIDTH: u32 = 200;
pub const TAB_HEIGHT: u32 = 32;

pub const Key = struct {
    pub const BACKSPACE: u16 = 14;
    pub const TAB: u16 = 15;
    pub const U: u16 = 22;
    pub const ENTER: u16 = 28;
    pub const LEFT_CTRL: u16 = 29;
    pub const A: u16 = 30;
    pub const LEFT_SHIFT: u16 = 42;
    pub const Z: u16 = 44;
    pub const X: u16 = 45;
    pub const C: u16 = 46;
    pub const V: u16 = 47;
    pub const RIGHT_SHIFT: u16 = 54;
    pub const SPACE: u16 = 57;
    pub const F6: u16 = 64;
    pub const RIGHT_CTRL: u16 = 97;
    pub const UP: u16 = 103;
    pub const LEFT: u16 = 105;
    pub const RIGHT: u16 = 106;
    pub const DOWN: u16 = 108;
    pub const DELETE: u16 = 111;
};

pub const CLIPBOARD_CAPACITY: usize = 256;

pub const DiosixGui = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,

    windows: std.ArrayList(Window),
    subprograms: std.ArrayList(SubProgram),
    active_sub_idx: usize = 0,
    active_win_idx: ?usize = null,

    cursor: cursor_mod.Cursor,
    mouse_left_down: bool = false,

    // Keyboard modifier states tracked from input events
    ctrl_down: bool = false,
    shift_down: bool = false,

    // System clipboard for text copy / cut / paste (guaranteed null-terminated)
    clipboard_buf: [CLIPBOARD_CAPACITY + 1]u8 = @splat(0),
    clipboard_len: usize = 0,

    // Keyboard navigation focus
    focus_on_tab_bar: bool = false,

    // Real-time window transparency percentage (0 = fully opaque, 100 = invisible; default 50%)
    window_transparency: u32 = 50,

    // Real-time backdrop Gaussian blur strength (0 = no blur, 100 = max blur; default 50%)
    blur_strength: u32 = 50,

    // Static graduated background colors (default light blue top, dark blue bottom)
    bg_top_color: u32 = fb.Color.SKY_BASE_TOP,
    bg_bot_color: u32 = fb.Color.GRADIENT_BOT_DEFAULT,

    // Damage tracking: dirty bounding box needing redraw
    dirty_box: fb.Box = fb.Box{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 },

    // Scratch buffer for deterministic separable Gaussian blur passes
    blur_scratch: []u32,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !DiosixGui {
        const total_h = std.math.add(usize, height, 64) catch return error.InvalidDimensions;
        const scratch_len = std.math.mul(usize, width, total_h) catch return error.InvalidDimensions;
        const scratch_mem = try allocator.alloc(u32, scratch_len);

        var gui = DiosixGui{
            .allocator = allocator,
            .width = width,
            .height = height,
            .windows = .empty,
            .subprograms = .empty,
            .active_sub_idx = 0,
            .cursor = cursor_mod.Cursor{
                .x = @as(i32, @intCast(width / 2)),
                .y = @as(i32, @intCast(height / 2)),
            },
            .blur_scratch = scratch_mem,
        };

        // 1. Register all monolithic sub-programs
        try gui.subprograms.append(allocator, sys_sub.createSubProgram(allocator));
        try gui.subprograms.append(allocator, icon_sub.createSubProgram(allocator));
        try gui.subprograms.append(allocator, guests_sub.createSubProgram(allocator));
        try gui.subprograms.append(allocator, storage_sub.createSubProgram(allocator));
        try gui.subprograms.append(allocator, power_sub.createSubProgram(allocator));

        // 2. Build and populate all fixed-size window panes on startup
        try gui.buildSystemInfoWindows();
        try gui.buildIconTestWindows();
        try gui.buildGuestsWindows();
        try gui.buildStorageWindows();
        try gui.buildPowerWindows();

        // 3. Initialize all sub-programs
        for (gui.subprograms.items) |*sub| {
            sub.init_fn(sub, &gui);
        }

        // 4. Activate initial sub-program (System Info)
        gui.activateSubProgram(0);

        // Initial state is full-screen damage
        gui.markFullDirty();

        return gui;
    }

    pub fn deinit(self: *DiosixGui) void {
        for (self.windows.items) |*win| {
            win.deinit();
        }
        self.windows.deinit(self.allocator);

        for (self.subprograms.items) |*sub| {
            sub.deinit();
        }
        self.subprograms.deinit(self.allocator);

        self.allocator.free(self.blur_scratch);
    }

    // --- Window Builders ---

    fn buildSystemInfoWindows(self: *DiosixGui) !void {
        // Left Specs Window Pane
        var win_specs = Window.init(self.allocator, sys_sub.WIN_SPECS_ID, 24, 54, 780, 536, "SYSTEM SPECIFICATIONS & HYPERVISOR");
        _ = try win_specs.addIcon(Icon.createReadOnly(sys_sub.ICON_BADGE_ID, 24, 46, 732, 28, "[ PRIVILEGED DOMAIN 0 (ROOT VM) - FULL HYPERVISOR AUTHORITY ]"));
        _ = try win_specs.addIcon(Icon.createReadOnly(sys_sub.ICON_CID_ID, 24, 88, 732, 24, "Assigned Context ID : CID 1 (Platform Domain 0)"));
        _ = try win_specs.addIcon(Icon.createReadOnly(sys_sub.ICON_ARCH_ID, 24, 122, 732, 24, "Architecture        : RISC-V 64-bit (rv64gc / sv39x4 virt)"));
        _ = try win_specs.addIcon(Icon.createReadOnly(sys_sub.ICON_VCPUS_ID, 24, 156, 732, 24, "Online Virtual CPUs : 4 Cores (Hart 0 - 3 online)"));
        _ = try win_specs.addIcon(Icon.createReadOnly(sys_sub.ICON_RAM_ID, 24, 190, 732, 24, "Physical Memory     : 2048 MB Total / 128 MB Hypervisor Reserve"));
        _ = try win_specs.addIcon(Icon.createReadOnly(sys_sub.ICON_HV_ID, 24, 224, 732, 24, "Hypervisor Core     : Diosix Microkernel v0.2.0 (Type-1 Bare-Metal)"));
        _ = try win_specs.addIcon(Icon.createReadOnly(sys_sub.ICON_NET_ID, 24, 258, 732, 24, "Virtual Network     : diosix0 (10.0.3.1/24, Virtual Switch Active)"));
        _ = try win_specs.addIcon(Icon.createReadOnly(sys_sub.ICON_UPTIME_ID, 24, 292, 732, 24, "System Uptime       : Initializing telemetry..."));
        try self.windows.append(self.allocator, win_specs);

        // Right Actions Window Pane
        var win_actions = Window.init(self.allocator, sys_sub.WIN_ACTIONS_ID, 824, 54, 432, 536, "OPERATIONS");
        var btn_refresh = Icon.createButton(sys_sub.ICON_BTN_REFRESH_ID, 24, 54, 384, 36, "Refresh System Status");
        btn_refresh.callback = sys_sub.onRefreshClicked;
        _ = try win_actions.addIcon(btn_refresh);

        var btn_specs = Icon.createButton(sys_sub.ICON_BTN_SPECS_ID, 24, 106, 384, 36, "Hardware Capabilities");
        btn_specs.callback = sys_sub.onSpecsClicked;
        _ = try win_actions.addIcon(btn_specs);

        _ = try win_actions.addIcon(Icon.createReadOnly(sys_sub.ICON_LABEL_PLATFORM_CTRL_ID, 24, 168, 384, 24, "Host Platform Control:"));

        var btn_reboot = Icon.createButton(sys_sub.ICON_BTN_REBOOT_ID, 24, 204, 384, 36, "Reboot Host Platform");
        btn_reboot.callback = sys_sub.onRebootClicked;
        _ = try win_actions.addIcon(btn_reboot);

        var btn_poweroff = Icon.createButton(sys_sub.ICON_BTN_POWEROFF_ID, 24, 256, 384, 36, "Power Off Host Platform");
        btn_poweroff.callback = sys_sub.onPowerOffClicked;
        _ = try win_actions.addIcon(btn_poweroff);
        try self.windows.append(self.allocator, win_actions);

        // Bottom Log Window Pane
        var win_log = Window.init(self.allocator, sys_sub.WIN_LOG_ID, 24, 608, 1232, 172, "DIOSIX SYSTEM LOG & STATUS");
        _ = try win_log.addIcon(Icon.createReadOnly(sys_sub.ICON_LOG_TEXT_ID, 24, 54, 1184, 28, "Privileged Domain 0: Full host hypervisor authority active across /dev/diosix."));
        try self.windows.append(self.allocator, win_log);
    }

    fn buildIconTestWindows(self: *DiosixGui) !void {
        // Left Showcase Pane: Read-only, Read-write, Sliders, Tick box
        var win_ctrls = Window.init(self.allocator, icon_sub.WIN_CONTROLS_ID, 24, 54, 600, 536, "INTERACTIVE CONTROLS SHOWCASE");
        _ = try win_ctrls.addIcon(Icon.createReadOnly(icon_sub.ICON_RO_LABEL1_ID, 24, 40, 552, 18, "1. Read-Only Telemetry Display:"));
        _ = try win_ctrls.addIcon(Icon.createReadOnly(icon_sub.ICON_RO_TEXT_ID, 24, 60, 552, 24, "Live Core Telemetry: 0 ticks (OK)"));

        _ = try win_ctrls.addIcon(Icon.createReadOnly(icon_sub.ICON_RO_LABEL2_ID, 24, 94, 552, 18, "2. Read-Write Editable Text Field:"));
        var rw_text = Icon.createReadWrite(icon_sub.ICON_RW_TEXT_ID, 24, 114, 552, 34, "Diosix RISC-V Hypervisor");
        rw_text.callback = icon_sub.onReadWriteTextChanged;
        _ = try win_ctrls.addIcon(rw_text);

        _ = try win_ctrls.addIcon(Icon.createReadOnly(icon_sub.ICON_RO_LABEL3_ID, 24, 158, 552, 18, "3. Real-Time Window Transparency Slider:"));
        var sl_trans = Icon.createSlider(icon_sub.ICON_SLIDER_TRANSPARENCY_ID, 24, 178, 552, 46, 0, 90, 50, "%");
        sl_trans.setText("Window Transparency (Glass Opacity)");
        sl_trans.callback = icon_sub.onTransparencySliderChanged;
        _ = try win_ctrls.addIcon(sl_trans);

        _ = try win_ctrls.addIcon(Icon.createReadOnly(icon_sub.ICON_RO_LABEL4_ID, 24, 234, 552, 18, "4. Backdrop Gaussian Blur Strength Slider:"));
        var sl_blur = Icon.createSlider(icon_sub.ICON_SLIDER_BLUR_ID, 24, 254, 552, 46, 0, 100, 50, "%");
        sl_blur.setText("Backdrop Gaussian Blur (Frosted Glass)");
        sl_blur.callback = icon_sub.onBlurSliderChanged;
        _ = try win_ctrls.addIcon(sl_blur);

        _ = try win_ctrls.addIcon(Icon.createReadOnly(icon_sub.ICON_RO_LABEL5_ID, 24, 310, 552, 18, "5. Scalar Slider (Interactive Drag & Keys):"));
        var sl_vcpu = Icon.createSlider(icon_sub.ICON_SLIDER_VCPU_ID, 24, 330, 552, 46, 0, 100, 75, "%");
        sl_vcpu.setText("VCPU Quota Allocation");
        sl_vcpu.callback = icon_sub.onVcpuSliderChanged;
        _ = try win_ctrls.addIcon(sl_vcpu);

        _ = try win_ctrls.addIcon(Icon.createReadOnly(icon_sub.ICON_RO_LABEL6_ID, 24, 386, 552, 18, "6. Independent Tick Box:"));
        var tick_log = Icon.createTickBox(icon_sub.ICON_TICK_LOGGING_ID, 24, 406, 552, 28, "Enable Verbose Real-Time Telemetry", true, null, .inclusive);
        tick_log.callback = icon_sub.onLoggingToggled;
        _ = try win_ctrls.addIcon(tick_log);
        try self.windows.append(self.allocator, win_ctrls);

        // Right Groups Pane: Backdrop Color Selection
        var win_groups = Window.init(self.allocator, icon_sub.WIN_GROUPS_ID, 644, 54, 612, 536, "BACKDROP GRADIENT COLOR SELECTION");
        _ = try win_groups.addIcon(Icon.createReadOnly(icon_sub.ICON_RO_TOP_LABEL_ID, 24, 44, 564, 20, "Top Backdrop Color (Graduated Shading Top):"));

        var rad_top1 = Icon.createTickBox(icon_sub.ICON_TOP_LIGHT_BLUE_ID, 24, 74, 564, 28, "Light Blue (Default #4C8BE0)", true, 1, .exclusive);
        rad_top1.callback = icon_sub.onTopColorSelected;
        _ = try win_groups.addIcon(rad_top1);

        var rad_top2 = Icon.createTickBox(icon_sub.ICON_TOP_CYAN_ID, 24, 110, 564, 28, "Sky Cyan (#2EB8D8)", false, 1, .exclusive);
        rad_top2.callback = icon_sub.onTopColorSelected;
        _ = try win_groups.addIcon(rad_top2);

        var rad_top3 = Icon.createTickBox(icon_sub.ICON_TOP_AMBER_ID, 24, 146, 564, 28, "Sunset Amber (#C86840)", false, 1, .exclusive);
        rad_top3.callback = icon_sub.onTopColorSelected;
        _ = try win_groups.addIcon(rad_top3);

        var rad_top4 = Icon.createTickBox(icon_sub.ICON_TOP_SLATE_ID, 24, 182, 564, 28, "Slate Frost (#607890)", false, 1, .exclusive);
        rad_top4.callback = icon_sub.onTopColorSelected;
        _ = try win_groups.addIcon(rad_top4);

        _ = try win_groups.addIcon(Icon.createReadOnly(icon_sub.ICON_RO_BOT_LABEL_ID, 24, 230, 564, 20, "Bottom Backdrop Color (Graduated Shading Bottom):"));

        var rad_bot1 = Icon.createTickBox(icon_sub.ICON_BOT_DARK_BLUE_ID, 24, 260, 564, 28, "Dark Blue (Default #0C1836)", true, 2, .exclusive);
        rad_bot1.callback = icon_sub.onBotColorSelected;
        _ = try win_groups.addIcon(rad_bot1);

        var rad_bot2 = Icon.createTickBox(icon_sub.ICON_BOT_NAVY_ID, 24, 296, 564, 28, "Midnight Navy (#060B18)", false, 2, .exclusive);
        rad_bot2.callback = icon_sub.onBotColorSelected;
        _ = try win_groups.addIcon(rad_bot2);

        var rad_bot3 = Icon.createTickBox(icon_sub.ICON_BOT_INDIGO_ID, 24, 332, 564, 28, "Deep Indigo (#180828)", false, 2, .exclusive);
        rad_bot3.callback = icon_sub.onBotColorSelected;
        _ = try win_groups.addIcon(rad_bot3);

        var rad_bot4 = Icon.createTickBox(icon_sub.ICON_BOT_PITCH_ID, 24, 368, 564, 28, "Pitch Black (#000206)", false, 2, .exclusive);
        rad_bot4.callback = icon_sub.onBotColorSelected;
        _ = try win_groups.addIcon(rad_bot4);

        try self.windows.append(self.allocator, win_groups);

        // Bottom Inspector Pane
        var win_insp = Window.init(self.allocator, icon_sub.WIN_INSPECTOR_ID, 24, 608, 1232, 172, "LIVE CALLBACK INSPECTOR");
        _ = try win_insp.addIcon(Icon.createReadOnly(icon_sub.ICON_INSPECTOR_TEXT_ID, 24, 54, 1184, 28, "Interactive Showcase: Drag the transparency slider or select backdrop colors to test callbacks."));
        try self.windows.append(self.allocator, win_insp);
    }

    fn buildGuestsWindows(self: *DiosixGui) !void {
        var win_list = Window.init(self.allocator, guests_sub.WIN_GUEST_LIST_ID, 24, 54, 780, 536, "GUEST DOMAIN INVENTORY");
        var row1 = Icon.createButton(guests_sub.ICON_GUEST_ROW1_ID, 24, 54, 732, 38, "second-vm   [CID 2, 2 vCPUs, 256 MB RAM, IP: 10.0.3.2, Status: RUNNING]");
        row1.callback = guests_sub.onGuestRowClicked;
        _ = try win_list.addIcon(row1);

        var row2 = Icon.createButton(guests_sub.ICON_GUEST_ROW2_ID, 24, 104, 732, 38, "debian-vm   [CID 3, 2 vCPUs, 1024 MB RAM, Disk: debian.img, Status: STOPPED]");
        row2.callback = guests_sub.onGuestRowClicked;
        _ = try win_list.addIcon(row2);

        var row3 = Icon.createButton(guests_sub.ICON_GUEST_ROW3_ID, 24, 154, 732, 38, "micro-guest [CID 4, 1 vCPU,  64 MB RAM, Payload: Minimal, Status: STOPPED]");
        row3.callback = guests_sub.onGuestRowClicked;
        _ = try win_list.addIcon(row3);
        try self.windows.append(self.allocator, win_list);

        var win_actions = Window.init(self.allocator, guests_sub.WIN_GUEST_ACTIONS_ID, 824, 54, 432, 536, "DOMAIN ACTIONS");
        var btn_launch = Icon.createButton(guests_sub.ICON_GUEST_ACTION_LAUNCH_ID, 24, 54, 384, 36, "Start Selected Domain");
        btn_launch.callback = guests_sub.onLaunchGuestClicked;
        _ = try win_actions.addIcon(btn_launch);

        var btn_stop = Icon.createButton(guests_sub.ICON_GUEST_ACTION_STOP_ID, 24, 106, 384, 36, "Terminate Selected Domain");
        btn_stop.callback = guests_sub.onStopGuestClicked;
        _ = try win_actions.addIcon(btn_stop);

        var btn_ssh = Icon.createButton(guests_sub.ICON_GUEST_ACTION_SSH_ID, 24, 158, 384, 36, "Open Virtual SSH Console");
        btn_ssh.callback = guests_sub.onSshGuestClicked;
        _ = try win_actions.addIcon(btn_ssh);
        try self.windows.append(self.allocator, win_actions);

        var win_details = Window.init(self.allocator, guests_sub.WIN_GUEST_DETAILS_ID, 24, 608, 1232, 172, "DOMAIN STATUS DETAILS");
        _ = try win_details.addIcon(Icon.createReadOnly(guests_sub.ICON_GUEST_DETAIL_TEXT_ID, 24, 54, 1184, 28, "Select a virtual machine from the inventory list above to perform domain operations."));
        try self.windows.append(self.allocator, win_details);
    }

    fn buildStorageWindows(self: *DiosixGui) !void {
        var win_list = Window.init(self.allocator, storage_sub.WIN_STORAGE_LIST_ID, 24, 54, 780, 536, "VIRTUAL DISK DATASTORE");
        var d1 = Icon.createButton(storage_sub.ICON_DISK_ITEM1_ID, 24, 54, 732, 38, "debian.img       [Size: 4096 MB, Type: ext4, Attached: debian-vm]");
        d1.callback = storage_sub.onDiskItemClicked;
        _ = try win_list.addIcon(d1);

        var d2 = Icon.createButton(storage_sub.ICON_DISK_ITEM2_ID, 24, 104, 732, 38, "second-vm.img    [Size: 512 MB,  Type: ext4, Attached: second-vm]");
        d2.callback = storage_sub.onDiskItemClicked;
        _ = try win_list.addIcon(d2);

        var d3 = Icon.createButton(storage_sub.ICON_DISK_ITEM3_ID, 24, 154, 732, 38, "scratch-data.img [Size: 1024 MB, Type: ext4, Unattached]");
        d3.callback = storage_sub.onDiskItemClicked;
        _ = try win_list.addIcon(d3);
        try self.windows.append(self.allocator, win_list);

        var win_actions = Window.init(self.allocator, storage_sub.WIN_STORAGE_ACTIONS_ID, 824, 54, 432, 536, "STORAGE OPERATIONS");
        var btn_c = Icon.createButton(storage_sub.ICON_DISK_CREATE_ID, 24, 54, 384, 36, "Create Virtual Disk");
        btn_c.callback = storage_sub.onCreateDiskClicked;
        _ = try win_actions.addIcon(btn_c);

        var btn_r = Icon.createButton(storage_sub.ICON_DISK_RESIZE_ID, 24, 106, 384, 36, "Resize Virtual Disk");
        btn_r.callback = storage_sub.onResizeDiskClicked;
        _ = try win_actions.addIcon(btn_r);

        var btn_d = Icon.createButton(storage_sub.ICON_DISK_DELETE_ID, 24, 158, 384, 36, "Delete Virtual Disk");
        btn_d.callback = storage_sub.onDeleteDiskClicked;
        _ = try win_actions.addIcon(btn_d);
        try self.windows.append(self.allocator, win_actions);

        var win_details = Window.init(self.allocator, storage_sub.WIN_STORAGE_DETAILS_ID, 24, 608, 1232, 172, "DATASTORE STATUS");
        _ = try win_details.addIcon(Icon.createReadOnly(storage_sub.ICON_STORAGE_DETAIL_ID, 24, 54, 1184, 28, "Datastore mounted at /var/lib/diosix/disks. Select an image for disk geometry and usage."));
        try self.windows.append(self.allocator, win_details);
    }

    fn buildPowerWindows(self: *DiosixGui) !void {
        var win_menu = Window.init(self.allocator, power_sub.WIN_POWER_MENU_ID, 24, 54, 600, 536, "PLATFORM POWER MANAGEMENT");
        var btn_reb = Icon.createButton(power_sub.ICON_PWR_REBOOT_ID, 24, 54, 552, 42, "[ Reboot Host Hardware Platform ]");
        btn_reb.callback = power_sub.onPowerReboot;
        _ = try win_menu.addIcon(btn_reb);

        var btn_shut = Icon.createButton(power_sub.ICON_PWR_SHUTDOWN_ID, 24, 116, 552, 42, "[ Power Off Host Hardware Platform ]");
        btn_shut.callback = power_sub.onPowerShutdown;
        _ = try win_menu.addIcon(btn_shut);

        var btn_susp = Icon.createButton(power_sub.ICON_PWR_SUSPEND_ID, 24, 178, 552, 42, "[ Low-Power ACPI / PSCI Standby ]");
        btn_susp.callback = power_sub.onPowerSuspend;
        _ = try win_menu.addIcon(btn_susp);
        try self.windows.append(self.allocator, win_menu);

        var win_status = Window.init(self.allocator, power_sub.WIN_POWER_STATUS_ID, 644, 54, 612, 536, "POWER SECURITY POLICY");
        _ = try win_status.addIcon(Icon.createReadOnly(power_sub.ICON_PWR_STATUS_TEXT_ID, 24, 54, 564, 48, "Platform control commands require Root VM Domain 0 privileges."));
        try self.windows.append(self.allocator, win_status);
    }

    // --- Sub-Program Tab Switching & Preemptive Multitasking ---

    pub fn activateSubProgram(self: *DiosixGui, idx: usize) void {
        if (idx >= self.subprograms.items.len) return;

        self.markFullDirty();

        // Deactivate previous subprogram
        if (self.active_sub_idx < self.subprograms.items.len) {
            const old = &self.subprograms.items[self.active_sub_idx];
            old.on_deactivate_fn(old, self);
        }

        self.active_sub_idx = idx;
        const new_sub = &self.subprograms.items[idx];
        new_sub.on_activate_fn(new_sub, self);

        // Select first active window with interactive icons in view
        self.active_win_idx = null;
        var first_interactive: ?usize = null;
        var first_onscreen: ?usize = null;

        for (self.windows.items, 0..) |*win, w_idx| {
            if (win.is_onscreen) {
                if (first_onscreen == null) first_onscreen = w_idx;
                if (first_interactive == null and win.hasInteractiveIcons()) {
                    first_interactive = w_idx;
                }
                win.is_active = false;
            }
        }

        const target_win_idx = first_interactive orelse first_onscreen;
        if (target_win_idx) |t_idx| {
            self.focusWindow(t_idx);
            const win = &self.windows.items[t_idx];
            if (win.focused_icon_idx == null) {
                _ = win.focusFirstInteractiveIcon();
            }
        }
        self.markFullDirty();
    }

    pub fn nextTab(self: *DiosixGui) void {
        const next_idx = (self.active_sub_idx + 1) % self.subprograms.items.len;
        self.activateSubProgram(next_idx);
    }

    pub fn prevTab(self: *DiosixGui) void {
        const prev_idx = (self.active_sub_idx + self.subprograms.items.len - 1) % self.subprograms.items.len;
        self.activateSubProgram(prev_idx);
    }

    // Preemptive Multitasking Loop: called every frame
    // Preemptively runs tick on ALL subprograms giving each CPU time regardless of view!
    pub fn tick(self: *DiosixGui, dt_ms: u32) void {
        for (self.subprograms.items, 0..) |*sub, idx| {
            const is_active = (idx == self.active_sub_idx);
            sub.tick_fn(sub, self, dt_ms, is_active);
        }
    }

    // --- Damage Tracking ---

    pub fn markDirty(self: *DiosixGui, box: fb.Box) void {
        self.dirty_box = self.dirty_box.merge(box);
    }

    pub fn markFullDirty(self: *DiosixGui) void {
        self.dirty_box = fb.Box.fromPosSize(0, 0, self.width, self.height);
    }

    pub fn markWindowDirty(self: *DiosixGui, win_id: u32) void {
        for (self.windows.items) |*win| {
            if (win.id == win_id and win.is_onscreen) {
                self.markDirty(win.getBox());
                break;
            }
        }
    }

    pub fn isDirty(self: *const DiosixGui) bool {
        return !self.dirty_box.isEmpty();
    }

    // --- Window and Icon Queries ---

    pub fn setWindowOnScreen(self: *DiosixGui, win_id: u32, on: bool) void {
        for (self.windows.items) |*win| {
            if (win.id == win_id) {
                const was_on = win.is_onscreen;
                win.setOnScreen(on);
                if (was_on != on) {
                    self.markDirty(fb.Box.fromPosSize(win.onscreen_x, win.onscreen_y, win.width, win.height));
                }
                break;
            }
        }
    }

    pub fn findIcon(self: *DiosixGui, win_id: u32, icon_id: u32) ?*Icon {
        for (self.windows.items) |*win| {
            if (win.id == win_id) {
                if (win.is_onscreen) {
                    self.markDirty(win.getBox());
                }
                return win.getIconById(icon_id);
            }
        }
        return null;
    }

    pub fn setWindowTransparency(self: *DiosixGui, pct: u32) void {
        const clamped = std.math.clamp(pct, 0, 100);
        if (self.window_transparency != clamped) {
            self.window_transparency = clamped;
            self.markFullDirty();
        }
    }

    pub fn getWindowOpacityAlpha(self: *const DiosixGui) u8 {
        const opacity_pct: u32 = if (self.window_transparency >= 100) 0 else (100 - self.window_transparency);
        return @intCast((opacity_pct * 255) / 100);
    }

    pub fn setBlurStrength(self: *DiosixGui, pct: u32) void {
        const clamped = std.math.clamp(pct, 0, 100);
        if (self.blur_strength != clamped) {
            self.blur_strength = clamped;
            self.markFullDirty();
        }
    }

    pub fn getBlurStrength(self: *const DiosixGui) u32 {
        return self.blur_strength;
    }

    pub fn getBlurRadius(self: *const DiosixGui) u32 {
        return @divTrunc(self.blur_strength * 10, 100);
    }

    pub fn setBackdropTopColor(self: *DiosixGui, col: u32) void {
        if (self.bg_top_color != col) {
            self.bg_top_color = col;
            self.markFullDirty();
        }
    }

    pub fn setBackdropBotColor(self: *DiosixGui, col: u32) void {
        if (self.bg_bot_color != col) {
            self.bg_bot_color = col;
            self.markFullDirty();
        }
    }

    pub fn setClipboard(self: *DiosixGui, text: []const u8) void {
        var safe_len = @min(text.len, CLIPBOARD_CAPACITY);
        if (safe_len < text.len) {
            // String was truncated. Ensure we do not truncate in the middle of a multi-byte UTF-8 sequence.
            var i = safe_len;
            while (i > 0 and (text[i - 1] & 0xC0) == 0x80) {
                i -= 1;
            }
            if (i > 0 and text[i - 1] >= 0x80) {
                const lead = text[i - 1];
                const expected_len: usize = if ((lead & 0xE0) == 0xC0)
                    2
                else if ((lead & 0xF0) == 0xE0)
                    3
                else if ((lead & 0xF8) == 0xF0)
                    4
                else
                    1;
                if (safe_len - (i - 1) < expected_len) {
                    safe_len = i - 1;
                }
            }
        }
        @memcpy(self.clipboard_buf[0..safe_len], text[0..safe_len]);
        self.clipboard_buf[safe_len] = 0;
        self.clipboard_len = safe_len;
    }

    pub fn getClipboard(self: *const DiosixGui) []const u8 {
        const safe_len = @min(self.clipboard_len, CLIPBOARD_CAPACITY);
        return self.clipboard_buf[0..safe_len];
    }

    // --- Input Dispatch ---

    pub fn handleMouseRelease(self: *DiosixGui) void {
        self.mouse_left_down = false;
        for (self.windows.items) |*win| {
            if (win.is_onscreen) {
                const changed = win.handleMouseRelease();
                if (changed) {
                    self.markDirty(win.getBox());
                }
            }
        }
    }

    pub fn handleMouseMove(self: *DiosixGui, px: i32, py: i32, left_down: bool) void {
        self.cursor.x = px;
        self.cursor.y = py;
        self.mouse_left_down = left_down;

        // Route mouse move to on-screen windows
        for (self.windows.items) |*win| {
            if (win.is_onscreen) {
                const changed = win.handleMouseMove(self, px, py, left_down);
                if (changed) {
                    self.markDirty(win.getBox());
                }
            }
        }
    }

    pub fn handleMouseClick(self: *DiosixGui, px: i32, py: i32) void {
        // 1. Check if click is on top tab bar
        if (py < @as(i32, @intCast(TAB_BAR_HEIGHT))) {
            self.handleTabBarClick(px, py);
            return;
        }

        // 2. Check if click is on an on-screen window
        var i = self.windows.items.len;
        while (i > 0) : (i -= 1) {
            const win = &self.windows.items[i - 1];
            if (win.is_onscreen and win.contains(px, py)) {
                // Focus this window
                self.focusWindow(i - 1);
                _ = win.handleMouseClick(self, px, py);
                self.markDirty(win.getBox());
                break;
            }
        }
    }

    fn handleTabBarClick(self: *DiosixGui, px: i32, py: i32) void {
        _ = py;
        if (px >= TAB_START_X) {
            const rel_x = px - TAB_START_X;
            const clicked_tab = @divTrunc(rel_x, TAB_STRIDE);
            const in_tab_x = @mod(rel_x, TAB_STRIDE);
            if (clicked_tab >= 0 and clicked_tab < self.subprograms.items.len and in_tab_x < @as(i32, @intCast(TAB_WIDTH))) {
                self.activateSubProgram(@intCast(clicked_tab));
            }
        }
    }

    pub fn focusWindow(self: *DiosixGui, target_idx: usize) void {
        if (self.active_win_idx) |old_idx| {
            if (old_idx < self.windows.items.len) {
                const old_win = &self.windows.items[old_idx];
                old_win.is_active = false;
                if (old_win.is_onscreen) self.markDirty(old_win.getBox());
            }
        }
        for (self.windows.items, 0..) |*win, idx| {
            win.is_active = (idx == target_idx);
            if (idx == target_idx and win.is_onscreen) {
                self.markDirty(win.getBox());
            }
        }
        self.active_win_idx = target_idx;
    }

    // Focus next on-screen window pane that has interactive icons, preserving icon focus
    pub fn focusNextPane(self: *DiosixGui) void {
        const total = self.windows.items.len;
        if (total == 0) return;
        const cur_idx = self.active_win_idx orelse 0;

        var i: usize = 1;
        while (i <= total) : (i += 1) {
            const check = (cur_idx + i) % total;
            const win = &self.windows.items[check];
            if (win.is_onscreen and win.hasInteractiveIcons()) {
                self.focusWindow(check);
                if (win.focused_icon_idx == null) {
                    _ = win.focusFirstInteractiveIcon();
                }
                self.markDirty(win.getBox());
                return;
            }
        }
    }

    // Focus previous on-screen window pane that has interactive icons, preserving icon focus
    pub fn focusPrevPane(self: *DiosixGui) void {
        const total = self.windows.items.len;
        if (total == 0) return;
        const cur_idx = self.active_win_idx orelse 0;

        var i: usize = 1;
        while (i <= total) : (i += 1) {
            const check = (cur_idx + total * total - i) % total;
            const win = &self.windows.items[check];
            if (win.is_onscreen and win.hasInteractiveIcons()) {
                self.focusWindow(check);
                if (win.focused_icon_idx == null) {
                    _ = win.focusLastInteractiveIcon();
                }
                self.markDirty(win.getBox());
                return;
            }
        }
    }

    // Focus next pane and select its first interactive icon (used for Tab overflow)
    pub fn focusNextPaneFirst(self: *DiosixGui) void {
        const total = self.windows.items.len;
        if (total == 0) return;
        const cur_idx = self.active_win_idx orelse 0;

        var i: usize = 1;
        while (i <= total) : (i += 1) {
            const check = (cur_idx + i) % total;
            const win = &self.windows.items[check];
            if (win.is_onscreen and win.hasInteractiveIcons()) {
                self.focusWindow(check);
                _ = win.focusFirstInteractiveIcon();
                self.markDirty(win.getBox());
                return;
            }
        }
        if (self.getActiveWindow()) |cur_win| {
            _ = cur_win.focusFirstInteractiveIcon();
            self.markDirty(cur_win.getBox());
        }
    }

    // Focus previous pane and select its last interactive icon (used for Shift-Tab underflow)
    pub fn focusPrevPaneLast(self: *DiosixGui) void {
        const total = self.windows.items.len;
        if (total == 0) return;
        const cur_idx = self.active_win_idx orelse 0;

        var i: usize = 1;
        while (i <= total) : (i += 1) {
            const check = (cur_idx + total * total - i) % total;
            const win = &self.windows.items[check];
            if (win.is_onscreen and win.hasInteractiveIcons()) {
                self.focusWindow(check);
                _ = win.focusLastInteractiveIcon();
                self.markDirty(win.getBox());
                return;
            }
        }
        if (self.getActiveWindow()) |cur_win| {
            _ = cur_win.focusLastInteractiveIcon();
            self.markDirty(cur_win.getBox());
        }
    }

    pub fn focusNextWindow(self: *DiosixGui) void {
        self.focusNextPane();
    }

    pub fn handleKey(self: *DiosixGui, key_code: u16, key_char: ?u8, pressed: bool) void {
        self.handleKeyWithModifiers(key_code, key_char, pressed, self.ctrl_down, self.shift_down);
    }

    pub fn handleKeyWithModifiers(self: *DiosixGui, key_code: u16, key_char: ?u8, pressed: bool, ctrl: bool, shift: bool) void {
        if (!pressed) {
            if (key_code == Key.ENTER or key_code == Key.SPACE) {
                if (self.getActiveWindow()) |win| {
                    if (win.focused_icon_idx) |idx| {
                        if (idx < win.icons.items.len) {
                            const icon = &win.icons.items[idx];
                            if (icon.is_active_press) {
                                icon.is_active_press = false;
                                self.markDirty(win.getBox());
                            }
                        }
                    }
                }
            }
            return;
        }

        const active_win = self.getActiveWindow();
        const focused_icon: ?*Icon = if (active_win) |win|
            if (win.focused_icon_idx) |idx|
                if (idx < win.icons.items.len) &win.icons.items[idx] else null
            else
                null
        else
            null;
        const is_in_text_field = if (focused_icon) |ic| (ic.icon_type == .read_write_text) else false;

        // 1. Number keys '1'..'5' quick switch subprograms ONLY if not typing in a text field and Ctrl is not held
        if (!is_in_text_field and !ctrl) {
            if (key_char) |c| {
                if (c >= '1' and c <= '5') {
                    const sub_idx: usize = @intCast(c - '1');
                    if (sub_idx < self.subprograms.items.len) {
                        self.activateSubProgram(sub_idx);
                        return;
                    }
                }
            }
        }

        // 2. Direct Pane Navigation via F6 / Shift-F6
        if (key_code == Key.F6) {
            if (shift) {
                self.focusPrevPane();
            } else {
                self.focusNextPane();
            }
            return;
        }

        // 3. Tab Navigation: moves focus to next/prev item; transitions across panes on boundary
        // Ctrl-Tab switches directly between panes
        if (key_code == Key.TAB) {
            if (ctrl) {
                if (shift) {
                    self.focusPrevPane();
                } else {
                    self.focusNextPane();
                }
                return;
            }
            if (active_win) |win| {
                if (shift) {
                    if (!win.focusPrevIcon()) {
                        self.focusPrevPaneLast();
                    }
                } else {
                    if (!win.focusNextIcon()) {
                        self.focusNextPaneFirst();
                    }
                }
                self.markDirty(win.getBox());
                return;
            } else {
                self.focusNextPaneFirst();
                return;
            }
        }

        // 4. Control Codes recognition (both keycode+ctrl and raw ASCII control bytes)
        const is_ctrl_a = (ctrl and (key_code == Key.A or key_char == 'a' or key_char == 'A')) or (key_char != null and key_char.? == 1);
        const is_ctrl_c = (ctrl and (key_code == Key.C or key_char == 'c' or key_char == 'C')) or (key_char != null and key_char.? == 3);
        const is_ctrl_v = (ctrl and (key_code == Key.V or key_char == 'v' or key_char == 'V')) or (key_char != null and key_char.? == 22);
        const is_ctrl_x = (ctrl and (key_code == Key.X or key_char == 'x' or key_char == 'X')) or (key_char != null and key_char.? == 24);
        const is_ctrl_u = (ctrl and (key_code == Key.U or key_char == 'u' or key_char == 'U')) or (key_char != null and key_char.? == 21);

        // 5. If focused on a read_write_text icon, handle text field actions
        if (is_in_text_field) {
            const icon = focused_icon.?;
            const win = active_win.?;

            if (is_ctrl_a) {
                // Control-A: Select all
                icon.selectAll();
                self.markDirty(win.getBox());
                return;
            } else if (is_ctrl_c) {
                // Control-C: Copy selected text
                if (icon.hasSelection()) {
                    self.setClipboard(icon.getSelectedText());
                }
                return;
            } else if (is_ctrl_x) {
                // Control-X: Cut selected text
                if (icon.hasSelection()) {
                    self.setClipboard(icon.getSelectedText());
                    _ = icon.deleteSelection();
                    if (icon.callback) |cb| cb(self, @ptrCast(win), icon);
                    self.markDirty(win.getBox());
                }
                return;
            } else if (is_ctrl_v) {
                // Control-V: Paste
                const clip = self.getClipboard();
                if (clip.len > 0) {
                    _ = icon.deleteSelection();
                    icon.insertString(clip);
                    if (icon.callback) |cb| cb(self, @ptrCast(win), icon);
                    self.markDirty(win.getBox());
                }
                return;
            } else if (is_ctrl_u) {
                // Control-U: Clear the whole field
                icon.clearField();
                if (icon.callback) |cb| cb(self, @ptrCast(win), icon);
                self.markDirty(win.getBox());
                return;
            }

            // If Ctrl is held but unhandled, do not type printable characters
            if (ctrl) return;

            // Arrow keys in writable text field
            if (key_code == Key.LEFT) {
                if (shift) {
                    if (icon.selection_start == null) {
                        icon.selection_start = icon.cursor_pos;
                    }
                    if (icon.cursor_pos > 0) {
                        icon.cursor_pos -= 1;
                    }
                    icon.selection_end = icon.cursor_pos;
                } else {
                    if (icon.getSelectionBounds()) |b| {
                        icon.cursor_pos = b.min;
                        icon.clearSelection();
                    } else if (icon.cursor_pos > 0) {
                        icon.cursor_pos -= 1;
                    }
                }
                self.markDirty(win.getBox());
                return;
            } else if (key_code == Key.RIGHT) {
                if (shift) {
                    if (icon.selection_start == null) {
                        icon.selection_start = icon.cursor_pos;
                    }
                    if (icon.cursor_pos < icon.text_len) {
                        icon.cursor_pos += 1;
                    }
                    icon.selection_end = icon.cursor_pos;
                } else {
                    if (icon.getSelectionBounds()) |b| {
                        icon.cursor_pos = b.max;
                        icon.clearSelection();
                    } else if (icon.cursor_pos < icon.text_len) {
                        icon.cursor_pos += 1;
                    }
                }
                self.markDirty(win.getBox());
                return;
            } else if (key_code == Key.UP) {
                // Up arrow moves to previous item
                if (!win.focusPrevIcon()) {
                    self.focusPrevPaneLast();
                }
                self.markDirty(win.getBox());
                return;
            } else if (key_code == Key.DOWN) {
                // Down arrow moves to next item
                if (!win.focusNextIcon()) {
                    self.focusNextPaneFirst();
                }
                self.markDirty(win.getBox());
                return;
            }

            // Backspace and Delete
            if (key_code == Key.BACKSPACE) {
                if (icon.hasSelection()) {
                    _ = icon.deleteSelection();
                } else {
                    icon.deleteBackward();
                }
                if (icon.callback) |cb| cb(self, @ptrCast(win), icon);
                self.markDirty(win.getBox());
                return;
            } else if (key_code == Key.DELETE) {
                if (icon.hasSelection()) {
                    _ = icon.deleteSelection();
                } else {
                    icon.deleteForward();
                }
                if (icon.callback) |cb| cb(self, @ptrCast(win), icon);
                self.markDirty(win.getBox());
                return;
            }

            // Regular character typing
            if (key_char) |c| {
                if (c >= 32 and c <= 126) {
                    if (icon.hasSelection()) {
                        _ = icon.deleteSelection();
                    }
                    icon.insertChar(c);
                    if (icon.callback) |cb| cb(self, @ptrCast(win), icon);
                    self.markDirty(win.getBox());
                    return;
                }
            }
        }

        // 6. Non-text field handling (Sliders, Action Buttons, Checkboxes, Pane Navigation)
        if (active_win) |win| {
            if (focused_icon) |icon| {
                if (icon.icon_type == .slider) {
                    if (key_code == Key.LEFT) {
                        icon.adjustSlider(-5);
                        if (icon.callback) |cb| cb(self, @ptrCast(win), icon);
                        self.markDirty(win.getBox());
                        return;
                    } else if (key_code == Key.RIGHT) {
                        icon.adjustSlider(5);
                        if (icon.callback) |cb| cb(self, @ptrCast(win), icon);
                        self.markDirty(win.getBox());
                        return;
                    } else if (key_code == Key.UP) {
                        win.focusPrevIconWrap();
                        self.markDirty(win.getBox());
                        return;
                    } else if (key_code == Key.DOWN) {
                        win.focusNextIconWrap();
                        self.markDirty(win.getBox());
                        return;
                    }
                }
            }

            // Up / Down arrow navigates vertically within the pane (wrapping around)
            if (key_code == Key.UP) {
                win.focusPrevIconWrap();
                self.markDirty(win.getBox());
                return;
            } else if (key_code == Key.DOWN) {
                win.focusNextIconWrap();
                self.markDirty(win.getBox());
                return;
            }

            // Left / Right arrow moves keyboard focus between panes
            if (key_code == Key.RIGHT) {
                self.focusNextPane();
                return;
            } else if (key_code == Key.LEFT) {
                self.focusPrevPane();
                return;
            }

            // Enter or Space activates the focused action button or toggles tickbox
            if (key_code == Key.ENTER or key_code == Key.SPACE) {
                if (win.focused_icon_idx) |f_idx| {
                    if (f_idx < win.icons.items.len) {
                        win.triggerIcon(self, &win.icons.items[f_idx]);
                        self.markDirty(win.getBox());
                    }
                }
                return;
            }
        }
    }

    pub fn getActiveWindow(self: *DiosixGui) ?*Window {
        if (self.active_win_idx) |idx| {
            if (idx < self.windows.items.len) return &self.windows.items[idx];
        }
        return null;
    }

    // --- Render Pipeline ---

    // Intelligent damage-aware redraw into clean_surface (without cursor)
    // Returns the damaged bounding box that was redrawn (empty if nothing changed)
    pub fn renderDamaged(self: *DiosixGui, clean_surface: *fb.Surface) fb.Box {
        if (self.dirty_box.isEmpty()) return fb.Box{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };

        const screen_box = fb.Box.fromPosSize(0, 0, self.width, self.height);
        const damage = self.dirty_box.intersect(screen_box);
        self.dirty_box = fb.Box{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };

        if (damage.isEmpty()) return fb.Box{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };

        const win_alpha = self.getWindowOpacityAlpha();
        const tab_bar_box = fb.Box.fromPosSize(0, 0, self.width, TAB_BAR_HEIGHT);
        const blur_radius = self.getBlurRadius();

        const is_full_screen = (damage.x0 == 0 and damage.y0 == 0 and
            damage.x1 == @as(i32, @intCast(self.width)) and
            damage.y1 == @as(i32, @intCast(self.height)));

        if (is_full_screen) {
            clean_surface.drawGraduatedBackground(self.bg_top_color, self.bg_bot_color);
            self.renderTabBar(clean_surface);
            for (self.windows.items) |*win| {
                if (win.is_onscreen) {
                    const win_box = win.getBox();
                    clean_surface.drawBlurredBackdropInBox(win_box, win_box, self.bg_top_color, self.bg_bot_color, blur_radius, Window.CORNER_RADIUS, self.blur_scratch);
                    win.render(clean_surface, win_alpha);
                }
            }
        } else {
            // 1. Redraw tab bar if it intersects damage
            if (damage.intersects(tab_bar_box)) {
                clean_surface.drawGraduatedBackgroundInBox(tab_bar_box, self.bg_top_color, self.bg_bot_color);
                self.renderTabBar(clean_surface);
            }

            // 2. Redraw any on-screen window intersecting damage
            for (self.windows.items) |*win| {
                if (win.is_onscreen and win.intersectsBox(damage)) {
                    const win_box = win.getBox();
                    clean_surface.drawBlurredBackdropInBox(win_box, win_box, self.bg_top_color, self.bg_bot_color, blur_radius, Window.CORNER_RADIUS, self.blur_scratch);
                    win.render(clean_surface, win_alpha);
                }
            }
        }

        return damage;
    }

    pub fn render(self: *DiosixGui, surface: *fb.Surface) void {
        self.markFullDirty();
        _ = self.renderDamaged(surface);
        self.cursor.draw(surface);
    }

    fn renderTabBar(self: *DiosixGui, surface: *fb.Surface) void {
        const bar_box = fb.Box.fromPosSize(0, 0, self.width, TAB_BAR_HEIGHT);

        // Translucent top header bar (85% opaque neutral dark glass)
        surface.drawRoundedTranslucentBox(bar_box, 0, fb.Color.GLASS_BG, 220, null);

        // Header bottom divider line
        const div_box = fb.Box.fromPosSize(0, @as(i32, @intCast(TAB_BAR_HEIGHT - 1)), self.width, 1);
        surface.fillBox(div_box, fb.Color.TAB_DIVIDER);

        // Title Branding: Questrial Regular with Accent Gold
        font.drawTextWithShadow(surface, "DIOSIX SYSTEM MENU", 18, 12, fb.Color.ACCENT_GOLD, fb.Color.BLACK);

        // Render Tabs
        for (self.subprograms.items, 0..) |*sub, idx| {
            const tx = TAB_START_X + @as(i32, @intCast(idx)) * TAB_STRIDE;
            const ty: i32 = 5;
            const t_box = fb.Box.fromPosSize(tx, ty, TAB_WIDTH, TAB_HEIGHT);

            const title_w = font.measureString(sub.tab_title);
            const text_x = if (TAB_WIDTH > title_w) tx + @as(i32, @intCast((TAB_WIDTH - title_w) / 2)) else tx + 4;

            const is_active = (idx == self.active_sub_idx);
            if (is_active) {
                // Active tab: Translucent rounded glass pill with bright frosted border
                surface.drawRoundedTranslucentBox(t_box, 6, fb.Color.TAB_ACTIVE_BG, 230, fb.Color.GLASS_BTN_BORDER);
                font.drawTextWithShadow(surface, sub.tab_title, text_x, ty + 7, fb.Color.WHITE, fb.Color.BLACK);
            } else {
                // Inactive tab: subtle translucent dark pill
                surface.drawRoundedTranslucentBox(t_box, 6, fb.Color.TAB_INACTIVE_BG, 180, fb.Color.TAB_INACTIVE_BORDER);
                font.drawTextWithShadow(surface, sub.tab_title, text_x, ty + 7, fb.Color.TEXT_MUTED, fb.Color.BLACK);
            }
        }
    }
};
