// Resource quota enforcement and VMID allocation for Guest VMs.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const atomic = @import("../atomic.zig");
const physmem = @import("../physmem.zig");
const debug = @import("../debug.zig");
const scheduler = @import("../scheduler.zig");
const guest_mod = @import("../guest.zig");
const sbi = @import("interface").sbi;

pub const max_vmids: u16 = 4096;
pub const BITS_PER_WORD: usize = @bitSizeOf(u64);
pub const VMID_BITMAP_WORDS: usize = max_vmids / BITS_PER_WORD;
pub const MAX_STOP_SPINS: usize = 100_000;

pub const QuotaSet = struct {
    max_ram_pages: usize = std.math.maxInt(usize),
    used_ram_pages: usize = 0,
    max_vcpus: usize = std.math.maxInt(usize),
    used_vcpus: usize = 0,
    max_priority: u8 = std.math.maxInt(u8),
    max_child_depth: usize = std.math.maxInt(usize),
    current_depth: usize = 0,
    max_descendants: usize = std.math.maxInt(usize),
    used_descendants: usize = 0,
};

// Global guest manager state to encapsulate VMIDs and guest ID counters.
const GuestManagerState = struct {
    vmid_bitmap: [VMID_BITMAP_WORDS]u64 = blk: {
        var bm: [VMID_BITMAP_WORDS]u64 = @splat(0);
        // VMID 0 is permanently reserved in RISC-V hgatp.
        bm[0] = 1;
        break :blk bm;
    },
    guest_id_next: usize = sbi.CID_SELF,
};

var guest_manager = atomic.LockPayload(GuestManagerState).init(
    "Global guest manager state",
    .{},
);

pub fn allocGuestId() usize {
    const guard = guest_manager.acquire();
    defer guard.release();
    const state = guard.get();
    const next = state.guest_id_next;
    state.guest_id_next =
        std.math.add(usize, next, 1) catch std.math.maxInt(usize);
    return next;
}

pub fn resetGuestManagerForTest() void {
    const guard = guest_manager.acquire();
    defer guard.release();
    const state = guard.get();
    state.guest_id_next = sbi.CID_SELF;
    state.vmid_bitmap = @splat(0);
    state.vmid_bitmap[0] = 1;
}

pub fn isVmidAllocated(id: u16) bool {
    if (id >= max_vmids) return false;
    const guard = guest_manager.acquire();
    defer guard.release();
    const state = guard.get();
    const wi = id / BITS_PER_WORD;
    const bit: u6 = @intCast(id % BITS_PER_WORD);
    return (state.vmid_bitmap[wi] & (@as(u64, 1) << bit)) != 0;
}

pub fn allocVmid() !u16 {
    const guard = guest_manager.acquire();
    defer guard.release();
    const state = guard.get();

    for (&state.vmid_bitmap, 0..) |*word, wi| {
        if (word.* == std.math.maxInt(u64)) continue;
        const free_bit: u6 = @intCast(@ctz(~word.*));
        const vmid: u16 = @intCast(wi * BITS_PER_WORD + free_bit);
        if (vmid >= max_vmids) break;
        word.* |= @as(u64, 1) << free_bit;
        return vmid;
    }
    debug.printf("VMID: All {} VMIDs exhausted\n", .{max_vmids});
    return error.OutOfMemory;
}

pub fn freeVmid(id: u16) void {
    const guard = guest_manager.acquire();
    defer guard.release();
    const state = guard.get();
    if (id == 0 or id >= max_vmids) return;
    const wi = id / BITS_PER_WORD;
    const bit: u6 = @intCast(id % BITS_PER_WORD);
    state.vmid_bitmap[wi] &= ~(@as(u64, 1) << bit);
}

