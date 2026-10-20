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
pub const state_mod = @import("vcore/state.zig");

pub const VirtualCoreID = usize;
pub var time_offset: u64 = 0;

pub const Priority = enum { high, normal };
pub const VirtualCoreState = enum {
    running,
    ready,
    stopped,
    blocked,

    pub const uninitialized = VirtualCoreState.stopped;
};
pub const SchedulerList = dsa.LinkedList(*VirtualCore);
pub const VirtualCoreType = enum { native, emulated };

pub const WEIGHT_HIGH: u32 = 2048;
pub const WEIGHT_NORMAL: u32 = 1024;

pub const IOAPIC_NUM_REDIR_ENTRIES = state_mod.IOAPIC_NUM_REDIR_ENTRIES;
pub const IOAPIC_REDIR_MASKED = state_mod.IOAPIC_REDIR_MASKED;
pub const LAPIC_PAGE_SIZE = state_mod.LAPIC_PAGE_SIZE;
pub const LAPIC_LVT_MASKED = state_mod.LAPIC_LVT_MASKED;
pub const LAPIC_REG_ID = state_mod.LAPIC_REG_ID;
pub const LAPIC_REG_VERSION = state_mod.LAPIC_REG_VERSION;
pub const LAPIC_REG_SPURIOUS = state_mod.LAPIC_REG_SPURIOUS;
pub const LAPIC_VERSION_INTEGRATED = state_mod.LAPIC_VERSION_INTEGRATED;
pub const LAPIC_SPURIOUS_ALL_MASKED = state_mod.LAPIC_SPURIOUS_ALL_MASKED;
pub const LAPIC_ID_SHIFT = state_mod.LAPIC_ID_SHIFT;
pub const EMULATOR_STACK_SIZE_BYTES = state_mod.EMULATOR_STACK_SIZE_BYTES;
pub const EMULATOR_STACK_PAGE_ORDER = state_mod.EMULATOR_STACK_PAGE_ORDER;
pub const EMULATOR_TLS_SIZE_BYTES = state_mod.EMULATOR_TLS_SIZE_BYTES;
pub const EMULATOR_TLS_PAGE_ORDER = state_mod.EMULATOR_TLS_PAGE_ORDER;
pub const EMULATOR_TLS_TP_OFFSET = state_mod.EMULATOR_TLS_TP_OFFSET;
pub const PIT_BASE_FREQUENCY_HZ = state_mod.PIT_BASE_FREQUENCY_HZ;
pub const PIT_DEFAULT_LATCH_100HZ = state_mod.PIT_DEFAULT_LATCH_100HZ;
pub const PIT_TIMER_ACCESS_LSB_MSB = state_mod.PIT_TIMER_ACCESS_LSB_MSB;
pub const PIT_TIMER_MODE_SQUARE_WAVE = state_mod.PIT_TIMER_MODE_SQUARE_WAVE;
pub const max_sub_vcores = state_mod.max_sub_vcores;
pub const emulation_timeslice_instructions =
    state_mod.emulation_timeslice_instructions;
pub const MAX_DEINIT_SPINS = state_mod.MAX_DEINIT_SPINS;
pub const LapicTimerState = state_mod.LapicTimerState;
pub const SubVcoreState = state_mod.SubVcoreState;

