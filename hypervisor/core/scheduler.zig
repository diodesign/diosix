// Red-black tree virtual CPU core scheduler with hierarchical pCPU quota
// shares and work-conserving CFS-style vruntime ordering.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const riscv = @import("../hardware/native/cpu/riscv64/mod.zig");
const pcore = @import("pcore.zig");
const vcore = @import("vcore.zig");
const guest = @import("guest.zig");
const atomic = @import("atomic.zig");
const physmem = @import("physmem.zig");
pub const quota = @import("scheduler/quota.zig");

pub const NICE_0_WEIGHT = quota.NICE_0_WEIGHT;
pub const MIN_RUNTIME_DELTA = quota.MIN_RUNTIME_DELTA;
pub const PCPU_WINDOW_TICKS = quota.PCPU_WINDOW_TICKS;
pub const FULL_SHARE_BP = quota.FULL_SHARE_BP;
pub const MIN_SHARE_BP = quota.MIN_SHARE_BP;
pub const effectiveSubtreeShareBp = quota.effectiveSubtreeShareBp;
pub const effectiveSelfShareBp = quota.effectiveSelfShareBp;
pub const isWithinPcpuQuota = quota.isWithinPcpuQuota;
pub const recordActiveRuntime = quota.recordActiveRuntime;

// Global scheduler state backed by an intrusive vruntime red-black tree.
const SchedulerState = struct {
    run_tree: vcore.SchedulerTree = .{},
};

var global_scheduler = atomic.LockPayload(SchedulerState).init(
    "Global scheduler state",
    .{},
);

var global_min_vruntime = std.atomic.Value(u64).init(0);

const MAX_LOCAL_VCORES = 8;

pub fn init() void {
    const guard = global_scheduler.acquire();
    defer guard.release();
    guard.get().run_tree.init();
}

// Initialize the per-CPU scheduler state.
pub fn initCpu() void {
    const pc = pcore.this();
    pcore.getRunTree(pc).init();
    pc.run_queue_count = 0;
    pc.blocked_queue.init();
    pc.active_vcore = null;
    pc.trap_count = 0;
    pc.last_trap_pc = 0;
    pc.last_trap_val = 0;
    pc.trap_loop_count = 0;
    pc.in_emulation_runner = false;
}

// Add a virtual core to a run tree (local preferred, global for overflow).
// Only vcores in 'ready' or 'running' state may be queued.
pub fn queue(vc: *vcore.VirtualCore) void {
    enqueue(vc, true);
}

fn isVcoreRunnableForEnqueue(vc: *vcore.VirtualCore) bool {
    const cur_state = @atomicLoad(vcore.VirtualCoreState, &vc.state, .acquire);
    const g_state = @atomicLoad(guest.GuestState, &vc.guest.state, .acquire);
    return !@atomicLoad(bool, &vc.wfi_blocked, .acquire) and
        vc.getRunningCpu() == null and
        cur_state == .ready and g_state == .valid;
}

