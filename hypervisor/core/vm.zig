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
            self.paging.?.deinit();
        } else {
            self.pmp_config.?.deinit();
            if (self.is_ram_allocated and self.range_size > 0) {
                physmem.freePage(self.base_hpa);
            }
        }
    }

    // Map physical memory into guest address space
    pub fn map(self: *GuestSpace, gpa: usize, hpa: usize, size: usize, flags: u64) !void {
        if (self.mode == .h_paging) {
            // Map individual pages for paging (allows fragmentation/CoW)
            var offset: usize = 0;
            while (offset < size) : (offset += physmem.PageSize) {
                try self.paging.?.mapPage(gpa + offset, hpa + offset, flags, self.is_trusted);
            }
        } else {
            // Map as one contiguous block for PMP.
            // If this region falls completely within our pre-allocated guest RAM region,
            // we do not need to create a redundant PMP entry for it, preventing TooManyRegions hardware limits.
            if (hpa >= self.base_hpa and hpa + size <= self.base_hpa + self.range_size) {
                return; // Already covered by main RAM container
            }
        }
    }

    // Unmap physical memory from guest address space
    pub fn unmap(self: *GuestSpace, gpa: usize, size: usize) void {
        if (self.mode == .h_paging) {
            var offset: usize = 0;
            while (offset < size) : (offset += physmem.PageSize) {
                self.paging.?.unmapPage(gpa + offset);
            }
        }
    }

    // Handle a guest physical page fault (dynamic paging, MMIO, or error)
    pub fn handleFault(self: *GuestSpace, vc: *anyopaque, gpa: usize, cause: usize) !void {
        _ = vc;
        _ = cause;
        if (self.mode == .h_paging) {
            try self.paging.?.resolveFault(gpa, self.is_trusted);
        } else {
            // PMP mode doesn't support CoW/Demand Paging yet
            return error.NotSupported;
        }
    }

    // Load hgatp for paging or set PMP regs for fallback
    pub fn apply(self: *GuestSpace, vmid: u16) void {
        if (self.mode == .h_paging) {
            const new_hgatp = self.paging.?.hgatp(vmid);
            if (riscv.readHgatp() != new_hgatp) {
                riscv.writeHgatp(new_hgatp);
                riscv.hfenceGvma();
            }
        } else {
            self.pmp_config.?.apply();
        }
    }

    // Translate a Guest Physical Address to a Host Physical Address
    pub fn translateGPA(self: *const GuestSpace, gpa: usize) !usize {
        if (self.mode == .h_paging) {
            const pt = self.paging.?;
            // Check if it's within the optimized identity/offset range
            if (pt.root_range_size > 0 and gpa >= pt.root_base_gpa and gpa < pt.root_base_gpa + pt.root_range_size) {
                return gpa - pt.root_base_gpa + pt.root_base_hpa;
            }
            // Otherwise, perform a page table walk
            const pte_ptr = pt.walk(gpa, false) catch return error.TranslationFailed;
            if (pte_ptr.* & sv39x4.PTEFlags.valid == 0) return error.TranslationFailed;
            const hpa = (pte_ptr.* >> 10) << 12;
            if (hpa == 0) return error.TranslationFailed;
            return hpa + (gpa % physmem.PageSize);
        } else {
            // PMP mode: resolve the GPA through the optimized identity mapping.
            if (self.range_size > 0 and gpa >= self.base_gpa and gpa < self.base_gpa + self.range_size) {
                return self.base_hpa + (gpa - self.base_gpa);
            }
            return error.TranslationFailed;
        }
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
