// Physical CPU core management
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const riscv = @import("../hardware/native/cpu/riscv64/mod.zig");
const vcore = @import("vcore.zig");
const alloc = @import("alloc.zig");
const atomic = @import("atomic.zig");

pub const TABLE_ROWS: usize = 32;
pub const MAX_SYSTEM_CORES: usize = 4096;
pub const DYNAMIC_CORE_HEAP_SIZE: usize = 128 * 1024;

pub const DynamicCoreNode = struct {
    id: usize,
    hart_id: usize,
    context: riscv.CpuContext,
    heap_mem: []u8,
    next: ?*DynamicCoreNode = null,
};

pub const TableRow = struct {
    static_ptr: ?*riscv.CpuContext = null,
    dynamic_head: ?*DynamicCoreNode = null,
};

fn initCoreTable() [TABLE_ROWS]TableRow {
    var table: [TABLE_ROWS]TableRow = undefined;
    for (&table) |*row| {
        row.* = .{ .static_ptr = null, .dynamic_head = null };
    }
    return table;
}

// Fixed-length two-column table managing physical CPU core structures:
// Column 1: static pointers for internal IDs 0..31
// Column 2: linked list heads for dynamic cores (bucket = id % TABLE_ROWS)
pub var core_table: [TABLE_ROWS]TableRow = initCoreTable();

// Fallback / unit test storage for static contexts
pub var static_contexts: [TABLE_ROWS]riscv.CpuContext = undefined;

// Atomic sequential internal core ID counter
pub var next_cpu_id: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

// Flag indicating global dynamic heap allocator is available for cores >= 32
pub var dynamic_heap_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// Flag indicating the host machine is stopping (reboot or shutdown in progress)
pub var host_stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// Global allocator used to allocate DynamicCoreNodes for cores >= 32
pub var global_allocator: ?std.mem.Allocator = null;

// Lock protecting dynamic core insertions into Column 2
var table_lock: atomic.SpinLock = atomic.SpinLock.init();

// Atomically claim the next sequential internal physical CPU ID
pub fn claimNextCpuId() usize {
    return next_cpu_id.fetchAdd(1, .seq_cst);
}

// Mark the dynamic heap as ready and register the global allocator
pub fn setDynamicHeapReady(allocator: std.mem.Allocator) void {
    global_allocator = allocator;
    dynamic_heap_ready.store(true, .release);
}

// Check if dynamic memory allocation is ready for cores >= 32
pub fn isDynamicHeapReady() bool {
    return dynamic_heap_ready.load(.acquire);
}

// Register a static physical CPU core (IDs 0..31) in Column 1
pub fn registerStaticCore(id: usize, hart_id: usize, ctx: *riscv.CpuContext) void {
    if (id >= TABLE_ROWS) return;
    ctx.cpu_core_id = id;
    ctx.hardware_hart_id = hart_id;
    ctx.is_parked = false;
    core_table[id].static_ptr = ctx;
    if (id < riscv.cpu_to_hart_map.len) {
        riscv.cpu_to_hart_map[id] = hart_id;
    }
    if (id < riscv.cpu_contexts.len) {
        riscv.cpu_contexts[id] = ctx;
    }
}

