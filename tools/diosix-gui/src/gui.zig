// Final Fantasy 7/8 Themed Dynamic GUI Coordinator for Diosix.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("framebuffer.zig");
const cursor_mod = @import("cursor.zig");
const window_mod = @import("window.zig");
const Window = window_mod.Window;
const host_info = @import("host.zig");
pub const osk_mod = @import("osk.zig");
pub const welcome_mod = @import("welcome.zig");
pub const panes = @import("panes.zig");
const gui_nav = @import("gui/nav.zig");
const gui_input = @import("gui/input.zig");
const gui_render = @import("gui/render.zig");
const linux = std.os.linux;

pub const TAB_BAR_HEIGHT: u32 = 0;
pub const BORDER_GAP: i32 = 16;

// Standard Window & Icon IDs.
pub const WIN_MENU_ID: u32 = 100;
pub const WIN_VERSION_ID: u32 = 101;
pub const WIN_BACK_ID: u32 = 102;
pub const WIN_HELP_ID: u32 = 103;
pub const WIN_STATUS_ID: u32 = 104;
pub const WIN_ABOUT_ID: u32 = WIN_STATUS_ID;
pub const WIN_CONFIG_ID: u32 = 105;
pub const WIN_SOFTWARE_ID: u32 = 106;
pub const WIN_HARDWARE_ID: u32 = 107;

pub const WIN_VM_FLEET_ID: u32 = 200;
pub const WIN_VM_DRAWER_ID: u32 = 201;
pub const WIN_POWER_MODAL_ID: u32 = 202;

pub const WIN_OSK_ID: u32 = 300;
pub const WIN_WELCOME_ID: u32 = 301;
pub const WIN_TOUR_ID: u32 = 302;

pub const ICON_OSK_TOGGLE_ID: u32 = 1400;
pub const ICON_TOUR_LAUNCH_ID: u32 = 1401;
pub const ICON_OSK_KEY_BASE_ID: u32 = 1410;
pub const ICON_OSK_DISPLAY_ID: u32 = 1450;
pub const ICON_WELCOME_TOUR_BTN_ID: u32 = 1460;
pub const ICON_WELCOME_INSTALL_BTN_ID: u32 = 1461;
pub const ICON_WELCOME_DISMISS_BTN_ID: u32 = 1462;
pub const ICON_TOUR_PREV_BTN_ID: u32 = 1470;
pub const ICON_TOUR_NEXT_BTN_ID: u32 = 1471;
pub const ICON_TOUR_CLOSE_BTN_ID: u32 = 1472;

// Main Menu IDs.
pub const ICON_MENU_SOFTWARE_ID: u32 = 1001;
pub const ICON_MENU_HARDWARE_ID: u32 = 1002;
pub const ICON_MENU_ABOUT_ID: u32 = 1003;
pub const ICON_MENU_STATUS_ID: u32 = ICON_MENU_ABOUT_ID;
pub const ICON_MENU_CONFIG_ID: u32 = 1004;
pub const ICON_MENU_RESTART_ID: u32 = 1005;
pub const ICON_MENU_SHUTDOWN_ID: u32 = 1006;
pub const ICON_MENU_GUESTS_ID: u32 = ICON_MENU_SOFTWARE_ID;

pub const ICON_VERSION_TEXT_ID: u32 = 1011;
pub const ICON_BACK_BTN_ID: u32 = 1021;
pub const ICON_HELP_TEXT_ID: u32 = 1031;

// VM Fleet Overview IDs.
pub const ICON_VM_CREATE_NEW_ID: u32 = 1200;
pub const ICON_VM_ROOTVM_ID: u32 = 1201;
pub const ICON_VM_ALPINE_ID: u32 = 1202;
pub const ICON_VM_DEBIAN_ID: u32 = 1203;
pub const ICON_VM_FREEBSD_ID: u32 = 1204;
pub const ICON_VM_SNAP_DEBIAN_ID: u32 = 1205;
pub const ICON_VM_NETBSD_ID: u32 = 1206;

