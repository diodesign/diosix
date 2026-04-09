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

// Global physical memory state
const PhysMemState = struct {
    has_h_extension: bool,
    page_stack_top: ?*PageStackNode,
    regions: [max_regions]Region,
    region_count: usize,
    total_pages: usize,
    free_pages: usize,
    lock: atomic.NamedSpinLock,
};

const max_regions = 16;

// A node in the LIFO page stack, stored at the start of the free page itself
const PageStackNode = struct {
    next: ?*PageStackNode,
};

var phys_mem_state = PhysMemState{
    .has_h_extension = false,
    .page_stack_top = null,
    .regions = undefined,
    .region_count = 0,
    .total_pages = 0,
    .free_pages = 0,
    .lock = atomic.NamedSpinLock.init("Physical memory lock"),
};

// Initialize physical memory management using the device tree
pub fn init(device_tree: *dt.DeviceTree) !void {
    phys_mem_state.has_h_extension = riscv.hasHExtension();

    debug.printf("PhysMem: H-extension {s}\n", .{if (phys_mem_state.has_h_extension) "detected" else "NOT detected"});

    // Calculate hypervisor footprint, including per-CPU slots (each 1MB)
    const cpu_slab_size = 1024 * 1024;
    const num_cpus = if (builtin.is_test) 1 else device_tree.countCpus();
    const hv_start = if (builtin.is_test) test_hv_start else @intFromPtr(&__hypervisor_start);
    const hv_static_end = if (builtin.is_test) test_hv_end else @intFromPtr(&__hypervisor_end);
    const hv_end = hv_static_end + (num_cpus * cpu_slab_size);
    const hv_region = Region{ .base = hv_start, .size = hv_end - hv_start };

    debug.printf("PhysMem: HV footprint 0x{x} - 0x{x} ({} KB)\n", .{ hv_start, hv_end, hv_region.size / 1024 });

    // Look for memory nodes in the device tree
    var it = device_tree.iter("/", 1);
    var found_ram = false;
    while (it.next()) |path| {
        if (std.mem.startsWith(u8, std.fs.path.basename(path), "memory@")) {
            const reg_prop = device_tree.getProperty(path, "reg") catch continue;
            const cells = device_tree.getAddressSizeCells("/"); // Root usually defines DRAM cells

            // reg is a list of (address, size) pairs
            const data = reg_prop.data orelse continue;
            const cell_size = 4;
            const entry_size = (cells.address + cells.size) * cell_size;

            var i: usize = 0;
            while (i + entry_size <= data.len) : (i += entry_size) {
                const base = try readCells(data[i..], cells.address);
                const size = try readCells(data[i + cells.address * cell_size ..], cells.size);

                try addRamBlock(Region{ .base = @intCast(base), .size = @intCast(size) }, hv_region, device_tree.reserved_memory[0..device_tree.reserved_count]);
                found_ram = true;
            }
        }
    }

    if (!found_ram and !builtin.is_test) return PhysMemError.NoRAMFound;

    debug.printf("PhysMem: Initialized with {} free pages ({} MB total reachable)\n", .{ phys_mem_state.free_pages, (phys_mem_state.total_pages * PageSize) / (1024 * 1024) });
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

fn addRamBlock(ram: Region, hv: Region, reserved: []dt.ReservedMemoryEntry) !void {
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
            // If H-extension is present, break it into pages and add to stack.
            // If not, we'll keep it as a large region (future use).
            if (phys_mem_state.has_h_extension) {
                var addr = current_base;
                // Align up to page boundary
                addr = (addr + PageSize - 1) & ~(PageSize - 1);
                while (addr + PageSize <= next_step) : (addr += PageSize) {
                    pushFreePage(addr);
                    phys_mem_state.total_pages += 1;
                }
            } else {
                if (phys_mem_state.region_count < max_regions) {
                    phys_mem_state.regions[phys_mem_state.region_count] = Region{ .base = current_base, .size = next_step - current_base };
                    phys_mem_state.region_count += 1;
                }
                phys_mem_state.total_pages += (next_step - current_base) / PageSize;
            }
        }
        current_base = next_step;
    }
}

fn pushFreePage(addr: usize) void {
    const node: *PageStackNode = @ptrFromInt(addr);
    node.next = phys_mem_state.page_stack_top;
    phys_mem_state.page_stack_top = node;
    phys_mem_state.free_pages += 1;
}

// Allocate a 4KB physical page. Returns physical address.
pub fn allocPage() !usize {
    phys_mem_state.lock.lock();
    defer phys_mem_state.lock.unlock();

    if (phys_mem_state.page_stack_top) |node| {
        phys_mem_state.page_stack_top = node.next;
        phys_mem_state.free_pages -= 1;
        const addr = @intFromPtr(node);
        // Zero the page
        if (!builtin.is_test) {
            @memset(@as(*[PageSize]u8, @ptrFromInt(addr)), 0);
        }
        return addr;
    }
    return PhysMemError.OutOfMemory;
}

// Free a 4KB physical page.
pub fn freePage(addr: usize) void {
    phys_mem_state.lock.lock();
    defer phys_mem_state.lock.unlock();
    pushFreePage(addr);
}

test "physical memory page allocation" {
    const testing = std.testing;

    // Reset state for testing
    phys_mem_state = PhysMemState{
        .has_h_extension = true,
        .page_stack_top = null,
        .regions = undefined,
        .region_count = 0,
        .total_pages = 0,
        .free_pages = 0,
        .lock = atomic.NamedSpinLock.init("Test lock"),
    };

    // Use a small local buffer as "physical memory"
    var test_pages: [4 * PageSize]u8 align(PageSize) = undefined;
    const base = @intFromPtr(&test_pages);

    // Push pages onto stack
    pushFreePage(base);
    pushFreePage(base + PageSize);
    phys_mem_state.total_pages = 2;

    try testing.expectEqual(@as(usize, 2), phys_mem_state.free_pages);
    try testing.expectEqual(@as(usize, 2), phys_mem_state.total_pages);

    // Allocate a page
    const p1 = try allocPage();
    try testing.expectEqual(base + PageSize, p1);
    try testing.expectEqual(@as(usize, 1), phys_mem_state.free_pages);

    // Allocate another page
    const p2 = try allocPage();
    try testing.expectEqual(base, p2);
    try testing.expectEqual(@as(usize, 0), phys_mem_state.free_pages);

    // Out of memory
    try testing.expectError(PhysMemError.OutOfMemory, allocPage());

    // Free a page
    freePage(p1);
    try testing.expectEqual(@as(usize, 1), phys_mem_state.free_pages);
    const p1_again = try allocPage();
    try testing.expectEqual(p1, p1_again);
}
