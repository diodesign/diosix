// Right-Hand Guest Detail and Action Pane Builder for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("../../framebuffer.zig");
const font = @import("../../font.zig");
const icon_mod = @import("../../icon.zig");
const Icon = icon_mod.Icon;
const window_mod = @import("../../window.zig");
const Window = window_mod.Window;
const host_info = @import("../../host.zig");
const text_label = @import("../../label.zig");
const gui_mod = @import("../../gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const quota_controls = @import("../quota_controls.zig");
const panes_terminal = @import("../terminal.zig");
const guests_pane = @import("../guests.zig");

const BORDER_GAP = gui_mod.BORDER_GAP;
const WIN_GUEST_DETAIL_ID = gui_mod.WIN_GUEST_DETAIL_ID;

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

pub fn populateGuestDetailWindow(
    self: *DiosixGui,
    win: *Window,
    guest: *const host_info.RunningGuest,
) !void {
    win.icons.clearRetainingCapacity();

    const geom = guests_pane.computeGuestPaneGeometry(self);
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

    try panes_terminal.addGuestDetailTerminalButtons(
        self,
        win,
        guest,
        pad_x,
        inner_w,
        item_h,
        &cur_y,
    );

    if (!guest.isSelf()) {
        var sub_ic = Icon.createReadOnly(
            gui_mod.ICON_GUEST_SUBTREE_NOTE_ID,
            pad_x,
            cur_y,
            inner_w,
            row_h,
            "Subtree: opaque (managed by child)",
        );
        sub_ic.setCustomColor(fb.Color.INK_SECONDARY);
        _ = try win.addIcon(sub_ic);
        cur_y += @intCast(row_h + self.scalePx(6));

        var restart_item = Icon.createButton(
            gui_mod.ICON_GUEST_RESTART_ID,
            pad_x,
            cur_y,
            inner_w,
            item_h,
            "Restart",
        );
        restart_item.user_tag = @intCast(guest.cid);
        restart_item.setHelpText("Restart the selected guest VM");
        restart_item.callback = onGuestRestartClicked;
        _ = try win.addIcon(restart_item);
        cur_y += @intCast(item_h + self.scalePx(6));

        var shutdown_item = Icon.createButton(
            gui_mod.ICON_GUEST_SHUTDOWN_ID,
            pad_x,
            cur_y,
            inner_w,
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
        cur_y += @intCast(self.scalePx(4));
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

    const geom = guests_pane.computeGuestPaneGeometry(self);
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

test {
    std.testing.refAllDecls(@This());
}
