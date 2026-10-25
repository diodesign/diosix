// Coordinator, Dynamic Window Lifecycle, and Telemetry Tests for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const testing = std.testing;
const fb = @import("../framebuffer.zig");
const font = @import("../font.zig");
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const icon_mod = @import("../icon.zig");
const Icon = icon_mod.Icon;
const host_info = @import("../host.zig");

test "diosix-gui: coordinator init, layout, and host telemetry panes" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // 1. Initial layout has 4 windows: Menu, Running Guests, Version, Help.
    try testing.expectEqual(@as(usize, 4), gui.windows.items.len);

    var win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    try testing.expect(win_menu.is_onscreen);
    try testing.expectEqual(gui_mod.BORDER_GAP, win_menu.x);
    try testing.expectEqual(gui_mod.BORDER_GAP, win_menu.y);
    try testing.expectEqual(@as(usize, 5), win_menu.icons.items.len);

    const item_create = &win_menu.icons.items[0];
    const item_status = &win_menu.icons.items[1];
    const item_config = &win_menu.icons.items[2];
    const item_restart = &win_menu.icons.items[3];
    const item_shutdown = &win_menu.icons.items[4];
    try testing.expectEqualStrings("Create VM", item_create.getText());
    try testing.expectEqualStrings("About", item_status.getText());
    try testing.expectEqualStrings("Config", item_config.getText());
    try testing.expectEqualStrings("Restart", item_restart.getText());
    try testing.expectEqualStrings("Shutdown", item_shutdown.getText());
    const menu_t = icon_mod.IconType.menu_item;
    try testing.expectEqual(menu_t, item_create.icon_type);
    try testing.expectEqual(menu_t, item_status.icon_type);
    try testing.expectEqual(menu_t, item_config.icon_type);
    try testing.expectEqual(menu_t, item_restart.icon_type);
    try testing.expectEqual(menu_t, item_shutdown.icon_type);

    // 2. Mouse hover over menu items sets is_hovered.
    gui.handleMouseMove(
        win_menu.x + item_status.rel_x + 5,
        win_menu.y + item_status.rel_y + 5,
        false,
    );
    try testing.expect(item_status.is_hovered);
    try testing.expect(!item_config.is_hovered);

    gui.handleMouseMove(
        win_menu.x + item_config.rel_x + 5,
        win_menu.y + item_config.rel_y + 5,
        false,
    );
    try testing.expect(!item_status.is_hovered);
    try testing.expect(item_config.is_hovered);

    // 3. Version pane in bottom-right corner.
    const win_ver = gui.getWindow(gui_mod.WIN_VERSION_ID).?;
    try testing.expect(win_ver.is_onscreen);
    try testing.expectEqual(@as(u32, 40), win_ver.height);
    const ver_w: i32 = @intCast(win_ver.width);
    const ver_h: i32 = @intCast(win_ver.height);
    try testing.expectEqual(1280 - ver_w - gui_mod.BORDER_GAP, win_ver.x);
    try testing.expectEqual(800 - ver_h - gui_mod.BORDER_GAP, win_ver.y);
    const ver_icon = win_ver.getIconById(gui_mod.ICON_VERSION_TEXT_ID).?;
    try testing.expect(std.mem.startsWith(u8, ver_icon.getText(), "diosix"));
    try testing.expect(!ver_icon.is_selectable);

    // 4. Active Help pane spanning remaining screen width with even spacing.
    const win_help = gui.getWindow(gui_mod.WIN_HELP_ID).?;
    try testing.expect(win_help.is_onscreen);
    try testing.expectEqual(@as(u32, 40), win_help.height);
    try testing.expectEqual(gui_mod.BORDER_GAP, win_help.x);
    try testing.expectEqual(win_ver.y, win_help.y);
    const help_w: i32 = @intCast(win_help.width);
    const gap = win_ver.x - (win_help.x + help_w);
    try testing.expectEqual(gui_mod.BORDER_GAP, gap);
    try testing.expectEqual(gui_mod.BORDER_GAP, 1280 - (win_ver.x + ver_w));

    const help_icon = win_help.getIconById(gui_mod.ICON_HELP_TEXT_ID).?;

    // 5. Active Help dynamic updates.
    gui.handleMouseMove(
        win_menu.x + item_status.rel_x + 5,
        win_menu.y + item_status.rel_y + 5,
        false,
    );
    try testing.expectEqualStrings(
        "View hypervisor footprint, host telemetry, and build information",
        help_icon.getText(),
    );

    gui.handleMouseMove(
        win_menu.x + item_config.rel_x + 5,
        win_menu.y + item_config.rel_y + 5,
        false,
    );
    try testing.expectEqualStrings(
        "Configure window transparency, color scheme, and display settings",
        help_icon.getText(),
    );

    gui.handleMouseMove(
        win_ver.x + ver_icon.rel_x + 5,
        win_ver.y + ver_icon.rel_y + 5,
        false,
    );
    try testing.expectEqualStrings(
        "Hypervisor name, version number, build branch, and commit hash",
        help_icon.getText(),
    );

    gui.handleMouseMove(50, 500, false);
    try testing.expectEqualStrings("Welcome to diosix", help_icon.getText());

    // 6. Clicking Status menu item opens the Status pane.
    gui.handleMouseClick(
        win_menu.x + item_status.rel_x + 5,
        win_menu.y + item_status.rel_y + 5,
    );
    gui.completeNavAnimation();

    const win_status = gui.getWindow(gui_mod.WIN_STATUS_ID).?;
    try testing.expect(win_status.is_onscreen);
    const exp_w: u32 = @intCast(1280 - gui_mod.BORDER_GAP - win_status.x);
    try testing.expectEqual(exp_w, win_status.width);

    const host_hdr_id = gui_mod.ICON_STATUS_HOST_HDR_ID;
    const status_host_hdr = win_status.getIconById(host_hdr_id).?;
    try testing.expectEqualStrings("Host", status_host_hdr.getText());

    const col1_right: i32 = 140;
    const col2_x: i32 = 160;

    const up_lbl_id = gui_mod.ICON_STATUS_HOST_UPTIME_LABEL_ID;
    const up_val_id = gui_mod.ICON_STATUS_HOST_UPTIME_ID;
    const lbl_uptime = win_status.getIconById(up_lbl_id).?;
    const val_uptime = win_status.getIconById(up_val_id).?;
    try testing.expectEqualStrings("Uptime", lbl_uptime.getText());
    const up_w: i32 = @intCast(font.measureString(lbl_uptime.getText()));
    try testing.expectEqual(col1_right, lbl_uptime.rel_x + up_w);
    try testing.expectEqual(col2_x, val_uptime.rel_x);
    try testing.expectEqual(lbl_uptime.rel_y, val_uptime.rel_y);

    const cpu_lbl_id = gui_mod.ICON_STATUS_HOST_CPU_LABEL_ID;
    const cpu_val_id = gui_mod.ICON_STATUS_HOST_CPU_ID;
    const lbl_cpu = win_status.getIconById(cpu_lbl_id).?;
    const val_cpu = win_status.getIconById(cpu_val_id).?;
    try testing.expectEqualStrings("CPU cores", lbl_cpu.getText());
    const cpu_w: i32 = @intCast(font.measureString(lbl_cpu.getText()));
    try testing.expectEqual(col1_right, lbl_cpu.rel_x + cpu_w);
    try testing.expectEqual(col2_x, val_cpu.rel_x);
    try testing.expectEqual(lbl_cpu.rel_y, val_cpu.rel_y);

    const ram_lbl_id = gui_mod.ICON_STATUS_HOST_RAM_LABEL_ID;
    const ram_val_id = gui_mod.ICON_STATUS_HOST_RAM_ID;
    const lbl_ram = win_status.getIconById(ram_lbl_id).?;
    const val_ram = win_status.getIconById(ram_val_id).?;
    try testing.expectEqualStrings("RAM", lbl_ram.getText());
    const ram_w: i32 = @intCast(font.measureString(lbl_ram.getText()));
    try testing.expectEqual(col1_right, lbl_ram.rel_x + ram_w);
    try testing.expectEqual(col2_x, val_ram.rel_x);
    try testing.expectEqual(lbl_ram.rel_y, val_ram.rel_y);

    const tm_lbl_id = gui_mod.ICON_STATUS_HOST_TIME_LABEL_ID;
    const tm_val_id = gui_mod.ICON_STATUS_HOST_TIME_ID;
    const lbl_time = win_status.getIconById(tm_lbl_id).?;
    const val_time = win_status.getIconById(tm_val_id).?;
    try testing.expectEqualStrings("Time and date", lbl_time.getText());
    const tm_w: i32 = @intCast(font.measureString(lbl_time.getText()));
    try testing.expectEqual(col1_right, lbl_time.rel_x + tm_w);
    try testing.expectEqual(col2_x, val_time.rel_x);
    try testing.expectEqual(lbl_time.rel_y, val_time.rel_y);

    const hv_hdr_id = gui_mod.ICON_STATUS_HV_HDR_ID;
    const status_hv_hdr = win_status.getIconById(hv_hdr_id).?;
    try testing.expectEqualStrings("Hypervisor", status_hv_hdr.getText());

    const bld_lbl_id = gui_mod.ICON_STATUS_HV_BUILD_LABEL_ID;
    const b1_id = gui_mod.ICON_STATUS_HV_BUILD1_ID;
    const b2_id = gui_mod.ICON_STATUS_HV_BUILD2_ID;
    const lbl_build = win_status.getIconById(bld_lbl_id).?;
    const val_b1 = win_status.getIconById(b1_id).?;
    const val_b2 = win_status.getIconById(b2_id).?;
    try testing.expectEqualStrings("Build", lbl_build.getText());
    const bld_w: i32 = @intCast(font.measureString(lbl_build.getText()));
    try testing.expectEqual(col1_right, lbl_build.rel_x + bld_w);
    try testing.expectEqual(col2_x, val_b1.rel_x);
    try testing.expectEqual(col2_x, val_b2.rel_x);
    try testing.expectEqual(lbl_build.rel_y, val_b1.rel_y);

    const ft_lbl_id = gui_mod.ICON_STATUS_HV_FOOTPRINT_LABEL_ID;
    const ft_val_id = gui_mod.ICON_STATUS_HV_FOOTPRINT_ID;
    const lbl_foot = win_status.getIconById(ft_lbl_id).?;
    const val_foot = win_status.getIconById(ft_val_id).?;
    try testing.expectEqualStrings("Footprint", lbl_foot.getText());
    const ft_w: i32 = @intCast(font.measureString(lbl_foot.getText()));
    try testing.expectEqual(col1_right, lbl_foot.rel_x + ft_w);
    try testing.expectEqual(col2_x, val_foot.rel_x);
    try testing.expectEqual(lbl_foot.rel_y, val_foot.rel_y);

    try testing.expectEqualStrings("--", val_cpu.getText());
    try testing.expectEqualStrings("--", val_ram.getText());
    try testing.expectEqualStrings("--", val_b1.getText());
    try testing.expectEqualStrings("--", val_foot.getText());

    gui.handleMouseMove(win_status.x + 10, win_status.y + 10, false);
    try testing.expectEqualStrings(
        "Information about this host system and hypervisor",
        help_icon.getText(),
    );

    const icon_status = win_menu.getIconById(gui_mod.ICON_MENU_STATUS_ID).?;
    try testing.expect(icon_status.is_selected);
    try testing.expect(gui.getWindow(gui_mod.WIN_BACK_ID) != null);
    try testing.expectEqual(gui_mod.MENU_CONTRACTED_H, win_menu.height);

    // 7. Clicking Back button returns to main menu and repopulates full menu.
    const win_back = gui.getWindow(gui_mod.WIN_BACK_ID).?;
    const back_btn = win_back.getIconById(gui_mod.ICON_BACK_BTN_ID).?;
    gui.handleMouseClick(
        win_back.x + back_btn.rel_x + 5,
        win_back.y + back_btn.rel_y + 5,
    );
    gui.completeNavAnimation();
    try testing.expect(gui.getWindow(gui_mod.WIN_STATUS_ID) == null);
    try testing.expect(gui.getWindow(gui_mod.WIN_BACK_ID) == null);
    try testing.expectEqual(gui_mod.MENU_FULL_H, win_menu.height);
    win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    try testing.expectEqual(@as(usize, 5), win_menu.icons.items.len);

    gui.handleMouseMove(50, 500, false);
    try testing.expectEqualStrings("Welcome to diosix", help_icon.getText());
}

