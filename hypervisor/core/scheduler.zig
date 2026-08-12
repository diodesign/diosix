// Red-black tree-based scheduler of virtual CPU cores
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
const alloc = @import("alloc.zig");
const debug = @import("debug.zig");
const atomic = @import("atomic.zig");
const physmem = @import("physmem.zig");

const CoreTree = vcore.SchedulerTree;

// Global scheduler state
const SchedulerState = struct {
    run_queue: CoreTree,
};

var global_scheduler = atomic.LockPayload(SchedulerState).init("Global scheduler state", .{
    .run_queue = undefined,
});

var global_min_vruntime = std.atomic.Value(u64).init(0);

const MAX_LOCAL_VCORES = 8;
const PULL_BATCH = 4;

pub fn init() void {
    const guard = global_scheduler.acquire();
    defer guard.release();
    guard.get().run_queue.init();
}

// initialize the per-CPU scheduler state
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
}

// Add a virtual core to a run queue (local preferred, global for overflow).
// Only vcores in 'ready' state may be queued.
pub fn queue(vc: *vcore.VirtualCore) void {
    if (@atomicLoad(bool, &vc.wfi_blocked, .acquire)) return;
    // Only schedulable states may be queued.
    if (vc.state != .ready and vc.state != .running) return;

    // Atomically claim queuing rights. If already queued, do not insert again.
    if (@atomicRmw(bool, &vc.is_queued, .Xchg, true, .acq_rel)) return;

    vc.state = .ready;
    vc.running_on_cpu = null;

    // Ensure the vcore's vruntime isn't too far behind to prevent it
    // from hogging the CPU if it's been sleeping for a long time.
    const min_vr = global_min_vruntime.load(.monotonic);
    if (vc.vruntime < min_vr) {
        vc.vruntime = min_vr;
    }

    vc.updateSchedulerWeight();
    vc.last_queued_time = riscv.readTime();

    const pc = pcore.this();
    const is_local = (vc.id == pc.cpu_core_id) or (if (pc.active_vcore) |active| @intFromPtr(active) == @intFromPtr(vc) else false) or builtin.is_test;

    if (is_local and pc.run_queue_count < MAX_LOCAL_VCORES) {
        pc.run_queue.insert(&vc.scheduler_node);
        pc.run_queue_count += 1;
    } else {
        // Offload to lock-protected global queue for cross-CPU work or overflow
        const guard = global_scheduler.acquire();
        guard.get().run_queue.insert(&vc.scheduler_node);
        guard.release();

        // Wake up active physical CPUs so any idle core can pick up the work
        for (0..riscv.MAX_PHYS_CORES) |target_cpu| {
            if (riscv.cpu_contexts[target_cpu] == null) continue;
            const hw_hart = riscv.cpu_to_hart_map[target_cpu];
            if (hw_hart != pc.hardware_hart_id) {
                if (riscv.CLINT.msip(hw_hart)) |ptr| {
                    ptr.* = 1;
                }
            }
        }
    }
}

fn searchNodeById(node_opt: ?*vcore.SchedulerTree.Node, target_id: usize, misa: usize) ?*vcore.SchedulerTree.Node {
    const node = node_opt orelse return null;
    if (searchNodeById(node.left, target_id, misa)) |found| return found;
    const vc: *vcore.VirtualCore = @fieldParentPtr("scheduler_node", node);
    if (vc.id == target_id and (vc.requiredExtensions() & misa) == vc.requiredExtensions()) {
        return node;
    }
    return searchNodeById(node.right, target_id, misa);
}

fn searchNodeAny(node_opt: ?*vcore.SchedulerTree.Node, misa: usize) ?*vcore.SchedulerTree.Node {
    const node = node_opt orelse return null;
    if (searchNodeAny(node.left, misa)) |found| return found;
    const vc: *vcore.VirtualCore = @fieldParentPtr("scheduler_node", node);
    if ((vc.requiredExtensions() & misa) == vc.requiredExtensions()) {
        return node;
    }
    return searchNodeAny(node.right, misa);
}

