// Per-VM Terminal Session State Machine & Viewport Grid Sizing for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const font = @import("../font.zig");
const host_info = @import("../host.zig");
const text_label = @import("../label.zig");
const terminal_mod = @import("../terminal.zig");
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;

const BORDER_GAP = gui_mod.BORDER_GAP;
pub const WIN_TERMINAL_ID: u32 = 205;

pub fn findGuestNameByCid(
    cid: u64,
    name_buf: *[host_info.GUEST_NAME_BYTES]u8,
) []const u8 {
    var guests_buf: [host_info.MAX_RUNNING_GUESTS]host_info.RunningGuest =
        undefined;
    const count = host_info.queryRunningGuests(&guests_buf);
    for (0..count) |i| {
        if (guests_buf[i].cid == cid) {
            const inst = guests_buf[i].getInstanceName();
            return text_label.fmtLabel(name_buf, "{s}", .{inst});
        }
    }
    if (cid <= 1) return "root";
    return text_label.fmtLabel(name_buf, "guest-{d}", .{cid});
}

pub fn hasLiveSshSession(self: *const DiosixGui, cid: u64) bool {
    if (self.terminal.active and self.terminal.mode == .ssh and
        !self.terminal.exited and self.terminal.target_cid == cid)
    {
        return true;
    }
    for (&self.bg_ssh_sessions) |*s| {
        if (s.active and s.mode == .ssh and !s.exited and s.target_cid == cid) {
            return true;
        }
    }
    return false;
}

pub fn discardGuestSshSession(self: *DiosixGui, cid: u64) void {
    const prev_inv = self.terminal.inverted;
    if (self.terminal.active and self.terminal.mode == .ssh and
        self.terminal.target_cid == cid)
    {
        self.terminal.closeSession();
        self.terminal.inverted = prev_inv;
    }
    for (&self.bg_ssh_sessions) |*s| {
        if (s.active and s.target_cid == cid) s.closeSession();
    }
}

pub fn onTerminalNavigateBack(self: *DiosixGui) void {
    if (!self.terminal.active) return;
    const prev_inv = self.terminal.inverted;
    if (self.terminal.mode == .console or self.terminal.exited) {
        self.terminal.closeSession();
        self.terminal.inverted = prev_inv;
        return;
    }

    var target_slot: usize = 0;
    var found_slot = false;
    for (&self.bg_ssh_sessions, 0..) |*s, idx| {
        if (s.active and s.target_cid == self.terminal.target_cid) {
            target_slot = idx;
            found_slot = true;
            break;
        }
    }
    if (!found_slot) {
        for (&self.bg_ssh_sessions, 0..) |*s, idx| {
            if (!s.active or s.exited) {
                if (s.active) s.closeSession();
                target_slot = idx;
                found_slot = true;
                break;
            }
        }
    }
    if (!found_slot) {
        self.bg_ssh_sessions[0].closeSession();
        target_slot = 0;
    }

    self.bg_ssh_sessions[target_slot] = self.terminal;
    self.terminal = .{ .inverted = prev_inv };
}

pub fn restoreBgSshSession(self: *DiosixGui, cid: u64) bool {
    for (&self.bg_ssh_sessions) |*s| {
        if (s.active and s.target_cid == cid) {
            if (s.exited or s.mode != .ssh) {
                s.closeSession();
                return false;
            }
            const prev_inv = self.terminal.inverted;
            self.terminal = s.*;
            self.terminal.inverted = prev_inv;
            s.* = .{};
            return true;
        }
    }
    return false;
}

pub fn computeTermRect(
    self: *DiosixGui,
) struct { x: i32, w: u32, h: u32 } {
    const term_x = self.getChildTargetX();
    const raw_w = @as(i32, @intCast(self.width)) - BORDER_GAP - term_x;
    const term_w: u32 = if (raw_w > 280) @intCast(raw_w) else 520;
    const base_max_h = gui_mod.panes.getMaxPaneHeight(self);
    const osk_reserve: u32 = if (self.osk_state.visible) 228 else 0;
    const term_h: u32 = if (base_max_h > osk_reserve + 180)
        base_max_h - osk_reserve
    else
        base_max_h;
    return .{ .x = term_x, .w = term_w, .h = term_h };
}

pub fn computeViewportGrid(
    self: *DiosixGui,
) struct { cols: usize, rows: usize } {
    const rect = computeTermRect(self);
    const pad_x = self.scalePx(14);
    const top_h = self.scalePx(74);
    const bot_pad = self.scalePx(12);
    const inner_pad = self.scalePx(8) * 2;
    const inner_w = (rect.w -| (pad_x * 2)) -| inner_pad;
    const inner_h = (rect.h -| (top_h + bot_pad)) -| inner_pad;

    const font_h = font.getActiveLineHeight();
    const cell_w = @max(4, font.getMonoCharAdvanceAtHeight(font_h));
    const row_step = font_h + @max(2, font_h / 6);

    const cols = std.math.clamp(
        @as(usize, inner_w / cell_w),
        20,
        terminal_mod.MAX_TERM_COLS,
    );
    const rows = std.math.clamp(
        @as(usize, inner_h / row_step),
        6,
        terminal_mod.MAX_TERM_ROWS,
    );
    return .{ .cols = cols, .rows = rows };
}

pub fn pollTerminal(self: *DiosixGui) void {
    if (self.terminal.active) {
        if (self.terminal.poll()) self.markWindowDirty(WIN_TERMINAL_ID);
    }
    for (&self.bg_ssh_sessions) |*s| {
        if (s.active) {
            _ = s.poll();
            if (s.exited) {
                s.closeSession();
                if (self.getWindow(gui_mod.WIN_GUEST_DETAIL_ID) != null) {
                    self.updateGuestsPaneData();
                }
            }
        }
    }
}

pub fn isTerminalWindowOpen(self: *DiosixGui) bool {
    if (!self.terminal.active) return false;
    const win = self.getWindow(WIN_TERMINAL_ID) orelse return false;
    return win.is_onscreen;
}

test {
    std.testing.refAllDecls(@This());
}
