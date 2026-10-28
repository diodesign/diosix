// Linked-list virtual CPU core scheduler with hierarchical pCPU quota shares
// and work-conserving CFS-style vruntime ordering.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const riscv = @import("../hardware/native/cpu/riscv64/mod.zig");
const dsa = @import("dsa.zig");
const pcore = @import("pcore.zig");
const vcore = @import("vcore.zig");
const guest = @import("guest.zig");
const atomic = @import("atomic.zig");
const physmem = @import("physmem.zig");

// Global scheduler state using an intrusive doubly-linked list.
const SchedulerState = struct {
    run_queue: dsa.LinkedList(*vcore.VirtualCore),
};

var global_scheduler = atomic.LockPayload(SchedulerState).init(
    "Global scheduler state",
    .{ .run_queue = undefined },
);

var global_min_vruntime = std.atomic.Value(u64).init(0);

const MAX_LOCAL_VCORES = 8;

pub const NICE_0_WEIGHT: u64 = vcore.WEIGHT_NORMAL;
pub const MIN_RUNTIME_DELTA: u64 = 1;
pub const PCPU_WINDOW_TICKS: u64 = 200_000; // 20 ms at 10 MHz.
pub const FULL_SHARE_BP: u64 = 10_000; // 100.00% in basis points.
pub const MIN_SHARE_BP: u64 = 100; // 1.00% floor in basis points.

pub fn init() void {
    const guard = global_scheduler.acquire();
    defer guard.release();
    guard.get().run_queue.init();
}

// Initialize the per-CPU scheduler state.
pub fn initCpu() void {
    const pc = pcore.this();
    pc.run_queue.init();
    pc.run_queue_count = 0;
    pc.blocked_queue.init();
    pc.active_vcore = null;
    pc.blocked_vcore = null;
    pc.trap_count = 0;
    pc.last_trap_pc = 0;
    pc.last_trap_val = 0;
    pc.trap_loop_count = 0;
    pc.in_emulation_runner = false;
}

/// Computes the multiplicative pCPU share granted to `g` and its subtree
/// in basis points (`10,000` = 100%). For example:
/// Root (100%) -> Child (50%) -> Grandchild (25%) = `1,250` bp (12.5%).
pub fn effectiveSubtreeShareBp(g: *const guest.Guest) u64 {
    var share_bp: u64 = FULL_SHARE_BP;
    var cur: ?*const guest.Guest = g;
    while (cur) |node| : (cur = node.parent) {
        const pct: u64 = @min(@as(u64, node.quotas.pcpu_quota_pct), 100);
        share_bp = (share_bp * pct) / 100;
    }
    return @max(MIN_SHARE_BP, share_bp);
}

/// Computes the effective pCPU share retained by `g`'s own vCores after
/// subtracting the percentage delegated to `g`'s direct children.
pub fn effectiveSelfShareBp(g: *const guest.Guest) u64 {
    const subtree_bp = effectiveSubtreeShareBp(g);
    const del_pct: u64 = @min(
        @as(u64, g.quotas.delegated_pcpu_pct),
        guest.quota_mod.MAX_CHILD_PCPU_QUOTA_PCT,
    );
    const retained_pct: u64 = 100 -| del_pct;
    return @max(MIN_SHARE_BP, (subtree_bp * retained_pct) / 100);
}

fn syncGuestWindow(g: *guest.Guest, cur_win: u64) void {
    if (g.quotas.window_id != cur_win) {
        g.quotas.window_id = cur_win;
        g.quotas.window_ticks_used = 0;
        g.quotas.subtree_window_ticks_used = 0;
    }
}

/// Returns true if `g` and every ancestor in its lineage are currently within
/// their rolling window pCPU tick budgets.
pub fn isWithinPcpuQuota(g: *guest.Guest, now: u64) bool {
    const cur_win = now / PCPU_WINDOW_TICKS;
    const raw_cores: u64 = @intCast(pcore.next_cpu_id.load(.acquire));
    const total_win_ticks = PCPU_WINDOW_TICKS * @max(@as(u64, 1), raw_cores);

    syncGuestWindow(g, cur_win);
    const self_share = effectiveSelfShareBp(g);
    const self_budget = @max(
        @as(u64, 1),
        (total_win_ticks * self_share) / FULL_SHARE_BP,
    );
    if (g.quotas.window_ticks_used >= self_budget) return false;

    var cur: ?*guest.Guest = g;
    while (cur) |node| : (cur = node.parent) {
        syncGuestWindow(node, cur_win);
        const sub_share = effectiveSubtreeShareBp(node);
        const sub_budget = @max(
            @as(u64, 1),
            (total_win_ticks * sub_share) / FULL_SHARE_BP,
        );
        if (node.quotas.subtree_window_ticks_used >= sub_budget) return false;
    }
    return true;
}