fn applyClampedQuota(
    target: *guest_mod.Guest,
    ceil: *const guest_mod.Guest,
    args: sbi.QuotaArgs,
) void {
    if (args.max_ram_pages > 0) {
        const max_r = @min(
            ceil.quotas.max_ram_pages,
            @as(usize, @intCast(args.max_ram_pages)),
        );
        target.quotas.max_ram_pages = @min(target.quotas.max_ram_pages, max_r);
        target.quotas.used_ram_pages = @min(
            target.quotas.used_ram_pages,
            target.quotas.max_ram_pages,
        );
        const max_bytes = std.math.mul(
            usize,
            target.quotas.max_ram_pages,
            physmem.PageSize,
        ) catch std.math.maxInt(usize);
        if (target == ceil) {
            if (target.space.range_size == 0 or
                target.space.range_size > max_bytes)
            {
                target.space.setRangeSize(max_bytes);
            }
        } else {
            target.space.setRangeSize(max_bytes);
        }
    }
    if (args.max_vcpus > 0) {
        const max_v = @min(ceil.quotas.max_vcpus, @as(usize, args.max_vcpus));
        target.quotas.max_vcpus = @min(target.quotas.max_vcpus, max_v);
        if (target != ceil) {
            target.quotas.used_vcpus =
                @min(target.quotas.used_vcpus, target.quotas.max_vcpus);
        }
    }
    if (args.max_child_depth > 0) {
        const max_d = @min(
            ceil.quotas.max_child_depth,
            @as(usize, args.max_child_depth),
        );
        target.quotas.max_child_depth =
            @min(target.quotas.max_child_depth, max_d);
    }
    if (args.max_descendants > 0) {
        const max_desc = @min(
            ceil.quotas.max_descendants,
            @as(usize, args.max_descendants),
        );
        target.quotas.max_descendants =
            @min(target.quotas.max_descendants, max_desc);
    }
}

pub fn setQuota(self: *guest_mod.Guest, args: sbi.QuotaArgs) !void {
    if (args.target_cid == sbi.CID_SELF) {
        applyClampedQuota(self, self, args);
    } else if (args.target_cid >= sbi.CID_FIRST_CHILD) {
        if (self.getGuestByCid(args.target_cid)) |child| {
            applyClampedQuota(child, self, args);
        } else {
            return error.InvalidParam;
        }
    } else {
        return error.AccessDenied;
    }
}

pub fn reduceQuota(self: *guest_mod.Guest, new_quotas: QuotaSet) void {
    self.quotas.max_ram_pages =
        @min(self.quotas.max_ram_pages, new_quotas.max_ram_pages);
    self.quotas.max_vcpus =
        @min(self.quotas.max_vcpus, new_quotas.max_vcpus);
    self.quotas.max_priority =
        @min(self.quotas.max_priority, new_quotas.max_priority);
    self.quotas.max_child_depth =
        @min(self.quotas.max_child_depth, new_quotas.max_child_depth);
    self.quotas.max_descendants =
        @min(self.quotas.max_descendants, new_quotas.max_descendants);
}

pub fn checkQuota(
    self: *const guest_mod.Guest,
    ram_pages: usize,
    vcpus: usize,
    depth: usize,
) bool {
    const new_ram = std.math.add(
        usize,
        self.quotas.used_ram_pages,
        ram_pages,
    ) catch return false;
    if (new_ram > self.quotas.max_ram_pages) return false;
    const new_vcpus = std.math.add(
        usize,
        self.quotas.used_vcpus,
        vcpus,
    ) catch return false;
    if (new_vcpus > self.quotas.max_vcpus) return false;
    if (depth > self.quotas.max_child_depth) return false;
    const new_desc = std.math.add(
        usize,
        self.quotas.used_descendants,
        1,
    ) catch return false;
    if (new_desc > self.quotas.max_descendants) return false;

    if (self.parent) |p| {
        return p.checkQuota(ram_pages, vcpus, depth);
    }
    return true;
}

