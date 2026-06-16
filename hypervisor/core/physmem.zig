// Physical memory management routines
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const atomic = @import("atomic.zig");
const riscv = @import("riscv.zig");
const debug = @import("debug.zig");
const dt = @import("dt.zig");

const builtin = @import("builtin");

// Hypervisor linker symbols
extern const __hypervisor_start: u8;
extern const __hypervisor_end: u8;

// Mock linker symbols for tests
const test_hv_start_val: u8 = 0;
const test_hv_end_val: u8 = 0;
var test_hv_start = if (builtin.is_test) @as(usize, 0x80000000) else 0;
var test_hv_end = if (builtin.is_test) @as(usize, 0x80010000) else 0;

pub const PageSize: usize = 0x1000; // 4KB pages
const PageShift: u6 = 12;

pub const PhysMemError = error{
    NoRAMFound,
    OutOfMemory,
    RegionOverlap,
};

// Represents a contiguous region of physical memory
pub const Region = struct {
    base: usize,
    size: usize,

    pub fn end(self: Region) usize {
        return self.base + self.size;
    }
};

// Flags for PageDescriptor
pub const PageFlags = struct {
    pub const free: u8 = 1 << 0;
    pub const cow: u8 = 1 << 1;
};

// Metadata for a single 4KB physical page
pub const PageDescriptor = struct {
    refcount: u32,
    flags: u8,
    order: u8, // For buddy allocator
};

// Global physical memory state
const PhysMemState = struct {
    has_h_extension: bool,
    free_lists: [max_order]?*PageStackNode,
    regions: [max_regions]Region,
    region_count: usize,
    ram_base: usize,
    ram_size: usize,
    total_pages: usize,
    free_pages: usize,
    metadata: []PageDescriptor,
    hv_region: Region,
    lock: atomic.NamedSpinLock,
};

const max_regions = 16;
pub const max_order = 12; // Up to 2^11 pages = 16MB contiguous. Increase if needed for larger Superpages.

// A node in the LIFO page stack, stored at the start of the free page itself
const PageStackNode = struct {
    next: ?*PageStackNode,
};

const init_free_lists: [max_order]?*PageStackNode = @import("std").mem.zeroes([max_order]?*PageStackNode);

var phys_mem_state = PhysMemState{
    .has_h_extension = false,
    .free_lists = init_free_lists,
    .regions = undefined,
    .region_count = 0,
    .ram_base = 0,
    .ram_size = 0,
    .total_pages = 0,
    .free_pages = 0,
    .metadata = &.{},
    .hv_region = .{ .base = 0, .size = 0 },
    .lock = atomic.NamedSpinLock.init("Physical memory lock"),
};

pub const TestState = struct {
    allocator: std.mem.Allocator,
    metadata: []PageDescriptor,
    ram: []u8,

    pub fn deinit(self: *TestState) void {
        self.allocator.free(self.metadata);
        self.allocator.free(self.ram);
        phys_mem_state.metadata = &.{};
        phys_mem_state.ram_size = 0;
    }
};

pub fn initForTest(allocator: std.mem.Allocator, num_pages: usize) !TestState {
    const metadata = try allocator.alloc(PageDescriptor, num_pages);
    @memset(std.mem.sliceAsBytes(metadata), 0);
    const ram = try allocator.alloc(u8, num_pages * PageSize);

    const lock_ms = phys_mem_state.lock.lock();
    defer phys_mem_state.lock.unlock(lock_ms);

    phys_mem_state.has_h_extension = true;
    phys_mem_state.free_lists = init_free_lists;
    phys_mem_state.ram_base = @intFromPtr(ram.ptr);
    phys_mem_state.ram_size = num_pages * PageSize;
    phys_mem_state.total_pages = num_pages;
    phys_mem_state.free_pages = 0;
    phys_mem_state.metadata = metadata;

    var addr = phys_mem_state.ram_base;
    for (0..num_pages) |_| {
        pushFreeBlockLocked(addr, 0);
        addr += PageSize;
    }

    // Register this RAM region so isRam() works in tests
    phys_mem_state.region_count = 1;
    phys_mem_state.regions[0] = .{ .base = phys_mem_state.ram_base, .size = phys_mem_state.ram_size };

    return TestState{ .allocator = allocator, .metadata = metadata, .ram = ram };
}

