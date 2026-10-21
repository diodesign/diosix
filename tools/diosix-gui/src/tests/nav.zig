// Navigation, Animation, Active Help, and Hit Exclusivity Tests for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const testing = std.testing;
const fb = @import("../framebuffer.zig");
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const icon_mod = @import("../icon.zig");
const tests_visual = @import("visual.zig");

test "diosix-gui: linked list pane architecture and switching between panes" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    var win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    const icon_status = win_menu.getIconById(gui_mod.ICON_MENU_STATUS_ID).?;
    const icon_config = win_menu.getIconById(gui_mod.ICON_MENU_CONFIG_ID).?;

    // 1. Initially no child panes and full menu.
    try testing.expect(win_menu.child_window_id == null);
    try testing.expect(!icon_status.is_selected);
    try testing.expect(!icon_config.is_selected);
    try testing.expect(gui.getWindow(gui_mod.WIN_BACK_ID) == null);
    try testing.expectEqual(gui_mod.MENU_FULL_H, win_menu.height);

    // 2. Open Status pane: menu rolls up, Back pane and Status pane appear.
    try gui.activateMenuItem(gui_mod.ICON_MENU_STATUS_ID);
    gui.completeNavAnimation();
    win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    try testing.expectEqual(gui_mod.WIN_STATUS_ID, win_menu.child_window_id.?);
    try testing.expect(gui.getWindow(gui_mod.WIN_STATUS_ID) != null);
    try testing.expect(gui.getWindow(gui_mod.WIN_BACK_ID) != null);
    try testing.expectEqual(gui_mod.MENU_CONTRACTED_H, win_menu.height);
    const st_id = gui_mod.ICON_MENU_STATUS_ID;
    const win_status_item = win_menu.getIconById(st_id).?;
    try testing.expect(win_status_item.is_selected);

    // 3. Switch to Config pane: Status is torn down, Config is opened.
    try gui.activateMenuItem(gui_mod.ICON_MENU_CONFIG_ID);
    gui.completeNavAnimation();
    win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    try testing.expect(gui.getWindow(gui_mod.WIN_STATUS_ID) == null);
    try testing.expect(gui.getWindow(gui_mod.WIN_CONFIG_ID) != null);
    try testing.expectEqual(gui_mod.WIN_CONFIG_ID, win_menu.child_window_id.?);
    try testing.expect(gui.getWindow(gui_mod.WIN_BACK_ID) != null);
    try testing.expectEqual(gui_mod.MENU_CONTRACTED_H, win_menu.height);
    const cfg_id = gui_mod.ICON_MENU_CONFIG_ID;
    const win_config_item = win_menu.getIconById(cfg_id).?;
    try testing.expect(win_config_item.is_selected);

    // 4. Clicking Back button restores full main menu and repopulates.
    const win_back = gui.getWindow(gui_mod.WIN_BACK_ID).?;
    const back_btn = win_back.getIconById(gui_mod.ICON_BACK_BTN_ID).?;
    gui.handleMouseClick(
        win_back.x + back_btn.rel_x + 5,
        win_back.y + back_btn.rel_y + 5,
    );
    gui.completeNavAnimation();
    win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    try testing.expect(gui.getWindow(gui_mod.WIN_CONFIG_ID) == null);
    try testing.expect(gui.getWindow(gui_mod.WIN_BACK_ID) == null);
    try testing.expect(win_menu.child_window_id == null);
    try testing.expectEqual(gui_mod.MENU_FULL_H, win_menu.height);
    try testing.expectEqual(@as(usize, 4), win_menu.icons.items.len);
}