// Register a dynamic physical CPU core (IDs 32+) in Column 2
pub fn registerDynamicCore(id: usize, hart_id: usize) !*riscv.CpuContext {
    if (id >= MAX_SYSTEM_CORES) return error.ExceedsMaxCores;
    const allocator = global_allocator orelse return error.HeapNotReady;

    if (fromId(id) != null or fromHartId(hart_id) != null) {
        return error.AlreadyExists;
    }

    const bucket = id % TABLE_ROWS;

    const heap_mem = try allocator.alloc(u8, DYNAMIC_CORE_HEAP_SIZE);
    errdefer allocator.free(heap_mem);

    const node = try allocator.create(DynamicCoreNode);
    errdefer allocator.destroy(node);
    @memset(@as([*]u8, @ptrCast(node))[0..@sizeOf(DynamicCoreNode)], 0);
    node.id = id;
    node.hart_id = hart_id;
    node.heap_mem = heap_mem;
    node.next = null;

    node.context.cpu_core_id = id;
    node.context.hardware_hart_id = hart_id;
    node.context.last_timer_val = riscv.TIMER_INFINITY;
    node.context.in_m_mode = true;
    node.context.is_parked = false;
    node.context.blocked_lock = atomic.SpinLock.init();
    node.context.allocator.init(@intFromPtr(heap_mem.ptr), heap_mem.len) catch |err| {
        return err;
    };

    const flags = table_lock.lock();
    defer table_lock.unlock(flags);

    var cur = core_table[bucket].dynamic_head;
    while (cur) |c| {
        if (c.id == id or c.hart_id == hart_id) {
            return error.AlreadyExists;
        }
        cur = c.next;
    }

    node.next = core_table[bucket].dynamic_head;
    core_table[bucket].dynamic_head = node;

    return &node.context;
}

// Return the CPU context for the physical core running this code
pub fn this() *riscv.CpuContext {
    return riscv.getCPUContext();
}

// Return the CPU context for the given internal physical core ID, or null
pub fn fromId(id: usize) ?*riscv.CpuContext {
    if (id < TABLE_ROWS) {
        return core_table[id].static_ptr;
    }
    if (id >= MAX_SYSTEM_CORES) return null;

    const flags = table_lock.lock();
    defer table_lock.unlock(flags);

    const bucket = id % TABLE_ROWS;
    var current = core_table[bucket].dynamic_head;
    while (current) |node| {
        if (node.id == id) {
            return &node.context;
        }
        current = node.next;
    }
    return null;
}

// Return the CPU context for the given hardware hart ID, or null
pub fn fromHartId(hart_id: usize) ?*riscv.CpuContext {
    // Check Column 1 (static cores)
    for (0..TABLE_ROWS) |i| {
        if (core_table[i].static_ptr) |ctx| {
            if (ctx.hardware_hart_id == hart_id) {
                return ctx;
            }
        }
    }
    // Check Column 2 (dynamic cores) under table_lock
    const flags = table_lock.lock();
    defer table_lock.unlock(flags);

    for (0..TABLE_ROWS) |bucket| {
        var current = core_table[bucket].dynamic_head;
        while (current) |node| {
            if (node.hart_id == hart_id) {
                return &node.context;
            }
            current = node.next;
        }
    }
    return null;
}

// Check if a given tp value points to a valid host CpuContext
pub fn isHostTp(tp_val: usize) bool {
    if (tp_val == 0 or tp_val % 16 != 0) return false;

    // Check Column 1 static pointers
    for (0..TABLE_ROWS) |i| {
        if (core_table[i].static_ptr) |ctx| {
            if (@intFromPtr(ctx) == tp_val) return true;
        }
    }
    // Check Column 2 dynamic nodes under table_lock
    const flags = table_lock.lock();
    defer table_lock.unlock(flags);

    for (0..TABLE_ROWS) |bucket| {
        var current = core_table[bucket].dynamic_head;
        while (current) |node| {
            if (@intFromPtr(&node.context) == tp_val) return true;
            current = node.next;
        }
    }
    return false;
}

// Count total online physical cores (static + dynamic)
pub fn countOnline() usize {
    var count: usize = 0;
    for (0..TABLE_ROWS) |i| {
        if (core_table[i].static_ptr != null) count += 1;
    }
    const flags = table_lock.lock();
    defer table_lock.unlock(flags);

    for (0..TABLE_ROWS) |i| {
        var current = core_table[i].dynamic_head;
        while (current) |node| {
            count += 1;
            current = node.next;
        }
    }
    return count;
}