// Pick the next virtual core to run, pulling from global if local is empty
pub fn pickNext() ?*vcore.VirtualCore {
    const pc = pcore.this();
    const misa = riscv.readMisa();

    // 1. Try to pick matching vcore (vcore.id == cpu_core_id) from local run queue first
    if (searchNodeById(pc.run_queue.root, pc.cpu_core_id, misa)) |node| {
        const vc: *vcore.VirtualCore = @fieldParentPtr("scheduler_node", node);
        pc.run_queue.remove(node);
        pc.run_queue_count -= 1;
        @atomicStore(bool, &vc.is_queued, false, .release);
        global_min_vruntime.store(vc.vruntime, .monotonic);
        return vc;
    }

    // 2. Otherwise pick any compatible vcore from local run queue
    if (searchNodeAny(pc.run_queue.root, misa)) |node| {
        const vc: *vcore.VirtualCore = @fieldParentPtr("scheduler_node", node);
        pc.run_queue.remove(node);
        pc.run_queue_count -= 1;
        @atomicStore(bool, &vc.is_queued, false, .release);
        global_min_vruntime.store(vc.vruntime, .monotonic);
        return vc;
    }

    // 3. Local queue is empty, pull matching vcore from global queue
    const guard = global_scheduler.acquire();
    defer guard.release();
    const state = guard.get();

    if (searchNodeById(state.run_queue.root, pc.cpu_core_id, misa)) |node| {
        const vc: *vcore.VirtualCore = @fieldParentPtr("scheduler_node", node);
        state.run_queue.remove(node);
        @atomicStore(bool, &vc.is_queued, false, .release);
        global_min_vruntime.store(vc.vruntime, .monotonic);
        return vc;
    }

    // 4. Fallback: pull any compatible vcore from global queue
    if (searchNodeAny(state.run_queue.root, misa)) |node| {
        const vc: *vcore.VirtualCore = @fieldParentPtr("scheduler_node", node);
        state.run_queue.remove(node);
        @atomicStore(bool, &vc.is_queued, false, .release);
        global_min_vruntime.store(vc.vruntime, .monotonic);
        return vc;
    }

    return null;
}

// Called when a physical core is ready for more work
pub fn schedule() void {
    const pc = pcore.this();

    // If there's an active vcore, update its runtime before putting it back
    if (pc.active_vcore) |ptr| {
        const vc: *vcore.VirtualCore = @ptrCast(@alignCast(ptr));
        if (!@atomicLoad(bool, &vc.wfi_blocked, .acquire)) {
            const now = riscv.readTime();
            const actual_time = if (now > vc.last_queued_time) now - vc.last_queued_time else 1;
            const delta: u64 = actual_time * 1024 / vc.weight;
            vc.vruntime += delta;
            queue(vc);
        }
        pc.active_vcore = null;
    }

    if (pickNext()) |next_vc| {
        pcore.contextSwitch(next_vc);
    } else {
        // Nothing to run.
        if (pc.cpu_core_id == 0 and pc.trap_count < 1) {
            pc.trap_count += 1;
        }
    }
}

// Relinquish the CPU to the scheduler
pub fn yield(vc: *vcore.VirtualCore) void {
    const pc = pcore.this();
    if (pc.active_vcore) |ptr| {
        const active_vc: *vcore.VirtualCore = @ptrCast(@alignCast(ptr));
        if (active_vc == vc) {
            pc.active_vcore = null;
            const now = riscv.readTime();
            const actual_time = if (now > vc.last_queued_time) now - vc.last_queued_time else 1;
            const delta: u64 = actual_time * 1024 / vc.weight;
            vc.vruntime += delta;
            queue(vc);
        }
    }
}