test "diosix-gui: 3-tier active help priority system" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const win_help = gui.getWindow(gui_mod.WIN_HELP_ID).?;
    const help_icon = win_help.getIconById(gui_mod.ICON_HELP_TEXT_ID).?;
    const win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    const item_about = &win_menu.icons.items[0];

    // Priority 1: Cursor over icon with help text displays icon help text.
    gui.handleMouseMove(
        win_menu.x + item_about.rel_x + 5,
        win_menu.y + item_about.rel_y + 5,
        false,
    );
    try testing.expectEqualStrings(
        "View hypervisor footprint, host telemetry, and build information",
        help_icon.getText(),
    );

    // Priority 2: Open Status pane. Text icons have no help text, pane does.
    try gui.activateMenuItem(gui_mod.ICON_MENU_STATUS_ID);
    gui.completeNavAnimation();
    const win_status = gui.getWindow(gui_mod.WIN_STATUS_ID).?;

    // Cursor over Back button shows Back button help text.
    const win_back = gui.getWindow(gui_mod.WIN_BACK_ID).?;
    const back_btn = win_back.getIconById(gui_mod.ICON_BACK_BTN_ID).?;
    gui.handleMouseMove(
        win_back.x + back_btn.rel_x + 5,
        win_back.y + back_btn.rel_y + 5,
        false,
    );
    try testing.expectEqualStrings(
        "Return to the main menu",
        help_icon.getText(),
    );

    // Cursor over status pane's "Uptime" label -> shows pane help text.
    const uptime_id = gui_mod.ICON_STATUS_HOST_UPTIME_LABEL_ID;
    const lbl_uptime = win_status.getIconById(uptime_id).?;
    gui.handleMouseMove(
        win_status.x + lbl_uptime.rel_x + 2,
        win_status.y + lbl_uptime.rel_y + 2,
        false,
    );
    try testing.expectEqualStrings(
        "Information about this host system and hypervisor",
        help_icon.getText(),
    );

    // Cursor over empty region of status pane -> shows pane help text.
    gui.handleMouseMove(win_status.x + 10, win_status.y + 10, false);
    try testing.expectEqualStrings(
        "Information about this host system and hypervisor",
        help_icon.getText(),
    );

    // Priority 3: Cursor over empty desktop -> shows fallback text.
    gui.handleMouseMove(50, 500, false);
    try testing.expectEqualStrings("Welcome to diosix", help_icon.getText());
}

test "diosix-gui: menu roll-up animation, pane slide-in, and repopulation" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const pixel_mem = try allocator.alloc(u32, 1280 * 800);
    defer allocator.free(pixel_mem);
    const pitch = 1280 * @sizeOf(u32);
    var surface = fb.Surface.init(pixel_mem.ptr, 1280, 800, pitch);

    const win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    try testing.expectEqual(gui_mod.MENU_FULL_H, win_menu.height);
    try testing.expectEqual(gui_mod.NavAnimState.idle, gui.nav_anim_state);

    // 1. Activate Status menu item initiates opening animation.
    try gui.activateMenuItem(gui_mod.ICON_MENU_STATUS_ID);
    try testing.expectEqual(gui_mod.NavAnimState.opening, gui.nav_anim_state);
    try testing.expect(gui.hasActiveAnimation());

    // 2. Tick 100ms: intermediate animation frame.
    gui.tick(100);
    try testing.expectEqual(gui_mod.NavAnimState.opening, gui.nav_anim_state);
    try testing.expect(
        gui.nav_anim_progress > 0.0 and gui.nav_anim_progress < 1.0,
    );
    try testing.expect(win_menu.height < gui_mod.MENU_FULL_H);
    try testing.expect(win_menu.height > gui_mod.MENU_CONTRACTED_H);

    const win_back = gui.getWindow(gui_mod.WIN_BACK_ID).?;
    try testing.expect(win_back.x < gui_mod.BORDER_GAP);

    const win_status = gui.getWindow(gui_mod.WIN_STATUS_ID).?;
    try testing.expect(win_status.x > gui.getChildTargetX());

    gui.markFullDirty();
    _ = gui.renderDamaged(&surface);
    try tests_visual.writePpmFile(&surface, "/tmp/diosix_menu_anim_midway.ppm");

    // 3. Tick 150ms: animation completes.
    gui.tick(150);
    try testing.expectEqual(gui_mod.NavAnimState.idle, gui.nav_anim_state);
    try testing.expectEqual(gui_mod.MENU_CONTRACTED_H, win_menu.height);
    try testing.expectEqual(gui_mod.BORDER_GAP, win_back.x);
    try testing.expectEqual(gui.getChildTargetX(), win_status.x);

    // 4. Click Back button initiates closing animation.
    const back_btn = win_back.getIconById(gui_mod.ICON_BACK_BTN_ID).?;
    gui.handleMouseClick(
        win_back.x + back_btn.rel_x + 5,
        win_back.y + back_btn.rel_y + 5,
    );
    try testing.expectEqual(gui_mod.NavAnimState.closing, gui.nav_anim_state);
    try testing.expect(gui.hasActiveAnimation());

    // 5. Tick 100ms: intermediate closing frame.
    gui.tick(100);
    try testing.expectEqual(gui_mod.NavAnimState.closing, gui.nav_anim_state);
    try testing.expect(win_menu.height > gui_mod.MENU_CONTRACTED_H);
    try testing.expect(win_menu.height < gui_mod.MENU_FULL_H);
    try testing.expect(win_back.x < gui_mod.BORDER_GAP);
    try testing.expect(win_status.x > gui.getChildTargetX());

    // 6. Tick 150ms: closing completes, repopulating full menu.
    gui.tick(150);
    try testing.expectEqual(gui_mod.NavAnimState.idle, gui.nav_anim_state);
    const win_menu_repop = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    try testing.expectEqual(gui_mod.MENU_FULL_H, win_menu_repop.height);
    try testing.expect(gui.getWindow(gui_mod.WIN_BACK_ID) == null);
    try testing.expect(gui.getWindow(gui_mod.WIN_STATUS_ID) == null);
    try testing.expectEqual(@as(usize, 4), win_menu_repop.icons.items.len);
}

