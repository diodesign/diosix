// Memory Load, Store, and Atomic Execution Helpers for RV32 Interpreter.
//
// Executes guest RV32 integer load/store (LB, LBU, LH, LHU, LW, SB, SH, SW)
// and A-extension atomic (LR.W, SC.W, AMO*.W) operations via SoftTLB.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const decoder_rv32 = @import("../../decoders/rv32.zig");
const vcpu_mod = @import("../../../vcpu.zig");
const softtlb_mod = @import("../../../softtlb.zig");
const bus_mod = @import("../../../devices/bus.zig");

pub inline fn u32Gpr(self: anytype, r: u5) u32 {
    return @truncate(self.vcpu.getGpr(r));
}

pub inline fn i32Gpr(self: anytype, r: u5) i32 {
    return @bitCast(u32Gpr(self, r));
}

pub fn execLb(
    self: anytype,
    pc_before: u32,
    d: decoder_rv32.LoadType,
) bool {
    const vaddr = u32Gpr(self, d.rs1) +% @as(u32, @bitCast(d.offset));
    const res = self.tlb.readU8(vaddr, self.bus);
    if (res.trap) |cause| {
        self.trap(cause, pc_before, vaddr);
        return false;
    }
    const sval = @as(i8, @bitCast(@as(u8, @truncate(res.val))));
    self.vcpu.setGpr(d.rd, @as(u32, @bitCast(@as(i32, sval))));
    return true;
}

pub fn execLbu(
    self: anytype,
    pc_before: u32,
    d: decoder_rv32.LoadType,
) bool {
    const vaddr = u32Gpr(self, d.rs1) +% @as(u32, @bitCast(d.offset));
    const res = self.tlb.readU8(vaddr, self.bus);
    if (res.trap) |cause| {
        self.trap(cause, pc_before, vaddr);
        return false;
    }
    self.vcpu.setGpr(d.rd, res.val);
    return true;
}

pub fn execLh(
    self: anytype,
    pc_before: u32,
    d: decoder_rv32.LoadType,
) bool {
    const vaddr = u32Gpr(self, d.rs1) +% @as(u32, @bitCast(d.offset));
    const res = self.tlb.readU16(vaddr, self.bus);
    if (res.trap) |cause| {
        self.trap(cause, pc_before, vaddr);
        return false;
    }
    const sval = @as(i16, @bitCast(@as(u16, @truncate(res.val))));
    self.vcpu.setGpr(d.rd, @as(u32, @bitCast(@as(i32, sval))));
    return true;
}

pub fn execLhu(
    self: anytype,
    pc_before: u32,
    d: decoder_rv32.LoadType,
) bool {
    const vaddr = u32Gpr(self, d.rs1) +% @as(u32, @bitCast(d.offset));
    const res = self.tlb.readU16(vaddr, self.bus);
    if (res.trap) |cause| {
        self.trap(cause, pc_before, vaddr);
        return false;
    }
    self.vcpu.setGpr(d.rd, res.val);
    return true;
}

pub fn execLw(
    self: anytype,
    pc_before: u32,
    d: decoder_rv32.LoadType,
) bool {
    const vaddr = u32Gpr(self, d.rs1) +% @as(u32, @bitCast(d.offset));
    const res = self.tlb.readU32(vaddr, self.bus);
    if (res.trap) |cause| {
        self.trap(cause, pc_before, vaddr);
        return false;
    }
    self.vcpu.setGpr(d.rd, res.val);
    return true;
}

pub fn execSb(
    self: anytype,
    pc_before: u32,
    d: decoder_rv32.StoreType,
) bool {
    const vaddr = u32Gpr(self, d.rs1) +% @as(u32, @bitCast(d.offset));
    if (self.tlb.writeU8(
        vaddr,
        @truncate(u32Gpr(self, d.rs2)),
        self.bus,
    )) |cause| {
        self.trap(cause, pc_before, vaddr);
        return false;
    }
    return true;
}

pub fn execSh(
    self: anytype,
    pc_before: u32,
    d: decoder_rv32.StoreType,
) bool {
    const vaddr = u32Gpr(self, d.rs1) +% @as(u32, @bitCast(d.offset));
    if (self.tlb.writeU16(
        vaddr,
        @truncate(u32Gpr(self, d.rs2)),
        self.bus,
    )) |cause| {
        self.trap(cause, pc_before, vaddr);
        return false;
    }
    return true;
}

