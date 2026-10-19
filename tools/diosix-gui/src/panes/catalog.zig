// Software & Images and Hardware & Peripherals Panes for Diosix GUI.
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

pub const CardSpec = struct {
    id: u32,
    title: []const u8,
    subtitle: []const u8,
    badge: []const u8,
    badge_color: u32,
    help: []const u8,
};

pub fn addSlateCardList(
    win: *Window,
    pad_x: i32,
    start_y: i32,
    card_w: u32,
    items: []const CardSpec,
) !void {
    const card_h: u32 = 56;
    const card_spacing: i32 = 8;
    var cur_y: i32 = start_y;
    for (items) |it| {
        var c = Icon.createSlateCard(
            it.id,
            pad_x,
            cur_y,
            card_w,
            card_h,
            it.title,
            it.subtitle,
            it.badge,
            it.badge_color,
        );
        c.setHelpText(it.help);
        _ = try win.addIcon(c);
        cur_y += @as(i32, @intCast(card_h + card_spacing));
    }
}

pub fn buildSoftwarePane(self: *DiosixGui) !void {
    const menu_win = self.getWindow(gui_mod.WIN_MENU_ID);
    const sw_x: i32 = if (menu_win) |mw|
        mw.x + @as(i32, @intCast(mw.width)) + BORDER_GAP
    else
        172;
    const sw_y: i32 = BORDER_GAP;
    const avail_w = @as(i32, @intCast(self.width)) - sw_x - BORDER_GAP;
    const sw_w: u32 = if (avail_w > 200) @intCast(avail_w) else 780;
    const ver_y = @as(i32, @intCast(self.height)) - 40 - BORDER_GAP;
    const bottom_y = ver_y - BORDER_GAP;
    const sw_h: u32 = if (bottom_y > sw_y) @intCast(bottom_y - sw_y) else 600;

    const win = try self.createWindow(
        gui_mod.WIN_SOFTWARE_ID,
        sw_x,
        sw_y,
        sw_w,
        sw_h,
        "Software & images",
    );
    win.setHelpText(
        "Browse and manage VM configuration manifests, " ++
            "virtual disks, and OS images",
    );
    win.parent_window_id = gui_mod.WIN_MENU_ID;
    win.linked_menu_item_id = gui_mod.ICON_MENU_SOFTWARE_ID;
    if (self.getWindow(gui_mod.WIN_MENU_ID)) |mw| {
        mw.child_window_id = gui_mod.WIN_SOFTWARE_ID;
    }
    self.setMenuItemSelected(gui_mod.ICON_MENU_SOFTWARE_ID, true);

    const pad_x: i32 = 14;
    const btn_w: u32 = 112;
    const btn_h: u32 = 28;
    var filter_x: i32 = pad_x;
    const filter_y: i32 = 44;

    const filters = [_]struct { id: u32, label: []const u8, help: []const u8 }{
        .{
            .id = gui_mod.ICON_SW_FILTER_ALL_ID,
            .label = "All (6)",
            .help = "Show all software assets",
        },
        .{
            .id = gui_mod.ICON_SW_FILTER_MAN_ID,
            .label = "Manifests",
            .help = "Filter VM configuration manifests",
        },
        .{
            .id = gui_mod.ICON_SW_FILTER_DSK_ID,
            .label = "Disks",
            .help = "Filter virtual disk images",
        },
        .{
            .id = gui_mod.ICON_SW_FILTER_IMG_ID,
            .label = "OS images",
            .help = "Filter installable ISO and cloud images",
        },
    };
    for (filters) |fl| {
        var btn = Icon.createButton(
            fl.id,
            filter_x,
            filter_y,
            btn_w,
            btn_h,
            fl.label,
        );
        btn.setHelpText(fl.help);
        _ = try win.addIcon(btn);
        filter_x += @as(i32, @intCast(btn_w)) + 8;
    }

    const imp_w: u32 = 150;
    const imp_x = @as(i32, @intCast(sw_w)) - @as(i32, @intCast(imp_w)) - pad_x;
    if (imp_x > filter_x + 8) {
        var b_imp = Icon.createButton(
            gui_mod.ICON_SW_BTN_IMPORT_ID,
            imp_x,
            filter_y,
            imp_w,
            btn_h,
            "+ Import image",
        );
        b_imp.setHelpText("Import external disk image or ISO");
        _ = try win.addIcon(b_imp);
    }

    const card_w: u32 = if (sw_w > @as(u32, @intCast(pad_x * 2)))
        sw_w - @as(u32, @intCast(pad_x * 2))
    else
        200;
    const start_y: i32 = filter_y + @as(i32, @intCast(btn_h)) + 12;

    const items = [_]CardSpec{
        .{
            .id = gui_mod.ICON_SW_ITEM_ALPINE_MAN_ID,
            .title = "alpine-router.toml",
            .subtitle = "Configuration manifest | 2 vCPU, 256MB RAM " ++
                "| VirtIO-Net | 1.4 KB",
            .badge = "Manifest",
            .badge_color = fb.Color.ACCENT_CYAN,
            .help = "VM deployment manifest for Alpine router",
        },
        .{
            .id = gui_mod.ICON_SW_ITEM_DEBIAN_MAN_ID,
            .title = "debian-desktop.toml",
            .subtitle = "Configuration manifest | 4 vCPU, 2048MB RAM " ++
                "| VirtIO-GPU | 2.1 KB",
            .badge = "Manifest",
            .badge_color = fb.Color.ACCENT_CYAN,
            .help = "VM deployment manifest for Debian workstation",
        },
        .{
            .id = gui_mod.ICON_SW_ITEM_ALPINE_RAW_ID,
            .title = "rootfs-alpine.raw",
            .subtitle = "Virtual disk | 2.0 GB allocated | ext4 root " ++
                "filesystem | Attached to alpine-router",
            .badge = "Virtual disk",
            .badge_color = fb.Color.ACCENT_GOLD,
            .help = "Raw virtual disk image for alpine-router",
        },
        .{
            .id = gui_mod.ICON_SW_ITEM_DATA_QCOW_ID,
            .title = "data-volume.qcow2",
            .subtitle = "Virtual disk | 20.0 GB virtual / 3.4 GB disk " ++
                "| QCOW2 sparse allocation",
            .badge = "Virtual disk",
            .badge_color = fb.Color.ACCENT_GOLD,
            .help = "Dynamic QCOW2 storage volume for data pool",
        },
        .{
            .id = gui_mod.ICON_SW_ITEM_ALPINE_ISO_ID,
            .title = "alpine-virt-3.20.iso",
            .subtitle = "OS installation image | 58 MB | Alpine Linux " ++
                "3.20 standard (riscv64)",
            .badge = "OS image",
            .badge_color = fb.Color.ACCENT_GREEN,
            .help = "Bootable installation CD-ROM ISO image",
        },
        .{
            .id = gui_mod.ICON_SW_ITEM_DEBIAN_QCOW_ID,
            .title = "debian-12-cloud.qcow2",
            .subtitle = "OS cloud image | 640 MB | Debian GNU/Linux 12 " ++
                "(Bookworm GenericCloud)",
            .badge = "OS image",
            .badge_color = fb.Color.ACCENT_GREEN,
            .help = "Cloud-init compatible base disk image",
        },
    };

    try addSlateCardList(win, pad_x, start_y, card_w, &items);
}

