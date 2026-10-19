// Software MMU & Sv32 Page Table Walker for Diosix Emulated Guests
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("interface").riscv;
const bus_mod = @import("devices/bus.zig");
const ops = @import("softtlb/ops.zig");
const walk = @import("softtlb/walk.zig");

pub const PAGE_SHIFT = 12;
pub const PAGE_SIZE: u32 = 1 << PAGE_SHIFT;
pub const PAGE_OFFSET_MASK: u32 = PAGE_SIZE - 1; // 0xfff.
pub const INVALID_VADDR_PAGE: u32 = 0xffff_ffff;
pub const INVALID_TAG: u32 = INVALID_VADDR_PAGE;

pub const SV32_VPN1_SHIFT = 22;
pub const SV32_VPN_MASK: u32 = 0x3ff;
pub const SV32_PPN_SHIFT = 10;
pub const SV32_PPN1_PTE_SHIFT = 20;
pub const SV32_PTE_PPN_MASK: usize = 0xffff_fc00;
pub const SV32_PTE_PPN0_MASK: u32 = 0x000f_fc00;
pub const SV32_SUPERPAGE_SIZE: u32 = 1 << SV32_VPN1_SHIFT; // 4 MiB.
pub const SV32_SUPERPAGE_MASK: u32 = SV32_SUPERPAGE_SIZE - 1; // 0x003f_ffff.
pub const SV32_SATP_MODE_SHIFT = 31;
pub const SV32_SATP_PPN_MASK: usize = 0x003f_ffff;

pub const PTE = struct {
    pub const V = 1 << 0;
    pub const R = 1 << 1;
    pub const W = 1 << 2;
    pub const X = 1 << 3;
    pub const U = 1 << 4;
    pub const RWX = R | W | X;
    pub const VRWX = V | R | W | X;
    pub const FLAGS_MASK: u32 = 0x1f;

    /// Return true if a raw PTE has the Valid bit set and does not use the
    /// reserved R=0, W=1 encoding.
    pub inline fn isValid(pte: u32) bool {
        return (pte & V) != 0 and !((pte & R) == 0 and (pte & W) != 0);
    }

    /// Return true if a valid PTE points to the next page-table level.
    pub inline fn isPointer(pte: u32) bool {
        return (pte & RWX) == 0;
    }
};

pub const SoftTlbEntry = struct {
    guest_vaddr_page: u32 = INVALID_VADDR_PAGE,
    /// [0]: Valid, [1]: Read, [2]: Write, [3]: Execute, [4]: User.
    flags: u8 = 0,
    _pad: u8 = 0,
    epoch: u16 = 0,
    host_paddr_page: usize = 0,
};

