// Architecture-specific dynamic recompiler handler for AArch64 guests.
//
// Reserved for future AArch64 guest decoder and translation expansion.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const emulation_native = @import("emulation");
const VCpu = emulation_native.VCpu;
const vcore = @import("../../../../core/vcore.zig");

pub const ExceptionAction = enum {
    emulated,
    delivered,
    unhandled,
    wfi,
};

pub fn initRegisters(vcpu: *VCpu, entry: usize, dtb: usize, vcore_id: usize) void {
    vcpu.pc = @truncate(entry);
    vcpu.setReg(0, @truncate(dtb));
    _ = vcore_id;
}

pub fn readPC(vcpu: *const VCpu) u32 {
    return vcpu.pc;
}

pub fn writePC(vcpu: *VCpu, pc: u32) void {
    vcpu.pc = pc;
}
