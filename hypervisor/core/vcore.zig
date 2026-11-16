// Virtual CPU core management.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const riscv = @import("../hardware/native/cpu/riscv64/mod.zig");
const dsa = @import("dsa.zig");
const guest = @import("guest.zig");
const pcore = @import("pcore.zig");
const physmem = @import("physmem.zig");
const native_emu = @import("emulation");
const glue = @import("emulation.zig");

pub const VirtualCoreID = usize;
pub const NO_CPU: usize = std.math.maxInt(usize);
pub const MAX_DEINIT_SPINS: usize = 100_000;
pub var time_offset: u64 = 0;

pub const Priority = enum { high, normal };
pub const VirtualCoreState = enum {
    running,
    ready,
    stopped,
    blocked,

    pub const uninitialized = VirtualCoreState.stopped;
};
pub const VirtualCoreType = enum { native, emulated };

pub const WEIGHT_HIGH: u32 = 2048;
pub const WEIGHT_NORMAL: u32 = 1024;

pub const HEDELEG_GUEST_DELEGATE: usize = riscv.HEDELEG_DELEGATED;
pub const HIDELEG_VS_INTERRUPTS: usize = riscv.HIDELEG_DELEGATED;

pub fn compareSchedulerVcores(a: *VirtualCore, b: *VirtualCore) i8 {
    if (a == b) return 0;
    const va = @atomicLoad(u64, &a.vruntime, .monotonic);
    const vb = @atomicLoad(u64, &b.vruntime, .monotonic);
    if (va != vb) {
        return if (va < vb) -1 else 1;
    }
    if (a.guest_id != b.guest_id) {
        return if (a.guest_id < b.guest_id) -1 else 1;
    }
    if (a.id != b.id) {
        return if (a.id < b.id) -1 else 1;
    }
    return if (@intFromPtr(a) < @intFromPtr(b)) -1 else 1;
}

pub const SchedulerTree = dsa.RedBlackTree(
    *VirtualCore,
    compareSchedulerVcores,
);

