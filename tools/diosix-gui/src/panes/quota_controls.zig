// Physical Quota Discovery & Interactive Slider Controls for Diosix GUI.
//
// Provides resource pool summary headers and interactive pCPU% / RAM pool
// sliders for both the Create VM detail pane and the Running Guest VMs detail
// pane, enforcing tunable Root VM retained pCPU% and hierarchical RAM pool
// subset bounds.
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
    const w_ret = font.measureString("Retained %");
    const w_pcpu = font.measureString("pCPU pool");
    const w_ram = font.measureString("RAM pool");
    const max_txt = @max(w_ret, @max(w_pcpu, w_ram));
    return @max(self.scalePx(76), max_txt + self.scalePx(12));
}

pub fn defaultVmNameForImage(entry: *const host_info.VmImageEntry) []const u8 {
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
    try addLabel(
        win,
        ICON_CREATE_VM_NAME_LBL_ID,
        pad_x,
        cur_y.*,
        lbl_w,
        row_h,
        "Name",
        fb.Color.INK_SECONDARY,
    );
    const id = ICON_CREATE_VM_NAME_INPUT_ID;
    const nm = self.getCreateVmName();
    var name_in = Icon.createReadWrite(id, sld_x, cur_y.*, sld_w, row_h, nm);
    name_in.max_input_len = 32;
    name_in.setHelpText("Custom name for this guest VM");
    name_in.callback = onCreateVmNameClicked;
    _ = try win.addIcon(name_in);
    cur_y.* += @intCast(row_h + self.scalePx(10));
}

pub const ParentQuotaSummary = struct {
    pool_ram_mb: u32,
    avail_ram_mb: u32,
    retained_pcpu_pct: u32 = sbi.DEFAULT_RETAINED_PCPU_PCT,
    max_del_pcpu_pct: u32 = sbi.MAX_CHILD_PCPU_QUOTA_PCT,
    delegated_pcpu_pct: u32,
    avail_pcpu_pct: u32,
};

