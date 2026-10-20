// Virtual CPU Control and Status Register (CSR) & Exception Injection Logic
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("interface").riscv;
const bus_mod = @import("../devices/bus.zig");
const vcpu_mod = @import("../vcpu.zig");

const VCpu = vcpu_mod.VCpu;
const PRIV_USER = vcpu_mod.PRIV_USER;
const PRIV_SUPERVISOR = vcpu_mod.PRIV_SUPERVISOR;
const PRIV_MACHINE = vcpu_mod.PRIV_MACHINE;

/// Default RV32IMAFDC misa encoding.
pub const DEFAULT_MISA_RV32: u32 =
    riscv.IsaExtension.MXL_32 | @as(u32, @truncate(riscv.IsaExtension.gc));

pub const MISA_FD_MASK: u32 = @truncate(
    riscv.IsaExtension.f | riscv.IsaExtension.d,
);
pub const MSTATUS_VS_MASK_U32: u32 = @truncate(riscv.MSTATUS.VS_MASK);
pub const MSTATUS_FS_MASK_U32: u32 = @truncate(riscv.MSTATUS.FS_MASK);
pub const MSTATUS_FS_DIRTY_U32: u32 = @truncate(riscv.MSTATUS.FS_DIRTY);
pub const MSTATUS_UBE_U32: u32 = 1 << 6;
pub const MSTATUS_XS_MASK_U32: u32 = 0b11 << 15;
pub const SSTATUS_WRITABLE_MASK: u32 = @as(
    u32,
    @truncate(
        riscv.MSTATUS.SIE |
            riscv.MSTATUS.SPIE |
            riscv.MSTATUS.SPP |
            riscv.MSTATUS.VS_MASK |
            riscv.MSTATUS.FS_MASK |
            riscv.MSTATUS.SUM |
            riscv.MSTATUS.MXR,
    ),
) | MSTATUS_UBE_U32 | MSTATUS_XS_MASK_U32 | riscv.MSTATUS.SD_RV32;

pub const CAUSE_INTERRUPT_RV32: u32 = 0x8000_0000;
pub const CAUSE_CODE_MASK_RV32: u32 = 0x7fff_ffff;
pub const FCSR_FFLAGS_MASK: u32 = 0x1f;
pub const FCSR_FRM_SHIFT: u5 = 5;
pub const FCSR_FRM_MASK: u32 = 0x7;
pub const FCSR_FRM_FIELD_MASK: u32 = FCSR_FRM_MASK << FCSR_FRM_SHIFT;
pub const FCSR_MASK: u32 = 0xff;
pub const SIP_WRITABLE_MASK: u32 = @truncate(riscv.MIP.SSIP);
pub const MIP_STIP_U32: u32 = @truncate(riscv.MIP.STIP);
pub const TVEC_MODE_MASK: u32 = 0x3;
pub const TVEC_MODE_VECTORED: u32 = 1;
pub const DELEGATE_ALL_MASK: u32 = 0xffff;
pub const TIMER_INFINITY: u64 = std.math.maxInt(u64);
pub const HIGH_WORD_SHIFT: u6 = bus_mod.HIGH_WORD_SHIFT;

fn computeEffectiveMip(self: *const VCpu) u32 {
    const now = VCpu.readGuestTime();
    var m = @atomicLoad(u32, &self.mip, .seq_cst);
    if (self.vstimecmp != TIMER_INFINITY and now >= self.vstimecmp) {
        m |= MIP_STIP_U32;
    } else if (self.vstimecmp != TIMER_INFINITY) {
        m &= ~MIP_STIP_U32;
    }
    return m;
}

fn maskFpIfDisabled(self: *const VCpu, val: u32) u32 {
    return if ((self.misa & MISA_FD_MASK) == 0)
        val & ~MSTATUS_FS_MASK_U32
    else
        val;
}

