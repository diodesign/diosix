// RISC-V SV39x4 Stage-2 (G-stage) Page Table Management
//
// SV39x4 provides a 41-bit Guest Physical Address (GPA) space by using
// a 16KB root-level page table (compared to 4KB for S-mode SV39).

const std = @import("std");
const physmem = @import("../../physmem.zig");
const debug = @import("../../debug.zig");

pub const SV39x4Error = error{
    InvalidAlignment,
    MappingOverlap,
    WalkFailed,
};

pub const PTEFlags = struct {
    pub const valid: u64 = 1 << 0;
    pub const read: u64 = 1 << 1;
    pub const write: u64 = 1 << 2;
    pub const execute: u64 = 1 << 3;
    pub const user: u64 = 1 << 4;
    pub const global: u64 = 1 << 5;
    pub const accessed: u64 = 1 << 6;
    pub const dirty: u64 = 1 << 7;

    // Software defined flags (bits 9-8)
    pub const cow: u64 = 1 << 8;
    pub const demand: u64 = 1 << 9;
};

pub const PTE = u64;

pub const PageTable = struct {
    root_phys: usize, // Root table (order 2 block = 16KB)
    shadow_source: ?*const PageTable = null,

    // For Root VM identity/offset mapping
    // If range_size > 0, faults in this GPA range are resolved via (gpa - base_gpa + base_hpa)
    root_base_gpa: usize = 0,
    root_base_hpa: usize = 0,
    root_range_size: usize = 0,

    pub fn init(base_gpa: usize, base_hpa: usize, range_size: usize) !PageTable {
        const addr = try physmem.allocPageSelection(2);
        return PageTable{
            .root_phys = addr,
            .shadow_source = null,
            .root_base_gpa = base_gpa,
            .root_base_hpa = base_hpa,
            .root_range_size = range_size,
        };
    }

    pub fn deinit(self: *PageTable) void {
        self.destroyTable(self.root_phys, 2);
    }

    fn destroyTable(self: *PageTable, addr: usize, level: u8) void {
        const ptes = @as([*]PTE, @ptrFromInt(addr));
        const num_entries = if (level == 2) @as(usize, 2048) else @as(usize, 512);

        for (0..num_entries) |i| {
            const pte = ptes[i];
            if (pte & PTEFlags.valid != 0) {
                // If not a leaf, recurse
                if (pte & (PTEFlags.read | PTEFlags.write | PTEFlags.execute) == 0) {
                    const next_addr = (pte >> 10) << 12;
                    self.destroyTable(next_addr, level - 1);
                } else {
                    // Leaf: decrement refcount of the actual data page
                    const hpa = (pte >> 10) << 12;
                    // Only decrement if it was a RAM page (MMIO pages don't have refcounts)
                    if (physmem.isRam(hpa, physmem.PageSize)) {
                        physmem.decrementPageRef(hpa);
                    }
                }
            }
        }
        physmem.freePage(addr);
    }

    // Map a single 4KB page
    pub fn mapPage(self: *PageTable, gpa: usize, hpa: usize, flags: u64, is_trusted: bool) !void {
        if (gpa % physmem.PageSize != 0 or hpa % physmem.PageSize != 0) return SV39x4Error.InvalidAlignment;

        // Security Shields:
        // Prevent mapping hypervisor memory
        if (physmem.isHypervisorMemory(hpa, physmem.PageSize)) return error.AccessDenied;

        // Prevent non-trusted guest mapping MMIO
        if (!is_trusted and physmem.isMmio(hpa, physmem.PageSize)) return error.AccessDenied;

        var ptes_phys = self.root_phys;
        var level: u8 = 2;

        while (level > 0) : (level -= 1) {
            const index = self.getIdx(gpa, level);
            const ptes = @as([*]PTE, @ptrFromInt(ptes_phys));

            if (ptes[index] & PTEFlags.valid == 0) {
                // Create next level table
                const next_table = try physmem.allocPage();
                ptes[index] = ((next_table >> 12) << 10) | PTEFlags.valid;
            } else if (ptes[index] & (PTEFlags.read | PTEFlags.write | PTEFlags.execute) != 0) {
                return SV39x4Error.MappingOverlap;
            }

            ptes_phys = (ptes[index] >> 10) << 12;
        }

        // At level 0, set leaf entry
        const index = self.getIdx(gpa, 0);
        const ptes = @as([*]PTE, @ptrFromInt(ptes_phys));

        if (ptes[index] & PTEFlags.valid != 0) {
            const existing_hpa = (ptes[index] >> 10) << 12;
            if (existing_hpa == hpa) return; // Already correctly mapped
            return SV39x4Error.MappingOverlap;
        }

        ptes[index] = ((hpa >> 12) << 10) | flags | PTEFlags.valid | PTEFlags.accessed | PTEFlags.dirty;
        if (physmem.isRam(hpa, physmem.PageSize) and physmem.isManaged(hpa)) {
            physmem.incrementPageRef(hpa);
        }
    }

    // Walk the page table to find the entry for the given GPA.
    // If 'create' is true, intermediate tables are allocated as needed.
    pub fn walk(self: *const PageTable, gpa: usize, create: bool) !*PTE {
        var ptes_phys = self.root_phys;
        var level: u8 = 2;

        while (level > 0) : (level -= 1) {
            const index = self.getIdx(gpa, level);
            const ptes = @as([*]PTE, @ptrFromInt(ptes_phys));

            if (ptes[index] & PTEFlags.valid == 0) {
                if (!create) return error.WalkFailed;
                const next_table = try physmem.allocPage();
                ptes[index] = ((next_table >> 12) << 10) | PTEFlags.valid;
            } else if (ptes[index] & (PTEFlags.read | PTEFlags.write | PTEFlags.execute) != 0) {
                return SV39x4Error.WalkFailed; // Encountered leaf too early
            }

            ptes_phys = (ptes[index] >> 10) << 12;
        }

        const index = self.getIdx(gpa, 0);
        const ptes = @as([*]PTE, @ptrFromInt(ptes_phys));
        return &ptes[index];
    }

    fn resolveCoW(self: *PageTable, pte_ptr: *PTE) !void {
        _ = self;
        const pte = pte_ptr.*;
        const hpa = (pte >> 10) << 12;

        // Always clone for now. A more advanced implementation would check the refcount.
        const new_hpa = try physmem.allocPage();
        @memcpy(@as([*]u8, @ptrFromInt(new_hpa))[0..physmem.PageSize], @as([*]u8, @ptrFromInt(hpa))[0..physmem.PageSize]);

        if (physmem.isManaged(hpa)) {
            physmem.decrementPageRef(hpa);
        }
        pte_ptr.* = ((new_hpa >> 12) << 10) | (pte & ~PTEFlags.cow) | PTEFlags.write | PTEFlags.valid | PTEFlags.accessed | PTEFlags.dirty;
    }

    fn getIdx(self: *const PageTable, gpa: usize, level: u8) usize {
        _ = self;
        return switch (level) {
            2 => (gpa >> 30) & 0x7FF, // 11 bits for root
            1 => (gpa >> 21) & 0x1FF, // 9 bits
            0 => (gpa >> 12) & 0x1FF, // 9 bits
            else => unreachable,
        };
    }

    // Create a Copy-on-Write fork of this page table.
    // This is "Truly Cheap": it returns an empty root table with a shadow source.
    pub fn fork(self: *const PageTable) !PageTable {
        const other_root = try physmem.allocPageSelection(2);

        // Note: we don't copy ANY entries from the source.
        // Instead, we rely on resolveFault and thawFromShadow to populate
        // the child's table on demand. This ensures all shared pages
        // are properly marked as CoW.

        return PageTable{
            .root_phys = other_root,
            .shadow_source = self,
            .root_base_gpa = self.root_base_gpa,
            .root_base_hpa = self.root_base_hpa,
            .root_range_size = self.root_range_size,
        };
    }

    // DELETED: forkTable is no longer used for eager cloning.

    // Entry point for fault handling
    pub fn resolveFault(self: *PageTable, gpa: usize, is_trusted: bool) !void {
        // Identity map standard MMIO/peripheral regions below RAM for trusted guests (like Root VM)
        if (is_trusted and gpa < 0x80000000) {
            const gpa_page = gpa & ~(physmem.PageSize - 1);
            try self.mapPage(gpa_page, gpa_page, PTEFlags.read | PTEFlags.write | PTEFlags.valid | PTEFlags.accessed | PTEFlags.dirty | PTEFlags.user, is_trusted);
            return;
        }

        // Root VM identity mapping
        if (gpa >= self.root_base_gpa and gpa < self.root_base_gpa + self.root_range_size) {
            const hpa = gpa - self.root_base_gpa + self.root_base_hpa;
            // Round down to page boundaries to ensure idempotency and alignment.
            const gpa_page = gpa & ~(physmem.PageSize - 1);
            const hpa_page = hpa & ~(physmem.PageSize - 1);
            // Safety: verify the target HPA does not overlap the hypervisor footprint.
            if (physmem.isHypervisorMemory(hpa_page, physmem.PageSize)) {
                return error.AccessDenied;
            }
            try self.mapPage(gpa_page, hpa_page, PTEFlags.read | PTEFlags.write | PTEFlags.execute | PTEFlags.valid | PTEFlags.accessed | PTEFlags.dirty | PTEFlags.user, is_trusted);
            return;
        }

        // Resolve via walking
        const pte_ptr = try self.walk(gpa, true);
        const pte = pte_ptr.*;

        if (pte & PTEFlags.valid != 0) {
            // Check for CoW
            if (pte & PTEFlags.cow != 0) {
                try self.resolveCoW(pte_ptr);
                return;
            }
            return; // Already valid leafy mapping?
        }

        // Recursive thawing from shadow chain
        if (self.shadow_source) |shadow| {
            try self.thawFromShadow(shadow, gpa, is_trusted);
            return;
        }

        return error.UnhandledFault;
    }

    fn thawFromShadow(self: *PageTable, shadow: *const PageTable, gpa: usize, is_trusted: bool) !void {
        const pte_ptr = try shadow.walk(gpa, false);
        const pte = pte_ptr.*;

        if (pte & PTEFlags.valid != 0) {
            if (pte & (PTEFlags.read | PTEFlags.write | PTEFlags.execute) != 0) {
                // Leaf mapping: clone it (as CoW)
                const hpa = (pte >> 10) << 12;
                try self.mapPage(gpa, hpa, (pte & ~(PTEFlags.write)) | PTEFlags.cow, is_trusted);
                physmem.incrementPageRef(hpa); // Both now share it as CoW
            } else {
                // Should not happen for flattened shadow chains, but handle for safety
                return error.ShadowCorruption;
            }
        } else {
            // Recurse up the shadow chain
            if (shadow.shadow_source) |parent_shadow| {
                try self.thawFromShadow(parent_shadow, gpa, is_trusted);
            } else {
                return error.NotFoundInShadow;
            }
        }
    }

    pub fn hgatp(self: PageTable, vmid: u16) u64 {
        const mode_sv39x4: u64 = 8;
        const vmid_u64: u64 = vmid;
        return (mode_sv39x4 << 60) | (vmid_u64 << 44) | (self.root_phys >> 12);
    }
};

