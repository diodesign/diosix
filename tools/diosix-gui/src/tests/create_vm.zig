// Unit Tests for Create VM Menu Item, Image Selection, and Configuration Panes.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const testing = std.testing;
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const host_info = @import("../host.zig");
const panes = @import("../panes.zig");
const fb = @import("../framebuffer.zig");

test "diosix-gui: Create VM menu spacing, image selection, and VM creation" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    var mock_hv = std.mem.zeroes(host_info.HypervisorInfo);
    mock_hv.host_physical_cores = 8;
    mock_hv.host_total_ram_kb = 4096 * 1024;
    mock_hv.host_free_ram_kb = 2048 * 1024;
    host_info.mock_hypervisor_info = mock_hv;
    defer host_info.mock_hypervisor_info = null;

    var mock_imgs: [1]host_info.VmImageEntry = .{.{}};
    mock_imgs[0].setTitle("Diosix Base Linux");
    mock_imgs[0].setFilename("diosix-base-linux.elf");
    mock_imgs[0].setPath("/var/lib/diosix/images/diosix-base-linux.elf");
    mock_imgs[0].size_bytes = 28 * 1024 * 1024;
    mock_imgs[0].default_vcpus = 2;
    mock_imgs[0].default_ram_mb = 512;
    host_info.images.mock_available_images = &mock_imgs;
    defer host_info.images.mock_available_images = null;

    var mock_st: [2]host_info.StorageOption = .{ .{}, .{} };
    mock_st[0].setLabel("None");
    mock_st[0].setPath("");
    mock_st[1].setLabel("data.raw (1 GB)");
    mock_st[1].setPath("/var/lib/diosix/disks/data.raw");
    host_info.images.mock_available_storage = &mock_st;
    defer host_info.images.mock_available_storage = null;

    host_info.images.mock_last_created_vm = null;
    defer host_info.images.mock_last_created_vm = null;

    // 1. Verify "Create VM" is at the top of the main menu with 14px spacing
    // below it, matching the 14px spacing below "Config" before "Restart".
    const win_menu = gui.getWindow(gui_mod.WIN_MENU_ID).?;
    try testing.expectEqual(@as(usize, 5), win_menu.icons.items.len);
    const item_create = &win_menu.icons.items[0];
    const item_about = &win_menu.icons.items[1];
    const item_config = &win_menu.icons.items[2];
    const item_restart = &win_menu.icons.items[3];

    try testing.expectEqualStrings("Create VM", item_create.getText());
    const gap_below_create = item_about.rel_y -
        (item_create.rel_y + @as(i32, @intCast(item_create.height)));
    const gap_below_config = item_restart.rel_y -
        (item_config.rel_y + @as(i32, @intCast(item_config.height)));
    try testing.expectEqual(@as(i32, 14), gap_below_create);
    try testing.expectEqual(gap_below_config, gap_below_create);

    // 2. Click "Create VM": opens WIN_CREATE_VM_ID with half available width.
    gui.handleMouseClick(
        win_menu.x + item_create.rel_x + 5,
        win_menu.y + item_create.rel_y + 5,
    );
    gui.handleMouseRelease();
    gui.completeNavAnimation();

    const geom = panes.computeGuestPaneGeometry(&gui);
    const win_create = gui.getWindow(gui_mod.WIN_CREATE_VM_ID).?;
    try testing.expect(win_create.is_onscreen);
    try testing.expectEqual(geom.guests_x, win_create.x);
    try testing.expectEqual(geom.guests_w, win_create.width);
    try testing.expect(gui.getWindow(gui_mod.WIN_CREATE_VM_DETAIL_ID) == null);

    const img_item = win_create.getIconById(
        gui_mod.ICON_CREATE_VM_ITEM_BASE_ID,
    ).?;
    try testing.expect(
        std.mem.indexOf(u8, img_item.getText(), "Diosix Base Linux") != null,
    );

    // 3. Select the image: opens WIN_CREATE_VM_DETAIL_ID on the right.
    gui.handleMouseClick(
        win_create.x + img_item.rel_x + 10,
        win_create.y + img_item.rel_y + 10,
    );
    gui.handleMouseRelease();

    const win_detail = gui.getWindow(gui_mod.WIN_CREATE_VM_DETAIL_ID).?;
    try testing.expect(win_detail.is_onscreen);
    try testing.expectEqual(geom.detail_x, win_detail.x);
    try testing.expectEqual(geom.detail_w, win_detail.width);

    const name_in = win_detail.getIconById(
        gui_mod.ICON_CREATE_VM_NAME_INPUT_ID,
    ).?;
    const vcpus_sld = win_detail.getIconById(
        gui_mod.ICON_CREATE_VM_VCPUS_SLIDER_ID,
    ).?;
    const ram_sld = win_detail.getIconById(
        gui_mod.ICON_CREATE_VM_RAM_SLIDER_ID,
    ).?;
    const pcpu_sld = win_detail.getIconById(
        gui_mod.ICON_CREATE_VM_PCPU_SLIDER_ID,
    ).?;
    const ram_q_sld = win_detail.getIconById(
        gui_mod.ICON_CREATE_VM_RAM_QUOTA_SLIDER_ID,
    ).?;
    const quota_info = win_detail.getIconById(
        gui_mod.ICON_CREATE_VM_QUOTA_INFO_ID,
    ).?;
    const st_opt1 = win_detail.getIconById(
        gui_mod.ICON_CREATE_VM_STORAGE_BASE_ID + 1,
    ).?;
    const create_btn = win_detail.getIconById(
        gui_mod.ICON_CREATE_VM_BTN_ID,
    ).?;

    try testing.expectEqualStrings("diosix-base-linux", name_in.getText());
    try testing.expectEqual(@as(i32, 2), vcpus_sld.slider_val);
    try testing.expectEqual(@as(i32, 512), ram_sld.slider_val);
    try testing.expectEqual(@as(i32, 20), pcpu_sld.slider_val);
    try testing.expectEqual(@as(i32, 512), ram_q_sld.slider_val);
    try testing.expect(
        std.mem.indexOf(u8, quota_info.getText(), "90% pCPU") != null,
    );

    // 4. Focus the Name input field, type a custom name ("web-node-1"), dial
    // vCPUs to 4, RAM to 768 MB, pCPU quota to 40%, RAM quota to 768 MB,
    // select storage option 1, and click Create.
    gui.handleMouseClick(
        win_detail.x + name_in.rel_x + 10,
        win_detail.y + name_in.rel_y + 10,
    );
    gui.handleMouseRelease();
    name_in.clearField();
    for ("web-node-1") |ch| gui.handleKeyChar(ch);
    try testing.expectEqualStrings("web-node-1", name_in.getText());

    const exp_stops = [_]i32{
        1,   2,   4,   8,   16,  32,   48,   64,   96,   128,
        192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096,
    };
    vcpus_sld.setSliderValue(1);
    for (exp_stops, 0..) |ev, s_idx| {
        if (s_idx > 0) vcpus_sld.adjustSlider(1);
        try testing.expectEqual(ev, vcpus_sld.slider_val);
    }
    vcpus_sld.setSliderValue(4);
    if (vcpus_sld.callback) |cb| cb(&gui, win_detail, vcpus_sld);
    ram_sld.adjustSlider(4);
    if (ram_sld.callback) |cb| cb(&gui, win_detail, ram_sld);
    pcpu_sld.adjustSlider(20);
    if (pcpu_sld.callback) |cb| cb(&gui, win_detail, pcpu_sld);
    ram_q_sld.setSliderValue(768);
    if (ram_q_sld.callback) |cb| cb(&gui, win_detail, ram_q_sld);

    gui.handleMouseClick(
        win_detail.x + st_opt1.rel_x + 10,
        win_detail.y + st_opt1.rel_y + 10,
    );
    gui.handleMouseRelease();
    try testing.expectEqual(@as(usize, 1), gui.create_vm_storage_idx);

    gui.handleMouseClick(
        win_detail.x + create_btn.rel_x + 10,
        win_detail.y + create_btn.rel_y + 10,
    );
    gui.handleMouseRelease();
    gui.completeNavAnimation();

    try testing.expect(host_info.images.mock_last_created_vm != null);
    const created = host_info.images.mock_last_created_vm.?;
    try testing.expectEqualStrings("web-node-1", created.getName());
    try testing.expectEqualStrings(
        "/var/lib/diosix/images/diosix-base-linux.elf",
        created.getImagePath(),
    );
    try testing.expectEqual(@as(u32, 4), created.vcpus);
    try testing.expectEqual(@as(u32, 768), created.ram_mb);
    try testing.expectEqual(@as(u32, 40), created.pcpu_quota_pct);
    try testing.expectEqual(@as(u32, 768), created.ram_quota_mb);
    try testing.expectEqualStrings(
        "/var/lib/diosix/disks/data.raw",
        created.getStoragePath(),
    );
    try testing.expect(gui.getWindow(gui_mod.WIN_CREATE_VM_ID) == null);
    try testing.expect(gui.getWindow(gui_mod.WIN_CREATE_VM_DETAIL_ID) == null);

    // Verify background task notification/progress bar was spawned above the
    // bottom info pane with the same height and full width of the display,
    // and dismiss it via its right-hand Dismiss button.
    const help_win = gui.getWindow(gui_mod.WIN_HELP_ID).?;
    const task_win = gui.getWindow(gui_mod.WIN_TASK_BASE_ID).?;
    try testing.expect(task_win.is_onscreen);
    try testing.expectEqual(gui_mod.BORDER_GAP, task_win.x);
    try testing.expectEqual(
        gui.width - @as(u32, @intCast(gui_mod.BORDER_GAP * 2)),
        task_win.width,
    );
    try testing.expectEqual(help_win.height, task_win.height);
    try testing.expectEqual(
        help_win.y - @as(i32, @intCast(task_win.height)) - gui_mod.BORDER_GAP,
        task_win.y,
    );
    const dismiss_btn = task_win.getIconById(gui_mod.ICON_TASK_DISMISS_ID).?;
    gui.handleMouseClick(
        task_win.x + dismiss_btn.rel_x + 5,
        task_win.y + dismiss_btn.rel_y + 5,
    );
    gui.handleMouseRelease();
    try testing.expect(gui.getWindow(gui_mod.WIN_TASK_BASE_ID) == null);

    // 5. Verify Running guest VMs pane sizes vertically to the number of items
    // up until its vertical limit (geom.max_h) and then becomes scrollable.
    var one_guest: [1]host_info.RunningGuest = .{
        .{ .cid = 1, .is_root = true },
    };
    host_info.guests.mock_running_guests = &one_guest;
    defer host_info.guests.mock_running_guests = null;
    gui.updateGuestsPaneData();
    const gwin = gui.getWindow(gui_mod.WIN_GUESTS_ID).?;
    const h_one = gwin.height;
    try testing.expect(h_one < gui_mod.MENU_FULL_H);
    try testing.expect(!gwin.isScrollable());

    var many_guests: [20]host_info.RunningGuest = @splat(.{ .cid = 1 });
    for (&many_guests, 0..) |*mg, idx| mg.cid = idx + 1;
    host_info.guests.mock_running_guests = &many_guests;
    gui.updateGuestsPaneData();
    try testing.expectEqual(geom.max_h, gwin.height);
    try testing.expect(gwin.isScrollable());

    // 6. Spawn multiple notifications/progress bars and verify they stack
    // above the info pane, shrink overlapping panes vertically (making them
    // scrollable), display progress/completion/quota-exhausted errors, and
    // restore pane height when dismissed.
    const argv_dummy = [_][]const u8{ "/usr/bin/dsx", "run", "base" };
    const t1 = gui.spawnBackgroundTask(
        "Creating VM (vm-1)",
        "Resolving guest image...",
        &argv_dummy,
    );
    const t2 = gui.spawnBackgroundTask(
        "Creating VM (vm-2)",
        "Checking resource quotas...",
        &argv_dummy,
    );
    try testing.expectEqual(@as(usize, 2), gui.task_mgr.activeCount());

    const bar1 = gui.getWindow(gui_mod.WIN_TASK_BASE_ID).?;
    const bar2 = gui.getWindow(gui_mod.WIN_TASK_BASE_ID + 1).?;
    const step_h: i32 = @intCast(
        help_win.height + @as(u32, @intCast(gui_mod.BORDER_GAP)),
    );
    try testing.expectEqual(help_win.y - step_h, bar1.y);
    try testing.expectEqual(help_win.y - step_h * 2, bar2.y);

    const gwin_after = gui.getWindow(gui_mod.WIN_GUESTS_ID).?;
    try testing.expectEqual(
        geom.max_h - @as(u32, @intCast(step_h * 2)),
        gwin_after.height,
    );
    try testing.expect(gwin_after.isScrollable());

    // Update task 1 progress and complete it; fail task 2 with quota error.
    _ = gui.task_mgr.updateProgress(
        t1,
        65,
        "Loading guest ELF segment 1/1...",
    );
    _ = gui.task_mgr.completeTask(
        t1,
        "Child VM 'vm-1' (CID 2) started in background.",
    );
    _ = gui.task_mgr.failTask(
        t2,
        "Error: Create child VM failed: vCPU quota exhausted (4/4 vCPUs).",
    );
    gui.syncTaskPanes();

    const bar1_done = gui.getWindow(gui_mod.WIN_TASK_BASE_ID).?;
    const bar1_prog = bar1_done.getIconById(gui_mod.ICON_TASK_PROGRESS_ID).?;
    try testing.expectEqual(@as(i32, 100), bar1_prog.slider_val);
    try testing.expectEqual(
        @as(?u32, fb.Color.PROGRESS_SUCCESS_GREEN),
        bar1_prog.custom_color,
    );

    const bar2_err = gui.getWindow(gui_mod.WIN_TASK_BASE_ID + 1).?;
    try testing.expect(
        bar2_err.getIconById(gui_mod.ICON_TASK_PROGRESS_ID) == null,
    );
    const err_lbl = bar2_err.getIconById(gui_mod.ICON_TASK_LABEL_ID).?;
    try testing.expect(
        std.mem.indexOf(u8, err_lbl.getText(), "vCPU quota exhausted") != null,
    );

    // Dismiss both notifications and verify gwin expands back to geom.max_h.
    _ = gui.task_mgr.dismissTask(t1);
    _ = gui.task_mgr.dismissTask(t2);
    gui.syncTaskPanes();
    try testing.expectEqual(
        geom.max_h,
        gui.getWindow(gui_mod.WIN_GUESTS_ID).?.height,
    );

    // 7. Verify live pCPU % and RAM quota sliders in Running guest VMs detail
    // pane for a running child VM.
    const mb: u64 = 1024 * 1024;
    var two_guests: [2]host_info.RunningGuest = .{
        .{
            .cid = 1,
            .is_root = true,
            .vcpus = 4,
            .ram_bytes = 256 * mb,
            .ram_quota_bytes = 1536 * mb,
            .delegated_ram_bytes = 512 * mb,
            .pcpu_quota_pct = 100,
            .delegated_pcpu_pct = 80,
        },
        .{
            .cid = 2,
            .is_root = false,
            .vcpus = 2,
            .ram_bytes = 512 * mb,
            .ram_quota_bytes = 512 * mb,
            .used_ram_bytes = 128 * mb,
            .pcpu_quota_pct = 80,
        },
    };
    two_guests[0].setInstanceName("root (self)");
    two_guests[1].setInstanceName("child-1");
    host_info.guests.mock_running_guests = &two_guests;
    host_info.guests.mock_last_guest_action = null;
    defer host_info.guests.mock_last_guest_action = null;
    gui.updateGuestsPaneData();

    const child_item = gwin.getIconById(
        gui_mod.ICON_GUESTS_ITEM_BASE_ID + 1,
    ).?;
    gui.handleMouseClick(
        gwin.x + child_item.rel_x + 10,
        gwin.y + child_item.rel_y + 10,
    );
    gui.handleMouseRelease();

    var gdetail = gui.getWindow(gui_mod.WIN_GUEST_DETAIL_ID).?;
    const gpcpu = gdetail.getIconById(
        gui_mod.ICON_GUEST_PCPU_QUOTA_SLIDER_ID,
    ).?;
    const gram = gdetail.getIconById(
        gui_mod.ICON_GUEST_RAM_QUOTA_SLIDER_ID,
    ).?;
    try testing.expectEqual(@as(i32, 80), gpcpu.slider_val);
    try testing.expectEqual(@as(i32, 90), gpcpu.slider_max);
    try testing.expectEqual(@as(i32, 512), gram.slider_val);

    // Dial child-1 pCPU from 80% down to 50% (-30%).
    gpcpu.adjustSlider(-30);
    if (gpcpu.callback) |cb| cb(&gui, gdetail, gpcpu);
    const act = host_info.guests.mock_last_guest_action.?;
    try testing.expectEqual(
        host_info.guests.GuestActionKind.set_quota,
        act.action,
    );
    try testing.expectEqual(@as(u64, 2), act.cid);
    try testing.expectEqual(@as(u32, 50), act.pcpu_quota_pct);
    try testing.expectEqual(@as(u32, 512), act.ram_quota_mb);

    // 8. Verify terminal state machine:
    // "Open new SSH terminal" -> create terminal (shifts panes out, full width,
    // no Close icon) -> Back hides terminal -> "Reopen SSH terminal" -> Reopen
    // -> session exits -> Back discards session -> "Open new SSH terminal".
    var ssh_btn = gdetail.getIconById(gui_mod.ICON_GUEST_SSH_ID).?;
    const con_btn = gdetail.getIconById(gui_mod.ICON_GUEST_CONSOLE_ID).?;
    try testing.expectEqualStrings("Open new SSH terminal", ssh_btn.getText());
    try testing.expectEqualStrings("Open serial console", con_btn.getText());

    gui.handleMouseClick(
        gdetail.x + ssh_btn.rel_x + 10,
        gdetail.y - gdetail.scroll_y + ssh_btn.rel_y + 10,
    );
    gui.handleMouseRelease();
    gui.completeNavAnimation();

    // Other panes slid out; only contracted menu, Back pane, and full-width
    // terminal remain onscreen. No Close button on terminal pane.
    try testing.expect(gui.getWindow(gui_mod.WIN_GUESTS_ID) == null);
    try testing.expect(gui.getWindow(gui_mod.WIN_GUEST_DETAIL_ID) == null);
    try testing.expect(gui.getWindow(gui_mod.WIN_BACK_ID).?.is_onscreen);

    var win_term = gui.getWindow(gui_mod.WIN_TERMINAL_ID).?;
    try testing.expect(win_term.is_onscreen);
    try testing.expectEqual(@as(usize, 5), win_term.icons.items.len);
    try testing.expect(gui.terminal.active);
    try testing.expect(gui.terminal.cols > 80);
    try testing.expectEqual(@as(u64, 2), gui.terminal.target_cid);
    try testing.expectEqual(
        gui_mod.terminal_mod.TerminalMode.ssh,
        gui.terminal.mode,
    );

    // Invert button toggles terminal color inversion.
    const inv_btn = win_term.getIconById(gui_mod.ICON_TERM_INVERT_BTN_ID).?;
    try testing.expect(!gui.terminal.inverted);
    gui.handleMouseClick(
        win_term.x + inv_btn.rel_x + 10,
        win_term.y + inv_btn.rel_y + 10,
    );
    gui.handleMouseRelease();
    try testing.expect(gui.terminal.inverted);

    // Type command into terminal and verify it reaches the session buffer.
    for ("ls -la\n") |ch| gui.handleKeyChar(ch);
    try testing.expectEqualStrings("ls -la\n", gui.terminal.getMockSentBytes());
    try testing.expectEqualStrings("# ls -la", gui.terminal.getRowTrimmed(1));

    // Clicking Back hides the terminal while keeping the SSH session alive;
    // button now reads "Reopen SSH terminal".
    try gui.navigateBack();
    gui.completeNavAnimation();
    try testing.expect(!gui.terminal.active);
    try testing.expect(gui.hasLiveSshSession(2));
    try testing.expect(gui.getWindow(gui_mod.WIN_TERMINAL_ID) == null);

    gdetail = gui.getWindow(gui_mod.WIN_GUEST_DETAIL_ID).?;
    ssh_btn = gdetail.getIconById(gui_mod.ICON_GUEST_SSH_ID).?;
    try testing.expectEqualStrings("Reopen SSH terminal", ssh_btn.getText());

    // Clicking "Reopen SSH terminal" reopens the preserved session.
    gui.handleMouseClick(
        gdetail.x + ssh_btn.rel_x + 10,
        gdetail.y - gdetail.scroll_y + ssh_btn.rel_y + 10,
    );
    gui.handleMouseRelease();
    gui.completeNavAnimation();
    win_term = gui.getWindow(gui_mod.WIN_TERMINAL_ID).?;
    try testing.expect(gui.terminal.active);
    try testing.expectEqualStrings("# ls -la", gui.terminal.getRowTrimmed(1));

    // When the session exits and Back is clicked, the session is discarded
    // and the button reverts to "Open new SSH terminal".
    gui.terminal.exited = true;
    try gui.navigateBack();
    gui.completeNavAnimation();
    try testing.expect(!gui.hasLiveSshSession(2));
    gdetail = gui.getWindow(gui_mod.WIN_GUEST_DETAIL_ID).?;
    ssh_btn = gdetail.getIconById(gui_mod.ICON_GUEST_SSH_ID).?;
    try testing.expectEqualStrings("Open new SSH terminal", ssh_btn.getText());
    const qhdr = gdetail.getIconById(gui_mod.ICON_GUEST_QUOTA_HDR_ID).?;
    try testing.expectEqualStrings(
        "Resource pool (VM + children)",
        qhdr.getText(),
    );

    // 9. Per-guest console terminal preservation and unexpected crash alert.
    gui.setWindowTransparency(50);
    // 50% / 4 = 12% transparency -> 88% opacity (224/255).
    try testing.expectEqual(@as(u8, 224), gui.getAttentionOpacityAlpha());

    try gui.openGuestTerminal(2, .console);
    gui.completeNavAnimation();
    for ("dmesg\n") |ch| gui.handleKeyChar(ch);
    try gui.openGuestTerminal(1, .console);
    gui.completeNavAnimation();
    try gui.openGuestTerminal(2, .console);
    gui.completeNavAnimation();
    try testing.expectEqualStrings("dmesg", gui.terminal.getRowTrimmed(1));
    try gui.navigateBack();
    gui.completeNavAnimation();
    gdetail = gui.getWindow(gui_mod.WIN_GUEST_DETAIL_ID).?;
    const con_btn_after = gdetail.getIconById(gui_mod.ICON_GUEST_CONSOLE_ID).?;
    try testing.expectEqualStrings(
        "Reopen serial console",
        con_btn_after.getText(),
    );

    // Simulate child-1 (CID 2) crashing unexpectedly; verify terminal is
    // released and bottom crash notification bar is displayed.
    host_info.guests.mock_running_guests = two_guests[0..1];
    gui.updateGuestsPaneData();
    const crash_bar = gui.getWindow(gui_mod.WIN_TASK_BASE_ID).?;
    const crash_lbl = crash_bar.getIconById(gui_mod.ICON_TASK_LABEL_ID).?;
    try testing.expect(
        std.mem.indexOf(u8, crash_lbl.getText(), "child-1") != null,
    );

    testing.refAllDecls(@This());
}