pub fn buildHardwarePane(self: *DiosixGui) !void {
    const menu_win = self.getWindow(gui_mod.WIN_MENU_ID);
    const hw_x: i32 = if (menu_win) |mw|
        mw.x + @as(i32, @intCast(mw.width)) + BORDER_GAP
    else
        172;
    const hw_y: i32 = BORDER_GAP;
    const avail_w = @as(i32, @intCast(self.width)) - hw_x - BORDER_GAP;
    const hw_w: u32 = if (avail_w > 200) @intCast(avail_w) else 780;
    const ver_y = @as(i32, @intCast(self.height)) - 40 - BORDER_GAP;
    const bottom_y = ver_y - BORDER_GAP;
    const hw_h: u32 = if (bottom_y > hw_y) @intCast(bottom_y - hw_y) else 600;

    const win = try self.createWindow(
        gui_mod.WIN_HARDWARE_ID,
        hw_x,
        hw_y,
        hw_w,
        hw_h,
        "Hardware & peripherals",
    );
    win.setHelpText(
        "Inspect and manage physical hardware, network bridges, " ++
            "and security devices",
    );
    win.parent_window_id = gui_mod.WIN_MENU_ID;
    win.linked_menu_item_id = gui_mod.ICON_MENU_HARDWARE_ID;
    if (self.getWindow(gui_mod.WIN_MENU_ID)) |mw| {
        mw.child_window_id = gui_mod.WIN_HARDWARE_ID;
    }
    self.setMenuItemSelected(gui_mod.ICON_MENU_HARDWARE_ID, true);

    const pad_x: i32 = 14;
    const card_w: u32 = if (hw_w > @as(u32, @intCast(pad_x * 2)))
        hw_w - @as(u32, @intCast(pad_x * 2))
    else
        200;

    const items = [_]CardSpec{
        .{
            .id = gui_mod.ICON_HW_ITEM_ETH0_ID,
            .title = "eth0 (Realtek RTL8111 Gigabit)",
            .subtitle = "Physical NIC | 1000BASE-T full duplex " ++
                "| MAC: 52:54:00:12:34:56 | Link up",
            .badge = "Ethernet",
            .badge_color = fb.Color.ACCENT_GREEN,
            .help = "Primary physical host network interface controller",
        },
        .{
            .id = gui_mod.ICON_HW_ITEM_BR0_ID,
            .title = "br0 (Diosix Hypervisor Bridge)",
            .subtitle = "Virtual L2 switch | 4 tap endpoints attached " ++
                "| MTU 1500 | 10.0.3.254/24",
            .badge = "Virtual bridge",
            .badge_color = fb.Color.ACCENT_CYAN,
            .help = "Host virtual Ethernet bridge interconnecting guest VMs",
        },
        .{
            .id = gui_mod.ICON_HW_ITEM_TPM_ID,
            .title = "VirtIO TPM 2.0 (TCG Compliant)",
            .subtitle = "Hardware cryptoprocessor | PCRs 0-23 valid " ++
                "| Attestation ready",
            .badge = "Security",
            .badge_color = fb.Color.ACCENT_GOLD,
            .help = "Trusted Platform Module providing hardware-rooted " ++
                "cryptographic measurement",
        },
        .{
            .id = gui_mod.ICON_HW_ITEM_YUBIKEY_ID,
            .title = "YubiKey 5 FIPS (USB Security Key)",
            .subtitle = "Hardware token | Serial: 14829104 " ++
                "| Passthrough: Root VM | Ready",
            .badge = "USB token",
            .badge_color = fb.Color.ACCENT_GOLD,
            .help = "FIPS-certified physical USB security key for " ++
                "root operator authentication",
        },
        .{
            .id = gui_mod.ICON_HW_ITEM_NVME_ID,
            .title = "NVMe SSD 1TB (Samsung 980 Pro)",
            .subtitle = "Storage controller | PCIe 4.0 x4 | 1000.2 GB " ++
                "| S.M.A.R.T. health: 100% (41°C)",
            .badge = "Storage",
            .badge_color = fb.Color.ACCENT_GREEN,
            .help = "High-speed non-volatile solid-state storage controller",
        },
        .{
            .id = gui_mod.ICON_HW_ITEM_CPU_ID,
            .title = "Host CPU Cores (RISC-V 64)",
            .subtitle = "16 physical cores (RV64GCBH) @ 2.2 GHz " ++
                "| Hypervisor S/H-mode extensions active",
            .badge = "Processor",
            .badge_color = fb.Color.ACCENT_GREEN,
            .help = "Host physical processors with hardware " ++
                "virtualization extensions",
        },
    };

    try addSlateCardList(win, pad_x, 44, card_w, &items);
}

test {
    @import("std").testing.refAllDecls(@This());
}
