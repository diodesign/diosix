// VM Fleet, Catalog, Hardware, Power Modal, and OSK Tests for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const testing = std.testing;
const fb = @import("../framebuffer.zig");
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const icon_mod = @import("../icon.zig");
const Icon = icon_mod.Icon;
const host_info = @import("../host.zig");

test "diosix-gui: VM fleet overview, slate card selection, and action drawer" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // 1. Initially Fleet Overview and Action Drawer exist.
    const win_fleet = gui.getWindow(gui_mod.WIN_VM_FLEET_ID).?;
    var win_drawer = gui.getWindow(gui_mod.WIN_VM_DRAWER_ID).?;
    try testing.expect(win_fleet.is_onscreen);
    try testing.expect(win_drawer.is_onscreen);

    // Initial selected VM is alpine-router.
    try testing.expectEqual(gui_mod.ICON_VM_ALPINE_ID, gui.selected_vm_id);
    const alpine_card = win_fleet.getIconById(gui_mod.ICON_VM_ALPINE_ID).?;
    try testing.expect(alpine_card.is_selected);

    // 2. Select rootvm (Root VM supervisor).
    gui.selectVm(gui_mod.ICON_VM_ROOTVM_ID);
    win_drawer = gui.getWindow(gui_mod.WIN_VM_DRAWER_ID).?;
    try testing.expectEqual(gui_mod.ICON_VM_ROOTVM_ID, gui.selected_vm_id);

    const root_card = win_fleet.getIconById(gui_mod.ICON_VM_ROOTVM_ID).?;
    try testing.expect(root_card.is_selected);
    try testing.expect(root_card.card_is_supervisor);
    try testing.expectEqualStrings("Supervisor", root_card.getCardBadge());

    // Root VM drawer contains supervisor notice and NO force terminate button.
    const n1_id = gui_mod.ICON_DRAWER_NOTICE1_ID;
    const kill_id = gui_mod.ICON_DRAWER_BTN_KILL_ID;
    const stop_id = gui_mod.ICON_DRAWER_BTN_STOP_ID;
    const pause_id = gui_mod.ICON_DRAWER_BTN_PAUSE_ID;
    const cons_id = gui_mod.ICON_DRAWER_BTN_CONSOLE_ID;
    const snap_id = gui_mod.ICON_DRAWER_BTN_SNAP_ID;
    try testing.expect(win_drawer.getIconById(n1_id) != null);
    try testing.expect(win_drawer.getIconById(kill_id) == null);
    try testing.expect(win_drawer.getIconById(stop_id) == null);

    // 3. Switch back to child guest VM (alpine-router).
    gui.selectVm(gui_mod.ICON_VM_ALPINE_ID);
    win_drawer = gui.getWindow(gui_mod.WIN_VM_DRAWER_ID).?;
    try testing.expectEqual(gui_mod.ICON_VM_ALPINE_ID, gui.selected_vm_id);
    try testing.expect(alpine_card.is_selected);
    try testing.expect(!root_card.is_selected);

    // Child guest drawer has pause, stop, console, snapshot, and kill buttons.
    try testing.expect(win_drawer.getIconById(n1_id) == null);
    try testing.expect(win_drawer.getIconById(pause_id) != null);
    try testing.expect(win_drawer.getIconById(stop_id) != null);
    try testing.expect(win_drawer.getIconById(cons_id) != null);
    try testing.expect(win_drawer.getIconById(snap_id) != null);
    try testing.expect(win_drawer.getIconById(kill_id) != null);

    // 4. Test drawer actions dispatch help telemetry updates.
    const win_help = gui.getWindow(gui_mod.WIN_HELP_ID).?;
    const help_icon = win_help.getIconById(gui_mod.ICON_HELP_TEXT_ID).?;

    gui.handleVmAction(pause_id);
    try testing.expectEqualStrings(
        "Guest virtual CPU execution paused",
        help_icon.getText(),
    );

    gui.handleVmAction(stop_id);
    try testing.expectEqualStrings(
        "ACPI shutdown signal dispatched to guest",
        help_icon.getText(),
    );

    gui.handleVmAction(cons_id);
    try testing.expectEqualStrings(
        "Virtual serial console bridge connected",
        help_icon.getText(),
    );

    gui.handleVmAction(snap_id);
    try testing.expectEqualStrings(
        "Snapshot taken: RAM and disk checkpoint saved",
        help_icon.getText(),
    );

    gui.handleVmAction(kill_id);
    try testing.expectEqualStrings(
        "SIGKILL sent to guest VM container",
        help_icon.getText(),
    );

    // 5. Select frozen snapshot card (debian-snap-pre-upgrade).
    gui.selectVm(gui_mod.ICON_VM_SNAP_DEBIAN_ID);
    win_drawer = gui.getWindow(gui_mod.WIN_VM_DRAWER_ID).?;
    try testing.expectEqual(gui_mod.ICON_VM_SNAP_DEBIAN_ID, gui.selected_vm_id);

    // Snapshot drawer displays restore, clone, and delete buttons.
    const rest_id = gui_mod.ICON_DRAWER_BTN_RESTORE_ID;
    const clone_id = gui_mod.ICON_DRAWER_BTN_CLONE_ID;
    const del_id = gui_mod.ICON_DRAWER_BTN_DELETE_ID;
    try testing.expect(win_drawer.getIconById(rest_id) != null);
    try testing.expect(win_drawer.getIconById(clone_id) != null);
    try testing.expect(win_drawer.getIconById(del_id) != null);
    try testing.expect(win_drawer.getIconById(kill_id) == null);

    gui.handleVmAction(rest_id);
    try testing.expectEqualStrings(
        "Snapshot restored to running state",
        help_icon.getText(),
    );

    gui.handleVmAction(clone_id);
    try testing.expectEqualStrings(
        "Cloned snapshot to new VM instance",
        help_icon.getText(),
    );

    gui.handleVmAction(del_id);
    try testing.expectEqualStrings(
        "Item removed and storage reclaimed",
        help_icon.getText(),
    );
}

