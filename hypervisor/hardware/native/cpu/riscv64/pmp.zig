// RISC-V Physical Memory Protection (PMP) management.
// Used as a fallback for guest isolation when the H-extension is missing.
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
const riscv = @import("mod.zig");

const is_test = builtin.is_test;

pub const PMPError = error{
    TooManyRegions,
    InvalidAlignment,
    AddressNotFound,
};

pub const PMPAccess = struct {
    pub const none: u8 = 0;
    pub const read: u8 = 1 << 0;
    pub const write: u8 = 1 << 1;
    pub const execute: u8 = 1 << 2;
    pub const rwx: u8 = read | write | execute;
    pub const tor: u8 = 1 << 3; // Top of Range mode
    pub const napot: u8 = 3 << 3; // Naturally Aligned Power of Two mode (0x18)
    pub const locked: u8 = 1 << 7; // Lock entry (enforced in M-mode too)
    pub const rwx_mask: u8 = rwx;
    pub const tor_locked_rwx: u8 = rwx | tor | locked;
};

pub const TOR_LOCKED_RWX: u8 = PMPAccess.tor_locked_rwx;
pub const PMP_ADDR_SHIFT: u6 = 2;
pub const ENTRIES_PER_PMPCFG: usize = 8;
pub const PMPCFG_ENTRY_BITS: usize = 8;
pub const PMPCFG_ENTRY_MASK: usize = 0xff;

pub const Region = struct {
    base: usize,
    size: usize,
    flags: u8,
};

