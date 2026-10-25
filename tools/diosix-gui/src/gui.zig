// Scalable Vector Dynamic GUI Coordinator for Diosix.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("framebuffer.zig");
const font = @import("font.zig");
const cursor_mod = @import("cursor.zig");
const window_mod = @import("window.zig");
const Window = window_mod.Window;
const host_info = @import("host.zig");
pub const osk_mod = @import("osk.zig");
pub const welcome_mod = @import("welcome.zig");
pub const panes = @import("panes.zig");
pub const scale_mod = @import("scale.zig");
pub const dither_mod = @import("dither.zig");
pub const vector_mod = @import("vector.zig");
pub const tasks_mod = @import("tasks.zig");
const gui_nav = @import("gui/nav.zig");
const gui_input = @import("gui/input.zig");
const gui_render = @import("gui/render.zig");
const linux = std.os.linux;

pub const BORDER_GAP: i32 = 16;

// Standard Window & Icon IDs.
pub const WIN_MENU_ID: u32 = 100;
pub const WIN_VERSION_ID: u32 = 101;
pub const WIN_BACK_ID: u32 = 102;
pub const WIN_HELP_ID: u32 = 103;
pub const WIN_STATUS_ID: u32 = 104;
pub const WIN_ABOUT_ID: u32 = WIN_STATUS_ID;
pub const WIN_CONFIG_ID: u32 = 105;
pub const WIN_SCHEME_DROPDOWN_ID: u32 = 106;
pub const WIN_GUESTS_ID: u32 = 107;
pub const WIN_GUEST_DETAIL_ID: u32 = 108;
pub const WIN_CREATE_VM_ID: u32 = 109;
pub const WIN_CREATE_VM_DETAIL_ID: u32 = 110;
pub const WIN_TASK_BASE_ID: u32 = panes.WIN_TASK_BASE_ID;
pub const ICON_TASK_LABEL_ID: u32 = panes.ICON_TASK_LABEL_ID;
pub const ICON_TASK_PROGRESS_ID: u32 = panes.ICON_TASK_PROGRESS_ID;
pub const ICON_TASK_DISMISS_ID: u32 = panes.ICON_TASK_DISMISS_ID;
pub const WIN_POWER_MODAL_ID: u32 = 202;
pub const WIN_OSK_ID: u32 = 300;
pub const WIN_WELCOME_ID: u32 = 301;
pub const WIN_TOUR_ID: u32 = 302;

pub const ICON_OSK_TOGGLE_ID: u32 = 1400;
pub const ICON_TOUR_LAUNCH_ID: u32 = 1401;
pub const ICON_OSK_KEY_BASE_ID: u32 = 1410;
pub const ICON_OSK_DISPLAY_ID: u32 = 1450;
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

// Main Menu IDs.
pub const ICON_MENU_CREATE_VM_ID: u32 = 1002;
pub const ICON_MENU_ABOUT_ID: u32 = 1003;
pub const ICON_MENU_STATUS_ID: u32 = ICON_MENU_ABOUT_ID;
pub const ICON_MENU_CONFIG_ID: u32 = 1004;
pub const ICON_MENU_RESTART_ID: u32 = 1005;
pub const ICON_MENU_SHUTDOWN_ID: u32 = 1006;

pub const ICON_VERSION_TEXT_ID: u32 = 1011;
pub const ICON_BACK_BTN_ID: u32 = 1021;
pub const ICON_HELP_TEXT_ID: u32 = 1031;

// Power Modal IDs.
pub const ICON_POWER_TITLE_ID: u32 = 1380;
pub const ICON_POWER_MSG1_ID: u32 = 1381;
pub const ICON_POWER_MSG2_ID: u32 = 1382;
pub const ICON_POWER_CANCEL_ID: u32 = 1383;
pub const ICON_POWER_CONFIRM_ID: u32 = 1384;

pub const MENU_ITEM_HEIGHT: u32 = 28;
pub const MENU_ITEM_SPACING: u32 = 6;
pub const MENU_PAD_X: i32 = 16;
pub const MENU_TOP_PAD: i32 = 12;
pub const MENU_BOT_PAD: i32 = 12;
pub const MENU_FULL_H: u32 = 204;
pub const MENU_CONTRACTED_H: u32 = 56;
pub const BACK_PANE_H: u32 = 56;
pub const BACK_PANE_GAP: i32 = 12;
pub const BACK_PANE_Y: i32 =
    BORDER_GAP + @as(i32, @intCast(MENU_CONTRACTED_H)) + BACK_PANE_GAP;

