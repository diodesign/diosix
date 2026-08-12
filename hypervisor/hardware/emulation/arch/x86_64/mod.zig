// Architecture-specific dynamic recompiler handler for x86_64 guests.
//
// Reserved for future x86_64 guest decoder and translation expansion.
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

pub fn initRegisters(vcpu: *VCpu, entry: usize, gpa_base: usize, range_size: usize, early_pgt_gpa: usize, sub_vcore_count: usize, vcore_id: usize) void {
    _ = gpa_base;
    _ = range_size;
    _ = early_pgt_gpa;
    _ = sub_vcore_count;
    _ = vcore_id;
    vcpu.pc = @truncate(entry);
}

pub fn readPC(vcpu: *const VCpu) u32 {
    return vcpu.pc;
}

pub fn writePC(vcpu: *VCpu, pc: u32) void {
    vcpu.pc = pc;
}
