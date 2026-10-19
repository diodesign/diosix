// Software MMU Sv32 Page-Table Walker & Direct-Mapping Helpers
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("interface").riscv;
const bus_mod = @import("../devices/bus.zig");
const softtlb_mod = @import("../softtlb.zig");

const SoftTlb = softtlb_mod.SoftTlb;
const DirectMappingRegion = SoftTlb.DirectMappingRegion;
const PTE = softtlb_mod.PTE;

const PAGE_SHIFT = softtlb_mod.PAGE_SHIFT;
const PAGE_SIZE = softtlb_mod.PAGE_SIZE;
const PAGE_OFFSET_MASK = softtlb_mod.PAGE_OFFSET_MASK;
const TLB_MASK = softtlb_mod.TLB_MASK;
const MAX_CONTIGUOUS_REGIONS = softtlb_mod.MAX_CONTIGUOUS_REGIONS;

const SV32_VPN1_SHIFT = softtlb_mod.SV32_VPN1_SHIFT;
const SV32_VPN_MASK = softtlb_mod.SV32_VPN_MASK;
const SV32_PPN_SHIFT = softtlb_mod.SV32_PPN_SHIFT;
const SV32_PPN1_PTE_SHIFT = softtlb_mod.SV32_PPN1_PTE_SHIFT;
const SV32_PTE_PPN_MASK = softtlb_mod.SV32_PTE_PPN_MASK;
const SV32_PTE_PPN0_MASK = softtlb_mod.SV32_PTE_PPN0_MASK;
const SV32_SUPERPAGE_SIZE = softtlb_mod.SV32_SUPERPAGE_SIZE;
const SV32_SUPERPAGE_MASK = softtlb_mod.SV32_SUPERPAGE_MASK;
const SV32_SATP_MODE_SHIFT = softtlb_mod.SV32_SATP_MODE_SHIFT;
const SV32_SATP_PPN_MASK = softtlb_mod.SV32_SATP_PPN_MASK;

pub const KERNEL_HIGH_VADDR_BASE: u32 = 0xc000_0000;
pub const KERNEL_LOW_VADDR_BASE: u32 = 0x4000_0000;

pub fn fallbackIdentity(self: *SoftTlb, vaddr: u32) ?usize {
    if (vaddr < PAGE_SIZE) return null; // NULL pointer dereference traps.
    if (bus_mod.Bus.isMmioAddr(vaddr)) {
        return vaddr; // MMIO physical address directly.
    }

    const gpa: usize = if (vaddr >= KERNEL_HIGH_VADDR_BASE)
        self.guest_gpa_base +% (vaddr -% KERNEL_HIGH_VADDR_BASE)
    else if (vaddr >= KERNEL_LOW_VADDR_BASE and vaddr < self.guest_gpa_base)
        self.guest_gpa_base +% (vaddr -% KERNEL_LOW_VADDR_BASE)
    else if (vaddr < self.guest_gpa_base)
        self.guest_gpa_base +% vaddr
    else
        vaddr;

    if (self.guest_hpa_base > 0 and gpa >= self.guest_gpa_base and
        (gpa - self.guest_gpa_base) < self.guest_ram_size)
    {
        if (self.translateGpaToHpa(gpa)) |hpa| {
            const page = vaddr >> PAGE_SHIFT;
            self.entries[page & TLB_MASK] = .{
                .guest_vaddr_page = page,
                .host_paddr_page = hpa & ~@as(usize, PAGE_OFFSET_MASK),
                .flags = PTE.VRWX,
                .epoch = self.epoch,
            };
            return hpa;
        }
    }
    return null;
}

