// Virtual CPU core management.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("arch/riscv64/riscv.zig");
const dsa = @import("dsa.zig");
const guest = @import("guest.zig");
const physmem = @import("physmem.zig");

pub const VirtualCoreID = usize;

pub const Priority = enum {
    high,
    normal,
};

pub const VirtualCoreState = enum {
    running,
    ready,
    stopped,
};

pub const SchedulerTree = dsa.RedBlackTree(u64, dsa.compareU64);

pub const VirtualCoreType = enum {
    native,
    emulated,
};

pub const max_sub_vcores: usize = 8;
pub const emulation_timeslice_instructions: u32 = 50_000;

pub const SubVcoreState = struct {
    id: usize = 0,
    state: VirtualCoreState = .stopped,
    context: ?*anyopaque = null, // uc_context
    timer_scheduled: bool = false,
    timer_target: u64 = 0,
    wfi_blocked: bool = false,
    pending_ipi: bool = false,

    start_pc: u64 = 0,
    start_a0: u64 = 0,
    start_a1: u64 = 0,
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
            uc: ?*anyopaque,
            target_arch: guest.TargetArch,
            entry: usize,
            dtb: usize,
            context: riscv.ThreadContext,
            machine: riscv.MachineState,
            guest_state: riscv.GuestState,
            stack: []u8,
            emu_running: bool = false,
            
            sub_vcores: [max_sub_vcores]SubVcoreState = std.mem.zeroes([max_sub_vcores]SubVcoreState),
            sub_vcore_count: usize = 1,
            active_sub_vcore: usize = 0,
            last_run_sub_vcore: ?usize = null,
            preempt_pending: bool = false,

            exception_cause: u32 = 0,
        },
    },

    timer_scheduled: bool,
    timer_target: u64,
    timer_skip_blocks: u32, // blocks to skip before next timer stop (avoids busy-loop when SIE=0)
    running_on_cpu: ?usize,
    wfi_blocked: bool,
    pending_ipi: bool,
    blocked_on_cpu: ?usize, // Which physical core blocked this vcore (WFI)

    // Scheduling data.
    priority: Priority,
    // For CFS-style scheduling.
    vruntime: u64,
    weight: u32, // For weighting vruntime increments.
    last_queued_time: u64, // Timestamp (rdtime) when last queued, for accounting.

    // Node for the scheduler's Red-Black Tree.
    // We order by vruntime.
    scheduler_node: SchedulerTree.Node,

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
            .timer_skip_blocks = 0,
            .running_on_cpu = null,
            .wfi_blocked = false,
            .pending_ipi = false,
            .blocked_on_cpu = null,
            .priority = priority,
            .vruntime = 0,
            .weight = switch (priority) {
                .high => 2048,
                .normal => 1024,
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
                        .mstatus = (1 << 11) | riscv.MSTATUS.MPV | (3 << riscv.MSTATUS.VS_SHIFT) | (3 << riscv.MSTATUS.FS_SHIFT), // MPP=1 (Supervisor), MPV=1 (Virtualization), VS=Dirty, FS=Dirty
                        .hstatus = riscv.HSTATUS.SPV | riscv.HSTATUS.SPVP | riscv.HSTATUS.VTW,
                        .hgatp = 0,
                        .hedeleg = 0xb1fb, // Delegate exceptions to guest: includes breakpoint (bit 3)
                        .hideleg = 0x644, // Delegate VS interrupts and physical SEIP
                        .hvip = 0,
                    },
                    .guest_state = .{
                        .vsstatus = (3 << riscv.MSTATUS.VS_SHIFT) | (3 << riscv.MSTATUS.FS_SHIFT),
                        .vsie = 0,
                        .vstvec = 0,
                        .vsscratch = 0,
                        .vsepc = 0,
                        .vscause = 0,
                        .vstval = 0,
                        .vsatp = 0,
                        .vstimecmp = 0xffffffffffffffff,
                        .vsenvcfg = (@as(usize, 1) << 63) | 240,
                    },
                },
            };
            vcore.exec_path.native.context[@intFromEnum(riscv.Register.a0)] = id; // A0 = VCPU ID.
            vcore.exec_path.native.context[@intFromEnum(riscv.Register.a1)] = dtb; // A1 = DTB address.
        } else {
            const stack_size = 128 * 1024; // 128KB stack
            const stack = parent.allocator.alloc(u8, stack_size) catch @panic("Failed to allocate S-mode stack for emulator");

            var hypervisor_gp: usize = 0;
            asm volatile ("mv %[g], gp" : [g] "=r" (hypervisor_gp));

            vcore.exec_path = .{
                .emulated = .{
                    .uc = null,
                    .target_arch = parent.target_arch,
                    .entry = entry,
                    .dtb = dtb,
                    .context = std.mem.zeroes(riscv.ThreadContext),
                    .machine = .{
                        .mepc = @intFromPtr(&@import("emulation.zig").emulatedRunnerSMode),
                        .mstatus = (1 << 11) | (1 << 7) | (3 << riscv.MSTATUS.FS_SHIFT), // MPP=1 (Supervisor Mode), MPIE=1 (enable M-mode interrupts after mret), MPV=0, FS=3
                        .hstatus = 0,
                        .hgatp = 0,
                        .hedeleg = 0,
                        .hideleg = 0,
                        .hvip = 0,
                    },
                    .guest_state = std.mem.zeroes(riscv.GuestState),
                    .stack = stack,
                },
            };
            vcore.exec_path.emulated.context[@intFromEnum(riscv.Register.sp)] = @intFromPtr(stack.ptr) + stack.len;
            vcore.exec_path.emulated.context[@intFromEnum(riscv.Register.gp)] = hypervisor_gp;
        }

        // Initialize the scheduler node's contents to the vruntime for ordering.
        vcore.scheduler_node.contents = 0;

        return vcore;
    }

    pub fn deinit(self: *VirtualCore) void {
        switch (self.exec_path) {
            .emulated => |*e| {
                if (e.uc) |uc| {
                    _ = @import("unicorn.zig").uc_close(uc);
                    e.uc = null;
                }
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
            return true;
        }
        return false;
    }

    // Update the scheduler node with latest vruntime before insertion.
    pub fn updateSchedulerWeight(self: *VirtualCore) void {
        self.scheduler_node.contents = self.vruntime;
    }

    pub fn fork(self: *const VirtualCore, child_guest: *guest.Guest) !*VirtualCore {
        const vc = try child_guest.allocator.create(VirtualCore);
        errdefer child_guest.allocator.destroy(vc);

        vc.* = self.*;
        vc.guest = child_guest;
        vc.guest_id = child_guest.id;

        switch (vc.exec_path) {
            .native => |*n| {
                n.context[@intFromEnum(riscv.Register.a0)] = 0; // Return 0 in the child (A0 is X10).
            },
            .emulated => |*e| {
                e.uc = null; // Fresh Unicorn context on startup for child
            },
        }

        // Reset scheduler node for the new vcore.
        vc.running_on_cpu = null;
        vc.pending_ipi = false;
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