test "diosix-gui: Software pane with filter bar and image assets" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // 1. Activate Software menu item.
    try gui.activateMenuItem(gui_mod.ICON_MENU_SOFTWARE_ID);
    gui.completeNavAnimation();

    // Fleet Overview and Action Drawer are torn down.
    try testing.expect(gui.getWindow(gui_mod.WIN_VM_FLEET_ID) == null);
    try testing.expect(gui.getWindow(gui_mod.WIN_VM_DRAWER_ID) == null);

    // Software pane is active.
    const win_sw = gui.getWindow(gui_mod.WIN_SOFTWARE_ID).?;
    try testing.expect(win_sw.is_onscreen);
    try testing.expectEqualStrings("Software & images", win_sw.title.?);

    // Filter buttons exist.
    const f_all = gui_mod.ICON_SW_FILTER_ALL_ID;
    const f_man = gui_mod.ICON_SW_FILTER_MAN_ID;
    const f_dsk = gui_mod.ICON_SW_FILTER_DSK_ID;
    const f_img = gui_mod.ICON_SW_FILTER_IMG_ID;
    const b_imp = gui_mod.ICON_SW_BTN_IMPORT_ID;
    try testing.expect(win_sw.getIconById(f_all) != null);
    try testing.expect(win_sw.getIconById(f_man) != null);
    try testing.expect(win_sw.getIconById(f_dsk) != null);
    try testing.expect(win_sw.getIconById(f_img) != null);
    try testing.expect(win_sw.getIconById(b_imp) != null);

    // Software slate cards exist.
    const man_id = gui_mod.ICON_SW_ITEM_ALPINE_MAN_ID;
    const raw_id = gui_mod.ICON_SW_ITEM_ALPINE_RAW_ID;
    const c_man = win_sw.getIconById(man_id).?;
    try testing.expectEqualStrings("alpine-router.toml", c_man.getText());
    try testing.expectEqualStrings("Manifest", c_man.getCardBadge());

    const c_dsk = win_sw.getIconById(raw_id).?;
    try testing.expectEqualStrings("rootfs-alpine.raw", c_dsk.getText());
    try testing.expectEqualStrings("Virtual disk", c_dsk.getCardBadge());

    // 2. Click Back button restores Fleet Overview & Drawer.
    const win_back = gui.getWindow(gui_mod.WIN_BACK_ID).?;
    const back_btn = win_back.getIconById(gui_mod.ICON_BACK_BTN_ID).?;
    gui.handleMouseClick(
        win_back.x + back_btn.rel_x + 5,
        win_back.y + back_btn.rel_y + 5,
    );
    gui.completeNavAnimation();

    try testing.expect(gui.getWindow(gui_mod.WIN_SOFTWARE_ID) == null);
    try testing.expect(gui.getWindow(gui_mod.WIN_VM_FLEET_ID) != null);
    try testing.expect(gui.getWindow(gui_mod.WIN_VM_DRAWER_ID) != null);
}