pub fn queryParentQuotaSummary() ParentQuotaSummary {
    var guests_buf: [host_info.MAX_RUNNING_GUESTS]host_info.RunningGuest =
        undefined;
    const count = host_info.queryRunningGuests(&guests_buf);
    var root_max_del_pcpu: u32 = sbi.MAX_CHILD_PCPU_QUOTA_PCT;
    var root_del_pcpu: u32 = 0;
    var sum_child_pcpu: u32 = 0;
    var root_pool_bytes: u64 = 0;
    var root_del_bytes: u64 = 0;
    var sum_child_ram_bytes: u64 = 0;

    for (0..count) |i| {
        const g = &guests_buf[i];
        if (g.is_root) {
            if (g.pcpu_quota_pct > 0 and g.pcpu_quota_pct < 100) {
                root_max_del_pcpu = g.pcpu_quota_pct;
            }
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
        root_max_del_pcpu,
        @max(root_del_pcpu, sum_child_pcpu),
    );
    const avail_pcpu: u32 = root_max_del_pcpu -| eff_del_pcpu;
    const eff_del_bytes: u64 = @max(root_del_bytes, sum_child_ram_bytes);
    const avail_bytes: u64 = root_pool_bytes -| eff_del_bytes;

    return .{
        .pool_ram_mb = @intCast(
            std.math.clamp(root_pool_bytes / mem_size.MIB, 128, 8192),
        ),
        .avail_ram_mb = @intCast(
            std.math.clamp(avail_bytes / mem_size.MIB, 0, 8192),
        ),
        .retained_pcpu_pct = 100 -| root_max_del_pcpu,
        .max_del_pcpu_pct = root_max_del_pcpu,
        .delegated_pcpu_pct = eff_del_pcpu,
        .avail_pcpu_pct = avail_pcpu,
    };
}

fn onCreatePcpuSliderChanged(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    self.create_vm_pcpu_pct = @intCast(std.math.clamp(ic.slider_val, 1, 99));
}

fn onCreateRamQuotaSliderChanged(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    const snapped = @divTrunc(@max(128, ic.slider_val) + 32, 64) * 64;
    ic.setSliderValue(snapped);
    const new_rq: u32 = @intCast(@max(128, ic.slider_val));
    self.create_vm_ram_quota_mb = new_rq;
    if (new_rq < self.create_vm_ram_mb) {
        self.create_vm_ram_mb = new_rq;
        const ram_id = gui_mod.ICON_CREATE_VM_RAM_SLIDER_ID;
        if (self.findIcon(gui_mod.WIN_CREATE_VM_DETAIL_ID, ram_id)) |ram_ic| {
            ram_ic.setSliderValue(@intCast(new_rq));
            if (self.getWindow(gui_mod.WIN_CREATE_VM_DETAIL_ID)) |dwin| {
                self.markDirty(dwin.getBox());
            }
        }
    }
}

pub fn addLabel(
    win: *Window,
    id: u32,
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    txt: []const u8,
    color: u32,
) !void {
    var ic = Icon.createReadOnly(id, x, y, w, h, txt);
    ic.setCustomColor(color);
    _ = try win.addIcon(ic);
}

const SliderRowSpec = struct {
    lbl_id: u32,
    sld_id: u32,
    lbl_txt: []const u8,
    min_val: i32,
    max_val: i32,
    cur_val: i32,
    step: i32 = 1,
    unit: []const u8,
    help: []const u8,
    user_tag: usize = 0,
    cb: icon_mod.IconCallback,
};

fn addSliderRow(
    win: *Window,
    pad_x: i32,
    lbl_w: u32,
    sld_x: i32,
    sld_w: u32,
    row_h: u32,
    y: i32,
    spec: SliderRowSpec,
) !void {
    const clr = fb.Color.INK_SECONDARY;
    try addLabel(win, spec.lbl_id, pad_x, y, lbl_w, row_h, spec.lbl_txt, clr);
    var sld = Icon.createSlider(
        spec.sld_id,
        sld_x,
        y,
        sld_w,
        row_h,
        spec.min_val,
        spec.max_val,
        spec.cur_val,
        spec.unit,
    );
    sld.slider_step = spec.step;
    sld.user_tag = spec.user_tag;
    sld.setHelpText(spec.help);
    sld.callback = spec.cb;
    _ = try win.addIcon(sld);
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
        "Pool for VM + children ({d} MB RAM, {d}% pCPU free)",
        .{ summary.avail_ram_mb, summary.avail_pcpu_pct },
    );
    const hdr_id = ICON_CREATE_VM_QUOTA_INFO_ID;
    const ink = fb.Color.INK;
    try addLabel(win, hdr_id, pad_x, cur_y.*, inner_w, row_h, info_str, ink);
    cur_y.* += @intCast(row_h + self.scalePx(6));

    const max_pcpu: i32 = @intCast(@max(@as(u32, 1), summary.avail_pcpu_pct));
    const cur_pcpu: i32 = std.math.clamp(
        @as(i32, @intCast(self.create_vm_pcpu_pct)),
        1,
        max_pcpu,
    );
    self.create_vm_pcpu_pct = @intCast(cur_pcpu);
    try addSliderRow(win, pad_x, lbl_w, sld_x, sld_w, row_h, cur_y.*, .{
        .lbl_id = ICON_CREATE_VM_PCPU_LBL_ID,
        .sld_id = ICON_CREATE_VM_PCPU_SLIDER_ID,
        .lbl_txt = "pCPU pool",
        .min_val = 1,
        .max_val = max_pcpu,
        .cur_val = cur_pcpu,
        .unit = "%",
        .help = "Physical CPU share for this VM and its children",
        .cb = onCreatePcpuSliderChanged,
    });
    cur_y.* += @intCast(row_h + self.scalePx(10));

    const avail_aligned: u32 = (summary.avail_ram_mb / 64) * 64;
    const max_rq: i32 = @intCast(@max(@as(u32, 128), avail_aligned));
    const cur_rq: i32 = std.math.clamp(
        @as(i32, @intCast(self.create_vm_ram_quota_mb)),
        128,
        max_rq,
    );
    self.create_vm_ram_quota_mb = @intCast(cur_rq);
    try addSliderRow(win, pad_x, lbl_w, sld_x, sld_w, row_h, cur_y.*, .{
        .lbl_id = ICON_CREATE_VM_RAM_QUOTA_LBL_ID,
        .sld_id = ICON_CREATE_VM_RAM_QUOTA_SLIDER_ID,
        .lbl_txt = "RAM pool",
        .min_val = 128,
        .max_val = max_rq,
        .cur_val = cur_rq,
        .step = 64,
        .unit = " MB",
        .help = "Total physical RAM pool for this VM + children",
        .cb = onCreateRamQuotaSliderChanged,
    });
    cur_y.* += @intCast(row_h + self.scalePx(12));
}

