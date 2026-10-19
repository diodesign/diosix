// Physical CPU core management.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const riscv = @import("../hardware/native/cpu/riscv64/mod.zig");
const vcore = @import("vcore.zig");
const atomic = @import("atomic.zig");

pub const TABLE_ROWS: usize = 32;
pub const MAX_SYSTEM_CORES: usize = 4096;
pub const DYNAMIC_CORE_HEAP_SIZE: usize = 128 * 1024;
pub const TP_REQUIRED_ALIGNMENT: usize = 16;

pub const DynamicCoreNode = struct {
    id: usize,
    hart_id: usize,
    context: riscv.CpuContext,
    run_lock: atomic.SpinLock = atomic.SpinLock.init(),
    heap_mem: []u8,
    next: ?*DynamicCoreNode = null,
};

pub const TableRow = struct {
    static_ptr: ?*riscv.CpuContext = null,
    dynamic_head: ?*DynamicCoreNode = null,
};

fn initCoreTable() [TABLE_ROWS]TableRow {
    var table: [TABLE_ROWS]TableRow = undefined;
    for (&table) |*row| row.* = .{};
    return table;
}

// Fixed-length two-column table managing physical CPU core structures:
// Column 1: static pointers for internal IDs 0..31.
// Column 2: linked list heads for dynamic cores (bucket = id % TABLE_ROWS).
pub var core_table: [TABLE_ROWS]TableRow = initCoreTable();
pub var static_contexts: [TABLE_ROWS]riscv.CpuContext = undefined;
pub var static_run_locks: [TABLE_ROWS]atomic.SpinLock =
    @splat(atomic.SpinLock.init());
pub var next_cpu_id: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
pub var dynamic_heap_ready: std.atomic.Value(bool) =
    std.atomic.Value(bool).init(false);
pub var host_stopping: std.atomic.Value(bool) =
    std.atomic.Value(bool).init(false);
pub var global_allocator: ?std.mem.Allocator = null;
var table_lock: atomic.SpinLock = atomic.SpinLock.init();

pub fn getRunLock(ctx: *riscv.CpuContext) *atomic.SpinLock {
    if (ctx.cpu_core_id < TABLE_ROWS) {
        return &static_run_locks[ctx.cpu_core_id];
    }
    const node: *DynamicCoreNode = @fieldParentPtr("context", ctx);
    return &node.run_lock;
}

pub fn claimNextCpuId() usize {
    return next_cpu_id.fetchAdd(1, .seq_cst);
}

pub fn setDynamicHeapReady(allocator: std.mem.Allocator) void {
    global_allocator = allocator;
    dynamic_heap_ready.store(true, .release);
}

pub fn isDynamicHeapReady() bool {
    return dynamic_heap_ready.load(.acquire);
}

pub fn registerStaticCore(
    id: usize,
    hart_id: usize,
    ctx: *riscv.CpuContext,
) void {
    if (id >= TABLE_ROWS) return;
    ctx.cpu_core_id = id;
    ctx.hardware_hart_id = hart_id;
    ctx.is_parked = false;
    static_run_locks[id] = atomic.SpinLock.init();
    core_table[id].static_ptr = ctx;
    if (id < riscv.cpu_to_hart_map.len) riscv.cpu_to_hart_map[id] = hart_id;
    if (id < riscv.cpu_contexts.len) riscv.cpu_contexts[id] = ctx;
}

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
    node.run_lock = atomic.SpinLock.init();
    node.heap_mem = heap_mem;

    node.context.cpu_core_id = id;
    node.context.hardware_hart_id = hart_id;
    node.context.last_timer_val = riscv.TIMER_INFINITY;
    node.context.in_m_mode = true;
    node.context.is_parked = false;
    node.context.blocked_lock = atomic.SpinLock.init();
    try node.context.allocator.init(@intFromPtr(heap_mem.ptr), heap_mem.len);

    const flags = table_lock.lock();
    defer table_lock.unlock(flags);

    var cur = core_table[bucket].dynamic_head;
    while (cur) |c| : (cur = c.next) {
        if (c.id == id or c.hart_id == hart_id) return error.AlreadyExists;
    }

    node.next = core_table[bucket].dynamic_head;
    core_table[bucket].dynamic_head = node;
    return &node.context;
}