pub fn checkRamQuota(self: *const guest_mod.Guest, ram_pages: usize) bool {
    const new_ram = std.math.add(
        usize,
        self.quotas.used_ram_pages,
        ram_pages,
    ) catch return false;
    if (new_ram > self.quotas.max_ram_pages) return false;
    if (self.parent) |p| {
        return p.checkRamQuota(ram_pages);
    }
    return true;
}

pub fn consumeQuota(
    self: *guest_mod.Guest,
    ram_pages: usize,
    vcpus: usize,
) void {
    self.quotas.used_ram_pages = std.math.add(
        usize,
        self.quotas.used_ram_pages,
        ram_pages,
    ) catch self.quotas.max_ram_pages;
    self.quotas.used_vcpus = std.math.add(
        usize,
        self.quotas.used_vcpus,
        vcpus,
    ) catch self.quotas.max_vcpus;
    if (self.parent) |p| {
        p.consumeQuota(ram_pages, vcpus);
    }
}

pub fn releaseQuota(
    self: *guest_mod.Guest,
    ram_pages: usize,
    vcpus: usize,
) void {
    self.quotas.used_ram_pages -|= ram_pages;
    self.quotas.used_vcpus -|= vcpus;
    if (self.parent) |p| {
        p.releaseQuota(ram_pages, vcpus);
    }
}

pub fn setManifest(self: *guest_mod.Guest, data: []const u8) !void {
    if (data.len > guest_mod.MAX_MANIFEST_SIZE_BYTES) {
        return error.ManifestTooLarge;
    }
    const new_buf = try self.allocator.alloc(u8, data.len);
    @memcpy(new_buf, data);

    const old_buf = blk: {
        const s = self.manifest_lock.lock();
        defer self.manifest_lock.unlock(s);
        const old = self.manifest;
        self.manifest = new_buf;
        break :blk old;
    };
    if (old_buf) |m| self.allocator.free(m);
}

pub fn readManifest(self: *guest_mod.Guest, out_buf: []u8) ?usize {
    const s = self.manifest_lock.lock();
    defer self.manifest_lock.unlock(s);
    if (self.manifest) |m| {
        const copy_len: usize = @min(out_buf.len, m.len);
        @memcpy(out_buf[0..copy_len], m[0..copy_len]);
        return m.len;
    }
    return null;
}

pub fn getManifestLength(self: *guest_mod.Guest) usize {
    const s = self.manifest_lock.lock();
    defer self.manifest_lock.unlock(s);
    return if (self.manifest) |m| m.len else 0;
}

pub fn stop(self: *guest_mod.Guest) void {
    const builtin = @import("builtin");
    const riscv = @import("../../hardware/native/cpu/riscv64/mod.zig");
    const pcore = @import("../pcore.zig");
    const my_cpu = if (builtin.is_test)
        0
    else
        riscv.getCPUContext().hardware_hart_id;
    var it = self.vcores.start;
    while (it) |node| : (it = node.next) {
        const vc = node.contents;
        vc.state = .stopped;
        @atomicStore(bool, &vc.wfi_blocked, false, .release);

        if (!builtin.is_test) {
            scheduler.dequeue(vc);
            if (vc.running_on_cpu) |home_cpu| {
                if (home_cpu != my_cpu) pcore.sendIpiToCpu(home_cpu);
            }
        }
    }

    if (!builtin.is_test) {
        it = self.vcores.start;
        while (it) |node| : (it = node.next) {
            const vc = node.contents;
            var spins: usize = 0;
            while ((@as(*volatile ?usize, &vc.running_on_cpu)).* != null and
                spins < MAX_STOP_SPINS) : (spins += 1)
            {
                if (vc.running_on_cpu == my_cpu) break;
                std.atomic.spinLoopHint();
            }
        }
    }
}