test "diosix-gui: dynamic window lifecycle (create, destroy, destroyAll)" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const win = try gui.createWindow(501, 100, 100, 300, 200, "Dynamic Pane");
    try testing.expect(win.is_onscreen);
    try testing.expectEqual(@as(usize, 5), gui.windows.items.len);

    _ = try win.addIcon(Icon.createButton(5001, 10, 10, 100, 30, "Action"));
    try testing.expect(gui.getWindow(501) != null);

    const destroyed = gui.destroyWindow(501);
    try testing.expect(destroyed);
    try testing.expectEqual(@as(usize, 4), gui.windows.items.len);
    try testing.expect(gui.getWindow(501) == null);

    gui.destroyAllWindows();
    try testing.expectEqual(@as(usize, 0), gui.windows.items.len);
}

test "diosix-gui: left menu scrollable auto-activation on small screens" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 800, 70);
    defer gui.deinit();

    const win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    try testing.expect(win_menu.isScrollable());
    try testing.expect(win_menu.getMaxScroll() > 0);
}

test "diosix-gui: real-time window transparency and backdrop controls" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    try testing.expectEqual(@as(u32, 30), gui.window_transparency);
    try testing.expectEqual(@as(u8, 178), gui.getWindowOpacityAlpha());

    gui.setWindowTransparency(0);
    try testing.expectEqual(@as(u32, 0), gui.window_transparency);
    try testing.expectEqual(@as(u8, 255), gui.getWindowOpacityAlpha());

    gui.setWindowTransparency(80);
    try testing.expectEqual(@as(u32, 80), gui.window_transparency);
    try testing.expectEqual(@as(u8, 51), gui.getWindowOpacityAlpha());

    gui.setBackdropTopColor(0x00c86840);
    try testing.expectEqual(@as(u32, 0x00c86840), gui.bg_top_color);

    gui.setBackdropBotColor(0x00060b18);
    try testing.expectEqual(@as(u32, 0x00060b18), gui.bg_bot_color);
}

