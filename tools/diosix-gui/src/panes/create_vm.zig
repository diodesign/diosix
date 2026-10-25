// Create VM Image Selection & Right-Hand Configuration Pane for Diosix GUI.
//
// Displays available VM images in the left half of the available display space
// when "Create VM" is selected from the main menu. Selecting an image opens a
// right-hand configuration pane in the second half of the available space to
// dial vCPUs, RAM, and storage, with a "Create" button to launch the VM.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("../framebuffer.zig");
const font = @import("../font.zig");
const icon_mod = @import("../icon.zig");
const Icon = icon_mod.Icon;
const window_mod = @import("../window.zig");
const Window = window_mod.Window;
const host_info = @import("../host.zig");
const text_label = @import("../label.zig");
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const panes_guests = @import("guests.zig");
const quota_controls = @import("quota_controls.zig");

const BORDER_GAP = gui_mod.BORDER_GAP;
const WIN_MENU_ID = gui_mod.WIN_MENU_ID;
const WIN_CREATE_VM_ID = gui_mod.WIN_CREATE_VM_ID;
const WIN_CREATE_VM_DETAIL_ID = gui_mod.WIN_CREATE_VM_DETAIL_ID;
const STORAGE_GROUP_ID: u16 = 1;

fn formatImageItemLabel(
    out_buf: *[text_label.LABEL_BUF_BYTES]u8,
    entry: *const host_info.VmImageEntry,
) []const u8 {
    var sz_buf: [host_info.MEM_SIZE_STR_BYTES]u8 = undefined;
    const sz_str = host_info.formatMemorySize(&sz_buf, entry.size_bytes);
    return text_label.fmtLabel(
        out_buf,
        "{s}\n{s} ({s})",
        .{ entry.getTitle(), entry.getFilename(), sz_str },
    );
}

fn resolveMaxVcpus() i32 {
    if (host_info.getHypervisorInfo()) |info| {
        if (info.host_physical_cores > 0) {
            return @intCast(@min(@as(u32, 16), info.host_physical_cores));
        }
    }
    return 4;
}

fn resolveMaxRamMb() i32 {
    if (host_info.getHypervisorInfo()) |info| {
        if (info.host_free_ram_kb >= 128 * 1024) {
            const free_mb: u64 = info.host_free_ram_kb / 1024;
            const aligned_mb: u64 = (free_mb / 64) * 64;
            return @intCast(std.math.clamp(aligned_mb, 128, 8192));
        }
    }
    return 1024;
}

fn onImageItemClicked(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    self.selectCreateVmImage(ic.user_tag) catch {};
}

fn onVcpusSliderChanged(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    self.create_vm_vcpus = @intCast(@max(1, ic.slider_val));
}

fn onRamSliderChanged(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    const raw = @max(128, ic.slider_val);
    const snapped = @divTrunc(raw + 32, 64) * 64;
    ic.setSliderValue(snapped);
    self.create_vm_ram_mb = @intCast(@max(128, ic.slider_val));
}

fn onStorageOptionClicked(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    self.create_vm_storage_idx = ic.user_tag;
}

fn onCreateVmButtonClicked(g: *anyopaque, _: *anyopaque, _: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    const img_idx = self.selected_create_image_idx orelse return;

    var imgs: [host_info.MAX_VM_IMAGES]host_info.VmImageEntry = undefined;
    const img_count = host_info.queryAvailableImages(&imgs);
    if (img_idx >= img_count) return;

    var st_opts: [host_info.MAX_STORAGE_OPTIONS]host_info.StorageOption =
        undefined;
    const st_count = host_info.queryAvailableStorageOptions(&st_opts);
    const st_path = if (self.create_vm_storage_idx < st_count)
        st_opts[self.create_vm_storage_idx].getPath()
    else
        "";

    const img_path = imgs[img_idx].getPath();
    if (img_path.len == 0) return;

    const name_id = gui_mod.ICON_CREATE_VM_NAME_INPUT_ID;
    if (self.findIcon(WIN_CREATE_VM_DETAIL_ID, name_id)) |nic| {
        const typed = std.mem.trim(u8, nic.getText(), " \t");
        if (typed.len > 0) self.setCreateVmName(typed);
    }
    const raw_name = self.getCreateVmName();
    const vm_name = if (raw_name.len > 0)
        raw_name
    else
        quota_controls.defaultVmNameForImage(&imgs[img_idx]);
    var name_buf: [64]u8 = undefined;
    const name_s = std.fmt.bufPrint(&name_buf, "{s}", .{vm_name}) catch "vm";

    host_info.images.recordCreatedVmWithQuota(
        name_s,
        img_path,
        self.create_vm_vcpus,
        self.create_vm_ram_mb,
        self.create_vm_pcpu_pct,
        self.create_vm_ram_quota_mb,
        st_path,
    );
    const tasks = gui_mod.panes.panes_tasks;
    tasks.spawnCreateVmTask(self, name_s, img_path, st_path);

    self.selected_create_image_idx = null;
    _ = self.destroyWindow(WIN_CREATE_VM_DETAIL_ID);
    self.navigateBack() catch {};
}

