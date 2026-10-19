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
const interface = @import("interface");

pub const VirtualCoreID = usize;
pub var time_offset: u64 = 0;

pub const Priority = enum { high, normal };
pub const VirtualCoreState = enum { running, ready, stopped, blocked };
pub const SchedulerList = dsa.LinkedList(*VirtualCore);
pub const VirtualCoreType = enum { native, emulated };

pub const WEIGHT_HIGH: u32 = 2048;
pub const WEIGHT_NORMAL: u32 = 1024;

pub const IOAPIC_NUM_REDIR_ENTRIES: usize = 24;
pub const IOAPIC_REDIR_MASKED: u64 = 0x00010000;

pub const LAPIC_PAGE_SIZE: usize = 4096;
pub const LAPIC_LVT_MASKED: u32 = 0x00010000;
pub const LAPIC_REG_ID: usize = 0x20;
pub const LAPIC_REG_VERSION: usize = 0x30;
pub const LAPIC_REG_SPURIOUS: usize = 0xf0;
pub const LAPIC_VERSION_INTEGRATED: u32 = 0x00050014;
pub const LAPIC_SPURIOUS_ALL_MASKED: u32 = 0x000000ff;
pub const LAPIC_ID_SHIFT: u5 = 24;

// 2 MiB S-mode stack (order 9 = 512 pages) and 4 KiB TLS block (order 0).
pub const EMULATOR_STACK_SIZE_BYTES: usize = 2 * 1024 * 1024;
pub const EMULATOR_STACK_PAGE_ORDER: u8 = 9;
pub const EMULATOR_TLS_SIZE_BYTES: usize = 4096;
pub const EMULATOR_TLS_PAGE_ORDER: u8 = 0;
pub const EMULATOR_TLS_TP_OFFSET: usize = 2048;

pub const PIT_BASE_FREQUENCY_HZ: u64 = 1_193_182;
pub const PIT_DEFAULT_LATCH_100HZ: u64 = 11932;
pub const PIT_TIMER_ACCESS_LSB_MSB: u8 = 3;
pub const PIT_TIMER_MODE_SQUARE_WAVE: u8 = 3;

pub const HEDELEG_GUEST_DELEGATE: usize = riscv.HEDELEG_DELEGATED;
pub const HIDELEG_VS_INTERRUPTS: usize = riscv.HIDELEG_DELEGATED;

fn initIoapicRedtbl() [IOAPIC_NUM_REDIR_ENTRIES]u64 {
    var tbl: [IOAPIC_NUM_REDIR_ENTRIES]u64 = undefined;
    for (&tbl) |*entry| entry.* = IOAPIC_REDIR_MASKED;
    return tbl;
}

pub const max_sub_vcores: usize = 8;
pub const emulation_timeslice_instructions: u32 = 2_000_000;

pub const LapicTimerState = struct {
    lvt_timer: u32 = LAPIC_LVT_MASKED,
    init_count: u32 = 0,
    divide_cfg: u32 = 0,
    start_time: u64 = 0,
    period_ticks: u64 = 0,
};

pub const SubVcoreState = struct {
    id: usize = 0,
    state: VirtualCoreState = .stopped,
    context: ?*anyopaque = null,
    timer_scheduled: bool = false,
    timer_target: u64 = 0,
    wfi_blocked: bool = false,
    pending_ipi: bool = false,
    pending_ipi_vector: u8 = 0,
    start_pc: u64 = 0,
    start_a0: u64 = 0,
    start_a1: u64 = 0,
    last_pc: u64 = 0,
    lapic_timer: LapicTimerState = .{},
    icr_dest: u32 = 0,
    last_page_fault_addr: u64 = 0,
    freeze_count: u32 = 0,
    fs_base: u64 = 0,
    gs_base: u64 = 0,
    kernel_gs_base: u64 = 0,
};

