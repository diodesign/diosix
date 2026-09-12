// Unified guest memory space management (GuestSpace)
//
// Manages memory address translation (Stage-2 Sv39x4 hardware paging or
// physical memory protection PMP fallback). Overall VM lifecycle,
// quotas, and execution context are managed by Guest in core/guest.zig.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const physmem = @import("physmem.zig");
const sv39x4 = @import("../hardware/native/cpu/riscv64/sv39x4.zig");
const pmp = @import("../hardware/native/cpu/riscv64/pmp.zig");
const riscv = @import("../hardware/native/cpu/riscv64/mod.zig");

pub const ALL_PHYSICAL_MEMORY: usize = std.math.maxInt(usize);

pub const GuestSpace = struct {
    mode: enum { h_paging, pmp_fallback },
    paging: ?sv39x4.PageTable,
    pmp_config: ?pmp.PMPConfig,
    is_trusted: bool,
    base_gpa: usize,
    base_hpa: usize,
    range_size: usize,
    is_ram_allocated: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, is_trusted: bool, base_gpa: usize, base_hpa: usize, range_size: usize) !GuestSpace {
        if (riscv.hasHExtension()) {
            return GuestSpace{
                .mode = .h_paging,
                .paging = try sv39x4.PageTable.init(base_gpa, base_hpa, range_size),
                .pmp_config = null,
                .is_trusted = is_trusted,
                .base_gpa = base_gpa,
                .base_hpa = base_hpa,
                .range_size = range_size,
                .is_ram_allocated = false,
                .allocator = allocator,
            };
        } else {
            var pmp_config = try pmp.PMPConfig.init(allocator);

            // 1. Deny access to the hypervisor's private DRAM region [ram_base, base_hpa)
            const ram_base = physmem.getRamBase();
            const hv_size = base_hpa - ram_base;
            if (hv_size > 0) {
                try pmp_config.addRegion(ram_base, hv_size, pmp.PMPAccess.none);
            }

            // 2. Allow access to the entire 64-bit physical address space for everything else.
            // Under PMP check ordering, the hypervisor range denial is matched first,
            // so this securely enables direct guest S-mode/U-mode access to RAM and all MMIO peripherals.
            try pmp_config.addRegion(0, ALL_PHYSICAL_MEMORY, pmp.PMPAccess.rwx);

            return GuestSpace{
                .mode = .pmp_fallback,
                .paging = null,
                .pmp_config = pmp_config,
                .is_trusted = is_trusted,
                .base_gpa = base_gpa,
                .base_hpa = base_hpa,
                .range_size = range_size,
                .is_ram_allocated = false,
                .allocator = allocator,
            };
        }
    }

    pub fn deinit(self: *GuestSpace) void {
        if (self.mode == .h_paging) {
            if (self.paging) |*p| {
                p.deinit();
                self.paging = null;
            }
        } else {
            if (self.pmp_config) |*p| {
                p.deinit();
                self.pmp_config = null;
            }
            if (self.is_ram_allocated and self.range_size > 0) {
                physmem.freePage(self.base_hpa);
                self.is_ram_allocated = false;
            }
        }
    }

    // Map physical memory into guest address space
    pub fn map(self: *GuestSpace, gpa: usize, hpa: usize, size: usize, flags: u64) !void {
        if (self.mode == .h_paging) {
            if (self.paging) |*pt| {
                // Map individual pages for paging (allows fragmentation/CoW)
                var offset: usize = 0;
                while (offset < size) : (offset += physmem.PageSize) {
                    try pt.mapPage(gpa + offset, hpa + offset, flags, self.is_trusted);
                }
            } else {
                return error.NotSupported;
            }
        } else {
            // Map as one contiguous block for PMP.
            // If this region falls completely within our pre-allocated guest RAM region,
            // we do not need to create a redundant PMP entry for it, preventing TooManyRegions hardware limits.
            if (hpa >= self.base_hpa and (hpa - self.base_hpa) + size <= self.range_size) {
                return; // Already covered by main RAM container
            }
        }
    }

    // Unmap physical memory from guest address space
    pub fn unmap(self: *GuestSpace, gpa: usize, size: usize) void {
        if (self.mode == .h_paging) {
            if (self.paging) |*pt| {
                var offset: usize = 0;
                while (offset < size) : (offset += physmem.PageSize) {
                    pt.unmapPage(gpa + offset);
                }
            }
        }
    }

    // Handle a guest physical page fault (dynamic paging, MMIO, or error)
    pub fn handleFault(self: *GuestSpace, vc: *anyopaque, gpa: usize, cause: usize) !void {
        _ = vc;
        _ = cause;
        if (self.mode == .h_paging) {
            if (self.paging) |*pt| {
                try pt.resolveFault(gpa, self.is_trusted);
            } else {
                return error.NotSupported;
            }
        } else {
            // PMP mode doesn't support CoW/Demand Paging yet
            return error.NotSupported;
        }
    }

    // Load hgatp for paging or set PMP regs for fallback
    pub fn apply(self: *GuestSpace, vmid: u16) void {
        if (self.mode == .h_paging) {
            const new_hgatp = if (self.paging) |*pt| pt.hgatp(vmid) else 0;
            if (riscv.readHgatp() != new_hgatp) {
                riscv.writeHgatp(new_hgatp);
                riscv.hfenceGvma();
            }
        } else {
            if (self.pmp_config) |*p| p.apply();
        }
    }

    // Translate a Guest Physical Address to a Host Physical Address
    pub fn translateGPA(self: *const GuestSpace, gpa: usize) !usize {
        if (self.mode == .h_paging) {
            const pt = self.paging orelse return error.TranslationFailed;
            // Check if it's within the optimized identity/offset range
            if (pt.root_range_size > 0 and gpa >= pt.root_base_gpa and (gpa - pt.root_base_gpa) < pt.root_range_size) {
                const off = gpa - pt.root_base_gpa;
                return std.math.add(usize, pt.root_base_hpa, off) catch return error.TranslationFailed;
            }
            // Otherwise, perform a page table walk
            const pte_ptr = pt.walk(gpa, false) catch return error.TranslationFailed;
            if (pte_ptr.* & sv39x4.PTEFlags.valid == 0) return error.TranslationFailed;
            const hpa = sv39x4.pteToHpa(pte_ptr.*);
            if (hpa == 0) return error.TranslationFailed;
            return std.math.add(usize, hpa, gpa % physmem.PageSize) catch return error.TranslationFailed;
        } else {
            // PMP mode: resolve the GPA through the optimized identity mapping.
            if (self.range_size > 0 and gpa >= self.base_gpa and (gpa - self.base_gpa) < self.range_size) {
                const off = gpa - self.base_gpa;
                return std.math.add(usize, self.base_hpa, off) catch return error.TranslationFailed;
            }
            return error.TranslationFailed;
        }
    }

    // Safely copy data from host buffer to guest physical memory space.
    // Handles multi-page transfers and non-contiguous guest physical mappings.
    // Pre-validates the entire GPA range to ensure atomicity against unmapped faults.
    pub fn copyToGuest(self: *const GuestSpace, dst_gpa: usize, src: []const u8) !void {
        if (src.len == 0) return;
        _ = std.math.add(usize, dst_gpa, src.len) catch return error.TranslationFailed;

        // Pass 1: Pre-validate all target pages to avoid partial writes on unmapped faults
        var check_off: usize = 0;
        while (check_off < src.len) {
            const cur_gpa = dst_gpa + check_off;
            const cur_hpa = try self.translateGPA(cur_gpa);
            const page_rem = physmem.PageSize - (cur_gpa % physmem.PageSize);
            const chunk = @min(src.len - check_off, page_rem);
            if (physmem.isHypervisorMemory(cur_hpa, chunk)) return error.AccessDenied;
            check_off += chunk;
        }

        // Pass 2: Transfer data page by page
        var transferred: usize = 0;
        while (transferred < src.len) {
            const cur_gpa = dst_gpa + transferred;
            const cur_hpa = try self.translateGPA(cur_gpa);
            const page_rem = physmem.PageSize - (cur_gpa % physmem.PageSize);
            const chunk = @min(src.len - transferred, page_rem);
            if (physmem.isHypervisorMemory(cur_hpa, chunk)) return error.AccessDenied;
            @memcpy(@as([*]u8, @ptrFromInt(cur_hpa))[0..chunk], src[transferred .. transferred + chunk]);
            transferred += chunk;
        }
    }

    // Safely copy data from guest physical memory space into host buffer.
    // Handles multi-page transfers and non-contiguous guest physical mappings.
    pub fn copyFromGuest(self: *const GuestSpace, dst: []u8, src_gpa: usize) !void {
        if (dst.len == 0) return;
        _ = std.math.add(usize, src_gpa, dst.len) catch return error.TranslationFailed;

        var transferred: usize = 0;
        while (transferred < dst.len) {
            const cur_gpa = src_gpa + transferred;
            const cur_hpa = try self.translateGPA(cur_gpa);
            const page_rem = physmem.PageSize - (cur_gpa % physmem.PageSize);
            const chunk = @min(dst.len - transferred, page_rem);
            if (physmem.isHypervisorMemory(cur_hpa, chunk)) return error.AccessDenied;
            @memcpy(dst[transferred .. transferred + chunk], @as([*]const u8, @ptrFromInt(cur_hpa))[0..chunk]);
            transferred += chunk;
        }
    }

    // Read a typed struct from guest physical address space, safely handling page boundaries.
    pub fn readGuestStruct(self: *const GuestSpace, comptime T: type, gpa: usize) !T {
        var val: T = undefined;
        try self.copyFromGuest(std.mem.asBytes(&val), gpa);
        return val;
    }

    // Write a typed struct to guest physical address space, safely handling page boundaries.
    pub fn writeGuestStruct(self: *const GuestSpace, comptime T: type, gpa: usize, val: T) !void {
        try self.copyToGuest(gpa, std.mem.asBytes(&val));
    }
};

