// Physical memory management routines.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const atomic = @import("atomic.zig");
const riscv = @import("../hardware/native/cpu/riscv64/mod.zig");
const debug = @import("debug.zig");
const dt = @import("dt.zig");

extern const __hypervisor_start: u8;
extern const __hypervisor_end: u8;

var test_hv_start = if (builtin.is_test) @as(usize, 0x80000000) else 0;
var test_hv_end = if (builtin.is_test) @as(usize, 0x80010000) else 0;

pub const PageSize: usize = 0x1000; // 4 KiB pages.
pub const PhysMemError = error{ NoRAMFound, OutOfMemory };

pub const Region = struct {
    base: usize,
    size: usize,
    pub fn end(self: Region) usize {
        return std.math.add(usize, self.base, self.size) catch
            std.math.maxInt(usize);
    }
};
pub const PageFlags = struct {
    pub const free: u8 = 1 << 0;
    pub const cow: u8 = 1 << 1;
};
pub const PageDescriptor = struct { refcount: u32, flags: u8, order: u8 };
const max_regions = 16;
pub const max_order = 16; // Up to 2^15 pages = 128 MiB contiguous.
const PageStackNode = struct { next: ?*PageStackNode };
const init_free_lists: [max_order]?*PageStackNode =
    std.mem.zeroes([max_order]?*PageStackNode);

const PhysMemState = struct {
    has_h_extension: bool = false,
    free_lists: [max_order]?*PageStackNode = init_free_lists,
    regions: [max_regions]Region = undefined,
    region_count: usize = 0,
    ram_base: usize = 0,
    ram_size: usize = 0,
    total_pages: usize = 0,
    free_pages: usize = 0,
    metadata: []PageDescriptor = &.{},
    hv_region: Region = .{ .base = 0, .size = 0 },
    lock: atomic.NamedSpinLock =
        atomic.NamedSpinLock.init("Physical memory lock"),
};
var phys_mem_state = PhysMemState{};

pub const TestState = struct {
    allocator: std.mem.Allocator,
    metadata: []PageDescriptor,
    raw_ram: []u8,
    pub fn deinit(self: *TestState) void {
        const lock_ms = phys_mem_state.lock.lock();
        defer phys_mem_state.lock.unlock(lock_ms);
        self.allocator.free(self.metadata);
        self.allocator.free(self.raw_ram);
        phys_mem_state = PhysMemState{};
    }
};

pub fn initForTest(allocator: std.mem.Allocator, num_pages: usize) !TestState {
    const metadata = try allocator.alloc(PageDescriptor, num_pages);
    @memset(std.mem.sliceAsBytes(metadata), 0);
    const align_pad = 16 * PageSize;
    const raw_ram = try allocator.alloc(u8, num_pages * PageSize + align_pad);
    const aligned_base =
        std.mem.alignForward(usize, @intFromPtr(raw_ram.ptr), align_pad);
    const lock_ms = phys_mem_state.lock.lock();
    defer phys_mem_state.lock.unlock(lock_ms);
    phys_mem_state = .{
        .has_h_extension = true,
        .ram_base = aligned_base,
        .ram_size = num_pages * PageSize,
        .total_pages = num_pages,
        .metadata = metadata,
        .region_count = 1,
        .hv_region = .{ .base = 0x80000000, .size = 0x200000 },
    };
    phys_mem_state.regions[0] = .{
        .base = phys_mem_state.ram_base,
        .size = phys_mem_state.ram_size,
    };
    for (0..num_pages) |i| {
        pushFreeBlockLocked(phys_mem_state.ram_base + i * PageSize, 0);
    }
    return .{
        .allocator = allocator,
        .metadata = metadata,
        .raw_ram = raw_ram,
    };
}
// Compute the hypervisor HPA footprint including static per-CPU slabs.
pub fn computeHvRegion(device_tree: *dt.DeviceTree) Region {
    const max_c = riscv.STATIC_PHYS_CORES;
    const num_slabs: usize =
        if (builtin.is_test) 1 else @min(device_tree.countCpus(), max_c);
    const hv_start = if (builtin.is_test)
        test_hv_start
    else
        @intFromPtr(&__hypervisor_start);
    const hv_static_end =
        if (builtin.is_test) test_hv_end else @intFromPtr(&__hypervisor_end);
    const hv_end = hv_static_end + (num_slabs * riscv.CPU_SLAB_SIZE);
    return .{ .base = hv_start, .size = hv_end - hv_start };
}
fn populateRegionsLocked(device_tree: *dt.DeviceTree) !void {
    phys_mem_state.hv_region = computeHvRegion(device_tree);
    phys_mem_state.region_count = 0;
    var it = device_tree.iter("/", 1);
    while (it.next()) |path| {
        if (!std.mem.startsWith(u8, std.fs.path.basename(path), "memory@")) {
            continue;
        }
        const reg_prop = device_tree.getProperty(path, "reg") catch continue;
        const cells = device_tree.getAddressSizeCells("/");
        const data = reg_prop.data orelse continue;
        const entry_size = (cells.address + cells.size) * 4;
        var i: usize = 0;
        while (i + entry_size <= data.len) : (i += entry_size) {
            const base = try readCells(data[i..], cells.address);
            const size =
                try readCells(data[i + cells.address * 4 ..], cells.size);
            if (phys_mem_state.region_count < max_regions) {
                phys_mem_state.regions[phys_mem_state.region_count] = .{
                    .base = @intCast(base),
                    .size = @intCast(size),
                };
                phys_mem_state.region_count += 1;
            }
        }
    }
}