/// Query the dynamic direct-mapped host physical region for a virtual address.
pub fn getDirectMappingRegion(
    self: *SoftTlb,
    vaddr: u32,
) ?DirectMappingRegion {
    const satp_mode = (self.satp >> SV32_SATP_MODE_SHIFT) & 1;
    if (satp_mode == 0 or self.privilege_mode == riscv.PRIV_MACHINE) {
        if (self.guest_hpa_base > 0 and vaddr >= self.guest_gpa_base and
            (vaddr - self.guest_gpa_base) < self.guest_ram_size)
        {
            const vstart = @as(u32, @truncate(self.guest_gpa_base));
            const vend = vstart +% @as(u32, @truncate(self.guest_ram_size));
            const vstart_sext = @as(i64, @as(i32, @bitCast(vstart)));
            return .{
                .vaddr_start = vstart,
                .vaddr_end = vend,
                .hpa_start = self.guest_hpa_base,
                .delta = @as(i64, @intCast(self.guest_hpa_base)) -
                    vstart_sext,
            };
        }
        return null;
    }

    const reg_slot =
        (vaddr >> SV32_VPN1_SHIFT) & (MAX_CONTIGUOUS_REGIONS - 1);
    const region = &self.contiguous_regions[reg_slot];
    if (region.valid and vaddr >= region.vaddr_start and
        vaddr < region.vaddr_end)
    {
        const vstart_sext =
            @as(i64, @as(i32, @bitCast(region.vaddr_start)));
        return .{
            .vaddr_start = region.vaddr_start,
            .vaddr_end = region.vaddr_end,
            .hpa_start = region.hpa_start,
            .delta = @as(i64, @intCast(region.hpa_start)) - vstart_sext,
        };
    }
    return null;
}

