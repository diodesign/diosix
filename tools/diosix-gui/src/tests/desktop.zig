// Integration Tests for Guest VirtIO-GPU Desktop Window & Input Routing.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const testing = std.testing;
const fb = @import("../framebuffer.zig");
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const host_info = @import("../host.zig");
const desktop_input = @import("../panes/desktop/input.zig");

test "diosix-gui: guest desktop window scanout, input routing, and cleanup" {
    const allocator = testing.allocator;
    defer {
        host_info.guests.mock_running_guests = null;
        host_info.desktop.resetDesktopMocks();
    }

    var guests = [_]host_info.RunningGuest{
        .{ .cid = 1, .is_self = true, .vcpus = 4 },
        .{ .cid = 2, .is_self = false, .vcpus = 2 },
    };
    guests[0].setInstanceName("root");
    guests[0].setImageName("Linux");
    guests[1].setInstanceName("desktop-vm");
    guests[1].setImageName("debian-xfce.qcow2");
    host_info.guests.mock_running_guests = &guests;

    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // 1. Root VM detail pane does not expose a child guest display button.
    const win_guests = gui.getWindow(gui_mod.WIN_GUESTS_ID).?;
    const g0 = win_guests.getIconById(gui_mod.ICON_GUESTS_ITEM_BASE_ID).?;
    gui.handleMouseClick(
        win_guests.x + g0.rel_x + 10,
        win_guests.y + g0.rel_y + 10,
    );
    gui.handleMouseRelease();
    const root_detail = gui.getWindow(gui_mod.WIN_GUEST_DETAIL_ID).?;
    try testing.expect(
        root_detail.getIconById(gui_mod.ICON_GUEST_DISPLAY_ID) == null,
    );

    // 2. Child VM detail pane exposes "Open guest display".
    const g1 = win_guests.getIconById(gui_mod.ICON_GUESTS_ITEM_BASE_ID + 1).?;
    gui.handleMouseClick(
        win_guests.x + g1.rel_x + 10,
        win_guests.y + g1.rel_y + 10,
    );
    gui.handleMouseRelease();
    const child_detail = gui.getWindow(gui_mod.WIN_GUEST_DETAIL_ID).?;
    const disp_btn =
        child_detail.getIconById(gui_mod.ICON_GUEST_DISPLAY_ID).?;
    try testing.expectEqualStrings("Open guest display", disp_btn.getText());

    // 3. Clicking "Open guest display" transitions to WIN_GUEST_DISPLAY_ID.
    gui.handleMouseClick(
        child_detail.x + disp_btn.rel_x + 10,
        child_detail.y - child_detail.scroll_y + disp_btn.rel_y + 10,
    );
    gui.handleMouseRelease();
    gui.completeNavAnimation();

    try testing.expect(gui.desktop.active);
    try testing.expectEqual(@as(u64, 2), gui.desktop.target_cid);
    try testing.expect(gui.getWindow(gui_mod.WIN_GUESTS_ID) == null);
    const win_disp = gui.getWindow(gui_mod.WIN_GUEST_DISPLAY_ID).?;
    try testing.expect(win_disp.is_onscreen);

    const sem_json = try gui.exportSemanticStateJson(allocator);
    defer allocator.free(sem_json);
    try testing.expect(
        std.mem.indexOf(u8, sem_json, "\"active_pane\":\"guest_display\"") !=
            null,
    );

    const status_ic = win_disp.getIconById(gui_mod.ICON_DISP_STATUS_ID).?;
    try testing.expectEqualStrings(
        "desktop-vm (CID 2 - waiting for guest display)",
        status_ic.getText(),
    );

    // 4. Activate a 4x2 guest VirtIO-GPU scanout and render a frame.
    const scanout_px = [_]u32{
        0x00e63946, 0x00e63946, 0x002a9d8f, 0x002a9d8f,
        0x00e63946, 0x00e63946, 0x002a9d8f, 0x002a9d8f,
    };
    host_info.desktop.mock_scanout = .{
        .cid = 2,
        .width = 4,
        .height = 2,
        .active = true,
        .frame_seq = 1,
        .pixels = &scanout_px,
    };
    gui.tick(16);

    try testing.expect(gui.desktop.scanout_active);
    try testing.expectEqual(@as(u32, 4), gui.desktop.fb_width);
    try testing.expectEqual(@as(u32, 2), gui.desktop.fb_height);
    try testing.expectEqualStrings(
        "desktop-vm (CID 2 - 4x2 VirtIO-GPU)",
        win_disp.getIconById(gui_mod.ICON_DISP_STATUS_ID).?.getText(),
    );

    const surf_buf = try allocator.alloc(u32, 1280 * 800);
    defer allocator.free(surf_buf);
    @memset(surf_buf, 0);
    var surface = fb.Surface.init(surf_buf.ptr, 1280, 800, 1280 * @sizeOf(u32));
    gui.render(&surface);

    const vbox = gui.desktop.viewport_box;
    try testing.expect(!vbox.isEmpty());
    const left_sample = surface.getPixel(
        vbox.x0 + 8,
        vbox.y0 + @as(i32, @intCast(vbox.height() / 2)),
    );
    const right_sample = surface.getPixel(
        vbox.x1 - 8,
        vbox.y0 + @as(i32, @intCast(vbox.height() / 2)),
    );
    try testing.expectEqual(@as(u32, 0x00e63946), left_sample);
    try testing.expectEqual(@as(u32, 0x002a9d8f), right_sample);

    // 5. Pointer click, motion, right-click, scroll, and keyboard forwarding.
    const mid_x = vbox.x0 + @as(i32, @intCast(vbox.width() / 2));
    const mid_y = vbox.y0 + @as(i32, @intCast(vbox.height() / 2));
    gui.handleMouseClick(mid_x, mid_y);
    const click_batch = host_info.desktop.mock_last_input.?;
    try testing.expectEqual(@as(u64, 2), click_batch.target_cid);
    try testing.expectEqual(@as(usize, 4), click_batch.count);
    try testing.expectEqual(desktop_input.EV_ABS, click_batch.events[0].type);
    try testing.expectEqual(desktop_input.EV_KEY, click_batch.events[2].type);
    try testing.expectEqual(desktop_input.BTN_LEFT, click_batch.events[2].code);
    try testing.expectEqual(@as(u32, 1), click_batch.events[2].value);

    // Navigating Back while BTN_LEFT is held sends release and frees buffer.
    try gui.navigateBack();
    gui.completeNavAnimation();
    const rel_batch = host_info.desktop.mock_last_input.?;
    try testing.expectEqual(desktop_input.BTN_LEFT, rel_batch.events[0].code);
    try testing.expectEqual(@as(u32, 0), rel_batch.events[0].value);
    try testing.expect(!gui.desktop.active);
    try testing.expect(gui.desktop.frame_buf == null);

    // 6. Reopen desktop, forward raw physical Shift+key and unexpected VM exit.
    try gui.openGuestDesktop(2);
    gui.completeNavAnimation();
    gui.render(&surface);

    gui_mod.panes.handleEvdevKey(&gui, desktop_input.KEY_LEFTSHIFT, 1);
    try testing.expectEqual(
        desktop_input.KEY_LEFTSHIFT,
        host_info.desktop.mock_last_input.?.events[0].code,
    );
    gui.handleKeyChar('A');
    try testing.expectEqual(
        @as(usize, 6),
        host_info.desktop.mock_last_input.?.count,
    );
    gui.handleMouseScroll(mid_x, mid_y, -1);
    try testing.expectEqual(
        desktop_input.EV_REL,
        host_info.desktop.mock_last_input.?.events[0].type,
    );

    host_info.guests.mock_running_guests = guests[0..1];
    gui.updateGuestsPaneData();
    gui.completeNavAnimation();
    try testing.expect(!gui.desktop.active);
    try testing.expect(gui.getWindow(gui_mod.WIN_GUEST_DISPLAY_ID) == null);

    // 7. Zero-copy scanout + dirty rect + cursor overlay rendering.
    host_info.guests.mock_running_guests = &guests;
    gui.updateGuestsPaneData();
    try gui.openGuestDesktop(2);
    gui.completeNavAnimation();
    var cur_shape: [64]u32 = @splat(0);
    cur_shape[0] = 0xff00ff00; // bright green opaque cursor pixel at (0, 0)
    const zc_px = [_]u32{
        0x00112233, 0x00112233, 0x00112233, 0x00112233,
        0x00112233, 0x00112233, 0x00112233, 0x00112233,
    };
    host_info.desktop.mock_scanout = .{
        .cid = 2,
        .width = 4,
        .height = 2,
        .active = true,
        .zero_copy = true,
        .frame_seq = 10,
        .cursor_visible = true,
        .cursor_seq = 1,
        .cursor_x = 0,
        .cursor_y = 0,
        .cursor_w = 1,
        .cursor_h = 1,
        .cursor_pixels = &cur_shape,
        .pixels = &zc_px,
    };
    gui.tick(16);
    try testing.expect(gui.desktop.frame_buf == null);
    try testing.expect(gui.desktop.zero_copy_pixels != null);
    gui.render(&surface);
    const zb = gui.desktop.viewport_box;
    try testing.expectEqual(
        @as(u32, 0x0000ff00),
        surface.getPixel(zb.x0, zb.y0),
    );

    // Steady-state partial dirty update marks dirty box instead of full pane.
    try testing.expect(!gui.isDirty());
    host_info.desktop.mock_scanout.?.frame_seq = 11;
    host_info.desktop.mock_scanout.?.dirty_x = 2;
    host_info.desktop.mock_scanout.?.dirty_y = 1;
    host_info.desktop.mock_scanout.?.dirty_w = 2;
    host_info.desktop.mock_scanout.?.dirty_h = 1;
    gui.tick(16);
    try testing.expect(gui.desktop.has_dirty_rect);
    try testing.expect(gui.isDirty());

    testing.refAllDecls(@This());
}