// Maximum number of PMP regions we support (7 TOR regions = 14 entries).
pub const MAX_REGIONS: usize = 7;
pub const NUM_PMP_ENTRIES: usize = 16;

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

    pub fn addRegion(
        self: *PMPConfig,
        base: usize,
        size: usize,
        flags: u8,
    ) !void {
        if (self.regions.items.len >= MAX_REGIONS) {
            return PMPError.TooManyRegions;
        }
        _ = std.math.add(usize, base, size) catch {
            return PMPError.InvalidAlignment;
        };
        try self.regions.append(self.allocator, .{
            .base = base,
            .size = size,
            .flags = flags,
        });
    }

    /// Apply this PMP configuration to the current physical core.
    /// Called during context switch to a guest vcore.
    ///
    /// TOR mode: pmpaddrN = base >> 2, pmpaddrN+1 = (base + size) >> 2,
    /// pmpcfgN+1 = TOR | perms.
    pub fn apply(self: *PMPConfig) void {
        if (is_test) return;

        clearAllPmp();

        var entry: usize = 0;
        for (self.regions.items) |reg| {
            if (reg.base == 0 and reg.size == ~@as(usize, 0)) {
                if (entry >= NUM_PMP_ENTRIES) break;
                writePmpAddr(entry, ~@as(usize, 0));
                const cfg = PMPAccess.napot | (reg.flags & PMPAccess.rwx_mask);
                writePmpCfg(entry, cfg);
                entry += 1;
            } else {
                if (entry + 2 > NUM_PMP_ENTRIES) break;
                const top = std.math.add(usize, reg.base, reg.size) catch break;
                const base_shifted = reg.base >> PMP_ADDR_SHIFT;
                const top_shifted = top >> PMP_ADDR_SHIFT;
                const cfg = PMPAccess.tor | (reg.flags & PMPAccess.rwx_mask);

                writePmpAddr(entry, base_shifted);
                writePmpAddr(entry + 1, top_shifted);
                writePmpCfg(entry + 1, cfg);

                entry += 2;
            }
        }

        // Final entry: deny-all for everything else (NAPOT, no permissions).
        if (entry < NUM_PMP_ENTRIES) {
            writePmpAddr(entry, ~@as(usize, 0));
            writePmpCfg(entry, PMPAccess.napot);
        }
    }

    pub fn clearAllPmp() void {
        if (comptime is_test) return;
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
        if (comptime is_test) return;
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
    /// PMP configs are packed 8-per-register in pmpcfg0 (0-7) and
    /// pmpcfg2 (8-15).
    pub fn writePmpCfg(index: usize, cfg: u8) void {
        if (comptime is_test) return;
        if (index >= NUM_PMP_ENTRIES) return;

        const reg_index = index / ENTRIES_PER_PMPCFG;
        const byte_pos: u6 =
            @intCast((index % ENTRIES_PER_PMPCFG) * PMPCFG_ENTRY_BITS);
        const mask = ~(@as(usize, PMPCFG_ENTRY_MASK) << byte_pos);
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
extern const __data_start: u8;
extern const __hypervisor_end: u8;

const CPU_STACK_SIZE: usize = 512 * 1024;

pub fn isHypervisorAddress(addr: usize, size: usize) bool {
    if (comptime is_test) return false;
    const hv_start = @intFromPtr(&__hypervisor_start);
    const hv_end = @intFromPtr(&__hypervisor_end);
    const hv_top = std.math.add(
        usize,
        hv_end,
        riscv.STATIC_PHYS_CORES << riscv.CPU_SLAB_SHIFT,
    ) catch std.math.maxInt(usize);
    const end = std.math.add(usize, addr, size) catch return true;
    return addr < hv_top and end > hv_start;
}

pub fn applyEmulatorPmp(
    cpu_core_id: usize,
    base_hpa: usize,
    range_size: usize,
) void {
    if (comptime is_test) return;

    PMPConfig.clearAllPmp();

    const hv_start = @intFromPtr(&__hypervisor_start);
    const data_start = @intFromPtr(&__data_start);
    const hv_end = @intFromPtr(&__hypervisor_end);
    const rx_cfg = PMPAccess.tor | PMPAccess.read | PMPAccess.execute;
    const rw_cfg = PMPAccess.tor | PMPAccess.read | PMPAccess.write;

    // Entry 0 and 1: Hypervisor text + rodata (RX).
    PMPConfig.writePmpAddr(0, hv_start >> PMP_ADDR_SHIFT);
    PMPConfig.writePmpAddr(1, data_start >> PMP_ADDR_SHIFT);
    PMPConfig.writePmpCfg(1, rx_cfg);

    // Entry 2 and 3: Hypervisor data + bss + embedded rootvm (RW).
    PMPConfig.writePmpAddr(2, data_start >> PMP_ADDR_SHIFT);
    PMPConfig.writePmpAddr(3, hv_end >> PMP_ADDR_SHIFT);
    PMPConfig.writePmpCfg(3, rw_cfg);

    // Entry 4 and 5: Current CPU core slab (RW).
    const slab_base = if (cpu_core_id < riscv.STATIC_PHYS_CORES)
        hv_end + (cpu_core_id << riscv.CPU_SLAB_SHIFT)
    else
        @intFromPtr(riscv.getCPUContext()) - CPU_STACK_SIZE;
    PMPConfig.writePmpAddr(4, slab_base >> PMP_ADDR_SHIFT);
    PMPConfig.writePmpAddr(
        5,
        (slab_base + riscv.CPU_SLAB_SIZE) >> PMP_ADDR_SHIFT,
    );
    PMPConfig.writePmpCfg(5, rw_cfg);

    // Entry 6 and 7: Guest RAM (RW).
    if (range_size > 0) {
        if (std.math.add(usize, base_hpa, range_size)) |top_hpa| {
            PMPConfig.writePmpAddr(6, base_hpa >> PMP_ADDR_SHIFT);
            PMPConfig.writePmpAddr(7, top_hpa >> PMP_ADDR_SHIFT);
            PMPConfig.writePmpCfg(7, rw_cfg);
        } else |_| {}
    }

    // Entry 8: Deny-all for the rest of the address space (NAPOT, no perms).
    PMPConfig.writePmpAddr(8, ~@as(usize, 0));
    PMPConfig.writePmpCfg(8, PMPAccess.napot);
}

test "PMP configuration regions and capacity limits" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;

    var config = try PMPConfig.init(testing.allocator);
    defer config.deinit();

    try testing.expectEqual(@as(usize, 0), config.regions.items.len);

    var i: usize = 0;
    while (i < MAX_REGIONS) : (i += 1) {
        try config.addRegion(
            0x80000000 + (i * 0x100000),
            0x100000,
            PMPAccess.rwx,
        );
    }

    try testing.expectEqual(MAX_REGIONS, config.regions.items.len);

    try testing.expectError(
        error.TooManyRegions,
        config.addRegion(0x90000000, 0x100000, PMPAccess.rwx),
    );

    const reg0 = config.regions.items[0];
    try testing.expectEqual(@as(usize, 0x80000000), reg0.base);
    try testing.expectEqual(@as(usize, 0x100000), reg0.size);
    try testing.expectEqual(PMPAccess.rwx, reg0.flags);
}
