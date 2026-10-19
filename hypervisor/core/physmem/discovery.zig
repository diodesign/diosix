// Physical memory region discovery from Flattened Device Tree (FDT).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const riscv = @import("../../hardware/native/cpu/riscv64/mod.zig");
const dt = @import("../dt.zig");
const physmem = @import("../physmem.zig");

const Region = physmem.Region;
const PageSize = physmem.PageSize;
const PhysMemError = physmem.PhysMemError;

// Compute the hypervisor HPA footprint including static per-CPU slabs.
pub fn computeHvRegion(device_tree: *dt.DeviceTree) Region {
    const max_c = riscv.STATIC_PHYS_CORES;
    const num_slabs: usize =
        if (builtin.is_test) 1 else @min(device_tree.countCpus(), max_c);
    const hv_start = if (builtin.is_test)
        physmem.test_hv_start
    else
        @intFromPtr(&physmem.__hypervisor_start);
    const hv_static_end = if (builtin.is_test)
        physmem.test_hv_end
    else
        @intFromPtr(&physmem.__hypervisor_end);
    const hv_end = hv_static_end + (num_slabs * riscv.CPU_SLAB_SIZE);
    return .{ .base = hv_start, .size = hv_end - hv_start };
}

pub fn populateRegionsLocked(device_tree: *dt.DeviceTree) !void {
    physmem.phys_mem_state.hv_region = computeHvRegion(device_tree);
    physmem.phys_mem_state.region_count = 0;

    var it = device_tree.iter("/", 1);
    while (it.next()) |path| {
        if (!std.mem.startsWith(u8, std.fs.path.basename(path), "memory@")) {
            continue;
        }
        const reg_prop = device_tree.getProperty(path, "reg") catch continue;
        const cells = device_tree.getAddressSizeCells("/");
        const data = reg_prop.data orelse continue;
        const entry_size = (cells.address + cells.size) * @sizeOf(u32);
        var i: usize = 0;
        while (i + entry_size <= data.len) : (i += entry_size) {
            const base = try readCells(data[i..], cells.address);
            const size_off = i + cells.address * @sizeOf(u32);
            const size = try readCells(data[size_off..], cells.size);
            if (physmem.phys_mem_state.region_count < physmem.max_regions) {
                const idx = physmem.phys_mem_state.region_count;
                physmem.phys_mem_state.regions[idx] = .{
                    .base = @intCast(base),
                    .size = @intCast(size),
                };
                physmem.phys_mem_state.region_count += 1;
            }
        }
    }
}

pub fn readCells(data: []const u8, count: usize) !u64 {
    if (count == 1) {
        if (data.len < @sizeOf(u32)) return error.OutOfBounds;
        return std.mem.readInt(u32, data[0..@sizeOf(u32)], .big);
    }
    if (count == 2) {
        if (data.len < @sizeOf(u64)) return error.OutOfBounds;
        return std.mem.readInt(u64, data[0..@sizeOf(u64)], .big);
    }
    return error.WidthUnsupported;
}

pub fn clipExclusion(
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

pub fn addRamBlock(
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
            var addr = std.mem.alignForward(usize, current_base, PageSize);
            while (addr < next_step) {
                var order: u8 = 0;
                while (order + 1 < physmem.max_order) {
                    const next_sz =
                        (@as(usize, 1) << @intCast(order + 1)) * PageSize;
                    if (addr % next_sz == 0 and addr + next_sz <= next_step) {
                        order += 1;
                    } else break;
                }
                physmem.pushFreeBlock(addr, order);
                addr += (@as(usize, 1) << @intCast(order)) * PageSize;
            }
        }
        current_base = next_step;
    }
}

pub fn discoverMemoryRegions(device_tree: *dt.DeviceTree) !void {
    const lock_ms = physmem.phys_mem_state.lock.lock();
    defer physmem.phys_mem_state.lock.unlock(lock_ms);
    try populateRegionsLocked(device_tree);
}

pub const discoverRegions = discoverMemoryRegions;

pub fn getDiscoveredRamBytes() usize {
    const lock_ms = physmem.phys_mem_state.lock.lock();
    defer physmem.phys_mem_state.lock.unlock(lock_ms);
    var total: usize = 0;
    for (0..physmem.phys_mem_state.region_count) |i| {
        const reg_sz = physmem.phys_mem_state.regions[i].size;
        total = std.math.add(usize, total, reg_sz) catch
            std.math.maxInt(usize);
    }
    return total;
}

pub fn findContiguousRegion(size: usize) !Region {
    const lock_ms = physmem.phys_mem_state.lock.lock();
    defer physmem.phys_mem_state.lock.unlock(lock_ms);
    if (physmem.phys_mem_state.region_count == 0) {
        return PhysMemError.NoRAMFound;
    }
    for (0..physmem.phys_mem_state.region_count) |i| {
        const reg = physmem.phys_mem_state.regions[i];
        if (reg.size < size) continue;
        if (reg.end() >= size) {
            const top_base =
                std.mem.alignBackward(usize, reg.end() - size, PageSize);
            if (top_base >= reg.base and
                !physmem.isHypervisorMemory(top_base, size))
            {
                return .{ .base = top_base, .size = size };
            }
        }
        var base = std.mem.alignForward(usize, reg.base, PageSize);
        while (true) {
            const end = std.math.add(usize, base, size) catch break;
            if (end > reg.end()) break;
            if (!physmem.isHypervisorMemory(base, size)) {
                return .{ .base = base, .size = size };
            }
            base = std.math.add(usize, base, PageSize) catch break;
        }
    }
    return PhysMemError.OutOfMemory;
}

test "FDT cell reading and exclusion clipping" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;

    const buf32 = [_]u8{ 0x80, 0x00, 0x00, 0x00 };
    try testing.expectEqual(@as(u64, 0x80000000), try readCells(&buf32, 1));

    var next_step: usize = 0x80004000;
    var skip = false;
    clipExclusion(0x80000000, 0x80000000, 0x80002000, &next_step, &skip);
    try testing.expect(skip);
    try testing.expectEqual(@as(usize, 0x80002000), next_step);
}