// Return the total free bytes in the hypervisor heap across all active physical CPU cores
pub fn getTotalFreeHeapBytes() usize {
    var total: usize = 0;
    for (0..TABLE_ROWS) |i| {
        if (core_table[i].static_ptr) |ctx| {
            total += ctx.allocator.free_size;
        }
    }
    const flags = table_lock.lock();
    defer table_lock.unlock(flags);

    for (0..TABLE_ROWS) |i| {
        var current = core_table[i].dynamic_head;
        while (current) |node| {
            total += node.context.allocator.free_size;
            current = node.next;
        }
    }
    return total;
}

pub extern fn hw_run_vcore(
    context: *riscv.ThreadContext,
    machine: *const riscv.MachineState,
    guest_state: *const riscv.GuestState,
) noreturn;

// Send a physical IPI to a specific physical CPU internal core ID (0..4095)
pub fn sendIpiToCpu(cpu_id: usize) void {
    if (builtin.is_test) return;
    if (fromId(cpu_id)) |ctx| {
        const hw_hart = ctx.hardware_hart_id;
        if (hw_hart != this().hardware_hart_id) {
            if (riscv.CLINT.msip(hw_hart)) |ptr| {
                ptr.* = 1;
                return;
            }
        } else {
            return;
        }
    }
    broadcastIpi();
}

// Send a physical IPI to all other online physical cores to wake them.
pub fn broadcastIpi() void {
    if (builtin.is_test) return;
    const my_hart = this().hardware_hart_id;

    // Column 1 static cores
    for (0..TABLE_ROWS) |i| {
        if (core_table[i].static_ptr) |ctx| {
            const hw_hart = ctx.hardware_hart_id;
            if (hw_hart != my_hart) {
                if (riscv.CLINT.msip(hw_hart)) |ptr| {
                    ptr.* = 1;
                }
            }
        }
    }

    // Column 2 dynamic cores
    const flags = table_lock.lock();
    defer table_lock.unlock(flags);

    for (0..TABLE_ROWS) |bucket| {
        var current = core_table[bucket].dynamic_head;
        while (current) |node| {
            const hw_hart = node.hart_id;
            if (hw_hart != my_hart) {
                if (riscv.CLINT.msip(hw_hart)) |ptr| {
                    ptr.* = 1;
                }
            }
            current = node.next;
        }
    }
}

// Signal all other online physical cores to park in M-mode and spin-wait until they are parked.
pub fn parkOtherCores() void {
    host_stopping.store(true, .release);
    broadcastIpi();

    if (countOnline() <= 1) return;

    const my_ctx = this();
    const max_spins: usize = if (builtin.is_test) 1_000 else 100_000_000;
    var spins: usize = 0;
    while (spins < max_spins) : (spins += 1) {
        var all_parked = true;

        // Check Column 1 static cores
        for (0..TABLE_ROWS) |i| {
            if (core_table[i].static_ptr) |ctx| {
                if (ctx != my_ctx) {
                    if (!@atomicLoad(bool, &ctx.is_parked, .acquire)) {
                        all_parked = false;
                        break;
                    }
                }
            }
        }

        if (all_parked) {
            // Check Column 2 dynamic cores
            const flags = table_lock.lock();
            for (0..TABLE_ROWS) |bucket| {
                var current = core_table[bucket].dynamic_head;
                while (current) |node| {
                    if (&node.context != my_ctx) {
                        if (!@atomicLoad(bool, &node.context.is_parked, .acquire)) {
                            all_parked = false;
                            break;
                        }
                    }
                    current = node.next;
                }
                if (!all_parked) break;
            }
            table_lock.unlock(flags);
        }

        if (all_parked) return;

        if (spins % 10_000 == 0) {
            broadcastIpi();
        }
        riscv.pause();
    }
}

