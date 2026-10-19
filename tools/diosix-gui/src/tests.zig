// Core Unit Tests for Diosix Monolithic GUI (diosix-gui).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const testing = std.testing;
const fb = @import("framebuffer.zig");
const font = @import("font.zig");
const drm = @import("drm.zig");
const gui_mod = @import("gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const icon_mod = @import("icon.zig");
const Icon = icon_mod.Icon;
const window_mod = @import("window.zig");
const Window = window_mod.Window;
const intro_mod = @import("intro.zig");
const audio_mod = @import("audio.zig");
const noise_mod = @import("noise.zig");
const banner_font_mod = @import("font/banner.zig");
const host_info = @import("host.zig");
const cursor_mod = @import("cursor.zig");

test "diosix-gui: surface drawing and translucent window pane" {
    var pixel_buffer: [100 * 100]u32 = undefined;
    @memset(&pixel_buffer, 0x004c8be0);
    var surface = fb.Surface.init(&pixel_buffer, 100, 100, 400);

    const test_box = fb.Box.fromPosSize(10, 10, 80, 80);
    surface.drawWindowPane(test_box);

    // Check that inside client area is translucent blended with background.
    const client_pixel = surface.getPixel(50, 50);
    try testing.expect(client_pixel != 0x004c8be0);
    try testing.expect(client_pixel != fb.Color.GLASS_BG);

    // Outside corner should remain untouched background.
    const outside_corner = surface.getPixel(10, 10);
    try testing.expectEqual(@as(u32, 0x004c8be0), outside_corner);
}

test "diosix-gui: text rendering with drop shadow" {
    var pixel_buffer: [200 * 50]u32 = undefined;
    @memset(&pixel_buffer, 0);
    var surface = fb.Surface.init(&pixel_buffer, 200, 50, 800);

    font.drawTextWithShadow(
        &surface,
        "DIOSIX",
        10,
        10,
        fb.Color.WHITE,
        fb.Color.BLACK,
    );

    // Verify string width measurement.
    const measured_w = font.measureString("DIOSIX");
    try testing.expect(measured_w > 0);
}

test "diosix-gui: icon types, sliders, and editing" {
    var ic_ro = Icon.createReadOnly(1, 0, 0, 100, 20, "Read-Only");
    try testing.expectEqualStrings("Read-Only", ic_ro.getText());

    var ic_rw = Icon.createReadWrite(2, 0, 25, 100, 25, "Initial");
    ic_rw.insertChar('!');
    try testing.expectEqualStrings("Initial!", ic_rw.getText());
    ic_rw.deleteBackward();
    try testing.expectEqualStrings("Initial", ic_rw.getText());

    var ic_sl = Icon.createSlider(3, 0, 55, 120, 30, 0, 100, 50, "%");
    ic_sl.adjustSlider(10);
    try testing.expectEqual(@as(i32, 60), ic_sl.slider_val);
    ic_sl.adjustSlider(-100);
    try testing.expectEqual(@as(i32, 0), ic_sl.slider_val);
}

test "diosix-gui: icon grouping and exclusive radio behavior" {
    const allocator = testing.allocator;
    var win = Window.init(allocator, 1, 0, 0, 300, 300, "Group Test");
    defer win.deinit();

    const mode = icon_mod.GroupMode.exclusive;
    _ = try win.addIcon(
        Icon.createTickBox(10, 10, 10, 200, 24, "Option A", true, 1, mode),
    );
    _ = try win.addIcon(
        Icon.createTickBox(11, 10, 40, 200, 24, "Option B", false, 1, mode),
    );
    _ = try win.addIcon(
        Icon.createTickBox(12, 10, 70, 200, 24, "Option C", false, 1, mode),
    );

    try testing.expect(win.icons.items[0].is_ticked);
    try testing.expect(!win.icons.items[1].is_ticked);
    try testing.expect(!win.icons.items[2].is_ticked);

    var dummy_gui: usize = 0;
    win.triggerIcon(@ptrCast(&dummy_gui), &win.icons.items[1]);

    try testing.expect(!win.icons.items[0].is_ticked);
    try testing.expect(win.icons.items[1].is_ticked);
    try testing.expect(!win.icons.items[2].is_ticked);
}

test "diosix-gui: window offscreen parking and movement" {
    const allocator = testing.allocator;
    var win = Window.init(allocator, 42, 50, 60, 400, 300, "Window Move Test");
    defer win.deinit();

    try testing.expect(!win.is_onscreen);
    try testing.expect(win.x < 0);

    win.setOnScreen(true);
    try testing.expect(win.is_onscreen);
    try testing.expectEqual(@as(i32, 50), win.x);
    try testing.expectEqual(@as(i32, 60), win.y);

    win.setOnScreen(false);
    try testing.expect(!win.is_onscreen);
    try testing.expect(win.x < 0);
}

test "diosix-gui: static graduated background rendering" {
    var pixel_buffer: [100 * 100]u32 = undefined;
    var surface = fb.Surface.init(&pixel_buffer, 100, 100, 400);

    const top_col: u32 = 0x004c8be0;
    const bot_col: u32 = 0x000c1836;

    surface.drawGraduatedBackground(top_col, bot_col);

    const top_px = surface.getPixel(50, 0);
    const top_b = top_px & 0xff;
    try testing.expect(top_b >= 200);

    const bot_px = surface.getPixel(50, 99);
    const bot_b = bot_px & 0xff;
    try testing.expect(bot_b < 100);
}

test "diosix-gui: surface copyBoxFrom tile copying" {
    var src_pixels: [100 * 100]u32 = undefined;
    var dst_pixels: [100 * 100]u32 = undefined;

    @memset(&src_pixels, 0x00ff0000);
    @memset(&dst_pixels, 0x00000000);

    var src = fb.Surface.init(&src_pixels, 100, 100, 400);
    var dst = fb.Surface.init(&dst_pixels, 100, 100, 400);

    const copy_box = fb.Box.fromPosSize(20, 20, 40, 40);
    dst.copyBoxFrom(&src, copy_box);

    try testing.expectEqual(@as(u32, 0x00ff0000), dst.getPixel(30, 30));
    try testing.expectEqual(@as(u32, 0x00000000), dst.getPixel(10, 10));
    try testing.expectEqual(@as(u32, 0x00000000), dst.getPixel(70, 70));
}

test "diosix-gui: icon text selection, select-all, and cut/copy/paste" {
    var ic = Icon.createReadWrite(1, 0, 0, 200, 30, "Hello World");
    try testing.expectEqualStrings("Hello World", ic.getText());
    try testing.expect(!ic.hasSelection());

    ic.selection_start = 0;
    ic.selection_end = 5;
    try testing.expect(ic.hasSelection());
    try testing.expectEqualStrings("Hello", ic.getSelectedText());

    _ = ic.deleteSelection();
    try testing.expectEqualStrings(" World", ic.getText());
    try testing.expect(!ic.hasSelection());

    ic.insertString("Brave");
    try testing.expectEqualStrings("Brave World", ic.getText());

    ic.selectAll();
    try testing.expect(ic.hasSelection());
    try testing.expectEqualStrings("Brave World", ic.getSelectedText());

    ic.clearField();
    try testing.expectEqualStrings("", ic.getText());
    try testing.expectEqual(@as(usize, 0), ic.cursor_pos);
}

test "diosix-gui: mouse click and select dragging in text field" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const win = try gui.createWindow(201, 100, 100, 600, 400, "Drag Test Pane");
    const rw = Icon.createReadWrite(1, 10, 50, 400, 30, "Diosix Drag Test");
    const icon = try win.addIcon(rw);
    gui.focusWindow(gui.windows.items.len - 1);

    const click_x = win.x + icon.rel_x + 10;
    const click_y = win.y + icon.rel_y + 10;

    _ = win.handleMouseClick(@ptrCast(&gui), click_x, click_y);
    try testing.expect(icon.is_focused);
    try testing.expect(icon.is_dragging_select);
    try testing.expectEqual(@as(usize, 0), icon.selection_start.?);

    const drag_x = win.x + icon.rel_x + 80;
    _ = win.handleMouseMove(@ptrCast(&gui), drag_x, click_y, true);
    try testing.expect(icon.hasSelection());
    try testing.expect(icon.selection_end.? > 0);

    _ = win.handleMouseRelease();
    try testing.expect(!icon.is_dragging_select);
    try testing.expect(icon.hasSelection());

    _ = icon.deleteSelection();
    try testing.expect(!icon.hasSelection());
    try testing.expect(icon.getText().len < 16);
}