// Add a virtual core to a run queue (local preferred, global for overflow).
// Only vcores in 'ready' or 'running' state may be queued.
pub fn queue(vc: *vcore.VirtualCore) void {
    enqueue(vc, true);
}

fn enqueue(vc: *vcore.VirtualCore, notify_idle: bool) void {
    if (@atomicLoad(bool, &vc.wfi_blocked, .acquire)) return;
    if (vc.state != .ready and vc.state != .running) return;
    if (vc.guest.state != .valid) {
        vc.state = .stopped;
        return;
    }

    if (vc.running_on_cpu != null) return;
    if (@atomicRmw(bool, &vc.is_queued, .Xchg, true, .acq_rel)) return;

    vc.state = .ready;
    const min_vr = global_min_vruntime.load(.monotonic);
    if (vc.vruntime < min_vr) vc.vruntime = min_vr;

    vc.updateSchedulerWeight();
    vc.last_queued_time = riscv.readTime();

    const pc = pcore.this();
    const target_local_pc: ?*riscv.CpuContext = if (builtin.is_test)
        pc
    else if (vc.guest.is_root)
        pcore.fromHartId(vc.id)
    else
        null;

    vc.scheduler_node.contents = vc;
    if (target_local_pc) |lpc| {
        const run_lock = pcore.getRunLock(lpc);
        const run_flags = run_lock.lock();
        if (lpc.run_queue_count < MAX_LOCAL_VCORES) {
            const node_ptr: *dsa.LinkedList(*anyopaque).Node =
                @ptrCast(&vc.scheduler_node);
            lpc.run_queue.pushEnd(node_ptr);
            lpc.run_queue_count += 1;
            run_lock.unlock(run_flags);
            if (notify_idle and !builtin.is_test and lpc != pc) {
                pcore.sendIpiToCpu(lpc.cpu_core_id);
            }
            return;
        }
        run_lock.unlock(run_flags);
    }

    const guard = global_scheduler.acquire();
    guard.get().run_queue.pushEnd(&vc.scheduler_node);
    guard.release();

    if (notify_idle) pcore.wakeIdleCores();
}

fn dequeueFromCore(target_pc: *riscv.CpuContext, vc: *vcore.VirtualCore) bool {
    const run_lock = pcore.getRunLock(target_pc);
    const run_flags = run_lock.lock();
    defer run_lock.unlock(run_flags);

    var it_local = target_pc.run_queue.start;
    while (it_local) |node| : (it_local = node.next) {
        const local_vc: *vcore.VirtualCore =
            @ptrCast(@alignCast(node.contents));
        if (local_vc == vc) {
            target_pc.run_queue.remove(node);
            if (target_pc.run_queue_count > 0) target_pc.run_queue_count -= 1;
            @atomicStore(bool, &vc.is_queued, false, .release);
            return true;
        }
    }
    return false;
}

// Remove a virtual core from the run queue if present.
pub fn dequeue(vc: *vcore.VirtualCore) void {
    const pc = pcore.this();
    if (dequeueFromCore(pc, vc)) return;
    if (pcore.fromHartId(vc.id)) |hart_pc| {
        if (hart_pc != pc and dequeueFromCore(hart_pc, vc)) return;
    }
    for (&pcore.core_table) |*row| {
        if (row.static_ptr) |other_pc| {
            if (other_pc != pc and dequeueFromCore(other_pc, vc)) return;
        }
    }
    const guard = global_scheduler.acquire();
    defer guard.release();
    const state = guard.get();
    var it = state.run_queue.start;
    while (it) |node| : (it = node.next) {
        if (node.contents == vc) {
            state.run_queue.remove(node);
            @atomicStore(bool, &vc.is_queued, false, .release);
            break;
        }
    }
}

fn canRunOnCpu(
    vc: *const vcore.VirtualCore,
    pc: *const riscv.CpuContext,
    misa: usize,
) bool {
    if (vc.running_on_cpu != null) return false;
    const req = vc.requiredExtensions();
    if ((req & misa) != req) return false;
    if (!builtin.is_test and vc.guest.is_root) {
        return vc.id == pc.hardware_hart_id;
    }
    return true;
}

