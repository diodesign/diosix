// Visual Verification, Config, and Screenshot Tests for Diosix Monolithic GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const fb = @import("../framebuffer.zig");
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const intro_mod = @import("../intro.zig");
const host_info = @import("../host.zig");

// Screenshots are capped at one framebuffer row's worth of pixels.
const PPM_MAX_WIDTH: usize = 1280;
const PPM_HEADER_MAX_BYTES: usize = "P6\n4294967295 4294967295\n255\n".len;

pub fn writePpmFile(surface: *const fb.Surface, path_z: [*:0]const u8) !void {
    const flags = linux.O{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .NOFOLLOW = true,
    };
    const rc = linux.open(path_z, flags, 0o600);
    const signed_rc: isize = @bitCast(rc);
    if (signed_rc < 0) return error.OpenFileFailed;
    const fd: i32 = @intCast(signed_rc);
    defer _ = linux.close(fd);

    const row_w: usize = @min(surface.width, PPM_MAX_WIDTH);
    // Longest header: two 10-digit u32 values (width is capped far below).
    var hdr_buf: [PPM_HEADER_MAX_BYTES]u8 = undefined;
    const hdr = std.fmt.bufPrint(
        &hdr_buf,
        "P6\n{d} {d}\n255\n",
        .{ row_w, surface.height },
    ) catch unreachable;
    _ = linux.write(fd, hdr.ptr, hdr.len);

    var rgb_row: [PPM_MAX_WIDTH * 3]u8 = undefined;
    var y: u32 = 0;
    while (y < surface.height) : (y += 1) {
        var x: u32 = 0;
        while (x < row_w) : (x += 1) {
            const px = surface.pixels[y * surface.stridePixels() + x];
            rgb_row[x * 3 + 0] = @intCast((px >> 16) & 0xff);
            rgb_row[x * 3 + 1] = @intCast((px >> 8) & 0xff);
            rgb_row[x * 3 + 2] = @intCast(px & 0xff);
        }
        _ = linux.write(fd, &rgb_row, row_w * 3);
    }
}

test "diosix-gui: optical glass pane lens highlights and superellipse" {
    const allocator = testing.allocator;
    const pixel_mem = try allocator.alloc(u32, 200 * 200);
    defer allocator.free(pixel_mem);

    @memset(pixel_mem, 0x00202020);
    var surface = fb.Surface.init(pixel_mem.ptr, 200, 200, 200 * @sizeOf(u32));

    const box = fb.Box{ .x0 = 20, .y0 = 20, .x1 = 180, .y1 = 180 };
    surface.drawGlassPane(box, 10, fb.Color.GLASS_BG, 200, null, true, true);

    const px_tl = surface.getPixel(20, 40);
    const px_tr = surface.getPixel(179, 40);
    try testing.expect(((px_tl >> 16) & 0xff) > ((px_tr >> 16) & 0xff));
    try testing.expect(((px_tl >> 8) & 0xff) > ((px_tr >> 8) & 0xff));
    try testing.expect((px_tl & 0xff) > (px_tr & 0xff));

    const px_br = surface.getPixel(179, 150);
    const px_bl = surface.getPixel(20, 150);
    try testing.expect((px_br & 0xff) > (px_bl & 0xff));
}

test "diosix-gui: subtle superellipse curvature on panes" {
    const allocator = testing.allocator;
    const pixel_mem = try allocator.alloc(u32, 100 * 100);
    defer allocator.free(pixel_mem);

    const bg_color: u32 = 0x00101010;
    const fill_color: u32 = 0x00e0e0e0;
    const box = fb.Box{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 100 };
    const radius: u32 = 16;

    @memset(pixel_mem, bg_color);
    var surface = fb.Surface.init(pixel_mem.ptr, 100, 100, 100 * @sizeOf(u32));
    surface.drawGlassPane(box, radius, fill_color, 255, null, false, false);
    try testing.expectEqual(bg_color, surface.getPixel(4, 4));

    @memset(pixel_mem, bg_color);
    surface.drawGlassPane(box, radius, fill_color, 255, null, false, true);
    try testing.expectEqual(fill_color, surface.getPixel(4, 4));
}

