// Power Modal, Welcome Modal, Guided Tour, and OSK Tests for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const testing = std.testing;
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const host_info = @import("../host.zig");
const font = @import("../font.zig");

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

test "diosix-gui: Config resolution, color depth, and UI scale dropdowns" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    try gui.activateMenuItem(gui_mod.ICON_MENU_CONFIG_ID);
    gui.completeNavAnimation();

    var win_cfg = gui.getWindow(gui_mod.WIN_CONFIG_ID).?;
    const res_drop = win_cfg.getIconById(gui_mod.ICON_CONFIG_RES_DROPDOWN_ID).?;
    try testing.expectEqualStrings("1280x800 (WXGA)", res_drop.getText());

    // 1. Open Resolution dropdown and select 1920x1080 (index 5).
    gui.handleMouseClick(
        win_cfg.x + res_drop.rel_x + 10,
        win_cfg.y + res_drop.rel_y + 10,
    );
    gui.handleMouseRelease();
    const pop_res = gui.getWindow(gui_mod.WIN_SCHEME_DROPDOWN_ID).?;
    try testing.expectEqual(@as(usize, 8), pop_res.icons.items.len);
    const fhd_opt = &pop_res.icons.items[5];
    gui.handleMouseClick(
        pop_res.x + fhd_opt.rel_x + 10,
        pop_res.y + fhd_opt.rel_y + 10,
    );
    gui.handleMouseRelease();

    try testing.expectEqual(@as(u32, 1920), gui.width);
    try testing.expectEqual(@as(u32, 1080), gui.height);
    try testing.expect(gui.display_reconfig_pending);

    // 2. Open Color depth dropdown and select 16-bit RGB565 (index 1).
    win_cfg = gui.getWindow(gui_mod.WIN_CONFIG_ID).?;
    const depth_drop =
        win_cfg.getIconById(gui_mod.ICON_CONFIG_DEPTH_DROPDOWN_ID).?;
    gui.handleMouseClick(
        win_cfg.x + depth_drop.rel_x + 10,
        win_cfg.y - win_cfg.scroll_y + depth_drop.rel_y + 10,
    );
    gui.handleMouseRelease();
    const pop_depth = gui.getWindow(gui_mod.WIN_SCHEME_DROPDOWN_ID).?;
    try testing.expectEqual(@as(usize, 4), pop_depth.icons.items.len);
    const opt_16bit = &pop_depth.icons.items[1];
    gui.handleMouseClick(
        pop_depth.x + opt_16bit.rel_x + 10,
        pop_depth.y + opt_16bit.rel_y + 10,
    );
    gui.handleMouseRelease();
    try testing.expectEqual(gui_mod.ColorDepth.bpp16, gui.color_depth);

    // 3. Test UI scale override (150%).
    try gui.setUiScaleMode(.pct_150);
    try testing.expectEqual(@as(u32, 150), gui.getEffectiveScalePercent());
}

test "diosix-gui: popup opacity and modal dynamic text-fitting and wrapping" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1920, 1080);
    defer gui.deinit();

    // Context/dropdown menus should have 20% of pane transparency.
    gui.setWindowTransparency(50);
    try testing.expectEqual(@as(u8, 127), gui.getWindowOpacityAlpha());
    // 50% / 5 = 10% transparency -> 90% opacity (229/255).
    try testing.expectEqual(@as(u8, 229), gui.getPopupOpacityAlpha());

    // At 1920x1080 and 200% scale, power modal expands to fit text on 1 line.
    try gui.setUiScaleMode(.pct_200);
    try gui.showPowerModal(.shutdown);
    var pwin = gui.getWindow(gui_mod.WIN_POWER_MODAL_ID).?;
    const msg2 = pwin.getIconById(gui_mod.ICON_POWER_MSG2_ID).?;
    try testing.expect(pwin.width > 520);
    try testing.expect(msg2.width >= font.measureString(msg2.getText()));

    // At 800x600 and 200% scale, power modal clamps width and wraps text.
    try gui.setResolutionPreset(.r800x600);
    pwin = gui.getWindow(gui_mod.WIN_POWER_MODAL_ID).?;
    const msg2_wrapped = pwin.getIconById(gui_mod.ICON_POWER_MSG2_ID).?;
    try testing.expect(pwin.width <= 800);
    try testing.expect(msg2_wrapped.wrap_text);
    try testing.expect(msg2_wrapped.height > font.getActiveLineHeight());
}