// Pick the next virtual core to run using a two-pass work-conserving policy:
// Pass 1 prefers runnable vCores whose VM (and ancestors) are within their
// pCPU quota window budget. Pass 2 falls back to over-quota vCores so physical
// cores never idle when runnable work exists.
pub fn pickNext() ?*vcore.VirtualCore {
    const pc = pcore.this();
    const misa = riscv.readMisa();
    const now = riscv.readTime();

    const guard = global_scheduler.acquire();
    defer guard.release();
    const state = guard.get();

    const run_lock = pcore.getRunLock(pc);
    const run_flags = run_lock.lock();
    defer run_lock.unlock(run_flags);

    var uq_local_node: ?*dsa.LinkedList(*anyopaque).Node = null;
    var uq_local_vr: u64 = std.math.maxInt(u64);
    var any_local_node: ?*dsa.LinkedList(*anyopaque).Node = null;
    var any_local_vr: u64 = std.math.maxInt(u64);

    var it = pc.run_queue.start;
    while (it) |node| {
        const next_it = node.next;
        const vc: *vcore.VirtualCore = @ptrCast(@alignCast(node.contents));
        if (vc.state == .stopped or vc.guest.state != .valid) {
            vc.state = .stopped;
            pc.run_queue.remove(node);
            if (pc.run_queue_count > 0) pc.run_queue_count -= 1;
            @atomicStore(bool, &vc.is_queued, false, .release);
            it = next_it;
            continue;
        }
        if (canRunOnCpu(vc, pc, misa)) {
            if (vc.vruntime < any_local_vr) {
                any_local_vr = vc.vruntime;
                any_local_node = node;
            }
            if (isWithinPcpuQuota(vc.guest, now) and
                vc.vruntime < uq_local_vr)
            {
                uq_local_vr = vc.vruntime;
                uq_local_node = node;
            }
        }
        it = next_it;
    }

    var uq_global_node: ?*dsa.LinkedList(*vcore.VirtualCore).Node = null;
    var uq_global_vr: u64 = std.math.maxInt(u64);
    var any_global_node: ?*dsa.LinkedList(*vcore.VirtualCore).Node = null;
    var any_global_vr: u64 = std.math.maxInt(u64);

    var g_it = state.run_queue.start;
    while (g_it) |node| {
        const next_git = node.next;
        const vc: *vcore.VirtualCore = node.contents;
        if (vc.state == .stopped or vc.guest.state != .valid) {
            vc.state = .stopped;
            state.run_queue.remove(node);
            @atomicStore(bool, &vc.is_queued, false, .release);
            g_it = next_git;
            continue;
        }
        if (canRunOnCpu(vc, pc, misa)) {
            if (vc.vruntime < any_global_vr) {
                any_global_vr = vc.vruntime;
                any_global_node = node;
            }
            if (isWithinPcpuQuota(vc.guest, now) and
                vc.vruntime < uq_global_vr)
            {
                uq_global_vr = vc.vruntime;
                uq_global_node = node;
            }
        }
        g_it = next_git;
    }

    const has_uq = (uq_local_node != null or uq_global_node != null);
    const idle_other = pcore.hasIdleOtherCore();
    const best_local_node = if (has_uq and !idle_other)
        uq_local_node
    else
        (uq_local_node orelse any_local_node);
    const best_local_vr =
        if (best_local_node == uq_local_node) uq_local_vr else any_local_vr;
    const best_global_node = if (has_uq) uq_global_node else any_global_node;
    const best_global_vr = if (has_uq) uq_global_vr else any_global_vr;
    const prefer_local = best_local_node != null and
        (idle_other or best_local_vr <= best_global_vr);

    if (best_global_node != null and !prefer_local) {
        const node = best_global_node.?;
        const vc = node.contents;
        state.run_queue.remove(node);
        vc.running_on_cpu = pc.cpu_core_id;
        @atomicStore(bool, &vc.is_queued, false, .release);
        _ = global_min_vruntime.fetchMax(vc.vruntime, .monotonic);
        return vc;
    }

    if (best_local_node) |node| {
        const vc: *vcore.VirtualCore = @ptrCast(@alignCast(node.contents));
        pc.run_queue.remove(node);
        if (pc.run_queue_count > 0) pc.run_queue_count -= 1;
        vc.running_on_cpu = pc.cpu_core_id;
        @atomicStore(bool, &vc.is_queued, false, .release);
        _ = global_min_vruntime.fetchMax(vc.vruntime, .monotonic);
        if (best_global_node != null) pcore.wakeIdleCores();
        return vc;
    }

    return null;
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
        vc.guest.quotas.window_ticks_used +|= elapsed;
        var cur: ?*guest.Guest = vc.guest;
        while (cur) |node| : (cur = node.parent) {
            syncGuestWindow(node, cur_win);
            node.quotas.subtree_window_ticks_used +|= elapsed;
        }
        return elapsed;
    }
    return MIN_RUNTIME_DELTA;
}