pub fn resetForRun(self: *guest_mod.Guest, entry: usize, dtb: usize) void {
    self.state = .valid;
    self.initial_entry_point = entry;
    self.initial_dtb_ptr = dtb;
    self.uart = .{
        .guest_id = self.id,
        .out_fn = guest_mod.Guest.guestUartOutput,
    };
    self.timer.reset();
    self.pic.reset();
    var is_primary = true;
    var it = self.vcores.start;
    while (it) |node| : (it = node.next) {
        const vc = node.contents;
        vc.reset(entry, dtb);
        vc.state = if (is_primary) .ready else .stopped;
        is_primary = false;
    }
}

test "guest quota management, manifest, and VMID double-free guard" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    const allocator = testing.allocator;

    scheduler.init();
    scheduler.initCpu();
    resetGuestManagerForTest();

    var phys_test = try physmem.initForTest(allocator, 4096);
    defer phys_test.deinit();

    const parent = try guest_mod.createGuest(
        allocator,
        true,
        true,
        null,
        0,
        0,
        0x1000000,
        .riscv64,
    );
    defer parent.deinit();
    _ = try parent.addVcore(0, 0, 0, .normal, null);

    const child = try parent.createChild(false, .riscv64, 1);
    defer child.deinit();

    try parent.setQuota(.{
        .target_cid = 2,
        .max_ram_pages = 1024,
        .max_vcpus = 2,
        .max_child_depth = 4,
        .max_descendants = 10,
    });
    try testing.expectEqual(@as(usize, 1024), child.quotas.max_ram_pages);
    try testing.expectEqual(@as(usize, 2), child.quotas.max_vcpus);

    try child.setQuota(.{
        .target_cid = sbi.CID_SELF,
        .max_ram_pages = 512,
        .max_vcpus = 1,
        .max_child_depth = 2,
        .max_descendants = 5,
    });
    try testing.expectEqual(@as(usize, 512), child.quotas.max_ram_pages);
    try testing.expectEqual(@as(usize, 1), child.quotas.max_vcpus);

    try testing.expectError(
        error.AccessDenied,
        child.setQuota(.{
            .target_cid = sbi.CID_PARENT,
            .max_ram_pages = 100,
            .max_vcpus = 1,
            .max_child_depth = 1,
            .max_descendants = 1,
        }),
    );

    const sample_manifest = "[vm]\nname = \"test-child\"\ncid = 2\n";
    try child.setManifest(sample_manifest);
    var read_buf: [64]u8 = undefined;
    const mlen = child.readManifest(&read_buf).?;
    try testing.expectEqualStrings(sample_manifest, read_buf[0..mlen]);

    try testing.expect(!child.checkQuota(std.math.maxInt(usize), 1, 1));
    try testing.expect(!child.checkQuota(1, std.math.maxInt(usize), 1));

    const parent_base_ram = parent.quotas.used_ram_pages;
    try testing.expect(child.checkRamQuota(100));
    try testing.expect(!child.checkRamQuota(600));
    child.consumeQuota(100, 0);
    try testing.expectEqual(@as(usize, 100), child.quotas.used_ram_pages);
    const exp_ram = parent_base_ram + 100;
    try testing.expectEqual(exp_ram, parent.quotas.used_ram_pages);
    child.releaseQuota(100, 0);
    try testing.expectEqual(@as(usize, 0), child.quotas.used_ram_pages);
    try testing.expectEqual(parent_base_ram, parent.quotas.used_ram_pages);

    // VMID double-free guard: terminateWithCode followed by deinit.
    const child1 = try parent.createChild(false, .riscv64, 0);
    const vmid1 = child1.vmid;
    try testing.expect(vmid1 != 0);
    child1.terminateWithCode(0);
    try testing.expectEqual(@as(u16, 0), child1.vmid);

    const child2 = try parent.createChild(false, .riscv64, 0);
    defer child2.deinit();
    try testing.expectEqual(vmid1, child2.vmid);

    child1.deinit();
    try testing.expect(isVmidAllocated(child2.vmid));
}
