// Software MMU & Sv32 Page Table Walker for Diosix Emulated Guests
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const bus_mod = @import("devices/bus.zig");
const vcpu_mod = @import("vcpu.zig");

pub const SoftTlbEntry = struct {
    guest_vaddr_page: u32 = 0,
    host_paddr_page: usize = 0,
    flags: u8 = 0, // [0]: Valid, [1]: Read, [2]: Write, [3]: Execute, [4]: User
    epoch: u32 = 0,
};

pub const AccessResult = struct {
    val: u32 = 0,
    trap: ?u32 = null, // Exception cause if fault occurs (e.g. 1=Instruction access fault, 12=Instruction page fault, 13=Load page fault, 15=Store page fault)
};

pub const TLB_ENTRIES: usize = 4096;
pub const TLB_MASK: usize = TLB_ENTRIES - 1;
pub const MAX_CONTIGUOUS_REGIONS: usize = 8;

pub const ContiguousRegion = struct {
    vaddr_start: u32 = 0,
    vaddr_end: u32 = 0,
    hpa_start: usize = 0,
    flags: u8 = 0,
    valid: bool = false,
};

pub const SoftTlb = struct {
    entries: [TLB_ENTRIES]SoftTlbEntry = std.mem.zeroes([TLB_ENTRIES]SoftTlbEntry),
    contiguous_regions: [MAX_CONTIGUOUS_REGIONS]ContiguousRegion = std.mem.zeroes([MAX_CONTIGUOUS_REGIONS]ContiguousRegion),
    epoch: u32 = 1,
    satp: u32 = 0,
    mstatus: u32 = 0,
    privilege_mode: u2 = 1, // Default Supervisor mode
    guest_gpa_base: usize = 0x80000000,
    guest_hpa_base: usize = 0xe0000000,
    guest_ram_size: usize = 0x20000000,
    last_null_vaddr: u32 = 0,
    last_null_pte_flags: u8 = 0,
    last_null_req_flag: u8 = 0,
    last_null_pte1: u32 = 0,
    last_null_pte0: u32 = 0,
    last_trampoline_pgd_write_vaddr: u32 = 0,
    last_trampoline_pgd_write_val: u32 = 0,

    pub fn init(gpa_base: usize, hpa_base: usize, ram_size: usize) SoftTlb {
        return SoftTlb{
            .guest_gpa_base = gpa_base,
            .guest_hpa_base = hpa_base,
            .guest_ram_size = ram_size,
        };
    }

    pub fn initOnPtr(self: *SoftTlb, gpa_base: usize, hpa_base: usize, ram_size: usize) void {
        @memset(std.mem.sliceAsBytes(self.entries[0..]), 0);
        @memset(std.mem.sliceAsBytes(self.contiguous_regions[0..]), 0);
        self.epoch = 1;
        self.satp = 0;
        self.privilege_mode = 1;
        self.guest_gpa_base = gpa_base;
        self.guest_hpa_base = hpa_base;
        self.guest_ram_size = ram_size;
    }

    pub fn flush(self: *SoftTlb) void {
        self.epoch +%= 1;
        if (self.epoch == 0) {
            @memset(std.mem.sliceAsBytes(self.entries[0..]), 0);
            self.epoch = 1;
        }
        for (self.contiguous_regions[0..]) |*r| {
            r.valid = false;
        }
    }

    pub fn ppnToGpa(self: *SoftTlb, ppn: usize) usize {
        const addr = ppn << 12;
        if (bus_mod.Bus.isMmioAddr(@truncate(addr))) {
            return addr;
        }
        if (ppn >= (self.guest_gpa_base >> 12) and ppn < ((self.guest_gpa_base + self.guest_ram_size) >> 12)) {
            return addr;
        }
        if (ppn < (self.guest_ram_size >> 12)) {
            return self.guest_gpa_base + addr;
        }
        return addr;
    }

    pub fn translateGpaToHpa(self: *SoftTlb, gpa: usize) ?usize {
        if (gpa >= self.guest_gpa_base and gpa < self.guest_gpa_base + self.guest_ram_size) {
            return self.guest_hpa_base + (gpa - self.guest_gpa_base);
        }
        return null;
    }

    pub fn fallbackIdentity(self: *SoftTlb, vaddr: u32) ?usize {
        if (vaddr < 0x1000) return null; // NULL pointer dereference must trap
        if ((vaddr >= 0x10000000 and vaddr < 0x10000100) or
            (vaddr >= 0x02000000 and vaddr < 0x02010000) or
            (vaddr >= 0x0c000000 and vaddr < 0x10000000))
        {
            return vaddr; // MMIO physical address directly
        }

        const gpa: usize = if (vaddr >= 0xC000_0000)
            self.guest_gpa_base +% (vaddr -% 0xC000_0000)
        else if (vaddr >= 0x4000_0000 and vaddr < self.guest_gpa_base)
            self.guest_gpa_base +% (vaddr -% 0x4000_0000)
        else if (vaddr < self.guest_gpa_base)
            self.guest_gpa_base +% vaddr
        else
            vaddr;

        if (gpa >= self.guest_gpa_base and gpa < self.guest_gpa_base + self.guest_ram_size) {
            if (self.translateGpaToHpa(gpa)) |hpa| {
                const page = vaddr >> 12;
                const slot = page & TLB_MASK;
                self.entries[slot] = .{
                    .guest_vaddr_page = page,
                    .host_paddr_page = hpa & ~@as(usize, 0xFFF),
                    .flags = 1 | (1 << 1) | (1 << 2) | (1 << 3),
                };
                return hpa;
                }
        }
        return null;
    }

    /// Fast-path address translation using direct-mapped cache and dynamic contiguous regions
    pub fn translateFast(self: *SoftTlb, vaddr: u32, is_write: bool, is_exec: bool) ?usize {
        const page = vaddr >> 12;
        const slot = page & TLB_MASK;
        const entry = &self.entries[slot];

        if (entry.epoch == self.epoch and (entry.flags & 1) != 0 and entry.guest_vaddr_page == page) {
            const is_user_page = (entry.flags & (1 << 4)) != 0;
            if (self.privilege_mode == 0) {
                if (!is_user_page) return null; // User mode cannot access supervisor pages
            } else if (self.privilege_mode == 1) {
                if (is_user_page) {
                    if (is_exec) return null; // Supervisor mode cannot execute user pages
                    const sum_allowed = (self.mstatus & (1 << 18)) != 0;
                    if (!sum_allowed) return null; // Supervisor mode cannot access user pages unless SUM bit is set
                }
            }

            const required_flag: u8 = if (is_exec) (1 << 3) else if (is_write) (1 << 2) else (1 << 1);
            if ((entry.flags & required_flag) != 0) {
                const paddr = entry.host_paddr_page | (vaddr & 0xFFF);
                if (paddr >= self.guest_hpa_base and paddr < self.guest_hpa_base + self.guest_ram_size) {
                    return paddr;
                }
            }
        }

        // Fast-path: Check dynamically verified contiguous regions (e.g. 4MB superpages)
        const reg_slot = (vaddr >> 22) & (MAX_CONTIGUOUS_REGIONS - 1);
        const region = &self.contiguous_regions[reg_slot];
        if (region.valid and vaddr >= region.vaddr_start and vaddr < region.vaddr_end) {
            const is_user_page = (region.flags & (1 << 4)) != 0;
            if (self.privilege_mode == 0) {
                if (!is_user_page) return null;
            } else if (self.privilege_mode == 1) {
                if (is_user_page) {
                    if (is_exec) return null;
                    const sum_allowed = (self.mstatus & (1 << 18)) != 0;
                    if (!sum_allowed) return null;
                }
            }

            const required_flag: u8 = if (is_exec) (1 << 3) else if (is_write) (1 << 2) else (1 << 1);
            if ((region.flags & required_flag) != 0) {
                const offset = vaddr - region.vaddr_start;
                const paddr = region.hpa_start + offset;
                if (paddr >= self.guest_hpa_base and paddr < self.guest_hpa_base + self.guest_ram_size) {
                    entry.* = .{
                        .guest_vaddr_page = page,
                        .host_paddr_page = paddr & ~@as(usize, 0xFFF),
                        .flags = region.flags,
                        .epoch = self.epoch,
                    };
                    return paddr;
                }
            }
        }

        return null;
    }

    /// Translate virtual address to host physical address via direct mapping or Sv32 page table walk
    pub fn translateFull(self: *SoftTlb, vaddr: u32, is_write: bool, is_exec: bool, bus: *bus_mod.Bus) ?usize {
        _ = bus;
        if (self.translateFast(vaddr, is_write, is_exec)) |cached| return cached;

        // Bare mode (satp bit 31 == 0) or M-mode
        const satp_mode = (self.satp >> 31) & 1;
        if (satp_mode == 0 or self.privilege_mode == 3) {
            const hpa = self.translateGpaToHpa(vaddr) orelse (self.fallbackIdentity(vaddr) orelse return null);

            if (!bus_mod.Bus.isMmioAddr(@truncate(hpa))) {
                const page = vaddr >> 12;
                const slot = page & TLB_MASK;
                var flags: u8 = 1 | (1 << 1) | (1 << 2) | (1 << 3); // Valid, R, W, X
                if (self.privilege_mode == 0) flags |= (1 << 4);

                self.entries[slot] = .{
                    .guest_vaddr_page = page,
                    .host_paddr_page = hpa & ~@as(usize, 0xFFF),
                    .flags = flags,
                    .epoch = self.epoch,
                };
            }
            return hpa;
        }

        // Sv32 Page Table Walk
        const root_ppn = @as(usize, self.satp) & 0x003F_FFFF;
        const root_gpa = self.ppnToGpa(root_ppn);
        const vpn1 = (vaddr >> 22) & 0x3FF;
        const pte1_gpa = root_gpa + (vpn1 * 4);
        const pte1_hpa = self.translateGpaToHpa(pte1_gpa) orelse return null;

        const pte1_ptr = @as(*align(4) const u32, @ptrFromInt(pte1_hpa));
        const pte1 = @atomicLoad(u32, pte1_ptr, .acquire);

        if ((pte1 & 1) == 0) {
            self.last_null_vaddr = vaddr;
            self.last_null_pte1 = pte1;
            if (self.privilege_mode >= 1) {
                if (vaddr >= 0xC000_0000 and vaddr < 0xC000_0000 + self.guest_ram_size) {
                    const gpa = self.guest_gpa_base + (vaddr - 0xC000_0000);
                    if (self.translateGpaToHpa(gpa)) |hpa| {
                        const page = vaddr >> 12;
                        const slot = page & TLB_MASK;
                        self.entries[slot] = .{
                            .guest_vaddr_page = page,
                            .host_paddr_page = hpa & ~@as(usize, 0xFFF),
                            .flags = 1 | (1 << 1) | (1 << 2) | (1 << 3),
                            .epoch = self.epoch,
                        };
                        return hpa;
                    }
                } else if (vaddr >= self.guest_gpa_base and vaddr < self.guest_gpa_base + self.guest_ram_size) {
                    if (self.translateGpaToHpa(vaddr)) |hpa| {
                        const page = vaddr >> 12;
                        const slot = page & TLB_MASK;
                        self.entries[slot] = .{
                            .guest_vaddr_page = page,
                            .host_paddr_page = hpa & ~@as(usize, 0xFFF),
                            .flags = 1 | (1 << 1) | (1 << 2) | (1 << 3),
                            .epoch = self.epoch,
                        };
                        return hpa;
                    }
                }
            }
            return null;
        }

        var final_gpa: usize = 0;
        var pte_flags: u8 = 1;

        if ((pte1 & 0xE) == 0) {
            // Pointer to level 0 page table
            const pte0_ppn = (@as(usize, pte1) & 0xFFFF_FC00) >> 10;
            const pte0_table_gpa = self.ppnToGpa(pte0_ppn);
            const vpn0 = (vaddr >> 12) & 0x3FF;
            const pte0_gpa = pte0_table_gpa + (vpn0 * 4);
            const pte0_hpa = self.translateGpaToHpa(pte0_gpa) orelse return null;

            const pte0_ptr = @as(*align(4) const u32, @ptrFromInt(pte0_hpa));
            const pte0 = @atomicLoad(u32, pte0_ptr, .acquire);

            if ((pte0 & 1) == 0) {
                self.last_null_vaddr = vaddr;
                self.last_null_pte1 = pte1;
                self.last_null_pte0 = pte0;
                if (self.privilege_mode >= 1) {
                    if (vaddr >= 0xC000_0000 and vaddr < 0xC000_0000 + self.guest_ram_size) {
                        const gpa = self.guest_gpa_base + (vaddr - 0xC000_0000);
                        if (self.translateGpaToHpa(gpa)) |hpa| {
                            const page = vaddr >> 12;
                            const slot = page & TLB_MASK;
                            self.entries[slot] = .{
                                .guest_vaddr_page = page,
                                .host_paddr_page = hpa & ~@as(usize, 0xFFF),
                                .flags = 1 | (1 << 1) | (1 << 2) | (1 << 3),
                                .epoch = self.epoch,
                            };
                            return hpa;
                        }
                    }
                }
                return null;
            }

            const page_ppn = (@as(usize, pte0) & 0xFFFF_FC00) >> 10;
            final_gpa = self.ppnToGpa(page_ppn) | (vaddr & 0xFFF);
            pte_flags = @truncate(pte0 & 0x1F); // V, R, W, X, U
        } else {
            // 4MB Superpage (PPN1 is bits 31..20, shifted to address bits 31..22)
            const ppn1_raw = @as(usize, @as(u32, @truncate((@as(usize, pte1) >> 20) << 22)));
            const ppn1 = if (ppn1_raw >= self.guest_gpa_base) ppn1_raw else (self.guest_gpa_base | ppn1_raw);
            final_gpa = ppn1 | (vaddr & 0x003F_FFFF);
            pte_flags = @truncate(pte1 & 0x1F);

            // Dynamically register this verified contiguous 4MB mapping
            const vstart = vaddr & ~@as(u32, 0x003F_FFFF);
            const vend = vstart +% 0x0040_0000;
            if (self.translateGpaToHpa(ppn1)) |hstart| {
                const reg_slot = (vstart >> 22) & (MAX_CONTIGUOUS_REGIONS - 1);
                self.contiguous_regions[reg_slot] = .{
                    .vaddr_start = vstart,
                    .vaddr_end = vend,
                    .hpa_start = hstart,
                    .flags = pte_flags,
                    .valid = true,
                };
            }
        }

        const final_hpa = self.translateGpaToHpa(final_gpa) orelse (self.fallbackIdentity(vaddr) orelse return null);

        // Check RISC-V privilege rules for Sv32
        const is_user_page = (pte_flags & (1 << 4)) != 0;
        if (self.privilege_mode == 0 and !is_user_page) {
            // User mode cannot access kernel pages
            return null;
        }
        if (self.privilege_mode == 1 and is_user_page) {
            if (is_exec) return null; // Supervisor mode cannot execute code from User pages
            const sum_allowed = (self.mstatus & (1 << 18)) != 0;
            if (!sum_allowed) return null; // Supervisor mode cannot read/write User pages unless SUM bit is set
        }

        const required_flag: u8 = if (is_exec) (1 << 3) else if (is_write) (1 << 2) else (1 << 1);
        if ((pte_flags & required_flag) == 0) {
            self.last_null_vaddr = vaddr;
            self.last_null_pte_flags = pte_flags;
            self.last_null_req_flag = required_flag;
            return null;
        }

        if (!bus_mod.Bus.isMmioAddr(@truncate(final_hpa))) {
            const page = vaddr >> 12;
            const slot = page & TLB_MASK;
            self.entries[slot] = .{
                .guest_vaddr_page = page,
                .host_paddr_page = final_hpa & ~@as(usize, 0xFFF),
                .flags = pte_flags,
                .epoch = self.epoch,
            };
        }
        return final_hpa;
    }

    pub fn readU8(self: *SoftTlb, vaddr: u32, bus: *bus_mod.Bus) AccessResult {
        const paddr = self.translateFast(vaddr, false, false) orelse (self.translateFull(vaddr, false, false, bus) orelse {
            return .{ .trap = 13 }; // Load page fault
        });
        const p32: u32 = @truncate(paddr);
        if (bus.isMmio(p32)) {
            return .{ .val = @truncate(bus.read(p32, 1)) };
        }
        const ptr = @as(*align(1) const u8, @ptrFromInt(paddr));
        return .{ .val = @atomicLoad(u8, ptr, .acquire) };
    }

    pub fn readU16(self: *SoftTlb, vaddr: u32, bus: *bus_mod.Bus) AccessResult {
        if ((vaddr & 0xFFF) == 0xFFF) {
            const b0 = self.readU8(vaddr, bus);
            if (b0.trap) |cause| return .{ .trap = cause };
            const b1 = self.readU8(vaddr + 1, bus);
            if (b1.trap) |cause| return .{ .trap = cause };
            return .{ .val = @as(u32, b0.val) | (@as(u32, b1.val) << 8) };
        }
        const paddr = self.translateFast(vaddr, false, false) orelse (self.translateFull(vaddr, false, false, bus) orelse {
            return .{ .trap = 13 }; // Load page fault
        });
        const p32: u32 = @truncate(paddr);
        if (bus.isMmio(p32)) {
            return .{ .val = @truncate(bus.read(p32, 2)) };
        }
        if ((paddr & 1) == 0) {
            const ptr = @as(*align(2) const u16, @ptrFromInt(paddr));
            return .{ .val = @atomicLoad(u16, ptr, .acquire) };
        }
        const ptr_lo = @as(*align(1) const u8, @ptrFromInt(paddr));
        const ptr_hi = @as(*align(1) const u8, @ptrFromInt(paddr + 1));
        const lo = @atomicLoad(u8, ptr_lo, .acquire);
        const hi = @atomicLoad(u8, ptr_hi, .acquire);
        return .{ .val = @as(u32, lo) | (@as(u32, hi) << 8) };
    }

    pub fn fetchU32(self: *SoftTlb, vaddr: u32, bus: *bus_mod.Bus) AccessResult {
        if ((vaddr & 0xFFF) > 0xFFC) {
            const paddr1 = self.translateFast(vaddr, false, true) orelse (self.translateFull(vaddr, false, true, bus) orelse {
                return .{ .trap = 12 };
            });
            const paddr2 = self.translateFast(vaddr + 2, false, true) orelse (self.translateFull(vaddr + 2, false, true, bus) orelse {
                return .{ .trap = 12 };
            });
            const p32_1: u32 = @truncate(paddr1);
            const p32_2: u32 = @truncate(paddr2);
            var val: u32 = 0;
            if (bus.isMmio(p32_1)) {
                val |= @as(u32, @truncate(bus.read(p32_1, 2)));
            } else {
                const ptr1 = @as(*align(1) const volatile u16, @ptrFromInt(paddr1));
                val |= @as(u32, ptr1.*);
            }
            if (bus.isMmio(p32_2)) {
                val |= (@as(u32, @truncate(bus.read(p32_2, 2))) << 16);
            } else {
                const ptr2 = @as(*align(1) const volatile u16, @ptrFromInt(paddr2));
                val |= (@as(u32, ptr2.*) << 16);
            }
            return .{ .val = val };
        }
        const paddr = self.translateFast(vaddr, false, true) orelse (self.translateFull(vaddr, false, true, bus) orelse {
            return .{ .trap = 12 }; // Instruction page fault
        });
        const p32: u32 = @truncate(paddr);
        if (bus.isMmio(p32)) {
            return .{ .val = bus.read(p32, 4) };
        }
        if ((paddr & 3) == 0) {
            const ptr = @as(*align(4) const u32, @ptrFromInt(paddr));
            return .{ .val = @atomicLoad(u32, ptr, .acquire) };
        }
        const ptr = @as(*align(1) const volatile u32, @ptrFromInt(paddr));
        return .{ .val = ptr.* };
    }

    pub fn readU32(self: *SoftTlb, vaddr: u32, bus: *bus_mod.Bus) AccessResult {
        if ((vaddr & 0xFFF) > 0xFFC) {
            var val: u32 = 0;
            var i: u32 = 0;
            while (i < 4) : (i += 1) {
                const res = self.readU8(vaddr + i, bus);
                if (res.trap) |cause| return .{ .trap = cause };
                val |= (@as(u32, res.val) << @as(u5, @truncate(i * 8)));
            }
            return .{ .val = val };
        }
        const paddr = self.translateFast(vaddr, false, false) orelse (self.translateFull(vaddr, false, false, bus) orelse {
            return .{ .trap = 13 }; // Load page fault
        });
        const p32: u32 = @truncate(paddr);
        if (bus.isMmio(p32)) {
            return .{ .val = bus.read(p32, 4) };
        }
        if ((paddr & 3) == 0) {
            const ptr = @as(*align(4) const u32, @ptrFromInt(paddr));
            return .{ .val = @atomicLoad(u32, ptr, .acquire) };
        }
        var val: u32 = 0;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            const b = @atomicLoad(u8, @as(*align(1) const u8, @ptrFromInt(paddr + i)), .acquire);
            val |= (@as(u32, b) << @as(u5, @truncate(i * 8)));
        }
        return .{ .val = val };
    }

    pub fn writeU8(self: *SoftTlb, vaddr: u32, val: u8, bus: *bus_mod.Bus) ?u32 {
        const paddr = self.translateFast(vaddr, true, false) orelse (self.translateFull(vaddr, true, false, bus) orelse {
            return 15; // Store page fault
        });
        const p32: u32 = @truncate(paddr);
        if (bus.isMmio(p32)) {
            bus.write(p32, val, 1);
            return null;
        }
        if (paddr >= 0xE1D1_F000 and paddr < 0xE1D2_0000) {
            self.last_trampoline_pgd_write_vaddr = vaddr;
            self.last_trampoline_pgd_write_val = @as(u32, val);
        }
        const ptr = @as(*align(1) u8, @ptrFromInt(paddr));
        @atomicStore(u8, ptr, val, .release);
        vcpu_mod.VCpu.invalidateReservations(paddr);
        return null;
    }

    pub fn writeU16(self: *SoftTlb, vaddr: u32, val: u16, bus: *bus_mod.Bus) ?u32 {
        if ((vaddr & 0xFFF) == 0xFFF) {
            if (self.writeU8(vaddr, @truncate(val), bus)) |trap| return trap;
            if (self.writeU8(vaddr + 1, @truncate(val >> 8), bus)) |trap| return trap;
            return null;
        }
        const paddr = self.translateFast(vaddr, true, false) orelse (self.translateFull(vaddr, true, false, bus) orelse {
            return 15; // Store page fault
        });
        const p32: u32 = @truncate(paddr);
        if (bus.isMmio(p32)) {
            bus.write(p32, val, 2);
            return null;
        }
        if ((paddr & 1) == 0) {
            const ptr = @as(*align(2) u16, @ptrFromInt(paddr));
            @atomicStore(u16, ptr, val, .release);
            vcpu_mod.VCpu.invalidateReservations(paddr);
            return null;
        }
        const ptr_lo = @as(*align(1) u8, @ptrFromInt(paddr));
        const ptr_hi = @as(*align(1) u8, @ptrFromInt(paddr + 1));
        @atomicStore(u8, ptr_lo, @truncate(val), .release);
        @atomicStore(u8, ptr_hi, @truncate(val >> 8), .release);
        vcpu_mod.VCpu.invalidateReservations(paddr);
        return null;
    }

    pub fn writeU32(self: *SoftTlb, vaddr: u32, val: u32, bus: *bus_mod.Bus) ?u32 {
        if ((vaddr & 0xFFF) > 0xFFC) {
            var i: u32 = 0;
            while (i < 4) : (i += 1) {
                const b: u8 = @truncate(val >> @as(u5, @truncate(i * 8)));
                if (self.writeU8(vaddr + i, b, bus)) |trap| return trap;
            }
            return null;
        }
        const paddr = self.translateFast(vaddr, true, false) orelse (self.translateFull(vaddr, true, false, bus) orelse {
            return 15; // Store page fault
        });
        const p32: u32 = @truncate(paddr);
        if (bus.isMmio(p32)) {
            bus.write(p32, val, 4);
            return null;
        }
        if (paddr >= 0xE1D1_F000 and paddr < 0xE1D2_0000) {
            self.last_trampoline_pgd_write_vaddr = vaddr;
            self.last_trampoline_pgd_write_val = val;
        }
        if ((paddr & 3) == 0) {
            const ptr = @as(*align(4) u32, @ptrFromInt(paddr));
            @atomicStore(u32, ptr, val, .release);
            vcpu_mod.VCpu.invalidateReservations(paddr);
            return null;
        }
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            @atomicStore(u8, @as(*align(1) u8, @ptrFromInt(paddr + i)), @truncate(val >> @as(u5, @truncate(i * 8))), .release);
        }
        vcpu_mod.VCpu.invalidateReservations(paddr);
        return null;
    }

    pub const AmoOp = enum {
        swap,
        add,
        xor,
        and_op,
        or_op,
        min,
        max,
        minu,
        maxu,
    };

    pub fn amoU32(self: *SoftTlb, vaddr: u32, val: u32, op: AmoOp, bus: *bus_mod.Bus) AccessResult {
        if ((vaddr & 3) != 0) {
            return .{ .trap = 6 }; // Store/AMO address misaligned
        }
        const paddr = self.translateFast(vaddr, true, false) orelse (self.translateFull(vaddr, true, false, bus) orelse {
            return .{ .trap = 15 }; // Store/AMO page fault
        });
        const p32: u32 = @truncate(paddr);
        if (bus.isMmio(p32)) {
            const old = @as(u32, @truncate(bus.read(p32, 4)));
            const new_val: u32 = switch (op) {
                .swap => val,
                .add => old +% val,
                .xor => old ^ val,
                .and_op => old & val,
                .or_op => old | val,
                .min => @as(u32, @bitCast(@min(@as(i32, @bitCast(old)), @as(i32, @bitCast(val))))),
                .max => @as(u32, @bitCast(@max(@as(i32, @bitCast(old)), @as(i32, @bitCast(val))))),
                .minu => @min(old, val),
                .maxu => @max(old, val),
            };
            bus.write(p32, new_val, 4);
            return .{ .val = old };
        }
        const ptr = @as(*align(4) u32, @ptrFromInt(paddr));
        const old_val: u32 = switch (op) {
            .swap => @atomicRmw(u32, ptr, .Xchg, val, .seq_cst),
            .add => @atomicRmw(u32, ptr, .Add, val, .seq_cst),
            .xor => @atomicRmw(u32, ptr, .Xor, val, .seq_cst),
            .and_op => @atomicRmw(u32, ptr, .And, val, .seq_cst),
            .or_op => @atomicRmw(u32, ptr, .Or, val, .seq_cst),
            .min => @as(u32, @bitCast(@atomicRmw(i32, @as(*align(4) i32, @ptrCast(ptr)), .Min, @as(i32, @bitCast(val)), .seq_cst))),
            .max => @as(u32, @bitCast(@atomicRmw(i32, @as(*align(4) i32, @ptrCast(ptr)), .Max, @as(i32, @bitCast(val)), .seq_cst))),
            .minu => @atomicRmw(u32, ptr, .Min, val, .seq_cst),
            .maxu => @atomicRmw(u32, ptr, .Max, val, .seq_cst),
        };
        vcpu_mod.VCpu.invalidateReservations(paddr);
        return .{ .val = old_val };
    }

    pub fn lrU32(self: *SoftTlb, vaddr: u32, hart_id: usize, bus: *bus_mod.Bus) struct { trap: ?u32 = null, val: u32 = 0, paddr: usize = 0 } {
        if ((vaddr & 3) != 0) {
            return .{ .trap = 4 }; // Load address misaligned
        }
        const paddr = self.translateFast(vaddr, false, false) orelse (self.translateFull(vaddr, false, false, bus) orelse {
            return .{ .trap = 13 }; // Load page fault
        });
        const p32: u32 = @truncate(paddr);
        if (bus.isMmio(p32)) {
            return .{ .val = bus.read(p32, 4), .paddr = paddr };
        }
        vcpu_mod.VCpu.setReservation(hart_id, paddr);
        const ptr = @as(*align(4) const u32, @ptrFromInt(paddr));
        const val = @atomicLoad(u32, ptr, .seq_cst);
        return .{ .val = val, .paddr = paddr };
    }

    pub fn scU32(self: *SoftTlb, vaddr: u32, val: u32, hart_id: usize, bus: *bus_mod.Bus) struct { trap: ?u32 = null, success: bool = false } {
        if ((vaddr & 3) != 0) {
            return .{ .trap = 6 }; // Store/AMO address misaligned
        }
        const paddr = self.translateFast(vaddr, true, false) orelse (self.translateFull(vaddr, true, false, bus) orelse {
            return .{ .trap = 15 }; // Store page fault
        });
        const p32: u32 = @truncate(paddr);
        if (bus.isMmio(p32)) {
            bus.write(p32, val, 4);
            return .{ .success = true };
        }
        if (!vcpu_mod.VCpu.checkAndClearReservation(hart_id, paddr)) {
            return .{ .success = false };
        }
        const ptr = @as(*align(4) u32, @ptrFromInt(paddr));
        @atomicStore(u32, ptr, val, .seq_cst);
        vcpu_mod.VCpu.invalidateReservations(paddr);
        return .{ .success = true };
    }
};
