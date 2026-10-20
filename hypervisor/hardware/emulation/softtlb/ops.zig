// Software MMU Load, Store, Fetch, and Atomic Memory Operations
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("interface").riscv;
const bus_mod = @import("../devices/bus.zig");
const vcpu_mod = @import("../vcpu.zig");
const softtlb_mod = @import("../softtlb.zig");
const SoftTlb = softtlb_mod.SoftTlb;
const AccessResult = softtlb_mod.AccessResult;

const PAGE_SIZE = softtlb_mod.PAGE_SIZE;
const PAGE_OFFSET_MASK = softtlb_mod.PAGE_OFFSET_MASK;

pub const ALIGN16_MASK: usize = @alignOf(u16) - 1;
pub const ALIGN32_MASK: usize = @alignOf(u32) - 1;
pub const BITS_PER_BYTE: u5 = 8;

const TRAP_LOAD_MISALIGNED: u32 = @backingInt(riscv.Cause.load_alignment);
const TRAP_STORE_MISALIGNED: u32 = @backingInt(riscv.Cause.store_alignment);
const TRAP_INST_PAGE_FAULT: u32 =
    @backingInt(riscv.Cause.instruction_page_fault);
const TRAP_LOAD_PAGE_FAULT: u32 = @backingInt(riscv.Cause.load_page_fault);
const TRAP_STORE_PAGE_FAULT: u32 = @backingInt(riscv.Cause.store_page_fault);

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

pub const LrResult = struct {
    trap: ?u32 = null,
    val: u32 = 0,
    paddr: usize = 0,
};

pub const ScResult = struct {
    trap: ?u32 = null,
    success: bool = false,
};

/// Return true if an access of `size` bytes at `vaddr` straddles a 4 KiB
/// virtual page boundary. When true, the access spans two virtual pages that
/// may map to non-contiguous physical frames or have different permissions,
/// so each page must be translated independently.
inline fn crossesPageBoundary(vaddr: u32, size: u32) bool {
    return (vaddr & PAGE_OFFSET_MASK) > (PAGE_SIZE - size);
}

pub fn readU8(self: *SoftTlb, vaddr: u32, bus: *bus_mod.Bus) AccessResult {
    const paddr = self.translateFast(vaddr, false, false) orelse
        (self.translateFull(vaddr, false, false, bus) orelse {
            return .{ .trap = TRAP_LOAD_PAGE_FAULT };
        });
    const p32: u32 = @truncate(paddr);
    if (bus.isMmio(p32)) {
        return .{ .val = @truncate(bus.read(p32, 1)) };
    }
    const ptr = @as(*align(1) const u8, @ptrFromInt(paddr));
    return .{ .val = @atomicLoad(u8, ptr, .acquire) };
}

pub fn readU16(self: *SoftTlb, vaddr: u32, bus: *bus_mod.Bus) AccessResult {
    if (crossesPageBoundary(vaddr, @sizeOf(u16))) {
        const b0 = readU8(self, vaddr, bus);
        if (b0.trap) |cause| return .{ .trap = cause };
        const b1 = readU8(self, vaddr +% 1, bus);
        if (b1.trap) |cause| return .{ .trap = cause };
        return .{
            .val = @as(u32, b0.val) | (@as(u32, b1.val) << BITS_PER_BYTE),
        };
    }
    const paddr = self.translateFast(vaddr, false, false) orelse
        (self.translateFull(vaddr, false, false, bus) orelse {
            return .{ .trap = TRAP_LOAD_PAGE_FAULT };
        });
    const p32: u32 = @truncate(paddr);
    if (bus.isMmio(p32)) {
        return .{ .val = @truncate(bus.read(p32, 2)) };
    }
    if ((paddr & ALIGN16_MASK) == 0) {
        const ptr = @as(*align(2) const u16, @ptrFromInt(paddr));
        return .{ .val = @atomicLoad(u16, ptr, .acquire) };
    }
    const ptr_lo = @as(*align(1) const u8, @ptrFromInt(paddr));
    const ptr_hi = @as(*align(1) const u8, @ptrFromInt(paddr +% 1));
    const lo = @atomicLoad(u8, ptr_lo, .acquire);
    const hi = @atomicLoad(u8, ptr_hi, .acquire);
    return .{ .val = @as(u32, lo) | (@as(u32, hi) << BITS_PER_BYTE) };
}