pub fn accountRuntime(vc: *vcore.VirtualCore) void {
    const actual_time = recordActiveRuntime(vc);
    const base_weight: u64 = if (vc.weight > 0) vc.weight else NICE_0_WEIGHT;
    const share_bp = effectiveSelfShareBp(vc.guest);
    const vcore_cnt: u64 = @max(@as(u64, 1), vc.guest.vcores.count());
    const eff_weight: u64 = @max(
        @as(u64, 1),
        (base_weight * share_bp) / (FULL_SHARE_BP * vcore_cnt),
    );
    vc.vruntime +|= (actual_time *| NICE_0_WEIGHT) / eff_weight;
    const max_lead = global_min_vruntime.load(.monotonic) +|
        (riscv.TIMESLICE_TICKS * 4);
    if (vc.vruntime > max_lead) vc.vruntime = max_lead;
}

fn accountAndRequeue(vc: *vcore.VirtualCore) void {
    if (vc.state != .ready and vc.state != .running) return;
    vc.state = .ready;
    accountRuntime(vc);
    enqueue(vc, false);
}

// Called when a physical core is ready for more work.
pub fn schedule() void {
    const pc = pcore.this();
    const prev_ptr = pc.active_vcore;

    if (prev_ptr) |ptr| {
        const vc: *vcore.VirtualCore = @ptrCast(@alignCast(ptr));
        const was_wfi = @atomicLoad(bool, &vc.wfi_blocked, .acquire);
        vc.running_on_cpu = null;
        pc.active_vcore = null;
        if (!was_wfi) accountAndRequeue(vc) else accountRuntime(vc);
    }

    if (pickNext()) |next_vc| {
        if (prev_ptr == @as(?*anyopaque, next_vc)) {
            pc.active_vcore = next_vc;
        } else if (prev_ptr) |ptr| {
            const pvc: *vcore.VirtualCore = @ptrCast(@alignCast(ptr));
            if (@atomicLoad(bool, &pvc.is_queued, .acquire) and
                !pvc.guest.is_root) pcore.wakeIdleCores();
        }
        pcore.contextSwitch(next_vc);
        if (next_vc.exec_path == .emulated and !pc.in_emulation_runner) {
            pc.in_emulation_runner = true;
            @import("emulation.zig").emulatedRunnerSMode(next_vc);
        }
    } else if (pc.cpu_core_id == 0 and pc.trap_count < 1) {
        pc.trap_count += 1;
    }
}

// Relinquish the CPU to the scheduler.
pub fn yield(vc: *vcore.VirtualCore) void {
    const pc = pcore.this();
    const prev_ptr = pc.active_vcore;
    if (prev_ptr == @as(?*anyopaque, vc)) {
        vc.running_on_cpu = null;
        pc.active_vcore = null;
        accountAndRequeue(vc);
    }
    if (pickNext()) |next_vc| {
        if (prev_ptr == @as(?*anyopaque, next_vc)) pc.active_vcore = next_vc;
        pcore.contextSwitch(next_vc);
    }
}

test "scheduler queuing, multiplicative pCPU shares, and work-conserving" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    riscv.initMockHardware();
    init();
    global_min_vruntime.store(0, .monotonic);
    initCpu();
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

    var vc1 = vcore.VirtualCore.init(1, root, 0, 0, .normal);
    var vc2 = vcore.VirtualCore.init(2, child, 0, 0, .normal);
    child.quotas.window_id = 0;
    child.quotas.window_ticks_used = PCPU_WINDOW_TICKS;
    child.quotas.subtree_window_ticks_used = PCPU_WINDOW_TICKS;
    vc1.vruntime = 100;
    vc2.vruntime = 50;
    vc1.state = .ready;
    vc2.state = .ready;
    queue(&vc1);
    queue(&vc2);
    try testing.expectEqual(@as(usize, 1), (pickNext() orelse unreachable).id);
    try testing.expectEqual(@as(usize, 2), (pickNext() orelse unreachable).id);
    try testing.expect(pickNext() == null);
}