fn enqueue(vc: *vcore.VirtualCore, notify_idle: bool) void {
    if (@atomicLoad(bool, &vc.wfi_blocked, .seq_cst)) return;
    const init_state = @atomicLoad(vcore.VirtualCoreState, &vc.state, .seq_cst);
    if (init_state != .ready and init_state != .running) return;
    if (@atomicLoad(guest.GuestState, &vc.guest.state, .acquire) != .valid) {
        @atomicStore(vcore.VirtualCoreState, &vc.state, .stopped, .seq_cst);
        return;
    }

    if (vc.getRunningCpu() != null) return;
    if (@atomicRmw(bool, &vc.is_queued, .Xchg, true, .acq_rel)) return;

    _ = @cmpxchgStrong(
        vcore.VirtualCoreState,
        &vc.state,
        .running,
        .ready,
        .seq_cst,
        .seq_cst,
    );
    const min_vr = global_min_vruntime.load(.monotonic);
    const cur_vr = @atomicLoad(u64, &vc.vruntime, .acquire);
    if (cur_vr < min_vr) @atomicStore(u64, &vc.vruntime, min_vr, .release);

    vc.updateSchedulerWeight();
    vc.last_queued_time = riscv.readTime();

    const pc = pcore.this();
    const target_local_pc: ?*riscv.CpuContext = if (builtin.is_test)
        pc
    else if (vc.guest.has_host_passthrough)
        pcore.fromHartId(vc.id)
    else
        null;

    vc.scheduler_node.contents = vc;
    if (target_local_pc) |lpc| {
        @atomicStore(usize, &vc.queued_cpu_id, lpc.cpu_core_id, .seq_cst);
        const run_lock = pcore.getRunLock(lpc);
        const run_flags = run_lock.lock();
        if (!isVcoreRunnableForEnqueue(vc)) {
            @atomicStore(usize, &vc.queued_cpu_id, vcore.NO_CPU, .release);
            @atomicStore(bool, &vc.is_queued, false, .release);
            run_lock.unlock(run_flags);
            return;
        }
        if (lpc.run_queue_count < MAX_LOCAL_VCORES) {
            pcore.getRunTree(lpc).insert(&vc.scheduler_node);
            vc.setInRunTree(true);
            lpc.run_queue_count += 1;
            run_lock.unlock(run_flags);
            if (notify_idle and !builtin.is_test and lpc != pc) {
                pcore.sendIpiToCpu(lpc.cpu_core_id);
            }
            return;
        }
        @atomicStore(usize, &vc.queued_cpu_id, vcore.NO_CPU, .release);
        run_lock.unlock(run_flags);
    } else {
        @atomicStore(usize, &vc.queued_cpu_id, vcore.NO_CPU, .release);
    }

    const guard = global_scheduler.acquire();
    if (!isVcoreRunnableForEnqueue(vc)) {
        @atomicStore(bool, &vc.is_queued, false, .release);
        guard.release();
        return;
    }
    guard.get().run_tree.insert(&vc.scheduler_node);
    vc.setInRunTree(true);
    guard.release();

    if (notify_idle) pcore.wakeIdleCores();
}

fn dequeueFromCore(target_pc: *riscv.CpuContext, vc: *vcore.VirtualCore) bool {
    const run_lock = pcore.getRunLock(target_pc);
    const run_flags = run_lock.lock();
    defer run_lock.unlock(run_flags);

    if (vc.isInRunTree() and
        @atomicLoad(usize, &vc.queued_cpu_id, .acquire) ==
            target_pc.cpu_core_id)
    {
        pcore.getRunTree(target_pc).remove(&vc.scheduler_node);
        vc.setInRunTree(false);
        if (target_pc.run_queue_count > 0) target_pc.run_queue_count -= 1;
        @atomicStore(usize, &vc.queued_cpu_id, vcore.NO_CPU, .release);
        @atomicStore(bool, &vc.is_queued, false, .release);
        return true;
    }
    return false;
}

// Remove a virtual core from its local or global run tree in O(log N).
pub fn dequeue(vc: *vcore.VirtualCore) void {
    if (!@atomicLoad(bool, &vc.is_queued, .acquire)) return;
    const pc = pcore.this();
    const target_cpu = @atomicLoad(usize, &vc.queued_cpu_id, .seq_cst);
    if (target_cpu != vcore.NO_CPU) {
        const target_pc = if (target_cpu == pc.cpu_core_id)
            pc
        else
            pcore.fromId(target_cpu);
        if (target_pc) |tpc| {
            if (dequeueFromCore(tpc, vc)) return;
        }
    }

    const guard = global_scheduler.acquire();
    defer guard.release();
    if (vc.isInRunTree() and
        @atomicLoad(usize, &vc.queued_cpu_id, .acquire) == vcore.NO_CPU)
    {
        guard.get().run_tree.remove(&vc.scheduler_node);
        vc.setInRunTree(false);
        @atomicStore(bool, &vc.is_queued, false, .release);
    }
}

fn canRunOnCpu(
    vc: *const vcore.VirtualCore,
    pc: *const riscv.CpuContext,
    misa: usize,
) bool {
    if (vc.getRunningCpu() != null) return false;
    const req = vc.requiredExtensions();
    if ((req & misa) != req) return false;
    if (!builtin.is_test and vc.guest.has_host_passthrough) {
        return vc.id == pc.hardware_hart_id;
    }
    return true;
}

