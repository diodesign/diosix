// Virtual Machine Fleet Overview and Contextual Action Drawer for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const fb = @import("../framebuffer.zig");
const icon_mod = @import("../icon.zig");
const Icon = icon_mod.Icon;
const window_mod = @import("../window.zig");
const Window = window_mod.Window;
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;

const BORDER_GAP = gui_mod.BORDER_GAP;
const WIN_MENU_ID = gui_mod.WIN_MENU_ID;
const WIN_VM_FLEET_ID = gui_mod.WIN_VM_FLEET_ID;
const WIN_VM_DRAWER_ID = gui_mod.WIN_VM_DRAWER_ID;

const ICON_VM_CREATE_NEW_ID = gui_mod.ICON_VM_CREATE_NEW_ID;
const ICON_VM_ROOTVM_ID = gui_mod.ICON_VM_ROOTVM_ID;
const ICON_VM_ALPINE_ID = gui_mod.ICON_VM_ALPINE_ID;
const ICON_VM_DEBIAN_ID = gui_mod.ICON_VM_DEBIAN_ID;
const ICON_VM_FREEBSD_ID = gui_mod.ICON_VM_FREEBSD_ID;
const ICON_VM_SNAP_DEBIAN_ID = gui_mod.ICON_VM_SNAP_DEBIAN_ID;
const ICON_VM_NETBSD_ID = gui_mod.ICON_VM_NETBSD_ID;

const ICON_DRAWER_TITLE_ID = gui_mod.ICON_DRAWER_TITLE_ID;
const ICON_DRAWER_STATE_ID = gui_mod.ICON_DRAWER_STATE_ID;
const ICON_DRAWER_SPEC1_ID = gui_mod.ICON_DRAWER_SPEC1_ID;
const ICON_DRAWER_SPEC2_ID = gui_mod.ICON_DRAWER_SPEC2_ID;
const ICON_DRAWER_SPEC3_ID = gui_mod.ICON_DRAWER_SPEC3_ID;
const ICON_DRAWER_NOTICE1_ID = gui_mod.ICON_DRAWER_NOTICE1_ID;
const ICON_DRAWER_NOTICE2_ID = gui_mod.ICON_DRAWER_NOTICE2_ID;
const ICON_DRAWER_BTN_START_ID = gui_mod.ICON_DRAWER_BTN_START_ID;
const ICON_DRAWER_BTN_STOP_ID = gui_mod.ICON_DRAWER_BTN_STOP_ID;
const ICON_DRAWER_BTN_PAUSE_ID = gui_mod.ICON_DRAWER_BTN_PAUSE_ID;
const ICON_DRAWER_BTN_SNAP_ID = gui_mod.ICON_DRAWER_BTN_SNAP_ID;
const ICON_DRAWER_BTN_CONSOLE_ID = gui_mod.ICON_DRAWER_BTN_CONSOLE_ID;
const ICON_DRAWER_BTN_KILL_ID = gui_mod.ICON_DRAWER_BTN_KILL_ID;
const ICON_DRAWER_BTN_RESTORE_ID = gui_mod.ICON_DRAWER_BTN_RESTORE_ID;
const ICON_DRAWER_BTN_CLONE_ID = gui_mod.ICON_DRAWER_BTN_CLONE_ID;
const ICON_DRAWER_BTN_DELETE_ID = gui_mod.ICON_DRAWER_BTN_DELETE_ID;

fn onVmCardSelected(
    gui_ctx: *anyopaque,
    win_ctx: *anyopaque,
    icon: *Icon,
) void {
    _ = win_ctx;
    const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    self.selectVm(icon.id);
}

fn onVmActionClicked(
    gui_ctx: *anyopaque,
    win_ctx: *anyopaque,
    icon: *Icon,
) void {
    _ = win_ctx;
    const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    self.handleVmAction(icon.id);
}

fn addDrawerReadOnly(
    win: *Window,
    id: u32,
    y: i32,
    w: u32,
    h: u32,
    text: []const u8,
    color: u32,
) !void {
    var ic = Icon.createReadOnly(id, 14, y, w, h, text);
    ic.setCustomColor(color);
    _ = try win.addIcon(ic);
}

const DrawerBtnSpec = struct {
    id: u32,
    label: []const u8,
    help: []const u8,
    color: ?u32 = null,
};