pub fn execSw(
    self: anytype,
    pc_before: u32,
    d: decoder_rv32.StoreType,
) bool {
    const vaddr = u32Gpr(self, d.rs1) +% @as(u32, @bitCast(d.offset));
    if (self.tlb.writeU32(
        vaddr,
        u32Gpr(self, d.rs2),
        self.bus,
    )) |cause| {
        self.trap(cause, pc_before, vaddr);
        return false;
    }
    return true;
}

pub fn execLrW(
    self: anytype,
    pc_before: u32,
    next_pc: u32,
    d: decoder_rv32.LrType,
) void {
    const vaddr = u32Gpr(self, d.rs1);
    const res = self.tlb.lrU32(vaddr, @intCast(self.vcpu.id), self.bus);
    if (res.trap) |cause| {
        self.trap(cause, pc_before, vaddr);
        return;
    }
    if (d.rd != 0) self.vcpu.setGpr(d.rd, res.val);
    self.vcpu.pc = next_pc;
}

pub fn execScW(
    self: anytype,
    pc_before: u32,
    next_pc: u32,
    d: decoder_rv32.AmoType,
) void {
    const vaddr = u32Gpr(self, d.rs1);
    const val = u32Gpr(self, d.rs2);
    const res = self.tlb.scU32(vaddr, val, @intCast(self.vcpu.id), self.bus);
    if (res.trap) |cause| {
        self.trap(cause, pc_before, vaddr);
        return;
    }
    if (d.rd != 0) self.vcpu.setGpr(d.rd, if (res.success) 0 else 1);
    self.vcpu.pc = next_pc;
}

pub fn execAmo(
    self: anytype,
    pc_before: u32,
    next_pc: u32,
    d: decoder_rv32.AmoType,
    op: softtlb_mod.SoftTlb.AmoOp,
) void {
    const vaddr = u32Gpr(self, d.rs1);
    const val = u32Gpr(self, d.rs2);
    const res = self.tlb.amoU32(vaddr, val, op, self.bus);
    if (res.trap) |cause| {
        self.trap(cause, pc_before, vaddr);
        return;
    }
    if (d.rd != 0) self.vcpu.setGpr(d.rd, res.val);
    self.vcpu.pc = next_pc;
}

test "interpreter mem load and store helpers" {
    const testing = std.testing;
    testing.refAllDecls(@This());

    var ram: [4096]u8 align(4096) = @splat(0);
    var vcpu = vcpu_mod.VCpu{ .id = 0, .pc = 0x8000_0000 };
    var tlb = softtlb_mod.SoftTlb.init(0x8000_0000, @intFromPtr(&ram), 4096);
    var uart = @import("../../../devices/vuart.zig").VirtualUart{};
    var timer = @import("../../../devices/vtimer.zig").VirtualTimer{};
    var pic = @import("../../../devices/vpic.zig").VirtualPlic{};
    var bus = bus_mod.Bus{ .uart = &uart, .timer = &timer, .pic = &pic };

    const MockEnv = struct {
        vcpu: *vcpu_mod.VCpu,
        tlb: *softtlb_mod.SoftTlb,
        bus: *bus_mod.Bus,

        pub fn trap(
            self: *@This(),
            cause: u32,
            fault_pc: u32,
            stval: u32,
        ) void {
            self.vcpu.injectException(cause, fault_pc, stval);
        }
    };

    var env = MockEnv{ .vcpu = &vcpu, .tlb = &tlb, .bus = &bus };
    vcpu.setGpr(10, 0x8000_0010);
    vcpu.setGpr(11, 0xdead_beef);

    try testing.expect(
        execSw(&env, 0x8000_0000, .{ .rs1 = 10, .rs2 = 11, .offset = 4 }),
    );
    try testing.expect(
        execLw(&env, 0x8000_0004, .{ .rd = 12, .rs1 = 10, .offset = 4 }),
    );
    try testing.expectEqual(@as(u32, 0xdead_beef), u32Gpr(&env, 12));
}
