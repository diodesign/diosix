// Architecture-specific emulation handler for 32-bit RISC-V guests.
//
// Handles initial register state, PC accessors, and 32-bit GPR helpers for
// the native freestanding Zig dynamic recompiler.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const emulation_native = @import("emulation");
pub const VCpu = emulation_native.VCpu;
pub const Engine = emulation_native.Engine;
const riscv = @import("../../../native/cpu/riscv64/mod.zig");
const riscv_if = @import("interface").riscv;

pub const ExceptionAction = enum {
    emulated,
    delivered,
    unhandled,
    wfi,
};

/// Exception delegation mask for medeleg.
const MEDELEG_DEFAULT: u32 = @truncate(
    riscv_if.DELEGATED_EXCEPTIONS |
        (1 << @backingInt(riscv.Cause.illegal_instruction)) |
        (1 << @backingInt(riscv.Cause.virtual_supervisor_environment_call)) |
        (1 << @backingInt(riscv.Cause.machine_environment_call)),
);
/// Interrupt delegation mask for mideleg.
const MIDELEG_DEFAULT: u32 = @truncate(
    riscv.MIP.SSIP | riscv.MIP.STIP | riscv.MIP.SEIP,
);

/// Set up initial RISC-V register state for a new emulated vcore.
pub fn initRegisters(
    vcpu: *VCpu,
    entry: usize,
    dtb: usize,
    vcore_id: usize,
) void {
    vcpu.pc = @truncate(entry);
    vcpu.setReg(
        @truncate(@backingInt(riscv.Register.a0)),
        @truncate(vcore_id),
    );
    vcpu.setReg(
        @truncate(@backingInt(riscv.Register.a1)),
        @truncate(dtb),
    );

    vcpu.medeleg = MEDELEG_DEFAULT;
    vcpu.mideleg = MIDELEG_DEFAULT;
    vcpu.privilege_mode = emulation_native.vcpu.PRIV_SUPERVISOR;
    vcpu.softtlb.privilege_mode = emulation_native.vcpu.PRIV_SUPERVISOR;
    vcpu.mstatus = @truncate(
        riscv.MSTATUS.MPP_SUPERVISOR |
            riscv.MSTATUS.SPP |
            riscv.MSTATUS.MPIE |
            riscv.MSTATUS.SPIE |
            riscv.MSTATUS.TW |
            riscv.MSTATUS.FS_DIRTY |
            riscv.MSTATUS.VS_DIRTY,
    );
    vcpu.time = riscv.readTime();
}

/// Read the program counter.
pub fn readPC(vcpu: *const VCpu) u32 {
    return vcpu.pc;
}

/// Write the program counter.
pub fn writePC(vcpu: *VCpu, pc: u32) void {
    vcpu.pc = pc;
}

/// Read a RISC-V general purpose register (x0-x31).
pub fn readGpr(vcpu: *const VCpu, reg: u5) u32 {
    return @truncate(vcpu.getReg(reg));
}

/// Write a RISC-V general purpose register (x0-x31).
pub fn writeGpr(vcpu: *VCpu, reg: u5, val: u32) void {
    vcpu.setReg(reg, val);
}

test "riscv32 arch register initialization and accessors" {
    const testing = std.testing;
    testing.refAllDecls(@This());

    var cpu = VCpu{};
    initRegisters(&cpu, 0x80000000, 0x82200000, 3);
    try testing.expectEqual(@as(u32, 0x80000000), readPC(&cpu));
    try testing.expectEqual(
        @as(u32, 3),
        readGpr(&cpu, @truncate(@backingInt(riscv.Register.a0))),
    );
    try testing.expectEqual(
        @as(u32, 0x82200000),
        readGpr(&cpu, @truncate(@backingInt(riscv.Register.a1))),
    );

    const t0: u5 = @truncate(@backingInt(riscv.Register.t0));
    writePC(&cpu, 0x80001000);
    writeGpr(&cpu, t0, 0xcafebabe);
    try testing.expectEqual(@as(u32, 0x80001000), readPC(&cpu));
    try testing.expectEqual(@as(u32, 0xcafebabe), readGpr(&cpu, t0));
}