// Initialize physical memory management using the device tree
pub fn init(device_tree: *dt.DeviceTree, rootvm_region: ?Region) !void {
    phys_mem_state.has_h_extension = riscv.hasHExtension();

    // Calculate hypervisor footprint, including per-CPU slots (each 1MB)
    const cpu_slab_size = 1024 * 1024;
    const num_cpus = if (builtin.is_test) 1 else device_tree.countCpus();
    const hv_start = if (builtin.is_test) test_hv_start else @intFromPtr(&__hypervisor_start);
    const hv_static_end = if (builtin.is_test) test_hv_end else @intFromPtr(&__hypervisor_end);
    const hv_end = hv_static_end + (num_cpus * cpu_slab_size);
    const hv_region = Region{ .base = hv_start, .size = hv_end - hv_start };
    phys_mem_state.hv_region = hv_region;

    debug.printf("Hypervisor HPA footprint 0x{x} - 0x{x} ({} KB)\n", .{ hv_start, hv_end, hv_region.size / 1024 });

    if (rootvm_region) |rvm| {
        debug.printf("Root VM HPA reservation 0x{x} - 0x{x} ({} MB)\n", .{ rvm.base, rvm.end(), rvm.size / (1024 * 1024) });
    }

    // First pass to find the range of RAM we need to track
    var min_ram: usize = 0xFFFFFFFFFFFFFFFF;
    var max_ram: usize = 0;

    var it = device_tree.iter("/", 1);
    while (it.next()) |path| {
        if (std.mem.startsWith(u8, std.fs.path.basename(path), "memory@")) {
            const reg_prop = device_tree.getProperty(path, "reg") catch continue;
            const cells = device_tree.getAddressSizeCells("/");
            const data = reg_prop.data orelse continue;
            const cell_size = 4;
            const entry_size = (cells.address + cells.size) * cell_size;

            var i: usize = 0;
            while (i + entry_size <= data.len) : (i += entry_size) {
                const base = try readCells(data[i..], cells.address);
                const size = try readCells(data[i + cells.address * cell_size ..], cells.size);
                if (base < min_ram) min_ram = @intCast(base);
                if (base + size > max_ram) max_ram = @intCast(base + size);
            }
        }
    }

    if (max_ram == 0 and !builtin.is_test) return PhysMemError.NoRAMFound;

    phys_mem_state.ram_base = min_ram;
    phys_mem_state.ram_size = max_ram - min_ram;
    phys_mem_state.total_pages = phys_mem_state.ram_size / PageSize;
    // phys_mem_state.region_count is already populated by discoverRegions

    // Region discovery is skipped as it should be called via discoverRegions() first

    // Allocate and reserve space for page metadata
    const metadata_size = phys_mem_state.total_pages * @sizeOf(PageDescriptor);
    debug.printf("Allocating {} KB for page metadata\n", .{metadata_size / 1024});

    // For now, we take the metadata from the very beginning of the first free block.
    // We'll need a way to ensure this is reserved.
    // Actually, let's find the first free block now.
    var metadata_phys: usize = 0;
    it = device_tree.iter("/", 1);
    find_metadata_block: while (it.next()) |path| {
        if (std.mem.startsWith(u8, std.fs.path.basename(path), "memory@")) {
            const reg_prop = device_tree.getProperty(path, "reg") catch continue;
            const cells = device_tree.getAddressSizeCells("/");
            const data = reg_prop.data orelse continue;
            const entry_size = (cells.address + cells.size) * 4;
            var i: usize = 0;
            while (i + entry_size <= data.len) : (i += entry_size) {
                const base = try readCells(data[i..], cells.address);
                const size = try readCells(data[i + cells.address * 4 ..], cells.size);
                const reg = Region{ .base = @intCast(base), .size = @intCast(size) };

                // metadata must be outside hypervisor footprint
                if (reg.base < hv_region.base) {
                    if (hv_region.base - reg.base >= metadata_size) {
                        metadata_phys = reg.base;
                        break :find_metadata_block;
                    }
                } else if (reg.end() > hv_region.end()) {
                    const free_start = @max(reg.base, hv_region.end());
                    if (reg.end() - free_start >= metadata_size) {
                        metadata_phys = free_start;
                        break :find_metadata_block;
                    }
                }
            }
        }
    }

    if (metadata_phys == 0 and !builtin.is_test) return PhysMemError.OutOfMemory;

    // Initialize metadata slice
    if (!builtin.is_test) {
        phys_mem_state.metadata = @as([*]PageDescriptor, @ptrFromInt(metadata_phys))[0..phys_mem_state.total_pages];
        @memset(std.mem.sliceAsBytes(phys_mem_state.metadata), 0);
    }

    const metadata_region = Region{ .base = metadata_phys, .size = metadata_size };

    // econd pass: Add RAM chunks to buddy allocator, skipping HV and metadata
    it = device_tree.iter("/", 1);
    while (it.next()) |path| {
        if (std.mem.startsWith(u8, std.fs.path.basename(path), "memory@")) {
            const reg_prop = device_tree.getProperty(path, "reg") catch continue;
            const cells = device_tree.getAddressSizeCells("/");
            const data = reg_prop.data orelse continue;
            const cell_size = 4;
            const entry_size = (cells.address + cells.size) * cell_size;

            var i: usize = 0;
            while (i + entry_size <= data.len) : (i += entry_size) {
                const base = try readCells(data[i..], cells.address);
                const size = try readCells(data[i + cells.address * cell_size ..], cells.size);

                // Add RAM block, now also skipping metadata and rootvm
                try addRamBlock(Region{ .base = @intCast(base), .size = @intCast(size) }, hv_region, metadata_region, rootvm_region, device_tree.reserved_memory[0..device_tree.reserved_count]);
            }
        }
    }

    debug.printf("Physical memory initialized with {} free pages ({} MB total reachable)\n", .{ phys_mem_state.free_pages, (phys_mem_state.total_pages * PageSize) / (1024 * 1024) });
}

