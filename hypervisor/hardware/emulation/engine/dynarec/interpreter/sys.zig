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
const mem = @import("mem.zig");
const riscv = @import("interface").riscv;

pub const u32Gpr = mem.u32Gpr;
pub const i32Gpr = mem.i32Gpr;
pub const execAmo = mem.execAmo;

pub const VREG_BYTES: u32 = 32;
pub const CSR_PRIV_SHIFT: u4 = 8;
pub const CSR_PRIV_MASK: u12 = 0x3;
pub const CSR_ACCESS_SHIFT: u4 = 10;
pub const CSR_ACCESS_READ_ONLY: u12 = 0x3;
pub const NAN_BOX_F32_PREFIX: u64 = 0xffff_ffff_0000_0000;
pub const WORD_BITS: u6 = 32;

fn checkCsrAccess(priv: u8, csr: u12, will_write: bool) bool {
    const min_priv: u8 = @truncate((csr >> CSR_PRIV_SHIFT) & CSR_PRIV_MASK);
    if (priv < min_priv) return false;
    const is_ro = ((csr >> CSR_ACCESS_SHIFT) & CSR_PRIV_MASK) ==
        CSR_ACCESS_READ_ONLY;
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
    if (csr == riscv.CSR.SATP or
        csr == riscv.CSR.SSTATUS or
        csr == riscv.CSR.MSTATUS)
    {
        self.tlb.syncCpuState(
            self.vcpu.satp,
            self.vcpu.privilege_mode,
            self.vcpu.mstatus,
        );
    }
}

pub const CAUSE_ILLEGAL_INSN: u32 =
    @backingInt(riscv.Cause.illegal_instruction);
pub const CAUSE_BREAKPOINT: u32 = @backingInt(riscv.Cause.breakpoint);
pub const CAUSE_USER_ECALL: u32 =
    @backingInt(riscv.Cause.user_environment_call);
pub const CAUSE_SUPERVISOR_ECALL: u32 =
    @backingInt(riscv.Cause.supervisor_environment_call);
pub const CAUSE_MACHINE_ECALL: u32 =
    @backingInt(riscv.Cause.machine_environment_call);

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
        self.trap(CAUSE_ILLEGAL_INSN, pc_before, 0);
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

fn syncPrivChange(self: anytype, new_priv: u2) void {
    if (self.vcpu.privilege_mode != new_priv) {
        self.tlb.privilege_mode = self.vcpu.privilege_mode;
    }
    self.tlb.syncCpuState(self.vcpu.satp, new_priv, self.vcpu.mstatus);
    self.vcpu.privilege_mode = new_priv;
}

pub fn execSret(self: anytype, pc_before: u32) void {
    if (self.vcpu.privilege_mode < vcpu_mod.PRIV_SUPERVISOR or
        (self.vcpu.privilege_mode == vcpu_mod.PRIV_SUPERVISOR and
            (self.vcpu.mstatus & riscv.MSTATUS.TSR) != 0))
    {
        self.trap(CAUSE_ILLEGAL_INSN, pc_before, 0);
        return;
    }
    const spp = (self.vcpu.mstatus >> riscv.SSTATUS.SPP_SHIFT) & 1;
    const spie_set =
        (self.vcpu.mstatus & @as(u32, @truncate(riscv.MSTATUS.SPIE))) != 0;
    var mstatus = self.vcpu.mstatus &
        ~@as(u32, @truncate(riscv.MSTATUS.SIE | riscv.MSTATUS.SPP));
    if (spie_set) mstatus |= @truncate(riscv.MSTATUS.SIE);
    mstatus |= @truncate(riscv.MSTATUS.SPIE);
    self.vcpu.mstatus = mstatus;

    syncPrivChange(self, @truncate(spp));
    self.vcpu.scause = 0;
    self.vcpu.stval = 0;
    self.vcpu.pc = self.vcpu.sepc;
}