test "diosix-gui: config pane controls and dynamic appearance customization" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // 1. Open Config pane.
    try gui.activateMenuItem(gui_mod.ICON_MENU_CONFIG_ID);
    gui.completeNavAnimation();
    const win_config = gui.getWindow(gui_mod.WIN_CONFIG_ID).?;
    try testing.expect(win_config.is_onscreen);
    try testing.expectEqual(gui_mod.WIN_MENU_ID, win_config.parent_window_id.?);
    try testing.expectEqual(
        gui_mod.ICON_MENU_CONFIG_ID,
        win_config.linked_menu_item_id.?,
    );

    const win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    try testing.expectEqual(gui_mod.WIN_CONFIG_ID, win_menu.child_window_id.?);

    const cfg_item_id = gui_mod.ICON_MENU_CONFIG_ID;
    const icon_config_menu = win_menu.getIconById(cfg_item_id).?;
    try testing.expect(icon_config_menu.is_selected);
    try testing.expect(gui.getWindow(gui_mod.WIN_BACK_ID) != null);
    try testing.expectEqual(gui_mod.MENU_CONTRACTED_H, win_menu.height);

    // 2. Adjust Transparency slider.
    const tr_id = gui_mod.ICON_CONFIG_TRANSPARENCY_SLIDER_ID;
    const trans_slider = win_config.getIconById(tr_id).?;
    try testing.expectEqual(@as(u32, 30), gui.window_transparency);
    try testing.expectEqual(@as(i32, 30), trans_slider.slider_val);

    trans_slider.adjustSlider(10);
    if (trans_slider.callback) |cb| cb(&gui, win_config, trans_slider);
    try testing.expectEqual(@as(u32, 40), gui.window_transparency);
    try testing.expectEqual(@as(i32, 40), trans_slider.slider_val);

    // 3. Adjust Blur strength slider.
    const bl_id = gui_mod.ICON_CONFIG_BLUR_SLIDER_ID;
    const blur_slider = win_config.getIconById(bl_id).?;
    try testing.expectEqual(@as(u32, 50), gui.blur_strength);
    try testing.expectEqual(@as(i32, 50), blur_slider.slider_val);

    blur_slider.adjustSlider(-20);
    if (blur_slider.callback) |cb| cb(&gui, win_config, blur_slider);
    try testing.expectEqual(@as(u32, 30), gui.blur_strength);
    try testing.expectEqual(@as(i32, 30), blur_slider.slider_val);
    try testing.expectEqual(@as(u32, 3), gui.getBlurRadius());

    // 4. Adjust Background Animation Speed slider.
    const sp_id = gui_mod.ICON_CONFIG_SPEED_SLIDER_ID;
    const speed_slider = win_config.getIconById(sp_id).?;
    try testing.expectEqual(@as(u32, 50), gui.bg_animation_speed);
    try testing.expectEqual(@as(i32, 50), speed_slider.slider_val);

    speed_slider.adjustSlider(25);
    if (speed_slider.callback) |cb| cb(&gui, win_config, speed_slider);
    try testing.expectEqual(@as(u32, 75), gui.bg_animation_speed);
    try testing.expectEqual(@as(i32, 75), speed_slider.slider_val);

    speed_slider.setSliderValue(0);
    if (speed_slider.callback) |cb| cb(&gui, win_config, speed_slider);
    try testing.expectEqual(@as(u32, 0), gui.bg_animation_speed);
    try testing.expectEqual(@as(i32, 0), speed_slider.slider_val);
}

test "diosix-gui: GPU acceleration detection and degraded fallback mode" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const acc = gui_mod.RenderMode.accelerated;
    try testing.expectEqual(acc, gui.getRenderMode());

    gui.setRenderMode(.degraded);
    try testing.expectEqual(gui_mod.RenderMode.degraded, gui.getRenderMode());

    const prev_drift_x = gui.drift_x;
    const prev_drift_y = gui.drift_y;
    gui.tick(200);
    try testing.expectEqual(prev_drift_x, gui.drift_x);
    try testing.expectEqual(prev_drift_y, gui.drift_y);

    const pixel_mem = try allocator.alloc(u32, 1280 * 800);
    defer allocator.free(pixel_mem);
    const pitch = 1280 * @sizeOf(u32);
    var surface = fb.Surface.init(pixel_mem.ptr, 1280, 800, pitch);

    gui.markFullDirty();
    const damaged = gui.renderDamaged(&surface);
    try testing.expect(!damaged.isEmpty());
}

test "diosix-gui: render intro animation frames for the two warm moments" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const pixel_mem = try allocator.alloc(u32, 1280 * 800);
    defer allocator.free(pixel_mem);
    const pitch = 1280 * @sizeOf(u32);
    var surface = fb.Surface.init(pixel_mem.ptr, 1280, 800, pitch);

    var intro = intro_mod.IntroState.init(0);

    intro.elapsed_ms = 2100;
    intro.render(&surface, &gui);
    try writePpmFile(&surface, "/tmp/diosix_intro_moment1.ppm");

    intro.elapsed_ms = 4600;
    intro.render(&surface, &gui);
    try writePpmFile(&surface, "/tmp/diosix_intro_moment2.ppm");
}

test "diosix-gui: render dynamic layout screenshot for visual verification" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const pixel_mem = try allocator.alloc(u32, 1280 * 800);
    defer allocator.free(pixel_mem);
    const pitch = 1280 * @sizeOf(u32);
    var surface = fb.Surface.init(pixel_mem.ptr, 1280, 800, pitch);

    // 1. Mouse Mode: Hover mouse over "Hardware" menu item.
    const win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    const status_item = &win_menu.icons.items[1];
    gui.handleMouseMove(
        win_menu.x + status_item.rel_x + 10,
        win_menu.y + status_item.rel_y + 10,
        false,
    );

    gui.markFullDirty();
    _ = gui.renderDamaged(&surface);
    gui.cursor.draw(&surface);
    try writePpmFile(&surface, "/tmp/diosix_new_layout.ppm");
}

