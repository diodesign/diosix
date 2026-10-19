// Architecture-specific dynamic recompiler handler for AArch64 guests.
//
// Reserved for future AArch64 guest decoder and translation expansion.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const emulation_native = @import("emulation");
const VCpu = emulation_native.VCpu;

pub const ExceptionAction = enum {
    emulated,
    delivered,
    unhandled,
    wfi,
};

pub fn initRegisters(
    vcpu: *VCpu,
    entry: usize,
    dtb: usize,
    vcore_id: usize,
) void {
    vcpu.pc = @truncate(entry);
    vcpu.setReg(1, @truncate(dtb));
    _ = vcore_id;
}

pub fn readPC(vcpu: *const VCpu) u32 {
    return vcpu.pc;
}

pub fn writePC(vcpu: *VCpu, pc: u32) void {
    vcpu.pc = pc;
}

test "aarch64 arch register initialization and PC accessors" {
    const testing = std.testing;
    testing.refAllDecls(@This());

    var cpu = VCpu{};
    initRegisters(&cpu, 0x40080000, 0x44000000, 0);
    try testing.expectEqual(@as(u32, 0x40080000), readPC(&cpu));
    const x1_val: u32 = @truncate(cpu.getReg(1));
    try testing.expectEqual(@as(u32, 0x44000000), x1_val);

    writePC(&cpu, 0x40080100);
    try testing.expectEqual(@as(u32, 0x40080100), readPC(&cpu));
}