test "diosix-gui: action button selection via mouse click with feedback" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const win = try gui.createWindow(401, 50, 50, 300, 200, "Button Test Pane");
    var btn = Icon.createButton(1, 10, 45, 200, 30, "Action Button");

    const Handler = struct {
        var clicked_count: u32 = 0;
        fn onClick(_: *anyopaque, _: *anyopaque, _: *Icon) void {
            clicked_count += 1;
        }
    };
    Handler.clicked_count = 0;
    btn.callback = Handler.onClick;
    _ = try win.addIcon(btn);
    gui.focusWindow(gui.windows.items.len - 1);

    const btn_ref = &win.icons.items[0];

    // 1. Mouse click button.
    gui.handleMouseClick(win.x + btn_ref.rel_x + 5, win.y + btn_ref.rel_y + 5);
    try testing.expect(btn_ref.is_active_press);
    try testing.expectEqual(@as(u32, 1), Handler.clicked_count);

    // 2. Mouse release.
    gui.handleMouseRelease();
    try testing.expect(!btn_ref.is_active_press);
}

test "diosix-gui: graphical clipping of icons to bounding box" {
    const allocator = testing.allocator;
    const s_w: u32 = 200;
    const s_h: u32 = 100;
    const pixel_mem = try allocator.alloc(u32, s_w * s_h);
    defer allocator.free(pixel_mem);
    @memset(pixel_mem, 0);
    var surface = fb.Surface.init(pixel_mem.ptr, s_w, s_h, s_w * @sizeOf(u32));

    var label_icon = icon_mod.Icon.createReadOnly(
        1001,
        20,
        20,
        50,
        24,
        "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW",
    );
    label_icon.render(&surface, 0, 0, false);

    var inside_non_zero: usize = 0;
    var y: u32 = 20;
    while (y < 44) : (y += 1) {
        var x: u32 = 20;
        while (x < 70) : (x += 1) {
            if (pixel_mem[y * s_w + x] != 0) inside_non_zero += 1;
        }
    }
    try testing.expect(inside_non_zero > 0);

    y = 0;
    while (y < s_h) : (y += 1) {
        var x: u32 = 70;
        while (x < s_w) : (x += 1) {
            try testing.expectEqual(@as(u32, 0), pixel_mem[y * s_w + x]);
        }
    }
}