test "GuestSpace GPA to HPA translation and bounds checking" {
    const testing = std.testing;

    var phys_test = try physmem.initForTest(testing.allocator, 128);
    defer phys_test.deinit();

    // Initialize a mock GuestSpace with 1MB DRAM at GPA 0x80000000 -> HPA 0x80200000
    const base_gpa: usize = 0x80000000;
    const base_hpa: usize = 0x80200000;
    const size: usize = 1024 * 1024; // 1MB

    var space = try GuestSpace.init(testing.allocator, true, base_gpa, base_hpa, size);
    defer space.deinit();

    // 1. Valid GPA in range
    const hpa = try space.translateGPA(0x80001000);
    try testing.expectEqual(@as(usize, 0x80201000), hpa);

    // 2. GPA out of bounds (below base) -> TranslationFailed
    try testing.expectError(error.TranslationFailed, space.translateGPA(0x7FFFFFFF));

    // 3. GPA out of bounds (above limit) -> TranslationFailed
    try testing.expectError(error.TranslationFailed, space.translateGPA(base_gpa + size));
}

test "GuestSpace safe copy and struct transfer across page boundaries" {
    const testing = std.testing;

    var phys_test = try physmem.initForTest(testing.allocator, 128);
    defer phys_test.deinit();

    const base_gpa: usize = 0x80000000;
    const base_hpa = physmem.getRamBase() + 4 * physmem.PageSize;
    const size: usize = 2 * physmem.PageSize; // 2 pages = 8KB

    var space = try GuestSpace.init(testing.allocator, true, base_gpa, base_hpa, size);
    defer space.deinit();

    const TestStruct = extern struct {
        a: u64,
        b: u64,
        c: u32,
    };

    // Position struct so it straddles the 4KB page boundary:
    // Offset 4096 - 8 starts 8 bytes before end of page 0, continues into page 1
    const straddle_gpa = base_gpa + physmem.PageSize - 8;
    const original = TestStruct{
        .a = 0x1122334455667788,
        .b = 0x8877665544332211,
        .c = 0xDEADBEEF,
    };

    try space.writeGuestStruct(TestStruct, straddle_gpa, original);
    const read_back = try space.readGuestStruct(TestStruct, straddle_gpa);
    try testing.expectEqual(original.a, read_back.a);
    try testing.expectEqual(original.b, read_back.b);
    try testing.expectEqual(original.c, read_back.c);

    // Write struct extending past end of available space -> TranslationFailed
    const out_of_bounds_gpa = base_gpa + size - 4;
    try testing.expectError(error.TranslationFailed, space.writeGuestStruct(TestStruct, out_of_bounds_gpa, original));

    // Integer overflow in GPA address calculation -> TranslationFailed
    try testing.expectError(error.TranslationFailed, space.writeGuestStruct(TestStruct, std.math.maxInt(usize) - 4, original));

    // Shielding: guest space pointing to hypervisor memory cannot be read or written
    const hv_hpa = physmem.getHvRegion().base;
    if (hv_hpa > 0) {
        var poisoned_space = try GuestSpace.init(testing.allocator, false, 0x1000, hv_hpa, physmem.PageSize);
        defer poisoned_space.deinit();

        var dummy_buf: [16]u8 = @splat(0xAA);
        try testing.expectError(error.AccessDenied, poisoned_space.copyToGuest(0x1000, &dummy_buf));
        try testing.expectError(error.AccessDenied, poisoned_space.copyFromGuest(&dummy_buf, 0x1000));
    }
}
