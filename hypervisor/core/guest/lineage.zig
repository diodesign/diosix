// Parent/child lineage hierarchy, two-column CID/vcore lookup tables,
// cascading termination, and Steward/Standby Root failover for Guest VMs.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const vcore = @import("../vcore.zig");
const physmem = @import("../physmem.zig");
const pcore = @import("../pcore.zig");
const guest_mod = @import("../guest.zig");
const quota_mod = @import("quota.zig");
const sbi = @import("interface").sbi;

pub const STATIC_CHILD_HANDLES: usize = 32;
pub const DYNAMIC_CHILD_BUCKETS: usize = 32;
pub const MAX_CHILD_HANDLES: usize = 4096;
pub const STATIC_VCORES: usize = 32;
pub const VCORE_HASH_BUCKETS: usize = 32;

pub fn allocChildHandle(
    self: *guest_mod.Guest,
    child: *guest_mod.Guest,
) !usize {
    const s = self.tree_lock.lock();
    defer self.tree_lock.unlock(s);

    // Column 1: static array for handles 0..31 (CIDs 2..33).
    for (&self.child_static_handles, 0..) |*slot, i| {
        if (slot.* == null) {
            slot.* = child;
            child.child_handle_next = null;
            const cid = i + sbi.CID_FIRST_CHILD;
            child.local_cid = cid;
            return cid;
        }
    }

    // Column 2: dynamic chained hash table for handles 32..4095.
    const dynamic_count = MAX_CHILD_HANDLES - STATIC_CHILD_HANDLES;
    for (0..dynamic_count) |_| {
        const handle_idx = self.next_dynamic_handle;
        self.next_dynamic_handle += 1;
        if (self.next_dynamic_handle >= MAX_CHILD_HANDLES) {
            self.next_dynamic_handle = STATIC_CHILD_HANDLES;
        }

        const cand_cid = handle_idx + sbi.CID_FIRST_CHILD;
        const bucket = handle_idx % DYNAMIC_CHILD_BUCKETS;

        var in_use = false;
        var curr = self.child_dynamic_buckets[bucket];
        while (curr) |c| {
            if (c.local_cid == cand_cid) {
                in_use = true;
                break;
            }
            curr = c.child_handle_next;
        }

        if (!in_use) {
            child.child_handle_next = self.child_dynamic_buckets[bucket];
            self.child_dynamic_buckets[bucket] = child;
            child.local_cid = cand_cid;
            return cand_cid;
        }
    }

    return error.QuotaExceeded;
}

pub fn freeChildHandle(
    self: *guest_mod.Guest,
    child: *guest_mod.Guest,
) void {
    const s = self.tree_lock.lock();
    defer self.tree_lock.unlock(s);

    const cid = child.local_cid;
    if (cid >= sbi.CID_FIRST_CHILD) {
        const handle_idx = cid - sbi.CID_FIRST_CHILD;
        if (handle_idx < STATIC_CHILD_HANDLES) {
            if (self.child_static_handles[handle_idx] == child) {
                self.child_static_handles[handle_idx] = null;
                return;
            }
        } else if (handle_idx < MAX_CHILD_HANDLES) {
            const bucket = handle_idx % DYNAMIC_CHILD_BUCKETS;
            var curr = self.child_dynamic_buckets[bucket];
            var prev: ?*guest_mod.Guest = null;
            while (curr) |c| {
                if (c == child) {
                    if (prev) |p| {
                        p.child_handle_next = c.child_handle_next;
                    } else {
                        self.child_dynamic_buckets[bucket] =
                            c.child_handle_next;
                    }
                    c.child_handle_next = null;
                    return;
                }
                prev = c;
                curr = c.child_handle_next;
            }
        }
    }
}

pub fn getGuestByCid(self: *guest_mod.Guest, cid: usize) ?*guest_mod.Guest {
    if (cid == sbi.CID_PARENT) {
        return self.parent;
    } else if (cid == sbi.CID_SELF) {
        return self;
    } else if (cid >= sbi.CID_FIRST_CHILD) {
        const s = self.tree_lock.lock();
        defer self.tree_lock.unlock(s);

        const handle_idx = cid - sbi.CID_FIRST_CHILD;
        if (handle_idx < STATIC_CHILD_HANDLES) {
            return self.child_static_handles[handle_idx];
        } else if (handle_idx < MAX_CHILD_HANDLES) {
            const bucket = handle_idx % DYNAMIC_CHILD_BUCKETS;
            var curr = self.child_dynamic_buckets[bucket];
            while (curr) |c| {
                if (c.local_cid == cid) return c;
                curr = c.child_handle_next;
            }
        }
    }
    return null;
}