pub const PowerAction = host_info.PowerAction;
pub const ResolutionPreset = scale_mod.ResolutionPreset;
pub const UiScaleMode = scale_mod.UiScaleMode;
pub const ColorDepth = dither_mod.ColorDepth;

pub const RenderMode = enum { accelerated, degraded };
pub const NavAnimState = enum { idle, opening, closing };
pub const DriftDirection = enum(u2) { left = 0, right = 1, up = 2, down = 3 };

pub const SemanticAction = enum {
    @"menu.create_vm",
    @"menu.about",
    @"menu.status",
    @"menu.config",
    @"menu.back",
    @"osk.toggle",
    @"osk.show",
    @"osk.hide",
    @"welcome.open",
    @"welcome.close",
    @"tour.start",
    @"tour.next",
    @"tour.prev",
    @"tour.close",
};

pub const DRIFT_INTERVAL_MS: u32 = 60;

pub fn easeOutCubic(t: f32) f32 {
    const clamped = std.math.clamp(t, 0.0, 1.0);
    const inv = 1.0 - clamped;
    return 1.0 - inv * inv * inv;
}

pub const ICON_STATUS_HOST_HDR_ID: u32 = 1040;
pub const ICON_STATUS_HOST_UPTIME_LABEL_ID: u32 = 1041;
pub const ICON_STATUS_HOST_UPTIME_ID: u32 = 1042;
pub const ICON_STATUS_HOST_CPU_LABEL_ID: u32 = 1043;
pub const ICON_STATUS_HOST_CPU_ID: u32 = 1044;
pub const ICON_STATUS_HOST_RAM_LABEL_ID: u32 = 1045;
pub const ICON_STATUS_HOST_RAM_ID: u32 = 1046;
pub const ICON_STATUS_HOST_TIME_LABEL_ID: u32 = 1047;
pub const ICON_STATUS_HOST_TIME_ID: u32 = 1048;
pub const ICON_STATUS_HV_HDR_ID: u32 = 1049;
pub const ICON_STATUS_HV_BUILD_LABEL_ID: u32 = 1050;
pub const ICON_STATUS_HV_BUILD1_ID: u32 = 1051;
pub const ICON_STATUS_HV_BUILD2_ID: u32 = 1052;
pub const ICON_STATUS_HV_FOOTPRINT_LABEL_ID: u32 = 1053;
pub const ICON_STATUS_HV_FOOTPRINT_ID: u32 = 1054;

pub const ICON_CONFIG_HDR_ID: u32 = 1060;
pub const ICON_CONFIG_TRANSPARENCY_LBL_ID: u32 = 1061;
pub const ICON_CONFIG_TRANSPARENCY_SLIDER_ID: u32 = 1062;
pub const ICON_CONFIG_SPEED_LBL_ID: u32 = 1072;
pub const ICON_CONFIG_SPEED_SLIDER_ID: u32 = 1073;
pub const ICON_CONFIG_SCHEME_LBL_ID: u32 = 1074;
pub const ICON_CONFIG_SCHEME_DROPDOWN_ID: u32 = 1075;
pub const ICON_CONFIG_GUEST_RATE_LBL_ID: u32 = 1076;
pub const ICON_CONFIG_GUEST_RATE_SLIDER_ID: u32 = 1077;
pub const ICON_SCHEME_OPT_BASE_ID: u32 = 1080;

pub const ICON_CONFIG_DISPLAY_HDR_ID: u32 = 1090;
pub const ICON_CONFIG_RES_LBL_ID: u32 = 1091;
pub const ICON_CONFIG_RES_DROPDOWN_ID: u32 = 1092;
pub const ICON_CONFIG_DEPTH_LBL_ID: u32 = 1093;
pub const ICON_CONFIG_DEPTH_DROPDOWN_ID: u32 = 1094;
pub const ICON_CONFIG_SCALE_LBL_ID: u32 = 1095;
pub const ICON_CONFIG_SCALE_DROPDOWN_ID: u32 = 1096;
pub const ICON_RES_OPT_BASE_ID: u32 = 1100;
pub const ICON_DEPTH_OPT_BASE_ID: u32 = 1110;
pub const ICON_SCALE_OPT_BASE_ID: u32 = 1120;

