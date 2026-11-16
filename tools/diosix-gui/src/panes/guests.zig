// Running Guest VMs Pane & Right-Hand Guest Detail/Action Pane for Diosix GUI.
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
pub const detail = @import("guests/detail.zig");

pub const populateGuestDetailWindow = detail.populateGuestDetailWindow;
pub const buildGuestDetailPane = detail.buildGuestDetailPane;

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
    return .{
        .guests_x = guests_x,
        .guests_w = guests_w,
        .detail_x = detail_x,
        .detail_w = detail_w,
        .max_h = gui_mod.panes.getMaxPaneHeight(self),
    };
}

fn formatGuestItemLabel(
    out_buf: *[text_label.LABEL_BUF_BYTES]u8,
    guest: *const host_info.RunningGuest,
    tree_prefix: []const u8,
) []const u8 {
    var ram_buf: [host_info.MEM_SIZE_STR_BYTES]u8 = undefined;
    const ram_str = host_info.formatMemorySize(&ram_buf, guest.ram_bytes);
    const vcpu_word = if (guest.vcpus == 1) "vCPU" else "vCPUs";
    return text_label.fmtLabel(
        out_buf,
        "{s}{s} ({s}, {s} {s})\n{d} {s}, {d}% pCPU usage, {s} RAM",
        .{
            tree_prefix,
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

    const hdr_lbl = if (guests.len > 0 and guests[0].has_parent)
        "Local VM tree (parent: CID 0)"
    else
        "Local VM tree (parent: hypervisor)";
    var hdr = Icon.createReadOnly(
        gui_mod.ICON_GUESTS_HDR_ID,
        pad_x,
        @intCast(self.scalePx(12)),
        hdr_w,
        hdr_h,
        hdr_lbl,
    );
    hdr.setCustomColor(fb.Color.INK);
    _ = try win.addIcon(hdr);

    const item_x: i32 = @intCast(self.scalePx(10));
    const item_w: u32 = if (win.width > @as(u32, @intCast(item_x * 2)))
        win.width - @as(u32, @intCast(item_x * 2))
    else
        160;
    const indent_px = self.scalePx(14);
    const item_h = self.scalePx(42);
    const item_gap: i32 = @intCast(self.scalePx(6));
    var cur_y: i32 = @intCast(self.scalePx(40));

    var total_children: usize = 0;
    for (guests) |*g| {
        if (!g.isSelf()) total_children += 1;
    }
    var seen_children: usize = 0;

    for (guests, 0..) |*guest, idx| {
        const is_self = guest.isSelf();
        const tree_pfx: []const u8 = if (is_self) "" else blk: {
            seen_children += 1;
            break :blk if (seen_children == total_children) "└─ " else "├─ ";
        };
        const row_x: i32 = if (is_self)
            item_x
        else
            item_x + @as(i32, @intCast(indent_px));
        const row_w: u32 = if (is_self) item_w else item_w -| indent_px;
        var lbl_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
        const lbl = formatGuestItemLabel(&lbl_buf, guest, tree_pfx);
        var item = Icon.createMenuItem(
            gui_mod.ICON_GUESTS_ITEM_BASE_ID + @as(u32, @intCast(idx)),
            row_x,
            cur_y,
            row_w,
            item_h,
            lbl,
        );
        item.user_tag = @intCast(guest.cid);
        item.is_selected = (self.selected_guest_cid != null and
            self.selected_guest_cid.? == guest.cid);
        item.setHelpText(
            "Select VM to view quotas, local storage, and lifecycle options",
        );
        item.callback = onGuestItemClicked;
        _ = try win.addIcon(item);
        cur_y += @as(i32, @intCast(item_h)) + item_gap;
    }

    if (total_children > 0) {
        const note_h = self.scalePx(20);
        var note = Icon.createReadOnly(
            gui_mod.ICON_GUESTS_TREE_NOTE_ID,
            pad_x,
            cur_y,
            hdr_w,
            note_h,
            "Child subtrees are opaque to parent VMs",
        );
        note.setCustomColor(fb.Color.TEXT_MUTED);
        _ = try win.addIcon(note);
        cur_y += @as(i32, @intCast(note_h)) + item_gap;
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

pub fn updateGuestsPaneData(self: *DiosixGui) void {
    var prev_buf: [host_info.MAX_RUNNING_GUESTS]host_info.RunningGuest =
        undefined;
    const prev_count = if (host_info.guests.hasCachedGuests())
        host_info.queryRunningGuests(&prev_buf)
    else
        0;
    var guests_buf: [host_info.MAX_RUNNING_GUESTS]host_info.RunningGuest =
        undefined;
    const count = host_info.sampleRunningGuests(&guests_buf);
    if (prev_count > 0) {
        panes_terminal.reconcileRunningGuests(
            self,
            prev_buf[0..prev_count],
            guests_buf[0..count],
        );
    }

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
    _ = detail;
    std.testing.refAllDecls(@This());
}
