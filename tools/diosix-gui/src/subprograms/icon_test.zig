// Icon Types, Transparency & Backdrop Controls Sub-Program for Diosix GUI
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

// Window IDs owned by IconTest
pub const WIN_CONTROLS_ID: u32 = 200;
pub const WIN_GROUPS_ID: u32 = 201;
pub const WIN_INSPECTOR_ID: u32 = 202;

// Icon IDs
pub const ICON_RO_TEXT_ID: u32 = 2001;
pub const ICON_RW_TEXT_ID: u32 = 2002;
pub const ICON_SLIDER_TRANSPARENCY_ID: u32 = 2003;
pub const ICON_SLIDER_BLUR_ID: u32 = 2006;
pub const ICON_SLIDER_VCPU_ID: u32 = 2004;
pub const ICON_TICK_LOGGING_ID: u32 = 2005;

// Read-only label IDs
pub const ICON_RO_LABEL1_ID: u32 = 2090;
pub const ICON_RO_LABEL2_ID: u32 = 2091;
pub const ICON_RO_LABEL3_ID: u32 = 2092;
pub const ICON_RO_LABEL4_ID: u32 = 2095;
pub const ICON_RO_LABEL5_ID: u32 = 2093;
pub const ICON_RO_LABEL6_ID: u32 = 2094;
pub const ICON_RO_LABEL7_ID: u32 = 2096;
pub const ICON_PROGRESS_TEST_ID: u32 = 2007;
pub const ICON_RO_LABEL8_ID: u32 = 2097;
pub const ICON_BTN_RESET_DEFAULTS_ID: u32 = 2008;
pub const ICON_BTN_RUN_BENCHMARK_ID: u32 = 2009;
pub const ICON_RO_LABEL9_ID: u32 = 2098;
pub const ICON_SLIDER_TIMESLICE_ID: u32 = 2010;
pub const ICON_BTN_EXPORT_LOGS_ID: u32 = 2011;
pub const ICON_RO_TOP_LABEL_ID: u32 = 2190;
pub const ICON_RO_BOT_LABEL_ID: u32 = 2191;

// Exclusive Group 1 - Top Backdrop Color (Radio)
pub const ICON_TOP_LIGHT_BLUE_ID: u32 = 2101; // Default Light Blue
pub const ICON_TOP_CYAN_ID: u32       = 2102; // Sky Cyan
pub const ICON_TOP_AMBER_ID: u32      = 2103; // Sunset Amber
pub const ICON_TOP_SLATE_ID: u32      = 2104; // Slate Frost

// Exclusive Group 2 - Bottom Backdrop Color (Radio)
pub const ICON_BOT_DARK_BLUE_ID: u32  = 2105; // Default Dark Blue
pub const ICON_BOT_NAVY_ID: u32       = 2106; // Midnight Navy
pub const ICON_BOT_INDIGO_ID: u32     = 2107; // Deep Indigo
pub const ICON_BOT_PITCH_ID: u32      = 2108; // Pitch Black

pub const ICON_INSPECTOR_TEXT_ID: u32 = 2201;

pub const IconTestData = struct {
    counter: u32 = 0,
    elapsed_ms: u32 = 0,
    inspector_log: [128]u8 = @splat(0),
    inspector_len: usize = 0,

    pub fn setLog(self: *IconTestData, msg: []const u8) void {
        const c_len = @min(msg.len, self.inspector_log.len);
        @memcpy(self.inspector_log[0..c_len], msg[0..c_len]);
        self.inspector_len = c_len;
    }
};

var global_test_data = IconTestData{};

pub fn createSubProgram(allocator: std.mem.Allocator) SubProgram {
    var sub = SubProgram.init(
        allocator,
        2,
        "icon_test",
        "2: CONTROLS & ICONS",
        init,
        tick,
        onActivate,
        onDeactivate,
        handleKey,
        handleMouseClick,
        handleMouseMove,
    );
    sub.user_data = &global_test_data;
    return sub;
}

pub fn init(sub: *SubProgram, gui_ctx: *anyopaque) void {
    _ = sub;
    _ = gui_ctx;
    global_test_data.setLog("Interactive Showcase: Drag the transparency slider or select backdrop colors to test callbacks.");
}

pub fn onActivate(sub: *SubProgram, gui_ctx: *anyopaque) void {
    _ = sub;
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    gui.setWindowOnScreen(WIN_CONTROLS_ID, true);
    gui.setWindowOnScreen(WIN_GROUPS_ID, true);
    gui.setWindowOnScreen(WIN_INSPECTOR_ID, true);
}

pub fn onDeactivate(sub: *SubProgram, gui_ctx: *anyopaque) void {
    _ = sub;
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    gui.setWindowOnScreen(WIN_CONTROLS_ID, false);
    gui.setWindowOnScreen(WIN_GROUPS_ID, false);
    gui.setWindowOnScreen(WIN_INSPECTOR_ID, false);
}

