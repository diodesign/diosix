// Unified guest memory space management
// High-level abstraction that handles either H-extension paging or PMP.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const physmem = @import("physmem.zig");
const sv39x4 = @import("arch/riscv64/sv39x4.zig");
const pmp = @import("arch/riscv64/pmp.zig");
const riscv = @import("arch/riscv64/riscv.zig");

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
                try pmp_config.addRegion(ram_base, hv_size, 0); // flags = 0 (no access)
            }

            // 2. Allow access to the entire 64-bit physical address space for everything else.
            // Under PMP check ordering, the hypervisor range denial is matched first,
            // so this securely enables direct guest S-mode/U-mode access to RAM and all MMIO peripherals.
            try pmp_config.addRegion(0, ~@as(usize, 0), pmp.PMPAccess.read | pmp.PMPAccess.write | pmp.PMPAccess.execute);

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
            try self.pmp_config.?.addRegion(hpa, size, @intCast(flags));
        }
    }

    // Fork this memory space
    pub fn fork(self: *GuestSpace) !GuestSpace {
        if (self.mode == .h_paging) {
            return GuestSpace{
                .mode = .h_paging,
                .paging = try self.paging.?.fork(),
                .pmp_config = null,
                .is_trusted = self.is_trusted,
                .base_gpa = self.base_gpa,
                .base_hpa = self.base_hpa,
                .range_size = self.range_size,
                .is_ram_allocated = false,
                .allocator = self.allocator,
            };
        } else {
            const child_base_hpa = if (self.range_size > 0) blk: {
                const order: u8 = @intCast(std.math.log2(self.range_size / physmem.PageSize));
                const new_base = try physmem.allocPageSelection(order);
                @memcpy(@as([*]u8, @ptrFromInt(new_base))[0..self.range_size], @as([*]const u8, @ptrFromInt(self.base_hpa))[0..self.range_size]);
                break :blk new_base;
            } else 0;

            var pmp_config = try pmp.PMPConfig.init(self.allocator);

            // 1. Deny access to the hypervisor's private DRAM region [0x80000000, child_base_hpa)
            const hv_size = child_base_hpa - 0x80000000;
            if (hv_size > 0) {
                try pmp_config.addRegion(0x80000000, hv_size, 0); // flags = 0 (no access)
            }

            // 2. Allow access to the entire 64-bit physical address space for everything else.
            try pmp_config.addRegion(0, ~@as(usize, 0), pmp.PMPAccess.read | pmp.PMPAccess.write | pmp.PMPAccess.execute);

            return GuestSpace{
                .mode = .pmp_fallback,
                .paging = null,
                .pmp_config = pmp_config,
                .is_trusted = self.is_trusted,
                .base_gpa = self.base_gpa,
                .base_hpa = child_base_hpa,
                .range_size = self.range_size,
                .is_ram_allocated = if (self.range_size > 0) true else false,
                .allocator = self.allocator,
            };
        }
    }

    // Handle a guest physical page fault (CoW, shadow thawing, or error)
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
            riscv.writeHgatp(self.paging.?.hgatp(vmid));
        } else {
            self.pmp_config.?.apply();
        }
    }

    // Translate a Guest Physical Address to a Host Physical Address
    pub fn translateGPA(self: *const GuestSpace, gpa: usize) !usize {
        if (self.mode == .h_paging) {
            const pt = self.paging.?;
            // Check if it's within the optimized identity/offset range
            if (gpa >= pt.root_base_gpa and gpa < pt.root_base_gpa + pt.root_range_size) {
                return gpa - pt.root_base_gpa + pt.root_base_hpa;
            }
            // Otherwise, perform a page table walk
            const pte_ptr = pt.walk(gpa, false) catch return error.TranslationFailed;
            const hpa = (pte_ptr.* >> 10) << 12;
            return hpa + (gpa % physmem.PageSize);
        } else {
            // PMP mode: resolve the GPA through the optimized identity mapping.
            if (gpa >= self.base_gpa and gpa < self.base_gpa + self.range_size) {
                return self.base_hpa + (gpa - self.base_gpa);
            }
            return error.TranslationFailed;
        }
    }
};