test "diosix-gui: back menu item undecorated styling, arrow, and navigation" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // 1. Activate Status menu item.
    try gui.activateMenuItem(gui_mod.ICON_MENU_STATUS_ID);
    gui.completeNavAnimation();

    // 2. Verify WIN_BACK_ID contains an undecorated menu_item with back arrow.
    const win_back = gui.getWindow(gui_mod.WIN_BACK_ID).?;
    try testing.expectEqual(gui_mod.BACK_PANE_H, win_back.height);
    try testing.expectEqual(gui_mod.MENU_CONTRACTED_H, win_back.height);

    const back_item = win_back.getIconById(gui_mod.ICON_BACK_BTN_ID).?;
    try testing.expectEqual(icon_mod.IconType.menu_item, back_item.icon_type);
    try testing.expect(back_item.has_back_arrow);
    try testing.expectEqualStrings("Back", back_item.getText());

    // 3. Hovering over back menu item sets is_hovered.
    gui.handleMouseMove(
        win_back.x + back_item.rel_x + 5,
        win_back.y + back_item.rel_y + 5,
        false,
    );
    try testing.expect(back_item.is_hovered);

    // 4. Clicking triggers back navigation.
    gui.handleMouseClick(
        win_back.x + back_item.rel_x + 5,
        win_back.y + back_item.rel_y + 5,
    );
    gui.completeNavAnimation();
    try testing.expect(gui.getWindow(gui_mod.WIN_BACK_ID) == null);
    const menu_h = gui.getWindow(gui_mod.WIN_MENU_ID).?.height;
    try testing.expectEqual(gui_mod.MENU_FULL_H, menu_h);
}

test "diosix-gui: slider drag exclusivity prevents simultaneous slider moves" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // 1. Open Config pane.
    try gui.activateMenuItem(gui_mod.ICON_MENU_CONFIG_ID);
    gui.completeNavAnimation();

    const win_config = gui.getWindow(gui_mod.WIN_CONFIG_ID).?;
    const tr_id = gui_mod.ICON_CONFIG_TRANSPARENCY_SLIDER_ID;
    const bl_id = gui_mod.ICON_CONFIG_BLUR_SLIDER_ID;
    const trans_slider = win_config.getIconById(tr_id).?;
    const blur_slider = win_config.getIconById(bl_id).?;

    // Initial state: transparency slider at 30%, blur slider at 50%.
    try testing.expectEqual(@as(i32, 30), trans_slider.slider_val);
    try testing.expectEqual(@as(i32, 50), blur_slider.slider_val);

    // 2. Click on the Blur slider track.
    const blur_click_x = win_config.x + blur_slider.rel_x + 180;
    const blur_click_y = win_config.y + blur_slider.rel_y + 14;
    gui.handleMouseClick(blur_click_x, blur_click_y);

    // Blur slider updated, but Transparency slider remains unchanged at 30.
    const blur_val_after_click = blur_slider.slider_val;
    try testing.expect(blur_val_after_click != 50);
    try testing.expectEqual(@as(i32, 30), trans_slider.slider_val);
    try testing.expect(blur_slider.is_dragging_slider);
    try testing.expect(!trans_slider.is_dragging_slider);

    // 3. Drag mouse vertically UP into Transparency slider coordinates.
    const trans_y = win_config.y + trans_slider.rel_y + 14;
    const drag_x = win_config.x + blur_slider.rel_x + 50;
    gui.handleMouseMove(drag_x, trans_y, true);

    // ONLY Blur slider should update; Transparency slider MUST NOT MOVE!
    try testing.expect(blur_slider.slider_val < blur_val_after_click);
    try testing.expectEqual(@as(i32, 30), trans_slider.slider_val);
    try testing.expect(blur_slider.is_hovered);
    try testing.expect(!trans_slider.is_hovered);

    // 4. Release mouse button: ends drag.
    gui.handleMouseRelease();
    try testing.expect(!blur_slider.is_dragging_slider);
    try testing.expectEqual(@as(?usize, null), win_config.active_drag_icon_idx);
    try testing.expectEqual(@as(?u32, null), gui.active_drag_win_id);
    try testing.expectEqual(@as(i32, 30), trans_slider.slider_val);
}

