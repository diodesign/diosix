// Diosix SBI guest and hypervisor telemetry query handlers.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const riscv = @import("../../hardware/native/cpu/riscv64/mod.zig");
const vcore = @import("../vcore.zig");
const guest = @import("../guest.zig");
const pcore = @import("../pcore.zig");
const physmem = @import("../physmem.zig");
const sbi_core = @import("../sbi.zig");
const charter = @import("charter.zig");
const interface = @import("interface").sbi;
const arch = @import("interface").riscv;

extern const project_version: [*:0]const u8;
extern const git_branch: [*:0]const u8;
extern const git_revision: [*:0]const u8;
extern const build_date: [*:0]const u8;
extern const build_user: [*:0]const u8;
extern const build_hostname: [*:0]const u8;
extern const zig_version: [*:0]const u8;
extern const cpu_arch: [*:0]const u8;

const VCore = vcore.VirtualCore;
const ThreadCtx = riscv.ThreadContext;
const Guest = guest.Guest;

inline fn reply(vc: *VCore, ctx: *ThreadCtx, err: isize, val: usize) void {
    sbi_core.setResult(vc, ctx, err, val);
}

pub fn handleGetInfo(
    vc: *VCore,
    ctx: *ThreadCtx,
    g: *Guest,
    a0: usize,
    a1: usize,
    a2: usize,
) void {
    const is_cid = a0 < sbi_core.MAX_USER_CID_DISCRIMINATOR;
    const target_cid = if (is_cid) a0 else guest.CID_SELF;
    const info_gpa = if (is_cid) a1 else a0;
    const info_len = if (is_cid) a2 else a1;

    if (info_len != 0 and info_len < @sizeOf(interface.GuestInfo)) {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }
    if (target_cid == guest.CID_PARENT) {
        reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
        return;
    }
    const tg_opt = if (target_cid == guest.CID_SELF)
        g
    else
        g.getGuestByCid(target_cid);
    const tg = tg_opt orelse {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    };

    const max_u = std.math.maxInt(usize);
    const eff_ram: usize = if (tg.space.range_size > 0)
        tg.space.range_size / physmem.PageSize
    else if (tg.is_root)
        sbi_core.DEFAULT_ROOT_RAM_BYTES / physmem.PageSize
    else if (tg.quotas.used_ram_pages > 0 and tg.quotas.used_ram_pages != max_u)
        tg.quotas.used_ram_pages
    else if (tg.quotas.max_ram_pages > 0 and tg.quotas.max_ram_pages != max_u)
        tg.quotas.max_ram_pages
    else
        sbi_core.DEFAULT_CHILD_RAM_BYTES / physmem.PageSize;

    const child_count = blk: {
        const s = tg.tree_lock.lock();
        defer tg.tree_lock.unlock(s);
        break :blk tg.children.count();
    };
    const vcpus = tg.vcores.count();
    const now = if (builtin.is_test) 0 else riscv.readTime();
    var active_ticks: u64 = 0;
    var vc_it = tg.vcores.start;
    while (vc_it) |node| : (vc_it = node.next) {
        const tvc = node.contents;
        active_ticks +|= @atomicLoad(u64, &tvc.active_ticks, .monotonic);
        const last_disp = @atomicLoad(
            u64,
            &tvc.last_dispatched_time,
            .monotonic,
        );
        if (tvc.running_on_cpu != null and
            !@atomicLoad(bool, &tvc.wfi_blocked, .acquire) and
            last_disp > 0 and now > last_disp)
        {
            active_ticks +|= now -| last_disp;
        }
    }
    const info = interface.GuestInfo{
        .guest_id = if (tg == g) guest.CID_SELF else target_cid,
        .parent_id = if (tg == g)
            (if (g.parent != null) guest.CID_PARENT else 0)
        else
            guest.CID_SELF,
        .is_trusted = if (tg.is_trusted) 1 else 0,
        .is_root = if (tg.is_root) 1 else 0,
        .target_arch = @backingInt(tg.target_arch),
        .assigned_cid = if (tg.is_root)
            guest.CID_SELF
        else
            @truncate(tg.local_cid),
        .cpu_khz_ticks = @truncate(active_ticks / 1_000),
        .vcpus = vcpus,
        .self_ram_pages = eff_ram,
        .used_vcpus = if (tg.quotas.used_vcpus > 0)
            tg.quotas.used_vcpus
        else
            vcpus,
        .max_vcpus = if (tg.quotas.max_vcpus == max_u)
            guest.DEFAULT_ROOT_MAX_VCPUS
        else
            tg.quotas.max_vcpus,
        .used_ram_pages = if (tg.quotas.used_ram_pages > 0 and
            tg.quotas.used_ram_pages != max_u)
            tg.quotas.used_ram_pages
        else if (!tg.is_root and tg.space.mode == .pmp_fallback)
            eff_ram
        else
            0,
        .max_ram_pages = if (tg.quotas.max_ram_pages == max_u)
            (if (physmem.getFreeRamBytes() > 0)
                physmem.getFreeRamBytes() / physmem.PageSize
            else
                eff_ram)
        else
            tg.quotas.max_ram_pages,
        .child_count = child_count,
        .pcpu_quota_pct = if (tg.is_root)
            guest.quota_mod.maxChildPcpuPct(tg)
        else
            tg.quotas.pcpu_quota_pct,
        .delegated_pcpu_pct = tg.quotas.delegated_pcpu_pct,
        .delegated_ram_pages = tg.quotas.delegated_ram_pages,
    };

    g.space.writeGuestStruct(interface.GuestInfo, info_gpa, info) catch {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    reply(vc, ctx, sbi_core.SBI_SUCCESS, 0);
}

pub fn formatIsaString(
    misa: usize,
    out: *[interface.HOST_CPU_ISA_LEN]u8,
) void {
    var isa_buf: [interface.HOST_CPU_ISA_LEN - 1]u8 = undefined;
    const is_64 = (misa & arch.IsaExtension.MXL_64) != 0 or
        builtin.target.cpu.arch == .riscv64;
    const base_str = if (is_64) "RV64" else "RV32";
    @memcpy(isa_buf[0..base_str.len], base_str);
    var isa_len: usize = base_str.len;

    for ("IMAFDCSUH") |ch| {
        const bit = @as(usize, 1) << @intCast(ch - 'A');
        if ((misa & bit) != 0 and isa_len < isa_buf.len) {
            isa_buf[isa_len] = ch;
            isa_len += 1;
        }
    }
    if (isa_len == base_str.len) {
        const fallback = if (is_64) "RV64GC" else "RV32IMAFDC";
        @memcpy(out[0..fallback.len], fallback);
    } else {
        @memcpy(out[0..isa_len], isa_buf[0..isa_len]);
    }
}

fn appendSegmentsTruncated(buf: []u8, segments: []const []const u8) void {
    var pos: usize = 0;
    for (segments) |seg| {
        if (pos >= buf.len) break;
        const avail = buf.len - pos;
        const copy_len: usize = @min(avail, seg.len);
        @memcpy(buf[pos .. pos + copy_len], seg[0..copy_len]);
        pos += copy_len;
    }
}

pub fn handleGetHvInfo(
    vc: *VCore,
    ctx: *ThreadCtx,
    g: *Guest,
    buf_gpa: usize,
    buf_len: usize,
) void {
    if (buf_len < @sizeOf(interface.HypervisorInfo)) {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }
    var info = interface.HypervisorInfo{};

    const ver_str = std.mem.trim(u8, std.mem.span(project_version), " \t\r\n");
    const parsed_ver = sbi_core.parseVersionString(ver_str);
    info.version_major = parsed_ver.major;
    info.version_minor = parsed_ver.minor;
    info.version_patch = parsed_ver.patch;

    const rev_str = std.mem.trim(u8, std.mem.span(git_revision), " \t\r\n");
    const copy_len: usize = @min(rev_str.len, info.build_commit.len - 1);
    @memcpy(info.build_commit[0..copy_len], rev_str[0..copy_len]);

    const is_stable = (info.version_minor % 2) == 0;
    const channel = if (is_stable) "stable" else "beta";
    info.features = interface.HypervisorFeature.DYNAREC |
        interface.HypervisorFeature.VIRTIO_VSOCK;
    if (is_stable) info.features |= interface.HypervisorFeature.RELEASE_STABLE;
    if (charter.isCharterSealed()) {
        info.features |= interface.HypervisorFeature.CHARTER_SEALED;
    }
    if (!builtin.is_test and riscv.hasHExtension()) {
        info.features |= interface.HypervisorFeature.HARDWARE_VIRT |
            interface.HypervisorFeature.STAGE2_PAGING;
    }

    info.host_physical_cores = riscv.getOnlineCpuCount();
    info.host_timer_freq_hz = interface.HOST_TIMER_FREQ_HZ;
    info.host_total_ram_kb = @intCast(physmem.getTotalRamBytes() / 1024);
    info.host_free_ram_kb = @intCast(physmem.getFreeRamBytes() / 1024);
    info.hv_reserved_bytes = @intCast(physmem.getHvRegion().size);
    info.hv_heap_free_bytes = @intCast(pcore.getTotalFreeHeapBytes());

    appendSegmentsTruncated(info.build_desc[0 .. info.build_desc.len - 1], &.{
        "Version ",
        ver_str,
        " (",
        channel,
        ") ",
        std.mem.span(git_branch),
        "/",
        rev_str,
        " ",
        std.mem.span(build_date),
        " ",
        std.mem.span(build_user),
        "@",
        std.mem.span(build_hostname),
        " (Zig ",
        std.mem.span(zig_version),
        " ",
        std.mem.span(cpu_arch),
        ")",
    });

    formatIsaString(riscv.readMisa(), &info.host_cpu_isa);

    g.space.writeGuestStruct(interface.HypervisorInfo, buf_gpa, info) catch {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    reply(vc, ctx, sbi_core.SBI_SUCCESS, 0);
}

test "formatIsaString populates expected RISC-V ISA extensions" {
    std.testing.refAllDecls(@This());
    var out: [interface.HOST_CPU_ISA_LEN]u8 = @splat(0);
    formatIsaString(arch.IsaExtension.MXL_64 | arch.IsaExtension.gc, &out);
    const s = std.mem.sliceTo(&out, 0);
    try std.testing.expectEqualStrings("RV64IMAFDC", s);
}