// Represents a virtual CPU core's context and state.
pub const VirtualCore = struct {
    id: VirtualCoreID,
    guest: *guest.Guest,
    guest_id: usize,
    state: VirtualCoreState = .stopped,
    context: riscv.ThreadContext = std.mem.zeroes(riscv.ThreadContext),
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
            stack: []u8,
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
            lapic_mem: [LAPIC_PAGE_SIZE]u8 =
                std.mem.zeroes([LAPIC_PAGE_SIZE]u8),
            sc_hook_addr: u64 = 0,
            idle_hook_addr: u64 = 0,
            icr_dest: u32 = 0,
            ioapic_reg_sel: u8 = 0,
            ioapic_written: bool = false,
            ioapic_redtbl: [IOAPIC_NUM_REDIR_ENTRIES]u64 = initIoapicRedtbl(),
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
        self.guest_state.vstimecmp = std.math.maxInt(u64);
        self.guest_state.vsenvcfg =
            riscv.ENVCFG.STCE | riscv.ENVCFG.CACHE_OPS_ALL;
        self.context[@backingInt(riscv.Register.a0)] = self.id;
        self.context[@backingInt(riscv.Register.a1)] = arg1;
    }

    fn configureEmulatedCpuContext(
        self: *VirtualCore,
        stack: []u8,
        tls_phys: usize,
    ) void {
        self.machine = std.mem.zeroes(riscv.MachineState);
        self.machine.mepc = @intFromPtr(&glue.emulatedRunnerSMode);
        self.machine.mstatus = riscv.MSTATUS.MPP_SUPERVISOR |
            riscv.MSTATUS.MPIE |
            riscv.MSTATUS.FS_DIRTY;
        self.guest_state = std.mem.zeroes(riscv.GuestState);
        self.guest_state.vstimecmp = std.math.maxInt(u64);
        self.context[@backingInt(riscv.Register.sp)] =
            @intFromPtr(stack.ptr) + stack.len;
        self.context[@backingInt(riscv.Register.gp)] = readHostGp();
        self.context[@backingInt(riscv.Register.tp)] =
            tls_phys + EMULATOR_TLS_TP_OFFSET;
        self.context[@backingInt(riscv.Register.a0)] = 0;
    }

    pub fn initChecked(
        id: VirtualCoreID,
        parent: *guest.Guest,
        entry: usize,
        dtb: usize,
        priority: Priority,
    ) !VirtualCore {
        var vcore = VirtualCore{
            .id = id,
            .guest = parent,
            .guest_id = parent.id,
            .priority = priority,
            .weight = if (priority == .high) WEIGHT_HIGH else WEIGHT_NORMAL,
        };

        if (parent.target_arch == .riscv64) {
            vcore.configureNativeState(entry, dtb);
            vcore.exec_path = .{ .native = .{
                .siselect = 0,
                .required_extensions = riscv.IsaExtension.i,
            } };
        } else {
            const stack_phys = try physmem.allocPageSelection(
                EMULATOR_STACK_PAGE_ORDER,
            );
            errdefer physmem.freePage(stack_phys);
            const stack = @as(
                [*]align(16) u8,
                @ptrFromInt(stack_phys),
            )[0..EMULATOR_STACK_SIZE_BYTES];
            const tls_phys = try physmem.allocPageSelection(
                EMULATOR_TLS_PAGE_ORDER,
            );
            @memset(
                @as([*]u8, @ptrFromInt(tls_phys))[0..EMULATOR_TLS_SIZE_BYTES],
                0,
            );

            vcore.configureEmulatedCpuContext(stack, tls_phys);
            vcore.exec_path = .{ .emulated = .{
                .vcpu = null,
                .engine = null,
                .target_arch = parent.target_arch,
                .entry = entry,
                .dtb = dtb,
                .stack = stack,
                .stack_phys = stack_phys,
                .tls_phys = tls_phys,
                .tls_pointer = tls_phys + EMULATOR_TLS_TP_OFFSET,
            } };
        }

        if (parent.target_arch == .x86_64) {
            const init_latch: u64 = PIT_DEFAULT_LATCH_100HZ;
            const period_clint: u64 =
                (init_latch * interface.sbi.HOST_TIMER_FREQ_HZ) /
                PIT_BASE_FREQUENCY_HZ;
            parent.pit.channels[0] = .{
                .latch = @intCast(init_latch),
                .access = PIT_TIMER_ACCESS_LSB_MSB,
                .mode = PIT_TIMER_MODE_SQUARE_WAVE,
                .period_ticks = period_clint,
            };
            const em = &vcore.exec_path.emulated;
            em.sub_vcores[0].timer_scheduled = true;
            em.sub_vcores[0].timer_target =
                glue.readSModeTime() + period_clint;

            const apic_id = @as(u32, @intCast(id)) << LAPIC_ID_SHIFT;
            const id_buf = em.lapic_mem[LAPIC_REG_ID..][0..4];
            const ver_buf = em.lapic_mem[LAPIC_REG_VERSION..][0..4];
            const spur_buf = em.lapic_mem[LAPIC_REG_SPURIOUS..][0..4];
            std.mem.writeInt(u32, id_buf, apic_id, .little);
            std.mem.writeInt(u32, ver_buf, LAPIC_VERSION_INTEGRATED, .little);
            std.mem.writeInt(u32, spur_buf, LAPIC_SPURIOUS_ALL_MASKED, .little);
        }

        vcore.scheduler_node.contents = undefined;
        return vcore;
    }

    pub fn init(
        id: VirtualCoreID,
        parent: *guest.Guest,
        entry: usize,
        dtb: usize,
        priority: Priority,
    ) VirtualCore {
        return initChecked(id, parent, entry, dtb, priority) catch
            @panic("Failed to allocate emulator stack/TLS for VirtualCore");
    }

    pub fn reset(self: *VirtualCore, entry: usize, dtb: usize) void {
        self.state = .stopped;
        self.wfi_blocked = false;
        self.is_queued = false;
        self.running_on_cpu = null;
        self.context = std.mem.zeroes(riscv.ThreadContext);

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
            self.configureEmulatedCpuContext(e.stack, e.tls_phys);
        }
    }

    pub fn deinit(self: *VirtualCore) void {
        _ = @atomicRmw(bool, &self.wfi_blocked, .Xchg, false, .acq_rel);

        if (!builtin.is_test) {
            while ((@as(*volatile ?usize, &self.blocked_on_cpu)).*) |home_cpu| {
                pcore.sendIpiToCpu(home_cpu);
                std.atomic.spinLoopHint();
            }
            while ((@as(*volatile ?usize, &self.running_on_cpu)).* != null) {
                std.atomic.spinLoopHint();
            }
            while (@atomicLoad(bool, &self.is_queued, .acquire)) {
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
        glue.run(self);
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
    /// Atomically try to wake this vcore from WFI-blocked state.
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

test "virtual core initialization and emulated stack page reclamation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const id: VirtualCoreID = 42;
    var phys_test = try physmem.initForTest(alloc, 2048);
    defer phys_test.deinit();
    const parent = try guest.createGuest(
        alloc,
        false,
        false,
        null,
        0,
        0,
        0,
        .riscv64,
    );
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
    const emu_guest = try guest.createGuest(
        alloc,
        false,
        false,
        null,
        0x80000000,
        0x80000000,
        0x1000,
        .riscv32,
    );
    defer emu_guest.deinit();
    const free_before = physmem.getFreeRamBytes();
    const pri = Priority.normal;
    var emu_vc = try VirtualCore.initChecked(0, emu_guest, 0x8000, 0x9000, pri);
    try testing.expectEqual(
        EMULATOR_STACK_SIZE_BYTES + EMULATOR_TLS_SIZE_BYTES,
        free_before - physmem.getFreeRamBytes(),
    );
    emu_vc.deinit();
    try testing.expectEqual(free_before, physmem.getFreeRamBytes());
}
