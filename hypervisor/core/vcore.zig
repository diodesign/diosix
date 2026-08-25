// Virtual CPU core management.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const riscv = @import("../hardware/native/cpu/riscv64/mod.zig");
const dsa = @import("dsa.zig");
const guest = @import("guest.zig");
const physmem = @import("physmem.zig");
const native_emu = @import("emulation");
const glue = @import("emulation.zig");

pub const VirtualCoreID = usize;
pub var time_offset: u64 = 0;

pub const Priority = enum {
    high,
    normal,
};

pub const VirtualCoreState = enum {
    running,
    ready,
    stopped,
    blocked,
};

pub const SchedulerList = dsa.LinkedList(*VirtualCore);

pub const VirtualCoreType = enum {
    native,
    emulated,
};

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

pub const EMULATOR_STACK_SIZE_BYTES: usize = 2 * 1024 * 1024; // 2MB stack
pub const EMULATOR_STACK_PAGE_ORDER: usize = 9;
pub const EMULATOR_TLS_SIZE_BYTES: usize = 4096;
pub const EMULATOR_TLS_PAGE_ORDER: usize = 0;
pub const EMULATOR_TLS_TP_OFFSET: usize = 2048;

pub const PIT_BASE_FREQUENCY_HZ: u64 = 1_193_182;
pub const PIT_DEFAULT_LATCH_100HZ: u64 = 11932;
pub const PIT_TIMER_ACCESS_LSB_MSB: u8 = 3;
pub const PIT_TIMER_MODE_SQUARE_WAVE: u8 = 3;

pub const HEDELEG_GUEST_DELEGATE: usize = 0xb1fb;
pub const HIDELEG_VS_INTERRUPTS: usize = 0x1666;

fn init_ioapic_redtbl() [IOAPIC_NUM_REDIR_ENTRIES]u64 {
    var tbl: [IOAPIC_NUM_REDIR_ENTRIES]u64 = undefined;
    for (&tbl) |*entry| {
        entry.* = IOAPIC_REDIR_MASKED;
    }
    return tbl;
}

pub const max_sub_vcores: usize = 8;
pub const emulation_timeslice_instructions: u32 = 2_000_000;

pub const LapicTimerState = struct {
    lvt_timer: u32 = LAPIC_LVT_MASKED, // Masked (disabled) by default
    init_count: u32 = 0,
    divide_cfg: u32 = 0,
    start_time: u64 = 0,
    period_ticks: u64 = 0,
};