test "diosix-gui: touch-first single-icon and single-window hit exclusivity" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // 1. Verify main menu items: touching Status item exclusively selects it.
    const win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    const status_item = win_menu.getIconById(gui_mod.ICON_MENU_STATUS_ID).?;
    const config_item = win_menu.getIconById(gui_mod.ICON_MENU_CONFIG_ID).?;

    const touch_x = win_menu.x + status_item.rel_x + 20;
    const touch_y = win_menu.y + status_item.rel_y + 10;

    gui.handleMouseMove(touch_x, touch_y, false);
    try testing.expect(status_item.is_hovered);
    try testing.expect(!config_item.is_hovered);

    gui.handleMouseClick(touch_x, touch_y);
    gui.completeNavAnimation();

    // Switch to Config pane to test multiple controls.
    try gui.activateMenuItem(gui_mod.ICON_MENU_CONFIG_ID);
    gui.completeNavAnimation();

    const win_config = gui.getWindow(gui_mod.WIN_CONFIG_ID).?;
    const tr_id = gui_mod.ICON_CONFIG_TRANSPARENCY_SLIDER_ID;
    const bl_id = gui_mod.ICON_CONFIG_BLUR_SLIDER_ID;
    const trans_slider = win_config.getIconById(tr_id).?;
    const blur_slider = win_config.getIconById(bl_id).?;

    // Touch on transparency slider.
    const trans_touch_x = win_config.x + trans_slider.rel_x + 100;
    const trans_touch_y = win_config.y + trans_slider.rel_y + 14;
    gui.handleMouseClick(trans_touch_x, trans_touch_y);

    // Only transparency slider is captured; blur slider is untouched.
    try testing.expect(trans_slider.is_dragging_slider);
    try testing.expect(!blur_slider.is_dragging_slider);
    try testing.expect(win_config.active_drag_icon_idx != null);
    const drag_idx = win_config.active_drag_icon_idx.?;
    try testing.expectEqual(tr_id, win_config.icons.items[drag_idx].id);

    gui.handleMouseRelease();
    try testing.expect(!trans_slider.is_dragging_slider);
    try testing.expect(!blur_slider.is_dragging_slider);
    try testing.expectEqual(@as(?usize, null), win_config.active_drag_icon_idx);
}

