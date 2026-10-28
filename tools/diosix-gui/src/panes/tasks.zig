// Notification and Progress Bar Panes for Diosix GUI Background Tasks.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const win_mod = @import("../window.zig");
const Window = win_mod.Window;
const icon_mod = @import("../icon.zig");
const Icon = icon_mod.Icon;
const fb = @import("../framebuffer.zig");
const tasks_mod = @import("../tasks.zig");
const host_info = @import("../host.zig");

const BORDER_GAP_U32: u32 = @intCast(gui_mod.BORDER_GAP);
const WIN_HELP_ID = gui_mod.WIN_HELP_ID;
const WIN_VERSION_ID = gui_mod.WIN_VERSION_ID;

pub const WIN_TASK_BASE_ID: u32 = 160;
pub const ICON_TASK_LABEL_ID: u32 = 1;
pub const ICON_TASK_PROGRESS_ID: u32 = 2;
pub const ICON_TASK_DISMISS_ID: u32 = 3;

pub fn isTaskWindowId(id: u32) bool {
    return id >= WIN_TASK_BASE_ID and
        id < WIN_TASK_BASE_ID + @as(u32, @intCast(tasks_mod.MAX_TASKS));
}

pub fn getBaseMaxPaneHeight(self: *const DiosixGui) u32 {
    const reserve = BORDER_GAP_U32 * 3 + self.scalePx(40);
    return if (self.height > reserve + 60) self.height - reserve else 60;
}

pub fn getFooterReserveHeight(self: *const DiosixGui) u32 {
    const bar_h = self.scalePx(40);
    const count: u32 = @intCast(self.task_mgr.activeCount());
    return BORDER_GAP_U32 * 3 +
        (count + 1) * bar_h +
        count * BORDER_GAP_U32;
}

pub fn getMaxPaneHeight(self: *const DiosixGui) u32 {
    const reserve = getFooterReserveHeight(self);
    return if (self.height > reserve + 60) self.height - reserve else 60;
}

pub fn clampWindowToTaskStack(self: *DiosixGui, win: *Window) void {
    if (win.id == gui_mod.WIN_MENU_ID or
        win.id == gui_mod.WIN_BACK_ID or
        win.id == WIN_HELP_ID or
        win.id == WIN_VERSION_ID or
        isTaskWindowId(win.id))
    {
        return;
    }
    const max_bottom: i32 = @intCast(
        BORDER_GAP_U32 + getMaxPaneHeight(self),
    );
    if (win.onscreen_y >= max_bottom) return;

    const avail_h: u32 = @intCast(@max(56, max_bottom - win.onscreen_y));
    const base_h: u32 = if (win.natural_height > 0)
        win.natural_height
    else
        win.height;
    win.height = @min(base_h, avail_h);
    win.scroll_y = std.math.clamp(win.scroll_y, 0, win.getMaxScroll());
    if (win.isScrollable() and win.scrollbar_alpha == 0) {
        win.scrollbar_alpha = 200;
    }
}

fn onDismissTaskClick(
    gui_ctx: *anyopaque,
    _: *anyopaque,
    icon: *Icon,
) void {
    const self: *DiosixGui = @ptrCast(@alignCast(gui_ctx));
    const task_id: u32 = @intCast(icon.user_tag);
    if (self.task_mgr.dismissTask(task_id)) {
        syncTaskPanes(self);
    }
}