pub const SubVcoreState = struct {
    id: usize = 0,
    state: VirtualCoreState = .stopped,
    context: ?*anyopaque = null, // uc_context
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
    // Unique ID for this vcore within its guest.
    id: VirtualCoreID,
    // The guest this vcore belongs to.
    guest: *guest.Guest,
    guest_id: usize,
    state: VirtualCoreState,

    // Polymorphic execution path parameters
    exec_path: union(VirtualCoreType) {
        native: struct {
            // Virtual CPU registers and state.
            context: riscv.ThreadContext,

            // Machine and Hypervisor specific architecture state.
            machine: riscv.MachineState,

            // VS-mode state (usually context switched).
            guest_state: riscv.GuestState,

            required_extensions: usize,
            siselect: usize,
        },
        emulated: struct {
            vcpu: ?*native_emu.VCpu = null,
            engine: ?*native_emu.Engine = null,
            target_arch: guest.TargetArch,
            entry: usize,
            dtb: usize,
            context: riscv.ThreadContext,
            machine: riscv.MachineState,
            guest_state: riscv.GuestState,
            stack: []u8,
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

            sub_vcores: [max_sub_vcores]SubVcoreState = std.mem.zeroes([max_sub_vcores]SubVcoreState),
            sub_vcore_count: usize = 1,
            active_sub_vcore: usize = 0,
            last_run_sub_vcore: ?usize = null,
            preempt_pending: bool = false,

            exception_cause: u32 = 0,
            hsm_started: bool = false,
            lapic_mem: [LAPIC_PAGE_SIZE]u8 = std.mem.zeroes([LAPIC_PAGE_SIZE]u8),
            sc_hook_addr: u64 = 0,
            idle_hook_addr: u64 = 0,
            icr_dest: u32 = 0,
            ioapic_reg_sel: u8 = 0,
            ioapic_written: bool = false,
            ioapic_redtbl: [IOAPIC_NUM_REDIR_ENTRIES]u64 = init_ioapic_redtbl(),
        },
    },

    timer_scheduled: bool,
    timer_target: u64,
    virtual_time: u64,
    timer_skip_blocks: u32, // blocks to skip before next timer stop (avoids busy-loop when SIE=0)
    running_on_cpu: ?usize,
    wfi_blocked: bool,
    pending_ipi: bool,
    is_queued: bool,
    blocked_on_cpu: ?usize, // Which physical core blocked this vcore (WFI)

    // Scheduling data.
    priority: Priority,
    // For CFS-style scheduling.
    vruntime: u64,
    weight: u32, // For weighting vruntime increments.
    last_queued_time: u64, // Timestamp (rdtime) when last queued, for accounting.

    // Node for the scheduler's Red-Black Tree.
    // We order by vruntime.
    scheduler_node: SchedulerList.Node,

    // Node for the physical core's blocked queue (WFI).
    blocked_node: dsa.LinkedList(*anyopaque).Node,

    pub fn init(id: VirtualCoreID, parent: *guest.Guest, entry: usize, dtb: usize, priority: Priority) VirtualCore {
        var vcore = VirtualCore{
            .id = id,
            .guest = parent,
            .guest_id = parent.id,
            .state = .stopped,
            .timer_scheduled = false,
            .timer_target = 0,
            .virtual_time = 0,
            .timer_skip_blocks = 0,
            .running_on_cpu = null,
            .wfi_blocked = false,
            .pending_ipi = false,
            .is_queued = false,
            .blocked_on_cpu = null,
            .priority = priority,
            .vruntime = 0,
            .weight = switch (priority) {
                .high => WEIGHT_HIGH,
                .normal => WEIGHT_NORMAL,
            },
            .last_queued_time = 0,
            .scheduler_node = undefined,
            .blocked_node = undefined,
            .exec_path = undefined,
        };

        if (parent.target_arch == .riscv64) {
            vcore.exec_path = .{
                .native = .{
                    .siselect = 0,
                    .required_extensions = riscv.IsaExtension.i,
                    .context = std.mem.zeroes(riscv.ThreadContext),
                    .machine = .{
                        .mepc = entry,
                        .mstatus = (1 << 11) | riscv.MSTATUS.MPIE | riscv.MSTATUS.MPV | (3 << riscv.MSTATUS.VS_SHIFT) | (3 << riscv.MSTATUS.FS_SHIFT), // MPP=1 (Supervisor), MPIE=1, MPV=1 (Virtualization), VS=Dirty, FS=Dirty
                        .hstatus = riscv.HSTATUS.SPV | riscv.HSTATUS.SPVP,
                        .hgatp = if (parent.space.mode == .h_paging) parent.space.paging.?.hgatp(parent.vmid) else 0,
                        .hedeleg = HEDELEG_GUEST_DELEGATE, // Delegate exceptions to guest: includes breakpoint (bit 3)
                        .hideleg = HIDELEG_VS_INTERRUPTS, // Delegate VS interrupts (VSSIP, VSTIP, VSEIP, SGEIP)
                        .hvip = 0,
                    },
                    .guest_state = .{
                        .vsstatus = riscv.SSTATUS.SPIE | (3 << riscv.MSTATUS.VS_SHIFT) | (3 << riscv.MSTATUS.FS_SHIFT),
                        .vsie = 0,
                        .vstvec = 0,
                        .vsscratch = 0,
                        .vsepc = 0,
                        .vscause = 0,
                        .vstval = 0,
                        .vsatp = 0,
                        .vstimecmp = std.math.maxInt(u64),
                        .vsenvcfg = (@as(usize, 1) << 63) | 240,
                    },
                },
            };
            vcore.exec_path.native.context[@intFromEnum(riscv.Register.a0)] = id; // A0 = VCPU ID.
            vcore.exec_path.native.context[@intFromEnum(riscv.Register.a1)] = dtb; // A1 = DTB address.
        } else {
            const stack_phys = physmem.allocPageSelection(EMULATOR_STACK_PAGE_ORDER) catch @panic("Failed to allocate S-mode stack for emulator");
            const stack = @as([*]align(16) u8, @ptrFromInt(stack_phys))[0..EMULATOR_STACK_SIZE_BYTES];

            // Allocate a dummy TLS block for emulation runner context.
            const tls_phys = physmem.allocPageSelection(EMULATOR_TLS_PAGE_ORDER) catch @panic("Failed to allocate TLS for emulator");
            @memset(@as([*]u8, @ptrFromInt(tls_phys))[0..EMULATOR_TLS_SIZE_BYTES], 0);

            var hypervisor_gp: usize = 0;
            if (comptime !@import("builtin").is_test) {
                asm volatile ("mv %[g], gp" : [g] "=r" (hypervisor_gp));
            }

            vcore.exec_path = .{
                .emulated = .{
                    .vcpu = null,
                    .engine = null,
                    .target_arch = parent.target_arch,
                    .entry = entry,
                    .dtb = dtb,
                    .context = std.mem.zeroes(riscv.ThreadContext),
                    .machine = .{
                        .mepc = @intFromPtr(&@import("emulation.zig").emulatedRunnerSMode),
                        .mstatus = (1 << 11) | (1 << 7) | (3 << riscv.MSTATUS.FS_SHIFT), // MPP=1 (Supervisor Mode), MPIE=1 (enable S-mode interrupts after mret), MPV=0, FS=3
                        .hstatus = 0,
                        .hgatp = 0,
                        .hedeleg = 0,
                        .hideleg = 0,
                        .hvip = 0,
                    },
                    .guest_state = .{
                        .vsstatus = 0,
                        .vsie = 0,
                        .vstvec = 0,
                        .vsscratch = 0,
                        .vsepc = 0,
                        .vscause = 0,
                        .vstval = 0,
                        .vsatp = 0,
                        .vstimecmp = std.math.maxInt(u64),
                        .vsenvcfg = 0,
                    },
                    .stack = stack,
                    .tls_pointer = tls_phys + EMULATOR_TLS_TP_OFFSET,
                },
            };
            vcore.exec_path.emulated.context[@intFromEnum(riscv.Register.sp)] = @intFromPtr(stack.ptr) + stack.len;
            vcore.exec_path.emulated.context[@intFromEnum(riscv.Register.gp)] = hypervisor_gp;
            vcore.exec_path.emulated.context[@intFromEnum(riscv.Register.tp)] = tls_phys + EMULATOR_TLS_TP_OFFSET;
            vcore.exec_path.emulated.context[@intFromEnum(riscv.Register.a0)] = 0;
        }

        if (parent.target_arch == .x86_64) {
            const init_latch: u64 = PIT_DEFAULT_LATCH_100HZ; // 100 Hz default (10ms period)
            const period_clint: u64 = (init_latch * 10_000_000) / PIT_BASE_FREQUENCY_HZ;
            parent.pit.channels[0] = .{
                .latch = @intCast(init_latch),
                .access = PIT_TIMER_ACCESS_LSB_MSB,
                .mode = PIT_TIMER_MODE_SQUARE_WAVE,
                .period_ticks = period_clint,
            };
            vcore.exec_path.emulated.sub_vcores[0].timer_scheduled = true;
            vcore.exec_path.emulated.sub_vcores[0].timer_target = glue.readSModeTime() + period_clint;
        }

        if (parent.target_arch == .x86_64) {
            std.mem.writeInt(u32, vcore.exec_path.emulated.lapic_mem[LAPIC_REG_ID .. LAPIC_REG_ID + @sizeOf(u32)], @as(u32, @intCast(id)) << 24, .little); // APIC ID
            std.mem.writeInt(u32, vcore.exec_path.emulated.lapic_mem[LAPIC_REG_VERSION .. LAPIC_REG_VERSION + @sizeOf(u32)], LAPIC_VERSION_INTEGRATED, .little); // APIC Version
            std.mem.writeInt(u32, vcore.exec_path.emulated.lapic_mem[LAPIC_REG_SPURIOUS .. LAPIC_REG_SPURIOUS + @sizeOf(u32)], LAPIC_SPURIOUS_ALL_MASKED, .little); // Spurious Vector
        }

        // Initialize the scheduler node's contents to self pointer.

        vcore.scheduler_node.contents = undefined;

        return vcore;
    }

    pub fn reset(self: *VirtualCore, entry: usize, dtb: usize) void {
        self.state = .stopped;
        self.wfi_blocked = false;
        self.is_queued = false;
        self.running_on_cpu = null;

        switch (self.exec_path) {
            .native => |*n| {
                n.context = std.mem.zeroes(riscv.ThreadContext);
                n.context[@intFromEnum(riscv.Register.a0)] = self.id;
                n.context[@intFromEnum(riscv.Register.a1)] = dtb;
                n.machine.mepc = entry;
                n.machine.mstatus = (1 << 11) | riscv.MSTATUS.MPIE | riscv.MSTATUS.MPV | (3 << riscv.MSTATUS.VS_SHIFT) | (3 << riscv.MSTATUS.FS_SHIFT);
                n.machine.hstatus = riscv.HSTATUS.SPV | riscv.HSTATUS.SPVP;
                n.machine.hgatp = if (self.guest.space.mode == .h_paging) self.guest.space.paging.?.hgatp(self.guest.vmid) else 0;
                n.guest_state = .{
                    .vsstatus = riscv.SSTATUS.SPIE | (3 << riscv.MSTATUS.VS_SHIFT) | (3 << riscv.MSTATUS.FS_SHIFT),
                    .vsie = 0,
                    .vstvec = 0,
                    .vsscratch = 0,
                    .vsepc = 0,
                    .vscause = 0,
                    .vstval = 0,
                    .vsatp = 0,
                    .vstimecmp = 0xffffffffffffffff,
                    .vsenvcfg = (@as(usize, 1) << 63) | 240,
                };
            },
            .emulated => |*e| {
                e.entry = entry;
                e.dtb = dtb;
                if (e.engine) |eng| {
                    eng.tlb.flush();
                }
                e.sub_vcores = std.mem.zeroes([max_sub_vcores]SubVcoreState);
                e.sub_vcore_count = 1;
                e.active_sub_vcore = 0;
                e.last_run_sub_vcore = null;
                e.preempt_pending = false;
                e.hsm_started = false;
            },
        }
    }


    pub fn deinit(self: *VirtualCore) void {
        // Trigger a wake to dequeue it if it's blocked, preventing re-queueing
        _ = @atomicRmw(bool, &self.wfi_blocked, .Xchg, false, .acq_rel);

        if (!builtin.is_test) {
            // Spin wait until the home CPU removes it from the blocked_queue
            while ((@as(*volatile ?usize, &self.blocked_on_cpu)).*) |home_cpu| {
                if (home_cpu < riscv.cpu_to_hart_map.len) {
                    if (riscv.CLINT.msip(riscv.cpu_to_hart_map[home_cpu])) |ptr| {
                        ptr.* = 1; // Send IPI to wake the home CPU
                    }
                }
                std.atomic.spinLoopHint();
            }

            // Spin wait until the vcore is no longer running on a physical CPU
            while ((@as(*volatile ?usize, &self.running_on_cpu)).* != null) {
                std.atomic.spinLoopHint();
            }

            // Spin wait until the vcore is no longer in a blocked queue
            while ((@as(*volatile ?usize, &self.blocked_on_cpu)).* != null) {
                std.atomic.spinLoopHint();
            }

            // Spin wait until the vcore is removed from any run_queue
            while ((@as(*volatile bool, &self.is_queued)).*) {
                std.atomic.spinLoopHint();
            }
        }

        switch (self.exec_path) {
            .emulated => |*e| {
                e.vcpu = null;
                e.engine = null;
                self.guest.allocator.free(e.stack);
            },
            else => {},
        }
    }

    pub fn runEmulated(self: *VirtualCore) void {
        @import("emulation.zig").run(self);
    }

    pub fn requiredExtensions(self: *VirtualCore) usize {
        return switch (self.exec_path) {
            .native => |n| n.required_extensions,
            .emulated => 0,
        };
    }

    pub fn getNativeSiselect(self: *VirtualCore) *usize {
        return &self.exec_path.native.siselect;
    }

    pub fn getNativeContext(self: *VirtualCore) *riscv.ThreadContext {
        return switch (self.exec_path) {
            .native => |*n| &n.context,
            .emulated => |*e| &e.context,
        };
    }

    pub fn getNativeMachine(self: *VirtualCore) *riscv.MachineState {
        return switch (self.exec_path) {
            .native => |*n| &n.machine,
            .emulated => |*e| &e.machine,
        };
    }

    pub fn getNativeGuestState(self: *VirtualCore) *riscv.GuestState {
        return switch (self.exec_path) {
            .native => |*n| &n.guest_state,
            .emulated => |*e| &e.guest_state,
        };
    }

    pub fn getGuest(self: *VirtualCore) *guest.Guest {
        return self.guest;
    }

    /// Atomically try to wake this vcore from WFI-blocked state.
    /// Returns true if THIS caller won the race and woke the vcore.
    /// Returns false if the vcore was already awake (another core won).
    /// This prevents multiple physical cores from double-inserting the
    /// same vcore into the scheduler tree, which would corrupt it.
    pub fn tryWake(self: *VirtualCore) bool {
        // Atomic CAS: transition wfi_blocked from true → false.
        // Only one caller can succeed; others see it's already false.
        const old = @cmpxchgStrong(bool, &self.wfi_blocked, true, false, .acq_rel, .monotonic);
        if (old == null) {
            // We won — set the vcore ready for scheduling.
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

    // Update the scheduler node with self pointer before insertion.
    pub fn updateSchedulerWeight(self: *VirtualCore) void {
        self.scheduler_node.contents = self;
    }

    pub fn fork(self: *const VirtualCore, child_guest: *guest.Guest) !*VirtualCore {
        const vc = try child_guest.allocator.create(VirtualCore);
        errdefer child_guest.allocator.destroy(vc);

        vc.* = self.*;
        vc.guest = child_guest;
        vc.guest_id = child_guest.id;

        switch (vc.exec_path) {
            .native => |*n| {
                n.context[@intFromEnum(riscv.Register.a0)] = 0; // SBI error code = SBI_SUCCESS (0)
                n.context[@intFromEnum(riscv.Register.a1)] = 0; // Return value = 0 (Child marker)
            },
            .emulated => |*e| {
                e.vcpu = null;
                e.engine = null;
                e.context[@intFromEnum(riscv.Register.a0)] = 0;
                e.context[@intFromEnum(riscv.Register.a1)] = 0;
            },
        }


        // Reset scheduler node for the new vcore.
        vc.running_on_cpu = null;
        vc.pending_ipi = false;
        vc.is_queued = false;
        vc.scheduler_node = undefined;
        vc.updateSchedulerWeight();

        return vc;
    }
};

test "virtual core initialization" {
    const testing = std.testing;

    const id: VirtualCoreID = 42;
    const entry: usize = 0x8000;
    const dtb: usize = 0x9000;
    var phys_test = try physmem.initForTest(testing.allocator, 128);
    defer phys_test.deinit();
    const parent = try guest.createGuest(testing.allocator, false, false, null, 0, 0, 0, .riscv64);
    defer parent.deinit();

    const vc = VirtualCore.init(id, parent, entry, dtb, .normal);

    try testing.expectEqual(id, vc.id);
    try testing.expectEqual(parent.id, vc.guest_id);
    try testing.expectEqual(entry, vc.exec_path.native.machine.mepc);
    try testing.expectEqual(dtb, vc.exec_path.native.context[@intFromEnum(riscv.Register.a1)]); // a1
    try testing.expectEqual(id, vc.exec_path.native.context[@intFromEnum(riscv.Register.a0)]); // a0
    try testing.expectEqual(@as(u32, 1024), vc.weight);
    try testing.expectEqual(@as(u64, 0), vc.vruntime);
}