test "diosix-gui: config bottom gap, about build wrap, and 75% sliders" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // 1. At 75%..200% scale, sliders and dropdowns are vertically aligned with
    // their labels and slider thumbs fit completely inside slider height.
    for ([_]gui_mod.UiScaleMode{ .pct_75, .pct_100, .pct_150, .pct_200 }) |m| {
        try gui.setUiScaleMode(m);
        if (gui.getWindow(gui_mod.WIN_CONFIG_ID) == null) {
            try gui.toggleConfigPane();
        }
        const wc = gui.getWindow(gui_mod.WIN_CONFIG_ID).?;
        const tr_lbl =
            wc.getIconById(gui_mod.ICON_CONFIG_TRANSPARENCY_LBL_ID).?;
        const tr_sld =
            wc.getIconById(gui_mod.ICON_CONFIG_TRANSPARENCY_SLIDER_ID).?;
        try testing.expectEqual(tr_lbl.rel_y, tr_sld.rel_y);
        try testing.expectEqual(tr_lbl.height, tr_sld.height);

        const res_lbl = wc.getIconById(gui_mod.ICON_CONFIG_RES_LBL_ID).?;
        const res_dd = wc.getIconById(gui_mod.ICON_CONFIG_RES_DROPDOWN_ID).?;
        try testing.expectEqual(res_lbl.rel_y, res_dd.rel_y);
        try testing.expectEqual(res_lbl.height, res_dd.height);

        const lh = font.getActiveLineHeight();
        const thumb_h: u32 = @max(10, (lh * 14 + 9) / 18);
        try testing.expect(tr_sld.height >= thumb_h + 4);
    }

    // 2. At 150% and 200% scale on 1280x800, bottom gap below UI scale scales.
    try gui.setUiScaleMode(.pct_150);
    var win_cfg = gui.getWindow(gui_mod.WIN_CONFIG_ID).?;
    const scale_150 =
        win_cfg.getIconById(gui_mod.ICON_CONFIG_SCALE_DROPDOWN_ID).?;
    const bot_150 = scale_150.rel_y + @as(i32, @intCast(scale_150.height));
    try testing.expectEqual(
        @as(i32, @intCast(gui.scalePx(32))),
        win_cfg.getContentHeight() - bot_150,
    );

    try gui.setUiScaleMode(.pct_200);
    win_cfg = gui.getWindow(gui_mod.WIN_CONFIG_ID).?;
    const scale_200 =
        win_cfg.getIconById(gui_mod.ICON_CONFIG_SCALE_DROPDOWN_ID).?;
    const bot_200 = scale_200.rel_y + @as(i32, @intCast(scale_200.height));
    try testing.expectEqual(
        @as(i32, @intCast(gui.scalePx(32))),
        win_cfg.getContentHeight() - bot_200,
    );

    try gui.setResolutionPreset(.r800x600);
    win_cfg = gui.getWindow(gui_mod.WIN_CONFIG_ID).?;
    try testing.expect(win_cfg.isScrollable());
    try testing.expectEqual(
        @as(i32, @intCast(gui.scalePx(32))),
        win_cfg.getContentHeight() - bot_200,
    );
    try gui.setResolutionPreset(.r1280x800);

    // 3. About (Status) pane wraps long Build string and pushes Footprint down.
    var mock_info = std.mem.zeroes(host_info.HypervisorInfo);
    mock_info.version_major = 26;
    mock_info.version_minor = 1;
    mock_info.hv_reserved_bytes = 221 * 1024;
    mock_info.hv_heap_free_bytes = 128 * 1024;
    const long_desc =
        "Version 26.1 (beta) oct26-review/33f4966 " ++
        "Fri Oct 23 04:41:34 AM PDT 2026 chris@workstation " ++
        "(Zig 0.17.0 riscv64)";
    @memcpy(mock_info.build_desc[0..long_desc.len], long_desc);
    host_info.mock_hypervisor_info = mock_info;
    defer host_info.mock_hypervisor_info = null;

    try gui.toggleStatusPane();
    const win_st = gui.getWindow(gui_mod.WIN_STATUS_ID).?;
    const b1 = win_st.getIconById(gui_mod.ICON_STATUS_HV_BUILD1_ID).?;
    const b2 = win_st.getIconById(gui_mod.ICON_STATUS_HV_BUILD2_ID).?;
    const fp = win_st.getIconById(gui_mod.ICON_STATUS_HV_FOOTPRINT_ID).?;
    try testing.expect(b1.wrap_text);
    try testing.expect(b1.height > gui.scalePx(20));
    try testing.expect(b2.rel_y >= b1.rel_y + @as(i32, @intCast(b1.height)));
    try testing.expect(fp.rel_y >= b2.rel_y + @as(i32, @intCast(b2.height)));
}
