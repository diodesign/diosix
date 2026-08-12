// Simple, robust linked list scheduler of virtual CPU cores
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

// Global scheduler state using a simple intrusive doubly-linked list
const SchedulerState = struct {
    run_queue: dsa.LinkedList(*vcore.VirtualCore),
};

var global_scheduler = atomic.LockPayload(SchedulerState).init("Global scheduler state", .{
    .run_queue = undefined,
});

var global_min_vruntime = std.atomic.Value(u64).init(0);

const MAX_LOCAL_VCORES = 8;

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

    // Do NOT queue if actively running on a physical CPU
    if (vc.running_on_cpu != null) return;

    // Atomically claim queuing rights. If already queued, do not insert again.
    if (@atomicRmw(bool, &vc.is_queued, .Xchg, true, .acq_rel)) return;

    vc.state = .ready;

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

    vc.scheduler_node.contents = vc;
    if (is_local and pc.run_queue_count < MAX_LOCAL_VCORES) {
        const node_ptr: *dsa.LinkedList(*anyopaque).Node = @ptrCast(&vc.scheduler_node);
        pc.run_queue.pushEnd(node_ptr);
        pc.run_queue_count += 1;
    } else {
        // Offload to lock-protected global queue for cross-CPU work or overflow
        const guard = global_scheduler.acquire();
        guard.get().run_queue.pushEnd(&vc.scheduler_node);
        guard.release();

        // Wake up active physical CPUs so any idle core can pick up the work
        for (0..riscv.MAX_PHYS_CORES) |hw_hart| {
            if (hw_hart != pc.hardware_hart_id) {
                if (riscv.CLINT.msip(hw_hart)) |ptr| {
                    ptr.* = 1;
                }
            }
        }
    }
}

// Pick the next virtual core to run, pulling from global if local is empty
pub fn pickNext() ?*vcore.VirtualCore {
    const pc = pcore.this();
    const misa = riscv.readMisa();

    // 1. Try to pick matching vcore (vcore.id == cpu_core_id) from local run queue first
    var it = pc.run_queue.start;
    while (it) |node| {
        const vc: *vcore.VirtualCore = @ptrCast(@alignCast(node.contents));
        if (vc.running_on_cpu != null) {
            it = node.next;
            continue;
        }
        if (vc.id == pc.cpu_core_id and (vc.requiredExtensions() & misa) == vc.requiredExtensions()) {
            pc.run_queue.remove(node);
            pc.run_queue_count -= 1;
            vc.running_on_cpu = pc.cpu_core_id;
            @atomicStore(bool, &vc.is_queued, false, .release);
            global_min_vruntime.store(vc.vruntime, .monotonic);
            return vc;
        }
        it = node.next;
    }

    // 2. Otherwise pick any compatible vcore from local run queue
    it = pc.run_queue.start;
    while (it) |node| {
        const vc: *vcore.VirtualCore = @ptrCast(@alignCast(node.contents));
        if (vc.running_on_cpu != null) {
            it = node.next;
            continue;
        }
        if ((vc.requiredExtensions() & misa) == vc.requiredExtensions()) {
            pc.run_queue.remove(node);
            pc.run_queue_count -= 1;
            vc.running_on_cpu = pc.cpu_core_id;
            @atomicStore(bool, &vc.is_queued, false, .release);
            global_min_vruntime.store(vc.vruntime, .monotonic);
            return vc;
        }
        it = node.next;
    }

    // 3. Local queue is empty, pull matching vcore from global queue under lock
    const guard = global_scheduler.acquire();
    defer guard.release();
    const state = guard.get();

    var g_it = state.run_queue.start;
    while (g_it) |node| {
        const vc: *vcore.VirtualCore = node.contents;
        if (vc.running_on_cpu != null) {
            g_it = node.next;
            continue;
        }
        if (vc.id == pc.cpu_core_id and (vc.requiredExtensions() & misa) == vc.requiredExtensions()) {
            state.run_queue.remove(node);
            vc.running_on_cpu = pc.cpu_core_id;
            @atomicStore(bool, &vc.is_queued, false, .release);
            global_min_vruntime.store(vc.vruntime, .monotonic);
            return vc;
        }
        g_it = node.next;
    }

    // 4. Fallback: pull any compatible vcore from global queue
    g_it = state.run_queue.start;
    while (g_it) |node| {
        const vc: *vcore.VirtualCore = node.contents;
        if (vc.running_on_cpu != null) {
            g_it = node.next;
            continue;
        }
        if ((vc.requiredExtensions() & misa) == vc.requiredExtensions()) {
            state.run_queue.remove(node);
            vc.running_on_cpu = pc.cpu_core_id;
            @atomicStore(bool, &vc.is_queued, false, .release);
            global_min_vruntime.store(vc.vruntime, .monotonic);
            return vc;
        }
        g_it = node.next;
    }

    return null;
}

// Called when a physical core is ready for more work
pub fn schedule() void {
    const pc = pcore.this();

    // If there's an active vcore, update its runtime before putting it back
    if (pc.active_vcore) |ptr| {
        const vc: *vcore.VirtualCore = @ptrCast(@alignCast(ptr));
        const was_wfi = @atomicLoad(bool, &vc.wfi_blocked, .acquire);
        vc.running_on_cpu = null;
        pc.active_vcore = null;
        if (!was_wfi) {
            const now = riscv.readTime();
            const actual_time = if (now > vc.last_queued_time) now - vc.last_queued_time else 1;
            const delta: u64 = actual_time * 1024 / vc.weight;
            vc.vruntime += delta;
            queue(vc);
        }
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
            vc.running_on_cpu = null;
            pc.active_vcore = null;
            const now = riscv.readTime();
            const actual_time = if (now > vc.last_queued_time) now - vc.last_queued_time else 1;
            const delta: u64 = actual_time * 1024 / vc.weight;
            vc.vruntime += delta;
            queue(vc);
        }
    }
}

test "scheduler basic queuing and picking" {
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

    queue(&vc1);
    queue(&vc2);

    const next1 = pickNext() orelse return error.TestFailed;
    try testing.expect(next1.id == 1 or next1.id == 2);

    const next2 = pickNext() orelse return error.TestFailed;
    try testing.expect(next2.id == 1 or next2.id == 2);

    try testing.expect(pickNext() == null);
}