test "diosix-gui: intelligent damage tracking and idle frame skipping" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const clean_pixels = try allocator.alloc(u32, 1280 * 800);
    defer allocator.free(clean_pixels);
    const pitch = 1280 * @sizeOf(u32);
    var clean_surface = fb.Surface.init(clean_pixels.ptr, 1280, 800, pitch);

    try testing.expect(gui.isDirty());
    const init_damage = gui.renderDamaged(&clean_surface);
    try testing.expect(!init_damage.isEmpty());
    try testing.expect(!gui.isDirty());

    const idle_damage = gui.renderDamaged(&clean_surface);
    try testing.expect(idle_damage.isEmpty());

    gui.markWindowDirty(gui_mod.WIN_MENU_ID);
    try testing.expect(gui.isDirty());

    const partial_damage = gui.renderDamaged(&clean_surface);
    try testing.expect(!partial_damage.isEmpty());
    try testing.expect(!gui.isDirty());
}

test "diosix-gui: taller info panes and non-selectable icon text immunity" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const win_ver = gui.getWindow(gui_mod.WIN_VERSION_ID).?;
    const win_help = gui.getWindow(gui_mod.WIN_HELP_ID).?;
    const win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;

    try testing.expectEqual(@as(u32, 40), win_ver.height);
    try testing.expectEqual(@as(u32, 40), win_help.height);

    const ver_icon = win_ver.getIconById(gui_mod.ICON_VERSION_TEXT_ID).?;
    try testing.expectEqual(@as(u32, 24), ver_icon.height);
    try testing.expectEqual(@as(i32, 8), ver_icon.rel_y);
    try testing.expect(!ver_icon.is_selectable);

    const help_icon = win_help.getIconById(gui_mod.ICON_HELP_TEXT_ID).?;
    try testing.expectEqual(@as(u32, 24), help_icon.height);
    try testing.expectEqual(@as(i32, 8), help_icon.rel_y);
    try testing.expect(!help_icon.is_selectable);

    try testing.expect(win_menu.is_active);
    try testing.expect(!win_ver.is_active);
    try testing.expect(!win_help.is_active);
    try testing.expectEqual(@as(?usize, null), win_ver.focused_icon_idx);
    try testing.expectEqual(@as(?usize, null), win_help.focused_icon_idx);

    gui.handleMouseClick(win_ver.x + 20, win_ver.y + 20);
    try testing.expect(win_menu.is_active);
    try testing.expect(!win_ver.is_active);
    try testing.expect(!ver_icon.is_focused);
    try testing.expectEqual(@as(?usize, null), win_ver.focused_icon_idx);

    gui.handleMouseClick(win_help.x + 20, win_help.y + 20);
    try testing.expect(win_menu.is_active);
    try testing.expect(!win_help.is_active);
    try testing.expect(!help_icon.is_focused);
    try testing.expectEqual(@as(?usize, null), win_help.focused_icon_idx);

    gui.handleMouseMove(win_ver.x + 20, win_ver.y + 20, false);
    try testing.expect(!ver_icon.is_hovered);

    gui.handleMouseMove(win_help.x + 20, win_help.y + 20, false);
    try testing.expect(!help_icon.is_hovered);

    var btn = Icon.createButton(9999, 10, 10, 100, 30, "Click Me");
    try testing.expect(btn.is_selectable);
    try testing.expect(btn.hitTest(0, 0, 20, 20));

    btn.is_focused = true;
    btn.is_hovered = true;
    btn.setSelectable(false);
    try testing.expect(!btn.is_selectable);
    try testing.expect(!btn.is_focused);
    try testing.expect(!btn.is_hovered);
    try testing.expect(!btn.hitTest(0, 0, 20, 20));
}