test "diosix-gui: Hardware pane with physical and virtual peripherals" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // 1. Activate Hardware menu item.
    try gui.activateMenuItem(gui_mod.ICON_MENU_HARDWARE_ID);
    gui.completeNavAnimation();

    // Fleet Overview and Action Drawer are torn down.
    try testing.expect(gui.getWindow(gui_mod.WIN_VM_FLEET_ID) == null);
    try testing.expect(gui.getWindow(gui_mod.WIN_VM_DRAWER_ID) == null);

    // Hardware pane is active.
    const win_hw = gui.getWindow(gui_mod.WIN_HARDWARE_ID).?;
    try testing.expect(win_hw.is_onscreen);
    try testing.expectEqualStrings("Hardware & peripherals", win_hw.title.?);

    // Check peripheral slate cards.
    const c_eth = win_hw.getIconById(gui_mod.ICON_HW_ITEM_ETH0_ID).?;
    try testing.expect(std.mem.startsWith(u8, c_eth.getText(), "eth0"));
    try testing.expectEqualStrings("Ethernet", c_eth.getCardBadge());

    const c_br0 = win_hw.getIconById(gui_mod.ICON_HW_ITEM_BR0_ID).?;
    try testing.expect(std.mem.startsWith(u8, c_br0.getText(), "br0"));
    try testing.expectEqualStrings("Virtual bridge", c_br0.getCardBadge());

    const c_tpm = win_hw.getIconById(gui_mod.ICON_HW_ITEM_TPM_ID).?;
    try testing.expect(std.mem.startsWith(u8, c_tpm.getText(), "VirtIO TPM"));
    try testing.expectEqualStrings("Security", c_tpm.getCardBadge());

    const c_yubi = win_hw.getIconById(gui_mod.ICON_HW_ITEM_YUBIKEY_ID).?;
    try testing.expect(std.mem.startsWith(u8, c_yubi.getText(), "YubiKey 5"));
    try testing.expectEqualStrings("USB token", c_yubi.getCardBadge());

    const c_nvme = win_hw.getIconById(gui_mod.ICON_HW_ITEM_NVME_ID).?;
    try testing.expect(std.mem.startsWith(u8, c_nvme.getText(), "NVMe SSD"));
    try testing.expectEqualStrings("Storage", c_nvme.getCardBadge());

    const c_cpu = win_hw.getIconById(gui_mod.ICON_HW_ITEM_CPU_ID).?;
    const is_cpu = std.mem.startsWith(u8, c_cpu.getText(), "Host CPU Cores");
    try testing.expect(is_cpu);
    try testing.expectEqualStrings("Processor", c_cpu.getCardBadge());

    // 2. Click Back button restores Fleet Overview & Drawer.
    const win_back = gui.getWindow(gui_mod.WIN_BACK_ID).?;
    const back_btn = win_back.getIconById(gui_mod.ICON_BACK_BTN_ID).?;
    gui.handleMouseClick(
        win_back.x + back_btn.rel_x + 5,
        win_back.y + back_btn.rel_y + 5,
    );
    gui.completeNavAnimation();

    try testing.expect(gui.getWindow(gui_mod.WIN_HARDWARE_ID) == null);
    try testing.expect(gui.getWindow(gui_mod.WIN_VM_FLEET_ID) != null);
    try testing.expect(gui.getWindow(gui_mod.WIN_VM_DRAWER_ID) != null);
}

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

test "diosix-gui: slate card rendering and visual states" {
    const allocator = testing.allocator;
    const pixel_mem = try allocator.alloc(u32, 600 * 400);
    defer allocator.free(pixel_mem);
    var surface = fb.Surface.init(pixel_mem.ptr, 600, 400, 600 * @sizeOf(u32));
    @memset(pixel_mem, 0);

    var card = Icon.createSlateCard(
        999,
        20,
        20,
        300,
        56,
        "test-vm",
        "CID 2 | 2 vCPUs | 512 MB",
        "Running",
        fb.Color.ACCENT_GREEN,
    );
    try testing.expectEqual(icon_mod.IconType.slate_card, card.icon_type);
    try testing.expectEqualStrings("test-vm", card.getText());
    try testing.expectEqualStrings(
        "CID 2 | 2 vCPUs | 512 MB",
        card.getCardSubtitle(),
    );
    try testing.expectEqualStrings("Running", card.getCardBadge());
    try testing.expectEqual(fb.Color.ACCENT_GREEN, card.card_badge_color);

    // Test render in idle, hovered, and selected states.
    card.render(&surface, 0, 0, true);

    card.is_hovered = true;
    card.render(&surface, 0, 0, true);

    card.is_selected = true;
    card.render(&surface, 0, 0, true);
}

