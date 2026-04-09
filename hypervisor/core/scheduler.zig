// Red-black tree-based scheduler of virtual CPU cores
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const dsa = @import("dsa.zig");
const vcore = @import("vcore.zig");
const pcore = @import("pcore.zig");
const atomic = @import("atomic.zig");
const debug = @import("debug.zig");

const CoreTree = vcore.SchedulerTree;

// Global scheduler state
const Scheduler = struct {
    run_queue: CoreTree,
    lock: atomic.NamedSpinLock,
    min_vruntime: u64,
};

var global_scheduler = Scheduler{
    .run_queue = undefined,
    .lock = atomic.NamedSpinLock.init("Global scheduler lock"),
    .min_vruntime = 0,
};

const MAX_LOCAL_VCORES = 8;
const PULL_BATCH = 4;

pub fn init() void {
    global_scheduler.run_queue.init();
}

// initialize the per-CPU scheduler state
pub fn initCpu() void {
    const pc = pcore.this();
    pc.run_queue.init();
    pc.run_queue_count = 0;
    pc.active_vcore = null;
}

// Add a virtual core to a run queue (local preferred, global for overflow)
pub fn queue(vc: *vcore.VirtualCore) void {
    const pc = pcore.this();

    // Ensure the vcore's vruntime isn't too far behind to prevent it
    // from hogging the CPU if it's been sleeping for a long time.
    if (vc.vruntime < global_scheduler.min_vruntime) {
        vc.vruntime = global_scheduler.min_vruntime;
    }

    vc.updateSchedulerWeight();

    if (pc.run_queue_count < MAX_LOCAL_VCORES) {
        pc.run_queue.insert(&vc.scheduler_node);
        pc.run_queue_count += 1;
    } else {
        // Local queue is full, offload to the global queue
        global_scheduler.lock.lock();
        defer global_scheduler.lock.unlock();
        global_scheduler.run_queue.insert(&vc.scheduler_node);
    }
}

// Pick the next virtual core to run, pulling from global if local is empty
pub fn pickNext() ?*vcore.VirtualCore {
    const pc = pcore.this();

    // 1. Try to pick from the local run queue first
    if (pc.run_queue.findMin()) |node| {
        pc.run_queue.remove(node);
        pc.run_queue_count -= 1;

        const vc: *vcore.VirtualCore = @fieldParentPtr("scheduler_node", node);
        global_scheduler.min_vruntime = vc.vruntime;
        return vc;
    }

    // 2. Local queue is empty, try to pull from the global queue
    global_scheduler.lock.lock();
    defer global_scheduler.lock.unlock();

    if (global_scheduler.run_queue.findMin()) |first_node| {
        global_scheduler.run_queue.remove(first_node);
        const first_vc: *vcore.VirtualCore = @fieldParentPtr("scheduler_node", first_node);
        global_scheduler.min_vruntime = first_vc.vruntime;

        // Greedy pull: fill local queue with some more work from global
        var pulled: usize = 0;
        while (pulled < PULL_BATCH) : (pulled += 1) {
            if (global_scheduler.run_queue.findMin()) |node| {
                global_scheduler.run_queue.remove(node);
                pc.run_queue.insert(node);
                pc.run_queue_count += 1;
            } else break;
        }

        return first_vc;
    }

    return null;
}

// Called when a physical core is ready for more work
pub fn schedule() void {
    const pc = pcore.this();

    // If there's an active vcore, update its runtime before putting it back
    if (pc.active_vcore) |ptr| {
        const vc: *vcore.VirtualCore = @ptrCast(@alignCast(ptr));
        // TODO: Calculate actual time spent running and update vruntime
        // For now, use a fixed increment
        const delta: u64 = 1000 * 1024 / vc.weight;
        vc.vruntime += delta;
        queue(vc);
        pc.active_vcore = null;
    }

    if (pickNext()) |next_vc| {
        pcore.contextSwitch(next_vc);
    } else {
        // Nothing to run.
        // In a real system we might enter a low-power state or run housekeeping.
        debug.printf("CPU {}: Idle\n", .{pc.cpu_core_id});
    }
}

test "scheduler vruntime ordering" {
    const testing = std.testing;

    // Reset global scheduler state
    global_scheduler.run_queue.init();
    global_scheduler.min_vruntime = 0;
    initCpu();

    var vc1 = vcore.VirtualCore.init(1, 1, 0, 0, .normal);
    var vc2 = vcore.VirtualCore.init(2, 1, 0, 0, .normal);

    vc1.vruntime = 100;
    vc2.vruntime = 50;

    // Queue them
    queue(&vc1);
    queue(&vc2);

    // Pick next - should be vc2 because 50 < 100
    const next1 = pickNext() orelse return error.TestFailed;
    try testing.expectEqual(@as(usize, 2), next1.id);
    try testing.expectEqual(@as(u64, 50), global_scheduler.min_vruntime);

    // Pick next - should be vc1
    const next2 = pickNext() orelse return error.TestFailed;
    try testing.expectEqual(@as(usize, 1), next2.id);
    try testing.expectEqual(@as(u64, 100), global_scheduler.min_vruntime);

    // Queue empty
    try testing.expect(pickNext() == null);
}

test "hybrid local and global scheduling" {
    const testing = std.testing;

    // Reset state
    global_scheduler.run_queue.init();
    global_scheduler.min_vruntime = 0;
    initCpu();

    // 1. Fill local queue (up to MAX_LOCAL_VCORES = 8)
    var vcores: [10]vcore.VirtualCore = undefined;
    for (0..10) |i| {
        vcores[i] = vcore.VirtualCore.init(i, 1, 0, 0, .normal);
        vcores[i].vruntime = i * 10;
        queue(&vcores[i]);
    }

    const pc = pcore.this();
    try testing.expectEqual(@as(usize, 8), pc.run_queue_count);

    // Check that top of global queue has vcore with id 8 (the 9th one added)
    global_scheduler.lock.lock();
    const global_min = global_scheduler.run_queue.findMin();
    global_scheduler.lock.unlock();
    try testing.expect(global_min != null);
    const global_vc: *vcore.VirtualCore = @fieldParentPtr("scheduler_node", global_min.?);
    try testing.expectEqual(@as(usize, 8), global_vc.id);

    // 2. Pick all from local
    for (0..8) |_| {
        _ = pickNext();
    }
    try testing.expectEqual(@as(usize, 0), pc.run_queue_count);

    // 3. Next pick should pull from global
    // It should pull id 8 (and return it) and batch pull id 9 into local
    const pulled = pickNext() orelse return error.TestFailed;
    try testing.expectEqual(@as(usize, 8), pulled.id);
    try testing.expectEqual(@as(usize, 1), pc.run_queue_count); // id 9 should be here

    const last = pickNext() orelse return error.TestFailed;
    try testing.expectEqual(@as(usize, 9), last.id);
    try testing.expectEqual(@as(usize, 0), pc.run_queue_count);
}
