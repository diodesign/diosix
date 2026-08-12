// Guest VM management
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const atomic = @import("atomic.zig");
const vcore = @import("vcore.zig");
const physmem = @import("physmem.zig");
const dsa = @import("dsa.zig");
const vm_space = @import("vm.zig");
const riscv = @import("../hardware/native/cpu/riscv64/mod.zig");
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

pub const TargetArch = enum {
    riscv64,
    riscv32,
    aarch64,
    x86_64,
};

pub const PitChannel = struct {
    latch: u16 = 0,
    count_latched: bool = false,
    latched_val: u16 = 0,
    read_state: u8 = 0, // 0 = LSB, 1 = MSB
    write_state: u8 = 0, // 0 = LSB, 1 = MSB
    mode: u8 = 0,
    access: u8 = 3, // 1 = LSB, 2 = MSB, 3 = LSB/MSB
    start_time: u64 = 0,
    period_ticks: u64 = 0,
    gate: u8 = 1,
};

pub const PitState = struct {
    channels: [3]PitChannel = [_]PitChannel{ .{}, .{}, .{} },
    port_61: u8 = 0x01, // gate 2 enabled
    pic_master_imr: u8 = 0xff,
    pic_slave_imr: u8 = 0xff,
};

pub const Guest = struct {
    id: GuestID,
    state: GuestState,
    is_trusted: bool, // Can map MMIO and route interrupts
    is_root: bool, // Is the progenitor VM (PID 1)
    target_arch: TargetArch,

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

    // Early page table physical address (GPA) for x86_64 boot
    early_pgt_gpa: usize,

    // Fast O(1) lookup from guest_hart_id to vcore.
    // Lock-free because vcores are only added during init before booting.
    vcore_lookup: [max_vcores]?*vcore.VirtualCore,

    // PIT (Programmable Interval Timer) State
    pit: PitState,

    // Shared IO-APIC backing memory for x86_64 guests
    ioapic_mem: [4096]u8,

    // allocator for heap-allocated Guest structures
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: GuestID, is_trusted: bool, is_root: bool, parent: ?*Guest, base_gpa: usize, base_hpa: usize, range_size: usize, target_arch: TargetArch) !*Guest {
        const self = try allocator.create(Guest);
        errdefer allocator.destroy(self);

        self.* = .{
            .id = id,
            .state = .valid,
            .is_trusted = is_trusted,
            .is_root = is_root,
            .target_arch = target_arch,
            .quotas = if (parent) |p| p.quotas else .{},
            .parent = parent,
            .children = .{ .start = null, .end = null },
            .vcores = .{ .start = null, .end = null },
            .vmid = try allocVmid(),
            .vcore_lookup = std.mem.zeroes([max_vcores]?*vcore.VirtualCore),
            .space = try vm_space.GuestSpace.init(allocator, is_trusted, base_gpa, base_hpa, range_size),
            .early_pgt_gpa = if (target_arch == .x86_64) base_gpa + 0x70000 else 0,
            .pit = .{},
            .ioapic_mem = std.mem.zeroes([4096]u8),
            .allocator = allocator,
        };
        self.children.init();
        self.vcores.init();

        // Console input is restricted to the Root VM only.
        if (is_root) {
            debug.last_reader_guest_id = id;
        }

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

        // Release console focus
        debug.destroyGuestState(self.id);

        // Recursive termination of all children (cascading)
        var it_child = self.children.start;
        while (it_child) |node| {
            node.contents.terminate();
            it_child = node.next;
        }

        // Stop and free all vcores
        var it_vcore = self.vcores.start;
        while (it_vcore) |node| {
            node.contents.state = .stopped;
            it_vcore = node.next;
        }

        // Send an IPI to all CPUs to force them to reschedule and drop stopped vcores from their run_queues
        for (0..@import("../hardware/native/cpu/riscv64/mod.zig").cpu_to_hart_map.len) |target_cpu| {
            if (@import("../hardware/native/cpu/riscv64/mod.zig").CLINT.msip(@import("../hardware/native/cpu/riscv64/mod.zig").cpu_to_hart_map[target_cpu])) |ptr| {
                ptr.* = 1;
            }
        }

        // Reclaim resources in used counters up the lineage
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
        debug.destroyGuestState(self.id);
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

    /// Add a virtual core to this guest.
    /// `sched_queue` is an optional scheduler enqueue function. Pass `null` if the vcore
    /// should not be auto-enrolled (e.g. stopped secondary harts, or testing).
    /// This dependency-injection pattern allows future support for multiple scheduler backends.
    pub fn addVcore(self: *Guest, vid: vcore.VirtualCoreID, entry: usize, dtb: usize, priority: vcore.Priority, sched_queue: ?*const fn (*vcore.VirtualCore) void) !*vcore.VirtualCore {
        const vc = try self.allocator.create(vcore.VirtualCore);
        errdefer self.allocator.destroy(vc);

        vc.* = vcore.VirtualCore.init(vid, self, entry, dtb, priority);
        vc.blocked_node.contents = @ptrCast(vc);
        if (vc.exec_path == .emulated) {
            vc.exec_path.emulated.context[@intFromEnum(riscv.Register.a0)] = @intFromPtr(vc);
        }

        const node = try self.allocator.create(dsa.LinkedList(*vcore.VirtualCore).Node);
        errdefer self.allocator.destroy(node);

        node.* = .{
            .next = null,
            .previous = null,
            .contents = vc,
        };
        self.vcores.pushEnd(node);

        // Register in the O(1) lookup table if the hart ID fits.
        if (vid < max_vcores) {
            self.vcore_lookup[vid] = vc;
        } else {
            debug.printf("Warning: Guest {} created vcore with ID {} exceeding max_vcores ({})\n", .{ self.id, vid, max_vcores });
        }

        // Enroll the vcore in the scheduler if a queue function was provided.
        if (sched_queue) |q| {
            q(vc);
        }

        return vc;
    }

    pub const max_vcores: usize = 128;

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
        const child_id = blk: {
            const guard = guest_manager.acquire();
            defer guard.release();
            const state = guard.get();
            const next = state.guest_id_next;
            state.guest_id_next = next + 1;
            break :blk next;
        };

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
            .target_arch = self.target_arch,
            .quotas = self.quotas,
            .parent = self,
            .children = .{ .start = null, .end = null },
            .vcores = .{ .start = null, .end = null },
            .vmid = try allocVmid(),
            .vcore_lookup = std.mem.zeroes([max_vcores]?*vcore.VirtualCore),
            .space = child_space,
            .early_pgt_gpa = if (self.target_arch == .x86_64) child_space.base_gpa + 0x70000 else 0,
            .pit = .{},
            .ioapic_mem = std.mem.zeroes([4096]u8),
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
            if (vc.id < max_vcores) {
                child.vcore_lookup[vc.id] = vc;
            }
            it_vcore = node.next;
        }

        return child;
    }
};

