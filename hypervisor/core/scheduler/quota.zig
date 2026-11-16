// Hierarchical pCPU quota share computation and SMP rolling-window accounting.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("../../hardware/native/cpu/riscv64/mod.zig");
const pcore = @import("../pcore.zig");
const vcore = @import("../vcore.zig");
const guest = @import("../guest.zig");
const physmem = @import("../physmem.zig");
const scheduler = @import("../scheduler.zig");

pub const NICE_0_WEIGHT: u64 = vcore.WEIGHT_NORMAL;
pub const MIN_RUNTIME_DELTA: u64 = 1;
pub const PCPU_WINDOW_TICKS: u64 = 200_000; // 20 ms at 10 MHz.
pub const FULL_SHARE_BP: u64 = 10_000; // 100.00% in basis points.
pub const MIN_SHARE_BP: u64 = 100; // 1.00% floor in basis points.

/// Computes the multiplicative pCPU share granted to `g` and its subtree
/// in basis points (`10,000` = 100%). For example:
/// Root (100%) -> Child (50%) -> Grandchild (25%) = `1,250` bp (12.5%).
pub fn effectiveSubtreeShareBp(g: *const guest.Guest) u64 {
    var share_bp: u64 = FULL_SHARE_BP;
    var cur: ?*const guest.Guest = g;
    while (cur) |node| : (cur = node.parent) {
        const raw_pct = @atomicLoad(u32, &node.quotas.pcpu_quota_pct, .acquire);
        const pct: u64 = @min(@as(u64, raw_pct), 100);
        share_bp = (share_bp * pct) / 100;
    }
    return @max(MIN_SHARE_BP, share_bp);
}

/// Computes the effective pCPU share retained by `g`'s own vCores after
/// subtracting the percentage delegated to `g`'s direct children.
pub fn effectiveSelfShareBp(g: *const guest.Guest) u64 {
    const subtree_bp = effectiveSubtreeShareBp(g);
    const max_del: u64 = guest.quota_mod.maxChildPcpuPct(g);
    const raw_del = @atomicLoad(u32, &g.quotas.delegated_pcpu_pct, .acquire);
    const del_pct: u64 = @min(@as(u64, raw_del), max_del);
    const retained_pct: u64 = 100 -| del_pct;
    return @max(MIN_SHARE_BP, (subtree_bp * retained_pct) / 100);
}

fn syncGuestWindow(g: *guest.Guest, cur_win: u64) void {
    const old_win = @atomicLoad(u64, &g.quotas.window_id, .acquire);
    if (old_win != cur_win) {
        if (@cmpxchgStrong(
            u64,
            &g.quotas.window_id,
            old_win,
            cur_win,
            .acq_rel,
            .acquire,
        ) == null) {
            @atomicStore(u64, &g.quotas.window_ticks_used, 0, .release);
            @atomicStore(u64, &g.quotas.subtree_window_ticks_used, 0, .release);
        }
    }
}

/// Returns true if `g` and every ancestor in its lineage are currently within
/// their rolling window pCPU tick budgets.
pub fn isWithinPcpuQuota(g: *guest.Guest, now: u64) bool {
    const cur_win = now / PCPU_WINDOW_TICKS;
    const raw_cores: u64 = @intCast(pcore.countOnline());
    const total_win_ticks = PCPU_WINDOW_TICKS * @max(@as(u64, 1), raw_cores);

    syncGuestWindow(g, cur_win);
    const self_share = effectiveSelfShareBp(g);
    const self_budget = @max(
        @as(u64, 1),
        (total_win_ticks * self_share) / FULL_SHARE_BP,
    );
    const used = @atomicLoad(u64, &g.quotas.window_ticks_used, .acquire);
    if (used >= self_budget) return false;

    var cur: ?*guest.Guest = g;
    while (cur) |node| : (cur = node.parent) {
        syncGuestWindow(node, cur_win);
        const sub_share = effectiveSubtreeShareBp(node);
        const sub_budget = @max(
            @as(u64, 1),
            (total_win_ticks * sub_share) / FULL_SHARE_BP,
        );
        const sub_used =
            @atomicLoad(u64, &node.quotas.subtree_window_ticks_used, .acquire);
        if (sub_used >= sub_budget) return false;
    }
    return true;
}

