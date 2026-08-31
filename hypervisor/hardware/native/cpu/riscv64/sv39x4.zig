// RISC-V SV39x4 Stage-2 (G-stage) Page Table Management
//
// SV39x4 provides a 41-bit Guest Physical Address (GPA) space by using
// a 16KB root-level page table (compared to 4KB for S-mode SV39).

const std = @import("std");
const builtin = @import("builtin");
const physmem = @import("../../../../core/physmem.zig");
const debug = @import("../../../../core/debug.zig");
const riscv = @import("mod.zig");

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

    // For Root VM identity/offset mapping
    // If range_size > 0, faults in this GPA range are resolved via (gpa - base_gpa + base_hpa)
    root_base_gpa: usize = 0,
    root_base_hpa: usize = 0,
    root_range_size: usize = 0,

    pub fn init(base_gpa: usize, base_hpa: usize, range_size: usize) !PageTable {
        const addr = try physmem.allocPageSelection(2);
        @memset(@as([*]u8, @ptrFromInt(addr))[0..16384], 0);
        return PageTable{
            .root_phys = addr,
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
        _ = is_trusted;
        if (gpa % physmem.PageSize != 0 or hpa % physmem.PageSize != 0) return SV39x4Error.InvalidAlignment;

        // Security Shields:
        // Prevent mapping hypervisor memory
        if (physmem.isHypervisorMemory(hpa, physmem.PageSize)) return error.AccessDenied;

        var ptes_phys = self.root_phys;
        var level: u8 = 2;

        while (level > 0) : (level -= 1) {
            const index = self.getIdx(gpa, level);
            const ptes = @as([*]PTE, @ptrFromInt(ptes_phys));

            if (ptes[index] & PTEFlags.valid == 0) {
                // Create next level table
                const next_table = try physmem.allocPage();
                @memset(@as([*]u8, @ptrFromInt(next_table))[0..physmem.PageSize], 0);
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

    // Unmap a single 4KB page and decrement its refcount
    pub fn unmapPage(self: *PageTable, gpa: usize) void {
        if (self.walk(gpa, false)) |pte_ptr| {
            const pte = pte_ptr.*;
            if (pte & PTEFlags.valid != 0) {
                const hpa = (pte >> 10) << 12;
                pte_ptr.* = 0;
                if (physmem.isRam(hpa, physmem.PageSize) and physmem.isManaged(hpa)) {
                    physmem.decrementPageRef(hpa);
                }
            }
        } else |_| {}
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
                @memset(@as([*]u8, @ptrFromInt(next_table))[0..physmem.PageSize], 0);
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

    fn getIdx(self: *const PageTable, gpa: usize, level: u8) usize {
        _ = self;
        return switch (level) {
            2 => (gpa >> 30) & 0x7FF, // 11 bits for root
            1 => (gpa >> 21) & 0x1FF, // 9 bits
            0 => (gpa >> 12) & 0x1FF, // 9 bits
            else => unreachable,
        };
    }

    // Entry point for fault handling
    pub fn resolveFault(self: *PageTable, gpa: usize, is_trusted: bool) !void {
        // Identity map standard MMIO/peripheral regions (below RAM or PCIe BARs)
        if (gpa < physmem.getRamBase() or physmem.isMmio(gpa, physmem.PageSize)) {
            const gpa_page = gpa & ~(physmem.PageSize - 1);
            try self.mapPage(gpa_page, gpa_page, PTEFlags.read | PTEFlags.write | PTEFlags.valid | PTEFlags.accessed | PTEFlags.dirty | PTEFlags.user, is_trusted);
            return;
        }

        // Allow trusted guests to map host RAM (excluding hypervisor protected memory)
        if (is_trusted and physmem.isRam(gpa, physmem.PageSize)) {
            const gpa_page = gpa & ~(physmem.PageSize - 1);
            if (!physmem.isHypervisorMemory(gpa_page, physmem.PageSize)) {
                try self.mapPage(gpa_page, gpa_page, PTEFlags.read | PTEFlags.write | PTEFlags.execute | PTEFlags.valid | PTEFlags.accessed | PTEFlags.dirty | PTEFlags.user, is_trusted);
                return;
            }
        }

        // Check if already mapped in this table
        if (self.walk(gpa, false)) |pte_ptr| {
            const pte = pte_ptr.*;
            if (pte & PTEFlags.valid != 0) {
                return; // Already valid leaf mapping
            }
        } else |_| {}

        // Root VM pre-allocated DRAM mapping
        if (self.root_base_hpa > 0 and gpa >= self.root_base_gpa and gpa < self.root_base_gpa + (512 * 1024 * 1024)) {
            const hpa = gpa - self.root_base_gpa + self.root_base_hpa;
            const gpa_page = gpa & ~(physmem.PageSize - 1);
            const hpa_page = hpa & ~(physmem.PageSize - 1);
            if (physmem.isHypervisorMemory(hpa_page, physmem.PageSize)) {
                return error.AccessDenied;
            }
            try self.mapPage(gpa_page, hpa_page, PTEFlags.read | PTEFlags.write | PTEFlags.execute | PTEFlags.valid | PTEFlags.accessed | PTEFlags.dirty | PTEFlags.user, is_trusted);
            return;
        }

        // On-demand anonymous page allocation for guest DRAM
        if (gpa >= self.root_base_gpa and gpa < self.root_base_gpa + (512 * 1024 * 1024)) {
            const gpa_page = gpa & ~(physmem.PageSize - 1);
            const new_hpa = try physmem.allocPage();
            @memset(@as([*]u8, @ptrFromInt(new_hpa))[0..physmem.PageSize], 0);
            try self.mapPage(gpa_page, new_hpa, PTEFlags.read | PTEFlags.write | PTEFlags.execute | PTEFlags.valid | PTEFlags.accessed | PTEFlags.dirty | PTEFlags.user, is_trusted);
            return;
        }

        return error.UnhandledFault;
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

    // Shielding: Prevent mapping hypervisor memory
    const hv_hpa = physmem.getHvRegion().base;
    if (hv_hpa > 0) {
        try testing.expectError(error.AccessDenied, pt.mapPage(gpa + 0x1000, hv_hpa, PTEFlags.read | PTEFlags.valid, false));
    }
}