pub fn selectCreateVmImage(self: *DiosixGui, idx: usize) !void {
    var imgs: [host_info.MAX_VM_IMAGES]host_info.VmImageEntry = undefined;
    const count = host_info.queryAvailableImages(&imgs);
    if (idx >= count) return;

    self.selected_create_image_idx = idx;
    self.setCreateVmName(quota_controls.defaultVmNameForImage(&imgs[idx]));
    self.create_vm_vcpus = imgs[idx].default_vcpus;
    self.create_vm_ram_mb = imgs[idx].default_ram_mb;
    self.create_vm_pcpu_pct = 20;
    self.create_vm_ram_quota_mb = imgs[idx].default_ram_mb;
    self.create_vm_storage_idx = 0;

    if (self.getWindow(WIN_CREATE_VM_ID)) |cwin| {
        for (cwin.icons.items) |*ic| {
            if (ic.id >= gui_mod.ICON_CREATE_VM_ITEM_BASE_ID and
                ic.id < gui_mod.ICON_CREATE_VM_DETAIL_HDR_ID)
            {
                ic.setSelected(ic.user_tag == idx);
            }
        }
        self.markDirty(cwin.getBox());
    }
    try buildCreateVmDetailPane(self);
}

pub fn populateCreateVmWindow(
    self: *DiosixGui,
    win: *Window,
    images: []const host_info.VmImageEntry,
) !void {
    win.icons.clearRetainingCapacity();

    const geom = panes_guests.computeGuestPaneGeometry(self);
    win.width = geom.guests_w;

    const pad_x: i32 = @intCast(self.scalePx(16));
    const hdr_h = self.scalePx(22);
    const hdr_w = if (win.width > @as(u32, @intCast(pad_x * 2)))
        win.width - @as(u32, @intCast(pad_x * 2))
    else
        160;

    var hdr = Icon.createReadOnly(
        gui_mod.ICON_CREATE_VM_HDR_ID,
        pad_x,
        @intCast(self.scalePx(12)),
        hdr_w,
        hdr_h,
        "Available VM images",
    );
    hdr.setCustomColor(fb.Color.INK);
    _ = try win.addIcon(hdr);

    const item_x: i32 = @intCast(self.scalePx(10));
    const item_w: u32 = if (win.width > @as(u32, @intCast(item_x * 2)))
        win.width - @as(u32, @intCast(item_x * 2))
    else
        160;
    const item_h = self.scalePx(42);
    const item_gap: i32 = @intCast(self.scalePx(6));
    var cur_y: i32 = @intCast(self.scalePx(40));

    for (images, 0..) |*img, idx| {
        var lbl_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
        const lbl = formatImageItemLabel(&lbl_buf, img);
        var item = Icon.createMenuItem(
            gui_mod.ICON_CREATE_VM_ITEM_BASE_ID + @as(u32, @intCast(idx)),
            item_x,
            cur_y,
            item_w,
            item_h,
            lbl,
        );
        item.user_tag = idx;
        item.is_selected = (self.selected_create_image_idx != null and
            self.selected_create_image_idx.? == idx);
        item.setHelpText(
            "Select this VM image to configure vCPUs, RAM, and storage",
        );
        item.callback = onImageItemClicked;
        _ = try win.addIcon(item);
        cur_y += @as(i32, @intCast(item_h)) + item_gap;
    }

    const bot_pad = self.scalePx(14);
    win.content_bottom_pad = bot_pad;
    const content_end: i32 = if (images.len > 0) cur_y - item_gap else cur_y;
    const needed_h: u32 = @as(u32, @intCast(@max(0, content_end))) + bot_pad;
    win.natural_height = @min(
        @max(self.scalePx(56), needed_h),
        gui_mod.panes.getBaseMaxPaneHeight(self),
    );
    win.height = @min(win.natural_height, geom.max_h);
    win.scroll_y = std.math.clamp(win.scroll_y, 0, win.getMaxScroll());
}