test "diosix-gui: host_info hypervisor footprint format" {
    var mock_info = std.mem.zeroes(host_info.HypervisorInfo);
    mock_info.hv_reserved_bytes = 16 * 1024 * 1024;
    mock_info.hv_heap_free_bytes = 16580608;
    host_info.mock_hypervisor_info = mock_info;
    defer host_info.mock_hypervisor_info = null;

    var buf: [host_info.LABEL_BUF_BYTES]u8 = undefined;
    const str = host_info.getHvFootprintString(&buf);
    try testing.expectEqualStrings(
        "15.8 MB free of 16 MB reserved (98% free)",
        str,
    );
}

test "diosix-gui: input scaling and evdev absinfo calibration" {
    const main_mod = @import("../main.zig");
    const InputDeviceInfo = main_mod.InputDeviceInfo;
    // 1. Calibration with standard 0..4095 touchscreen.
    const touch_dev = InputDeviceInfo{
        .fd = 0,
        .min_x = 0,
        .max_x = 4095,
        .min_y = 0,
        .max_y = 4095,
        .has_abs = true,
    };
    try testing.expectEqual(@as(i32, 0), touch_dev.scaleX(0, 1920));
    try testing.expectEqual(@as(i32, 1919), touch_dev.scaleX(4095, 1920));
    try testing.expectEqual(@as(i32, 960), touch_dev.scaleX(2048, 1920));
    try testing.expectEqual(@as(i32, 0), touch_dev.scaleY(0, 1080));
    try testing.expectEqual(@as(i32, 1079), touch_dev.scaleY(4095, 1080));

    // 2. Calibration with standard tablet 0..32767.
    const tablet_dev = InputDeviceInfo{
        .fd = 1,
        .min_x = 0,
        .max_x = 32767,
        .min_y = 0,
        .max_y = 32767,
        .has_abs = true,
    };
    try testing.expectEqual(@as(i32, 0), tablet_dev.scaleX(0, 1280));
    try testing.expectEqual(@as(i32, 1279), tablet_dev.scaleX(32767, 1280));
    try testing.expectEqual(@as(i32, 640), tablet_dev.scaleX(16384, 1280));

    // 3. Out-of-bounds input clamping.
    try testing.expectEqual(@as(i32, 0), touch_dev.scaleX(-500, 1920));
    try testing.expectEqual(@as(i32, 1919), touch_dev.scaleX(10000, 1920));
    try testing.expectEqual(@as(i32, 0), touch_dev.scaleY(-100, 1080));
    try testing.expectEqual(@as(i32, 1079), touch_dev.scaleY(99999, 1080));

    // 4. Zero span fallback protection (prevents division by zero).
    const zero_span = InputDeviceInfo{
        .fd = 2,
        .min_x = 100,
        .max_x = 100,
        .min_y = 0,
        .max_y = 0,
    };
    try testing.expectEqual(@as(i32, 0), zero_span.scaleX(50, 1920));
    try testing.expectEqual(@as(i32, 0), zero_span.scaleY(50, 1080));
    testing.refAllDecls(@This());
}