// Initialize physical memory management using the device tree.
pub fn init(device_tree: *dt.DeviceTree, rootvm_region: ?Region) !void {
    phys_mem_state.has_h_extension = riscv.hasHExtension();
    if (phys_mem_state.region_count == 0) {
        try populateRegionsLocked(device_tree);
    } else {
        phys_mem_state.hv_region = computeHvRegion(device_tree);
    }
    const hv_reg = phys_mem_state.hv_region;
    debug.printf(
        "Hypervisor HPA footprint 0x{x} - 0x{x} ({} KB)\n",
        .{ hv_reg.base, hv_reg.end(), hv_reg.size / 1024 },
    );
    if (rootvm_region) |rvm| {
        debug.printf(
            "Root VM HPA reservation 0x{x} - 0x{x} ({} MB)\n",
            .{ rvm.base, rvm.end(), rvm.size / (1024 * 1024) },
        );
    }
    const active = phys_mem_state.regions[0..phys_mem_state.region_count];
    var min_ram: usize = std.math.maxInt(usize);
    var max_ram: usize = 0;
    for (active) |reg| {
        min_ram = @min(min_ram, reg.base);
        max_ram = @max(max_ram, reg.end());
    }
    if (max_ram == 0 and !builtin.is_test) return PhysMemError.NoRAMFound;
    phys_mem_state.ram_base = min_ram;
    phys_mem_state.ram_size = max_ram - min_ram;
    phys_mem_state.total_pages = phys_mem_state.ram_size / PageSize;
    const meta_sz = phys_mem_state.total_pages * @sizeOf(PageDescriptor);
    debug.printf("Allocating {} KB for page metadata\n", .{meta_sz / 1024});

    var meta_phys: usize = 0;
    for (active) |reg| {
        if (reg.base < hv_reg.base and hv_reg.base - reg.base >= meta_sz) {
            meta_phys = reg.base;
            break;
        } else if (reg.end() > hv_reg.end()) {
            const free_start = @max(reg.base, hv_reg.end());
            if (reg.end() - free_start >= meta_sz) {
                meta_phys = free_start;
                break;
            }
        }
    }
    if (meta_phys == 0 and !builtin.is_test) return PhysMemError.OutOfMemory;
    if (!builtin.is_test) {
        const meta_ptr: [*]PageDescriptor = @ptrFromInt(meta_phys);
        phys_mem_state.metadata = meta_ptr[0..phys_mem_state.total_pages];
        @memset(std.mem.sliceAsBytes(phys_mem_state.metadata), 0);
    }
    const meta_reg = Region{ .base = meta_phys, .size = meta_sz };
    const reserved = device_tree.reserved_memory[0..device_tree.reserved_count];
    for (active) |reg| {
        try addRamBlock(reg, hv_reg, meta_reg, rootvm_region, reserved);
    }
    const total_mb = (phys_mem_state.total_pages * PageSize) / (1024 * 1024);
    debug.printf(
        "Physical memory initialized with {} free pages ({} MB reachable)\n",
        .{ phys_mem_state.free_pages, total_mb },
    );
}