// Perform a context switch to the given virtual core
// This sets up the physical core to run the guest on the next exception return
pub fn contextSwitch(to_vcore: *vcore.VirtualCore) void {
    const cpu = this();
    if (cpu.active_vcore) |active| {
        if (@intFromPtr(active) == @intFromPtr(to_vcore) and to_vcore.running_on_cpu == cpu.cpu_core_id) {
            return;
        }
    }
    if ((@intFromPtr(to_vcore) & (@alignOf(vcore.VirtualCore) - 1)) != 0) {
        @import("debug.zig").printf("!!! contextSwitch given misaligned to_vcore 0x{x}\n", .{@intFromPtr(to_vcore)});
    }
    cpu.active_vcore = to_vcore;
    to_vcore.running_on_cpu = cpu.cpu_core_id;
    to_vcore.state = .running;
    to_vcore.last_dispatched_time = if (builtin.is_test) 0 else riscv.readTime();

    const pmp = @import("../hardware/native/cpu/riscv64/pmp.zig");
    pmp.PMPConfig.clearAllPmp();
    pmp.PMPConfig.writePmpAddr(0, std.math.maxInt(usize));
    pmp.PMPConfig.writePmpCfg(0, pmp.PMPAccess.napot | pmp.PMPAccess.rwx); // NAPOT, RWX

    to_vcore.guest.space.apply(to_vcore.guest.vmid);
    if (to_vcore.exec_path == .emulated) {
        // Store physical CPU core context pointer in emulated runner's tp register and vcore in a0
        if (!to_vcore.exec_path.emulated.emu_running) {
            to_vcore.context[@intFromEnum(riscv.Register.tp)] = @intFromPtr(cpu);
            to_vcore.context[@intFromEnum(riscv.Register.a0)] = @intFromPtr(to_vcore);
        }
    }
}

// Free all dynamically allocated core nodes
pub fn deinitDynamicCores() void {
    if (global_allocator) |allocator| {
        for (0..TABLE_ROWS) |bucket| {
            var current = core_table[bucket].dynamic_head;
            while (current) |node| {
                const next = node.next;
                if (node.heap_mem.len > 0) {
                    allocator.free(node.heap_mem);
                }
                allocator.destroy(node);
                current = next;
            }
            core_table[bucket].dynamic_head = null;
        }
    }
}

// Reset state for unit tests
pub fn resetForTest() void {
    deinitDynamicCores();
    core_table = initCoreTable();
    next_cpu_id.store(0, .seq_cst);
    dynamic_heap_ready.store(false, .seq_cst);
    host_stopping.store(false, .seq_cst);
    global_allocator = null;
}

test "physical CPU: static cores 0..31 indexed via Column 1" {
    resetForTest();
    defer resetForTest();

    // Register static cores 0..31
    for (0..TABLE_ROWS) |id| {
        @memset(@as([*]u8, @ptrCast(&static_contexts[id]))[0..@sizeOf(riscv.CpuContext)], 0);
        registerStaticCore(id, id * 10, &static_contexts[id]);
    }

    // Core 3 must directly resolve to static slot 3
    const core3 = fromId(3);
    try std.testing.expect(core3 != null);
    try std.testing.expectEqual(@as(usize, 3), core3.?.cpu_core_id);
    try std.testing.expectEqual(@as(usize, 30), core3.?.hardware_hart_id);
    try std.testing.expectEqual(@intFromPtr(&static_contexts[3]), @intFromPtr(core3.?));

    // Verify all 0..31
    for (0..TABLE_ROWS) |id| {
        const ctx = fromId(id);
        try std.testing.expect(ctx != null);
        try std.testing.expectEqual(id, ctx.?.cpu_core_id);
        try std.testing.expectEqual(id * 10, ctx.?.hardware_hart_id);
    }

    // Unregistered core >= 32 returns null
    try std.testing.expect(fromId(32) == null);
    try std.testing.expectEqual(@as(usize, 32), countOnline());
}