pub fn readCsr(self: *VCpu, csr: u12) u32 {
    return switch (csr) {
        riscv.CSR.MSTATUS => maskFpIfDisabled(self, self.mstatus),
        riscv.CSR.MISA => self.misa,
        riscv.CSR.MEDELEG => self.medeleg,
        riscv.CSR.MIDELEG => self.mideleg,
        riscv.CSR.MIE => self.mie,
        riscv.CSR.MTVEC => self.mtvec,
        riscv.CSR.MSCRATCH => self.mscratch,
        riscv.CSR.MEPC => self.mepc,
        riscv.CSR.MCAUSE => self.mcause,
        riscv.CSR.MTVAL => self.mtval,
        riscv.CSR.MIP => computeEffectiveMip(self),

        riscv.CSR.SSTATUS => maskFpIfDisabled(
            self,
            self.mstatus & SSTATUS_WRITABLE_MASK,
        ),
        riscv.CSR.SIE => self.mie & self.mideleg,
        riscv.CSR.STVEC => self.stvec,
        riscv.CSR.SSCRATCH => self.sscratch,
        riscv.CSR.SEPC => self.sepc,
        riscv.CSR.SCAUSE => self.scause,
        riscv.CSR.STVAL => self.stval,
        riscv.CSR.SIP => computeEffectiveMip(self) & self.mideleg,
        riscv.CSR.SATP => self.satp,

        riscv.CSR.FFLAGS => self.fcsr & FCSR_FFLAGS_MASK,
        riscv.CSR.FRM => (self.fcsr >> FCSR_FRM_SHIFT) & FCSR_FRM_MASK,
        riscv.CSR.FCSR => self.fcsr & FCSR_MASK,

        riscv.CSR.STIMECMP => @truncate(self.vstimecmp),
        riscv.CSR.STIMECMPH => @truncate(self.vstimecmp >> HIGH_WORD_SHIFT),

        riscv.CSR.CYCLE,
        riscv.CSR.TIME,
        riscv.CSR.INSTRET,
        => @truncate(VCpu.readGuestTime()),
        riscv.CSR.CYCLEH,
        riscv.CSR.TIMEH,
        riscv.CSR.INSTRETH,
        => @truncate(VCpu.readGuestTime() >> HIGH_WORD_SHIFT),

        riscv.CSR.MVENDORID,
        riscv.CSR.MARCHID,
        riscv.CSR.MIMPID,
        => 0,
        riscv.CSR.MHARTID => @truncate(self.id),

        else => 0,
    };
}

pub fn writeCsr(self: *VCpu, csr: u12, val: u32) void {
    switch (csr) {
        riscv.CSR.FFLAGS => {
            self.fcsr = (self.fcsr & ~FCSR_FFLAGS_MASK) |
                (val & FCSR_FFLAGS_MASK);
            self.mstatus |= MSTATUS_FS_DIRTY_U32;
        },
        riscv.CSR.FRM => {
            self.fcsr = (self.fcsr & ~FCSR_FRM_FIELD_MASK) |
                ((val & FCSR_FRM_MASK) << FCSR_FRM_SHIFT);
            self.mstatus |= MSTATUS_FS_DIRTY_U32;
        },
        riscv.CSR.FCSR => {
            self.fcsr = val & FCSR_MASK;
            self.mstatus |= MSTATUS_FS_DIRTY_U32;
        },

        riscv.CSR.MSTATUS => self.mstatus = maskFpIfDisabled(self, val),
        riscv.CSR.MEDELEG => self.medeleg = val,
        riscv.CSR.MIDELEG => {
            self.mideleg = val;
            self.sie = self.mie & val;
        },
        riscv.CSR.MIE => {
            self.mie = val;
            self.sie = val & self.mideleg;
        },
        riscv.CSR.MTVEC => self.mtvec = val,
        riscv.CSR.MSCRATCH => self.mscratch = val,
        riscv.CSR.MEPC => self.mepc = val,
        riscv.CSR.MCAUSE => self.mcause = val,
        riscv.CSR.MTVAL => self.mtval = val,
        riscv.CSR.MIP => @atomicStore(u32, &self.mip, val, .seq_cst),

        riscv.CSR.SSTATUS => {
            const mask = maskFpIfDisabled(self, SSTATUS_WRITABLE_MASK);
            self.mstatus = (self.mstatus & ~mask) | (val & mask);
        },
        riscv.CSR.SIE => {
            self.mie = (self.mie & ~self.mideleg) | (val & self.mideleg);
            self.sie = self.mie & self.mideleg;
        },
        riscv.CSR.STVEC => self.stvec = val,
        riscv.CSR.SSCRATCH => self.sscratch = val,
        riscv.CSR.SEPC => self.sepc = val,
        riscv.CSR.SCAUSE => self.scause = val,
        riscv.CSR.STVAL => self.stval = val,
        riscv.CSR.SIP => {
            const mask = self.mideleg & SIP_WRITABLE_MASK;
            if ((val & mask) != 0) {
                _ = @atomicRmw(u32, &self.mip, .Or, val & mask, .seq_cst);
            }
            if ((~val & mask) != 0) {
                _ = @atomicRmw(u32, &self.mip, .And, ~(~val & mask), .seq_cst);
            }
        },
        riscv.CSR.SATP => self.satp = val,

        riscv.CSR.STIMECMP => {
            self.vstimecmp = bus_mod.setLow32(self.vstimecmp, val);
        },
        riscv.CSR.STIMECMPH => {
            self.vstimecmp = bus_mod.setHigh32(self.vstimecmp, val);
        },

        else => {},
    }
}

