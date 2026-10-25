// RISC-V SV39x4 Stage-2 (G-stage) Page Table Management.
//
// SV39x4 provides a 41-bit Guest Physical Address (GPA) space by using
// a 16 KiB root-level page table (compared to 4 KiB for S-mode SV39).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const physmem = @import("../../../../core/physmem.zig");

pub const SV39x4Error = error{
    InvalidAlignment,
    MappingOverlap,
    WalkFailed,
    InvalidAddress,
};

pub const MAX_GPA: usize = 1 << 41; // 2 TiB SV39x4 Stage-2 GPA limit

pub const PTEFlags = struct {
    pub const valid: u64 = 1 << 0;
    pub const read: u64 = 1 << 1;
    pub const write: u64 = 1 << 2;
    pub const execute: u64 = 1 << 3;
    pub const user: u64 = 1 << 4;
    pub const global: u64 = 1 << 5;
    pub const accessed: u64 = 1 << 6;
    pub const dirty: u64 = 1 << 7;

    // Software-defined flags (bits 9:8).
    pub const cow: u64 = 1 << 8;
    pub const demand: u64 = 1 << 9;

    pub const rwx: u64 = read | write | execute;
    pub const leaf_rw_user: u64 =
        read | write | valid | accessed | dirty | user;
    pub const leaf_rwx_user: u64 =
        read | write | execute | valid | accessed | dirty | user;
};

pub const PTE = u64;

pub const PTE_PPN_SHIFT: u6 = 10;
pub const PTE_FLAGS_MASK: u64 = (1 << PTE_PPN_SHIFT) - 1;
pub const PAGE_SHIFT: u6 = 12;

pub const VPN0_SHIFT: u6 = 12;
pub const VPN1_SHIFT: u6 = 21;
pub const VPN2_SHIFT: u6 = 30;

pub const VPN_MASK: usize = 0x1ff;
pub const ROOT_VPN_MASK: usize = 0x7ff;

pub const HGATP_MODE_SV39X4: u64 = 8;
pub const HGATP_MODE_SHIFT: u6 = 60;
pub const HGATP_VMID_SHIFT: u6 = 44;

pub inline fn pteToHpa(pte: PTE) usize {
    return (pte >> PTE_PPN_SHIFT) << PAGE_SHIFT;
}

pub inline fn hpaToPte(hpa: usize) PTE {
    return (hpa >> PAGE_SHIFT) << PTE_PPN_SHIFT;
}

pub const ROOT_PAGE_ORDER: u6 = 2; // 2^2 = 4 pages = 16 KiB
pub const ROOT_TABLE_SIZE: usize = physmem.PageSize << ROOT_PAGE_ORDER;
pub const ROOT_ENTRIES: usize = ROOT_TABLE_SIZE / @sizeOf(PTE); // 2048
pub const LEVEL_ENTRIES: usize = physmem.PageSize / @sizeOf(PTE); // 512
pub const DEFAULT_GUEST_DRAM_LIMIT: usize = 512 * 1024 * 1024; // 512 MiB

fn getIdx(gpa: usize, level: u8) usize {
    return switch (level) {
        2 => (gpa >> VPN2_SHIFT) & ROOT_VPN_MASK, // 11 bits for root
        1 => (gpa >> VPN1_SHIFT) & VPN_MASK, // 9 bits
        0 => (gpa >> VPN0_SHIFT) & VPN_MASK, // 9 bits
        else => unreachable,
    };
}