pub fn fetchU32(self: *SoftTlb, vaddr: u32, bus: *bus_mod.Bus) AccessResult {
    if (crossesPageBoundary(vaddr, @sizeOf(u32))) {
        const paddr1 = self.translateFast(vaddr, false, true) orelse
            (self.translateFull(vaddr, false, true, bus) orelse {
                return .{ .trap = TRAP_INST_PAGE_FAULT };
            });
        const paddr2 = self.translateFast(vaddr +% 2, false, true) orelse
            (self.translateFull(vaddr +% 2, false, true, bus) orelse {
                return .{ .trap = TRAP_INST_PAGE_FAULT };
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
    const paddr = self.translateFast(vaddr, false, true) orelse
        (self.translateFull(vaddr, false, true, bus) orelse {
            return .{ .trap = TRAP_INST_PAGE_FAULT };
        });
    const p32: u32 = @truncate(paddr);
    if (bus.isMmio(p32)) {
        return .{ .val = bus.read(p32, 4) };
    }
    if ((paddr & ALIGN32_MASK) == 0) {
        const ptr = @as(*align(4) const u32, @ptrFromInt(paddr));
        return .{ .val = @atomicLoad(u32, ptr, .acquire) };
    }
    const ptr = @as(*align(1) const volatile u32, @ptrFromInt(paddr));
    return .{ .val = ptr.* };
}

pub fn readU32(self: *SoftTlb, vaddr: u32, bus: *bus_mod.Bus) AccessResult {
    if (crossesPageBoundary(vaddr, @sizeOf(u32))) {
        var val: u32 = 0;
        var i: u32 = 0;
        while (i < 4) : (i += 1) {
            const res = readU8(self, vaddr +% i, bus);
            if (res.trap) |cause| return .{ .trap = cause };
            const shift: u5 = @truncate(i * BITS_PER_BYTE);
            val |= (@as(u32, res.val) << shift);
        }
        return .{ .val = val };
    }
    const paddr = self.translateFast(vaddr, false, false) orelse
        (self.translateFull(vaddr, false, false, bus) orelse {
            return .{ .trap = TRAP_LOAD_PAGE_FAULT };
        });
    const p32: u32 = @truncate(paddr);
    if (bus.isMmio(p32)) {
        return .{ .val = bus.read(p32, 4) };
    }
    if ((paddr & ALIGN32_MASK) == 0) {
        const ptr = @as(*align(4) const u32, @ptrFromInt(paddr));
        return .{ .val = @atomicLoad(u32, ptr, .acquire) };
    }
    var val: u32 = 0;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const byte_ptr = @as(*align(1) const u8, @ptrFromInt(paddr +% i));
        const b = @atomicLoad(u8, byte_ptr, .acquire);
        const shift: u5 = @truncate(i * BITS_PER_BYTE);
        val |= (@as(u32, b) << shift);
    }
    return .{ .val = val };
}

inline fn translateWriteAddr(
    self: *SoftTlb,
    vaddr: u32,
    bus: *bus_mod.Bus,
) ?usize {
    return self.translateFast(vaddr, true, false) orelse
        self.translateFull(vaddr, true, false, bus);
}

inline fn writeTranslatedByte(
    paddr: usize,
    val: u8,
    bus: *bus_mod.Bus,
) void {
    const p32: u32 = @truncate(paddr);
    if (bus.isMmio(p32)) {
        bus.write(p32, val, 1);
        return;
    }
    const ptr = @as(*align(1) u8, @ptrFromInt(paddr));
    @atomicStore(u8, ptr, val, .release);
    vcpu_mod.VCpu.invalidateReservations(paddr);
}

pub fn writeU8(self: *SoftTlb, vaddr: u32, val: u8, bus: *bus_mod.Bus) ?u32 {
    const paddr = translateWriteAddr(self, vaddr, bus) orelse
        return TRAP_STORE_PAGE_FAULT;
    writeTranslatedByte(paddr, val, bus);
    return null;
}

pub fn writeU16(self: *SoftTlb, vaddr: u32, val: u16, bus: *bus_mod.Bus) ?u32 {
    if (crossesPageBoundary(vaddr, @sizeOf(u16))) {
        const paddr0 = translateWriteAddr(self, vaddr, bus) orelse
            return TRAP_STORE_PAGE_FAULT;
        const paddr1 = translateWriteAddr(self, vaddr +% 1, bus) orelse
            return TRAP_STORE_PAGE_FAULT;
        writeTranslatedByte(paddr0, @truncate(val), bus);
        writeTranslatedByte(paddr1, @truncate(val >> BITS_PER_BYTE), bus);
        return null;
    }
    const paddr = translateWriteAddr(self, vaddr, bus) orelse
        return TRAP_STORE_PAGE_FAULT;
    const p32: u32 = @truncate(paddr);
    if (bus.isMmio(p32)) {
        bus.write(p32, val, 2);
        return null;
    }
    if ((paddr & ALIGN16_MASK) == 0) {
        const ptr = @as(*align(2) u16, @ptrFromInt(paddr));
        @atomicStore(u16, ptr, val, .release);
        vcpu_mod.VCpu.invalidateReservations(paddr);
        return null;
    }
    const ptr_lo = @as(*align(1) u8, @ptrFromInt(paddr));
    const ptr_hi = @as(*align(1) u8, @ptrFromInt(paddr +% 1));
    @atomicStore(u8, ptr_lo, @truncate(val), .release);
    @atomicStore(u8, ptr_hi, @truncate(val >> BITS_PER_BYTE), .release);
    vcpu_mod.VCpu.invalidateReservations(paddr);
    return null;
}

pub fn writeU32(self: *SoftTlb, vaddr: u32, val: u32, bus: *bus_mod.Bus) ?u32 {
    if (crossesPageBoundary(vaddr, @sizeOf(u32))) {
        var paddrs: [4]usize = undefined;
        var i: u32 = 0;
        while (i < 4) : (i += 1) {
            paddrs[i] = translateWriteAddr(self, vaddr +% i, bus) orelse
                return TRAP_STORE_PAGE_FAULT;
        }
        i = 0;
        while (i < 4) : (i += 1) {
            const shift: u5 = @truncate(i * BITS_PER_BYTE);
            writeTranslatedByte(paddrs[i], @truncate(val >> shift), bus);
        }
        return null;
    }
    const paddr = translateWriteAddr(self, vaddr, bus) orelse
        return TRAP_STORE_PAGE_FAULT;
    const p32: u32 = @truncate(paddr);
    if (bus.isMmio(p32)) {
        bus.write(p32, val, 4);
        return null;
    }
    if ((paddr & ALIGN32_MASK) == 0) {
        const ptr = @as(*align(4) u32, @ptrFromInt(paddr));
        @atomicStore(u32, ptr, val, .release);
        vcpu_mod.VCpu.invalidateReservations(paddr);
        return null;
    }
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const byte_ptr = @as(*align(1) u8, @ptrFromInt(paddr +% i));
        const shift: u5 = @truncate(i * BITS_PER_BYTE);
        @atomicStore(u8, byte_ptr, @truncate(val >> shift), .release);
    }
    vcpu_mod.VCpu.invalidateReservations(paddr);
    return null;
}

pub fn amoU32(
    self: *SoftTlb,
    vaddr: u32,
    val: u32,
    op: AmoOp,
    bus: *bus_mod.Bus,
) AccessResult {
    if ((vaddr & ALIGN32_MASK) != 0) {
        return .{ .trap = TRAP_STORE_MISALIGNED };
    }
    const paddr = self.translateFast(vaddr, true, false) orelse
        (self.translateFull(vaddr, true, false, bus) orelse {
            return .{ .trap = TRAP_STORE_PAGE_FAULT };
        });
    const p32: u32 = @truncate(paddr);
    if (bus.isMmio(p32)) {
        const old = @as(u32, @truncate(bus.read(p32, 4)));
        const old_i32: i32 = @bitCast(old);
        const val_i32: i32 = @bitCast(val);
        const new_val: u32 = switch (op) {
            .swap => val,
            .add => old +% val,
            .xor => old ^ val,
            .and_op => old & val,
            .or_op => old | val,
            .min => @bitCast(@min(old_i32, val_i32)),
            .max => @bitCast(@max(old_i32, val_i32)),
            .minu => @min(old, val),
            .maxu => @max(old, val),
        };
        bus.write(p32, new_val, 4);
        return .{ .val = old };
    }
    const ptr = @as(*align(4) u32, @ptrFromInt(paddr));
    const iptr = @as(*align(4) i32, @ptrCast(ptr));
    const val_i32: i32 = @bitCast(val);
    const old_val: u32 = switch (op) {
        .swap => @atomicRmw(u32, ptr, .Xchg, val, .seq_cst),
        .add => @atomicRmw(u32, ptr, .Add, val, .seq_cst),
        .xor => @atomicRmw(u32, ptr, .Xor, val, .seq_cst),
        .and_op => @atomicRmw(u32, ptr, .And, val, .seq_cst),
        .or_op => @atomicRmw(u32, ptr, .Or, val, .seq_cst),
        .min => @bitCast(@atomicRmw(i32, iptr, .Min, val_i32, .seq_cst)),
        .max => @bitCast(@atomicRmw(i32, iptr, .Max, val_i32, .seq_cst)),
        .minu => @atomicRmw(u32, ptr, .Min, val, .seq_cst),
        .maxu => @atomicRmw(u32, ptr, .Max, val, .seq_cst),
    };
    vcpu_mod.VCpu.invalidateReservations(paddr);
    return .{ .val = old_val };
}

pub fn lrU32(
    self: *SoftTlb,
    vaddr: u32,
    hart_id: usize,
    bus: *bus_mod.Bus,
) LrResult {
    if ((vaddr & ALIGN32_MASK) != 0) {
        return .{ .trap = TRAP_LOAD_MISALIGNED };
    }
    const paddr = self.translateFast(vaddr, false, false) orelse
        (self.translateFull(vaddr, false, false, bus) orelse {
            return .{ .trap = TRAP_LOAD_PAGE_FAULT };
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

pub fn scU32(
    self: *SoftTlb,
    vaddr: u32,
    val: u32,
    hart_id: usize,
    bus: *bus_mod.Bus,
) ScResult {
    if ((vaddr & ALIGN32_MASK) != 0) {
        return .{ .trap = TRAP_STORE_MISALIGNED };
    }
    const paddr = self.translateFast(vaddr, true, false) orelse
        (self.translateFull(vaddr, true, false, bus) orelse {
            return .{ .trap = TRAP_STORE_PAGE_FAULT };
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

test "SoftTlb boundary access at 0xffffffff does not panic" {
    const testing = std.testing;
    testing.refAllDecls(@This());

    var uart = @import("../devices/vuart.zig").VirtualUart{};
    var timer = @import("../devices/vtimer.zig").VirtualTimer{};
    var pic = @import("../devices/vpic.zig").VirtualPlic{};
    var bus = bus_mod.Bus{
        .uart = &uart,
        .timer = &timer,
        .pic = &pic,
    };

    var tlb = SoftTlb.init(0x80000000, 0x80000000, 0x10000000);

    // 1. readU16 at 0xffffffff (unaligned across 32-bit boundary).
    const r16 = tlb.readU16(0xffffffff, &bus);
    try testing.expect(r16.trap != null);

    // 2. readU32 at 0xfffffffd (spans 0xfffffffd..0x00000000).
    const r32 = tlb.readU32(0xfffffffd, &bus);
    try testing.expect(r32.trap != null);

    // 3. writeU16 at 0xffffffff.
    const w16 = tlb.writeU16(0xffffffff, 0x1234, &bus);
    try testing.expect(w16 != null);

    // 4. writeU32 at 0xfffffffe.
    const w32 = tlb.writeU32(0xfffffffe, 0x12345678, &bus);
    try testing.expect(w32 != null);
}