fn readCells(data: []const u8, count: usize) !u64 {
    if (count == 1) {
        if (data.len < 4) return error.OutOfBounds;
        return std.mem.readInt(u32, data[0..4], .big);
    }
    if (count == 2) {
        if (data.len < 8) return error.OutOfBounds;
        return std.mem.readInt(u64, data[0..8], .big);
    }
    return error.WidthUnsupported;
}

fn clipExclusion(
    cur: usize,
    excl_base: usize,
    excl_end: usize,
    next_step: *usize,
    skip: *bool,
) void {
    if (cur >= excl_base and cur < excl_end) {
        if (excl_end > next_step.* or !skip.*) {
            next_step.* = excl_end;
            skip.* = true;
        }
    } else if (excl_base >= cur and excl_base < next_step.*) {
        next_step.* = excl_base;
    }
}

fn addRamBlock(
    ram: Region,
    hv: Region,
    meta: Region,
    rootvm: ?Region,
    reserved: []dt.ReservedMemoryEntry,
) !void {
    var current_base = ram.base;
    const ram_end = ram.end();
    while (current_base < ram_end) {
        var next_step = ram_end;
        var skip = false;
        clipExclusion(current_base, hv.base, hv.end(), &next_step, &skip);
        clipExclusion(current_base, meta.base, meta.end(), &next_step, &skip);
        if (rootvm) |rvm| {
            clipExclusion(current_base, rvm.base, rvm.end(), &next_step, &skip);
        }
        for (reserved) |res| {
            const max_u = @as(u64, std.math.maxInt(usize));
            const r_base: usize = @intCast(@min(res.address, max_u));
            const r_end64 =
                std.math.add(u64, res.address, res.size) catch max_u;
            const r_end: usize = @intCast(@min(r_end64, max_u));
            clipExclusion(current_base, r_base, r_end, &next_step, &skip);
        }
        if (!skip) {
            var addr = (current_base + PageSize - 1) & ~(PageSize - 1);
            while (addr < next_step) {
                var order: u8 = 0;
                while (order + 1 < max_order) {
                    const next_sz =
                        (@as(usize, 1) << @intCast(order + 1)) * PageSize;
                    if (addr % next_sz == 0 and addr + next_sz <= next_step) {
                        order += 1;
                    } else break;
                }
                pushFreeBlock(addr, order);
                addr += (@as(usize, 1) << @intCast(order)) * PageSize;
            }
        }
        current_base = next_step;
    }
}
fn getPageDescriptor(addr: usize) *PageDescriptor {
    if (!isManaged(addr)) @panic("Physical address out of range");
    const idx = (addr - phys_mem_state.ram_base) / PageSize;
    return &phys_mem_state.metadata[idx];
}
fn pushFreeBlock(addr: usize, order: u8) void {
    const lock_ms = phys_mem_state.lock.lock();
    defer phys_mem_state.lock.unlock(lock_ms);
    pushFreeBlockLocked(addr, order);
}

pub fn allocPageSelection(order: u8) !usize {
    const lock_ms = phys_mem_state.lock.lock();
    defer phys_mem_state.lock.unlock(lock_ms);
    var o = order;
    while (o < max_order) : (o += 1) {
        if (phys_mem_state.free_lists[o]) |node| {
            phys_mem_state.free_lists[o] = node.next;
            phys_mem_state.free_pages -= (@as(usize, 1) << @intCast(o));
            const addr = @intFromPtr(node);
            while (o > order) {
                o -= 1;
                const buddy = addr + (@as(usize, 1) << @intCast(o)) * PageSize;
                pushFreeBlockLocked(buddy, o);
            }
            const desc = getPageDescriptor(addr);
            desc.flags &= ~PageFlags.free;
            desc.order = order;
            desc.refcount = 1;
            const block_bytes = (@as(usize, 1) << @intCast(order)) * PageSize;
            @memset(@as([*]u8, @ptrFromInt(addr))[0..block_bytes], 0);
            return addr;
        }
    }
    return PhysMemError.OutOfMemory;
}