// Represents a virtual CPU core's context and state.
pub const VirtualCore = struct {
    id: VirtualCoreID,
    guest: *guest.Guest,
    guest_id: usize,
    state: VirtualCoreState = .stopped,
    context: riscv.ThreadContext = @splat(0),
    machine: riscv.MachineState = undefined,
    guest_state: riscv.GuestState = undefined,

    exec_path: union(VirtualCoreType) {
        native: struct {
            required_extensions: usize,
            siselect: usize,
            fp_state: riscv.FpState = .{},
            vec_state: riscv.VectorState = .{},
        },
        emulated: struct {
            vcpu: ?*native_emu.VCpu = null,
            engine: ?*native_emu.Engine = null,
            slot_idx: ?usize = null,
            target_arch: guest.TargetArch,
            entry: usize,
            dtb: usize,
            exit_count: u64 = 0,
            preempt_pending: bool = false,
        },
    } = undefined,

    timer_scheduled: bool = false,
    timer_target: u64 = 0,
    virtual_time: u64 = 0,
    running_cpu_id: usize = NO_CPU,
    wfi_blocked: bool = false,
    pending_ipi: bool = false,
    is_queued: bool = false,
    in_run_tree: bool = false,
    queued_cpu_id: usize = NO_CPU,
    blocked_cpu_id: usize = NO_CPU,

    priority: Priority,
    vruntime: u64 = 0,
    weight: u32,
    last_queued_time: u64 = 0,
    last_dispatched_time: u64 = 0,
    active_ticks: u64 = 0,

    scheduler_node: SchedulerTree.Node = undefined,
    blocked_node: dsa.LinkedList(*anyopaque).Node = undefined,
    lookup_next: ?*VirtualCore = null,

    fn readHostGp() usize {
        var hypervisor_gp: usize = 0;
        if (comptime !builtin.is_test) {
            asm volatile ("mv %[g], gp"
                : [g] "=r" (hypervisor_gp),
            );
        }
        return hypervisor_gp;
    }

    pub fn configureNativeState(
        self: *VirtualCore,
        entry: usize,
        arg1: usize,
    ) void {
        const hgatp_val = if (self.guest.space.mode == .h_paging)
            (if (self.guest.space.paging) |*p|
                p.hgatp(self.guest.vmid)
            else
                0)
        else
            0;
        self.machine = .{
            .mepc = entry,
            .mstatus = riscv.MSTATUS.MPP_SUPERVISOR | riscv.MSTATUS.MPIE |
                riscv.MSTATUS.MPV | riscv.MSTATUS.FS_DIRTY,
            .hstatus = riscv.HSTATUS.SPV | riscv.HSTATUS.SPVP,
            .hgatp = hgatp_val,
            .hedeleg = HEDELEG_GUEST_DELEGATE,
            .hideleg = HIDELEG_VS_INTERRUPTS,
            .hvip = 0,
        };
        self.guest_state = std.mem.zeroes(riscv.GuestState);
        self.guest_state.vsstatus =
            riscv.SSTATUS.SPIE | riscv.MSTATUS.FS_DIRTY;
        self.guest_state.vstimecmp = riscv.TIMER_INFINITY;
        self.guest_state.vsenvcfg =
            riscv.ENVCFG.STCE | riscv.ENVCFG.CACHE_OPS_ALL;
        self.context[@backingInt(riscv.Register.a0)] = self.id;
        self.context[@backingInt(riscv.Register.a1)] = arg1;
        if (self.exec_path == .native) {
            self.exec_path.native.fp_state = .{};
            self.exec_path.native.vec_state = .{};
        }
    }

    fn configureEmulatedCpuContext(self: *VirtualCore) void {
        self.machine = std.mem.zeroes(riscv.MachineState);
        self.machine.mepc = @intFromPtr(&glue.emulatedRunnerSMode);
        self.machine.mstatus = riscv.MSTATUS.MPP_SUPERVISOR |
            riscv.MSTATUS.MPIE |
            riscv.MSTATUS.FS_DIRTY;
        self.guest_state = std.mem.zeroes(riscv.GuestState);
        self.guest_state.vstimecmp = riscv.TIMER_INFINITY;
        self.context[@backingInt(riscv.Register.gp)] = readHostGp();
        self.context[@backingInt(riscv.Register.a0)] = 0;
    }

    pub fn initChecked(
        id: VirtualCoreID,
        parent: *guest.Guest,
        entry: usize,
        dtb: usize,
        priority: Priority,
    ) !VirtualCore {
        var vc = VirtualCore{
            .id = id,
            .guest = parent,
            .guest_id = parent.id,
            .priority = priority,
            .weight = if (priority == .high) WEIGHT_HIGH else WEIGHT_NORMAL,
        };

        if (parent.target_arch == .riscv64) {
            vc.exec_path = .{ .native = .{
                .siselect = 0,
                .required_extensions = riscv.IsaExtension.i,
            } };
            vc.configureNativeState(entry, dtb);
        } else {
            vc.configureEmulatedCpuContext();
            vc.exec_path = .{ .emulated = .{
                .vcpu = null,
                .engine = null,
                .target_arch = parent.target_arch,
                .entry = entry,
                .dtb = dtb,
            } };
        }

        vc.scheduler_node = .{ .contents = undefined };
        return vc;
    }

    pub fn init(
        id: VirtualCoreID,
        parent: *guest.Guest,
        entry: usize,
        dtb: usize,
        priority: Priority,
    ) VirtualCore {
        return initChecked(id, parent, entry, dtb, priority) catch
            @panic("Failed to initialize VirtualCore");
    }

    pub inline fn getState(self: *const VirtualCore) VirtualCoreState {
        return @atomicLoad(VirtualCoreState, &self.state, .seq_cst);
    }

    pub inline fn setState(self: *VirtualCore, st: VirtualCoreState) void {
        @atomicStore(VirtualCoreState, &self.state, st, .seq_cst);
    }

    pub inline fn getRunningCpu(self: *const VirtualCore) ?usize {
        const cpu = @atomicLoad(usize, &self.running_cpu_id, .seq_cst);
        return if (cpu == NO_CPU) null else cpu;
    }

    pub inline fn setRunningCpu(self: *VirtualCore, cpu: ?usize) void {
        const val: usize = cpu orelse NO_CPU;
        @atomicStore(usize, &self.running_cpu_id, val, .seq_cst);
    }

    pub inline fn getBlockedCpu(self: *const VirtualCore) ?usize {
        const cpu = @atomicLoad(usize, &self.blocked_cpu_id, .acquire);
        return if (cpu == NO_CPU) null else cpu;
    }

    pub inline fn setBlockedCpu(self: *VirtualCore, cpu: ?usize) void {
        const val: usize = cpu orelse NO_CPU;
        @atomicStore(usize, &self.blocked_cpu_id, val, .release);
    }

    pub inline fn isInRunTree(self: *const VirtualCore) bool {
        return @atomicLoad(bool, &self.in_run_tree, .acquire);
    }

    pub inline fn setInRunTree(self: *VirtualCore, in_tree: bool) void {
        @atomicStore(bool, &self.in_run_tree, in_tree, .release);
    }

    pub fn reset(self: *VirtualCore, entry: usize, dtb: usize) void {
        @atomicStore(VirtualCoreState, &self.state, .stopped, .seq_cst);
        @atomicStore(bool, &self.wfi_blocked, false, .seq_cst);
        @atomicStore(bool, &self.is_queued, false, .release);
        self.setInRunTree(false);
        @atomicStore(usize, &self.queued_cpu_id, NO_CPU, .release);
        self.setRunningCpu(null);
        self.setBlockedCpu(null);
        @atomicStore(u64, &self.active_ticks, 0, .monotonic);
        @atomicStore(u64, &self.last_dispatched_time, 0, .monotonic);
        self.context = @splat(0);

        if (self.exec_path == .native) {
            self.configureNativeState(entry, dtb);
        } else {
            const e = &self.exec_path.emulated;
            e.entry = entry;
            e.dtb = dtb;
            if (e.engine) |eng| eng.tlb.flush();
            e.preempt_pending = false;
            self.configureEmulatedCpuContext();
        }
    }

    pub fn deinit(self: *VirtualCore) void {
        _ = @atomicRmw(bool, &self.wfi_blocked, .Xchg, false, .seq_cst);

        if (!builtin.is_test) {
            var spins: usize = 0;
            while (self.getBlockedCpu()) |home_cpu| {
                if (spins >= MAX_DEINIT_SPINS) break;
                spins += 1;
                pcore.sendIpiToCpu(home_cpu);
                std.atomic.spinLoopHint();
            }
            const my_cpu = riscv.getCPUContext().cpu_core_id;
            spins = 0;
            while (self.getRunningCpu()) |run_cpu| {
                if (run_cpu == my_cpu or spins >= MAX_DEINIT_SPINS) break;
                spins += 1;
                std.atomic.spinLoopHint();
            }
            spins = 0;
            while (@atomicLoad(bool, &self.is_queued, .acquire) and
                spins < MAX_DEINIT_SPINS) : (spins += 1)
            {
                std.atomic.spinLoopHint();
            }
        }

        switch (self.exec_path) {
            .emulated => |*e| {
                glue.deinit(self);
                e.vcpu = null;
                e.engine = null;
                e.slot_idx = null;
            },
            else => {},
        }
    }

    pub fn requiredExtensions(self: *const VirtualCore) usize {
        return if (self.exec_path == .native)
            self.exec_path.native.required_extensions
        else
            0;
    }
    pub fn getNativeSiselect(self: *VirtualCore) *usize {
        return &self.exec_path.native.siselect;
    }
    pub inline fn getNativeContext(self: *VirtualCore) *riscv.ThreadContext {
        return &self.context;
    }
    pub inline fn getNativeMachine(self: *VirtualCore) *riscv.MachineState {
        return &self.machine;
    }
    pub inline fn getNativeGuestState(self: *VirtualCore) *riscv.GuestState {
        return &self.guest_state;
    }
    pub fn getGuest(self: *VirtualCore) *guest.Guest {
        return self.guest;
    }
    pub fn tryWake(self: *VirtualCore) bool {
        const old = @cmpxchgStrong(
            bool,
            &self.wfi_blocked,
            true,
            false,
            .seq_cst,
            .seq_cst,
        );
        if (old == null) {
            if (self.getBlockedCpu()) |home_cpu| {
                if (pcore.fromId(home_cpu)) |home_pcpu| {
                    const prev = home_pcpu.blocked_lock.lock();
                    if (self.getBlockedCpu() == home_cpu) {
                        home_pcpu.blocked_queue.remove(&self.blocked_node);
                        self.setBlockedCpu(null);
                    }
                    home_pcpu.blocked_lock.unlock(prev);
                } else {
                    self.setBlockedCpu(null);
                }
            }
            if (@atomicLoad(guest.GuestState, &self.guest.state, .acquire) !=
                .valid)
            {
                @atomicStore(VirtualCoreState, &self.state, .stopped, .seq_cst);
                return false;
            }
            @atomicStore(VirtualCoreState, &self.state, .ready, .seq_cst);
            if (self.exec_path == .emulated) {
                const host_time = riscv.readTime();
                const cur_vt = @atomicLoad(u64, &self.virtual_time, .monotonic);
                if (host_time > cur_vt) {
                    @atomicStore(
                        u64,
                        &self.virtual_time,
                        host_time,
                        .monotonic,
                    );
                }
            }
            return true;
        }
        return false;
    }
    pub fn updateSchedulerWeight(self: *VirtualCore) void {
        self.scheduler_node.contents = self;
    }
};