pub fn injectException(
    self: *VCpu,
    cause: u32,
    fault_pc: u32,
    stval: u32,
) void {
    VCpu.clearReservation(@intCast(self.id));
    self.load_res_addr = 0;
    const is_interrupt = (cause & CAUSE_INTERRUPT_RV32) != 0;
    const code = cause & CAUSE_CODE_MASK_RV32;
    const delegate_to_s =
        if (self.privilege_mode < PRIV_MACHINE and code < 32) blk: {
            const bit = @as(u32, 1) << @truncate(code);
            break :blk if (is_interrupt)
                (self.mideleg & bit) != 0
            else
                (self.medeleg & bit) != 0;
        } else false;

    if (delegate_to_s) {
        self.sepc = fault_pc;
        self.scause = cause;
        self.stval = stval;
        if (self.stvec == 0) {
            self.last_sepc_when_stvec_zero = fault_pc;
        }

        const sie_active =
            (self.mstatus & @as(u32, @truncate(riscv.MSTATUS.SIE))) != 0;
        const s_clear: u32 = @truncate(
            riscv.MSTATUS.SPP | riscv.MSTATUS.SPIE | riscv.MSTATUS.SIE,
        );
        var mstatus = self.mstatus & ~s_clear;
        mstatus |= (@as(u32, self.privilege_mode & 1) <<
            riscv.SSTATUS.SPP_SHIFT);
        if (sie_active) mstatus |= @truncate(riscv.MSTATUS.SPIE);
        self.mstatus = mstatus;

        self.privilege_mode = PRIV_SUPERVISOR;
        self.softtlb.privilege_mode = PRIV_SUPERVISOR;

        const mode = self.stvec & TVEC_MODE_MASK;
        const base = self.stvec & ~TVEC_MODE_MASK;
        self.pc = if (is_interrupt and mode == TVEC_MODE_VECTORED)
            base +% (4 *% code)
        else
            base;
    } else {
        self.mepc = fault_pc;
        self.mcause = cause;
        self.mtval = stval;

        const mie_active =
            (self.mstatus & @as(u32, @truncate(riscv.MSTATUS.MIE))) != 0;
        const m_clear: u32 = @truncate(
            riscv.MSTATUS.MPP_MASK | riscv.MSTATUS.MPIE | riscv.MSTATUS.MIE,
        );
        var mstatus = self.mstatus & ~m_clear;
        mstatus |= (@as(u32, self.privilege_mode & PRIV_MACHINE) <<
            riscv.MSTATUS.MPP_SHIFT);
        if (mie_active) mstatus |= @truncate(riscv.MSTATUS.MPIE);
        self.mstatus = mstatus;

        self.privilege_mode = PRIV_MACHINE;
        self.softtlb.privilege_mode = PRIV_MACHINE;

        const mode = self.mtvec & TVEC_MODE_MASK;
        const base = self.mtvec & ~TVEC_MODE_MASK;
        self.pc = if (is_interrupt and mode == TVEC_MODE_VECTORED)
            base +% (4 *% code)
        else
            base;
    }
}

test "VCpu CSR SIP write restriction to SSIP and STIMECMP access" {
    const testing = std.testing;
    testing.refAllDecls(@This());

    var cpu = VCpu{};
    cpu.mideleg = DELEGATE_ALL_MASK;
    cpu.writeCsr(riscv.CSR.MIP, @truncate(riscv.MIP.SEIP));

    // Writing SIP with SSIP | STIP | SEIP only modifies SSIP, preserving SEIP.
    cpu.writeCsr(
        riscv.CSR.SIP,
        @truncate(riscv.MIP.SSIP | riscv.MIP.STIP),
    );
    const mip_after_set = @atomicLoad(u32, &cpu.mip, .seq_cst);
    try testing.expectEqual(
        @as(u32, @truncate(riscv.MIP.SSIP | riscv.MIP.SEIP)),
        mip_after_set,
    );

    cpu.writeCsr(riscv.CSR.SIP, 0);
    const mip_after_clear = @atomicLoad(u32, &cpu.mip, .seq_cst);
    try testing.expectEqual(
        @as(u32, @truncate(riscv.MIP.SEIP)),
        mip_after_clear,
    );

    cpu.writeCsr(riscv.CSR.STIMECMP, 0x1234_5678);
    cpu.writeCsr(riscv.CSR.STIMECMPH, 0x9abc_def0);
    try testing.expectEqual(@as(u64, 0x9abc_def0_1234_5678), cpu.vstimecmp);
}