fn onGuestPcpuQuotaSliderChanged(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    const cid: u64 = @intCast(ic.user_tag);
    if (cid == sbi.CID_SELF) {
        const ret_pct: u32 = @intCast(std.math.clamp(ic.slider_val, 1, 99));
        _ = host_info.setGuestQuota(sbi.CID_SELF, ret_pct, 0);
        const s = queryParentQuotaSummary();
        const avail_pct = (100 -| ret_pct) -| s.delegated_pcpu_pct;
        const win_id = gui_mod.WIN_GUEST_DETAIL_ID;
        if (self.findIcon(win_id, ICON_GUEST_PCPU_QUOTA_LBL_ID)) |lbl| {
            var buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
            lbl.setText(text_label.fmtLabel(
                &buf,
                "{d}% pCPU retained, {d}% available ({d} MB RAM free)",
                .{ ret_pct, avail_pct, s.avail_ram_mb },
            ));
            if (self.getWindow(win_id)) |dwin| self.markDirty(dwin.getBox());
        }
        return;
    }
    if (cid < sbi.CID_FIRST_CHILD) return;
    const pct: u32 = @intCast(std.math.clamp(ic.slider_val, 1, 99));
    var cur_ram_mb: u32 = 256;
    const win_id = gui_mod.WIN_GUEST_DETAIL_ID;
    if (self.findIcon(win_id, ICON_GUEST_RAM_QUOTA_SLIDER_ID)) |ric| {
        cur_ram_mb = @intCast(@max(64, ric.slider_val));
    }
    _ = host_info.setGuestQuota(cid, pct, cur_ram_mb);
}

