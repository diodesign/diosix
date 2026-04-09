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

// ordering function for the RB-Tree (already defined in vcore.zig, but needed here)
fn compareU64(a: u64, b: u64) i8 {
    if (a < b) return -1;
    if (a > b) return 1;
    return 0;
}

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

pub fn init() void {
    global_scheduler.run_queue.init();
}

// Add a virtual core to the global run queue
pub fn queue(vc: *vcore.VirtualCore) void {
    global_scheduler.lock.lock();
    defer global_scheduler.lock.unlock();

    // Ensure the vcore's vruntime isn't too far behind to prevent it
    // from hogging the CPU if it's been sleeping for a long time.
    if (vc.vruntime < global_scheduler.min_vruntime) {
        vc.vruntime = global_scheduler.min_vruntime;
    }

    vc.updateSchedulerWeight();
    global_scheduler.run_queue.insert(&vc.scheduler_node);
}

// Pick the next virtual core to run and remove it from the queue
pub fn pickNext() ?*vcore.VirtualCore {
    global_scheduler.lock.lock();
    defer global_scheduler.lock.unlock();

    if (global_scheduler.run_queue.findMin()) |node| {
        global_scheduler.run_queue.remove(node);

        // Map the RB-Tree node back to the VirtualCore
        const vc: *vcore.VirtualCore = @fieldParentPtr("scheduler_node", node);

        // Update the global minimum vruntime
        global_scheduler.min_vruntime = vc.vruntime;

        return vc;
    }
    return null;
}

// Called when a physical core is ready for more work
pub fn schedule() void {
    const pc = pcore.this();

    // If there's an active vcore, update its runtime before putting it back
    if (pc.active_vcore) |vc| {
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
