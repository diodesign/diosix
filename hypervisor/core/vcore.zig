// Virtual CPU core management
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("riscv.zig");
const dsa = @import("dsa.zig");

pub const VirtualCoreID = usize;

pub const Priority = enum {
    high,
    normal,
};

pub const SchedulerTree = dsa.RedBlackTree(u64, compareU64);

// Represents a virtual CPU core's context and state
pub const VirtualCore = struct {
    // Unique ID for this vcore within its guest
    id: VirtualCoreID,
    // The guest this vcore belongs to (TODO: link to Guest struct)
    guest_id: usize,

    // Virtual CPU registers and state
    context: riscv.ThreadContext,

    // Machine state CSRs (for non-H or for context switching)
    mepc: usize,
    mstatus: usize,

    // H-extension state (if available)
    hstatus: usize,
    hgatp: usize,
    hedeleg: usize,
    hideleg: usize,

    // Scheduling data
    priority: Priority,
    vruntime: u64, // For CFS-style scheduling
    weight: u32, // For weighting vruntime increments

    // Node for the scheduler's Red-Black Tree
    // We order by vruntime
    scheduler_node: SchedulerTree.Node,

    pub fn init(id: VirtualCoreID, guest_id: usize, entry: usize, dtb: usize, priority: Priority) VirtualCore {
        var vcore = VirtualCore{
            .id = id,
            .guest_id = guest_id,
            .context = [_]usize{0} ** 32,
            .mepc = entry,
            .mstatus = 0, // TODO: Set appropriate initial mstatus
            .hstatus = 0,
            .hgatp = 0,
            .hedeleg = 0,
            .hideleg = 0,
            .priority = priority,
            .vruntime = 0,
            .weight = switch (priority) {
                .high => 2048,
                .normal => 1024,
            },
            .scheduler_node = undefined,
        };

        vcore.context[10] = id; // a0 = vcore ID
        vcore.context[11] = dtb; // a1 = DTB address

        // Initialize the scheduler node's contents to the vruntime for ordering
        vcore.scheduler_node.contents = 0;

        return vcore;
    }

    // Update the scheduler node with latest vruntime before insertion
    pub fn updateSchedulerWeight(self: *VirtualCore) void {
        self.scheduler_node.contents = self.vruntime;
    }
};

fn compareU64(a: u64, b: u64) i8 {
    if (a < b) return -1;
    if (a > b) return 1;
    return 0;
}

test "virtual core initialization" {
    const testing = std.testing;

    const id: VirtualCoreID = 42;
    const guest_id: usize = 1;
    const entry: usize = 0x8000;
    const dtb: usize = 0x9000;

    const vc = VirtualCore.init(id, guest_id, entry, dtb, .normal);

    try testing.expectEqual(id, vc.id);
    try testing.expectEqual(guest_id, vc.guest_id);
    try testing.expectEqual(entry, vc.mepc);
    try testing.expectEqual(dtb, vc.context[11]); // a1
    try testing.expectEqual(id, vc.context[10]); // a0
    try testing.expectEqual(@as(u32, 1024), vc.weight);
    try testing.expectEqual(@as(u64, 0), vc.vruntime);
}