fn onGuestRamQuotaSliderChanged(g: *anyopaque, _: *anyopaque, ic: *Icon) void {
    const self: *DiosixGui = @ptrCast(@alignCast(g));
    const cid: u64 = @intCast(ic.user_tag);
    if (cid < sbi.CID_FIRST_CHILD) return;
    const snapped = @divTrunc(@max(64, ic.slider_val) + 32, 64) * 64;
    ic.setSliderValue(snapped);
    const ram_mb: u32 = @intCast(@max(64, ic.slider_val));
    var cur_pcpu: u32 = sbi.DEFAULT_CHILD_PCPU_QUOTA_PCT;
    const win_id = gui_mod.WIN_GUEST_DETAIL_ID;
    if (self.findIcon(win_id, ICON_GUEST_PCPU_QUOTA_SLIDER_ID)) |pic| {
        cur_pcpu = @intCast(std.math.clamp(pic.slider_val, 1, 99));
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
    const lbl_w = computeControlLabelWidth(self);
    const sld_x: i32 = pad_x + @as(i32, @intCast(lbl_w));
    const sld_w: u32 = if (inner_w > lbl_w + 8) inner_w - lbl_w - 8 else 100;
    const hdr_id = ICON_GUEST_QUOTA_HDR_ID;
    const ink = fb.Color.INK;

    if (guest.is_root) {
        const hdr = "Host resource pool";
        try addLabel(win, hdr_id, pad_x, cur_y.*, inner_w, row_h, hdr, ink);
        cur_y.* += @intCast(row_h + self.scalePx(2));

        var summary_buf: [text_label.LABEL_BUF_BYTES]u8 = undefined;
        const ret_p = summary.retained_pcpu_pct;
        const avl_p = summary.avail_pcpu_pct;
        const summary_str = text_label.fmtLabel(
            &summary_buf,
            "{d}% pCPU retained, {d}% available ({d} MB RAM free)",
            .{ ret_p, avl_p, summary.avail_ram_mb },
        );
        const sub_id = ICON_GUEST_PCPU_QUOTA_LBL_ID;
        const sec = fb.Color.INK_SECONDARY;
        const y0 = cur_y.*;
        try addLabel(win, sub_id, pad_x, y0, inner_w, row_h, summary_str, sec);
        cur_y.* += @intCast(row_h + self.scalePx(4));

        const avail_ret: u32 = @min(99, 100 -| summary.delegated_pcpu_pct);
        const max_ret: i32 = @intCast(@max(@as(u32, 1), avail_ret));
        const cur_ret: i32 = std.math.clamp(
            @as(i32, @intCast(summary.retained_pcpu_pct)),
            1,
            max_ret,
        );
        try addSliderRow(win, pad_x, lbl_w, sld_x, sld_w, row_h, cur_y.*, .{
            .lbl_id = ICON_GUEST_RAM_QUOTA_LBL_ID,
            .sld_id = ICON_GUEST_PCPU_QUOTA_SLIDER_ID,
            .lbl_txt = "Retained %",
            .min_val = 1,
            .max_val = max_ret,
            .cur_val = cur_ret,
            .unit = "%",
            .help = "Minimum host pCPU % retained for the Root VM",
            .user_tag = @intCast(sbi.CID_SELF),
            .cb = onGuestPcpuQuotaSliderChanged,
        });
        cur_y.* += @intCast(row_h + self.scalePx(8));
        return;
    }

    const ch_hdr = "Resource pool (VM + children)";
    try addLabel(win, hdr_id, pad_x, cur_y.*, inner_w, row_h, ch_hdr, ink);
    cur_y.* += @intCast(row_h + self.scalePx(4));

    const cur_child_pct: u32 = if (guest.pcpu_quota_pct > 0)
        guest.pcpu_quota_pct
    else
        sbi.DEFAULT_CHILD_PCPU_QUOTA_PCT;
    const avail_sum = summary.avail_pcpu_pct +| cur_child_pct;
    const avail_plus_cur = @max(@as(u32, 1), avail_sum);
    const max_del = summary.max_del_pcpu_pct;
    const max_child_pct: i32 = @intCast(@min(max_del, avail_plus_cur));
    const clamped_pct: i32 = std.math.clamp(
        @as(i32, @intCast(cur_child_pct)),
        1,
        max_child_pct,
    );
    try addSliderRow(win, pad_x, lbl_w, sld_x, sld_w, row_h, cur_y.*, .{
        .lbl_id = ICON_GUEST_PCPU_QUOTA_LBL_ID,
        .sld_id = ICON_GUEST_PCPU_QUOTA_SLIDER_ID,
        .lbl_txt = "pCPU pool",
        .min_val = 1,
        .max_val = max_child_pct,
        .cur_val = clamped_pct,
        .unit = "%",
        .help = "Physical CPU share for this VM and any child VMs it creates",
        .user_tag = @intCast(guest.cid),
        .cb = onGuestPcpuQuotaSliderChanged,
    });
    cur_y.* += @intCast(row_h + self.scalePx(6));

    const self_mb_u32: u32 = @intCast(
        std.math.clamp(guest.ram_bytes / mem_size.MIB, 64, 8192),
    );
    const eff_ram_bytes = if (guest.ram_quota_bytes > 0)
        guest.ram_quota_bytes
    else
        guest.ram_bytes;
    const cur_mb_u32: u32 = @intCast(
        std.math.clamp(eff_ram_bytes / mem_size.MIB, self_mb_u32, 8192),
    );
    const max_ram_mb: i32 = @intCast(
        @max(cur_mb_u32, @max(@as(u32, 128), summary.pool_ram_mb)),
    );
    try addSliderRow(win, pad_x, lbl_w, sld_x, sld_w, row_h, cur_y.*, .{
        .lbl_id = ICON_GUEST_RAM_QUOTA_LBL_ID,
        .sld_id = ICON_GUEST_RAM_QUOTA_SLIDER_ID,
        .lbl_txt = "RAM pool",
        .min_val = @intCast(self_mb_u32),
        .max_val = max_ram_mb,
        .cur_val = @intCast(cur_mb_u32),
        .step = 64,
        .unit = " MB",
        .help = "Total physical RAM pool for this VM + children",
        .user_tag = @intCast(guest.cid),
        .cb = onGuestRamQuotaSliderChanged,
    });
    cur_y.* += @intCast(row_h + self.scalePx(10));
}

test {
    std.testing.refAllDecls(@This());
}