pub fn buildCreateVmPane(self: *DiosixGui) !void {
    const geom = panes_guests.computeGuestPaneGeometry(self);
    const win = try self.createWindow(
        WIN_CREATE_VM_ID,
        geom.guests_x,
        BORDER_GAP,
        geom.guests_w,
        self.scalePx(gui_mod.MENU_FULL_H),
        null,
    );
    win.setHelpText("Select an available VM image to configure and launch");
    win.parent_window_id = WIN_MENU_ID;
    win.linked_menu_item_id = gui_mod.ICON_MENU_CREATE_VM_ID;
    if (self.getWindow(WIN_MENU_ID)) |mw| {
        mw.child_window_id = WIN_CREATE_VM_ID;
    }
    self.setMenuItemSelected(gui_mod.ICON_MENU_CREATE_VM_ID, true);

    var imgs: [host_info.MAX_VM_IMAGES]host_info.VmImageEntry = undefined;
    const count = host_info.queryAvailableImages(&imgs);
    try populateCreateVmWindow(self, win, imgs[0..count]);

    if (self.selected_create_image_idx != null) {
        try buildCreateVmDetailPane(self);
    }
}

pub fn populateCreateVmDetailWindow(
    self: *DiosixGui,
    win: *Window,
    img: *const host_info.VmImageEntry,
) !void {
    win.icons.clearRetainingCapacity();

    const geom = panes_guests.computeGuestPaneGeometry(self);
    win.width = geom.detail_w;

    const pad_x: i32 = @intCast(self.scalePx(16));
    const inner_w: u32 = if (win.width > @as(u32, @intCast(pad_x * 2)))
        win.width - @as(u32, @intCast(pad_x * 2))
    else
        140;
    const row_h = self.scalePx(24);
    var cur_y: i32 = @intCast(self.scalePx(12));

    var hdr = Icon.createReadOnly(
        gui_mod.ICON_CREATE_VM_DETAIL_HDR_ID,
        pad_x,
        cur_y,
        inner_w,
        row_h,
        img.getTitle(),
    );
    hdr.setCustomColor(fb.Color.INK);
    _ = try win.addIcon(hdr);
    cur_y += @intCast(row_h + self.scalePx(10));

    const lbl_w = self.scalePx(64);
    const sld_x: i32 = pad_x + @as(i32, @intCast(lbl_w));
    const sld_w: u32 = if (inner_w > lbl_w + 8) inner_w - lbl_w - 8 else 100;

    try quota_controls.addCreateVmNameControl(
        self,
        win,
        pad_x,
        lbl_w,
        sld_x,
        sld_w,
        row_h,
        &cur_y,
    );

    var vcpu_lbl = Icon.createReadOnly(
        gui_mod.ICON_CREATE_VM_VCPUS_LBL_ID,
        pad_x,
        cur_y,
        lbl_w,
        row_h,
        "vCPUs",
    );
    vcpu_lbl.setCustomColor(fb.Color.INK_SECONDARY);
    _ = try win.addIcon(vcpu_lbl);

    const max_vcpus = resolveMaxVcpus();
    const cur_vcpus = std.math.clamp(
        @as(i32, @intCast(self.create_vm_vcpus)),
        1,
        max_vcpus,
    );
    self.create_vm_vcpus = @intCast(cur_vcpus);
    var vcpu_sld = Icon.createSlider(
        gui_mod.ICON_CREATE_VM_VCPUS_SLIDER_ID,
        sld_x,
        cur_y,
        sld_w,
        row_h,
        1,
        max_vcpus,
        cur_vcpus,
        "",
    );
    vcpu_sld.setHelpText("Number of virtual CPU cores to assign to this VM");
    vcpu_sld.callback = onVcpusSliderChanged;
    _ = try win.addIcon(vcpu_sld);
    cur_y += @intCast(row_h + self.scalePx(10));

    var ram_lbl = Icon.createReadOnly(
        gui_mod.ICON_CREATE_VM_RAM_LBL_ID,
        pad_x,
        cur_y,
        lbl_w,
        row_h,
        "RAM",
    );
    ram_lbl.setCustomColor(fb.Color.INK_SECONDARY);
    _ = try win.addIcon(ram_lbl);

    const max_ram = resolveMaxRamMb();
    const cur_ram = std.math.clamp(
        @as(i32, @intCast(self.create_vm_ram_mb)),
        128,
        max_ram,
    );
    self.create_vm_ram_mb = @intCast(cur_ram);
    var ram_sld = Icon.createSlider(
        gui_mod.ICON_CREATE_VM_RAM_SLIDER_ID,
        sld_x,
        cur_y,
        sld_w,
        row_h,
        128,
        max_ram,
        cur_ram,
        " MB",
    );
    ram_sld.slider_step = 64;
    ram_sld.setHelpText("Amount of guest logical RAM to assign to this VM");
    ram_sld.callback = onRamSliderChanged;
    _ = try win.addIcon(ram_sld);
    cur_y += @intCast(row_h + self.scalePx(10));

    try quota_controls.addCreateVmQuotaControls(
        self,
        win,
        pad_x,
        inner_w,
        lbl_w,
        sld_x,
        sld_w,
        row_h,
        &cur_y,
    );

    var st_hdr = Icon.createReadOnly(
        gui_mod.ICON_CREATE_VM_STORAGE_HDR_ID,
        pad_x,
        cur_y,
        inner_w,
        row_h,
        "Storage",
    );
    st_hdr.setCustomColor(fb.Color.INK);
    _ = try win.addIcon(st_hdr);
    cur_y += @intCast(row_h + self.scalePx(4));

    var st_opts: [host_info.MAX_STORAGE_OPTIONS]host_info.StorageOption =
        undefined;
    const st_count = host_info.queryAvailableStorageOptions(&st_opts);
    if (self.create_vm_storage_idx >= st_count) {
        self.create_vm_storage_idx = 0;
    }

    for (0..st_count) |i| {
        var tick = Icon.createTickBox(
            gui_mod.ICON_CREATE_VM_STORAGE_BASE_ID + @as(u32, @intCast(i)),
            pad_x,
            cur_y,
            inner_w,
            row_h,
            st_opts[i].getLabel(),
            i == self.create_vm_storage_idx,
            STORAGE_GROUP_ID,
            .exclusive,
        );
        tick.user_tag = i;
        tick.setHelpText("Select storage disk or ISO media to attach");
        tick.callback = onStorageOptionClicked;
        _ = try win.addIcon(tick);
        cur_y += @intCast(row_h + self.scalePx(4));
    }

    cur_y += @intCast(self.scalePx(8));
    const btn_w = self.scalePx(110);
    const btn_h = self.scalePx(32);
    var create_btn = Icon.createButton(
        gui_mod.ICON_CREATE_VM_BTN_ID,
        pad_x,
        cur_y,
        btn_w,
        btn_h,
        "Create",
    );
    create_btn.setHelpText("Create and launch the configured guest VM");
    create_btn.callback = onCreateVmButtonClicked;
    _ = try win.addIcon(create_btn);
    cur_y += @intCast(btn_h);

    const bot_pad = self.scalePx(16);
    win.content_bottom_pad = bot_pad;
    const min_h = self.scalePx(gui_mod.MENU_FULL_H);
    const needed_h: u32 = @as(u32, @intCast(@max(0, cur_y))) + bot_pad;
    win.natural_height = @min(
        @max(min_h, needed_h),
        gui_mod.panes.getBaseMaxPaneHeight(self),
    );
    win.height = @min(win.natural_height, geom.max_h);
}

pub fn buildCreateVmDetailPane(self: *DiosixGui) !void {
    const sel_idx = self.selected_create_image_idx orelse {
        _ = self.destroyWindow(WIN_CREATE_VM_DETAIL_ID);
        return;
    };

    var imgs: [host_info.MAX_VM_IMAGES]host_info.VmImageEntry = undefined;
    const count = host_info.queryAvailableImages(&imgs);
    if (sel_idx >= count) {
        self.selected_create_image_idx = null;
        _ = self.destroyWindow(WIN_CREATE_VM_DETAIL_ID);
        return;
    }

    const geom = panes_guests.computeGuestPaneGeometry(self);
    const win = try self.createWindow(
        WIN_CREATE_VM_DETAIL_ID,
        geom.detail_x,
        BORDER_GAP,
        geom.detail_w,
        self.scalePx(gui_mod.MENU_FULL_H),
        null,
    );
    win.setHelpText("Configure vCPUs, RAM, and storage for the new guest VM");
    try populateCreateVmDetailWindow(self, win, &imgs[sel_idx]);
}

test {
    std.testing.refAllDecls(@This());
}
