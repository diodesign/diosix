// Red-black tree-based scheduler of virtual CPU cores
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("riscv.zig");
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
    pc.trap_count = 0;
    pc.last_trap_pc = 0;
    pc.trap_loop_count = 0;
}

// Add a virtual core to a run queue (local preferred, global for overflow).
// Only vcores in 'ready' state may be queued.
pub fn queue(vc: *vcore.VirtualCore) void {
    // Only schedulable states may be queued.
    if (vc.state != .ready and vc.state != .running) return;
    vc.state = .ready;

    const pc = pcore.this();

    // Ensure the vcore's vruntime isn't too far behind to prevent it
    // from hogging the CPU if it's been sleeping for a long time.
    if (vc.vruntime < global_scheduler.min_vruntime) {
        vc.vruntime = global_scheduler.min_vruntime;
    }

    vc.updateSchedulerWeight();

    // Record the time at which this vcore was last queued (for accounting).
    vc.last_queued_time = riscv.readTime();

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
    const misa = riscv.readMisa();

    debug.raw_puts("PC ");
    debug.raw_putchar(@as(u8, @intCast(pc.cpu_core_id)) + '0');
    debug.raw_puts(": Pick\n");

    // 1. Try to pick from the local run queue first
    var it = pc.run_queue.findMin();
    while (it) |node| {
        const vc: *vcore.VirtualCore = @fieldParentPtr("scheduler_node", node);
        if ((vc.required_extensions & misa) == vc.required_extensions) {
            pc.run_queue.remove(node);
            pc.run_queue_count -= 1;
            global_scheduler.min_vruntime = vc.vruntime;
            return vc;
        }
        // If not compatible, try next in local queue (rare case if local queue is filtered)
        it = pc.run_queue.findNext(node);
    }

    // 2. Local queue is empty or incompatible, try to pull from the global queue
    debug.raw_puts("PC ");
    debug.raw_putchar(@as(u8, @intCast(pc.cpu_core_id)) + '0');
    debug.raw_puts(": GLock\n");
    global_scheduler.lock.lock();
    debug.raw_puts("PC ");
    debug.raw_putchar(@as(u8, @intCast(pc.cpu_core_id)) + '0');
    debug.raw_puts(": GAcq\n");
    defer global_scheduler.lock.unlock();

    var g_it = global_scheduler.run_queue.findMin();
    while (g_it) |node| {
        const vc: *vcore.VirtualCore = @fieldParentPtr("scheduler_node", node);
        if ((vc.required_extensions & misa) == vc.required_extensions) {
            global_scheduler.run_queue.remove(node);
            global_scheduler.min_vruntime = vc.vruntime;

            // Greedy pull: fill local queue with some more compatible work from global
            var pulled: usize = 0;
            var next_g = global_scheduler.run_queue.findMin();
            while (pulled < PULL_BATCH and next_g != null) {
                const g_node = next_g.?;
                next_g = global_scheduler.run_queue.findNext(g_node);
                
                const g_vc: *vcore.VirtualCore = @fieldParentPtr("scheduler_node", g_node);
                if ((g_vc.required_extensions & misa) == g_vc.required_extensions) {
                    global_scheduler.run_queue.remove(g_node);
                    pc.run_queue.insert(g_node);
                    pc.run_queue_count += 1;
                    pulled += 1;
                }
            }

            return vc;
        }
        g_it = global_scheduler.run_queue.findNext(node);
    }

    return null;
}

// Called when a physical core is ready for more work
pub fn schedule() void {
    const pc = pcore.this();

    // If there's an active vcore, update its runtime before putting it back
    if (pc.active_vcore) |ptr| {
        const vc: *vcore.VirtualCore = @ptrCast(@alignCast(ptr));
        // Calculate actual time spent running using the hardware timer.
        const now = riscv.readTime();
        const actual_time = if (now > vc.last_queued_time) now - vc.last_queued_time else 1;
        // Weight the runtime: heavier processes accumulate vruntime more slowly.
        const delta: u64 = actual_time * 1024 / vc.weight;
        vc.vruntime += delta;
        queue(vc);
        pc.active_vcore = null;
    }

    if (pickNext()) |next_vc| {
        debug.raw_puts("CPU ");
        debug.raw_putchar(@as(u8, @intCast(pc.cpu_core_id)) + '0');
        debug.raw_puts(": Run guest=");
        debug.raw_puthex(next_vc.guest_id);
        debug.raw_puts(" vcore=");
        debug.raw_puthex(next_vc.id);
        debug.raw_putchar('\n');
        
        pcore.contextSwitch(next_vc);
    } else {
        // Nothing to run.
        if (pc.cpu_core_id == 0 and pc.trap_count < 1) {
            debug.raw_puts("CPU 0: Idle\n");
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
    global_scheduler.run_queue.init();
    global_scheduler.min_vruntime = 0;
    initCpu();

    var phys_test = try physmem.initForTest(testing.allocator, 128);
    defer phys_test.deinit();

    const testing_allocator = testing.allocator;
    const g1 = try guest.createGuest(testing_allocator, false, false, null, 0, 0, 0);
    defer g1.deinit();
    const g2 = try guest.createGuest(testing_allocator, false, false, null, 0, 0, 0);
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
    riscv.initMockHardware();
    global_scheduler.run_queue.init();
    global_scheduler.min_vruntime = 0;
    initCpu();

    var phys_test = try physmem.initForTest(testing.allocator, 128);
    defer phys_test.deinit();

    // 1. Fill local queue (up to MAX_LOCAL_VCORES = 8)
    var test_guests = std.mem.zeroes([10]?*guest.Guest);
    defer for (test_guests) |maybe_g| if (maybe_g) |g| g.deinit();

    var vcpus: [10]vcore.VirtualCore = undefined;
    for (0..10) |i| {
        test_guests[i] = try guest.createGuest(testing.allocator, false, false, null, 0, 0, 0);
        vcpus[i] = vcore.VirtualCore.init(@intCast(i), test_guests[i].?, 0, 0, .normal);
        
        vcpus[i].vruntime = i * 10;
        vcpus[i].state = .ready;
        vcpus[i].updateSchedulerWeight();
        queue(&vcpus[i]);
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
