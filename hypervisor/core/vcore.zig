// Virtual CPU core management.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("riscv.zig");
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

// Represents a virtual CPU core's context and state.
pub const VirtualCore = struct {
    // Unique ID for this vcore within its guest.
    id: VirtualCoreID,
    // The guest this vcore belongs to.
    guest: *guest.Guest,
    guest_id: usize,
    state: VirtualCoreState,

    // Virtual CPU registers and state.
    context: riscv.ThreadContext,

    // Machine and Hypervisor specific architecture state.
    machine: riscv.MachineState,

    // VS-mode state (usually context switched).
    guest_state: riscv.GuestState,

    required_extensions: usize,

    // Scheduling data.
    priority: Priority,
    // For CFS-style scheduling.
    vruntime: u64,
    weight: u32, // For weighting vruntime increments.

    // Node for the scheduler's Red-Black Tree.
    // We order by vruntime.
    scheduler_node: SchedulerTree.Node,

    pub fn init(id: VirtualCoreID, parent: *guest.Guest, entry: usize, dtb: usize, priority: Priority) VirtualCore {
        var vcore = VirtualCore{
            .id = id,
            .guest = parent,
            .guest_id = parent.id,
            .state = .stopped,
            .context = [_]usize{0} ** 32,
            .machine = .{
                .mepc = entry,
                .mstatus = (1 << 11) | riscv.MSTATUS.MPV, // MPP=1 (Supervisor), MPV=1 (Virtualization)
                .hstatus = riscv.HSTATUS.SPV,
                .hgatp = 0,
                .hedeleg = 0xb1f3, // Delegate common exceptions to guest supervisor
                .hideleg = 0x333, // Delegate common interrupts to guest supervisor
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
            },
            .required_extensions = riscv.IsaExtension.i,
            .priority = priority,
            .vruntime = 0,
            .weight = switch (priority) {
                .high => 2048,
                .normal => 1024,
            },
            .scheduler_node = undefined,
        };

        vcore.context[@intFromEnum(riscv.Register.a0)] = id; // A0 = VCPU ID.
        vcore.context[@intFromEnum(riscv.Register.a1)] = dtb; // A1 = DTB address.

        // Initialize the scheduler node's contents to the vruntime for ordering.
        vcore.scheduler_node.contents = 0;

        return vcore;
    }

    pub fn deinit(self: *VirtualCore) void {
        _ = self;
        // Cleanup vcore specific resources if any.
    }

    pub fn getGuest(self: *VirtualCore) *guest.Guest {
        return self.guest;
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

        // Return 0 in the child (A0 is X10).
        vc.context[@intFromEnum(riscv.Register.a0)] = 0;

        // Reset scheduler node for the new vcore.
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
    const parent = try guest.createGuest(testing.allocator, false, false, null, 0, 0, 0);
    defer parent.deinit();

    const vc = VirtualCore.init(id, parent, entry, dtb, .normal);

    try testing.expectEqual(id, vc.id);
    try testing.expectEqual(parent.id, vc.guest_id);
    try testing.expectEqual(entry, vc.machine.mepc);
    try testing.expectEqual(dtb, vc.context[@intFromEnum(riscv.Register.a1)]); // a1
    try testing.expectEqual(id, vc.context[@intFromEnum(riscv.Register.a0)]); // a0
    try testing.expectEqual(@as(u32, 1024), vc.weight);
    try testing.expectEqual(@as(u64, 0), vc.vruntime);
}