pub const AccessResult = struct {
    val: u32 = 0,
    /// RISC-V exception cause (`riscv.Cause`) if a fault occurs.
    trap: ?u32 = null,
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
    entries: [TLB_ENTRIES]SoftTlbEntry = undefined,
    contiguous_regions: [MAX_CONTIGUOUS_REGIONS]ContiguousRegion =
        std.mem.zeroes([MAX_CONTIGUOUS_REGIONS]ContiguousRegion),
    epoch: u16 = 1,
    satp: u32 = 0,
    mstatus: u32 = 0,
    privilege_mode: u8 = riscv.PRIV_SUPERVISOR,
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

    pub const AmoOp = ops.AmoOp;
    pub const LrResult = ops.LrResult;
    pub const ScResult = ops.ScResult;

    pub const DirectMappingRegion = struct {
        vaddr_start: u32,
        vaddr_end: u32,
        hpa_start: usize,
        delta: i64,
    };

    pub fn init(gpa_base: usize, hpa_base: usize, ram_size: usize) SoftTlb {
        var tlb = SoftTlb{
            .guest_gpa_base = gpa_base,
            .guest_hpa_base = hpa_base,
            .guest_ram_size = ram_size,
        };
        tlb.initOnPtr(gpa_base, hpa_base, ram_size);
        return tlb;
    }

    pub fn initOnPtr(self: *SoftTlb, gpa: usize, hpa: usize, sz: usize) void {
        for (self.entries[0..]) |*entry| {
            entry.* = .{};
        }
        @memset(std.mem.sliceAsBytes(self.contiguous_regions[0..]), 0);
        self.epoch = 1;
        self.satp = 0;
        self.privilege_mode = riscv.PRIV_SUPERVISOR;
        self.guest_gpa_base = gpa;
        self.guest_hpa_base = hpa;
        self.guest_ram_size = sz;
    }

    pub fn flush(self: *SoftTlb) void {
        self.epoch +%= 1;
        for (self.entries[0..]) |*entry| {
            entry.guest_vaddr_page = INVALID_VADDR_PAGE;
            entry.flags = 0;
        }
        for (self.contiguous_regions[0..]) |*r| r.valid = false;
    }

    /// Synchronize SoftTLB address-space, privilege, and mstatus state with
    /// the virtual CPU, flushing cached translations when translation-affecting
    /// state changes.
    pub fn syncCpuState(
        self: *SoftTlb,
        satp: u32,
        priv: u8,
        mstatus: u32,
    ) void {
        const mask: u32 = riscv.MSTATUS.TRANSLATION_AFFECTING_MASK;
        if (self.satp != satp or
            self.privilege_mode != priv or
            ((self.mstatus ^ mstatus) & mask) != 0)
        {
            self.satp = satp;
            self.privilege_mode = priv;
            self.mstatus = mstatus;
            self.flush();
        } else {
            self.mstatus = mstatus;
        }
    }

    pub fn ppnToGpa(self: *SoftTlb, ppn: usize) usize {
        _ = self;
        return ppn << PAGE_SHIFT;
    }

    pub fn translateGpaToHpa(self: *SoftTlb, gpa: usize) ?usize {
        if (self.guest_hpa_base > 0 and gpa >= self.guest_gpa_base and
            (gpa - self.guest_gpa_base) < self.guest_ram_size)
        {
            return self.guest_hpa_base +% (gpa - self.guest_gpa_base);
        }
        return null;
    }

    pub fn checkPrivilegeFlags(
        self: *const SoftTlb,
        flags: u8,
        is_write: bool,
        is_exec: bool,
    ) bool {
        const is_user_page = (flags & PTE.U) != 0;
        if (self.privilege_mode == riscv.PRIV_USER) {
            if (!is_user_page) return false;
        } else if (self.privilege_mode == riscv.PRIV_SUPERVISOR and
            is_user_page)
        {
            if (is_exec or (self.mstatus & riscv.MSTATUS.SUM) == 0) {
                return false;
            }
        }
        const req_flag: u8 =
            if (is_exec) PTE.X else if (is_write) PTE.W else PTE.R;
        return (flags & req_flag) != 0;
    }

    /// Fast-path address translation using direct-mapped cache and contiguous
    /// superpage regions.
    pub fn translateFast(
        self: *SoftTlb,
        vaddr: u32,
        is_write: bool,
        is_exec: bool,
    ) ?usize {
        const page = vaddr >> PAGE_SHIFT;
        const entry = &self.entries[page & TLB_MASK];

        if (entry.epoch == self.epoch and (entry.flags & PTE.V) != 0 and
            entry.guest_vaddr_page == page)
        {
            if (!self.checkPrivilegeFlags(entry.flags, is_write, is_exec)) {
                return null;
            }
            const paddr = entry.host_paddr_page | (vaddr & PAGE_OFFSET_MASK);
            if (self.guest_hpa_base > 0 and paddr >= self.guest_hpa_base and
                (paddr - self.guest_hpa_base) < self.guest_ram_size)
            {
                return paddr;
            }
        }

        // Check dynamically verified contiguous regions (e.g. 4MB superpages).
        const reg_slot =
            (vaddr >> SV32_VPN1_SHIFT) & (MAX_CONTIGUOUS_REGIONS - 1);
        const region = &self.contiguous_regions[reg_slot];
        if (region.valid and vaddr >= region.vaddr_start and
            vaddr < region.vaddr_end)
        {
            if (!self.checkPrivilegeFlags(region.flags, is_write, is_exec)) {
                return null;
            }
            const paddr = region.hpa_start +% (vaddr - region.vaddr_start);
            if (self.guest_hpa_base > 0 and paddr >= self.guest_hpa_base and
                (paddr - self.guest_hpa_base) < self.guest_ram_size)
            {
                entry.* = .{
                    .guest_vaddr_page = page,
                    .host_paddr_page = paddr & ~@as(usize, PAGE_OFFSET_MASK),
                    .flags = region.flags,
                    .epoch = self.epoch,
                };
                return paddr;
            }
        }
        return null;
    }

    pub const fallbackIdentity = walk.fallbackIdentity;
    pub const getDirectMappingRegion = walk.getDirectMappingRegion;
    pub const translateFull = walk.translateFull;

    /// Query the dynamic direct-mapped host physical delta for a virtual
    /// address.
    pub fn getDirectMappingDelta(self: *SoftTlb, vaddr: u32) ?i64 {
        if (self.getDirectMappingRegion(vaddr)) |r| return r.delta;
        return null;
    }

    pub const readU8 = ops.readU8;
    pub const readU16 = ops.readU16;
    pub const fetchU32 = ops.fetchU32;
    pub const readU32 = ops.readU32;
    pub const writeU8 = ops.writeU8;
    pub const writeU16 = ops.writeU16;
    pub const writeU32 = ops.writeU32;
    pub const amoU32 = ops.amoU32;
    pub const lrU32 = ops.lrU32;
    pub const scU32 = ops.scU32;
};

test "SoftTlb Sv32 validation rejects illegal PTEs and misaligned superpages" {
    const testing = std.testing;
    testing.refAllDecls(@This());
    _ = ops;
    _ = walk;

    var uart = @import("devices/vuart.zig").VirtualUart{};
    var timer = @import("devices/vtimer.zig").VirtualTimer{};
    var pic = @import("devices/vpic.zig").VirtualPlic{};
    var bus = bus_mod.Bus{ .uart = &uart, .timer = &timer, .pic = &pic };

    var mock_ram: [8192]u8 align(4096) = std.mem.zeroes([8192]u8);
    const ram_addr = @intFromPtr(&mock_ram);

    var tlb = SoftTlb.init(0x80000000, ram_addr, 8192);
    tlb.satp = (1 << SV32_SATP_MODE_SHIFT) | 0x80000;
    tlb.privilege_mode = riscv.PRIV_SUPERVISOR;

    const root_pt = @as([*]u32, @ptrCast(@alignCast(&mock_ram[0])));

    // 1. Leaf PTE with R=0, W=1 (illegal reserved encoding).
    root_pt[0] = 0x20000000 | PTE.V | PTE.W;
    try testing.expect(
        tlb.translateFull(0x00000000, true, false, &bus) == null,
    );

    // 2. 4MB Superpage with misaligned PPN[0] != 0 (bits 19..10 set).
    root_pt[1] = 0x20000000 | 0x00000400 | PTE.V | PTE.R | PTE.W;
    try testing.expect(
        tlb.translateFull(0x00400000, false, false, &bus) == null,
    );

    // 3. Valid 4MB Superpage with PPN[0] == 0 (must succeed).
    root_pt[2] = 0x20000000 | PTE.V | PTE.R | PTE.W;
    try testing.expect(
        tlb.translateFull(0x00800000, false, false, &bus) != null,
    );
}
