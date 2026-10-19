// Privileged CSR, Trap-Return, Floating-Point & Vector Interpreter Helpers.
//
// Executes guest RV32 CSR accesses, SRET/MRET privilege transitions,
// floating-point (F/D) memory operations, and vector (V) memory operations.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const decoder_rv32 = @import("../../decoders/rv32.zig");
const vcpu_mod = @import("../../../vcpu.zig");
const softtlb_mod = @import("../../../softtlb.zig");
const riscv = @import("interface").riscv;

pub inline fn u32Gpr(self: anytype, r: u5) u32 {
    return @truncate(self.vcpu.getGpr(r));
}

pub inline fn i32Gpr(self: anytype, r: u5) i32 {
    return @bitCast(u32Gpr(self, r));
}

fn checkCsrAccess(priv: u8, csr: u12, will_write: bool) bool {
    const min_priv: u8 = @truncate((csr >> 8) & 3);
    if (priv < min_priv) return false;
    const is_ro = ((csr >> 10) & 3) == 3;
    if (will_write and is_ro) return false;
    return true;
}

pub inline fn isCsrAccessPermitted(
    self: anytype,
    csr: u12,
    will_write: bool,
) bool {
    if (!checkCsrAccess(self.vcpu.privilege_mode, csr, will_write)) {
        return false;
    }
    // RISC-V Privileged Spec: S-mode access to SATP raises illegal
    // instruction when mstatus.TVM = 1.
    if (csr == riscv.CSR.SATP and
        self.vcpu.privilege_mode == vcpu_mod.PRIV_SUPERVISOR and
        (self.vcpu.mstatus & riscv.MSTATUS.TVM) != 0)
    {
        return false;
    }
    return true;
}

pub inline fn handleCsrPostWrite(self: anytype, csr: u12) void {
    if (csr == riscv.CSR.SATP) {
        self.tlb.satp = self.vcpu.satp;
        self.tlb.flush();
    } else if (csr == riscv.CSR.SSTATUS or csr == riscv.CSR.MSTATUS) {
        const diff = self.tlb.mstatus ^ self.vcpu.mstatus;
        self.tlb.mstatus = self.vcpu.mstatus;
        if ((diff & riscv.MSTATUS.TRANSLATION_AFFECTING_MASK) != 0) {
            self.tlb.flush();
        }
    }
}

pub const CsrOp = enum { write, set, clear };

