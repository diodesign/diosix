// RISC-V Physical Memory Protection (PMP) management
// Used as a fallback for guest isolation when H-extension is missing.
//
// PMP uses Top-of-Range (TOR) mode which requires two entries per region:
// entry N = base address, entry N+1 = top address with TOR config.
// Typical hardware provides 16 PMP entries, so we support up to 7 regions
// (14 entries) plus one region reserved for the deny-all default.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const physmem = @import("physmem.zig");
const debug = @import("debug.zig");

const is_test = builtin.is_test;

pub const PMPError = error{
    TooManyRegions,
    InvalidAlignment,
    AddressNotFound,
};

pub const PMPAccess = struct {
    pub const read: u8 = 1 << 0;
    pub const write: u8 = 1 << 1;
    pub const execute: u8 = 1 << 2;
    pub const tor: u8 = 1 << 3; // Top of Range mode
};

pub const Region = struct {
    base: usize,
    size: usize,
    flags: u8,
};

// Maximum number of PMP regions we support (7 TOR regions = 14 entries + 2 deny-all).
pub const MAX_REGIONS: usize = 7;

pub const PMPConfig = struct {
    regions: std.ArrayList(Region),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !PMPConfig {
        return PMPConfig{
            .regions = std.ArrayList(Region).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PMPConfig) void {
        self.regions.deinit(self.allocator);
    }

    pub fn addRegion(self: *PMPConfig, base: usize, size: usize, flags: u8) !void {
        if (self.regions.items.len >= MAX_REGIONS) return PMPError.TooManyRegions;
        try self.regions.append(self.allocator, .{ .base = base, .size = size, .flags = flags });
    }

    /// Apply this PMP configuration to the current physical core.
    /// Called during context switch to a guest vcore.
    ///
    /// Strategy:
    /// First, deny all access by default (entry 0: NAPOT covering all memory, no permissions).
    /// Then, for each guest region, program a TOR pair (base + top) with RWX permissions.
    ///
    /// TOR mode: pmpaddrN = base >> 2, pmpaddrN+1 = (base + size) >> 2, pmpcfgN+1 = TOR | perms.
    pub fn apply(self: *PMPConfig) void {
        if (is_test) return;

        // First clear all PMP entries to deny-all state.
        clearAllPmp();

        // Program each region.
        var entry: usize = 0;
        for (self.regions.items) |reg| {
            if (reg.base == 0 and reg.size == ~@as(usize, 0)) {
                if (entry >= 16) break;
                writePmpAddr(entry, ~@as(usize, 0)); // Entire 64-bit space
                writePmpCfg(entry, 0x18 | (reg.flags & 0x07)); // NAPOT + RWX bits
                entry += 1;
            } else {
                if (entry + 2 > 16) break; // Hardware limit.
                const base_shifted = reg.base >> 2;
                const top_shifted = (reg.base + reg.size) >> 2;
                const cfg: u8 = PMPAccess.tor | (reg.flags & 0x07); // TOR + RWX bits

                writePmpAddr(entry, base_shifted);
                writePmpAddr(entry + 1, top_shifted);
                writePmpCfg(entry + 1, cfg);

                entry += 2;
            }
        }

        // Final entry: deny-all for everything else.
        // Set the last used entry+1 to NAPOT covering all remaining space with no perms.
        if (entry < 16) {
            writePmpAddr(entry, ~@as(usize, 0)); // All ones = entire address space (NAPOT)
            writePmpCfg(entry, 0x18); // NAPOT mode (bits 4:3 = 11), no R/W/X
        }
    }

    pub fn clearAllPmp() void {
        asm volatile ("csrw pmpcfg0, zero");
        asm volatile ("csrw pmpcfg2, zero");
        asm volatile ("csrw pmpaddr0, zero");
        asm volatile ("csrw pmpaddr1, zero");
        asm volatile ("csrw pmpaddr2, zero");
        asm volatile ("csrw pmpaddr3, zero");
        asm volatile ("csrw pmpaddr4, zero");
        asm volatile ("csrw pmpaddr5, zero");
        asm volatile ("csrw pmpaddr6, zero");
        asm volatile ("csrw pmpaddr7, zero");
        asm volatile ("csrw pmpaddr8, zero");
        asm volatile ("csrw pmpaddr9, zero");
        asm volatile ("csrw pmpaddr10, zero");
        asm volatile ("csrw pmpaddr11, zero");
        asm volatile ("csrw pmpaddr12, zero");
        asm volatile ("csrw pmpaddr13, zero");
        asm volatile ("csrw pmpaddr14, zero");
        asm volatile ("csrw pmpaddr15, zero");
    }

    /// Write a value to pmpaddr[index]. Only entries 0-15 are supported.
    pub fn writePmpAddr(index: usize, value: usize) void {
        switch (index) {
            0 => asm volatile ("csrw pmpaddr0, %[val]"
                :
                : [val] "r" (value),
            ),
            1 => asm volatile ("csrw pmpaddr1, %[val]"
                :
                : [val] "r" (value),
            ),
            2 => asm volatile ("csrw pmpaddr2, %[val]"
                :
                : [val] "r" (value),
            ),
            3 => asm volatile ("csrw pmpaddr3, %[val]"
                :
                : [val] "r" (value),
            ),
            4 => asm volatile ("csrw pmpaddr4, %[val]"
                :
                : [val] "r" (value),
            ),
            5 => asm volatile ("csrw pmpaddr5, %[val]"
                :
                : [val] "r" (value),
            ),
            6 => asm volatile ("csrw pmpaddr6, %[val]"
                :
                : [val] "r" (value),
            ),
            7 => asm volatile ("csrw pmpaddr7, %[val]"
                :
                : [val] "r" (value),
            ),
            8 => asm volatile ("csrw pmpaddr8, %[val]"
                :
                : [val] "r" (value),
            ),
            9 => asm volatile ("csrw pmpaddr9, %[val]"
                :
                : [val] "r" (value),
            ),
            10 => asm volatile ("csrw pmpaddr10, %[val]"
                :
                : [val] "r" (value),
            ),
            11 => asm volatile ("csrw pmpaddr11, %[val]"
                :
                : [val] "r" (value),
            ),
            12 => asm volatile ("csrw pmpaddr12, %[val]"
                :
                : [val] "r" (value),
            ),
            13 => asm volatile ("csrw pmpaddr13, %[val]"
                :
                : [val] "r" (value),
            ),
            14 => asm volatile ("csrw pmpaddr14, %[val]"
                :
                : [val] "r" (value),
            ),
            15 => asm volatile ("csrw pmpaddr15, %[val]"
                :
                : [val] "r" (value),
            ),
            else => {},
        }
    }

    /// Write configuration for a single PMP entry.
    /// PMP configs are packed 4-per-register in pmpcfg0 (entries 0-7) and pmpcfg2 (entries 8-15).
    pub fn writePmpCfg(index: usize, cfg: u8) void {
        if (index >= 16) return;

        // Determine which pmpcfg register and which byte within it.
        const reg_index = index / 8; // 0 → pmpcfg0, 1 → pmpcfg2
        const byte_pos: u6 = @intCast((index % 8) * 8);
        const mask = ~(@as(usize, 0xFF) << byte_pos);
        const value = @as(usize, cfg) << byte_pos;

        if (reg_index == 0) {
            var current = asm volatile ("csrr %[ret], pmpcfg0"
                : [ret] "=r" (-> usize),
            );
            current = (current & mask) | value;
            asm volatile ("csrw pmpcfg0, %[val]"
                :
                : [val] "r" (current),
            );
        } else {
            var current = asm volatile ("csrr %[ret], pmpcfg2"
                : [ret] "=r" (-> usize),
            );
            current = (current & mask) | value;
            asm volatile ("csrw pmpcfg2, %[val]"
                :
                : [val] "r" (current),
            );
        }
    }
};

extern const __hypervisor_start: u8;
extern const __bss_start: u8;
extern const __hypervisor_end: u8;

pub fn applyEmulatorPmp(cpu_core_id: usize, base_hpa: usize, range_size: usize) void {
    if (is_test) return;

    PMPConfig.clearAllPmp();

    const hv_start = @intFromPtr(&__hypervisor_start);
    const bss_start = @intFromPtr(&__bss_start);
    const hv_end = @intFromPtr(&__hypervisor_end);

    // Entry 0 and 1: Hypervisor text + rodata (RX)
    PMPConfig.writePmpAddr(0, hv_start >> 2);
    PMPConfig.writePmpAddr(1, bss_start >> 2);
    PMPConfig.writePmpCfg(1, PMPAccess.tor | PMPAccess.read | PMPAccess.execute);

    // Entry 2 and 3: Hypervisor data + bss (RW)
    PMPConfig.writePmpAddr(2, bss_start >> 2);
    PMPConfig.writePmpAddr(3, hv_end >> 2);
    PMPConfig.writePmpCfg(3, PMPAccess.tor | PMPAccess.read | PMPAccess.write);

    // Entry 4 and 5: Current CPU core slab (RW)
    const CPU_SLAB_SHIFT = 20;
    const CPU_SLAB_SIZE = 1 << CPU_SLAB_SHIFT;
    const slab_base = hv_end + (cpu_core_id << CPU_SLAB_SHIFT);
    PMPConfig.writePmpAddr(4, slab_base >> 2);
    PMPConfig.writePmpAddr(5, (slab_base + CPU_SLAB_SIZE) >> 2);
    PMPConfig.writePmpCfg(5, PMPAccess.tor | PMPAccess.read | PMPAccess.write);

    // Entry 6 and 7: Guest RAM (RW)
    if (range_size > 0) {
        PMPConfig.writePmpAddr(6, base_hpa >> 2);
        PMPConfig.writePmpAddr(7, (base_hpa + range_size) >> 2);
        PMPConfig.writePmpCfg(7, PMPAccess.tor | PMPAccess.read | PMPAccess.write);
    }

    // Entry 8: Deny-all for the rest of the address space (NAPOT mode, no perms)
    PMPConfig.writePmpAddr(8, ~@as(usize, 0));
    PMPConfig.writePmpCfg(8, 0x18); // NAPOT mode (bits 4:3 = 11), no R/W/X
}
