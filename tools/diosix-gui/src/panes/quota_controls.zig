// Physical Quota Discovery & Interactive Slider Controls for Diosix GUI.
//
// Provides physical quota summary headers and interactive pCPU% / RAM quota
// sliders for both the Create VM detail pane and the Running Guest VMs detail
// pane, enforcing the 90% child pCPU delegation limit and supporting H-mode
// RAM quota dialing.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const sbi = @import("interface").sbi;
const fb = @import("../framebuffer.zig");
const font = @import("../font.zig");
const icon_mod = @import("../icon.zig");
const Icon = icon_mod.Icon;
const window_mod = @import("../window.zig");
const Window = window_mod.Window;
const host_info = @import("../host.zig");
const mem_size = @import("../host/mem.zig");
const text_label = @import("../label.zig");
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;

pub const ICON_GUEST_QUOTA_HDR_ID: u32 = 1256;
pub const ICON_GUEST_PCPU_QUOTA_LBL_ID: u32 = 1257;
pub const ICON_GUEST_PCPU_QUOTA_SLIDER_ID: u32 = 1258;
pub const ICON_GUEST_RAM_QUOTA_LBL_ID: u32 = 1259;
pub const ICON_GUEST_RAM_QUOTA_SLIDER_ID: u32 = 1280;

pub const ICON_CREATE_VM_QUOTA_INFO_ID: u32 = 1347;
pub const ICON_CREATE_VM_PCPU_LBL_ID: u32 = 1348;
pub const ICON_CREATE_VM_PCPU_SLIDER_ID: u32 = 1349;
pub const ICON_CREATE_VM_RAM_QUOTA_LBL_ID: u32 = 1370;
pub const ICON_CREATE_VM_RAM_QUOTA_SLIDER_ID: u32 = 1371;
pub const ICON_CREATE_VM_NAME_LBL_ID: u32 = 1372;
pub const ICON_CREATE_VM_NAME_INPUT_ID: u32 = 1373;

pub fn computeControlLabelWidth(self: *const DiosixGui) u32 {
    const w_ram = font.measureString("RAM pool");
    const w_pcpu = font.measureString("pCPU %");
    const w_vcpu = font.measureString("vCPUs");
    const max_txt = @max(w_ram, @max(w_pcpu, w_vcpu));
    return @max(self.scalePx(76), max_txt + self.scalePx(12));
}

pub fn defaultVmNameForImage(
    entry: *const host_info.VmImageEntry,
) []const u8 {
    const fname = entry.getFilename();
    if (fname.len > 0) {
        if (std.mem.lastIndexOfScalar(u8, fname, '.')) |dot| {
            if (dot > 0) return fname[0..dot];
        }
        return fname;
    }
    return "guest-vm";
}

fn onCreateVmNameClicked(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    self.setCreateVmName(ic.getText());
    if (self.osk_state.seat_profile == .touch_tablet and
        !self.osk_state.visible)
    {
        self.osk_state.visible = true;
        self.buildOskWindow() catch {};
    }
}

pub fn addCreateVmNameControl(
    self: *DiosixGui,
    win: *Window,
    pad_x: i32,
    lbl_w: u32,
    sld_x: i32,
    sld_w: u32,
    row_h: u32,
    cur_y: *i32,
) !void {
    var name_lbl = Icon.createReadOnly(
        ICON_CREATE_VM_NAME_LBL_ID,
        pad_x,
        cur_y.*,
        lbl_w,
        row_h,
        "Name",
    );
    name_lbl.setCustomColor(fb.Color.INK_SECONDARY);
    _ = try win.addIcon(name_lbl);

    var name_in = Icon.createReadWrite(
        ICON_CREATE_VM_NAME_INPUT_ID,
        sld_x,
        cur_y.*,
        sld_w,
        row_h,
        self.getCreateVmName(),
    );
    name_in.max_input_len = 32;
    name_in.setHelpText(
        "Custom name for this guest VM (click and type to customize)",
    );
    name_in.callback = onCreateVmNameClicked;
    _ = try win.addIcon(name_in);
    cur_y.* += @intCast(row_h + self.scalePx(10));
}

pub const ParentQuotaSummary = struct {
    pool_ram_mb: u32,
    avail_ram_mb: u32,
    delegated_pcpu_pct: u32,
    avail_pcpu_pct: u32,
};