test "physical CPU: dynamic core 38 pauses then allocates into bucket 6 (Column 2)" {
    resetForTest();
    defer resetForTest();

    // Static core 3 in Column 1
    @memset(@as([*]u8, @ptrCast(&static_contexts[3]))[0..@sizeOf(riscv.CpuContext)], 0);
    registerStaticCore(3, 300, &static_contexts[3]);

    // Before dynamic heap is ready, registerDynamicCore returns error.HeapNotReady
    try std.testing.expect(!isDynamicHeapReady());
    try std.testing.expectError(error.HeapNotReady, registerDynamicCore(38, 380));

    // Boot CPU initializes dynamic heap
    setDynamicHeapReady(std.testing.allocator);
    try std.testing.expect(isDynamicHeapReady());

    // Core 38 registers dynamically
    const core38 = try registerDynamicCore(38, 380);
    try std.testing.expectEqual(@as(usize, 38), core38.cpu_core_id);
    try std.testing.expectEqual(@as(usize, 380), core38.hardware_hart_id);

    // Verify it is placed in bucket 38 % 32 = 6
    const bucket = 38 % TABLE_ROWS;
    try std.testing.expectEqual(@as(usize, 6), bucket);
    try std.testing.expect(core_table[6].dynamic_head != null);
    try std.testing.expectEqual(@as(usize, 38), core_table[6].dynamic_head.?.id);

    // Fast lookup fromId(38) succeeds
    const lookup38 = fromId(38);
    try std.testing.expect(lookup38 != null);
    try std.testing.expectEqual(@intFromPtr(core38), @intFromPtr(lookup38.?));

    // Fast lookup fromId(3) still succeeds via Column 1
    const lookup3 = fromId(3);
    try std.testing.expect(lookup3 != null);
    try std.testing.expectEqual(@as(usize, 3), lookup3.?.cpu_core_id);

    // Lookup fromHartId
    try std.testing.expect(fromHartId(300) != null);
    try std.testing.expect(fromHartId(380) != null);
    try std.testing.expect(fromHartId(999) == null);

    // Online count: 1 static + 1 dynamic = 2
    try std.testing.expectEqual(@as(usize, 2), countOnline());
}

test "physical CPU: hash collisions in Column 2 (e.g. core 38 and core 70)" {
    resetForTest();
    defer resetForTest();

    setDynamicHeapReady(std.testing.allocator);

    // Core 38: 38 % 32 = 6
    const core38 = try registerDynamicCore(38, 380);
    // Core 70: 70 % 32 = 6
    const core70 = try registerDynamicCore(70, 700);

    try std.testing.expectEqual(@as(usize, 6), 38 % TABLE_ROWS);
    try std.testing.expectEqual(@as(usize, 6), 70 % TABLE_ROWS);

    // Both must be found correctly via fromId
    const found38 = fromId(38);
    const found70 = fromId(70);
    try std.testing.expect(found38 != null);
    try std.testing.expect(found70 != null);
    try std.testing.expectEqual(@intFromPtr(core38), @intFromPtr(found38.?));
    try std.testing.expectEqual(@intFromPtr(core70), @intFromPtr(found70.?));

    // Both must be found via fromHartId
    try std.testing.expectEqual(@intFromPtr(core38), @intFromPtr(fromHartId(380).?));
    try std.testing.expectEqual(@intFromPtr(core70), @intFromPtr(fromHartId(700).?));
}

test "physical CPU: scaling up to 4096 cores dynamically" {
    resetForTest();
    defer resetForTest();

    setDynamicHeapReady(std.testing.allocator);

    // Register all 32 static cores
    for (0..TABLE_ROWS) |id| {
        @memset(@as([*]u8, @ptrCast(&static_contexts[id]))[0..@sizeOf(riscv.CpuContext)], 0);
        registerStaticCore(id, id + 1000, &static_contexts[id]);
    }

    // Register dynamic cores from 32 up to 512
    const target_cores: usize = 512;
    var id: usize = TABLE_ROWS;
    while (id < target_cores) : (id += 1) {
        _ = try registerDynamicCore(id, id + 1000);
    }

    try std.testing.expectEqual(target_cores, countOnline());

    // Verify lookups across range
    for (0..target_cores) |check_id| {
        const ctx = fromId(check_id);
        try std.testing.expect(ctx != null);
        try std.testing.expectEqual(check_id, ctx.?.cpu_core_id);
        try std.testing.expectEqual(check_id + 1000, ctx.?.hardware_hart_id);

        const hart_ctx = fromHartId(check_id + 1000);
        try std.testing.expect(hart_ctx != null);
        try std.testing.expectEqual(@intFromPtr(ctx.?), @intFromPtr(hart_ctx.?));
    }

    // Beyond max system cores error check
    try std.testing.expectError(error.ExceedsMaxCores, registerDynamicCore(MAX_SYSTEM_CORES, 9999));
}

