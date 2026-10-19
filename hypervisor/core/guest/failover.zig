// Steward reset and Standby Root failover for Guest VMs.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const debug = @import("../debug.zig");
const guest_mod = @import("../guest.zig");
const lineage = @import("lineage.zig");
const physmem = @import("../physmem.zig");
const scheduler = @import("../scheduler.zig");
const quota_mod = @import("quota.zig");
const sbi = @import("interface").sbi;

/// Non-destructively reset a Steward VM back to its golden boot entry point
/// without terminating or disturbing any of its child Leaf VMs.
pub fn resetSteward(self: *guest_mod.Guest, override_entry: usize) void {
    self.stop();
    self.steward_reset_count += 1;
    self.events = .{};
    self.whisper_rx = .{};
    const entry = if (override_entry != 0)
        override_entry
    else
        self.initial_entry_point;
    self.resetForRun(entry, self.initial_dtb_ptr);
}

/// Locate a healthy warm Standby Root VM among this Root VM's direct children.
pub fn findStandbyRoot(self: *guest_mod.Guest) ?*guest_mod.Guest {
    const s = self.tree_lock.lock();
    defer self.tree_lock.unlock(s);
    var it = self.children.start;
    while (it) |node| {
        const child = node.contents;
        if (child.is_standby_root and child.state == .valid) {
            return child;
        }
        it = node.next;
    }
    return null;
}

/// Promote a designated Standby Root VM (`standby`) to replace `old_root` as
/// the active Root VM (`CID 1`, `is_root = true`, `is_trusted = true`) and
/// non-destructively re-parent all surviving Steward and Leaf subtrees.
pub fn promoteStandbyRoot(
    old_root: *guest_mod.Guest,
    standby: *guest_mod.Guest,
) !void {
    if (!old_root.is_root or
        !standby.is_standby_root or
        standby.parent != old_root)
    {
        return error.InvalidParam;
    }

    old_root.freeChildHandle(standby);
    if (standby.child_node) |stby_node| {
        const s = old_root.tree_lock.lock();
        old_root.children.remove(stby_node);
        old_root.tree_lock.unlock(s);
        old_root.allocator.destroy(stby_node);
        standby.child_node = null;
    }

    standby.parent = null;
    standby.is_root = true;
    standby.is_standby_root = false;
    standby.is_trusted = true;
    standby.space.is_trusted = true;
    standby.local_cid = sbi.CID_SELF;
    standby.quotas.current_depth = 0;
    standby.quotas.max_ram_pages = old_root.quotas.max_ram_pages;
    standby.quotas.max_vcpus = old_root.quotas.max_vcpus;
    standby.quotas.max_child_depth = old_root.quotas.max_child_depth;
    standby.quotas.max_descendants = old_root.quotas.max_descendants;

    while (blk: {
        const s = old_root.tree_lock.lock();
        const n = old_root.children.popStart();
        old_root.tree_lock.unlock(s);
        break :blk n;
    }) |node| {
        const child = node.contents;
        const prev_cid = child.local_cid;
        old_root.freeChildHandle(child);

        child.parent = standby;
        node.next = null;
        node.previous = null;
        const assigned_static = blk: {
            const s = standby.tree_lock.lock();
            defer standby.tree_lock.unlock(s);
            standby.children.pushEnd(node);
            if (prev_cid >= sbi.CID_FIRST_CHILD and
                (prev_cid - sbi.CID_FIRST_CHILD) <
                    lineage.STATIC_CHILD_HANDLES and
                standby.child_static_handles[
                    prev_cid - sbi.CID_FIRST_CHILD
                ] == null)
            {
                standby.child_static_handles[
                    prev_cid - sbi.CID_FIRST_CHILD
                ] = child;
                child.child_handle_next = null;
                child.local_cid = prev_cid;
                break :blk true;
            }
            break :blk false;
        };
        if (!assigned_static) {
            _ = standby.allocChildHandle(child) catch |err| {
                debug.printf("Failover CID err: {s}\n", .{@errorName(err)});
            };
        }

        standby.quotas.used_descendants = std.math.add(
            usize,
            standby.quotas.used_descendants,
            1 + child.quotas.used_descendants,
        ) catch standby.quotas.max_descendants;
        standby.quotas.used_vcpus = std.math.add(
            usize,
            standby.quotas.used_vcpus,
            child.quotas.used_vcpus,
        ) catch standby.quotas.max_vcpus;
        standby.quotas.used_ram_pages = std.math.add(
            usize,
            standby.quotas.used_ram_pages,
            child.quotas.used_ram_pages,
        ) catch standby.quotas.max_ram_pages;
    }

    const main = @import("../../main.zig");
    if (main.global_root_vm == old_root) main.global_root_vm = standby;

    old_root.dropTrust();
    old_root.is_root = false;
}

test "Steward reset and Standby Root failover promotion" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    const alloc = testing.allocator;

    scheduler.init();
    scheduler.initCpu();
    quota_mod.resetGuestManagerForTest();

    var phys_test = try physmem.initForTest(alloc, 128);
    defer phys_test.deinit();

    const root = try guest_mod.createGuest(
        alloc,
        true,
        true,
        null,
        0x80000000,
        0,
        0x10000,
        .riscv64,
    );
    defer root.deinit();
    _ = try root.addVcore(0, 0x80200000, 0x81000000, .normal, null);

    const main = @import("../../main.zig");
    main.global_root_vm = root;
    defer main.global_root_vm = null;

    const standby = try root.createChild(true, .riscv64, 1);
    defer standby.deinit();
    standby.is_standby_root = true;

    const steward = try root.createChild(true, .riscv64, 1);
    defer steward.deinit();
    steward.is_steward = true;
    steward.initial_entry_point = 0xe0000000;
    steward.initial_dtb_ptr = 0xe0100000;

    resetSteward(steward, 0);
    try testing.expectEqual(@as(usize, 1), steward.steward_reset_count);

    try testing.expectEqual(standby, findStandbyRoot(root));
    try promoteStandbyRoot(root, standby);

    try testing.expect(standby.is_root);
    try testing.expect(!root.is_root);
    try testing.expectEqual(standby, main.global_root_vm);
    try testing.expectEqual(standby, steward.parent);
}