pub const ICON_GUESTS_HDR_ID: u32 = 1200;
pub const ICON_GUESTS_ITEM_BASE_ID: u32 = 1210;
pub const ICON_GUEST_DETAIL_HDR_ID: u32 = 1250;
pub const ICON_GUEST_RESTART_ID: u32 = 1251;
pub const ICON_GUEST_SHUTDOWN_ID: u32 = 1252;
pub const ICON_GUEST_STORAGE_HDR_ID: u32 = 1253;
pub const ICON_GUEST_PCPU_HDR_ID: u32 = 1254;
pub const ICON_GUEST_PCPU_GRAPH_ID: u32 = 1255;
pub const ICON_GUEST_QUOTA_HDR_ID: u32 = panes.ICON_GUEST_QUOTA_HDR_ID;
pub const ICON_GUEST_PCPU_QUOTA_LBL_ID = panes.ICON_GUEST_PCPU_QUOTA_LBL_ID;
pub const ICON_GUEST_PCPU_QUOTA_SLIDER_ID =
    panes.ICON_GUEST_PCPU_QUOTA_SLIDER_ID;
pub const ICON_GUEST_RAM_QUOTA_LBL_ID = panes.ICON_GUEST_RAM_QUOTA_LBL_ID;
pub const ICON_GUEST_RAM_QUOTA_SLIDER_ID = panes.ICON_GUEST_RAM_QUOTA_SLIDER_ID;
pub const ICON_GUEST_STORAGE_BASE_ID: u32 = 1260;

pub const ICON_CREATE_VM_HDR_ID: u32 = 1300;
pub const ICON_CREATE_VM_ITEM_BASE_ID: u32 = 1310;
pub const ICON_CREATE_VM_DETAIL_HDR_ID: u32 = 1340;
pub const ICON_CREATE_VM_VCPUS_LBL_ID: u32 = 1341;
pub const ICON_CREATE_VM_VCPUS_SLIDER_ID: u32 = 1342;
pub const ICON_CREATE_VM_RAM_LBL_ID: u32 = 1343;
pub const ICON_CREATE_VM_RAM_SLIDER_ID: u32 = 1344;
pub const ICON_CREATE_VM_STORAGE_HDR_ID: u32 = 1345;
pub const ICON_CREATE_VM_BTN_ID: u32 = 1346;
pub const ICON_CREATE_VM_QUOTA_INFO_ID = panes.ICON_CREATE_VM_QUOTA_INFO_ID;
pub const ICON_CREATE_VM_PCPU_LBL_ID = panes.ICON_CREATE_VM_PCPU_LBL_ID;
pub const ICON_CREATE_VM_PCPU_SLIDER_ID = panes.ICON_CREATE_VM_PCPU_SLIDER_ID;
pub const ICON_CREATE_VM_RAM_QUOTA_LBL_ID =
    panes.ICON_CREATE_VM_RAM_QUOTA_LBL_ID;
pub const ICON_CREATE_VM_RAM_QUOTA_SLIDER_ID =
    panes.ICON_CREATE_VM_RAM_QUOTA_SLIDER_ID;
pub const ICON_CREATE_VM_NAME_LBL_ID = panes.ICON_CREATE_VM_NAME_LBL_ID;
pub const ICON_CREATE_VM_NAME_INPUT_ID = panes.ICON_CREATE_VM_NAME_INPUT_ID;
pub const ICON_CREATE_VM_STORAGE_BASE_ID: u32 = 1350;

pub const DEFAULT_GUEST_UPDATE_INTERVAL_MS: u32 = 2000;
pub const BackdropScheme = fb.BackdropScheme;