fn addDrawerButtonList(
    win: *Window,
    pad_x: i32,
    start_y: i32,
    col_w: u32,
    specs: []const DrawerBtnSpec,
) !void {
    const btn_h: u32 = 30;
    const step_y: i32 = @as(i32, @intCast(btn_h)) + 8;
    var cur_y = start_y;
    for (specs) |sp| {
        var btn = Icon.createButton(
            sp.id,
            pad_x,
            cur_y,
            col_w,
            btn_h,
            sp.label,
        );
        btn.setHelpText(sp.help);
        if (sp.color) |c| btn.setCustomColor(c);
        btn.callback = onVmActionClicked;
        _ = try win.addIcon(btn);
        cur_y += step_y;
    }
}

pub fn buildVmFleetOverview(self: *DiosixGui) !void {
    const menu_win = self.getWindow(WIN_MENU_ID);
    const fleet_x: i32 = if (menu_win) |mw|
        mw.x + @as(i32, @intCast(mw.width)) + BORDER_GAP
    else
        172;
    const fleet_y: i32 = BORDER_GAP;
    const ver_y = @as(i32, @intCast(self.height)) - 40 - BORDER_GAP;
    const bottom_y = ver_y - BORDER_GAP;
    const avail_h: u32 =
        if (bottom_y > fleet_y) @intCast(bottom_y - fleet_y) else 600;

    const drawer_w: u32 = if (self.width >= 1200) 340 else 290;
    const drawer_x: i32 = @as(i32, @intCast(self.width)) - BORDER_GAP -
        @as(i32, @intCast(drawer_w));
    const avail_w: i32 = drawer_x - fleet_x - BORDER_GAP;
    const fleet_w: u32 = if (avail_w > 200) @intCast(avail_w) else 400;

    const win_fleet = try self.createWindow(
        WIN_VM_FLEET_ID,
        fleet_x,
        fleet_y,
        fleet_w,
        avail_h,
        "Virtual machines",
    );
    win_fleet.setHelpText(
        "Overview of virtual machines and frozen snapshots " ++
            "running on this host",
    );

    const card_pad_x: i32 = 14;
    const card_w: u32 = if (fleet_w > @as(u32, @intCast(card_pad_x * 2)))
        fleet_w - @as(u32, @intCast(card_pad_x * 2))
    else
        200;
    const create_card_h: u32 = 36;
    const create_card_y: i32 = 44;
    var create_card = Icon.createButton(
        ICON_VM_CREATE_NEW_ID,
        card_pad_x,
        create_card_y,
        card_w,
        create_card_h,
        "+ Create new virtual machine",
    );
    create_card.setHelpText(
        "Deploy a new guest virtual machine from a manifest " ++
            "template or disk image",
    );
    create_card.callback = onVmActionClicked;
    _ = try win_fleet.addIcon(create_card);

    const card_h: u32 = 62;
    const card_spacing: i32 = 8;
    var cur_y: i32 = create_card_y + @as(i32, @intCast(create_card_h)) + 12;

    const vm_specs = [_]struct {
        id: u32,
        name: []const u8,
        subtitle: []const u8,
        badge: []const u8,
        badge_color: u32,
        is_supervisor: bool,
        help: []const u8,
    }{
        .{
            .id = ICON_VM_ROOTVM_ID,
            .name = "rootvm",
            .subtitle = "Trusted host supervisor | 4 vCPUs " ++
                "| 256 MB RAM | Non-terminable",
            .badge = "Supervisor",
            .badge_color = fb.Color.ACCENT_GOLD,
            .is_supervisor = true,
            .help = "Host hypervisor supervisor root VM",
        },
        .{
            .id = ICON_VM_ALPINE_ID,
            .name = "alpine-router",
            .subtitle = "2 vCPUs | 256 MB RAM | 10.0.3.1 | Uptime: 14d 6h",
            .badge = "Running",
            .badge_color = fb.Color.ACCENT_GREEN,
            .is_supervisor = false,
            .help = "Guest VM: Alpine Linux network edge gateway",
        },
        .{
            .id = ICON_VM_DEBIAN_ID,
            .name = "debian-desktop",
            .subtitle = "4 vCPUs | 2048 MB RAM | 10.0.3.15 " ++
                "| VirtIO-GPU 1024x768",
            .badge = "Running",
            .badge_color = fb.Color.ACCENT_GREEN,
            .is_supervisor = false,
            .help = "Guest VM: Debian workstation with active GPU display",
        },
        .{
            .id = ICON_VM_FREEBSD_ID,
            .name = "freebsd-storage",
            .subtitle = "2 vCPUs | 1024 MB RAM | 10.0.3.40 " ++
                "| ZFS 500GB VirtIO-Blk",
            .badge = "Running",
            .badge_color = fb.Color.ACCENT_GREEN,
            .is_supervisor = false,
            .help = "Guest VM: FreeBSD network-attached storage array",
        },
        .{
            .id = ICON_VM_SNAP_DEBIAN_ID,
            .name = "debian-snap-pre-upgrade",
            .subtitle = "Snapshot of debian-desktop " ++
                "| Saved 2026-09-18 14:22 UTC | 412 MB",
            .badge = "Snapshot",
            .badge_color = fb.Color.ACCENT_CYAN,
            .is_supervisor = false,
            .help = "Frozen snapshot checkpoint: debian-desktop pre-upgrade",
        },
        .{
            .id = ICON_VM_NETBSD_ID,
            .name = "netbsd-test",
            .subtitle = "1 vCPU | 512 MB RAM | offline | VirtIO-Net",
            .badge = "Stopped",
            .badge_color = fb.Color.TEXT_MUTED,
            .is_supervisor = false,
            .help = "Guest VM: NetBSD automated testing environment (stopped)",
        },
    };

    for (vm_specs) |spec| {
        var card = Icon.createSlateCard(
            spec.id,
            card_pad_x,
            cur_y,
            card_w,
            card_h,
            spec.name,
            spec.subtitle,
            spec.badge,
            spec.badge_color,
        );
        card.card_is_supervisor = spec.is_supervisor;
        card.setHelpText(spec.help);
        card.callback = onVmCardSelected;
        if (self.selected_vm_id == spec.id) {
            card.setSelected(true);
        }
        _ = try win_fleet.addIcon(card);
        cur_y += @as(i32, @intCast(card_h + card_spacing));
    }

    try buildVmActionDrawer(self, drawer_x, fleet_y, drawer_w, avail_h);
}