pub fn allocPage() !usize {
    return try allocPageSelection(0);
}
pub fn freePage(addr: usize) void {
    decrementPageRef(addr);
}
pub fn getPageRef(addr: usize) u32 {
    return @atomicLoad(u32, &getPageDescriptor(addr).refcount, .seq_cst);
}
pub fn incrementPageRef(addr: usize) void {
    _ = @atomicRmw(u32, &getPageDescriptor(addr).refcount, .Add, 1, .seq_cst);
}
pub fn decrementPageRef(addr: usize) void {
    const desc = getPageDescriptor(addr);
    const old = @atomicRmw(u32, &desc.refcount, .Sub, 1, .seq_cst);
    if (old == 0) @panic("Physical memory reference count underflow");
    if (old == 1) {
        const lock_ms = phys_mem_state.lock.lock();
        defer phys_mem_state.lock.unlock(lock_ms);
        pushFreeBlockLocked(addr, desc.order);
    }
}

pub fn getTotalRamBytes() usize {
    return phys_mem_state.total_pages * PageSize;
}
pub fn getFreeRamBytes() usize {
    return phys_mem_state.free_pages * PageSize;
}
pub fn getHvRegion() Region {
    return phys_mem_state.hv_region;
}
pub fn getRamBase() usize {
    return phys_mem_state.regions[0].base;
}
pub fn isManaged(addr: usize) bool {
    if (addr < phys_mem_state.ram_base) return false;
    return (addr - phys_mem_state.ram_base) < phys_mem_state.ram_size;
}
pub fn isMmio(base: usize, size: usize) bool {
    return !isHypervisorMemory(base, size) and !isRam(base, size);
}
pub fn isHypervisorMemory(base: usize, size: usize) bool {
    if (size == 0) return false;
    const end = std.math.add(usize, base, size) catch std.math.maxInt(usize);
    return base < phys_mem_state.hv_region.end() and
        end > phys_mem_state.hv_region.base;
}
pub fn discoverRegions(device_tree: *dt.DeviceTree) !void {
    const lock_ms = phys_mem_state.lock.lock();
    defer phys_mem_state.lock.unlock(lock_ms);
    try populateRegionsLocked(device_tree);
}
pub fn getDiscoveredRamBytes() usize {
    const lock_ms = phys_mem_state.lock.lock();
    defer phys_mem_state.lock.unlock(lock_ms);
    var total: usize = 0;
    for (0..phys_mem_state.region_count) |i| {
        total = std.math.add(usize, total, phys_mem_state.regions[i].size) catch
            std.math.maxInt(usize);
    }
    return total;
}

pub fn findContiguousRegion(size: usize) !Region {
    const lock_ms = phys_mem_state.lock.lock();
    defer phys_mem_state.lock.unlock(lock_ms);
    if (phys_mem_state.region_count == 0) return PhysMemError.NoRAMFound;
    for (0..phys_mem_state.region_count) |i| {
        const reg = phys_mem_state.regions[i];
        if (reg.size < size) continue;
        if (reg.end() >= size) {
            const top_base = (reg.end() - size) & ~(PageSize - 1);
            if (top_base >= reg.base and !isHypervisorMemory(top_base, size)) {
                return .{ .base = top_base, .size = size };
            }
        }
        var base = (reg.base + PageSize - 1) & ~(PageSize - 1);
        while (true) {
            const end = std.math.add(usize, base, size) catch break;
            if (end > reg.end()) break;
            if (!isHypervisorMemory(base, size)) {
                return .{ .base = base, .size = size };
            }
            base = std.math.add(usize, base, PageSize) catch break;
        }
    }
    return PhysMemError.OutOfMemory;
}
pub fn isRam(base: usize, size: usize) bool {
    if (size == 0) return false;
    const end = std.math.add(usize, base, size) catch return false;
    for (0..phys_mem_state.region_count) |i| {
        const reg = phys_mem_state.regions[i];
        if (base >= reg.base and end <= reg.end()) return true;
    }
    return false;
}
fn pushFreeBlockLocked(addr: usize, order: u8) void {
    var current_addr = addr;
    var o = order;
    while (o + 1 < max_order) {
        const block_size = (@as(usize, 1) << @intCast(o)) * PageSize;
        const buddy_addr = current_addr ^ block_size;
        const ram_end = phys_mem_state.ram_base + phys_mem_state.ram_size;
        if (buddy_addr < phys_mem_state.ram_base or buddy_addr >= ram_end or
            isHypervisorMemory(buddy_addr, block_size)) break;
        const buddy_desc = getPageDescriptor(buddy_addr);
        if (buddy_desc.flags & PageFlags.free == 0 or buddy_desc.order != o) {
            break;
        }
        removeFromFreeList(buddy_addr, o);
        current_addr = @min(current_addr, buddy_addr);
        o += 1;
    }
    const desc = getPageDescriptor(current_addr);
    desc.flags |= PageFlags.free;
    desc.order = o;
    const node: *PageStackNode = @ptrFromInt(current_addr);
    node.next = phys_mem_state.free_lists[o];
    phys_mem_state.free_lists[o] = node;
    phys_mem_state.free_pages += (@as(usize, 1) << @intCast(o));
}