pub const DiosixGui = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    mm_width: u32 = 0,
    mm_height: u32 = 0,
    resolution_preset: ResolutionPreset = .r1280x800,
    color_depth: ColorDepth = .bpp32,
    ui_scale_mode: UiScaleMode = .auto,
    display_reconfig_pending: bool = false,
    windows: std.ArrayList(Window),
    active_win_idx: ?usize = null,
    cursor: cursor_mod.Cursor,
    mouse_left_down: bool = false,
    window_transparency: u32 = 30,
    bg_top_color: u32 = fb.Color.SKY_BASE_TOP,
    bg_bot_color: u32 = fb.Color.GRADIENT_BOT_DEFAULT,
    bg_scheme: BackdropScheme = .rainbow,
    drift_dir: DriftDirection = .right,
    drift_x: i32 = 0,
    drift_y: i32 = 0,
    drift_accum_ms: u32 = 0,
    bg_animation_speed: u32 = 50,
    render_mode: RenderMode = .accelerated,
    dirty_box: fb.Box = fb.Box{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 },
    uptime_accum_ms: u32 = 0,
    last_uptime_sec: u64 = 0,
    selected_guest_cid: ?u64 = null,
    guest_update_interval_ms: u32 = DEFAULT_GUEST_UPDATE_INTERVAL_MS,
    guest_update_accum_ms: u32 = 0,
    selected_create_image_idx: ?usize = null,
    create_vm_name_buf: [64]u8 = @splat(0),
    create_vm_name_len: usize = 0,
    create_vm_vcpus: u32 = 2,
    create_vm_ram_mb: u32 = 512,
    create_vm_pcpu_pct: u32 = 20,
    create_vm_ram_quota_mb: u32 = 512,
    create_vm_storage_idx: usize = 0,
    nav_anim_state: NavAnimState = .idle,
    nav_anim_progress: f32 = 0.0,
    nav_anim_duration_ms: f32 = 200.0,
    active_menu_id: ?u32 = null,
    active_drag_win_id: ?u32 = null,
    power_modal_action: ?PowerAction = null,
    power_action_confirmed: bool = false,
    osk_state: osk_mod.OskState = .{},
    welcome_state: welcome_mod.WelcomeState = .{},
    task_mgr: tasks_mod.TaskManager = .{},

    pub const FALLBACK_HELP_TEXT = "Welcome to diosix";

    pub fn init(
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
    ) !DiosixGui {
        if (width == 0 or height == 0) return error.InvalidDimensions;

        var ts: linux.timespec = undefined;
        const clk_rc = linux.clock_gettime(linux.CLOCK.REALTIME, &ts);
        const seed: u64 = if (@as(isize, @bitCast(clk_rc)) == 0)
            (@as(u64, @bitCast(ts.sec)) *% 31) ^
                (@as(u64, @bitCast(ts.nsec)) << 16)
        else
            0x12345678_9abcdef0;

        var prng = std.Random.DefaultPrng.init(seed);
        const dir_num = prng.random().uintLessThan(u32, 4);
        const chosen_dir: DriftDirection = @fromBackingInt(@intCast(dir_num));

        var gui = DiosixGui{
            .allocator = allocator,
            .width = width,
            .height = height,
            .resolution_preset = ResolutionPreset.fromDimensions(width, height),
            .windows = .empty,
            .cursor = .{
                .x = @as(i32, @intCast(width / 2)),
                .y = @as(i32, @intCast(height / 2)),
                .visible = false,
            },
            .drift_dir = chosen_dir,
        };
        errdefer gui.deinit();
        try gui.windows.ensureTotalCapacity(allocator, 16);

        gui.syncVectorScaleState();
        host_info.resetGuestTelemetryCache();
        try gui.buildMainMenu();
        try gui.buildBottomPanes();
        try gui.buildGuestsPane();
        if (gui.windows.items.len > 0) gui.focusWindow(0);
        gui.updateActiveHelp();
        gui.markFullDirty();
        return gui;
    }

    pub fn deinit(self: *DiosixGui) void {
        font.setActiveLineHeight(font.GLYPH_HEIGHT);
        cursor_mod.setScalePercent(100);
        for (&self.task_mgr.entries) |*e| e.closePipe();
        for (self.windows.items) |*win| win.deinit();
        self.windows.deinit(self.allocator);
    }

    pub fn getEffectiveScalePercent(self: *const DiosixGui) u32 {
        return scale_mod.resolveEffectiveScalePercent(
            self.ui_scale_mode,
            self.width,
            self.height,
            self.mm_width,
            self.mm_height,
        );
    }

    pub fn scalePx(self: *const DiosixGui, base_px: u32) u32 {
        return scale_mod.scaleDim(base_px, self.getEffectiveScalePercent());
    }

    pub fn syncVectorScaleState(self: *const DiosixGui) void {
        const eff_pct = self.getEffectiveScalePercent();
        font.setActiveLineHeight(
            scale_mod.scaleDim(font.GLYPH_HEIGHT, eff_pct),
        );
        cursor_mod.setScalePercent(eff_pct);
    }

    pub const setPhysicalDimensions = gui_render.setPhysicalDimensions;
    pub const setResolutionPreset = gui_render.setResolutionPreset;
    pub const setColorDepth = gui_render.setColorDepth;
    pub const setUiScaleMode = gui_render.setUiScaleMode;
    pub const relayoutAllWindows = gui_render.relayoutAllWindows;

    pub const createWindow = gui_render.createWindow;
    pub const destroyWindow = gui_render.destroyWindow;
    pub const destroyAllWindows = gui_render.destroyAllWindows;
    pub const getWindow = gui_render.getWindow;
    pub const setWindowOnScreen = gui_render.setWindowOnScreen;
    pub const setMenuItemSelected = gui_render.setMenuItemSelected;
    pub const setStatusMenuSelected = gui_render.setStatusMenuSelected;
    pub const findIcon = gui_render.findIcon;
    pub const renderDamaged = gui_render.renderDamaged;
    pub const render = gui_render.render;
    pub const drawWindowsWithAlpha = gui_render.drawWindowsWithAlpha;

    pub const buildMainMenu = gui_nav.buildMainMenu;
    pub const repopulateMainMenu = gui_nav.repopulateMainMenu;
    pub const contractMainMenu = gui_nav.contractMainMenu;
    pub const buildBackPane = gui_nav.buildBackPane;
    pub const buildBottomPanes = gui_nav.buildBottomPanes;
    pub const getChildTargetX = gui_nav.getChildTargetX;
    pub const getChildWindowId = gui_nav.getChildWindowId;
    pub const activateMenuItem = gui_nav.activateMenuItem;
    pub const navigateBack = gui_nav.navigateBack;
    pub const finishClosing = gui_nav.finishClosing;
    pub const completeNavAnimation = gui_nav.completeNavAnimation;
    pub const applyNavAnimation = gui_nav.applyNavAnimation;
    pub const teardownChildPanes = gui_nav.teardownChildPanes;
    pub const tick = gui_nav.tick;

    pub const findIconAt = gui_input.findIconAt;
    pub const findWindowAt = gui_input.findWindowAt;
    pub const updateActiveHelp = gui_input.updateActiveHelp;
    pub const clearMouseHover = gui_input.clearMouseHover;
    pub const handleMouseRelease = gui_input.handleMouseRelease;
    pub const handleMouseMove = gui_input.handleMouseMove;
    pub const handleMouseClick = gui_input.handleMouseClick;
    pub const handleMouseScroll = gui_input.handleMouseScroll;
    pub const focusWindow = gui_input.focusWindow;
    pub const focusWindowById = gui_input.focusWindowById;
    pub const getActiveWindow = gui_input.getActiveWindow;
    pub const confirmPowerModal = gui_input.confirmPowerModal;
    pub const triggerSemanticAction = gui_input.triggerSemanticAction;
    pub const exportSemanticStateJson = gui_input.exportSemanticStateJson;

    pub const buildStatusPane = panes.buildStatusPane;
    pub const updateStatusPaneData = panes.updateStatusPaneData;
    pub const buildGuestsPane = panes.buildGuestsPane;
    pub const buildGuestDetailPane = panes.buildGuestDetailPane;
    pub const updateGuestsPaneData = panes.updateGuestsPaneData;
    pub const selectRunningGuest = panes.selectRunningGuest;
    pub const buildCreateVmPane = panes.buildCreateVmPane;
    pub const buildCreateVmDetailPane = panes.buildCreateVmDetailPane;
    pub const selectCreateVmImage = panes.selectCreateVmImage;
    pub const syncTaskPanes = panes.syncTaskPanes;
    pub const spawnBackgroundTask = panes.spawnBackgroundTask;
    pub const pollBackgroundTasks = panes.pollBackgroundTasks;
    pub const buildConfigPane = panes.buildConfigPane;
    pub const toggleSchemeDropdown = panes.toggleSchemeDropdown;
    pub const toggleResolutionDropdown = panes.toggleResolutionDropdown;
    pub const toggleDepthDropdown = panes.toggleDepthDropdown;
    pub const toggleScaleDropdown = panes.toggleScaleDropdown;
    pub const closeSchemeDropdown = panes.closeSchemeDropdown;
    pub const showPowerModal = panes.showPowerModal;
    pub const buildOskWindow = panes.buildOskWindow;
    pub const showWelcomeModal = panes.showWelcomeModal;
    pub const showTourModal = panes.showTourModal;

    pub fn closePowerModal(self: *DiosixGui) void {
        _ = self.destroyWindow(WIN_POWER_MODAL_ID);
        self.power_modal_action = null;
        self.markFullDirty();
    }
    pub fn getCreateVmName(self: *const DiosixGui) []const u8 {
        return self.create_vm_name_buf[0..self.create_vm_name_len];
    }
    pub fn setCreateVmName(self: *DiosixGui, name: []const u8) void {
        const n = @min(name.len, self.create_vm_name_buf.len - 1);
        @memcpy(self.create_vm_name_buf[0..n], name[0..n]);
        self.create_vm_name_buf[n] = 0;
        self.create_vm_name_len = n;
    }
    pub fn toggleStatusPane(self: *DiosixGui) !void {
        try self.activateMenuItem(ICON_MENU_STATUS_ID);
    }
    pub fn toggleConfigPane(self: *DiosixGui) !void {
        try self.activateMenuItem(ICON_MENU_CONFIG_ID);
    }
    pub fn toggleOsk(self: *DiosixGui) !void {
        self.osk_state.toggle();
        try self.buildOskWindow();
    }

    pub fn hasActiveAnimation(self: *const DiosixGui) bool {
        return self.nav_anim_state != .idle;
    }
    pub fn setRenderMode(self: *DiosixGui, mode: RenderMode) void {
        self.render_mode = mode;
        self.markFullDirty();
    }
    pub fn getRenderMode(self: *const DiosixGui) RenderMode {
        return self.render_mode;
    }
    pub fn setBgAnimationSpeed(self: *DiosixGui, speed: u32) void {
        const clamped = std.math.clamp(speed, 0, 100);
        if (clamped == 0) self.drift_accum_ms = 0;
        self.bg_animation_speed = clamped;
    }
    pub fn getBgAnimationSpeed(self: *const DiosixGui) u32 {
        return self.bg_animation_speed;
    }
    pub fn setGuestUpdateIntervalSeconds(self: *DiosixGui, secs: u32) void {
        const clamped = std.math.clamp(secs, 1, 10);
        self.guest_update_interval_ms = clamped * 1000;
        self.guest_update_accum_ms = 0;
    }
    pub fn getGuestUpdateIntervalSeconds(self: *const DiosixGui) u32 {
        return @max(1, self.guest_update_interval_ms / 1000);
    }
    pub fn setDriftDirection(self: *DiosixGui, dir: DriftDirection) void {
        self.drift_dir = dir;
    }
    pub fn getDriftDirection(self: *const DiosixGui) DriftDirection {
        return self.drift_dir;
    }
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

    pub const setWindowTransparency = gui_render.setWindowTransparency;
    pub const getWindowOpacityAlpha = gui_render.getWindowOpacityAlpha;
    pub const getPopupOpacityAlpha = gui_render.getPopupOpacityAlpha;
    pub const setBackdropTopColor = gui_render.setBackdropTopColor;
    pub const setBackdropBotColor = gui_render.setBackdropBotColor;
    pub const setBackdropScheme = gui_render.setBackdropScheme;
    pub const getBackdropScheme = gui_render.getBackdropScheme;
    pub const handleOskAction = panes.handleOskAction;
    pub const handleKeyChar = panes.handleKeyChar;
    pub const handleKeySpecial = panes.handleKeySpecial;
};

test {
    _ = scale_mod;
    _ = dither_mod;
    _ = vector_mod;
    _ = tasks_mod;
    std.testing.refAllDecls(@This());
}