pub fn execMret(self: anytype, pc_before: u32) void {
    if (self.vcpu.privilege_mode < vcpu_mod.PRIV_MACHINE) {
        self.trap(CAUSE_ILLEGAL_INSN, pc_before, 0);
        return;
    }
    const mpp = (self.vcpu.mstatus >> riscv.MSTATUS.MPP_SHIFT) &
        vcpu_mod.PRIV_MACHINE;
    const mpie_set =
        (self.vcpu.mstatus & @as(u32, @truncate(riscv.MSTATUS.MPIE))) != 0;
    var mstatus = self.vcpu.mstatus &
        ~@as(u32, @truncate(riscv.MSTATUS.MIE | riscv.MSTATUS.MPP_MASK));
    if (mpie_set) mstatus |= @truncate(riscv.MSTATUS.MIE);
    mstatus |= @truncate(riscv.MSTATUS.MPIE);
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
    if ((self.vcpu.mstatus & vcpu_mod.MSTATUS_FS_MASK_U32) == 0) {
        self.trap(CAUSE_ILLEGAL_INSN, pc_before, 0);
        return false;
    }
    const vaddr = u32Gpr(self, d.rs1) +% @as(u32, @bitCast(d.offset));
    const res_lo = self.tlb.readU32(vaddr, self.bus);
    if (res_lo.trap) |cause| {
        self.trap(cause, pc_before, vaddr);
        return false;
    }
    if (is_double) {
        const res_hi = self.tlb.readU32(vaddr +% @sizeOf(u32), self.bus);
        if (res_hi.trap) |cause| {
            self.trap(cause, pc_before, vaddr +% @sizeOf(u32));
            return false;
        }
        self.vcpu.fpregs[d.rd] = @as(u64, res_lo.val) |
            (@as(u64, res_hi.val) << WORD_BITS);
    } else {
        self.vcpu.fpregs[d.rd] = NAN_BOX_F32_PREFIX | @as(u64, res_lo.val);
    }
    self.vcpu.mstatus |= vcpu_mod.MSTATUS_FS_DIRTY_U32;
    return true;
}

pub fn execFpStore(
    self: anytype,
    pc_before: u32,
    d: decoder_rv32.StoreType,
    is_double: bool,
) bool {
    if ((self.vcpu.mstatus & vcpu_mod.MSTATUS_FS_MASK_U32) == 0) {
        self.trap(CAUSE_ILLEGAL_INSN, pc_before, 0);
        return false;
    }
    const vaddr = u32Gpr(self, d.rs1) +% @as(u32, @bitCast(d.offset));
    const val_lo = @as(u32, @truncate(self.vcpu.fpregs[d.rs2]));
    if (self.tlb.writeU32(vaddr, val_lo, self.bus)) |cause| {
        self.trap(cause, pc_before, vaddr);
        return false;
    }
    if (is_double) {
        const val_hi =
            @as(u32, @truncate(self.vcpu.fpregs[d.rs2] >> WORD_BITS));
        if (self.tlb.writeU32(
            vaddr +% @sizeOf(u32),
            val_hi,
            self.bus,
        )) |cause| {
            self.trap(cause, pc_before, vaddr +% @sizeOf(u32));
            return false;
        }
    }
    self.vcpu.mstatus |= vcpu_mod.MSTATUS_FS_DIRTY_U32;
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
    if ((self.vcpu.mstatus & vcpu_mod.MSTATUS_VS_MASK_U32) == 0) {
        self.trap(CAUSE_ILLEGAL_INSN, pc_before, 0);
        return;
    }
    const base_vaddr = u32Gpr(self, rs1);
    const count: u32 = @min(
        if (self.vcpu.vl == 0) VREG_BYTES else self.vcpu.vl,
        VREG_BYTES,
    );
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
    std.testing.refAllDecls(@This());
    try std.testing.expect(
        !checkCsrAccess(riscv.PRIV_USER, riscv.CSR.SATP, false),
    );
    try std.testing.expect(
        checkCsrAccess(riscv.PRIV_SUPERVISOR, riscv.CSR.SATP, true),
    );
    try std.testing.expect(
        !checkCsrAccess(riscv.PRIV_MACHINE, riscv.CSR.CYCLE, true),
    );
    try std.testing.expect(
        checkCsrAccess(riscv.PRIV_USER, riscv.CSR.CYCLE, false),
    );
}