pub const HEDELEG_GUEST_DELEGATE: usize = riscv.HEDELEG_DELEGATED;
pub const HIDELEG_VS_INTERRUPTS: usize = riscv.HIDELEG_DELEGATED;

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
        },
        emulated: struct {
            vcpu: ?*native_emu.VCpu = null,
            engine: ?*native_emu.Engine = null,
            slot_idx: ?usize = null,
            target_arch: guest.TargetArch,
            entry: usize,
            dtb: usize,
            stack: []u8 = &.{},
            stack_phys: usize = 0,
            tls_phys: usize = 0,
            emu_running: bool = false,
            tls_pointer: usize = 0,
            virtual_smode_time: u64 = 0,
            pit_calibration_active: bool = false,
            pit_calibration_ticks: u32 = 0,
            delay_bypass_count: u32 = 0,
            last_mapped_user_page: u64 = 0,
            exit_count: u64 = 0,
            text_poke_happened: bool = false,
            trace_instructions_count: u32 = 0,
            trace_hook: ?*anyopaque = null,
            sub_vcores: [max_sub_vcores]SubVcoreState =
                std.mem.zeroes([max_sub_vcores]SubVcoreState),
            sub_vcore_count: usize = 1,
            active_sub_vcore: usize = 0,
            last_run_sub_vcore: ?usize = null,
            preempt_pending: bool = false,
            exception_cause: u32 = 0,
            hsm_started: bool = false,
            lapic_mem: [LAPIC_PAGE_SIZE]u8 = @splat(0),
            sc_hook_addr: u64 = 0,
            idle_hook_addr: u64 = 0,
            icr_dest: u32 = 0,
            ioapic_reg_sel: u8 = 0,
            ioapic_written: bool = false,
            ioapic_redtbl: [IOAPIC_NUM_REDIR_ENTRIES]u64 =
                state_mod.initIoapicRedtbl(),
        },
    } = undefined,

    timer_scheduled: bool = false,
    timer_target: u64 = 0,
    virtual_time: u64 = 0,
    timer_skip_blocks: u32 = 0,
    running_on_cpu: ?usize = null,
    wfi_blocked: bool = false,
    pending_ipi: bool = false,
    is_queued: bool = false,
    blocked_on_cpu: ?usize = null,

    priority: Priority,
    vruntime: u64 = 0,
    weight: u32,
    last_queued_time: u64 = 0,
    last_dispatched_time: u64 = 0,

    scheduler_node: SchedulerList.Node = undefined,
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
            vc.configureNativeState(entry, dtb);
            vc.exec_path = .{ .native = .{
                .siselect = 0,
                .required_extensions = riscv.IsaExtension.i,
            } };
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

        if (parent.target_arch == .x86_64) {
            state_mod.initX86PeripheralState(&vc, parent, id);
        }

        vc.scheduler_node.contents = undefined;
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

    pub fn reset(self: *VirtualCore, entry: usize, dtb: usize) void {
        self.state = .stopped;
        self.wfi_blocked = false;
        self.is_queued = false;
        self.running_on_cpu = null;
        self.context = @splat(0);

        if (self.exec_path == .native) {
            self.configureNativeState(entry, dtb);
        } else {
            const e = &self.exec_path.emulated;
            e.entry = entry;
            e.dtb = dtb;
            if (e.engine) |eng| eng.tlb.flush();
            e.sub_vcores = std.mem.zeroes([max_sub_vcores]SubVcoreState);
            e.sub_vcore_count = 1;
            e.active_sub_vcore = 0;
            e.last_run_sub_vcore = null;
            e.preempt_pending = false;
            e.hsm_started = false;
            self.configureEmulatedCpuContext();
        }
    }

    pub fn deinit(self: *VirtualCore) void {
        _ = @atomicRmw(bool, &self.wfi_blocked, .Xchg, false, .acq_rel);

        if (!builtin.is_test) {
            var spins: usize = 0;
            while ((@as(*volatile ?usize, &self.blocked_on_cpu)).*) |home_cpu| {
                if (spins >= MAX_DEINIT_SPINS) break;
                spins += 1;
                pcore.sendIpiToCpu(home_cpu);
                std.atomic.spinLoopHint();
            }
            spins = 0;
            while ((@as(*volatile ?usize, &self.running_on_cpu)).* != null and
                spins < MAX_DEINIT_SPINS) : (spins += 1)
            {
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
                if (e.stack_phys != 0) {
                    physmem.freePage(e.stack_phys);
                    e.stack_phys = 0;
                }
                if (e.tls_phys != 0) {
                    physmem.freePage(e.tls_phys);
                    e.tls_phys = 0;
                }
            },
            else => {},
        }
    }

    pub fn runEmulated(self: *VirtualCore) void {
        _ = glue.run(self);
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
            .acq_rel,
            .monotonic,
        );
        if (old == null) {
            if (self.blocked_on_cpu) |home_cpu| {
                if (pcore.fromId(home_cpu)) |home_pcpu| {
                    const prev = home_pcpu.blocked_lock.lock();
                    if (self.blocked_on_cpu == home_cpu) {
                        home_pcpu.blocked_queue.remove(&self.blocked_node);
                        self.blocked_on_cpu = null;
                    }
                    home_pcpu.blocked_lock.unlock(prev);
                } else {
                    self.blocked_on_cpu = null;
                }
            }
            self.state = .ready;
            if (self.exec_path == .emulated) {
                const host_time = riscv.readTime();
                if (host_time > self.virtual_time) {
                    self.virtual_time = host_time;
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
    _ = state_mod;
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