test "diosix-gui: VM fleet overview and action drawer sentence case" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // 1. Fleet Overview window title and create button in sentence case.
    const win_fleet = gui.getWindow(gui_mod.WIN_VM_FLEET_ID).?;
    try testing.expectEqualStrings("Virtual machines", win_fleet.title.?);

    const create_id = gui_mod.ICON_VM_CREATE_NEW_ID;
    const btn_create = win_fleet.getIconById(create_id).?;
    try testing.expectEqualStrings(
        "+ Create new virtual machine",
        btn_create.getText(),
    );

    // 2. VM badges in sentence case.
    const card_root = win_fleet.getIconById(gui_mod.ICON_VM_ROOTVM_ID).?;
    try testing.expectEqualStrings("Supervisor", card_root.getCardBadge());

    const card_alpine = win_fleet.getIconById(gui_mod.ICON_VM_ALPINE_ID).?;
    try testing.expectEqualStrings("Running", card_alpine.getCardBadge());

    const snap_vm_id = gui_mod.ICON_VM_SNAP_DEBIAN_ID;
    const card_snap = win_fleet.getIconById(snap_vm_id).?;
    try testing.expectEqualStrings("Snapshot", card_snap.getCardBadge());

    const card_netbsd = win_fleet.getIconById(gui_mod.ICON_VM_NETBSD_ID).?;
    try testing.expectEqualStrings("Stopped", card_netbsd.getCardBadge());

    // 3. Action Drawer window title and operation buttons in sentence case.
    const win_drawer = gui.getWindow(gui_mod.WIN_VM_DRAWER_ID).?;
    try testing.expectEqualStrings("VM controls", win_drawer.title.?);

    // Inspect buttons for running VM (alpine-router default selected).
    const stop_id = gui_mod.ICON_DRAWER_BTN_STOP_ID;
    const pause_id = gui_mod.ICON_DRAWER_BTN_PAUSE_ID;
    const snap_id = gui_mod.ICON_DRAWER_BTN_SNAP_ID;
    const cons_id = gui_mod.ICON_DRAWER_BTN_CONSOLE_ID;
    const kill_id = gui_mod.ICON_DRAWER_BTN_KILL_ID;
    const btn_stop = win_drawer.getIconById(stop_id).?;
    try testing.expectEqualStrings("Stop guest (ACPI)", btn_stop.getText());

    const btn_pause = win_drawer.getIconById(pause_id).?;
    try testing.expectEqualStrings("Pause execution", btn_pause.getText());

    const btn_snap = win_drawer.getIconById(snap_id).?;
    try testing.expectEqualStrings("Take snapshot", btn_snap.getText());

    const btn_cons = win_drawer.getIconById(cons_id).?;
    try testing.expectEqualStrings("Open console", btn_cons.getText());

    const btn_kill = win_drawer.getIconById(kill_id).?;
    try testing.expectEqualStrings("Force terminate", btn_kill.getText());

    // Switch to rootvm: verify supervisor protection buttons.
    gui.selectVm(gui_mod.ICON_VM_ROOTVM_ID);
    const win_root = gui.getWindow(gui_mod.WIN_VM_DRAWER_ID).?;
    const btn_uart = win_root.getIconById(cons_id).?;
    try testing.expectEqualStrings("Open serial console", btn_uart.getText());
    const btn_dump = win_root.getIconById(snap_id).?;
    try testing.expectEqualStrings("Capture core dump", btn_dump.getText());

    // Switch to snapshot: verify snapshot buttons.
    gui.selectVm(snap_vm_id);
    const win_snap = gui.getWindow(gui_mod.WIN_VM_DRAWER_ID).?;
    const rest_id = gui_mod.ICON_DRAWER_BTN_RESTORE_ID;
    const clone_id = gui_mod.ICON_DRAWER_BTN_CLONE_ID;
    const del_id = gui_mod.ICON_DRAWER_BTN_DELETE_ID;
    const btn_rest = win_snap.getIconById(rest_id).?;
    try testing.expectEqualStrings("Restore snapshot", btn_rest.getText());
    const btn_clone = win_snap.getIconById(clone_id).?;
    try testing.expectEqualStrings("Clone to new VM", btn_clone.getText());
    const btn_del = win_snap.getIconById(del_id).?;
    try testing.expectEqualStrings("Delete snapshot", btn_del.getText());
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