pub const PageTable = struct {
    root_phys: usize, // Root table (order-2 block = 16 KiB)

    // For Root VM identity/offset mapping: if range_size > 0, faults in this
    // GPA range are resolved via (gpa - base_gpa + base_hpa).
    root_base_gpa: usize = 0,
    root_base_hpa: usize = 0,
    root_range_size: usize = 0,

    pub fn init(
        base_gpa: usize,
        base_hpa: usize,
        range_size: usize,
    ) !PageTable {
        const addr = try physmem.allocPageSelection(ROOT_PAGE_ORDER);
        @memset(@as([*]u8, @ptrFromInt(addr))[0..ROOT_TABLE_SIZE], 0);
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
        if (addr == 0) return;
        const ptes = @as([*]PTE, @ptrFromInt(addr));
        const num_entries = if (level == 2) ROOT_ENTRIES else LEVEL_ENTRIES;

        for (0..num_entries) |i| {
            const pte = ptes[i];
            if ((pte & PTEFlags.valid) != 0) {
                if ((pte & PTEFlags.rwx) == 0) {
                    const next_addr = pteToHpa(pte);
                    self.destroyTable(next_addr, level - 1);
                } else {
                    const hpa = pteToHpa(pte);
                    if (physmem.isRam(hpa, physmem.PageSize) and
                        physmem.isManaged(hpa))
                    {
                        physmem.decrementPageRef(hpa);
                    }
                }
            }
        }
        physmem.freePage(addr);
    }

    /// Map a single 4 KiB page.
    pub fn mapPage(
        self: *PageTable,
        gpa: usize,
        hpa: usize,
        flags: u64,
        is_trusted: bool,
    ) !void {
        if (gpa >= MAX_GPA) return SV39x4Error.InvalidAddress;
        if (gpa % physmem.PageSize != 0 or hpa % physmem.PageSize != 0) {
            return SV39x4Error.InvalidAlignment;
        }

        // Security shields: prevent mapping hypervisor memory, and prevent
        // untrusted guests from directly mapping host physical MMIO.
        if (physmem.isHypervisorMemory(hpa, physmem.PageSize)) {
            return error.AccessDenied;
        }
        if (!is_trusted and
            (hpa < physmem.getRamBase() or
                physmem.isMmio(hpa, physmem.PageSize)))
        {
            return error.AccessDenied;
        }

        var ptes_phys = self.root_phys;
        var level: u8 = 2;

        while (level > 0) : (level -= 1) {
            const index = getIdx(gpa, level);
            const ptes = @as([*]PTE, @ptrFromInt(ptes_phys));

            if ((ptes[index] & PTEFlags.valid) == 0) {
                const next_table = try physmem.allocPage();
                const tbl_bytes =
                    @as([*]u8, @ptrFromInt(next_table))[0..physmem.PageSize];
                @memset(tbl_bytes, 0);
                ptes[index] = hpaToPte(next_table) | PTEFlags.valid;
            } else if ((ptes[index] & PTEFlags.rwx) != 0) {
                return SV39x4Error.MappingOverlap;
            }

            ptes_phys = pteToHpa(ptes[index]);
        }

        const index = getIdx(gpa, 0);
        const ptes = @as([*]PTE, @ptrFromInt(ptes_phys));

        if ((ptes[index] & PTEFlags.valid) != 0) {
            if (pteToHpa(ptes[index]) == hpa) return;
            return SV39x4Error.MappingOverlap;
        }

        ptes[index] = hpaToPte(hpa) | flags |
            PTEFlags.valid | PTEFlags.accessed | PTEFlags.dirty;
        if (physmem.isRam(hpa, physmem.PageSize) and physmem.isManaged(hpa)) {
            physmem.incrementPageRef(hpa);
        }
    }

    /// Unmap a single 4 KiB page and decrement its refcount.
    pub fn unmapPage(self: *PageTable, gpa: usize) void {
        if (gpa >= MAX_GPA) return;
        if (self.walk(gpa, false)) |pte_ptr| {
            const pte = pte_ptr.*;
            if ((pte & PTEFlags.valid) != 0) {
                const hpa = pteToHpa(pte);
                pte_ptr.* = 0;
                if (physmem.isRam(hpa, physmem.PageSize) and
                    physmem.isManaged(hpa))
                {
                    physmem.decrementPageRef(hpa);
                }
            }
        } else |_| {}
    }

    /// Walk the page table to find the leaf entry for the given GPA.
    /// If `create` is true, intermediate tables are allocated as needed.
    pub fn walk(self: *const PageTable, gpa: usize, create: bool) !*PTE {
        if (self.root_phys == 0 or gpa >= MAX_GPA) return error.WalkFailed;
        var ptes_phys = self.root_phys;
        var level: u8 = 2;

        while (level > 0) : (level -= 1) {
            if (ptes_phys == 0) return error.WalkFailed;
            const index = getIdx(gpa, level);
            const ptes = @as([*]PTE, @ptrFromInt(ptes_phys));

            if ((ptes[index] & PTEFlags.valid) == 0) {
                if (!create) return error.WalkFailed;
                const next_table = try physmem.allocPage();
                const tbl_bytes =
                    @as([*]u8, @ptrFromInt(next_table))[0..physmem.PageSize];
                @memset(tbl_bytes, 0);
                ptes[index] = hpaToPte(next_table) | PTEFlags.valid;
            } else if ((ptes[index] & PTEFlags.rwx) != 0) {
                return SV39x4Error.WalkFailed;
            }

            ptes_phys = pteToHpa(ptes[index]);
        }

        const index = getIdx(gpa, 0);
        const ptes = @as([*]PTE, @ptrFromInt(ptes_phys));
        return &ptes[index];
    }

    /// Entry point for direct PageTable fault resolution.
    pub fn resolveFault(self: *PageTable, gpa: usize, is_trusted: bool) !void {
        const gpa_page = std.mem.alignBackward(usize, gpa, physmem.PageSize);

        if (self.walk(gpa, false)) |pte_ptr| {
            if ((pte_ptr.* & PTEFlags.valid) != 0) return;
        } else |_| {}

        const dram_limit = if (self.root_range_size > 0)
            self.root_range_size
        else
            DEFAULT_GUEST_DRAM_LIMIT;

        const in_guest_dram = (self.root_base_gpa > 0 and
            gpa >= self.root_base_gpa and
            (gpa - self.root_base_gpa) < dram_limit) or
            (self.root_base_gpa == 0 and
                physmem.isRam(gpa, physmem.PageSize) and
                gpa < dram_limit);

        // Identity-map standard MMIO/peripheral regions (below RAM or PCIe).
        if (!in_guest_dram and
            (gpa < physmem.getRamBase() or
                physmem.isMmio(gpa, physmem.PageSize)))
        {
            if (!is_trusted) return error.AccessDenied;
            try self.mapPage(
                gpa_page,
                gpa_page,
                PTEFlags.leaf_rw_user,
                is_trusted,
            );
            return;
        }

        // Root VM pre-allocated DRAM mapping.
        if (self.root_base_hpa > 0 and in_guest_dram) {
            const offset = gpa - self.root_base_gpa;
            const hpa = std.math.add(usize, self.root_base_hpa, offset) catch
                return error.UnhandledFault;
            const hpa_page = std.mem.alignBackward(
                usize,
                hpa,
                physmem.PageSize,
            );
            if (physmem.isHypervisorMemory(hpa_page, physmem.PageSize)) {
                return error.AccessDenied;
            }
            try self.mapPage(
                gpa_page,
                hpa_page,
                PTEFlags.leaf_rwx_user,
                is_trusted,
            );
            return;
        }

        // On-demand anonymous page allocation for guest DRAM.
        if (in_guest_dram) {
            const new_hpa = try physmem.allocPage();
            errdefer physmem.freePage(new_hpa);
            @memset(
                @as([*]u8, @ptrFromInt(new_hpa))[0..physmem.PageSize],
                0,
            );
            try self.mapPage(
                gpa_page,
                new_hpa,
                PTEFlags.leaf_rwx_user,
                is_trusted,
            );
            physmem.decrementPageRef(new_hpa);
            return;
        }

        return error.UnhandledFault;
    }

    pub fn hgatp(self: PageTable, vmid: u16) u64 {
        const vmid_u64: u64 = vmid;
        return (HGATP_MODE_SV39X4 << HGATP_MODE_SHIFT) |
            (vmid_u64 << HGATP_VMID_SHIFT) |
            (self.root_phys >> PAGE_SHIFT);
    }
};

