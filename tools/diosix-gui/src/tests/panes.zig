// Power Modal, Welcome Modal, Guided Tour, and OSK Tests for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const testing = std.testing;
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const host_info = @import("../host.zig");

test "diosix-gui: Restart and Shutdown power confirmation modals" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // 1. Click Restart opens Restart modal.
    try gui.activateMenuItem(gui_mod.ICON_MENU_RESTART_ID);
    var win_modal = gui.getWindow(gui_mod.WIN_POWER_MODAL_ID).?;
    try testing.expect(win_modal.is_onscreen);
    try testing.expect(win_modal.is_modal);
    try testing.expectEqualStrings("Restart host system", win_modal.title.?);
    const act1 = gui.power_modal_action.?;
    try testing.expectEqual(gui_mod.PowerAction.restart, act1);
    try testing.expect(!gui.power_action_confirmed);

    // Cancel dismisses modal.
    const cancel_btn = win_modal.getIconById(gui_mod.ICON_POWER_CANCEL_ID).?;
    gui.handleMouseClick(
        win_modal.x + cancel_btn.rel_x + 5,
        win_modal.y + cancel_btn.rel_y + 5,
    );
    try testing.expect(gui.getWindow(gui_mod.WIN_POWER_MODAL_ID) == null);
    try testing.expect(gui.power_modal_action == null);

    // 2. Click Shutdown opens Shutdown modal.
    try gui.activateMenuItem(gui_mod.ICON_MENU_SHUTDOWN_ID);
    win_modal = gui.getWindow(gui_mod.WIN_POWER_MODAL_ID).?;
    try testing.expect(win_modal.is_onscreen);
    try testing.expect(win_modal.is_modal);
    try testing.expectEqualStrings("Shut down host system", win_modal.title.?);
    const act2 = gui.power_modal_action.?;
    try testing.expectEqual(gui_mod.PowerAction.shutdown, act2);

    // Confirm executes power action via host_info.executePowerAction.
    host_info.mock_power_action = null;
    const confirm_btn = win_modal.getIconById(gui_mod.ICON_POWER_CONFIRM_ID).?;
    gui.handleMouseClick(
        win_modal.x + confirm_btn.rel_x + 5,
        win_modal.y + confirm_btn.rel_y + 5,
    );
    try testing.expect(gui.power_action_confirmed);
    try testing.expectEqual(
        gui_mod.PowerAction.shutdown,
        host_info.mock_power_action.?,
    );
    const msg1 = win_modal.getIconById(gui_mod.ICON_POWER_MSG1_ID).?;
    try testing.expectEqualStrings(
        "Shutting down host system...",
        msg1.getText(),
    );
}

test "diosix-gui: dockable OSK, Welcome modal, Guided Tour, and semantic JSON" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // 1. Toggle OSK via semantic trigger.
    try testing.expect(try gui.triggerSemanticAction("osk.show"));
    try testing.expect(gui.osk_state.visible);
    try testing.expect(gui.getWindow(gui_mod.WIN_OSK_ID) != null);

    // Click 'd' key on OSK window.
    var win_osk = gui.getWindow(gui_mod.WIN_OSK_ID).?;
    const key_d = win_osk.getIconById(gui_mod.ICON_OSK_KEY_BASE_ID + 12).?;
    gui.handleMouseClick(
        win_osk.x + key_d.rel_x + 4,
        win_osk.y + key_d.rel_y + 4,
    );
    try testing.expectEqualStrings("d", gui.osk_state.getInputText());

    // Verify Shift key updates OSK keycap labels to uppercase.
    gui.handleOskAction(gui_mod.ICON_OSK_KEY_BASE_ID + 19);
    win_osk = gui.getWindow(gui_mod.WIN_OSK_ID).?;
    const key_q = win_osk.getIconById(gui_mod.ICON_OSK_KEY_BASE_ID).?;
    try testing.expectEqualStrings("Q", key_q.getText());

    // Verify Symbols key updates OSK keycap labels and escapes quotes in JSON.
    gui.handleOskAction(gui_mod.ICON_OSK_KEY_BASE_ID + 28);
    win_osk = gui.getWindow(gui_mod.WIN_OSK_ID).?;
    const key_sym = win_osk.getIconById(gui_mod.ICON_OSK_KEY_BASE_ID).?;
    try testing.expectEqualStrings("1", key_sym.getText());
    gui.osk_state.applyAction(.{ .char = '"' });
    gui.osk_state.applyAction(.{ .char = '\\' });

    // 2. Open Welcome modal and start 5-step Guided Tour.
    try testing.expect(try gui.triggerSemanticAction("welcome.open"));
    try testing.expect(gui.getWindow(gui_mod.WIN_WELCOME_ID) != null);

    try testing.expect(try gui.triggerSemanticAction("tour.start"));
    try testing.expect(gui.getWindow(gui_mod.WIN_WELCOME_ID) == null);
    try testing.expect(gui.getWindow(gui_mod.WIN_TOUR_ID) != null);
    try testing.expectEqual(@as(usize, 0), gui.welcome_state.current_step);

    try testing.expect(try gui.triggerSemanticAction("tour.next"));
    try testing.expectEqual(@as(usize, 1), gui.welcome_state.current_step);

    const state_json = try gui.exportSemanticStateJson(testing.allocator);
    defer testing.allocator.free(state_json);
    const has_osk = std.mem.indexOf(u8, state_json, "\"osk_visible\":true");
    const has_inp = std.mem.indexOf(
        u8,
        state_json,
        "\"osk_input\":\"d\\\"\\\\\"",
    );
    const has_tour = std.mem.indexOf(u8, state_json, "\"tour_visible\":true");
    const has_step = std.mem.indexOf(u8, state_json, "\"tour_step\":2");
    try testing.expect(has_osk != null);
    try testing.expect(has_inp != null);
    try testing.expect(has_tour != null);
    try testing.expect(has_step != null);

    try testing.expect(try gui.triggerSemanticAction("tour.close"));
    try testing.expect(gui.getWindow(gui_mod.WIN_TOUR_ID) == null);
    try testing.expect(try gui.triggerSemanticAction("osk.hide"));
    try testing.expect(gui.getWindow(gui_mod.WIN_OSK_ID) == null);
    testing.refAllDecls(@This());
}

test "diosix-gui: semantic JSON keeps a maximal escaped OSK string" {
    var gui = try DiosixGui.init(testing.allocator, 1280, 800);
    defer gui.deinit();

    // Worst case: every OSK byte is a quote that doubles when escaped.
    const osk_max = gui_mod.osk_mod.MAX_OSK_BUFFER_LEN;
    for (0..osk_max) |_| {
        gui.osk_state.applyAction(.{ .char = '"' });
    }
    const json = try gui.exportSemanticStateJson(testing.allocator);
    defer testing.allocator.free(json);
    const escaped = try testing.allocator.alloc(u8, osk_max * 2);
    defer testing.allocator.free(escaped);
    for (0..osk_max) |i| @memcpy(escaped[i * 2 ..][0..2], "\\\"");
    try testing.expect(std.mem.indexOf(u8, json, escaped) != null);
    try testing.expect(std.mem.endsWith(u8, json, "}\n"));
}