pub fn registerVcoreLookup(
    self: *guest_mod.Guest,
    vid: vcore.VirtualCoreID,
    vc: *vcore.VirtualCore,
) void {
    if (vid < STATIC_VCORES) {
        self.vcore_static[vid] = vc;
    } else {
        const bucket = vid % VCORE_HASH_BUCKETS;
        vc.lookup_next = self.vcore_dynamic_buckets[bucket];
        self.vcore_dynamic_buckets[bucket] = vc;
    }
}

pub fn findVcore(
    self: *const guest_mod.Guest,
    vid: vcore.VirtualCoreID,
) ?*vcore.VirtualCore {
    if (vid < STATIC_VCORES) {
        return self.vcore_static[vid];
    }
    const bucket = vid % VCORE_HASH_BUCKETS;
    var curr = self.vcore_dynamic_buckets[bucket];
    while (curr) |c| {
        if (c.id == vid) return c;
        curr = c.lookup_next;
    }
    return null;
}

pub fn createChild(
    self: *guest_mod.Guest,
    is_trusted: bool,
    target_arch: guest_mod.TargetArch,
    vcpu_count: usize,
) !*guest_mod.Guest {
    const num_vcpus = if (vcpu_count > 0) vcpu_count else 1;
    if (!self.checkQuota(0, num_vcpus, self.quotas.current_depth + 1)) {
        return error.QuotaExceeded;
    }

    const child_base_gpa: usize = switch (target_arch) {
        .riscv64, .riscv32 => guest_mod.CHILD_RV_BASE_GPA,
        .x86_64 => 0,
        .aarch64 => guest_mod.CHILD_ARM64_BASE_GPA,
    };
    const child_range_size = std.math.mul(
        usize,
        self.quotas.max_ram_pages,
        physmem.PageSize,
    ) catch std.math.maxInt(usize);

    const child_id = quota_mod.allocGuestId();
    const child = try guest_mod.Guest.init(
        self.allocator,
        child_id,
        is_trusted,
        false,
        self,
        child_base_gpa,
        0,
        child_range_size,
        target_arch,
    );
    errdefer {
        var p_anc: ?*guest_mod.Guest = self;
        while (p_anc) |anc| : (p_anc = anc.parent) {
            anc.quotas.used_descendants -|= 1;
        }
        child.deinit();
    }

    child.quotas = .{
        .max_ram_pages = self.quotas.max_ram_pages,
        .used_ram_pages = 0,
        .max_vcpus = self.quotas.max_vcpus,
        .used_vcpus = 0,
        .max_child_depth = self.quotas.max_child_depth -| 1,
        .current_depth = self.quotas.current_depth + 1,
        .max_descendants = self.quotas.max_descendants -| 1,
        .used_descendants = 0,
    };

    for (0..num_vcpus) |vc_id| {
        _ = try child.addVcore(@intCast(vc_id), 0, 0, .normal, null);
    }
    child.quotas.used_vcpus = num_vcpus;

    var p_opt: ?*guest_mod.Guest = self;
    while (p_opt) |p| : (p_opt = p.parent) {
        p.quotas.used_vcpus += num_vcpus;
    }
    return child;
}

pub fn terminateWithCode(self: *guest_mod.Guest, exit_code: usize) void {
    if (self.state == .dying) return;
    self.state = .dying;
    self.exit_code = exit_code;

    while (blk: {
        const s = self.tree_lock.lock();
        const n = self.children.popStart();
        self.tree_lock.unlock(s);
        break :blk n;
    }) |node| {
        const child = node.contents;
        child.child_node = null;
        child.terminateWithCode(exit_code);
        self.allocator.destroy(node);
    }

    self.stop();
    self.space.deinit();
    pcore.broadcastIpi();

    if (self.parent) |p| {
        p.events.push(.{
            .cid = self.local_cid,
            .event_type = @backingInt(sbi.EventType.child_terminated),
            .exit_code = @truncate(exit_code),
        });
        p.freeChildHandle(self);
        if (self.child_node) |node| {
            const s = p.tree_lock.lock();
            p.children.remove(node);
            p.tree_lock.unlock(s);
            p.allocator.destroy(node);
            self.child_node = null;
        }
    }

    const ram_reclaim = self.quotas.used_ram_pages;
    const vcpus_reclaim = self.quotas.used_vcpus;
    var p_opt = self.parent;
    while (p_opt) |p| : (p_opt = p.parent) {
        p.quotas.used_ram_pages -|= ram_reclaim;
        p.quotas.used_vcpus -|= vcpus_reclaim;
        p.quotas.used_descendants -|= 1;
    }
    self.parent = null;

    self.unregisterResources();
}

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
                (prev_cid - sbi.CID_FIRST_CHILD) < STATIC_CHILD_HANDLES and
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
            _ = standby.allocChildHandle(child) catch {};
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

    old_root.dropTrust();
    old_root.is_root = false;
}

