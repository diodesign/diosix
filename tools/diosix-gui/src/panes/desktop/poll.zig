// Guest VirtIO-GPU Scanout & Cursor Polling State for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const host_info = @import("../../host.zig");
const text_label = @import("../../label.zig");
const gui_mod = @import("../../gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const parent = @import("../desktop.zig");
const render = @import("render.zig");
const sbi = @import("interface").sbi;

pub const ScanoutPollStatus = struct {
    updated: bool,
    full: bool,
};

fn ensureCursorBuf(self: *DiosixGui) ?*[sbi.CURSOR_MAX_PIXELS]u32 {
    if (self.desktop.cursor_pixels == null) {
        const buf = self.allocator.alloc(
            u32,
            sbi.CURSOR_MAX_PIXELS,
        ) catch return null;
        @memset(buf, 0);
        self.desktop.cursor_pixels = buf;
    }
    const slice = self.desktop.cursor_pixels.?;
    if (slice.len < sbi.CURSOR_MAX_PIXELS) return null;
    return slice[0..sbi.CURSOR_MAX_PIXELS];
}

/// Polls guest VirtIO-GPU scanout + cursor overlay and updates `self.desktop`.
pub fn pollDesktopScanout(self: *DiosixGui) ScanoutPollStatus {
    const none = ScanoutPollStatus{ .updated = false, .full = false };
    if (!self.desktop.active) return none;
    const desired = parent.desiredGuestDisplaySize(self);
    const cbuf = ensureCursorBuf(self);
    var res = host_info.desktop.pollGuestScanout(
        self.desktop.target_cid,
        self.desktop.frame_seq,
        self.desktop.cursor_seq,
        self.desktop.cursor_visible,
        cbuf,
        self.desktop.frame_buf,
        desired.width,
        desired.height,
    ) orelse return none;

    if (res.zero_copy) {
        if (self.desktop.frame_buf) |old| {
            self.allocator.free(old);
            self.desktop.frame_buf = null;
        }
        self.desktop.zero_copy_pixels = res.pixels;
    } else {
        self.desktop.zero_copy_pixels = null;
        if (res.active and res.width > 0 and res.height > 0) {
            const need_px = std.math.mul(
                usize,
                @as(usize, res.width),
                @as(usize, res.height),
            ) catch return none;
            if (need_px > 0 and
                need_px <= host_info.desktop.MAX_GPU_SCANOUT_PIXELS)
            {
                const cur_len = if (self.desktop.frame_buf) |b| b.len else 0;
                if (cur_len < need_px) {
                    if (self.desktop.frame_buf) |old| {
                        self.allocator.free(old);
                        self.desktop.frame_buf = null;
                    }
                    const new_buf = self.allocator.alloc(u32, need_px) catch
                        return none;
                    @memset(new_buf, 0);
                    self.desktop.frame_buf = new_buf;
                    self.desktop.frame_seq = 0;
                    res = host_info.desktop.pollGuestScanout(
                        self.desktop.target_cid,
                        0,
                        self.desktop.cursor_seq,
                        self.desktop.cursor_visible,
                        cbuf,
                        self.desktop.frame_buf,
                        desired.width,
                        desired.height,
                    ) orelse return none;
                }
            }
        }
    }

    const state_changed = (res.active != self.desktop.scanout_active) or
        (res.width != self.desktop.fb_width) or
        (res.height != self.desktop.fb_height);
    const cursor_changed = res.zero_copy and
        (res.cursor_visible != self.desktop.cursor_visible or
            res.cursor_x != self.desktop.cursor_x or
            res.cursor_y != self.desktop.cursor_y or
            res.cursor_shape_updated);
    self.desktop.scanout_active = res.active;
    self.desktop.fb_width = res.width;
    self.desktop.fb_height = res.height;
    self.desktop.frame_seq = res.frame_seq;
    self.desktop.cursor_visible = res.cursor_visible;
    self.desktop.cursor_x = res.cursor_x;
    self.desktop.cursor_y = res.cursor_y;
    self.desktop.cursor_hot_x = res.cursor_hot_x;
    self.desktop.cursor_hot_y = res.cursor_hot_y;
    self.desktop.cursor_w = res.cursor_w;
    self.desktop.cursor_h = res.cursor_h;
    self.desktop.cursor_seq = res.cursor_seq;

    const any_upd = res.updated or state_changed or cursor_changed;
    if (!any_upd) return none;
    if (res.zero_copy and !state_changed and
        !self.desktop.viewport_box.isEmpty() and
        res.dirty_w > 0 and res.dirty_h > 0)
    {
        self.desktop.last_dirty_box = render.mapDirtyRectToViewport(
            self.desktop.viewport_box,
            res.width,
            res.height,
            res.dirty_x,
            res.dirty_y,
            res.dirty_w,
            res.dirty_h,
        );
        self.desktop.has_dirty_rect = true;
        return .{ .updated = true, .full = false };
    }
    self.desktop.has_dirty_rect = false;
    return .{ .updated = true, .full = true };
}

/// Polls active child desktop scanout and schedules minimal damage repaint.
pub fn pollDesktop(self: *DiosixGui) void {
    if (!parent.isDesktopWindowOpen(self)) return;
    const p = pollDesktopScanout(self);
    if (!p.updated) return;
    if (p.full) {
        if (self.findIcon(
            parent.WIN_GUEST_DISPLAY_ID,
            parent.ICON_DISP_STATUS_ID,
        )) |ic| {
            var status_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
            ic.setText(parent.formatStatusText(self, &status_buf));
        }
        self.markWindowDirty(parent.WIN_GUEST_DISPLAY_ID);
    } else if (self.desktop.has_dirty_rect) {
        self.markDirty(self.desktop.last_dirty_box);
    } else {
        self.markWindowDirty(parent.WIN_GUEST_DISPLAY_ID);
    }
}