pub fn buildVmActionDrawer(
    self: *DiosixGui,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
) !void {
    _ = self.destroyWindow(WIN_VM_DRAWER_ID);

    const win = try self.createWindow(
        WIN_VM_DRAWER_ID,
        x,
        y,
        width,
        height,
        "VM controls",
    );
    win.setHelpText(
        "Contextual controls and operations for the selected virtual machine",
    );

    const sel_id = self.selected_vm_id;
    const is_root = (sel_id == ICON_VM_ROOTVM_ID);
    const is_snap = (sel_id == ICON_VM_SNAP_DEBIAN_ID);
    const is_stopped = (sel_id == ICON_VM_NETBSD_ID);

    const pad_x: i32 = 14;
    const col_w: u32 = if (width > @as(u32, @intCast(pad_x * 2)))
        width - @as(u32, @intCast(pad_x * 2))
    else
        100;
    var cur_y: i32 = 44;

    const vm_title = switch (sel_id) {
        ICON_VM_ROOTVM_ID => "rootvm (Root VM)",
        ICON_VM_ALPINE_ID => "alpine-router",
        ICON_VM_DEBIAN_ID => "debian-desktop",
        ICON_VM_FREEBSD_ID => "freebsd-storage",
        ICON_VM_SNAP_DEBIAN_ID => "debian-snap-pre-upgrade",
        ICON_VM_NETBSD_ID => "netbsd-test",
        else => "Guest Virtual Machine",
    };
    const title_col =
        if (is_root) fb.Color.ACCENT_GOLD else fb.Color.ACCENT_CYAN;
    try addDrawerReadOnly(
        win,
        ICON_DRAWER_TITLE_ID,
        cur_y,
        col_w,
        20,
        vm_title,
        title_col,
    );
    cur_y += 24;

    const state_str = if (is_root)
        "State: Protected supervisor"
    else if (is_snap)
        "State: Frozen snapshot (RAM checkpoint)"
    else if (is_stopped)
        "State: Stopped (offline)"
    else
        "State: Running (PID 1042, link up)";
    const state_col = if (is_root)
        fb.Color.ACCENT_GOLD
    else if (is_snap)
        fb.Color.ACCENT_CYAN
    else if (is_stopped)
        fb.Color.TEXT_MUTED
    else
        fb.Color.ACCENT_GREEN;
    try addDrawerReadOnly(
        win,
        ICON_DRAWER_STATE_ID,
        cur_y,
        col_w,
        18,
        state_str,
        state_col,
    );
    cur_y += 24;

    const s1 = if (is_root)
        "Cores   : 4 vCPUs (dedicated)"
    else if (is_stopped)
        "Cores   : 1 vCPU (unallocated)"
    else
        "Cores   : 2-4 vCPUs (affinity set)";
    const s2 = if (is_root)
        "Memory  : 256 MB assigned"
    else if (is_snap)
        "Saved   : 412 MB delta, 20GB disk"
    else
        "Memory  : 256MB - 2048MB assigned";
    const s3 = if (is_root)
        "Role    : Trusted host supervisor"
    else if (is_stopped)
        "Network : tap3 (disconnected)"
    else
        "Network : VirtIO-Net (tap0 -> br0)";

    const spec_col: u32 = 0x00a0b4c8;
    const sp1_id = ICON_DRAWER_SPEC1_ID;
    const sp2_id = ICON_DRAWER_SPEC2_ID;
    const sp3_id = ICON_DRAWER_SPEC3_ID;
    try addDrawerReadOnly(win, sp1_id, cur_y, col_w, 18, s1, spec_col);
    cur_y += 20;
    try addDrawerReadOnly(win, sp2_id, cur_y, col_w, 18, s2, spec_col);
    cur_y += 20;
    try addDrawerReadOnly(win, sp3_id, cur_y, col_w, 18, s3, spec_col);
    cur_y += 26;

    const op_lbl = "Available operations";
    try addDrawerReadOnly(win, 1259, cur_y, col_w, 18, op_lbl, fb.Color.WHITE);
    cur_y += 24;

    if (is_root) {
        const n1 = "Root VM is protected.";
        const n2 = "To reboot or shut down the host,";
        const n3 = "use the options in the main menu.";
        const n1_id = ICON_DRAWER_NOTICE1_ID;
        const n2_id = ICON_DRAWER_NOTICE2_ID;
        const gold = fb.Color.ACCENT_GOLD;
        try addDrawerReadOnly(win, n1_id, cur_y, col_w, 18, n1, gold);
        cur_y += 20;
        try addDrawerReadOnly(win, n2_id, cur_y, col_w, 18, n2, spec_col);
        cur_y += 18;
        try addDrawerReadOnly(win, n2_id + 1, cur_y, col_w, 18, n3, spec_col);
        cur_y += 28;

        const root_btns = [_]DrawerBtnSpec{
            .{
                .id = ICON_DRAWER_BTN_CONSOLE_ID,
                .label = "Open serial console",
                .help = "Connect to Root VM UART console",
            },
            .{
                .id = ICON_DRAWER_BTN_SNAP_ID,
                .label = "Capture core dump",
                .help = "Save supervisor state to crash log",
            },
        };
        try addDrawerButtonList(win, pad_x, cur_y, col_w, &root_btns);
    } else if (is_snap) {
        const snap_btns = [_]DrawerBtnSpec{
            .{
                .id = ICON_DRAWER_BTN_RESTORE_ID,
                .label = "Restore snapshot",
                .help = "Revert VM to this memory and disk checkpoint",
            },
            .{
                .id = ICON_DRAWER_BTN_CLONE_ID,
                .label = "Clone to new VM",
                .help = "Spawn a new guest instance from this snapshot",
            },
            .{
                .id = ICON_DRAWER_BTN_DELETE_ID,
                .label = "Delete snapshot",
                .help = "Permanently discard this snapshot checkpoint",
                .color = fb.Color.ACCENT_RED,
            },
        };
        try addDrawerButtonList(win, pad_x, cur_y, col_w, &snap_btns);
    } else if (is_stopped) {
        const stop_btns = [_]DrawerBtnSpec{
            .{
                .id = ICON_DRAWER_BTN_START_ID,
                .label = "Start VM",
                .help = "Boot guest virtual machine",
            },
            .{
                .id = ICON_DRAWER_BTN_CONSOLE_ID,
                .label = "Edit manifest",
                .help = "Modify VM manifest configuration",
            },
            .{
                .id = ICON_DRAWER_BTN_DELETE_ID,
                .label = "Delete VM",
                .help = "Remove guest VM and free allocated resources",
                .color = fb.Color.ACCENT_RED,
            },
        };
        try addDrawerButtonList(win, pad_x, cur_y, col_w, &stop_btns);
    } else {
        const run_btns = [_]DrawerBtnSpec{
            .{
                .id = ICON_DRAWER_BTN_STOP_ID,
                .label = "Stop guest (ACPI)",
                .help = "Send ACPI power down signal to guest",
            },
            .{
                .id = ICON_DRAWER_BTN_PAUSE_ID,
                .label = "Pause execution",
                .help = "Freeze guest vCPUs without saving state",
            },
            .{
                .id = ICON_DRAWER_BTN_SNAP_ID,
                .label = "Take snapshot",
                .help = "Create a frozen RAM and disk checkpoint",
            },
            .{
                .id = ICON_DRAWER_BTN_CONSOLE_ID,
                .label = "Open console",
                .help = "Open virtual terminal or display",
            },
            .{
                .id = ICON_DRAWER_BTN_KILL_ID,
                .label = "Force terminate",
                .help = "Immediately kill guest VM process",
                .color = fb.Color.ACCENT_RED,
            },
        };
        try addDrawerButtonList(win, pad_x, cur_y, col_w, &run_btns);
    }
}
