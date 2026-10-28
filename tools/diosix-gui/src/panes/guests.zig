// Running Guest VMs Pane & Right-Hand Guest Detail/Action Pane for Diosix GUI.
//
// Displays all running guest VMs alongside the main menu, occupying half the
// available horizontal space next to the main menu, with live vCPU, pCPU%, and
// RAM telemetry updated every 2 seconds (configurable in the Config pane).
// Selecting a guest opens a detail/action pane to the right with Restart and
// Shutdown controls (omitted for the Root VM) and attached storage inventory.
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
const quota_controls = @import("quota_controls.zig");
const panes_terminal = @import("terminal.zig");

const BORDER_GAP = gui_mod.BORDER_GAP;
const WIN_MENU_ID = gui_mod.WIN_MENU_ID;
const WIN_GUESTS_ID = gui_mod.WIN_GUESTS_ID;
const WIN_GUEST_DETAIL_ID = gui_mod.WIN_GUEST_DETAIL_ID;

pub const GuestPaneGeometry = struct {
    guests_x: i32,
    guests_w: u32,
    detail_x: i32,
    detail_w: u32,
    max_h: u32,
};

pub fn computeGuestPaneGeometry(self: *DiosixGui) GuestPaneGeometry {
    const guests_x = self.getChildTargetX();
    const raw_avail = @as(i32, @intCast(self.width)) - BORDER_GAP - guests_x;
    const avail_w: u32 = if (raw_avail > 200) @intCast(raw_avail) else 400;
    const gap_u: u32 = @intCast(BORDER_GAP);
    const guests_w: u32 = if (avail_w > gap_u + 120)
        (avail_w - gap_u) / 2
    else
        avail_w / 2;
    const detail_x: i32 = guests_x + @as(i32, @intCast(guests_w)) + BORDER_GAP;
    const detail_w: u32 = if (avail_w > guests_w + gap_u)
        avail_w - guests_w - gap_u
    else
        guests_w;

    const max_h = gui_mod.panes.getMaxPaneHeight(self);

    return .{
        .guests_x = guests_x,
        .guests_w = guests_w,
        .detail_x = detail_x,
        .detail_w = detail_w,
        .max_h = max_h,
    };
}

fn formatGuestItemLabel(
    out_buf: *[text_label.LABEL_BUF_BYTES]u8,
    guest: *const host_info.RunningGuest,
) []const u8 {
    var ram_buf: [host_info.MEM_SIZE_STR_BYTES]u8 = undefined;
    const ram_str = host_info.formatMemorySize(&ram_buf, guest.ram_bytes);
    const vcpu_word = if (guest.vcpus == 1) "vCPU" else "vCPUs";
    return text_label.fmtLabel(
        out_buf,
        "{s} ({s}, {s} {s})\n{d} {s}, {d}% pCPU usage, {s} RAM",
        .{
            guest.getInstanceName(),
            guest.getImageName(),
            guest.getArchLabel(),
            guest.getVirtModeLabel(),
            guest.vcpus,
            vcpu_word,
            guest.pcpu_percent,
            ram_str,
        },
    );
}

fn onGuestItemClicked(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    const cid: u64 = @intCast(ic.user_tag);
    self.selectRunningGuest(cid) catch {};
}

fn onGuestRestartClicked(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    const cid: u64 = @intCast(ic.user_tag);
    if (cid < 2) return;
    host_info.guests.mock_last_guest_action = .{
        .cid = cid,
        .action = .restart,
    };
    const dsx_bin = host_info.images.resolveDsxBinarySlice();
    var cid_buf: [24]u8 = undefined;
    const cid_s = std.fmt.bufPrint(&cid_buf, "{d}", .{cid}) catch return;
    var title_buf: [64]u8 = undefined;
    const title_s = std.fmt.bufPrint(
        &title_buf,
        "Restarting VM (CID {d})",
        .{cid},
    ) catch "Restarting VM";
    const argv = [_][]const u8{ dsx_bin, "restart", cid_s };
    _ = self.spawnBackgroundTask(
        title_s,
        "Reloading guest image and restarting vCPUs...",
        &argv,
    );
    self.updateGuestsPaneData();
}