pub fn queryParentQuotaSummary() ParentQuotaSummary {
    var guests_buf: [host_info.MAX_RUNNING_GUESTS]host_info.RunningGuest =
        undefined;
    const count = host_info.queryRunningGuests(&guests_buf);
    var root_del_pcpu: u32 = 0;
    var sum_child_pcpu: u32 = 0;
    var root_pool_bytes: u64 = 0;
    var root_del_bytes: u64 = 0;
    var sum_child_ram_bytes: u64 = 0;

    for (0..count) |i| {
        const g = &guests_buf[i];
        if (g.is_root) {
            root_del_pcpu = g.delegated_pcpu_pct;
            root_pool_bytes = g.ram_quota_bytes;
            root_del_bytes = @max(g.delegated_ram_bytes, g.used_ram_bytes);
        } else {
            sum_child_pcpu +|= g.pcpu_quota_pct;
            sum_child_ram_bytes +|= if (g.ram_quota_bytes > 0)
                g.ram_quota_bytes
            else
                g.ram_bytes;
        }
    }

    if (root_pool_bytes == 0) {
        if (host_info.getHypervisorInfo()) |hv| {
            if (hv.host_free_ram_kb >= 128 * 1024) {
                root_pool_bytes = hv.host_free_ram_kb * mem_size.KIB;
            }
        }
    }
    if (root_pool_bytes == 0) root_pool_bytes = 1536 * mem_size.MIB;

    const eff_del_pcpu: u32 = @min(
        sbi.MAX_CHILD_PCPU_QUOTA_PCT,
        @max(root_del_pcpu, sum_child_pcpu),
    );
    const avail_pcpu: u32 = sbi.MAX_CHILD_PCPU_QUOTA_PCT -| eff_del_pcpu;
    const eff_del_bytes: u64 = @max(root_del_bytes, sum_child_ram_bytes);
    const avail_bytes: u64 = root_pool_bytes -| eff_del_bytes;

    const pool_mb: u32 = @intCast(
        std.math.clamp(root_pool_bytes / mem_size.MIB, 128, 8192),
    );
    const avail_mb: u32 = @intCast(
        std.math.clamp(avail_bytes / mem_size.MIB, 0, 8192),
    );

    return .{
        .pool_ram_mb = pool_mb,
        .avail_ram_mb = avail_mb,
        .delegated_pcpu_pct = eff_del_pcpu,
        .avail_pcpu_pct = avail_pcpu,
    };
}

fn onCreatePcpuSliderChanged(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    self.create_vm_pcpu_pct = @intCast(
        std.math.clamp(ic.slider_val, 1, sbi.MAX_CHILD_PCPU_QUOTA_PCT),
    );
}

fn onCreateRamQuotaSliderChanged(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    const raw = @max(64, ic.slider_val);
    const snapped = @divTrunc(raw + 32, 64) * 64;
    ic.setSliderValue(snapped);
    self.create_vm_ram_quota_mb = @intCast(@max(64, ic.slider_val));
}

