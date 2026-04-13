// Guest VM management
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const atomic = @import("atomic.zig");
const vcore = @import("vcore.zig");
const physmem = @import("physmem.zig");
const dsa = @import("dsa.zig");
const vm_space = @import("vm_space.zig");
const riscv = @import("riscv.zig");
const debug = @import("debug.zig");

pub const GuestID = usize;

pub const GuestState = enum {
    valid, // healthy and running
    dying, // being terminated
    restarting, // being reset
};

pub const QuotaSet = struct {
    max_ram_pages: usize = std.math.maxInt(usize),
    used_ram_pages: usize = 0,
    max_vcpus: usize = std.math.maxInt(usize),
    used_vcpus: usize = 0,
    max_priority: u8 = 255,
    max_child_depth: usize = std.math.maxInt(usize),
    current_depth: usize = 0,
    max_descendants: usize = std.math.maxInt(usize),
    used_descendants: usize = 0,
};

pub const Guest = struct {
    id: GuestID,
    state: GuestState,
    is_trusted: bool, // Can map MMIO and route interrupts
    is_root: bool,    // Is the progenitor VM (PID 1)

    // Subtree resource tracking
    quotas: QuotaSet,

    // Lineage tracking
    parent: ?*Guest,
    children: dsa.LinkedList(*Guest),

    // Virtual CPU cores belonging to this guest
    vcores: dsa.LinkedList(*vcore.VirtualCore),

    // Memory space (paging or PMP)
    space: vm_space.GuestSpace,

    // Virtual memory ID for this guest
    vmid: u16,

    // allocator for heap-allocated Guest structures
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: GuestID, is_trusted: bool, is_root: bool, parent: ?*Guest, base_gpa: usize, base_hpa: usize, range_size: usize) !*Guest {
        const self = try allocator.create(Guest);
        errdefer allocator.destroy(self);

        self.* = .{
            .id = id,
            .state = .valid,
            .is_trusted = is_trusted,
            .is_root = is_root,
            .quotas = if (parent) |p| p.quotas else .{},
            .parent = parent,
            .children = .{ .start = null, .end = null },
            .vcores = .{ .start = null, .end = null },
            .vmid = try allocVmid(),
            .space = try vm_space.GuestSpace.init(allocator, is_trusted, base_gpa, base_hpa, range_size),
            .allocator = allocator,
        };
        self.children.init();
        self.vcores.init();

        debug.last_reader_guest_id = id;

        if (parent) |p| {
            const node = try allocator.create(dsa.LinkedList(*Guest).Node);
            node.* = .{ .next = null, .previous = null, .contents = self };
            p.children.pushEnd(node);
            self.quotas.current_depth = p.quotas.current_depth + 1;

            // Increment descendants count up the lineage
            var p_anc: ?*Guest = p;
            while (p_anc) |anc| {
                anc.quotas.used_descendants += 1;
                p_anc = anc.parent;
            }
        }

        return self;
    }


    pub fn terminate(self: *Guest) void {
        self.state = .dying;
        
        // 1. Recursive termination of all children (cascading)
        var it_child = self.children.start;
        while (it_child) |node| {
            node.contents.terminate();
            it_child = node.next;
        }

        // 2. Stop and free all vcores
        var it_vcore = self.vcores.start;
        while (it_vcore) |node| {
            node.contents.state = .stopped;
            it_vcore = node.next;
        }

        // 3. Reclaim resources in used counters up the lineage
        var p_opt = self.parent;
        while (p_opt) |p| {
            p.quotas.used_ram_pages -= self.quotas.used_ram_pages;
            p.quotas.used_vcpus -= self.vcores.count();
            p.quotas.used_descendants -= 1;
            p_opt = p.parent;
        }
    }

    pub fn dropTrust(self: *Guest) void {
        self.is_trusted = false;
        self.space.is_trusted = false;
    }

    pub fn reduceQuota(self: *Guest, new_quotas: QuotaSet) void {
        // Only allow reductions
        self.quotas.max_ram_pages = @min(self.quotas.max_ram_pages, new_quotas.max_ram_pages);
        self.quotas.max_vcpus = @min(self.quotas.max_vcpus, new_quotas.max_vcpus);
        self.quotas.max_priority = @min(self.quotas.max_priority, new_quotas.max_priority);
        self.quotas.max_child_depth = @min(self.quotas.max_child_depth, new_quotas.max_child_depth);
        self.quotas.max_descendants = @min(self.quotas.max_descendants, new_quotas.max_descendants);
    }

    pub fn checkQuota(self: *Guest, ram_pages: usize, vcpus: usize, depth: usize) bool {
        // Check local limits
        if (self.quotas.used_ram_pages + ram_pages > self.quotas.max_ram_pages) return false;
        if (self.quotas.used_vcpus + vcpus > self.quotas.max_vcpus) return false;
        if (depth > self.quotas.max_child_depth) return false;
        if (self.quotas.used_descendants + 1 > self.quotas.max_descendants) return false;

        // Recursively check ancestors
        if (self.parent) |p| {
            return p.checkQuota(ram_pages, vcpus, depth);
        }
        return true;
    }

    pub fn consumeQuota(self: *Guest, ram_pages: usize, vcpus: usize) void {
        self.quotas.used_ram_pages += ram_pages;
        self.quotas.used_vcpus += vcpus;
        if (self.parent) |p| {
            p.consumeQuota(ram_pages, vcpus);
        }
    }

    pub fn deinit(self: *Guest) void {
        var it_vcore = self.vcores.start;
        while (it_vcore) |node| {
            const next = node.next;
            node.contents.deinit(); // VCore might need its own cleanup
            self.allocator.destroy(node.contents);
            self.allocator.destroy(node);
            it_vcore = next;
        }

        self.space.deinit();
        
        var it_child = self.children.start;
        while (it_child) |node| {
            const next = node.next;
            // node.contents should be deinitialized by the caller if they are the root,
            // or here if we want deep deinit. But tests usually deinit each guest manually.
            self.allocator.destroy(node);
            it_child = next;
        }

        freeVmid(self.vmid);
        self.allocator.destroy(self);
    }

    pub fn addVcore(self: *Guest, vid: vcore.VirtualCoreID, entry: usize, dtb: usize, priority: vcore.Priority) !*vcore.VirtualCore {
        const vc = try self.allocator.create(vcore.VirtualCore);
        errdefer self.allocator.destroy(vc);

        vc.* = vcore.VirtualCore.init(vid, self, entry, dtb, priority);

        const node = try self.allocator.create(dsa.LinkedList(*vcore.VirtualCore).Node);
        errdefer self.allocator.destroy(node);

        node.* = .{
            .next = null,
            .previous = null,
            .contents = vc,
        };
        self.vcores.pushEnd(node);
        
        // Enroll the vcore in the global scheduler
        const scheduler = @import("scheduler.zig");
        scheduler.queue(vc);

        return vc;
    }

    pub fn findVcore(self: *const Guest, vid: vcore.VirtualCoreID) ?*vcore.VirtualCore {
        var it = self.vcores.start;
        while (it) |node| {
            if (node.contents.id == vid) return node.contents;
            it = node.next;
        }
        return null;
    }

    // Add a memory region to this guest
    pub fn addMemoryRegion(self: *Guest, gpa: usize, hpa: usize, size: usize, flags: u64) !void {
        try self.space.map(gpa, hpa, size, flags);
    }

    // Fork this guest to create a child VM
    pub fn fork(self: *Guest) !*Guest {
        const child_id = guest_id_next.fetchAdd(1, .monotonic);
        
        // Resource check: RAM=0 (fork is lazy), VCPUs=count, Depth=current+1
        const vcpu_count = self.vcores.count();
        if (!self.checkQuota(0, vcpu_count, self.quotas.current_depth + 1)) {
            return error.QuotaExceeded;
        }

        // Create new guest space with lazy forking
        const child_space = try self.space.fork();
        
        const child = try self.allocator.create(Guest);
        errdefer self.allocator.destroy(child);
        
        child.* = .{
            .id = child_id,
            .state = .valid,
            .is_trusted = self.is_trusted,
            .is_root = false, // Only the progenitor is truly root
            .quotas = self.quotas,
            .parent = self,
            .children = .{ .start = null, .end = null },
            .vcores = .{ .start = null, .end = null },
            .vmid = try allocVmid(),
            .space = child_space,
            .allocator = self.allocator,
        };
        child.children.init();
        child.vcores.init();
        
        // Lineage tracking
        const line_node = try self.allocator.create(dsa.LinkedList(*Guest).Node);
        line_node.* = .{ .next = null, .previous = null, .contents = child };
        self.children.pushEnd(line_node);
        child.quotas.current_depth = self.quotas.current_depth + 1;

        // Ancestor tracking: consumed descendants and vcpus
        var p_opt: ?*Guest = self;
        while (p_opt) |p| {
            p.quotas.used_descendants += 1;
            p.quotas.used_vcpus += vcpu_count;
            p_opt = p.parent;
        }

        // Clone vcores
        var it_vcore = self.vcores.start;
        while (it_vcore) |node| {
            const vc = try node.contents.fork(child);
            const vc_node = try child.allocator.create(dsa.LinkedList(*vcore.VirtualCore).Node);
            vc_node.* = .{ .next = null, .previous = null, .contents = vc };
            child.vcores.pushEnd(vc_node);
            it_vcore = node.next;
        }

        return child;
    }
};