test "virtual core initialization and emulated state cleanup" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    const alloc = testing.allocator;
    const id: VirtualCoreID = 42;
    var phys_test = try physmem.initForTest(alloc, 2048);
    defer phys_test.deinit();
    const parent =
        try guest.createGuest(alloc, false, false, null, 0, 0, 0, .riscv64);
    defer parent.deinit();
    const vc = try VirtualCore.initChecked(id, parent, 0x8000, 0x9000, .normal);
    try testing.expectEqual(id, vc.id);
    try testing.expectEqual(parent.id, vc.guest_id);
    try testing.expectEqual(@as(usize, 0x8000), vc.machine.mepc);
    const a1_idx = @backingInt(riscv.Register.a1);
    const a0_idx = @backingInt(riscv.Register.a0);
    try testing.expectEqual(@as(usize, 0x9000), vc.context[a1_idx]);
    try testing.expectEqual(id, vc.context[a0_idx]);
    try testing.expectEqual(@as(u32, 1024), vc.weight);
    try testing.expectEqual(@as(u64, 0), vc.vruntime);
    const base: usize = 0x80000000;
    const emu_guest = try guest.createGuest(
        alloc,
        false,
        false,
        null,
        base,
        base,
        0x1000,
        .riscv32,
    );
    defer emu_guest.deinit();
    const free_before = physmem.getFreeRamBytes();
    const pri = Priority.normal;
    var emu_vc = try VirtualCore.initChecked(0, emu_guest, 0x8000, 0x9000, pri);
    try testing.expectEqual(free_before, physmem.getFreeRamBytes());
    emu_vc.deinit();
    try testing.expectEqual(free_before, physmem.getFreeRamBytes());
}