// VM Action Drawer IDs.
pub const ICON_DRAWER_TITLE_ID: u32 = 1250;
pub const ICON_DRAWER_STATE_ID: u32 = 1251;
pub const ICON_DRAWER_SPEC1_ID: u32 = 1252;
pub const ICON_DRAWER_SPEC2_ID: u32 = 1253;
pub const ICON_DRAWER_SPEC3_ID: u32 = 1254;
pub const ICON_DRAWER_NOTICE1_ID: u32 = 1255;
pub const ICON_DRAWER_NOTICE2_ID: u32 = 1256;
pub const ICON_DRAWER_BTN_START_ID: u32 = 1260;
pub const ICON_DRAWER_BTN_STOP_ID: u32 = 1261;
pub const ICON_DRAWER_BTN_PAUSE_ID: u32 = 1262;
pub const ICON_DRAWER_BTN_SNAP_ID: u32 = 1263;
pub const ICON_DRAWER_BTN_CONSOLE_ID: u32 = 1264;
pub const ICON_DRAWER_BTN_KILL_ID: u32 = 1265;
pub const ICON_DRAWER_BTN_RESTORE_ID: u32 = 1266;
pub const ICON_DRAWER_BTN_CLONE_ID: u32 = 1267;
pub const ICON_DRAWER_BTN_DELETE_ID: u32 = 1268;

// Software Pane IDs.
pub const ICON_SW_FILTER_ALL_ID: u32 = 1301;
pub const ICON_SW_FILTER_MAN_ID: u32 = 1302;
pub const ICON_SW_FILTER_DSK_ID: u32 = 1303;
pub const ICON_SW_FILTER_IMG_ID: u32 = 1304;
pub const ICON_SW_BTN_IMPORT_ID: u32 = 1305;
pub const ICON_SW_ITEM_ALPINE_MAN_ID: u32 = 1310;
pub const ICON_SW_ITEM_DEBIAN_MAN_ID: u32 = 1311;
pub const ICON_SW_ITEM_ALPINE_RAW_ID: u32 = 1312;
pub const ICON_SW_ITEM_DATA_QCOW_ID: u32 = 1313;
pub const ICON_SW_ITEM_ALPINE_ISO_ID: u32 = 1314;
pub const ICON_SW_ITEM_DEBIAN_QCOW_ID: u32 = 1315;

// Hardware Pane IDs.
pub const ICON_HW_ITEM_ETH0_ID: u32 = 1350;
pub const ICON_HW_ITEM_BR0_ID: u32 = 1351;
pub const ICON_HW_ITEM_TPM_ID: u32 = 1352;
pub const ICON_HW_ITEM_YUBIKEY_ID: u32 = 1353;
pub const ICON_HW_ITEM_NVME_ID: u32 = 1354;
pub const ICON_HW_ITEM_CPU_ID: u32 = 1355;

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
pub const MENU_FULL_H: u32 = 236;
pub const MENU_CONTRACTED_H: u32 = 56;
pub const BACK_PANE_H: u32 = 56;
pub const BACK_PANE_GAP: i32 = 12;
pub const BACK_PANE_Y: i32 =
    BORDER_GAP + @as(i32, @intCast(MENU_CONTRACTED_H)) + BACK_PANE_GAP;

pub const PowerAction = host_info.PowerAction;

pub const RenderMode = enum {
    accelerated,
    degraded,
};

pub const NavAnimState = enum {
    idle,
    opening,
    closing,
};

pub const DriftDirection = enum(u2) {
    left = 0,
    right = 1,
    up = 2,
    down = 3,
};