test "diosix-gui: render active help and status pane screenshots" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const pixel_mem = try allocator.alloc(u32, 1280 * 800);
    defer allocator.free(pixel_mem);
    const pitch = 1280 * @sizeOf(u32);
    var surface = fb.Surface.init(pixel_mem.ptr, 1280, 800, pitch);

    const win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    const about_item = &win_menu.icons.items[0];
    const config_item = &win_menu.icons.items[1];

    // 1. Mouse hover over first item: Active Help displays About help text.
    gui.handleMouseMove(
        win_menu.x + about_item.rel_x + 15,
        win_menu.y + about_item.rel_y + 15,
        false,
    );
    gui.markFullDirty();
    _ = gui.renderDamaged(&surface);
    gui.cursor.draw(&surface);
    try writePpmFile(&surface, "/tmp/diosix_help_guests.ppm");

    // 2. Mouse hover over second item: Active Help displays Config help text.
    gui.handleMouseMove(
        win_menu.x + config_item.rel_x + 15,
        win_menu.y + config_item.rel_y + 15,
        false,
    );
    gui.markFullDirty();
    _ = gui.renderDamaged(&surface);
    gui.cursor.draw(&surface);
    try writePpmFile(&surface, "/tmp/diosix_help_status.ppm");

    // 3. Click About to open status pane (fallback renders clean '--' values).
    gui.handleMouseClick(
        win_menu.x + about_item.rel_x + 15,
        win_menu.y + about_item.rel_y + 15,
    );
    gui.completeNavAnimation();
    gui.markFullDirty();
    _ = gui.renderDamaged(&surface);
    gui.cursor.draw(&surface);
    try writePpmFile(&surface, "/tmp/diosix_status_pane_fallback.ppm");

    // 4. Populate with live Hypervisor telemetry.
    var mock_info = std.mem.zeroes(host_info.HypervisorInfo);
    mock_info.version_major = 26;
    mock_info.version_minor = 1;
    mock_info.host_physical_cores = 4;
    mock_info.host_total_ram_kb = 16 * 1024 * 1024;
    mock_info.host_free_ram_kb = 9 * 1024 * 1024;
    mock_info.hv_reserved_bytes = 16 * 1024 * 1024;
    mock_info.hv_heap_free_bytes = 16580608;
    const isa_src = "RV64IMAFDC";
    @memcpy(mock_info.host_cpu_isa[0..isa_src.len], isa_src);
    const commit_src = "760a3d7";
    @memcpy(mock_info.build_commit[0..commit_src.len], commit_src);
    const desc_src = "Version 26.1 (beta) guestdev/760a3d7 Wed Sep 16 " ++
        "12:48:32 AM PDT 2026 chris@violet " ++
        "(Zig 0.17.0-dev.648+8d1b6e339 riscv64)";
    @memcpy(mock_info.build_desc[0..desc_src.len], desc_src);

    host_info.mock_hypervisor_info = mock_info;
    defer host_info.mock_hypervisor_info = null;

    gui.updateStatusPaneData();
    gui.markFullDirty();
    _ = gui.renderDamaged(&surface);
    gui.cursor.draw(&surface);
    try writePpmFile(&surface, "/tmp/diosix_status_pane.ppm");
    try writePpmFile(&surface, "/tmp/diosix_status_pane_table.ppm");

    // 5. Open Config pane and export visual verification screenshot.
    try gui.activateMenuItem(gui_mod.ICON_MENU_CONFIG_ID);
    gui.completeNavAnimation();
    gui.markFullDirty();
    _ = gui.renderDamaged(&surface);
    try writePpmFile(&surface, "/tmp/diosix_config_pane.ppm");
}

test "diosix-gui: render power modal and config pane screenshots" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const pixel_mem = try allocator.alloc(u32, 1280 * 800);
    defer allocator.free(pixel_mem);
    const pitch = 1280 * @sizeOf(u32);
    var surface = fb.Surface.init(pixel_mem.ptr, 1280, 800, pitch);

    // 1. Open Restart power modal and render.
    try gui.activateMenuItem(gui_mod.ICON_MENU_RESTART_ID);
    gui.markFullDirty();
    _ = gui.renderDamaged(&surface);
    gui.cursor.draw(&surface);
    try writePpmFile(&surface, "/tmp/diosix_restart_modal.ppm");

    // 2. Dismiss modal, open Config pane and render.
    gui.closePowerModal();
    try gui.activateMenuItem(gui_mod.ICON_MENU_CONFIG_ID);
    gui.completeNavAnimation();
    gui.markFullDirty();
    _ = gui.renderDamaged(&surface);
    gui.cursor.draw(&surface);
    try writePpmFile(&surface, "/tmp/diosix_config_pane.ppm");
    testing.refAllDecls(@This());
}