pub fn addCreateVmQuotaControls(
    self: *DiosixGui,
    win: *Window,
    pad_x: i32,
    inner_w: u32,
    lbl_w: u32,
    sld_x: i32,
    sld_w: u32,
    row_h: u32,
    cur_y: *i32,
) !void {
    const summary = queryParentQuotaSummary();

    var info_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
    const info_str = text_label.fmtLabel(
        &info_buf,
        "Available quota: {d} MB RAM, {d}% pCPU",
        .{ summary.avail_ram_mb, summary.avail_pcpu_pct },
    );
    var q_info = Icon.createReadOnly(
        ICON_CREATE_VM_QUOTA_INFO_ID,
        pad_x,
        cur_y.*,
        inner_w,
        row_h,
        info_str,
    );
    q_info.setCustomColor(fb.Color.INK_SECONDARY);
    _ = try win.addIcon(q_info);
    cur_y.* += @intCast(row_h + self.scalePx(6));

    var pcpu_lbl = Icon.createReadOnly(
        ICON_CREATE_VM_PCPU_LBL_ID,
        pad_x,
        cur_y.*,
        lbl_w,
        row_h,
        "pCPU %",
    );
    pcpu_lbl.setCustomColor(fb.Color.INK_SECONDARY);
    _ = try win.addIcon(pcpu_lbl);

    const max_pcpu: i32 = @intCast(@max(@as(u32, 1), summary.avail_pcpu_pct));
    const cur_pcpu: i32 = std.math.clamp(
        @as(i32, @intCast(self.create_vm_pcpu_pct)),
        1,
        max_pcpu,
    );
    self.create_vm_pcpu_pct = @intCast(cur_pcpu);
    var pcpu_sld = Icon.createSlider(
        ICON_CREATE_VM_PCPU_SLIDER_ID,
        sld_x,
        cur_y.*,
        sld_w,
        row_h,
        1,
        max_pcpu,
        cur_pcpu,
        "%",
    );
    pcpu_sld.setHelpText(
        "Physical CPU core time % allocated to this child VM (max 90%)",
    );
    pcpu_sld.callback = onCreatePcpuSliderChanged;
    _ = try win.addIcon(pcpu_sld);
    cur_y.* += @intCast(row_h + self.scalePx(10));

    var rq_lbl = Icon.createReadOnly(
        ICON_CREATE_VM_RAM_QUOTA_LBL_ID,
        pad_x,
        cur_y.*,
        lbl_w,
        row_h,
        "RAM pool",
    );
    rq_lbl.setCustomColor(fb.Color.INK_SECONDARY);
    _ = try win.addIcon(rq_lbl);

    const max_rq: i32 = @intCast(@max(@as(u32, 128), summary.pool_ram_mb));
    const cur_rq: i32 = std.math.clamp(
        @as(i32, @intCast(self.create_vm_ram_quota_mb)),
        64,
        max_rq,
    );
    self.create_vm_ram_quota_mb = @intCast(cur_rq);
    var rq_sld = Icon.createSlider(
        ICON_CREATE_VM_RAM_QUOTA_SLIDER_ID,
        sld_x,
        cur_y.*,
        sld_w,
        row_h,
        64,
        max_rq,
        cur_rq,
        " MB",
    );
    rq_sld.slider_step = 64;
    rq_sld.setHelpText(
        "Physical RAM quota pool granted to this child VM and its subtree",
    );
    rq_sld.callback = onCreateRamQuotaSliderChanged;
    _ = try win.addIcon(rq_sld);
    cur_y.* += @intCast(row_h + self.scalePx(12));
}

fn onGuestPcpuQuotaSliderChanged(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    const cid: u64 = @intCast(ic.user_tag);
    if (cid < sbi.CID_FIRST_CHILD) return;
    const pct: u32 = @intCast(
        std.math.clamp(ic.slider_val, 1, sbi.MAX_CHILD_PCPU_QUOTA_PCT),
    );
    var cur_ram_mb: u32 = 256;
    if (self.findIcon(
        gui_mod.WIN_GUEST_DETAIL_ID,
        ICON_GUEST_RAM_QUOTA_SLIDER_ID,
    )) |ric| {
        cur_ram_mb = @intCast(@max(64, ric.slider_val));
    }
    _ = host_info.setGuestQuota(cid, pct, cur_ram_mb);
}

fn onGuestRamQuotaSliderChanged(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    const cid: u64 = @intCast(ic.user_tag);
    if (cid < sbi.CID_FIRST_CHILD) return;
    const raw = @max(64, ic.slider_val);
    const snapped = @divTrunc(raw + 32, 64) * 64;
    ic.setSliderValue(snapped);
    const ram_mb: u32 = @intCast(@max(64, ic.slider_val));
    var cur_pcpu: u32 = sbi.DEFAULT_CHILD_PCPU_QUOTA_PCT;
    if (self.findIcon(
        gui_mod.WIN_GUEST_DETAIL_ID,
        ICON_GUEST_PCPU_QUOTA_SLIDER_ID,
    )) |pic| {
        cur_pcpu = @intCast(
            std.math.clamp(pic.slider_val, 1, sbi.MAX_CHILD_PCPU_QUOTA_PCT),
        );
    }
    _ = host_info.setGuestQuota(cid, cur_pcpu, ram_mb);
}