test "stage-2 paging and shielding" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    const allocator = testing.allocator;

    var phys_test = try physmem.initForTest(allocator, 128);
    defer phys_test.deinit();

    var pt = try PageTable.init(0, 0, 0);
    defer pt.deinit();

    const hpa = try physmem.allocPage();
    const gpa = 0x1000;
    const rw_valid = PTEFlags.read | PTEFlags.write | PTEFlags.valid;

    // Success case: map RAM for non-trusted guest.
    try pt.mapPage(gpa, hpa, rw_valid, false);
    physmem.decrementPageRef(hpa);
    const pte = (try pt.walk(gpa, false)).*;
    try testing.expect((pte & PTEFlags.valid) != 0);

    // Shielding: prevent mapping hypervisor memory.
    const hv_hpa = physmem.getHvRegion().base;
    if (hv_hpa > 0) {
        const ro_flags = PTEFlags.read | PTEFlags.valid;
        try testing.expectError(
            error.AccessDenied,
            pt.mapPage(gpa + 0x1000, hv_hpa, ro_flags, false),
        );
    }

    // Shielding: prevent untrusted guest from mapping host MMIO / peripherals.
    const mmio_hpa: usize = 0x10000000;
    try testing.expectError(
        error.AccessDenied,
        pt.mapPage(mmio_hpa, mmio_hpa, PTEFlags.read | PTEFlags.valid, false),
    );
    try testing.expectError(
        error.AccessDenied,
        pt.resolveFault(mmio_hpa, false),
    );
}
