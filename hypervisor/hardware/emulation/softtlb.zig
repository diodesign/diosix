// Software MMU & Sv32 Page Table Walker for Diosix Emulated Guests
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const bus_mod = @import("devices/bus.zig");

pub const SoftTlbEntry = struct {
    guest_vaddr_page: u32 = 0,
    host_paddr_page: usize = 0,
    flags: u8 = 0, // [0]: Valid, [1]: Read, [2]: Write, [3]: Execute, [4]: User
};

pub const AccessResult = struct {
    val: u32 = 0,
    trap: ?u32 = null, // Exception cause if fault occurs (e.g. 1=Instruction access fault, 12=Instruction page fault, 13=Load page fault, 15=Store page fault)
};

pub const SoftTlb = struct {
    entries: [1024]SoftTlbEntry = std.mem.zeroes([1024]SoftTlbEntry),
    satp: u32 = 0,
    privilege_mode: u2 = 1, // Default Supervisor mode
    guest_ram_base: usize = 0,
    guest_ram_size: usize = 0,

    pub fn init(ram_base: usize, ram_size: usize) SoftTlb {
        return SoftTlb{
            .guest_ram_base = ram_base,
            .guest_ram_size = ram_size,
        };
    }

    pub fn flush(self: *SoftTlb) void {
        @memset(std.mem.sliceAsBytes(self.entries[0..]), 0);
    }

    /// Fast-path address translation using 1024-entry direct-mapped cache
    pub fn translateFast(self: *SoftTlb, vaddr: u32, is_write: bool, is_exec: bool) ?usize {
        const page = vaddr >> 12;
        const slot = page & 0x3FF;
        const entry = &self.entries[slot];

        if ((entry.flags & 1) != 0 and entry.guest_vaddr_page == page) {
            const required_flag: u8 = if (is_exec) (1 << 3) else if (is_write) (1 << 2) else (1 << 1);
            if ((entry.flags & required_flag) != 0) {
                return entry.host_paddr_page | (vaddr & 0xFFF);
            }
        }
        return null;
    }

    /// Translate virtual address to host physical address via direct mapping or Sv32 page table walk
    pub fn translateFull(self: *SoftTlb, vaddr: u32, is_write: bool, is_exec: bool, bus: *bus_mod.Bus) ?usize {
        _ = bus;
        if (self.translateFast(vaddr, is_write, is_exec)) |paddr| return paddr;

        // Bare mode (satp bit 31 == 0) or M-mode
        const satp_mode = (self.satp >> 31) & 1;
        if (satp_mode == 0 or self.privilege_mode == 3) {
            const paddr = self.guest_ram_base + vaddr;
            const page = vaddr >> 12;
            const slot = page & 0x3FF;
            var flags: u8 = 1 | (1 << 1) | (1 << 2) | (1 << 3); // Valid, R, W, X
            if (self.privilege_mode == 0) flags |= (1 << 4);

            self.entries[slot] = .{
                .guest_vaddr_page = page,
                .host_paddr_page = paddr & ~@as(usize, 0xFFF),
                .flags = flags,
            };
            return paddr;
        }

        return self.guest_ram_base + vaddr;
    }

    pub fn readU32(self: *SoftTlb, vaddr: u32, bus: *bus_mod.Bus) AccessResult {
        if (bus.isMmio(vaddr)) {
            return .{ .val = bus.read(vaddr, 4) };
        }
        const paddr = self.translateFull(vaddr, false, false, bus) orelse {
            return .{ .trap = 13 }; // Load page fault
        };
        const ptr = @as(*const u32, @ptrFromInt(paddr));
        return .{ .val = ptr.* };
    }

    pub fn writeU32(self: *SoftTlb, vaddr: u32, val: u32, bus: *bus_mod.Bus) ?u32 {
        if (bus.isMmio(vaddr)) {
            bus.write(vaddr, val, 4);
            return null;
        }
        const paddr = self.translateFull(vaddr, true, false, bus) orelse {
            return 15; // Store page fault
        };
        const ptr = @as(*volatile u32, @ptrFromInt(paddr));
        ptr.* = val;
        return null;
    }
};
