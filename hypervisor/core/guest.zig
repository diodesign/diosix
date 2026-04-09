// Guest VM management
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const atomic = @import("atomic.zig");
const vcore = @import("vcore.zig");
const physmem = @import("physmem.zig");
const dsa = @import("dsa.zig");

pub const GuestID = usize;

pub const GuestState = enum {
    valid, // healthy and running
    dying, // being terminated
    restarting, // being reset
};

// Represents a virtual machine guest
pub const Guest = struct {
    id: GuestID,
    state: GuestState,

    // Virtual CPU cores belonging to this guest
    vcores: dsa.LinkedList(*vcore.VirtualCore),

    // Physical RAM regions assigned to this guest
    memory_regions: dsa.LinkedList(physmem.Region),

    // allocator for heap-allocated Guest structures
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: GuestID) !*Guest {
        const self = try allocator.create(Guest);
        errdefer allocator.destroy(self);

        self.* = .{
            .id = id,
            .state = .valid,
            .vcores = undefined,
            .memory_regions = undefined,
            .allocator = allocator,
        };
        self.vcores.init();
        self.memory_regions.init();
        return self;
    }

    pub fn deinit(self: *Guest) void {
        var it_vcore = self.vcores.start;
        while (it_vcore) |node| {
            const next = node.next;
            self.allocator.destroy(node.contents);
            self.allocator.destroy(node);
            it_vcore = next;
        }

        var it_mem = self.memory_regions.start;
        while (it_mem) |node| {
            const next = node.next;
            self.allocator.destroy(node);
            it_mem = next;
        }

        self.allocator.destroy(self);
    }

    // Add a virtual core to this guest
    pub fn addVcore(self: *Guest, vid: vcore.VirtualCoreID, entry: usize, dtb: usize, priority: vcore.Priority) !*vcore.VirtualCore {
        const vc = try self.allocator.create(vcore.VirtualCore);
        errdefer self.allocator.destroy(vc);

        vc.* = vcore.VirtualCore.init(vid, self.id, entry, dtb, priority);

        const node = try self.allocator.create(dsa.LinkedList(*vcore.VirtualCore).Node);
        errdefer self.allocator.destroy(node);

        node.* = .{
            .next = null,
            .previous = null,
            .contents = vc,
        };
        self.vcores.pushEnd(node);
        return vc;
    }

    // Add a memory region to this guest
    pub fn addMemoryRegion(self: *Guest, region: physmem.Region) !void {
        const node = try self.allocator.create(dsa.LinkedList(physmem.Region).Node);
        errdefer self.allocator.destroy(node);

        node.* = .{
            .next = null,
            .previous = null,
            .contents = region,
        };
        self.memory_regions.pushEnd(node);
    }
};

// Global guest tracking
var guest_id_next: usize = 0;
var guests_lock = atomic.NamedSpinLock.init("Global guests lock");
var guests_list: ?*dsa.LinkedList(*Guest).Node = null; // Basic list for now

pub fn createGuest(allocator: std.mem.Allocator) !*Guest {
    guests_lock.lock();
    defer guests_lock.unlock();

    const id = guest_id_next;
    guest_id_next += 1;

    return try Guest.init(allocator, id);
}

test "guest creation and vcore management" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Reset ID counter for predictable test
    guest_id_next = 0;

    const g1 = try createGuest(allocator);
    defer g1.deinit();
    try testing.expectEqual(@as(usize, 0), g1.id);

    const g2 = try createGuest(allocator);
    defer g2.deinit();
    try testing.expectEqual(@as(usize, 1), g2.id);

    // Add a vcore to g1
    const vc = try g1.addVcore(100, 0x1000, 0x2000, .high);
    try testing.expectEqual(@as(usize, 100), vc.id);
    try testing.expectEqual(g1.id, vc.guest_id);
    try testing.expectEqual(@as(usize, 0x1000), vc.mepc);

    // Check that it was added to the guest's vcore list
    try testing.expect(g1.vcores.start != null);
    try testing.expectEqual(vc, g1.vcores.start.?.contents);
}