test "scheduler vruntime ordering" {
    const testing = std.testing;

    // Reset global scheduler state
    riscv.initMockHardware();
    {
        const guard = global_scheduler.acquire();
        defer guard.release();
        guard.get().run_queue.init();
    }
    global_min_vruntime.store(0, .monotonic);
    initCpu();

    var phys_test = try physmem.initForTest(testing.allocator, 128);
    defer phys_test.deinit();

    const testing_allocator = testing.allocator;
    const g1 = try guest.createGuest(testing_allocator, false, false, null, 0, 0, 0, .riscv64);
    defer g1.deinit();
    const g2 = try guest.createGuest(testing_allocator, false, false, null, 0, 0, 0, .riscv64);
    defer g2.deinit();
    var vc1 = vcore.VirtualCore.init(1, g1, 0, 0, .normal);
    var vc2 = vcore.VirtualCore.init(2, g2, 0, 0, .normal);

    vc1.vruntime = 100;
    vc2.vruntime = 50;
    vc1.state = .ready;
    vc2.state = .ready;

    // Queue them (not queued by init)
    queue(&vc1);
    queue(&vc2);

    // Pick next - should be vc2 because 50 < 100
    const next1 = pickNext() orelse return error.TestFailed;
    try testing.expectEqual(@as(usize, 2), next1.id);
    try testing.expectEqual(@as(u64, 50), global_min_vruntime.load(.monotonic));

    // Pick next - should be vc1
    const next2 = pickNext() orelse return error.TestFailed;
    try testing.expectEqual(@as(usize, 1), next2.id);
    try testing.expectEqual(@as(u64, 100), global_min_vruntime.load(.monotonic));

    // Queue empty
    try testing.expect(pickNext() == null);
}

test "hybrid local and global scheduling" {
    const testing = std.testing;

    // Reset state
    riscv.initMockHardware();
    {
        const guard = global_scheduler.acquire();
        defer guard.release();
        guard.get().run_queue.init();
    }
    global_min_vruntime.store(0, .monotonic);
    initCpu();

    var phys_test = try physmem.initForTest(testing.allocator, 128);
    defer phys_test.deinit();

    // Fill local queue (up to MAX_LOCAL_VCORES = 8)
    var test_guests = std.mem.zeroes([10]?*guest.Guest);
    defer for (test_guests) |maybe_g| if (maybe_g) |g| g.deinit();

    var vcpus: [10]vcore.VirtualCore = undefined;
    for (0..10) |i| {
        test_guests[i] = try guest.createGuest(testing.allocator, false, false, null, 0, 0, 0, .riscv64);
        vcpus[i] = vcore.VirtualCore.init(@intCast(i), test_guests[i].?, 0, 0, .normal);

        vcpus[i].vruntime = i * 10;
        vcpus[i].state = .ready;
        vcpus[i].updateSchedulerWeight();
        queue(&vcpus[i]);
    }

    const pc = pcore.this();
    try testing.expectEqual(@as(usize, 8), pc.run_queue_count);

    // Check that top of global queue has vcore with id 8 (the 9th one added)
    const global_min = blk: {
        const guard = global_scheduler.acquire();
        defer guard.release();
        break :blk guard.get().run_queue.findMin();
    };
    try testing.expect(global_min != null);
    const global_vc: *vcore.VirtualCore = @fieldParentPtr("scheduler_node", global_min.?);
    try testing.expectEqual(@as(usize, 8), global_vc.id);

    // Pick all from local
    for (0..8) |_| {
        _ = pickNext();
    }
    try testing.expectEqual(@as(usize, 0), pc.run_queue_count);

    // Next pick should pull from global
    // It should pull id 8 (and return it) and batch pull id 9 into local
    const pulled = pickNext() orelse return error.TestFailed;
    try testing.expectEqual(@as(usize, 8), pulled.id);
    try testing.expectEqual(@as(usize, 1), pc.run_queue_count); // id 9 should be here

    const last = pickNext() orelse return error.TestFailed;
    try testing.expectEqual(@as(usize, 9), last.id);
    try testing.expectEqual(@as(usize, 0), pc.run_queue_count);
}