test "diosix-gui: graphical clipping inside button and editable text field" {
    const allocator = testing.allocator;
    const s_w: u32 = 180;
    const s_h: u32 = 80;
    const pixel_mem = try allocator.alloc(u32, s_w * s_h);
    defer allocator.free(pixel_mem);

    @memset(pixel_mem, 0);
    var surface = fb.Surface.init(pixel_mem.ptr, s_w, s_h, s_w * @sizeOf(u32));

    var btn = icon_mod.Icon.createButton(
        2001,
        10,
        10,
        60,
        30,
        "An Extremely Long Button Label That Exceeds Width",
    );
    btn.render(&surface, 0, 0, false);

    var y: u32 = 0;
    while (y < s_h) : (y += 1) {
        var x: u32 = 70;
        while (x < s_w) : (x += 1) {
            try testing.expectEqual(@as(u32, 0), pixel_mem[y * s_w + x]);
        }
    }
}

test "diosix-gui: Surface pushClip and popClip stack nesting" {
    const allocator = testing.allocator;
    const s_w: u32 = 100;
    const s_h: u32 = 100;
    const pixel_mem = try allocator.alloc(u32, s_w * s_h);
    defer allocator.free(pixel_mem);
    var surface = fb.Surface.init(pixel_mem.ptr, s_w, s_h, s_w * @sizeOf(u32));

    try testing.expectEqual(@as(i32, 0), surface.clip.x0);
    try testing.expectEqual(@as(i32, 100), surface.clip.x1);

    const clip1 = surface.pushClip(fb.Box.fromPosSize(10, 10, 50, 50));
    try testing.expectEqual(@as(i32, 10), surface.clip.x0);
    try testing.expectEqual(@as(i32, 60), surface.clip.x1);

    const clip2 = surface.pushClip(fb.Box.fromPosSize(30, 30, 50, 50));
    try testing.expectEqual(@as(i32, 30), surface.clip.x0);
    try testing.expectEqual(@as(i32, 60), surface.clip.x1);

    surface.popClip(clip2);
    try testing.expectEqual(@as(i32, 10), surface.clip.x0);
    try testing.expectEqual(@as(i32, 60), surface.clip.x1);

    surface.popClip(clip1);
    try testing.expectEqual(@as(i32, 0), surface.clip.x0);
    try testing.expectEqual(@as(i32, 100), surface.clip.x1);
}

test "diosix-gui: scrollable pane scrolling and bounds" {
    const allocator = testing.allocator;
    var win = Window.init(allocator, 999, 100, 100, 400, 300, "SCROLL TEST");
    defer win.deinit();
    win.setOnScreen(true);

    _ = try win.addIcon(Icon.createReadOnly(1, 20, 50, 360, 30, "Item 1"));
    _ = try win.addIcon(Icon.createReadOnly(2, 20, 150, 360, 30, "Item 2"));
    _ = try win.addIcon(Icon.createReadOnly(3, 20, 250, 360, 30, "Item 3"));
    _ = try win.addIcon(Icon.createReadOnly(4, 20, 350, 360, 30, "Item 4"));
    _ = try win.addIcon(Icon.createReadOnly(5, 20, 450, 360, 30, "Item 5"));

    try testing.expect(win.isScrollable());
    try testing.expectEqual(@as(i32, 190), win.getMaxScroll());

    _ = win.scrollBy(50);
    try testing.expectEqual(@as(i32, 50), win.scroll_y);

    _ = win.scrollBy(500);
    try testing.expectEqual(@as(i32, 190), win.scroll_y);

    _ = win.scrollBy(-500);
    try testing.expectEqual(@as(i32, 0), win.scroll_y);
}