pub fn this() *riscv.CpuContext {
    return riscv.getCPUContext();
}

pub fn fromId(id: usize) ?*riscv.CpuContext {
    if (id < TABLE_ROWS) return core_table[id].static_ptr;
    if (id >= MAX_SYSTEM_CORES) return null;

    const flags = table_lock.lock();
    defer table_lock.unlock(flags);

    var cur = core_table[id % TABLE_ROWS].dynamic_head;
    while (cur) |node| : (cur = node.next) {
        if (node.id == id) return &node.context;
    }
    return null;
}

pub fn fromHartId(hart_id: usize) ?*riscv.CpuContext {
    for (&core_table) |*row| {
        if (row.static_ptr) |ctx| {
            if (ctx.hardware_hart_id == hart_id) return ctx;
        }
    }
    const flags = table_lock.lock();
    defer table_lock.unlock(flags);

    for (&core_table) |*row| {
        var cur = row.dynamic_head;
        while (cur) |node| : (cur = node.next) {
            if (node.hart_id == hart_id) return &node.context;
        }
    }
    return null;
}

pub fn isHostTp(tp_val: usize) bool {
    if (tp_val == 0 or tp_val % TP_REQUIRED_ALIGNMENT != 0) return false;

    for (&core_table) |*row| {
        if (row.static_ptr) |ctx| {
            if (@intFromPtr(ctx) == tp_val) return true;
        }
    }
    const flags = table_lock.lock();
    defer table_lock.unlock(flags);

    for (&core_table) |*row| {
        var cur = row.dynamic_head;
        while (cur) |node| : (cur = node.next) {
            if (@intFromPtr(&node.context) == tp_val) return true;
        }
    }
    return false;
}

pub fn countOnline() usize {
    var count: usize = 0;
    for (&core_table) |*row| {
        if (row.static_ptr != null) count += 1;
    }
    const flags = table_lock.lock();
    defer table_lock.unlock(flags);

    for (&core_table) |*row| {
        var cur = row.dynamic_head;
        while (cur) |node| : (cur = node.next) count += 1;
    }
    return count;
}

pub fn getTotalFreeHeapBytes() usize {
    var total: usize = 0;
    for (&core_table) |*row| {
        if (row.static_ptr) |ctx| {
            const af = ctx.allocator.lock.lock();
            defer ctx.allocator.lock.unlock(af);
            total += ctx.allocator.free_size;
        }
    }
    const flags = table_lock.lock();
    defer table_lock.unlock(flags);

    for (&core_table) |*row| {
        var cur = row.dynamic_head;
        while (cur) |node| : (cur = node.next) {
            const af = node.context.allocator.lock.lock();
            defer node.context.allocator.lock.unlock(af);
            total += node.context.allocator.free_size;
        }
    }
    return total;
}

pub extern fn hw_run_vcore(
    context: *riscv.ThreadContext,
    machine: *const riscv.MachineState,
    guest_state: *const riscv.GuestState,
) noreturn;

pub fn sendIpiToCpu(cpu_id: usize) void {
    if (builtin.is_test) return;
    if (fromId(cpu_id)) |ctx| {
        const hw_hart = ctx.hardware_hart_id;
        if (hw_hart != this().hardware_hart_id) {
            if (riscv.CLINT.msip(hw_hart)) |ptr| {
                ptr.* = 1;
                return;
            }
        } else return;
    }
    broadcastIpi();
}

pub fn broadcastIpi() void {
    if (builtin.is_test) return;
    const my_hart = this().hardware_hart_id;

    for (&core_table) |*row| {
        if (row.static_ptr) |ctx| {
            if (ctx.hardware_hart_id != my_hart) {
                if (riscv.CLINT.msip(ctx.hardware_hart_id)) |ptr| ptr.* = 1;
            }
        }
    }

    const flags = table_lock.lock();
    defer table_lock.unlock(flags);

    for (&core_table) |*row| {
        var cur = row.dynamic_head;
        while (cur) |node| : (cur = node.next) {
            if (node.hart_id != my_hart) {
                if (riscv.CLINT.msip(node.hart_id)) |ptr| ptr.* = 1;
            }
        }
    }
}