fn onGuestShutdownClicked(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    const cid: u64 = @intCast(ic.user_tag);
    if (host_info.shutdownGuestVm(cid)) {
        panes_terminal.discardGuestSshSession(self, cid);
        self.selected_guest_cid = null;
        _ = self.destroyWindow(WIN_GUEST_DETAIL_ID);
        self.updateGuestsPaneData();
    }
}

pub fn selectRunningGuest(self: *DiosixGui, cid: u64) !void {
    self.selected_guest_cid = cid;
    if (self.getWindow(WIN_GUESTS_ID)) |gwin| {
        for (gwin.icons.items) |*ic| {
            if (ic.id >= gui_mod.ICON_GUESTS_ITEM_BASE_ID and
                ic.id < gui_mod.ICON_GUEST_DETAIL_HDR_ID)
            {
                ic.setSelected(ic.user_tag == @as(usize, @intCast(cid)));
            }
        }
        self.markDirty(gwin.getBox());
    }
    try buildGuestDetailPane(self);
}

pub fn populateGuestsWindow(
    self: *DiosixGui,
    win: *Window,
    guests: []const host_info.RunningGuest,
) !void {
    win.icons.clearRetainingCapacity();

    const geom = computeGuestPaneGeometry(self);
    win.width = geom.guests_w;

    const pad_x: i32 = @intCast(self.scalePx(16));
    const hdr_h = self.scalePx(22);
    const hdr_w = if (win.width > @as(u32, @intCast(pad_x * 2)))
        win.width - @as(u32, @intCast(pad_x * 2))
    else
        160;

    var hdr = Icon.createReadOnly(
        gui_mod.ICON_GUESTS_HDR_ID,
        pad_x,
        @intCast(self.scalePx(12)),
        hdr_w,
        hdr_h,
        "Running guest VMs",
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

    for (guests, 0..) |*guest, idx| {
        var lbl_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
        const lbl = formatGuestItemLabel(&lbl_buf, guest);
        var item = Icon.createMenuItem(
            gui_mod.ICON_GUESTS_ITEM_BASE_ID + @as(u32, @intCast(idx)),
            item_x,
            cur_y,
            item_w,
            item_h,
            lbl,
        );
        item.user_tag = @intCast(guest.cid);
        item.is_selected = (self.selected_guest_cid != null and
            self.selected_guest_cid.? == guest.cid);
        item.setHelpText(
            "Select guest VM to view attached storage and lifecycle options",
        );
        item.callback = onGuestItemClicked;
        _ = try win.addIcon(item);
        cur_y += @as(i32, @intCast(item_h)) + item_gap;
    }

    const bot_pad = self.scalePx(14);
    win.content_bottom_pad = bot_pad;
    const content_end: i32 = if (guests.len > 0) cur_y - item_gap else cur_y;
    const needed_h: u32 = @as(u32, @intCast(@max(0, content_end))) + bot_pad;
    win.natural_height = @min(
        @max(self.scalePx(56), needed_h),
        gui_mod.panes.getBaseMaxPaneHeight(self),
    );
    win.height = @min(win.natural_height, geom.max_h);
    win.scroll_y = std.math.clamp(win.scroll_y, 0, win.getMaxScroll());
}

pub fn buildGuestsPane(self: *DiosixGui) !void {
    const geom = computeGuestPaneGeometry(self);
    const win = try self.createWindow(
        WIN_GUESTS_ID,
        geom.guests_x,
        BORDER_GAP,
        geom.guests_w,
        self.scalePx(gui_mod.MENU_FULL_H),
        null,
    );
    win.setHelpText("Running guest VMs and real-time resource usage");

    var guests_buf: [host_info.MAX_RUNNING_GUESTS]host_info.RunningGuest =
        undefined;
    const count = host_info.queryRunningGuests(&guests_buf);
    try populateGuestsWindow(self, win, guests_buf[0..count]);

    if (self.selected_guest_cid != null) {
        try buildGuestDetailPane(self);
    }
}

pub fn populateGuestDetailWindow(
    self: *DiosixGui,
    win: *Window,
    guest: *const host_info.RunningGuest,
) !void {
    win.icons.clearRetainingCapacity();

    const geom = computeGuestPaneGeometry(self);
    win.width = geom.detail_w;

    const pad_x: i32 = @intCast(self.scalePx(16));
    const inner_w: u32 = if (win.width > @as(u32, @intCast(pad_x * 2)))
        win.width - @as(u32, @intCast(pad_x * 2))
    else
        140;
    const row_h = self.scalePx(22);
    const item_h = self.scalePx(28);
    var cur_y: i32 = @intCast(self.scalePx(12));

    var title_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
    const title_str = text_label.fmtLabel(
        &title_buf,
        "{s} ({s}, {s} {s})",
        .{
            guest.getInstanceName(),
            guest.getImageName(),
            guest.getArchLabel(),
            guest.getVirtModeLabel(),
        },
    );
    var hdr = Icon.createReadOnly(
        gui_mod.ICON_GUEST_DETAIL_HDR_ID,
        pad_x,
        cur_y,
        inner_w,
        row_h,
        title_str,
    );
    hdr.setCustomColor(fb.Color.INK);
    _ = try win.addIcon(hdr);
    cur_y += @intCast(row_h + self.scalePx(6));

    const item_x: i32 = @intCast(self.scalePx(10));
    const menu_w: u32 = if (win.width > @as(u32, @intCast(item_x * 2)))
        win.width - @as(u32, @intCast(item_x * 2))
    else
        inner_w;

    try panes_terminal.addGuestDetailTerminalButtons(
        self,
        win,
        guest,
        item_x,
        menu_w,
        item_h,
        &cur_y,
    );

    if (!guest.is_root) {
        var restart_item = Icon.createMenuItem(
            gui_mod.ICON_GUEST_RESTART_ID,
            item_x,
            cur_y,
            menu_w,
            item_h,
            "Restart",
        );
        restart_item.user_tag = @intCast(guest.cid);
        restart_item.setHelpText("Restart the selected guest VM");
        restart_item.callback = onGuestRestartClicked;
        _ = try win.addIcon(restart_item);
        cur_y += @intCast(item_h + self.scalePx(4));

        var shutdown_item = Icon.createMenuItem(
            gui_mod.ICON_GUEST_SHUTDOWN_ID,
            item_x,
            cur_y,
            menu_w,
            item_h,
            "Shutdown",
        );
        shutdown_item.user_tag = @intCast(guest.cid);
        shutdown_item.setHelpText(
            "Shut down and terminate the selected guest VM",
        );
        shutdown_item.callback = onGuestShutdownClicked;
        _ = try win.addIcon(shutdown_item);
        cur_y += @intCast(item_h + self.scalePx(10));
    } else {
        cur_y += @intCast(self.scalePx(6));
    }

    var pcpu_hdr = Icon.createReadOnly(
        gui_mod.ICON_GUEST_PCPU_HDR_ID,
        pad_x,
        cur_y,
        inner_w,
        row_h,
        "pCPU usage",
    );
    pcpu_hdr.setCustomColor(fb.Color.INK);
    _ = try win.addIcon(pcpu_hdr);
    cur_y += @intCast(row_h + self.scalePx(4));

    const graph_h = self.scalePx(72);
    var pcpu_graph = Icon.createLineGraph(
        gui_mod.ICON_GUEST_PCPU_GRAPH_ID,
        pad_x,
        cur_y,
        inner_w,
        graph_h,
        guest.getPcpuHistory(),
    );
    pcpu_graph.setCustomColor(fb.Color.INK);
    pcpu_graph.setHelpText(
        "Physical CPU core usage over the past 60 update intervals",
    );
    _ = try win.addIcon(pcpu_graph);
    cur_y += @intCast(graph_h + self.scalePx(10));

    try quota_controls.addGuestDetailQuotaControls(
        self,
        win,
        guest,
        pad_x,
        inner_w,
        row_h,
        &cur_y,
    );

    var st_hdr = Icon.createReadOnly(
        gui_mod.ICON_GUEST_STORAGE_HDR_ID,
        pad_x,
        cur_y,
        inner_w,
        row_h,
        "Attached storage",
    );
    st_hdr.setCustomColor(fb.Color.INK);
    _ = try win.addIcon(st_hdr);
    cur_y += @intCast(row_h + self.scalePx(4));

    if (guest.storage_count == 0) {
        var none_ic = Icon.createReadOnly(
            gui_mod.ICON_GUEST_STORAGE_BASE_ID,
            pad_x,
            cur_y,
            inner_w,
            row_h,
            "None",
        );
        none_ic.setCustomColor(fb.Color.INK_SECONDARY);
        _ = try win.addIcon(none_ic);
        cur_y += @intCast(row_h);
    } else {
        for (0..guest.storage_count) |idx| {
            const st_txt = guest.getStorageItem(idx);
            const wm = font.measureWrappedText(st_txt, inner_w);
            const line_h = font.getActiveLineHeight();
            const item_row_h = @max(row_h, wm.height + (row_h -| line_h));
            var st_ic = Icon.createReadOnly(
                gui_mod.ICON_GUEST_STORAGE_BASE_ID + @as(u32, @intCast(idx)),
                pad_x,
                cur_y,
                inner_w,
                item_row_h,
                st_txt,
            );
            st_ic.wrap_text = true;
            st_ic.setCustomColor(fb.Color.INK_SECONDARY);
            _ = try win.addIcon(st_ic);
            cur_y += @intCast(item_row_h + self.scalePx(2));
        }
    }

    const bot_pad = self.scalePx(14);
    win.content_bottom_pad = bot_pad;
    const needed_h: u32 = @as(u32, @intCast(@max(0, cur_y))) + bot_pad;
    win.natural_height = @min(
        @max(self.scalePx(56), needed_h),
        gui_mod.panes.getBaseMaxPaneHeight(self),
    );
    win.height = @min(win.natural_height, geom.max_h);
    win.scroll_y = std.math.clamp(win.scroll_y, 0, win.getMaxScroll());
}

pub fn buildGuestDetailPane(self: *DiosixGui) !void {
    const sel_cid = self.selected_guest_cid orelse {
        _ = self.destroyWindow(WIN_GUEST_DETAIL_ID);
        return;
    };

    var guests_buf: [host_info.MAX_RUNNING_GUESTS]host_info.RunningGuest =
        undefined;
    const count = host_info.queryRunningGuests(&guests_buf);
    var found_idx: ?usize = null;
    for (0..count) |i| {
        if (guests_buf[i].cid == sel_cid) {
            found_idx = i;
            break;
        }
    }
    const idx = found_idx orelse {
        self.selected_guest_cid = null;
        _ = self.destroyWindow(WIN_GUEST_DETAIL_ID);
        return;
    };

    const geom = computeGuestPaneGeometry(self);
    const win = try self.createWindow(
        WIN_GUEST_DETAIL_ID,
        geom.detail_x,
        BORDER_GAP,
        geom.detail_w,
        self.scalePx(gui_mod.MENU_FULL_H),
        null,
    );
    win.setHelpText("Selected guest VM actions and attached storage");
    try populateGuestDetailWindow(self, win, &guests_buf[idx]);
}

pub fn updateGuestsPaneData(self: *DiosixGui) void {
    var guests_buf: [host_info.MAX_RUNNING_GUESTS]host_info.RunningGuest =
        undefined;
    const count = host_info.sampleRunningGuests(&guests_buf);

    const gwin = self.getWindow(WIN_GUESTS_ID) orelse return;
    const old_box = gwin.getBox();
    populateGuestsWindow(self, gwin, guests_buf[0..count]) catch return;
    if (!gwin.is_onscreen) return;
    self.markDirty(old_box.merge(gwin.getBox()));

    if (self.selected_guest_cid) |sel_cid| {
        var found: ?*const host_info.RunningGuest = null;
        for (0..count) |i| {
            if (guests_buf[i].cid == sel_cid) {
                found = &guests_buf[i];
                break;
            }
        }
        if (found) |guest_ptr| {
            if (self.getWindow(WIN_GUEST_DETAIL_ID)) |dwin| {
                const old_dbox = dwin.getBox();
                populateGuestDetailWindow(self, dwin, guest_ptr) catch {};
                self.markDirty(old_dbox.merge(dwin.getBox()));
            }
        } else {
            self.selected_guest_cid = null;
            _ = self.destroyWindow(WIN_GUEST_DETAIL_ID);
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