fn readCells(data: []const u8, count: usize) !u64 {
    if (count == 1) return @as(u64, @as(u32, data[0]) << 24 | @as(u32, data[1]) << 16 | @as(u32, data[2]) << 8 | @as(u32, data[3]));
    if (count == 2) {
        const high = @as(u64, @as(u32, data[0]) << 24 | @as(u32, data[1]) << 16 | @as(u32, data[2]) << 8 | @as(u32, data[3]));
        const low = @as(u64, @as(u32, data[4]) << 24 | @as(u32, data[5]) << 16 | @as(u32, data[6]) << 8 | @as(u32, data[7]));
        return (high << 32) | low;
    }
    return error.WidthUnsupported;
}

fn addRamBlock(ram: Region, hv: Region, metadata: Region, rootvm: ?Region, reserved: []dt.ReservedMemoryEntry) !void {
    var current_base = ram.base;
    const ram_end = ram.end();

    while (current_base < ram_end) {
        var next_step = ram_end;
        var skip = false;

        // Check if current_base falls into hypervisor region
        if (current_base >= hv.base and current_base < hv.end()) {
            next_step = hv.end();
            skip = true;
        } else if (hv.base >= current_base and hv.base < next_step) {
            next_step = hv.base;
        }

        // Check if current_base falls into metadata region
        if (current_base >= metadata.base and current_base < metadata.end()) {
            if (metadata.end() > next_step or !skip) {
                next_step = metadata.end();
                skip = true;
            }
        } else if (metadata.base >= current_base and metadata.base < next_step) {
            next_step = metadata.base;
        }

        // Check rootvm reservation
        if (rootvm) |rvm| {
            if (current_base >= rvm.base and current_base < rvm.end()) {
                if (rvm.end() > next_step or !skip) {
                    next_step = rvm.end();
                    skip = true;
                }
            } else if (rvm.base >= current_base and rvm.base < next_step) {
                next_step = rvm.base;
            }
        }

        // Check reserved memory regions
        for (reserved) |res| {
            const res_end = res.address + res.size;
            if (current_base >= res.address and current_base < res_end) {
                if (res_end > next_step or !skip) {
                    next_step = @intCast(res_end);
                    skip = true;
                }
            } else if (res.address >= current_base and res.address < next_step) {
                next_step = @intCast(res.address);
            }
        }

        if (!skip) {
            // This is reachable, usable RAM.
            // Break it into aligned buddy blocks and add them to the free lists.
            var addr = current_base;
            // Align up to page boundary
            addr = (addr + PageSize - 1) & ~(PageSize - 1);

            while (addr < next_step) {
                // Find the largest power-of-two block that fits
                var order: u8 = 0;
                while (order + 1 < max_order) {
                    const block_size = (@as(usize, 1) << @intCast(order + 1)) * PageSize;
                    if (addr % block_size == 0 and addr + block_size <= next_step) {
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
    if (addr < phys_mem_state.ram_base or addr >= phys_mem_state.ram_base + phys_mem_state.ram_size) {
        debug.printf("HPA 0x{x} out of range [0x{x}-0x{x})\n", .{ addr, phys_mem_state.ram_base, phys_mem_state.ram_base + phys_mem_state.ram_size });
        @panic("Physical address out of range");
    }
    const index = (addr - phys_mem_state.ram_base) / PageSize;
    return &phys_mem_state.metadata[index];
}

fn pushFreeBlock(addr: usize, order: u8) void {
    const lock_ms = phys_mem_state.lock.lock();
    defer phys_mem_state.lock.unlock(lock_ms);
    pushFreeBlockLocked(addr, order);
}

// Allocate power-of-two naturally aligned blocks.
// order 0 = 4KB, 1 = 8KB, 2 = 16KB, etc.
pub fn allocPageSelection(order: u8) !usize {
    const lock_ms = phys_mem_state.lock.lock();
    defer phys_mem_state.lock.unlock(lock_ms);

    var o = order;
    while (o < max_order) : (o += 1) {
        if (phys_mem_state.free_lists[o]) |node| {
            // Found a block!
            phys_mem_state.free_lists[o] = node.next;
            phys_mem_state.free_pages -= (@as(usize, 1) << @intCast(o));
            const addr = @intFromPtr(node);

            // Split it down to the requested order
            while (o > order) {
                o -= 1;
                const buddy_addr = addr + (@as(usize, 1) << @intCast(o)) * PageSize;
                pushFreeBlockLocked(buddy_addr, o);
            }

            // Mark the allocated block
            const desc = getPageDescriptor(addr);
            desc.flags &= ~PageFlags.free;
            desc.order = order;
            desc.refcount = 1;

            @memset(@as([*]u8, @ptrFromInt(addr))[0 .. (@as(usize, 1) << @intCast(order)) * PageSize], 0);
            return addr;
        }
    }
    return PhysMemError.OutOfMemory;
}

// Allocate a 4KB physical page. Returns physical address.
pub fn allocPage() !usize {
    return try allocPageSelection(0);
}

// Free a previously allocated physical page or block.
// Buddy merging is performed to coalese free memory.
pub fn freePage(addr: usize) void {
    decrementPageRef(addr);
}

// Increment reference count of a page. Used for Copy-on-Write sharing.
pub fn incrementPageRef(addr: usize) void {
    const desc = getPageDescriptor(addr);
    _ = @atomicRmw(u32, &desc.refcount, .Add, 1, .seq_cst);
}

// Decrement reference count of a page. If it reaches 0, free the page.
pub fn decrementPageRef(addr: usize) void {
    const desc = getPageDescriptor(addr);
    const old = @atomicRmw(u32, &desc.refcount, .Sub, 1, .seq_cst);
    if (old == 1) {
        const lock_ms = phys_mem_state.lock.lock();
        defer phys_mem_state.lock.unlock(lock_ms);
        pushFreeBlockLocked(addr, desc.order);
    }
}

pub fn isHypervisorMemory(base: usize, size: usize) bool {
    const end = base + size;
    const hv_start = phys_mem_state.hv_region.base;
    const hv_end = phys_mem_state.hv_region.end();

    // Check for overlap
    return (base < hv_end and end > hv_start);
}

// Discover RAM regions from the device tree without initializing the allocator.
pub fn discoverRegions(device_tree: *dt.DeviceTree) !void {
    const lock_ms = phys_mem_state.lock.lock();
    defer phys_mem_state.lock.unlock(lock_ms);

    phys_mem_state.region_count = 0;
    var it = device_tree.iter("/", 1);
    while (it.next()) |path| {
        if (std.mem.startsWith(u8, std.fs.path.basename(path), "memory@")) {
            const reg_prop = device_tree.getProperty(path, "reg") catch continue;
            const cells = device_tree.getAddressSizeCells("/");
            const data = reg_prop.data orelse continue;
            const cell_size = 4;
            const entry_size = (cells.address + cells.size) * cell_size;

            var j: usize = 0;
            while (j + entry_size <= data.len) : (j += entry_size) {
                const base = try readCells(data[j..], cells.address);
                const size = try readCells(data[j + cells.address * cell_size ..], cells.size);
                if (phys_mem_state.region_count < max_regions) {
                    phys_mem_state.regions[phys_mem_state.region_count] = .{ .base = @intCast(base), .size = @intCast(size) };
                    phys_mem_state.region_count += 1;
                }
            }
        }
    }
}

// Find a contiguous region of RAM of the requested size that doesn't overlap with the hypervisor.
pub fn findContiguousRegion(size: usize) !Region {
    const lock_ms = phys_mem_state.lock.lock();
    defer phys_mem_state.lock.unlock(lock_ms);

    if (phys_mem_state.region_count == 0) return PhysMemError.NoRAMFound;
    for (0..phys_mem_state.region_count) |i| {
        const reg = phys_mem_state.regions[i];
        if (reg.size < size) continue;

        // Try at the start of the region
        var base = reg.base;
        // Align to page size
        base = (base + PageSize - 1) & ~(PageSize - 1);

        while (base + size <= reg.end()) {
            const candidate = Region{ .base = base, .size = size };

            // Ensure no overlap with hypervisor footprint
            if (!isHypervisorMemory(candidate.base, candidate.size)) {
                // Also check if we're hitting the metadata (which is at the start of a free block)
                // For simplicity, we just check if it's within the first 128MB of the hypervisor's base
                // or similar. In a real system, we'd check against metadata_region saved in init.
                // But since we are looking for a LARGE block, we can just search from the END backwards.

                // Let's try from the end of the region instead to be safer
                // about metadata and hypervisor which are usually at the low end.
                const top_base = (reg.end() - size) & ~(PageSize - 1);
                if (!isHypervisorMemory(top_base, size)) {
                    return Region{ .base = top_base, .size = size };
                }
            }
            base += PageSize;
            if (base > reg.end()) break;
        }
    }

    return PhysMemError.OutOfMemory;
}

pub fn isRam(base: usize, size: usize) bool {
    const end = base + size;
    for (0..phys_mem_state.region_count) |i| {
        const reg = phys_mem_state.regions[i];
        if (base >= reg.base and end <= reg.end()) return true;
    }
    return false;
}

/// Returns true if the address is within the host physical RAM range managed by
/// the hypervisor's metadata descriptors. Static reservations (like the Root VM)
/// may be within 'isRam' but outside 'isManaged'.
pub fn isManaged(addr: usize) bool {
    return (addr >= phys_mem_state.ram_base and addr < phys_mem_state.ram_base + phys_mem_state.ram_size);
}

pub fn isMmio(base: usize, size: usize) bool {
    if (isHypervisorMemory(base, size)) return false;
    if (isRam(base, size)) return false;
    // If it's not RAM and not HV, we treat it as potentially MMIO (device space)
    return true;
}

fn pushFreeBlockLocked(addr: usize, order: u8) void {
    var current_addr = addr;
    var o = order;

    // Try to merge with buddy blocks
    while (o + 1 < max_order) {
        const block_size = (@as(usize, 1) << @intCast(o)) * PageSize;
        const buddy_addr = current_addr ^ block_size;

        // Check buddy is within our managed RAM
        if (buddy_addr < phys_mem_state.ram_base or buddy_addr >= phys_mem_state.ram_base + phys_mem_state.ram_size) break;

        // Never merge across reserved region boundaries (hypervisor, metadata, rootvm).
        if (isHypervisorMemory(buddy_addr, block_size)) break;

        const buddy_desc = getPageDescriptor(buddy_addr);
        // Only merge if buddy is free and of the same order
        if (buddy_desc.flags & PageFlags.free == 0 or buddy_desc.order != o) break;

        // Merge buddies
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
    while (current) |node| {
        if (@intFromPtr(node) == addr) {
            if (prev) |p| {
                p.next = node.next;
            } else {
                phys_mem_state.free_lists[order] = node.next;
            }
            phys_mem_state.free_pages -= (@as(usize, 1) << @intCast(order));

            // Mark the block as no longer free at this order
            const desc = getPageDescriptor(addr);
            desc.flags &= ~PageFlags.free;
            return;
        }
        prev = node;
        current = node.next;
    }
}

test "buddy allocator and refcounting" {
    const testing = std.testing;

    // Reset state for testing
    var test_metadata: [4]PageDescriptor = undefined;
    phys_mem_state = PhysMemState{
        .has_h_extension = true,
        .free_lists = init_free_lists,
        .regions = undefined,
        .region_count = 0,
        .ram_base = 0,
        .ram_size = 4 * PageSize,
        .total_pages = 4,
        .free_pages = 0,
        .metadata = &test_metadata,
        .hv_region = .{ .base = 0x100000000, .size = 0 }, // Far away from test RAM
        .lock = atomic.NamedSpinLock.init("Test lock"),
    };
    @memset(std.mem.sliceAsBytes(phys_mem_state.metadata), 0);

    // Use a small local buffer as "physical memory"
    var test_pages_buf: [4 * PageSize]u8 align(16 * PageSize) = undefined; // Align for buddy orders
    const base = @intFromPtr(&test_pages_buf);
    phys_mem_state.ram_base = base;

    // Add 4 individual pages of order 0
    pushFreeBlock(base, 0);
    pushFreeBlock(base + PageSize, 0);
    pushFreeBlock(base + 2 * PageSize, 0);
    pushFreeBlock(base + 3 * PageSize, 0);

    // After merging, we should have 1 block of order 2
    try testing.expectEqual(@as(usize, 4), phys_mem_state.free_pages);
    try testing.expect(phys_mem_state.free_lists[0] == null);
    try testing.expect(phys_mem_state.free_lists[1] == null);
    try testing.expect(phys_mem_state.free_lists[2] != null);

    // Allocate 16KB (order 2)
    const p1 = try allocPageSelection(2);
    try testing.expectEqual(base, p1);
    try testing.expectEqual(@as(usize, 0), phys_mem_state.free_pages);

    // Allocate order 0 (should fail)
    try testing.expectError(PhysMemError.OutOfMemory, allocPageSelection(0));

    // Refcount test
    incrementPageRef(p1);
    decrementPageRef(p1);
    try testing.expectEqual(@as(usize, 0), phys_mem_state.free_pages); // Should still be 1 (base ref was 1)

    // Force free for test
    freePage(p1);
    try testing.expectEqual(@as(usize, 4), phys_mem_state.free_pages);
}