pub fn execCsr(
    self: anytype,
    pc_before: u32,
    csr: u12,
    rd: u5,
    src_val: u32,
    will_write: bool,
    op: CsrOp,
) bool {
    if (!isCsrAccessPermitted(self, csr, will_write)) {
        self.trap(2, pc_before, 0);
        return false;
    }
    const old = self.vcpu.readCsr(csr);
    if (will_write) {
        const new_val: u32 = switch (op) {
            .write => src_val,
            .set => old | src_val,
            .clear => old & ~src_val,
        };
        self.vcpu.writeCsr(csr, new_val);
        handleCsrPostWrite(self, csr);
    }
    if (rd != 0) self.vcpu.setGpr(rd, old);
    return true;
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

fn syncPrivChange(self: anytype, new_priv: u2) void {
    const mask: u32 = riscv.MSTATUS.TRANSLATION_AFFECTING_MASK;
    if (self.vcpu.privilege_mode != new_priv or
        self.tlb.satp != self.vcpu.satp or
        ((self.tlb.mstatus ^ self.vcpu.mstatus) & mask) != 0)
    {
        self.tlb.privilege_mode = new_priv;
        self.tlb.satp = self.vcpu.satp;
        self.tlb.mstatus = self.vcpu.mstatus;
        self.tlb.flush();
    } else {
        self.tlb.mstatus = self.vcpu.mstatus;
    }
    self.vcpu.privilege_mode = new_priv;
    self.vcpu.priv_mode = new_priv;
}

pub fn execSret(self: anytype, pc_before: u32) void {
    if (self.vcpu.privilege_mode < vcpu_mod.PRIV_SUPERVISOR or
        (self.vcpu.privilege_mode == vcpu_mod.PRIV_SUPERVISOR and
            (self.vcpu.mstatus & riscv.MSTATUS.TSR) != 0))
    {
        self.trap(2, pc_before, 0);
        return;
    }
    const spp = (self.vcpu.mstatus >> riscv.SSTATUS.SPP_SHIFT) & 1;
    const spie = (self.vcpu.mstatus >> 5) & 1;
    var mstatus = self.vcpu.mstatus;
    mstatus = (mstatus & ~@as(u32, 0x02)) | (spie << 1);
    mstatus |= (1 << 5);
    mstatus &= ~@as(u32, 1 << riscv.SSTATUS.SPP_SHIFT);
    self.vcpu.mstatus = mstatus;

    syncPrivChange(self, @truncate(spp));
    self.vcpu.scause = 0;
    self.vcpu.stval = 0;
    self.vcpu.pc = self.vcpu.sepc;
}

pub fn execMret(self: anytype, pc_before: u32) void {
    if (self.vcpu.privilege_mode < vcpu_mod.PRIV_MACHINE) {
        self.trap(2, pc_before, 0);
        return;
    }
    const mpp = (self.vcpu.mstatus >> riscv.MSTATUS.MPP_SHIFT) & 3;
    const mpie = (self.vcpu.mstatus >> 7) & 1;
    var mstatus = self.vcpu.mstatus;
    mstatus = (mstatus & ~@as(u32, 0x08)) | (mpie << 3);
    mstatus |= (1 << 7);
    mstatus &= ~@as(u32, riscv.MSTATUS.MPP_MASK);
    self.vcpu.mstatus = mstatus;

    syncPrivChange(self, @truncate(mpp));
    self.vcpu.pc = self.vcpu.mepc;
}

pub fn execFpLoad(
    self: anytype,
    pc_before: u32,
    d: decoder_rv32.LoadType,
    is_double: bool,
) bool {
    if (((self.vcpu.mstatus >> 13) & 3) == 0) {
        self.trap(2, pc_before, 0);
        return false;
    }
    const vaddr = u32Gpr(self, d.rs1) +% @as(u32, @bitCast(d.offset));
    const res_lo = self.tlb.readU32(vaddr, self.bus);
    if (res_lo.trap) |cause| {
        self.trap(cause, pc_before, vaddr);
        return false;
    }
    if (is_double) {
        const res_hi = self.tlb.readU32(vaddr +% 4, self.bus);
        if (res_hi.trap) |cause| {
            self.trap(cause, pc_before, vaddr +% 4);
            return false;
        }
        self.vcpu.fpregs[d.rd] = @as(u64, res_lo.val) |
            (@as(u64, res_hi.val) << 32);
    } else {
        self.vcpu.fpregs[d.rd] = 0xffff_ffff_0000_0000 | @as(u64, res_lo.val);
    }
    self.vcpu.mstatus |= (3 << 13);
    return true;
}

pub fn execFpStore(
    self: anytype,
    pc_before: u32,
    d: decoder_rv32.StoreType,
    is_double: bool,
) bool {
    if (((self.vcpu.mstatus >> 13) & 3) == 0) {
        self.trap(2, pc_before, 0);
        return false;
    }
    const vaddr = u32Gpr(self, d.rs1) +% @as(u32, @bitCast(d.offset));
    const val_lo = @as(u32, @truncate(self.vcpu.fpregs[d.rs2]));
    if (self.tlb.writeU32(vaddr, val_lo, self.bus)) |cause| {
        self.trap(cause, pc_before, vaddr);
        return false;
    }
    if (is_double) {
        const val_hi = @as(u32, @truncate(self.vcpu.fpregs[d.rs2] >> 32));
        if (self.tlb.writeU32(vaddr +% 4, val_hi, self.bus)) |cause| {
            self.trap(cause, pc_before, vaddr +% 4);
            return false;
        }
    }
    self.vcpu.mstatus |= (3 << 13);
    return true;
}

pub fn execVecMem(
    self: anytype,
    pc_before: u32,
    next_pc: u32,
    rs1: u5,
    vreg: u5,
    is_store: bool,
) void {
    if (((self.vcpu.mstatus >> 9) & 3) == 0) {
        self.trap(2, pc_before, 0);
        return;
    }
    const base_vaddr = u32Gpr(self, rs1);
    const count = @min(if (self.vcpu.vl == 0) 32 else self.vcpu.vl, 32);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (is_store) {
            const byte = self.vcpu.vregs[vreg][i];
            if (self.tlb.writeU8(base_vaddr +% i, byte, self.bus)) |cause| {
                self.trap(cause, pc_before, base_vaddr +% i);
                return;
            }
        } else {
            const res = self.tlb.readU8(base_vaddr +% i, self.bus);
            if (res.trap) |cause| {
                self.trap(cause, pc_before, base_vaddr +% i);
                return;
            }
            self.vcpu.vregs[vreg][i] = @truncate(res.val);
        }
    }
    self.vcpu.pc = next_pc;
}

test "checkCsrAccess privilege and read-only enforcement" {
    try std.testing.expect(!checkCsrAccess(0, 0x180, false));
    try std.testing.expect(checkCsrAccess(1, 0x180, true));
    try std.testing.expect(!checkCsrAccess(3, 0xc00, true));
    try std.testing.expect(checkCsrAccess(0, 0xc00, false));
}