test "diosix-gui: scrollbar proximity detection and auto-hiding fade" {
    const allocator = testing.allocator;
    var win = Window.init(allocator, 998, 100, 100, 400, 300, "PROXIMITY TEST");
    defer win.deinit();
    win.setOnScreen(true);

    _ = try win.addIcon(Icon.createReadOnly(1, 20, 50, 360, 30, "Item 1"));
    _ = try win.addIcon(Icon.createReadOnly(2, 20, 450, 360, 30, "Item 2"));

    const track = win.getScrollbarTrackBox();
    const near_x = track.x0 - 10;
    const near_y = track.y0 + 20;

    _ = win.handleMouseMove(undefined, near_x, near_y, false);
    try testing.expect(win.scrollbar_alpha > 0);

    const far_x = win.x + 20;
    const far_y = win.y + 20;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        _ = win.handleMouseMove(undefined, far_x, far_y, false);
    }
    try testing.expectEqual(@as(u8, 0), win.scrollbar_alpha);
}

test "diosix-gui: strict viewport clipping prevents overdrawing borders" {
    const allocator = testing.allocator;
    var win = Window.init(allocator, 997, 100, 100, 400, 300, "CLIP TEST");
    defer win.deinit();
    win.setOnScreen(true);

    _ = try win.addIcon(Icon.createReadOnly(1, 20, 50, 360, 30, "Item 1"));
    _ = try win.addIcon(Icon.createReadOnly(2, 20, 450, 360, 30, "Item 2"));

    _ = win.scrollTo(100);

    const pixel_mem = try allocator.alloc(u32, 600 * 500);
    defer allocator.free(pixel_mem);
    @memset(pixel_mem, 0);
    var surface = fb.Surface.init(pixel_mem.ptr, 600, 500, 600 * @sizeOf(u32));

    win.render(&surface, 255);

    var y: u32 = 0;
    while (y < 100) : (y += 1) {
        var x: u32 = 0;
        while (x < 600) : (x += 1) {
            try testing.expectEqual(@as(u32, 0), pixel_mem[y * 600 + x]);
        }
    }
}

test "diosix-gui: mouse wheel scroll navigation" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const win = try gui.createWindow(601, 50, 50, 400, 300, "Scroll Nav Test");
    _ = try win.addIcon(Icon.createReadOnly(1, 20, 50, 360, 30, "Item 1"));
    _ = try win.addIcon(Icon.createReadOnly(2, 20, 450, 360, 30, "Item 2"));
    gui.focusWindow(gui.windows.items.len - 1);

    try testing.expect(win.isScrollable());
    const max_s = win.getMaxScroll();
    try testing.expect(max_s > 0);

    // 1. Mouse wheel down -> scroll by 30.
    gui.handleMouseScroll(win.x + 50, win.y + 50, 1);
    try testing.expectEqual(@as(i32, 30), win.scroll_y);

    // 2. Mouse wheel up -> scroll back up.
    gui.handleMouseScroll(win.x + 50, win.y + 50, -1);
    try testing.expectEqual(@as(i32, 0), win.scroll_y);
}

test {
    testing.refAllDecls(@This());
    _ = drm;
    _ = intro_mod;
    _ = audio_mod;
    _ = noise_mod;
    _ = banner_font_mod;
    _ = host_info;
    _ = cursor_mod;
    _ = gui_mod.osk_mod;
    _ = gui_mod.welcome_mod;
    _ = @import("backdrop.zig");
    _ = @import("backdrop/blur.zig");
    _ = @import("display.zig");
    _ = @import("glass.zig");
    _ = @import("gui/chrome.zig");
    _ = @import("gui/input.zig");
    _ = @import("gui/nav.zig");
    _ = @import("gui/render.zig");
    _ = @import("icon/render.zig");
    _ = @import("icon/text.zig");
    _ = @import("icon/viewport.zig");
    _ = @import("icon/widgets.zig");
    _ = @import("intro/fx.zig");
    _ = @import("panes.zig");
    _ = @import("panes/catalog.zig");
    _ = @import("panes/modal.zig");
    _ = @import("panes/osk.zig");
    _ = @import("panes/vm.zig");
    _ = @import("window/input.zig");
    _ = @import("tests/gui.zig");
    _ = @import("tests/nav.zig");
    _ = @import("tests/panes.zig");
    _ = @import("tests/visual.zig");
}