const TreeScanResult = struct {
    uq_node: ?*vcore.SchedulerTree.Node = null,
    any_node: ?*vcore.SchedulerTree.Node = null,
};

fn scanRunTree(
    tree: *vcore.SchedulerTree,
    count_opt: ?*usize,
    pc: *const riscv.CpuContext,
    misa: usize,
    now: u64,
) TreeScanResult {
    var res = TreeScanResult{};
    var it = tree.findMin();
    while (it) |node| {
        const next_it = tree.findNext(node);
        const vc = node.contents;
        const cur_st =
            @atomicLoad(vcore.VirtualCoreState, &vc.state, .acquire);
        const g_st =
            @atomicLoad(guest.GuestState, &vc.guest.state, .acquire);
        if (cur_st == .stopped or g_st != .valid) {
            @atomicStore(vcore.VirtualCoreState, &vc.state, .stopped, .seq_cst);
            tree.remove(node);
            vc.setInRunTree(false);
            if (count_opt) |cnt| {
                if (cnt.* > 0) cnt.* -= 1;
            }
            @atomicStore(usize, &vc.queued_cpu_id, vcore.NO_CPU, .release);
            @atomicStore(bool, &vc.is_queued, false, .release);
            it = next_it;
            continue;
        }
        if (canRunOnCpu(vc, pc, misa)) {
            if (res.any_node == null) res.any_node = node;
            if (isWithinPcpuQuota(vc.guest, now)) {
                res.uq_node = node;
                break;
            }
        }
        it = next_it;
    }
    return res;
}

// Pick the next virtual core to run using a two-pass work-conserving policy
// over ascending vruntime red-black trees:
// Pass 1 takes the lowest-vruntime runnable vCore within its pCPU quota window
// (early-exiting on the first match). Pass 2 falls back to the lowest-vruntime
// over-quota vCore so physical cores never idle when runnable work exists.
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

    const local_tree = pcore.getRunTree(pc);
    const local_scan = scanRunTree(
        local_tree,
        &pc.run_queue_count,
        pc,
        misa,
        now,
    );
    const global_scan = scanRunTree(&state.run_tree, null, pc, misa, now);

    const has_uq =
        (local_scan.uq_node != null or global_scan.uq_node != null);
    const idle_other = pcore.hasIdleOtherCore();
    const best_local_node = if (has_uq and !idle_other)
        local_scan.uq_node
    else
        (local_scan.uq_node orelse local_scan.any_node);
    const best_local_vr = if (best_local_node) |n|
        @atomicLoad(u64, &n.contents.vruntime, .monotonic)
    else
        std.math.maxInt(u64);
    const best_global_node =
        if (has_uq) global_scan.uq_node else global_scan.any_node;
    const best_global_vr = if (best_global_node) |n|
        @atomicLoad(u64, &n.contents.vruntime, .monotonic)
    else
        std.math.maxInt(u64);
    const prefer_local = best_local_node != null and
        (local_scan.uq_node != null or idle_other or
            best_local_vr <= best_global_vr);

    if (best_global_node != null and !prefer_local) {
        const node = best_global_node.?;
        const vc = node.contents;
        state.run_tree.remove(node);
        vc.setInRunTree(false);
        vc.setRunningCpu(pc.cpu_core_id);
        @atomicStore(usize, &vc.queued_cpu_id, vcore.NO_CPU, .release);
        @atomicStore(bool, &vc.is_queued, false, .release);
        const vr = @atomicLoad(u64, &vc.vruntime, .monotonic);
        _ = global_min_vruntime.fetchMax(vr, .monotonic);
        return vc;
    }

    if (best_local_node) |node| {
        const vc = node.contents;
        local_tree.remove(node);
        vc.setInRunTree(false);
        if (pc.run_queue_count > 0) pc.run_queue_count -= 1;
        vc.setRunningCpu(pc.cpu_core_id);
        @atomicStore(usize, &vc.queued_cpu_id, vcore.NO_CPU, .release);
        @atomicStore(bool, &vc.is_queued, false, .release);
        const vr = @atomicLoad(u64, &vc.vruntime, .monotonic);
        _ = global_min_vruntime.fetchMax(vr, .monotonic);
        if (best_global_node != null) pcore.wakeIdleCores();
        return vc;
    }

    return null;
}