pub fn parkOtherCores() void {
    host_stopping.store(true, .release);
    broadcastIpi();
    if (countOnline() <= 1) return;

    const my_ctx = this();
    const max_spins: usize = if (builtin.is_test) 1_000 else 100_000_000;
    var spins: usize = 0;
    while (spins < max_spins) : (spins += 1) {
        var all_parked = true;

        for (&core_table) |*row| {
            if (row.static_ptr) |ctx| {
                if (ctx != my_ctx and
                    !@atomicLoad(bool, &ctx.is_parked, .acquire))
                {
                    all_parked = false;
                    break;
                }
            }
        }

        if (all_parked) {
            const flags = table_lock.lock();
            for (&core_table) |*row| {
                var cur = row.dynamic_head;
                while (cur) |node| : (cur = node.next) {
                    if (&node.context != my_ctx and
                        !@atomicLoad(bool, &node.context.is_parked, .acquire))
                    {
                        all_parked = false;
                        break;
                    }
                }
                if (!all_parked) break;
            }
            table_lock.unlock(flags);
        }

        if (all_parked) return;
        if (spins % 10_000 == 0) broadcastIpi();
        riscv.pause();
    }
}

pub fn contextSwitch(to_vcore: *vcore.VirtualCore) void {
    const cpu = this();
    if (cpu.active_vcore) |active| {
        if (@intFromPtr(active) == @intFromPtr(to_vcore) and
            to_vcore.running_on_cpu == cpu.cpu_core_id)
        {
            return;
        }
    }
    if ((@intFromPtr(to_vcore) & (@alignOf(vcore.VirtualCore) - 1)) != 0) {
        @import("debug.zig").printf(
            "!!! contextSwitch given misaligned to_vcore 0x{x}\n",
            .{@intFromPtr(to_vcore)},
        );
    }
    cpu.active_vcore = to_vcore;
    to_vcore.running_on_cpu = cpu.cpu_core_id;
    to_vcore.state = .running;
    to_vcore.last_dispatched_time =
        if (builtin.is_test) 0 else riscv.readTime();

    const pmp = @import("../hardware/native/cpu/riscv64/pmp.zig");
    pmp.PMPConfig.clearAllPmp();
    pmp.PMPConfig.writePmpAddr(0, std.math.maxInt(usize));
    pmp.PMPConfig.writePmpCfg(0, pmp.PMPAccess.napot | pmp.PMPAccess.rwx);

    to_vcore.guest.space.apply(to_vcore.guest.vmid);
    if (to_vcore.exec_path == .emulated and
        !to_vcore.exec_path.emulated.emu_running)
    {
        to_vcore.context[@backingInt(riscv.Register.tp)] = @intFromPtr(cpu);
        to_vcore.context[@backingInt(riscv.Register.a0)] =
            @intFromPtr(to_vcore);
    }
}

pub fn deinitDynamicCores() void {
    const flags = table_lock.lock();
    defer table_lock.unlock(flags);
    if (global_allocator) |allocator| {
        for (&core_table) |*row| {
            var current = row.dynamic_head;
            while (current) |node| {
                const next = node.next;
                if (node.heap_mem.len > 0) allocator.free(node.heap_mem);
                allocator.destroy(node);
                current = next;
            }
            row.dynamic_head = null;
        }
    }
}

pub fn resetForTest() void {
    deinitDynamicCores();
    core_table = initCoreTable();
    next_cpu_id.store(0, .seq_cst);
    dynamic_heap_ready.store(false, .seq_cst);
    host_stopping.store(false, .seq_cst);
    global_allocator = null;
}

fn initStaticTestCore(id: usize, hart_id: usize) void {
    const ptr: [*]u8 = @ptrCast(&static_contexts[id]);
    @memset(ptr[0..@sizeOf(riscv.CpuContext)], 0);
    registerStaticCore(id, hart_id, &static_contexts[id]);
}