test "Two-column virtual core and child handle lookup tables" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var g: guest_mod.Guest = undefined;
    g.vcore_static = @splat(null);
    g.vcore_dynamic_buckets = @splat(null);
    g.vcores.init();

    var vc0: vcore.VirtualCore = undefined;
    vc0.id = 0;
    vc0.lookup_next = null;
    registerVcoreLookup(&g, 0, &vc0);

    var vc31: vcore.VirtualCore = undefined;
    vc31.id = 31;
    vc31.lookup_next = null;
    registerVcoreLookup(&g, 31, &vc31);

    var vc32: vcore.VirtualCore = undefined;
    vc32.id = 32;
    vc32.lookup_next = null;
    registerVcoreLookup(&g, 32, &vc32);

    var vc64: vcore.VirtualCore = undefined;
    vc64.id = 64;
    vc64.lookup_next = null;
    registerVcoreLookup(&g, 64, &vc64);

    try testing.expectEqual(&vc0, findVcore(&g, 0));
    try testing.expectEqual(&vc31, findVcore(&g, 31));
    try testing.expectEqual(&vc32, findVcore(&g, 32));
    try testing.expectEqual(&vc64, findVcore(&g, 64));
    try testing.expect(findVcore(&g, 1) == null);
    try testing.expect(findVcore(&g, 33) == null);

    var phys_test = try physmem.initForTest(allocator, 128);
    defer phys_test.deinit();
    const hpa = try physmem.allocPage();
    const parent = try guest_mod.createGuest(
        allocator,
        true,
        true,
        null,
        0x80000000,
        hpa,
        0x1000,
        .riscv64,
    );
    defer parent.deinit();

    _ = try parent.addVcore(0, 0, 0, .normal, null);
    try testing.expectError(
        error.DuplicateVcore,
        parent.addVcore(0, 0, 0, .normal, null),
    );
    _ = try parent.addVcore(42, 0, 0, .normal, null);
    try testing.expectError(
        error.DuplicateVcore,
        parent.addVcore(42, 0, 0, .normal, null),
    );

    const NUM_CHILDREN = 80;
    var dummy_children: [NUM_CHILDREN]guest_mod.Guest = undefined;
    var allocated_cids: [NUM_CHILDREN]usize = undefined;

    for (0..NUM_CHILDREN) |i| {
        dummy_children[i] = undefined;
        dummy_children[i].local_cid = 0;
        dummy_children[i].child_handle_next = null;
        allocated_cids[i] = try parent.allocChildHandle(&dummy_children[i]);
    }
    for (0..NUM_CHILDREN) |i| {
        try testing.expectEqual(
            &dummy_children[i],
            parent.getGuestByCid(allocated_cids[i]).?,
        );
    }

    parent.freeChildHandle(&dummy_children[5]);
    try testing.expect(parent.getGuestByCid(allocated_cids[5]) == null);
    parent.freeChildHandle(&dummy_children[45]);
    try testing.expect(parent.getGuestByCid(allocated_cids[45]) == null);

    var new_child_static: guest_mod.Guest = undefined;
    new_child_static.local_cid = 0;
    new_child_static.child_handle_next = null;
    const reused_cid = try parent.allocChildHandle(&new_child_static);
    try testing.expectEqual(allocated_cids[5], reused_cid);

    parent.next_dynamic_handle = 45;
    var reused_child: guest_mod.Guest = undefined;
    reused_child.local_cid = 0;
    reused_child.child_handle_next = null;
    const hole_cid = try parent.allocChildHandle(&reused_child);
    try testing.expectEqual(allocated_cids[45], hole_cid);
}