// Preemptive Multitasking Tick: Continues running even when this tab is not active!
pub fn tick(sub: *SubProgram, gui_ctx: *anyopaque, dt_ms: u32, is_active: bool) void {
    _ = sub;
    global_test_data.elapsed_ms += dt_ms;
    if (global_test_data.elapsed_ms >= 500) {
        global_test_data.elapsed_ms -= 500;
        global_test_data.counter += 1;

        // Background update demonstration: Update read-only telemetry counter
        if (is_active) {
            const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
            if (gui.findIcon(WIN_CONTROLS_ID, ICON_RO_TEXT_ID)) |ic| {
                var c_buf: [64]u8 = undefined;
                const c_str = std.fmt.bufPrint(&c_buf, "Live Core Telemetry: {d} ticks (OK)", .{global_test_data.counter}) catch "";
                ic.setText(c_str);
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

// Interactive Callbacks
pub fn onTransparencySliderChanged(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    gui.setWindowTransparency(@intCast(icon.slider_val));

    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[REAL-TIME] Window Transparency set to {d}% (Opacity: {d}%)", .{ icon.slider_val, 100 - icon.slider_val }) catch "";
    global_test_data.setLog(msg);
    updateInspector(gui_ctx);
}

pub fn onBlurSliderChanged(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    gui.setBlurStrength(@intCast(icon.slider_val));

    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[REAL-TIME] Backdrop Gaussian Blur set to {d}% (Radius: {d}px)", .{ icon.slider_val, gui.getBlurRadius() }) catch "";
    global_test_data.setLog(msg);
    updateInspector(gui_ctx);
}

pub fn onVcpuSliderChanged(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[CALLBACK] VCPU Quota adjusted to {d}% (Icon #{d})", .{ icon.slider_val, icon.id }) catch "";
    global_test_data.setLog(msg);
    updateInspector(gui_ctx);
}

pub fn onLoggingToggled(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    var buf: [128]u8 = undefined;
    const state_str = if (icon.is_ticked) "ENABLED" else "DISABLED";
    const msg = std.fmt.bufPrint(&buf, "[CALLBACK] Verbose Logging toggled to: {s}", .{state_str}) catch "";
    global_test_data.setLog(msg);
    updateInspector(gui_ctx);
}

pub fn onTopColorSelected(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    if (!icon.is_ticked) return;
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    const col: u32 = switch (icon.id) {
        ICON_TOP_LIGHT_BLUE_ID => 0x004C8BE0,
        ICON_TOP_CYAN_ID       => 0x002EB8D8,
        ICON_TOP_AMBER_ID      => 0x00C86840,
        ICON_TOP_SLATE_ID      => 0x00607890,
        else                   => 0x004C8BE0,
    };
    gui.setBackdropTopColor(col);

    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[BACKDROP TOP] Selected '{s}' (#0x{X:0>6})", .{ icon.getText(), col }) catch "";
    global_test_data.setLog(msg);
    updateInspector(gui_ctx);
}

pub fn onBotColorSelected(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    if (!icon.is_ticked) return;
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    const col: u32 = switch (icon.id) {
        ICON_BOT_DARK_BLUE_ID => 0x000C1836,
        ICON_BOT_NAVY_ID      => 0x00060B18,
        ICON_BOT_INDIGO_ID    => 0x00180828,
        ICON_BOT_PITCH_ID     => 0x00000206,
        else                  => 0x000C1836,
    };
    gui.setBackdropBotColor(col);

    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[BACKDROP BOTTOM] Selected '{s}' (#0x{X:0>6})", .{ icon.getText(), col }) catch "";
    global_test_data.setLog(msg);
    updateInspector(gui_ctx);
}

pub fn onReadWriteTextChanged(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[CALLBACK] Read-Write field input: '{s}'", .{icon.getText()}) catch "";
    global_test_data.setLog(msg);
    updateInspector(gui_ctx);
}

pub fn onResetDefaults(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    _ = icon;
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    gui.setWindowTransparency(50);
    gui.setBlurStrength(50);
    if (gui.findIcon(WIN_CONTROLS_ID, ICON_SLIDER_TRANSPARENCY_ID)) |sl| sl.setSliderValue(50);
    if (gui.findIcon(WIN_CONTROLS_ID, ICON_SLIDER_BLUR_ID)) |sl| sl.setSliderValue(50);
    if (gui.findIcon(WIN_CONTROLS_ID, ICON_SLIDER_VCPU_ID)) |sl| sl.setSliderValue(75);
    if (gui.findIcon(WIN_CONTROLS_ID, ICON_SLIDER_TIMESLICE_ID)) |sl| sl.setSliderValue(10);
    if (gui.findIcon(WIN_CONTROLS_ID, ICON_PROGRESS_TEST_ID)) |p| p.setProgress(65);
    global_test_data.setLog("[ACTION] Reset all controls and sliders to default configurations.");
    updateInspector(gui_ctx);
}

pub fn onRunBenchmark(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    _ = icon;
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    if (gui.findIcon(WIN_CONTROLS_ID, ICON_PROGRESS_TEST_ID)) |p| {
        const next_val = if (p.progress_val + 15 > 100) 20 else p.progress_val + 15;
        p.setProgress(next_val);
    }
    global_test_data.setLog("[BENCHMARK] Executed hypervisor stress workload pass.");
    updateInspector(gui_ctx);
}

pub fn onTimesliceSliderChanged(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[SCHEDULER] Timeslice quantum set to {d}ms", .{icon.slider_val}) catch "";
    global_test_data.setLog(msg);
    updateInspector(gui_ctx);
}

pub fn onExportLogs(gui_ctx: *anyopaque, win_ctx: *anyopaque, icon: *Icon) void {
    _ = win_ctx;
    _ = icon;
    global_test_data.setLog("[EXPORT] Telemetry and trace records exported to serial console.");
    updateInspector(gui_ctx);
}

fn updateInspector(gui_ctx: *anyopaque) void {
    const gui: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    if (gui.findIcon(WIN_INSPECTOR_ID, ICON_INSPECTOR_TEXT_ID)) |ic| {
        ic.setText(global_test_data.inspector_log[0..global_test_data.inspector_len]);
    }
}