fn removeFromFreeList(addr: usize, order: u8) void {
    var prev: ?*PageStackNode = null;
    var current = phys_mem_state.free_lists[order];
    while (current) |node| : ({
        prev = node;
        current = node.next;
    }) {
        if (@intFromPtr(node) == addr) {
            if (prev) |p|
                p.next = node.next
            else
                phys_mem_state.free_lists[order] = node.next;
            phys_mem_state.free_pages -= (@as(usize, 1) << @intCast(order));
            getPageDescriptor(addr).flags &= ~PageFlags.free;
            return;
        }
    }
}

test "buddy allocator, refcounting, overflow safety, and discoverRegions" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var phys_test = try initForTest(alloc, 4);
    defer phys_test.deinit();
    try testing.expectEqual(@as(usize, 4), phys_mem_state.free_pages);
    try testing.expect(phys_mem_state.free_lists[2] != null);
    const p1 = try allocPageSelection(2);
    try testing.expectEqual(phys_mem_state.ram_base, p1);
    try testing.expectError(PhysMemError.OutOfMemory, allocPageSelection(0));
    incrementPageRef(p1);
    decrementPageRef(p1);
    try testing.expectEqual(@as(usize, 0), phys_mem_state.free_pages);
    freePage(p1);
    try testing.expectEqual(@as(usize, 4), phys_mem_state.free_pages);
    const hv_base = getHvRegion().base;
    const max_u = std.math.maxInt(usize);
    try testing.expect(isHypervisorMemory(hv_base, 0x1000));
    try testing.expect(isHypervisorMemory(hv_base - 0x1000, 0x2000));
    try testing.expect(isHypervisorMemory(hv_base, max_u - 10));
    try testing.expect(!isHypervisorMemory(0x90000000, 0x1000));
    try testing.expect(!isHypervisorMemory(hv_base, 0));
    try testing.expect(!isRam(max_u - 0x100, 0x200));
    try testing.expect(!isRam(phys_mem_state.ram_base, max_u));
    try testing.expect(!isManaged(0) and !isManaged(max_u));
    try testing.expect(isManaged(phys_mem_state.ram_base));
    const tree = try dt.DeviceTree.init(alloc);
    defer tree.deinit();
    const Prop = dt.DeviceTreeProperty;
    try tree.editProperty("/", "#address-cells", try Prop.fromU32(alloc, 2));
    try tree.editProperty("/", "#size-cells", try Prop.fromU32(alloc, 2));
    const mem_txt = try Prop.fromText(alloc, "memory");
    try tree.editProperty("/memory@80000000", "device_type", mem_txt);
    const reg_v = try Prop.fromMultiU64(alloc, &.{ 0x80000000, 0x40000000 });
    try tree.editProperty("/memory@80000000", "reg", reg_v);
    try discoverRegions(tree);
    const expected_size = (test_hv_end - test_hv_start) + riscv.CPU_SLAB_SIZE;
    try testing.expectEqual(expected_size, getHvRegion().size);
    const reg = try findContiguousRegion(2 * 1024 * 1024);
    try testing.expect(!isHypervisorMemory(reg.base, reg.size));
}
