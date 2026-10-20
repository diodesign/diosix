// Unified guest memory space management (GuestSpace).
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
pub const transfer = @import("vm/transfer.zig");

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

    pub fn init(
        allocator: std.mem.Allocator,
        is_trusted: bool,
        base_gpa: usize,
        base_hpa: usize,
        range_size: usize,
    ) !GuestSpace {
        if (riscv.hasHExtension()) {
            return initPaging(
                allocator,
                is_trusted,
                base_gpa,
                base_hpa,
                range_size,
            );
        }
        return initPmpFallback(
            allocator,
            is_trusted,
            base_gpa,
            base_hpa,
            range_size,
        );
    }

    pub fn initPaging(
        allocator: std.mem.Allocator,
        is_trusted: bool,
        base_gpa: usize,
        base_hpa: usize,
        range_size: usize,
    ) !GuestSpace {
        return GuestSpace{
            .mode = .h_paging,
            .paging = try sv39x4.PageTable.init(
                base_gpa,
                base_hpa,
                range_size,
            ),
            .pmp_config = null,
            .is_trusted = is_trusted,
            .base_gpa = base_gpa,
            .base_hpa = base_hpa,
            .range_size = range_size,
            .is_ram_allocated = false,
            .allocator = allocator,
        };
    }

    pub fn initPmpFallback(
        allocator: std.mem.Allocator,
        is_trusted: bool,
        base_gpa: usize,
        base_hpa: usize,
        range_size: usize,
    ) !GuestSpace {
        var pmp_config = try pmp.PMPConfig.init(allocator);
        errdefer pmp_config.deinit();

        // 1. Deny access to the hypervisor's private DRAM region.
        const hv = physmem.getHvRegion();
        if (hv.size > 0) {
            try pmp_config.addRegion(hv.base, hv.size, pmp.PMPAccess.none);
        }

        // 2. Allow access to the rest of the 64-bit physical address space.
        // Under PMP check ordering, the hypervisor range denial is matched
        // first, enabling guest S-mode/U-mode access to RAM and MMIO.
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

    /// Maps physical memory into the guest address space.
    pub fn map(
        self: *GuestSpace,
        gpa: usize,
        hpa: usize,
        size: usize,
        flags: u64,
    ) !void {
        if (size == 0) return;
        const gpa_end = std.math.add(usize, gpa, size) catch
            return error.InvalidAddress;
        _ = std.math.add(usize, hpa, size) catch return error.InvalidAddress;
        if (self.mode == .h_paging and gpa_end > sv39x4.MAX_GPA) {
            return error.InvalidAddress;
        }

        if (self.mode == .h_paging) {
            if (self.paging) |*pt| {
                var offset: usize = 0;
                errdefer self.unmap(gpa, offset);
                while (offset < size) : (offset += physmem.PageSize) {
                    try pt.mapPage(
                        gpa + offset,
                        hpa + offset,
                        flags,
                        self.is_trusted,
                    );
                }
            } else {
                return error.NotSupported;
            }
        } else {
            // If this region falls within our pre-allocated guest RAM region,
            // no additional PMP entry is needed.
            if (hpa >= self.base_hpa and
                (hpa - self.base_hpa) + size <= self.range_size)
            {
                return;
            }
        }
    }

    /// Unmaps physical memory from the guest address space.
    pub fn unmap(self: *GuestSpace, gpa: usize, size: usize) void {
        if (size == 0) return;
        const gpa_end = std.math.add(usize, gpa, size) catch return;
        if (self.mode == .h_paging and gpa_end > sv39x4.MAX_GPA) return;

        if (self.mode == .h_paging) {
            if (self.paging) |*pt| {
                var offset: usize = 0;
                while (offset < size) : (offset += physmem.PageSize) {
                    pt.unmapPage(gpa + offset);
                }
            }
        }
    }

    /// Updates the guest range size and underlying page table limits.
    pub fn setRangeSize(self: *GuestSpace, new_size: usize) void {
        self.range_size = new_size;
        if (self.paging) |*pt| {
            pt.root_range_size = new_size;
        }
    }

    /// Handles a guest physical page fault (dynamic paging, MMIO, or error).
    pub fn handleFault(
        self: *GuestSpace,
        vc: *anyopaque,
        gpa: usize,
        cause: usize,
    ) !void {
        _ = vc;
        _ = cause;
        if (self.mode == .h_paging) {
            if (self.paging) |*pt| {
                try pt.resolveFault(gpa, self.is_trusted);
            } else {
                return error.NotSupported;
            }
        } else {
            return error.NotSupported;
        }
    }

    /// Loads `hgatp` for Stage-2 paging or applies PMP registers for fallback.
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

    /// Translates a Guest Physical Address (GPA) to a Host Physical Address.
    pub fn translateGPA(self: *const GuestSpace, gpa: usize) !usize {
        if (self.mode == .h_paging) {
            const pt = self.paging orelse return error.TranslationFailed;
            if (pt.root_base_hpa > 0 and
                pt.root_range_size > 0 and
                gpa >= pt.root_base_gpa and
                (gpa - pt.root_base_gpa) < pt.root_range_size)
            {
                const off = gpa - pt.root_base_gpa;
                return std.math.add(usize, pt.root_base_hpa, off) catch
                    return error.TranslationFailed;
            }
            const pte_ptr = pt.walk(gpa, false) catch
                return error.TranslationFailed;
            if (pte_ptr.* & sv39x4.PTEFlags.valid == 0) {
                return error.TranslationFailed;
            }
            const hpa = sv39x4.pteToHpa(pte_ptr.*);
            if (hpa == 0) return error.TranslationFailed;
            return std.math.add(usize, hpa, gpa % physmem.PageSize) catch
                return error.TranslationFailed;
        } else {
            if (self.base_hpa > 0 and
                self.range_size > 0 and
                gpa >= self.base_gpa and
                (gpa - self.base_gpa) < self.range_size)
            {
                const off = gpa - self.base_gpa;
                return std.math.add(usize, self.base_hpa, off) catch
                    return error.TranslationFailed;
            }
            return error.TranslationFailed;
        }
    }

    pub const copyToGuest = transfer.copyToGuest;
    pub const copyFromGuest = transfer.copyFromGuest;
    pub const readGuestStruct = transfer.readGuestStruct;
    pub const writeGuestStruct = transfer.writeGuestStruct;
};

test "GuestSpace GPA to HPA translation and PMP fallback shielding" {
    _ = transfer;
    std.testing.refAllDecls(@This());
    const testing = std.testing;

    var phys_test = try physmem.initForTest(testing.allocator, 128);
    defer phys_test.deinit();

    const base_gpa: usize = 0x80000000;
    const base_hpa: usize = 0x80200000;
    const size: usize = 1024 * 1024;

    var space = try GuestSpace.init(
        testing.allocator,
        true,
        base_gpa,
        base_hpa,
        size,
    );
    defer space.deinit();

    const hpa = try space.translateGPA(0x80001000);
    try testing.expectEqual(@as(usize, 0x80201000), hpa);
    try testing.expectError(
        error.TranslationFailed,
        space.translateGPA(0x7fffffff),
    );
    try testing.expectError(
        error.TranslationFailed,
        space.translateGPA(base_gpa + size),
    );

    // Verify PMP fallback initialization does not underflow when base_hpa == 0.
    var pmp_space = try GuestSpace.initPmpFallback(
        testing.allocator,
        false,
        base_gpa,
        0,
        size,
    );
    defer pmp_space.deinit();
    try testing.expectEqual(.pmp_fallback, pmp_space.mode);
}