// Global guest tracking
var guest_id_next = std.atomic.Value(usize).init(0);
var vmid_next: u16 = 1; // 0 is reserved
var guests_lock = atomic.NamedSpinLock.init("Global guests lock");

fn allocVmid() !u16 {
    guests_lock.lock();
    defer guests_lock.unlock();
    const id = vmid_next;
    vmid_next += 1;
    return id;
}

fn freeVmid(id: u16) void {
    _ = id; // TODO: Implement recycling
}

pub fn createGuest(allocator: std.mem.Allocator, is_trusted: bool, is_root: bool, parent: ?*Guest, base_gpa: usize, base_hpa: usize, range_size: usize) !*Guest {
    const id = blk: {
        guests_lock.lock();
        defer guests_lock.unlock();
        const next = guest_id_next.load(.monotonic);
        guest_id_next.store(next + 1, .monotonic);
        break :blk next;
    };

    return try Guest.init(allocator, id, is_trusted, is_root, parent, base_gpa, base_hpa, range_size);
}

test "guest fork and memory sharing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    guest_id_next.store(0, .monotonic); // Reset for test
    var phys_test = try physmem.initForTest(allocator, 128);
    defer phys_test.deinit();

    const hpa = try physmem.allocPage();
    const parent = try createGuest(allocator, true, true, null, 0x80000000, hpa, 0x1000);
    defer parent.deinit();

    const scheduler = @import("scheduler.zig");
    scheduler.init();
    scheduler.initCpu();

    // Add a vcore so there is something to fork
    _ = try parent.addVcore(0, 0, 0, .normal);

    const child = try parent.fork();
    defer child.deinit();

    try testing.expect(child.id != parent.id);
    try testing.expect(child.vmid != parent.vmid);
    
    // Check that we have a vcore in the child
    try testing.expect(child.vcores.start != null);
    const child_vc = child.vcores.start.?.contents;
    try testing.expectEqual(@as(usize, 0), child_vc.context[10]); // a0 is 0
}