/// Translate virtual address to host physical address via direct mapping
/// or Sv32 page table walk.
pub fn translateFull(
    self: *SoftTlb,
    vaddr: u32,
    is_write: bool,
    is_exec: bool,
    bus: *bus_mod.Bus,
) ?usize {
    _ = bus;
    if (self.translateFast(vaddr, is_write, is_exec)) |cached| {
        return cached;
    }

    const satp_mode = (self.satp >> SV32_SATP_MODE_SHIFT) & 1;
    if (satp_mode == 0 or self.privilege_mode == riscv.PRIV_MACHINE) {
        const hpa = self.translateGpaToHpa(vaddr) orelse
            (fallbackIdentity(self, vaddr) orelse return null);

        if (!bus_mod.Bus.isMmioAddr(@truncate(hpa))) {
            const page = vaddr >> PAGE_SHIFT;
            var flags: u8 = PTE.VRWX;
            if (self.privilege_mode == riscv.PRIV_USER) flags |= PTE.U;

            self.entries[page & TLB_MASK] = .{
                .guest_vaddr_page = page,
                .host_paddr_page = hpa & ~@as(usize, PAGE_OFFSET_MASK),
                .flags = flags,
                .epoch = self.epoch,
            };
        }
        return hpa;
    }

    // Sv32 Page Table Walk.
    const root_ppn = @as(usize, self.satp) & SV32_SATP_PPN_MASK;
    const root_gpa = self.ppnToGpa(root_ppn);
    const vpn1 = (vaddr >> SV32_VPN1_SHIFT) & SV32_VPN_MASK;
    const pte1_gpa = root_gpa +% (vpn1 * @sizeOf(u32));
    const pte1_hpa = self.translateGpaToHpa(pte1_gpa) orelse return null;

    const pte1_ptr = @as(*align(4) const u32, @ptrFromInt(pte1_hpa));
    const pte1 = @atomicLoad(u32, pte1_ptr, .acquire);

    if (!PTE.isValid(pte1)) {
        self.last_null_vaddr = vaddr;
        self.last_null_pte1 = pte1;
        return null;
    }

    var final_gpa: usize = 0;
    var pte_flags: u8 = PTE.V;

    if (PTE.isPointer(pte1)) {
        const pte0_ppn =
            (@as(usize, pte1) & SV32_PTE_PPN_MASK) >> SV32_PPN_SHIFT;
        const pte0_table_gpa = self.ppnToGpa(pte0_ppn);
        const vpn0 = (vaddr >> PAGE_SHIFT) & SV32_VPN_MASK;
        const pte0_gpa = pte0_table_gpa +% (vpn0 * @sizeOf(u32));
        const pte0_hpa =
            self.translateGpaToHpa(pte0_gpa) orelse return null;

        const pte0_ptr = @as(*align(4) const u32, @ptrFromInt(pte0_hpa));
        const pte0 = @atomicLoad(u32, pte0_ptr, .acquire);

        if (!PTE.isValid(pte0) or PTE.isPointer(pte0)) {
            self.last_null_vaddr = vaddr;
            self.last_null_pte1 = pte1;
            self.last_null_pte0 = pte0;
            return null;
        }

        const page_ppn =
            (@as(usize, pte0) & SV32_PTE_PPN_MASK) >> SV32_PPN_SHIFT;
        final_gpa = self.ppnToGpa(page_ppn) | (vaddr & PAGE_OFFSET_MASK);
        pte_flags = @truncate(pte0 & PTE.FLAGS_MASK);
    } else {
        // 4MB Superpage: PPN[0] (bits 19..10) must be 0 in Sv32.
        if ((pte1 & SV32_PTE_PPN0_MASK) != 0) {
            self.last_null_vaddr = vaddr;
            self.last_null_pte1 = pte1;
            return null;
        }
        const ppn1_shifted =
            (@as(usize, pte1) >> SV32_PPN1_PTE_SHIFT) << SV32_VPN1_SHIFT;
        const ppn1_raw = @as(usize, @as(u32, @truncate(ppn1_shifted)));
        const ppn1 = if (ppn1_raw >= self.guest_gpa_base)
            ppn1_raw
        else
            (self.guest_gpa_base | ppn1_raw);
        final_gpa = ppn1 | (vaddr & SV32_SUPERPAGE_MASK);
        pte_flags = @truncate(pte1 & PTE.FLAGS_MASK);

        const vstart = vaddr & ~SV32_SUPERPAGE_MASK;
        const vend = vstart +% SV32_SUPERPAGE_SIZE;
        if (self.translateGpaToHpa(ppn1)) |hstart| {
            const reg_slot =
                (vstart >> SV32_VPN1_SHIFT) & (MAX_CONTIGUOUS_REGIONS - 1);
            self.contiguous_regions[reg_slot] = .{
                .vaddr_start = vstart,
                .vaddr_end = vend,
                .hpa_start = hstart,
                .flags = pte_flags,
                .valid = true,
            };
        }
    }

    const final_hpa = self.translateGpaToHpa(final_gpa) orelse
        (if (bus_mod.Bus.isMmioAddr(@truncate(final_gpa)))
            final_gpa
        else
            return null);

    const req_flag: u8 =
        if (is_exec) PTE.X else if (is_write) PTE.W else PTE.R;
    if (!self.checkPrivilegeFlags(pte_flags, is_write, is_exec)) {
        self.last_null_vaddr = vaddr;
        self.last_null_pte_flags = pte_flags;
        self.last_null_req_flag = req_flag;
        return null;
    }

    if (!bus_mod.Bus.isMmioAddr(@truncate(final_hpa))) {
        const page = vaddr >> PAGE_SHIFT;
        self.entries[page & TLB_MASK] = .{
            .guest_vaddr_page = page,
            .host_paddr_page = final_hpa & ~@as(usize, PAGE_OFFSET_MASK),
            .flags = pte_flags,
            .epoch = self.epoch,
        };
    }
    return final_hpa;
}

test "SoftTlb walk fallbackIdentity MMIO and RAM mapping" {
    const testing = std.testing;
    testing.refAllDecls(@This());

    var tlb = SoftTlb.init(0x8000_0000, 0xe000_0000, 0x1000_0000);
    try testing.expect(fallbackIdentity(&tlb, 0x0000_0100) == null);
    try testing.expectEqual(
        @as(?usize, 0x1000_0000),
        fallbackIdentity(&tlb, 0x1000_0000),
    );
    try testing.expectEqual(
        @as(?usize, 0xe000_1000),
        fallbackIdentity(&tlb, 0xc000_1000),
    );
}