pub fn recordActiveRuntime(vc: *vcore.VirtualCore) u64 {
    const now = riscv.readTime();
    const last_disp = @atomicLoad(u64, &vc.last_dispatched_time, .monotonic);
    if (last_disp > 0 and now > last_disp) {
        const elapsed = now -| last_disp;
        _ = @atomicRmw(u64, &vc.active_ticks, .Add, elapsed, .monotonic);
        @atomicStore(u64, &vc.last_dispatched_time, now, .monotonic);
        const cur_win = now / PCPU_WINDOW_TICKS;
        syncGuestWindow(vc.guest, cur_win);
        _ = @atomicRmw(
            u64,
            &vc.guest.quotas.window_ticks_used,
            .Add,
            elapsed,
            .monotonic,
        );
        var cur: ?*guest.Guest = vc.guest;
        while (cur) |node| : (cur = node.parent) {
            syncGuestWindow(node, cur_win);
            _ = @atomicRmw(
                u64,
                &node.quotas.subtree_window_ticks_used,
                .Add,
                elapsed,
                .monotonic,
            );
        }
        return elapsed;
    }
    return MIN_RUNTIME_DELTA;
}

pub fn accountRuntime(
    vc: *vcore.VirtualCore,
    min_vruntime: *const std.atomic.Value(u64),
) void {
    const actual_time = recordActiveRuntime(vc);
    const base_weight: u64 = if (vc.weight > 0) vc.weight else NICE_0_WEIGHT;
    const share_bp = effectiveSelfShareBp(vc.guest);
    const vcore_cnt: u64 = @max(@as(u64, 1), vc.guest.vcores.count());
    const eff_weight: u64 = @max(
        @as(u64, 1),
        (base_weight * share_bp) / (FULL_SHARE_BP * vcore_cnt),
    );
    const prev_vr = @atomicLoad(u64, &vc.vruntime, .monotonic);
    var next_vr = prev_vr +| ((actual_time *| NICE_0_WEIGHT) / eff_weight);
    const max_lead = min_vruntime.load(.monotonic) +|
        (riscv.TIMESLICE_TICKS * 4);
    if (next_vr > max_lead) next_vr = max_lead;
    @atomicStore(u64, &vc.vruntime, next_vr, .release);
}

test "scheduler quota: multiplicative subtree shares and SMP rolling budget" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    riscv.initMockHardware();
    pcore.resetForTest();
    defer pcore.resetForTest();
    scheduler.init();
    scheduler.initCpu();
    guest.quota_mod.resetGuestManagerForTest();

    var phys_test = try physmem.initForTest(testing.allocator, 128);
    defer phys_test.deinit();
    const root = try guest.createGuest(
        testing.allocator,
        true,
        true,
        null,
        0,
        0,
        0,
        .riscv64,
    );
    defer root.deinit();
    const child = try root.createChild(false, .riscv64, 1);
    defer child.deinit();
    try root.setQuota(.{
        .target_cid = child.local_cid,
        .max_ram_pages = 64,
        .pcpu_quota_pct = 50,
    });
    const gchild = try child.createChild(false, .riscv64, 1);
    defer gchild.deinit();
    try child.setQuota(.{
        .target_cid = gchild.local_cid,
        .max_ram_pages = 32,
        .pcpu_quota_pct = 25,
    });

    try testing.expectEqual(@as(u64, 1250), effectiveSubtreeShareBp(gchild));
    try testing.expectEqual(@as(u64, 1250), effectiveSelfShareBp(gchild));
    try testing.expectEqual(@as(u64, 3750), effectiveSelfShareBp(child));
    try testing.expectEqual(@as(u64, 5000), effectiveSelfShareBp(root));

    // Verify online_core_count scales rolling-window pCPU budgets across SMP.
    pcore.online_core_count.store(1, .release);
    @atomicStore(u64, &child.quotas.window_id, 0, .release);
    @atomicStore(
        u64,
        &child.quotas.window_ticks_used,
        PCPU_WINDOW_TICKS,
        .release,
    );
    @atomicStore(
        u64,
        &child.quotas.subtree_window_ticks_used,
        PCPU_WINDOW_TICKS,
        .release,
    );
    try testing.expect(!isWithinPcpuQuota(child, 0));
    // 37.5% of 4 cores = 300k ticks > 200k ticks used.
    pcore.online_core_count.store(4, .release);
    try testing.expect(isWithinPcpuQuota(child, 0));
}