pub fn accountRuntime(vc: *vcore.VirtualCore) void {
    quota.accountRuntime(vc, &global_min_vruntime);
}

fn descheduleActive(pc: *riscv.CpuContext, vc: *vcore.VirtualCore) void {
    // Update vruntime while running_cpu_id still identifies this hart so a
    // concurrent tryWake() + queue() on another hart cannot insert vc into a
    // red-black tree while its key is changing.
    accountRuntime(vc);
    @atomicStore(u64, &vc.last_dispatched_time, 0, .monotonic);
    pc.active_vcore = null;
    vc.setRunningCpu(null);

    if (!@atomicLoad(bool, &vc.wfi_blocked, .seq_cst)) {
        _ = @cmpxchgStrong(
            vcore.VirtualCoreState,
            &vc.state,
            .running,
            .ready,
            .seq_cst,
            .seq_cst,
        );
        if (@atomicLoad(vcore.VirtualCoreState, &vc.state, .seq_cst) ==
            .ready)
        {
            enqueue(vc, false);
        }
    }
}

// Called when a physical core is ready for more work.
pub fn schedule() void {
    const pc = pcore.this();
    const prev_ptr = pc.active_vcore;

    if (prev_ptr) |ptr| {
        const vc: *vcore.VirtualCore = @ptrCast(@alignCast(ptr));
        descheduleActive(pc, vc);
    }

    if (pickNext()) |next_vc| {
        if (prev_ptr == @as(?*anyopaque, next_vc)) {
            pc.active_vcore = next_vc;
        } else if (prev_ptr) |ptr| {
            const pvc: *vcore.VirtualCore = @ptrCast(@alignCast(ptr));
            if (@atomicLoad(bool, &pvc.is_queued, .acquire) and
                !pvc.guest.has_host_passthrough) pcore.wakeIdleCores();
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
        descheduleActive(pc, vc);
    }
    if (pickNext()) |next_vc| {
        if (prev_ptr == @as(?*anyopaque, next_vc)) pc.active_vcore = next_vc;
        pcore.contextSwitch(next_vc);
    }
}

test "scheduler red-black tree vruntime ordering, dequeue, and fallback" {
    _ = quota;
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    riscv.initMockHardware();
    pcore.resetForTest();
    defer pcore.resetForTest();
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

    // Child is over-quota; root (vc1) is dispatched first, then work-conserving
    // fallback dispatches child (vc2).
    var vc1 = vcore.VirtualCore.init(1, root, 0, 0, .normal);
    var vc2 = vcore.VirtualCore.init(2, child, 0, 0, .normal);
    var vc3 = vcore.VirtualCore.init(3, root, 0, 0, .normal);
    vc1.vruntime = 100;
    vc2.vruntime = 50;
    vc3.vruntime = 25;
    vc1.state = .ready;
    vc2.state = .ready;
    vc3.state = .ready;
    queue(&vc1);
    queue(&vc2);
    queue(&vc3);
    dequeue(&vc3);
    try testing.expect(!vc3.is_queued and !vc3.isInRunTree());
    try testing.expectEqual(@as(usize, 1), (pickNext() orelse unreachable).id);
    try testing.expectEqual(@as(usize, 2), (pickNext() orelse unreachable).id);
    try testing.expect(pickNext() == null);

    // Concurrent WFI wake while running_cpu_id is still set must not drop wake:
    // queue() returns early while running, then descheduleActive() requeues vc.
    pcore.this().active_vcore = &vc2;
    vc2.setRunningCpu(pcore.this().cpu_core_id);
    vc2.setState(.blocked);
    @atomicStore(bool, &vc2.wfi_blocked, true, .seq_cst);
    try testing.expect(vc2.tryWake());
    queue(&vc2);
    try testing.expect(!vc2.is_queued);
    descheduleActive(pcore.this(), &vc2);
    try testing.expect(vc2.is_queued and vc2.isInRunTree());
    try testing.expectEqual(@as(?usize, null), vc2.getRunningCpu());
    dequeue(&vc2);
}