test "physical CPU: claimNextCpuId and static cores 0..31 via Column 1" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    resetForTest();
    defer resetForTest();

    try testing.expectEqual(@as(usize, 0), claimNextCpuId());
    try testing.expectEqual(@as(usize, 1), claimNextCpuId());
    for (0..TABLE_ROWS) |id| initStaticTestCore(id, id * 10);

    const core3 = fromId(3);
    try testing.expectEqual(@as(usize, 3), core3.?.cpu_core_id);
    try testing.expectEqual(@as(usize, 30), core3.?.hardware_hart_id);
    try testing.expectEqual(&static_contexts[3], core3.?);

    for (0..TABLE_ROWS) |id| {
        const ctx = fromId(id);
        try testing.expectEqual(id, ctx.?.cpu_core_id);
        try testing.expectEqual(id * 10, ctx.?.hardware_hart_id);
    }
    try testing.expect(fromId(32) == null);
    try testing.expectEqual(@as(usize, 32), countOnline());
}

test "physical CPU: dynamic core 38 allocates into bucket 6 and collisions" {
    const testing = std.testing;
    resetForTest();
    defer resetForTest();

    initStaticTestCore(3, 300);
    try testing.expect(!isDynamicHeapReady());
    try testing.expectError(error.HeapNotReady, registerDynamicCore(38, 380));

    setDynamicHeapReady(testing.allocator);
    try testing.expect(isDynamicHeapReady());

    const core38 = try registerDynamicCore(38, 380);
    try testing.expectEqual(@as(usize, 38), core38.cpu_core_id);
    try testing.expectEqual(@as(usize, 380), core38.hardware_hart_id);
    try testing.expectEqual(@as(usize, 38), core_table[6].dynamic_head.?.id);

    const core70 = try registerDynamicCore(70, 700);
    try testing.expectEqual(core38, fromId(38).?);
    try testing.expectEqual(core70, fromId(70).?);
    try testing.expectEqual(core38, fromHartId(380).?);
    try testing.expectEqual(core70, fromHartId(700).?);
    try testing.expectEqual(@as(usize, 3), fromId(3).?.cpu_core_id);
    try testing.expect(fromHartId(300) != null and fromHartId(999) == null);
    try testing.expectEqual(@as(usize, 3), countOnline());
}

test "physical CPU: scaling up to 4096 cores dynamically" {
    const testing = std.testing;
    resetForTest();
    defer resetForTest();

    setDynamicHeapReady(testing.allocator);
    for (0..TABLE_ROWS) |id| initStaticTestCore(id, id + 1000);

    const target_cores: usize = 512;
    for (TABLE_ROWS..target_cores) |id| {
        _ = try registerDynamicCore(id, id + 1000);
    }
    try testing.expectEqual(target_cores, countOnline());

    for (0..target_cores) |check_id| {
        const ctx = fromId(check_id);
        try testing.expectEqual(check_id, ctx.?.cpu_core_id);
        try testing.expectEqual(ctx.?, fromHartId(check_id + 1000).?);
    }
    try testing.expectError(
        error.ExceedsMaxCores,
        registerDynamicCore(MAX_SYSTEM_CORES, 9999),
    );
}

test "physical CPU: isHostTp, sendIpiToCpu, duplicates, and parkOtherCores" {
    const testing = std.testing;
    resetForTest();
    defer resetForTest();

    setDynamicHeapReady(testing.allocator);
    registerStaticCore(0, 100, riscv.getCPUContext());
    initStaticTestCore(1, 10);
    const dyn_ctx = try registerDynamicCore(40, 400);

    try testing.expect(isHostTp(@intFromPtr(riscv.getCPUContext())));
    try testing.expect(isHostTp(@intFromPtr(dyn_ctx)));
    try testing.expect(!isHostTp(0) and !isHostTp(0x1234));
    try testing.expect(!isHostTp(@intFromPtr(&static_contexts[1]) + 1));

    sendIpiToCpu(0);
    sendIpiToCpu(40);
    sendIpiToCpu(999);

    const err_dup = error.AlreadyExists;
    try testing.expectError(err_dup, registerDynamicCore(40, 401));
    try testing.expectError(err_dup, registerDynamicCore(41, 400));

    static_contexts[1].is_parked = true;
    dyn_ctx.is_parked = true;
    parkOtherCores();
    try testing.expect(host_stopping.load(.acquire));
}