test "guest creation and vcore management" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const scheduler = @import("scheduler.zig");
    scheduler.init();
    scheduler.initCpu();

    // Reset ID counter for predictable test
    guest_id_next.store(0, .monotonic);
    var phys_test = try physmem.initForTest(allocator, 128);
    defer phys_test.deinit();

    const g1 = try createGuest(allocator, true, true, null, 0, 0, 0);
    defer g1.deinit();
    try testing.expectEqual(@as(usize, 0), g1.id);

    const g2 = try createGuest(allocator, false, false, g1, 0, 0, 0);
    defer g2.deinit();
    try testing.expectEqual(@as(usize, 1), g2.id);
    try testing.expectEqual(g1, g2.parent.?);

    // Add a vcore to g1
    const vc = try g1.addVcore(100, 0x1000, 0x2000, .high);
    try testing.expectEqual(@as(usize, 100), vc.id);
    try testing.expectEqual(g1.id, vc.guest_id);
    try testing.expectEqual(@as(usize, 0x1000), vc.machine.mepc);

    // Check that it was added to the guest's vcore list
    try testing.expect(g1.vcores.start != null);
    try testing.expectEqual(vc, g1.vcores.start.?.contents);
}

test "guest trust drop" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var phys_test = try physmem.initForTest(allocator, 128);
    defer phys_test.deinit();

    const g = try createGuest(allocator, true, true, null, 0, 0, 0);
    defer g.deinit();

    try testing.expect(g.is_trusted == true);
    g.dropTrust();
    try testing.expect(g.is_trusted == false);
    try testing.expect(g.space.is_trusted == false);
}

test "guest cascading termination and lineage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var phys_test = try physmem.initForTest(allocator, 128);
    defer phys_test.deinit();

    const parent = try createGuest(allocator, true, true, null, 0, 0, 0);
    defer parent.deinit();

    const child = try createGuest(allocator, false, false, parent, 0, 0, 0);
    defer child.deinit();

    const grandchild = try createGuest(allocator, false, false, child, 0, 0, 0);
    defer grandchild.deinit();

    try testing.expectEqual(parent, child.parent.?);
    try testing.expectEqual(child, grandchild.parent.?);

    // Terminate parent
    parent.terminate();

    try testing.expect(parent.state == .dying);
    try testing.expect(child.state == .dying);
    try testing.expect(grandchild.state == .dying);
}
