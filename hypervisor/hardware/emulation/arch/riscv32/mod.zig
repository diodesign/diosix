// Architecture-specific emulation handler for 32-bit RISC-V guests.
//
// Handles instruction decoding, exception classification, CSR emulation,
// Sv32 page table translation, and SBI ECALL forwarding using the native
// freestanding Zig dynamic recompiler.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const emulation_native = @import("emulation");
pub const VCpu = emulation_native.VCpu;
pub const Engine = emulation_native.Engine;
const vcore = @import("../../../../core/vcore.zig");
const pcore = @import("../../../../core/pcore.zig");
const guest = @import("../../../../core/guest.zig");
const riscv = @import("../../../native/cpu/riscv64/mod.zig");
const debug = @import("../../../../core/debug.zig");

pub const ExceptionAction = enum {
    emulated,
    delivered,
    unhandled,
    wfi,
};

/// Exception delegation mask for medeleg.
const MEDELEG_DEFAULT: u32 = 0xBDFF;
/// Interrupt delegation mask for mideleg.
const MIDELEG_DEFAULT: u32 = 0x222;

/// Set up initial RISC-V register state for a new emulated vcore.
pub fn initRegisters(vcpu: *VCpu, entry: usize, dtb: usize, vcore_id: usize) void {
    vcpu.pc = @truncate(entry);
    vcpu.setReg(@intFromEnum(riscv.Register.a0), @truncate(vcore_id)); // a0
    vcpu.setReg(@intFromEnum(riscv.Register.a1), @truncate(dtb)); // a1

    vcpu.medeleg = MEDELEG_DEFAULT;
    vcpu.mideleg = MIDELEG_DEFAULT;
    vcpu.privilege_mode = emulation_native.vcpu.PRIV_SUPERVISOR;
    vcpu.priv_mode = emulation_native.vcpu.PRIV_SUPERVISOR;
    vcpu.softtlb.privilege_mode = emulation_native.vcpu.PRIV_SUPERVISOR;
    vcpu.mstatus = (1 << riscv.MSTATUS.MPP_SHIFT) | (1 << riscv.SSTATUS.SPP_SHIFT) | riscv.MSTATUS.MPIE | riscv.SSTATUS.SPIE | (1 << 21) | (3 << riscv.MSTATUS.FS_SHIFT) | (3 << riscv.MSTATUS.VS_SHIFT);
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

/// Translate virtual address to physical address via SoftTLB.
pub fn translateVA(vcpu: *VCpu, vaddr: u32) ?usize {
    return vcpu.softtlb.translate(vaddr, false);
}

/// Read a RISC-V general purpose register (x0-x31).
pub fn readGpr(vcpu: *const VCpu, reg: u5) u32 {
    return vcpu.getReg(reg);
}

/// Write a RISC-V general purpose register (x0-x31).
pub fn writeGpr(vcpu: *VCpu, reg: u5, val: u32) void {
    vcpu.setReg(reg, val);
}