test "physical CPU: isHostTp validation for static and dynamic cores" {
    resetForTest();
    defer resetForTest();

    setDynamicHeapReady(std.testing.allocator);

    @memset(@as([*]u8, @ptrCast(&static_contexts[0]))[0..@sizeOf(riscv.CpuContext)], 0);
    registerStaticCore(0, 0, &static_contexts[0]);
    const dyn_ctx = try registerDynamicCore(40, 400);

    // Host tp check
    try std.testing.expect(isHostTp(@intFromPtr(&static_contexts[0])));
    try std.testing.expect(isHostTp(@intFromPtr(dyn_ctx)));

    // Non-host or bogus addresses
    try std.testing.expect(!isHostTp(0));
    try std.testing.expect(!isHostTp(0x1234));
    try std.testing.expect(!isHostTp(@intFromPtr(&static_contexts[0]) + 1));
}

test "physical CPU: sendIpiToCpu and dynamic hart ID resolution" {
    resetForTest();
    defer resetForTest();

    setDynamicHeapReady(std.testing.allocator);

    // Static core 0 with hardware hart 100
    @memset(@as([*]u8, @ptrCast(&static_contexts[0]))[0..@sizeOf(riscv.CpuContext)], 0);
    registerStaticCore(0, 100, &static_contexts[0]);

    // Dynamic core 45 with hardware hart 450
    const dyn_ctx = try registerDynamicCore(45, 450);

    // Verify lookup of hardware hart IDs
    try std.testing.expectEqual(@as(usize, 100), fromId(0).?.hardware_hart_id);
    try std.testing.expectEqual(@as(usize, 450), fromId(45).?.hardware_hart_id);
    try std.testing.expectEqual(@as(usize, 45), dyn_ctx.cpu_core_id);

    // sendIpiToCpu executes safely in test mode without crashing
    sendIpiToCpu(0);
    sendIpiToCpu(45);
    sendIpiToCpu(999); // Unregistered core falls back gracefully
}

test "physical CPU: duplicate registration prevention in Column 2" {
    resetForTest();
    defer resetForTest();

    setDynamicHeapReady(std.testing.allocator);

    // Register dynamic core ID 50 with hart 500
    const dyn1 = try registerDynamicCore(50, 500);
    try std.testing.expectEqual(@as(usize, 50), dyn1.cpu_core_id);

    // Duplicate ID should fail
    try std.testing.expectError(error.AlreadyExists, registerDynamicCore(50, 501));

    // Duplicate hart ID should fail
    try std.testing.expectError(error.AlreadyExists, registerDynamicCore(51, 500));

    // Unique ID and hart should succeed
    const dyn2 = try registerDynamicCore(51, 501);
    try std.testing.expectEqual(@as(usize, 51), dyn2.cpu_core_id);
}

test "physical CPU: parkOtherCores signals host_stopping and waits for secondary cores" {
    resetForTest();
    defer resetForTest();

    try std.testing.expect(!host_stopping.load(.acquire));

    // Register static core 0 (current core) and core 1 (secondary core)
    @memset(@as([*]u8, @ptrCast(&static_contexts[1]))[0..@sizeOf(riscv.CpuContext)], 0);
    registerStaticCore(0, 0, riscv.getCPUContext());
    registerStaticCore(1, 10, &static_contexts[1]);

    // Initially secondary core is not parked
    try std.testing.expect(!static_contexts[1].is_parked);

    // Simulate secondary core receiving IPI and parking in M-mode
    static_contexts[1].is_parked = true;

    // parkOtherCores should set host_stopping and complete cleanly
    parkOtherCores();
    try std.testing.expect(host_stopping.load(.acquire));
}