// Global guest manager state to encapsulate VMIDs and guest ID counters.
const GuestManagerState = struct {
    vmid_bitmap: [max_vmids / 64]u64 = std.mem.zeroes([max_vmids / 64]u64),
    guest_id_next: usize = 0,
};

const max_vmids: u16 = 4096; // Practical limit; hardware may support fewer.
var guest_manager = atomic.LockPayload(GuestManagerState).init("Global guest manager state", .{});

fn allocVmid() !u16 {
    const guard = guest_manager.acquire();
    defer guard.release();
    const state = guard.get();

    // Search for a free bit in the bitmap (skip bit 0 = VMID 0).
    for (&state.vmid_bitmap, 0..) |*word, wi| {
        if (word.* == ~@as(u64, 0)) continue; // All bits set, skip.
        const free_bit = @ctz(~word.*);
        const vmid: u16 = @intCast(wi * 64 + free_bit);
        if (vmid == 0) {
            // VMID 0 is reserved; mark it used and continue searching.
            word.* |= @as(u64, 1) << @intCast(free_bit);
            continue;
        }
        word.* |= @as(u64, 1) << @intCast(free_bit);
        return vmid;
    }
    // All VMIDs exhausted.
    debug.printf("VMID: All {} VMIDs exhausted\n", .{max_vmids});
    return error.OutOfMemory;
}

fn freeVmid(id: u16) void {
    const guard = guest_manager.acquire();
    defer guard.release();
    const state = guard.get();
    if (id == 0 or id >= max_vmids) return;
    const wi = id / 64;
    const bit: u6 = @intCast(id % 64);
    state.vmid_bitmap[wi] &= ~(@as(u64, 1) << bit);
}