fn tryUpdateTaskPanesInPlace(
    self: *DiosixGui,
    bar_w: u32,
    bar_h: u32,
) bool {
    var active_slots: u32 = 0;
    for (&self.task_mgr.entries) |*entry| {
        if (!entry.active) continue;
        const win_id = WIN_TASK_BASE_ID + active_slots;
        const row_from_bottom: u32 = active_slots + 1;
        const bar_y: i32 = @as(i32, @intCast(self.height)) -
            @as(
                i32,
                @intCast(
                    BORDER_GAP_U32 +
                        (row_from_bottom + 1) * bar_h +
                        row_from_bottom * BORDER_GAP_U32,
                ),
            );
        const win = self.getWindow(win_id) orelse return false;
        if (win.onscreen_x != gui_mod.BORDER_GAP or
            win.onscreen_y != bar_y or
            win.width != bar_w or
            win.height != bar_h)
        {
            return false;
        }
        const has_prog = self.findIcon(win_id, ICON_TASK_PROGRESS_ID) != null;
        if ((entry.state != .failed) != has_prog) return false;
        if (self.findIcon(win_id, ICON_TASK_LABEL_ID) == null or
            self.findIcon(win_id, ICON_TASK_DISMISS_ID) == null)
        {
            return false;
        }
        active_slots += 1;
    }
    if (active_slots == 0) return false;
    var extra: u32 = active_slots;
    while (extra < @as(u32, @intCast(tasks_mod.MAX_TASKS))) : (extra += 1) {
        if (self.getWindow(WIN_TASK_BASE_ID + extra) != null) return false;
    }

    var slot_idx: u32 = 0;
    for (&self.task_mgr.entries) |*entry| {
        if (!entry.active) continue;
        const win_id = WIN_TASK_BASE_ID + slot_idx;
        const win = self.getWindow(win_id).?;
        var label_buf: [224]u8 = undefined;
        const label_txt = entry.formatDisplayLabel(&label_buf);
        if (self.findIcon(win_id, ICON_TASK_LABEL_ID)) |lbl_ic| {
            lbl_ic.setText(label_txt);
        }
        if (self.findIcon(win_id, ICON_TASK_PROGRESS_ID)) |prog_ic| {
            prog_ic.setSliderValue(@intCast(entry.progress_pct));
            if (entry.state == .completed) {
                prog_ic.setCustomColor(fb.Color.PROGRESS_SUCCESS_GREEN);
            } else {
                prog_ic.custom_color = null;
            }
        }
        if (self.findIcon(win_id, ICON_TASK_DISMISS_ID)) |btn_ic| {
            btn_ic.user_tag = entry.id;
        }
        self.markDirty(win.getBox());
        slot_idx += 1;
    }
    return true;
}

pub fn syncTaskPanes(self: *DiosixGui) void {
    const bar_h = self.scalePx(40);
    const bar_w = if (self.width > BORDER_GAP_U32 * 2)
        self.width - (BORDER_GAP_U32 * 2)
    else
        self.width;

    if (tryUpdateTaskPanesInPlace(self, bar_w, bar_h)) return;

    for (0..tasks_mod.MAX_TASKS) |i| {
        _ = self.destroyWindow(WIN_TASK_BASE_ID + @as(u32, @intCast(i)));
    }
    const pad_x: i32 = @intCast(self.scalePx(12));
    const btn_w = self.scalePx(96);
    const btn_h = self.scalePx(28);
    const btn_x: i32 = @as(i32, @intCast(bar_w)) -
        @as(i32, @intCast(btn_w)) - pad_x;
    const btn_y: i32 = @divTrunc(
        @as(i32, @intCast(bar_h)) - @as(i32, @intCast(btn_h)),
        2,
    );

    var slot_idx: u32 = 0;
    for (&self.task_mgr.entries) |*entry| {
        if (!entry.active) continue;

        const win_id = WIN_TASK_BASE_ID + slot_idx;
        const row_from_bottom: u32 = slot_idx + 1;
        const bar_y: i32 = @as(i32, @intCast(self.height)) -
            @as(
                i32,
                @intCast(
                    BORDER_GAP_U32 +
                        (row_from_bottom + 1) * bar_h +
                        row_from_bottom * BORDER_GAP_U32,
                ),
            );

        const win = self.createWindow(
            win_id,
            gui_mod.BORDER_GAP,
            bar_y,
            bar_w,
            bar_h,
            null,
        ) catch continue;
        win.content_bottom_pad = 0;
        win.z_order = 90 + slot_idx;
        win.setHelpText(
            "Background task progress and status notification",
        );

        var label_buf: [224]u8 = undefined;
        const label_txt = entry.formatDisplayLabel(&label_buf);

        if (entry.state != .failed) {
            const prog_w = @min(self.scalePx(220), bar_w / 4);
            const prog_x = btn_x - @as(i32, @intCast(prog_w)) - pad_x;
            const label_w: u32 = @intCast(@max(40, prog_x - pad_x * 2));
            _ = win.addIcon(
                Icon.createReadOnly(
                    ICON_TASK_LABEL_ID,
                    pad_x,
                    0,
                    label_w,
                    bar_h,
                    label_txt,
                ),
            ) catch {};
            var prog_ic = Icon.createProgressBar(
                ICON_TASK_PROGRESS_ID,
                prog_x,
                0,
                prog_w,
                bar_h,
                entry.progress_pct,
            );
            if (entry.state == .completed) {
                prog_ic.setCustomColor(fb.Color.PROGRESS_SUCCESS_GREEN);
            }
            _ = win.addIcon(prog_ic) catch {};
        } else {
            const label_w: u32 = @intCast(@max(40, btn_x - pad_x * 2));
            _ = win.addIcon(
                Icon.createReadOnly(
                    ICON_TASK_LABEL_ID,
                    pad_x,
                    0,
                    label_w,
                    bar_h,
                    label_txt,
                ),
            ) catch {};
        }

        if (win.addIcon(
            Icon.createButton(
                ICON_TASK_DISMISS_ID,
                btn_x,
                btn_y,
                btn_w,
                btn_h,
                "Dismiss",
            ),
        )) |btn| {
            btn.user_tag = entry.id;
            btn.callback = &onDismissTaskClick;
            btn.setHelpText("Dismiss this notification");
        } else |_| {}

        slot_idx += 1;
    }

    for (self.windows.items) |*w| {
        clampWindowToTaskStack(self, w);
    }
    self.markFullDirty();
}

