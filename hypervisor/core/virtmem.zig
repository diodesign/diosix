// Virtual memory and virtualization management
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("riscv.zig");
const physmem = @import("physmem.zig");
const debug = @import("debug.zig");

pub const VirtMemError = error{
    LevelUnsupported,
    PageAlreadyMapped,
};

// Stage-2 Page Table Entry (PTE) bits for Sv39x4
pub const PTE_V = (1 << 0);
pub const PTE_R = (1 << 1);
pub const PTE_W = (1 << 2);
pub const PTE_X = (1 << 3);
pub const PTE_U = (1 << 4);
pub const PTE_G = (1 << 5);
pub const PTE_A = (1 << 6);
pub const PTE_D = (1 << 7);

pub const PTE_RWX = PTE_R | PTE_W | PTE_X;

// A Stage 2 page table for a guest
pub const Stage2PageTable = struct {
    root_phys: usize, // Physical address of the root page table

    pub fn init() !Stage2PageTable {
        // Allocate a root page
        const root = try physmem.allocPage();
        return Stage2PageTable{ .root_phys = root };
    }

    // Map a guest physical page to a host physical page
    // gpa = guest physical address (page aligned)
    // hpa = host physical address (page aligned)
    pub fn mapPage(self: *Stage2PageTable, gpa: usize, hpa: usize, flags: usize) !void {
        var table: [*]usize = @ptrFromInt(self.root_phys);

        // Sv39 has 3 levels
        var level: usize = 2;
        while (level > 0) : (level -= 1) {
            const index = (gpa >> @intCast(12 + level * 9)) & 0x1FF;
            if (table[index] & PTE_V == 0) {
                // Allocate a new table level
                const new_table_phys = try physmem.allocPage();
                table[index] = ((new_table_phys >> 12) << 10) | PTE_V;
            }

            const next_table_phys = (table[index] >> 10) << 12;
            table = @ptrFromInt(next_table_phys);
        }

        const index = (gpa >> 12) & 0x1FF;
        if (table[index] & PTE_V != 0) return VirtMemError.PageAlreadyMapped;

        table[index] = ((hpa >> 12) << 10) | flags | PTE_V | PTE_A | PTE_D;
    }

    // Return hgatp value for this page table
    pub fn getHgatp(self: *Stage2PageTable) usize {
        const mode: usize = 8; // Sv39
        return (mode << 60) | (self.root_phys >> 12);
    }
};

// Apply PMP restrictions for a non-H system
// This is a simplified version that just grants access to a single region
pub fn applyPmp(base: usize, size: usize) void {
    const end = base + size;

    // We use TOR (Top Of Range) mode which uses two PMP entries
    // entry 0: base address
    // entry 1: end address, with TOR set in cfg

    // Program PMPADDR0 with base >> 2
    asm volatile ("csrw pmpaddr0, %[val]"
        :
        : [val] "r" (base >> 2),
    );
    // Program PMPADDR1 with end >> 2
    asm volatile ("csrw pmpaddr1, %[val]"
        :
        : [val] "r" (end >> 2),
    );

    // Set PMPCFG0:
    // entry 0: 0 (OFF)
    // entry 1: 0x1F (TOR | R | W | X)
    const tor: usize = 0x08;
    const rwx: usize = 0x07;
    const pmp1cfg = tor | rwx;

    asm volatile ("csrw pmpcfg0, %[val]"
        :
        : [val] "r" (pmp1cfg << 8),
    );
}

test "stage 2 page table mapping" {
    const testing = std.testing;

    // We need mock physical memory initialized for this test
    physmem.pushFreePage(0x90000000); // For root table
    physmem.pushFreePage(0x90001000); // For level 1
    physmem.pushFreePage(0x90002000); // For level 0

    var pt = try Stage2PageTable.init();

    const gpa = 0x40000000;
    const hpa = 0x80000000;

    try pt.mapPage(gpa, hpa, PTE_R | PTE_W);

    // Check hgatp (Sv39 is mode 8)
    const hgatp = pt.getHgatp();
    try testing.expectEqual((@as(usize, 8) << 60) | (pt.root_phys >> 12), hgatp);

    // Verify the mapping manually by walking the table from root
    const root_table: [*]usize = @ptrFromInt(pt.root_phys);
    const lv2_idx = (gpa >> (12 + 2 * 9)) & 0x1FF;
    try testing.expect(root_table[lv2_idx] & PTE_V != 0);

    const lv1_phys = (root_table[lv2_idx] >> 10) << 12;
    const lv1_table: [*]usize = @ptrFromInt(lv1_phys);
    const lv1_idx = (gpa >> (12 + 1 * 9)) & 0x1FF;
    try testing.expect(lv1_table[lv1_idx] & PTE_V != 0);

    const lv0_phys = (lv1_table[lv1_idx] >> 10) << 12;
    const lv0_table: [*]usize = @ptrFromInt(lv0_phys);
    const lv0_idx = (gpa >> 12) & 0x1FF;
    try testing.expect(lv0_table[lv0_idx] & PTE_V != 0);
    try testing.expectEqual((hpa >> 12) << 10 | PTE_R | PTE_W | PTE_V | PTE_A | PTE_D, lv0_table[lv0_idx]);
}