pub fn createGuest(allocator: std.mem.Allocator, is_trusted: bool, is_root: bool, parent: ?*Guest, base_gpa: usize, base_hpa: usize, range_size: usize, target_arch: TargetArch) !*Guest {
    const id = blk: {
        const guard = guest_manager.acquire();
        defer guard.release();
        const state = guard.get();
        const next = state.guest_id_next;
        state.guest_id_next = next + 1;
        break :blk next;
    };

    return try Guest.init(allocator, id, is_trusted, is_root, parent, base_gpa, base_hpa, range_size, target_arch);
}

test "guest fork and memory sharing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    {
        const guard = guest_manager.acquire();
        defer guard.release();
        const state = guard.get();
        state.guest_id_next = 0;
        state.vmid_bitmap = std.mem.zeroes([max_vmids / 64]u64);
    }
    var phys_test = try physmem.initForTest(allocator, 128);
    defer phys_test.deinit();

    const hpa = try physmem.allocPage();
    const parent = try createGuest(allocator, true, true, null, 0x80000000, hpa, 0x1000, .riscv64);
    defer parent.deinit();

    const scheduler = @import("scheduler.zig");
    scheduler.init();
    scheduler.initCpu();

    // Add a vcore so there is something to fork
    _ = try parent.addVcore(0, 0, 0, .normal, null);

    const child = try parent.fork();
    defer child.deinit();

    try testing.expect(child.id != parent.id);
    try testing.expect(child.vmid != parent.vmid);

    // Check that we have a vcore in the child
    try testing.expect(child.vcores.start != null);
    const child_vc = child.vcores.start.?.contents;
    try testing.expectEqual(@as(usize, 0), child_vc.exec_path.native.context[10]); // a0 is 0
}

test "guest creation and vcore management" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const scheduler = @import("scheduler.zig");
    scheduler.init();
    scheduler.initCpu();

    // Reset ID counter for predictable test
    {
        const guard = guest_manager.acquire();
        defer guard.release();
        const state = guard.get();
        state.guest_id_next = 0;
        state.vmid_bitmap = std.mem.zeroes([max_vmids / 64]u64);
    }
    var phys_test = try physmem.initForTest(allocator, 128);
    defer phys_test.deinit();

    const g1 = try createGuest(allocator, true, true, null, 0, 0, 0, .riscv64);
    defer g1.deinit();
    try testing.expectEqual(@as(usize, 0), g1.id);

    const g2 = try createGuest(allocator, false, false, g1, 0, 0, 0, .riscv64);
    defer g2.deinit();
    try testing.expectEqual(@as(usize, 1), g2.id);
    try testing.expectEqual(g1, g2.parent.?);

    // Add a vcore to g1
    const vc = try g1.addVcore(100, 0x1000, 0x2000, .high, null);
    try testing.expectEqual(@as(usize, 100), vc.id);
    try testing.expectEqual(g1.id, vc.guest_id);
    try testing.expectEqual(@as(usize, 0x1000), vc.exec_path.native.machine.mepc);

    // Check that it was added to the guest's vcore list
    try testing.expect(g1.vcores.start != null);
    try testing.expectEqual(vc, g1.vcores.start.?.contents);
}

test "guest trust drop" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var phys_test = try physmem.initForTest(allocator, 128);
    defer phys_test.deinit();

    const g = try createGuest(allocator, true, true, null, 0, 0, 0, .riscv64);
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

    const parent = try createGuest(allocator, true, true, null, 0, 0, 0, .riscv64);
    defer parent.deinit();

    const child = try createGuest(allocator, false, false, parent, 0, 0, 0, .riscv64);
    defer child.deinit();

    const grandchild = try createGuest(allocator, false, false, child, 0, 0, 0, .riscv64);
    defer grandchild.deinit();

    try testing.expectEqual(parent, child.parent.?);
    try testing.expectEqual(child, grandchild.parent.?);

    // Terminate parent
    parent.terminate();

    try testing.expect(parent.state == .dying);
    try testing.expect(child.state == .dying);
    try testing.expect(grandchild.state == .dying);
}