pub const SemanticAction = enum {
    @"menu.software",
    @"menu.hardware",
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
pub const ICON_CONFIG_BLUR_LBL_ID: u32 = 1063;
pub const ICON_CONFIG_BLUR_SLIDER_ID: u32 = 1064;
pub const ICON_CONFIG_THEME_LBL_ID: u32 = 1065;
pub const ICON_CONFIG_THEME_DAY_ID: u32 = 1066;
pub const ICON_CONFIG_THEME_MIDNIGHT_ID: u32 = 1067;
pub const ICON_CONFIG_THEME_SUNSET_ID: u32 = 1068;
pub const ICON_CONFIG_THEME_EMERALD_ID: u32 = 1069;
pub const ICON_CONFIG_SPEED_LBL_ID: u32 = 1072;
pub const ICON_CONFIG_SPEED_SLIDER_ID: u32 = 1073;
pub const GROUP_CONFIG_THEME: u16 = 1;

pub const DiosixGui = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,

    windows: std.ArrayList(Window),
    active_win_idx: ?usize = null,

    cursor: cursor_mod.Cursor,
    mouse_left_down: bool = false,

    window_transparency: u32 = 30,
    blur_strength: u32 = 50,

    bg_top_color: u32 = fb.Color.SKY_BASE_TOP,
    bg_bot_color: u32 = fb.Color.GRADIENT_BOT_DEFAULT,

    drift_dir: DriftDirection = .right,
    drift_x: i32 = 0,
    drift_y: i32 = 0,
    drift_accum_ms: u32 = 0,
    bg_animation_speed: u32 = 50,

    render_mode: RenderMode = .accelerated,
    dirty_box: fb.Box = fb.Box{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 },
    blur_scratch: []u32,

    uptime_accum_ms: u32 = 0,
    last_uptime_sec: u64 = 0,

    nav_anim_state: NavAnimState = .idle,
    nav_anim_progress: f32 = 0.0,
    nav_anim_duration_ms: f32 = 200.0,
    active_menu_id: ?u32 = null,

    active_drag_win_id: ?u32 = null,
    selected_vm_id: u32 = ICON_VM_ALPINE_ID,
    selected_theme_id: u32 = ICON_CONFIG_THEME_DAY_ID,

    power_modal_action: ?PowerAction = null,
    power_action_confirmed: bool = false,

    osk_state: osk_mod.OskState = .{},
    welcome_state: welcome_mod.WelcomeState = .{},

    pub const FALLBACK_HELP_TEXT = "Welcome to diosix";

    pub fn init(
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
    ) !DiosixGui {
        const total_h = std.math.add(
            usize,
            height,
            64,
        ) catch return error.InvalidDimensions;
        const scratch_len = std.math.mul(
            usize,
            width,
            total_h,
        ) catch return error.InvalidDimensions;
        const scratch_mem = try allocator.alloc(u32, scratch_len);

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
            .windows = .empty,
            .cursor = cursor_mod.Cursor{
                .x = @as(i32, @intCast(width / 2)),
                .y = @as(i32, @intCast(height / 2)),
                .visible = false,
            },
            .window_transparency = 30,
            .blur_scratch = scratch_mem,
            .drift_dir = chosen_dir,
            .bg_animation_speed = 50,
        };
        errdefer gui.deinit();

        try gui.buildMainMenu();
        try gui.buildBottomPanes();
        try gui.buildVmFleetOverview();

        if (gui.windows.items.len > 0) {
            gui.focusWindow(0);
        }

        gui.updateActiveHelp();
        gui.markFullDirty();

        return gui;
    }

    pub fn deinit(self: *DiosixGui) void {
        for (self.windows.items) |*win| {
            win.deinit();
        }
        self.windows.deinit(self.allocator);
        self.allocator.free(self.blur_scratch);
    }

    // --- Delegated Window Lifecycle, Navigation, Input, & Render Methods ---

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
    pub const selectVm = gui_input.selectVm;
    pub const handleVmAction = gui_input.handleVmAction;
    pub const confirmPowerModal = gui_input.confirmPowerModal;
    pub const triggerSemanticAction = gui_input.triggerSemanticAction;
    pub const exportSemanticStateJson = gui_input.exportSemanticStateJson;

    pub const buildStatusPane = panes.buildStatusPane;
    pub const updateStatusPaneData = panes.updateStatusPaneData;
    pub const buildConfigPane = panes.buildConfigPane;
    pub const buildSoftwarePane = panes.buildSoftwarePane;
    pub const buildHardwarePane = panes.buildHardwarePane;
    pub const buildVmFleetOverview = panes.buildVmFleetOverview;
    pub const buildVmActionDrawer = panes.buildVmActionDrawer;
    pub const showPowerModal = panes.showPowerModal;
    pub const buildOskWindow = panes.buildOskWindow;
    pub const showWelcomeModal = panes.showWelcomeModal;
    pub const showTourModal = panes.showTourModal;

    pub fn teardownVmFleetOverview(self: *DiosixGui) void {
        _ = self.destroyWindow(WIN_VM_FLEET_ID);
        _ = self.destroyWindow(WIN_VM_DRAWER_ID);
    }

    pub fn closePowerModal(self: *DiosixGui) void {
        _ = self.destroyWindow(WIN_POWER_MODAL_ID);
        self.power_modal_action = null;
        self.markFullDirty();
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
    pub const setBlurStrength = gui_render.setBlurStrength;
    pub const getBlurStrength = gui_render.getBlurStrength;
    pub const getBlurRadius = gui_render.getBlurRadius;
    pub const setBackdropTopColor = gui_render.setBackdropTopColor;
    pub const setBackdropBotColor = gui_render.setBackdropBotColor;
    pub const handleOskAction = panes.handleOskAction;
};