pub fn addGuestDetailQuotaControls(
    self: *DiosixGui,
    win: *Window,
    guest: *const host_info.RunningGuest,
    pad_x: i32,
    inner_w: u32,
    row_h: u32,
    cur_y: *i32,
) !void {
    const summary = queryParentQuotaSummary();

    if (guest.is_root) {
        var q_hdr = Icon.createReadOnly(
            ICON_GUEST_QUOTA_HDR_ID,
            pad_x,
            cur_y.*,
            inner_w,
            row_h,
            "Physical quota pool",
        );
        q_hdr.setCustomColor(fb.Color.INK);
        _ = try win.addIcon(q_hdr);
        cur_y.* += @intCast(row_h + self.scalePx(2));

        const ret_pcpu: u32 = 100 -| summary.delegated_pcpu_pct;
        var summary_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
        const summary_str = text_label.fmtLabel(
            &summary_buf,
            "{d} MB RAM free ({d}% pCPU retained)",
            .{ summary.avail_ram_mb, ret_pcpu },
        );
        var q_lbl = Icon.createReadOnly(
            ICON_GUEST_PCPU_QUOTA_LBL_ID,
            pad_x,
            cur_y.*,
            inner_w,
            row_h,
            summary_str,
        );
        q_lbl.setCustomColor(fb.Color.INK_SECONDARY);
        _ = try win.addIcon(q_lbl);
        cur_y.* += @intCast(row_h + self.scalePx(8));
        return;
    }

    var q_hdr = Icon.createReadOnly(
        ICON_GUEST_QUOTA_HDR_ID,
        pad_x,
        cur_y.*,
        inner_w,
        row_h,
        "Physical quota",
    );
    q_hdr.setCustomColor(fb.Color.INK);
    _ = try win.addIcon(q_hdr);
    cur_y.* += @intCast(row_h + self.scalePx(4));

    const lbl_w = computeControlLabelWidth(self);
    const sld_x: i32 = pad_x + @as(i32, @intCast(lbl_w));
    const sld_w: u32 = if (inner_w > lbl_w + 8) inner_w - lbl_w - 8 else 100;

    var pcpu_lbl = Icon.createReadOnly(
        ICON_GUEST_PCPU_QUOTA_LBL_ID,
        pad_x,
        cur_y.*,
        lbl_w,
        row_h,
        "pCPU %",
    );
    pcpu_lbl.setCustomColor(fb.Color.INK_SECONDARY);
    _ = try win.addIcon(pcpu_lbl);

    const cur_child_pct: u32 = if (guest.pcpu_quota_pct > 0)
        guest.pcpu_quota_pct
    else
        sbi.DEFAULT_CHILD_PCPU_QUOTA_PCT;
    const max_child_pct: i32 = @intCast(
        @min(
            sbi.MAX_CHILD_PCPU_QUOTA_PCT,
            @max(@as(u32, 1), summary.avail_pcpu_pct +| cur_child_pct),
        ),
    );
    const clamped_pct: i32 = std.math.clamp(
        @as(i32, @intCast(cur_child_pct)),
        1,
        max_child_pct,
    );
    var pcpu_sld = Icon.createSlider(
        ICON_GUEST_PCPU_QUOTA_SLIDER_ID,
        sld_x,
        cur_y.*,
        sld_w,
        row_h,
        1,
        max_child_pct,
        clamped_pct,
        "%",
    );
    pcpu_sld.user_tag = @intCast(guest.cid);
    pcpu_sld.setHelpText(
        "Dial physical CPU time percentage for this child VM (up to 90% total)",
    );
    pcpu_sld.callback = onGuestPcpuQuotaSliderChanged;
    _ = try win.addIcon(pcpu_sld);
    cur_y.* += @intCast(row_h + self.scalePx(6));

    var rq_lbl = Icon.createReadOnly(
        ICON_GUEST_RAM_QUOTA_LBL_ID,
        pad_x,
        cur_y.*,
        lbl_w,
        row_h,
        "RAM pool",
    );
    rq_lbl.setCustomColor(fb.Color.INK_SECONDARY);
    _ = try win.addIcon(rq_lbl);

    const eff_ram_bytes = if (guest.ram_quota_bytes > 0)
        guest.ram_quota_bytes
    else
        guest.ram_bytes;
    const cur_ram_mb: i32 = @intCast(
        std.math.clamp(eff_ram_bytes / mem_size.MIB, 64, 8192),
    );
    const max_ram_mb: i32 = @intCast(
        @max(
            @as(u32, @intCast(cur_ram_mb)),
            @max(@as(u32, 128), summary.pool_ram_mb),
        ),
    );
    var rq_sld = Icon.createSlider(
        ICON_GUEST_RAM_QUOTA_SLIDER_ID,
        sld_x,
        cur_y.*,
        sld_w,
        row_h,
        64,
        max_ram_mb,
        cur_ram_mb,
        " MB",
    );
    rq_sld.user_tag = @intCast(guest.cid);
    rq_sld.slider_step = 64;
    rq_sld.setHelpText(
        "Dial physical RAM quota for this child VM (below in-use triggers OOM)",
    );
    rq_sld.callback = onGuestRamQuotaSliderChanged;
    _ = try win.addIcon(rq_sld);
    cur_y.* += @intCast(row_h + self.scalePx(10));
}

test {
    std.testing.refAllDecls(@This());
}