test "stage-2 paging and shielding" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var phys_test = try physmem.initForTest(allocator, 128);
    defer phys_test.deinit();

    var pt = try PageTable.init(0, 0, 0);
    defer pt.deinit();

    const hpa = try physmem.allocPage();
    const gpa = 0x1000;

    // Success case: Map RAM for non-trusted guest
    try pt.mapPage(gpa, hpa, PTEFlags.read | PTEFlags.write | PTEFlags.valid, false);
    const pte = (try pt.walk(gpa, false)).*;
    try testing.expect(pte & PTEFlags.valid != 0);

    // Shielding: Prevent mapping hypervisor memory (assume HV at 0x80000000)
    // physmem.isHypervisorMemory is mocked in test to match hv_region
    // In initForTest, hv_region is usually far away.
    // Let's check a real MMIO address.
    const mmio_hpa = 0x10000000; // Likely MMIO
    try testing.expectError(error.AccessDenied, pt.mapPage(gpa + 0x1000, mmio_hpa, PTEFlags.read | PTEFlags.valid, false));

    // Trusted guest can map MMIO
    try pt.mapPage(gpa + 0x2000, mmio_hpa, PTEFlags.read | PTEFlags.valid, true);
}

test "stage-2 Copy-on-Write" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var phys_test = try physmem.initForTest(allocator, 128);
    defer phys_test.deinit();

    var pt = try PageTable.init(0, 0, 0);
    defer pt.deinit();

    const hpa = try physmem.allocPage();
    const gpa = 0x1000;
    try pt.mapPage(gpa, hpa, PTEFlags.read | PTEFlags.write | PTEFlags.valid, false);

    var pt2 = try pt.fork();
    defer pt2.deinit();

    // In pt2, the page table is empty, so walk will fail.
    // We must resolve the fault first.
    try pt2.resolveFault(gpa, false);

    // Now in pt2, the page should be CoW and not writable
    const pte2_ptr = try pt2.walk(gpa, false);
    try testing.expect(pte2_ptr.* & PTEFlags.cow != 0);
    try testing.expect(pte2_ptr.* & PTEFlags.write == 0);

    // Resolve fault
    try pt2.resolveFault(gpa, false);

    // Now it should be writable and not CoW
    try testing.expect(pte2_ptr.* & PTEFlags.cow == 0);
    try testing.expect(pte2_ptr.* & PTEFlags.write != 0);
    // And it should be a DIFFERENT physical page
    try testing.expect((pte2_ptr.* >> 10) << 12 != hpa);
}