test "diosix-gui: background texture drift shifts across ticks" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // Verify initial drift position, default 50% speed, and valid direction.
    try testing.expectEqual(@as(i32, 0), gui.drift_x);
    try testing.expectEqual(@as(i32, 0), gui.drift_y);
    try testing.expectEqual(@as(u32, 50), gui.getBgAnimationSpeed());
    const initial_dir = gui.getDriftDirection();
    try testing.expect(@backingInt(initial_dir) < 4);

    // 1. When speed is 0% (stopped), no movement occurs across ticks.
    gui.setBgAnimationSpeed(0);
    gui.setDriftDirection(.left);
    gui.tick(gui_mod.DRIFT_INTERVAL_MS * 10);
    try testing.expectEqual(@as(i32, 0), gui.drift_x);
    try testing.expectEqual(@as(i32, 0), gui.drift_y);

    // 2. Test full speed (100%): 1 step per DRIFT_INTERVAL_MS (60ms).
    gui.setBgAnimationSpeed(100);
    gui.setDriftDirection(.left);
    gui.tick(gui_mod.DRIFT_INTERVAL_MS);
    try testing.expectEqual(@as(i32, -1), gui.drift_x);
    try testing.expectEqual(@as(i32, 0), gui.drift_y);
    try testing.expect(gui.isDirty());

    gui.setDriftDirection(.right);
    gui.tick(gui_mod.DRIFT_INTERVAL_MS * 2);
    try testing.expectEqual(@as(i32, 1), gui.drift_x);
    try testing.expectEqual(@as(i32, 0), gui.drift_y);

    gui.setDriftDirection(.up);
    gui.tick(gui_mod.DRIFT_INTERVAL_MS);
    try testing.expectEqual(@as(i32, 1), gui.drift_x);
    try testing.expectEqual(@as(i32, -1), gui.drift_y);

    gui.setDriftDirection(.down);
    gui.tick(gui_mod.DRIFT_INTERVAL_MS * 2);
    try testing.expectEqual(@as(i32, 1), gui.drift_x);
    try testing.expectEqual(@as(i32, 1), gui.drift_y);

    // 3. Test half speed (default 50%): takes 2x interval (120ms) for 1 step.
    gui.setBgAnimationSpeed(50);
    gui.setDriftDirection(.right);
    gui.tick(gui_mod.DRIFT_INTERVAL_MS);
    try testing.expectEqual(@as(i32, 1), gui.drift_x);
    gui.tick(gui_mod.DRIFT_INTERVAL_MS);
    try testing.expectEqual(@as(i32, 2), gui.drift_x);
}

test "diosix-gui: tapping contracted menu item does not trigger back nav" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // 1. Select Status menu item.
    try gui.activateMenuItem(gui_mod.ICON_MENU_STATUS_ID);
    gui.completeNavAnimation();

    const win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    try testing.expectEqual(gui_mod.MENU_CONTRACTED_H, win_menu.height);
    try testing.expect(gui.getWindow(gui_mod.WIN_STATUS_ID) != null);
    try testing.expect(gui.getWindow(gui_mod.WIN_BACK_ID) != null);

    const st_id = gui_mod.ICON_MENU_STATUS_ID;
    const contracted_item = win_menu.getIconById(st_id).?;
    try testing.expect(contracted_item.is_selected);

    // 2. Click/Tap the contracted menu item label directly.
    gui.handleMouseClick(
        win_menu.x + contracted_item.rel_x + 5,
        win_menu.y + contracted_item.rel_y + 5,
    );
    gui.handleMouseRelease();

    // Verify it did NOT navigate back.
    try testing.expectEqual(gui_mod.MENU_CONTRACTED_H, win_menu.height);
    try testing.expect(gui.getWindow(gui_mod.WIN_STATUS_ID) != null);
    try testing.expect(gui.getWindow(gui_mod.WIN_BACK_ID) != null);
    try testing.expectEqual(st_id, gui.active_menu_id.?);

    // 3. Click/Tap the separate Back button.
    const win_back = gui.getWindow(gui_mod.WIN_BACK_ID).?;
    const back_btn = win_back.getIconById(gui_mod.ICON_BACK_BTN_ID).?;
    gui.handleMouseClick(
        win_back.x + back_btn.rel_x + 5,
        win_back.y + back_btn.rel_y + 5,
    );
    gui.handleMouseRelease();
    gui.completeNavAnimation();

    // Verify Back button DID navigate back.
    try testing.expect(gui.getWindow(gui_mod.WIN_STATUS_ID) == null);
    try testing.expect(gui.getWindow(gui_mod.WIN_BACK_ID) == null);
    const win_menu_repop = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    try testing.expectEqual(gui_mod.MENU_FULL_H, win_menu_repop.height);
    try testing.expectEqual(@as(usize, 4), win_menu_repop.icons.items.len);
    try testing.expect(gui.active_menu_id == null);
    testing.refAllDecls(@This());
}