pub fn spawnBackgroundTask(
    self: *DiosixGui,
    title: []const u8,
    initial_msg: []const u8,
    argv: []const []const u8,
) u32 {
    const mock = host_info_mock(self);
    const id = self.task_mgr.spawnCommand(
        title,
        initial_msg,
        argv,
        mock,
    );
    syncTaskPanes(self);
    return id;
}

fn host_info_mock(_: *const DiosixGui) bool {
    return host_info.mock_hypervisor_info != null or
        host_info.images.mock_available_images != null or
        host_info.guests.mock_running_guests != null;
}

pub fn spawnCreateVmTask(
    self: *DiosixGui,
    name_s: []const u8,
    img_path: []const u8,
    st_path: []const u8,
) void {
    const dsx_bin = host_info.images.resolveDsxBinarySlice();
    var vcpu_buf: [16]u8 = undefined;
    const vcpu_s = std.fmt.bufPrint(
        &vcpu_buf,
        "{d}",
        .{@max(1, self.create_vm_vcpus)},
    ) catch "1";
    var ram_buf: [24]u8 = undefined;
    const ram_s = std.fmt.bufPrint(
        &ram_buf,
        "{d}M",
        .{@max(64, self.create_vm_ram_mb)},
    ) catch "256M";
    var pcpu_buf: [16]u8 = undefined;
    const pcpu_s = std.fmt.bufPrint(
        &pcpu_buf,
        "{d}",
        .{std.math.clamp(self.create_vm_pcpu_pct, 1, 90)},
    ) catch "20";
    var rq_buf: [24]u8 = undefined;
    const rq_s = std.fmt.bufPrint(
        &rq_buf,
        "{d}M",
        .{@max(64, self.create_vm_ram_quota_mb)},
    ) catch "256M";
    var title_buf: [64]u8 = undefined;
    const title_s = std.fmt.bufPrint(
        &title_buf,
        "Creating VM ({s})",
        .{name_s},
    ) catch "Creating VM";

    const st_flag: []const u8 =
        if (std.mem.endsWith(u8, st_path, ".iso")) "--cdrom" else "--disk";
    const argv_with_st = [_][]const u8{
        dsx_bin,   "run",         img_path, "--name", name_s,
        "--vcpus", vcpu_s,        "--ram",  ram_s,    "--pcpu",
        pcpu_s,    "--ram-quota", rq_s,     st_flag,  st_path,
    };
    const n_args: usize = if (st_path.len > 0) 15 else 13;
    _ = spawnBackgroundTask(
        self,
        title_s,
        "Starting guest VM creation...",
        argv_with_st[0..n_args],
    );
}

pub fn pollBackgroundTasks(self: *DiosixGui) void {
    const res = self.task_mgr.poll();
    if (res.guests_changed) {
        self.updateGuestsPaneData();
    }
    if (res.ui_changed) {
        syncTaskPanes(self);
    }
}

test {
    std.testing.refAllDecls(@This());
}
