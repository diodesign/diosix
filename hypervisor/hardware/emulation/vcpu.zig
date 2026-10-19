// Virtual CPU Context & CSR State for Diosix Non-Native Emulated Guests
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const riscv = @import("interface").riscv;
const reservation = @import("reservation.zig");

pub inline fn readHostTime() u64 {
    var host_time: u64 = 0;
    if (comptime builtin.target.cpu.arch.isRISCV()) {
        asm volatile ("rdtime %[host_time]"
            : [host_time] "=r" (host_time),
        );
    }
    return host_time;
}

/// Privilege levels for virtual CPU.
pub const PrivilegeMode = enum(u2) {
    user = riscv.PRIV_USER,
    supervisor = riscv.PRIV_SUPERVISOR,
    machine = riscv.PRIV_MACHINE,
};

pub const PRIV_USER: u2 = riscv.PRIV_USER;
pub const PRIV_SUPERVISOR: u2 = riscv.PRIV_SUPERVISOR;
pub const PRIV_MACHINE: u2 = riscv.PRIV_MACHINE;

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
pub const SIP_WRITABLE_MASK: u32 = @truncate(
    riscv.MIP.SSIP | riscv.MIP.STIP | riscv.MIP.SEIP,
);
pub const MIP_STIP_U32: u32 = @truncate(riscv.MIP.STIP);
pub const TVEC_MODE_MASK: u32 = 0x3;
pub const TVEC_MODE_VECTORED: u32 = 1;
pub const DELEGATE_ALL_MASK: u32 = 0xffff;
pub const INITIAL_GUEST_INSN_TIME: u64 = 10_000_000;
pub const TIMER_INFINITY: u64 = std.math.maxInt(u64);
pub const LOW_WORD_MASK: u64 = 0x0000_0000_ffff_ffff;
pub const HIGH_WORD_MASK: u64 = 0xffff_ffff_0000_0000;
pub const HIGH_WORD_SHIFT: u6 = 32;

/// Virtual CPU State.
pub const VCpu = extern struct {
    /// Guest general purpose registers x0-x31 -> offset 0..256.
    regs: [32]u64 = std.mem.zeroes([32]u64),
    /// Guest program counter -> offset 256..260.
    pc: u32 = 0,
    _pad0: u32 = 0,
    id: u64 = 0, // offset 264..272.
    tlb_entries_ptr: u64 = 0, // offset 272..280.
    host_sp: u64 = 0, // offset 280..288.
    scratch_t1: u64 = 0, // offset 288..296.
    scratch_t2: u64 = 0, // offset 296..304.
    privilege_mode: u8 = PRIV_MACHINE,
    _pad1: u8 = 0,
    _pad2: u16 = 0,
    _pad4: u32 = 0,
    time: u64 = 0,
    running: bool = true,
    _pad5: u8 = 0,
    _pad6: u16 = 0,
    last_sepc_when_stvec_zero: u32 = 0,
    vregs: [32][32]u8 = std.mem.zeroes([32][32]u8),
    vl: u32 = 32,
    fpregs: [32]u64 = std.mem.zeroes([32]u64),
    fcsr: u32 = 0,

    // Machine-mode CSRs.
    mstatus: u32 = 0,
    misa: u32 = DEFAULT_MISA_RV32,
    medeleg: u32 = DELEGATE_ALL_MASK,
    mideleg: u32 = DELEGATE_ALL_MASK,
    mie: u32 = 0,
    mtvec: u32 = 0,
    mscratch: u32 = 0,
    mepc: u32 = 0,
    mcause: u32 = 0,
    mtval: u32 = 0,
    mip: u32 = 0,

    // Supervisor-mode CSRs.
    stvec: u32 = 0,
    sscratch: u32 = 0,
    sepc: u32 = 0,
    scause: u32 = 0,
    stval: u32 = 0,
    satp: u32 = 0,
    sie: u32 = 0,
    _pad7: u32 = 0,
    vstimecmp: u64 = TIMER_INFINITY,
    load_res_addr: u64 = 0,
    load_res_val: u32 = 0,
    needs_tlb_flush_flag: bool = false,
    needs_cache_flush_flag: bool = false,
    _pad8: u16 = 0,
    softtlb: extern struct { privilege_mode: u8 = PRIV_SUPERVISOR } = .{},

    pub const STATIC_RESERVATION_HARTS = reservation.STATIC_RESERVATION_HARTS;
    pub const DynamicReservationNode = reservation.DynamicReservationNode;
    pub const ReservationRow = reservation.ReservationRow;
    pub const setReservation = reservation.setReservation;
    pub const checkAndClearReservation = reservation.checkAndClearReservation;
    pub const clearReservation = reservation.clearReservation;
    pub const invalidateReservations = reservation.invalidateReservations;
    pub const resetReservations = reservation.resetReservations;

    pub fn setNeedsTlbFlush(self: *VCpu) void {
        @atomicStore(bool, &self.needs_tlb_flush_flag, true, .release);
    }

    pub fn checkAndClearTlbFlush(self: *VCpu) bool {
        return @atomicRmw(
            bool,
            &self.needs_tlb_flush_flag,
            .Xchg,
            false,
            .acquire,
        );
    }

    pub fn setNeedsCacheFlush(self: *VCpu) void {
        @atomicStore(bool, &self.needs_cache_flush_flag, true, .release);
    }

    pub fn checkAndClearCacheFlush(self: *VCpu) bool {
        return @atomicRmw(
            bool,
            &self.needs_cache_flush_flag,
            .Xchg,
            false,
            .acquire,
        );
    }

    pub fn getGpr(self: *const VCpu, reg: u5) u64 {
        if (reg == 0) return 0;
        const raw_i64: i64 = @bitCast(self.regs[reg]);
        const sext_i64: i64 = @as(i32, @truncate(raw_i64));
        return @bitCast(sext_i64);
    }

    pub fn getReg(self: *const VCpu, reg: u5) u64 {
        return self.getGpr(reg);
    }

    pub fn setGpr(self: *VCpu, reg: u5, val: u64) void {
        if (reg == 0) return;
        const raw_i64: i64 = @bitCast(val);
        const sext_i64: i64 = @as(i32, @truncate(raw_i64));
        self.regs[reg] = @bitCast(sext_i64);
    }

    pub fn setReg(self: *VCpu, reg: u5, val: u64) void {
        self.setGpr(reg, val);
    }

    comptime {
        std.debug.assert(@offsetOf(VCpu, "regs") == 0);
        std.debug.assert(@offsetOf(VCpu, "pc") == 256);
        std.debug.assert(@offsetOf(VCpu, "host_sp") == 280);
        std.debug.assert(@offsetOf(VCpu, "scratch_t1") == 288);
        std.debug.assert(SSTATUS_WRITABLE_MASK == 0x800de762);
    }

    pub var time_offset = std.atomic.Value(u64).init(0);
    pub var max_guest_time = std.atomic.Value(u64).init(0);
    pub var guest_insn_time =
        std.atomic.Value(u64).init(INITIAL_GUEST_INSN_TIME);

    pub fn setMipBit(self: *VCpu, bit: u5) void {
        _ = @atomicRmw(u32, &self.mip, .Or, @as(u32, 1) << bit, .seq_cst);
    }

    pub fn clearMipBit(self: *VCpu, bit: u5) void {
        _ = @atomicRmw(u32, &self.mip, .And, ~(@as(u32, 1) << bit), .seq_cst);
    }

    pub fn getMip(self: *const VCpu) u32 {
        var m = @atomicLoad(u32, &self.mip, .seq_cst);
        const now = readGuestTime();
        if (self.vstimecmp != TIMER_INFINITY and now >= self.vstimecmp) {
            m |= MIP_STIP_U32;
        }
        return m;
    }

    pub fn readGuestTime() u64 {
        const now = readHostTime();
        const offset = time_offset.load(.monotonic);
        return if (now >= offset) now - offset else 0;
    }

    fn computeEffectiveMip(self: *const VCpu) u32 {
        const now = readGuestTime();
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
            riscv.CSR.MSTATUS => self.maskFpIfDisabled(self.mstatus),
            riscv.CSR.MISA => self.misa,
            riscv.CSR.MEDELEG => self.medeleg,
            riscv.CSR.MIDELEG => self.mideleg,
            riscv.CSR.MIE => self.mie,
            riscv.CSR.MTVEC => self.mtvec,
            riscv.CSR.MSCRATCH => self.mscratch,
            riscv.CSR.MEPC => self.mepc,
            riscv.CSR.MCAUSE => self.mcause,
            riscv.CSR.MTVAL => self.mtval,
            riscv.CSR.MIP => self.computeEffectiveMip(),

            riscv.CSR.SSTATUS => self.maskFpIfDisabled(
                self.mstatus & SSTATUS_WRITABLE_MASK,
            ),
            riscv.CSR.SIE => self.mie & self.mideleg,
            riscv.CSR.STVEC => self.stvec,
            riscv.CSR.SSCRATCH => self.sscratch,
            riscv.CSR.SEPC => self.sepc,
            riscv.CSR.SCAUSE => self.scause,
            riscv.CSR.STVAL => self.stval,
            riscv.CSR.SIP => self.computeEffectiveMip() & self.mideleg,
            riscv.CSR.SATP => self.satp,

            riscv.CSR.FFLAGS => self.fcsr & FCSR_FFLAGS_MASK,
            riscv.CSR.FRM => (self.fcsr >> FCSR_FRM_SHIFT) & FCSR_FRM_MASK,
            riscv.CSR.FCSR => self.fcsr & FCSR_MASK,

            riscv.CSR.STIMECMP => @truncate(self.vstimecmp),
            riscv.CSR.STIMECMPH => @truncate(self.vstimecmp >> HIGH_WORD_SHIFT),

            riscv.CSR.CYCLE,
            riscv.CSR.TIME,
            riscv.CSR.INSTRET,
            => @truncate(readGuestTime()),
            riscv.CSR.CYCLEH,
            riscv.CSR.TIMEH,
            riscv.CSR.INSTRETH,
            => @truncate(readGuestTime() >> HIGH_WORD_SHIFT),

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

            riscv.CSR.MSTATUS => self.mstatus = self.maskFpIfDisabled(val),
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
                const mask = self.maskFpIfDisabled(SSTATUS_WRITABLE_MASK);
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
                const prev = @atomicLoad(u32, &self.mip, .seq_cst);
                @atomicStore(
                    u32,
                    &self.mip,
                    (prev & ~mask) | (val & mask),
                    .seq_cst,
                );
            },
            riscv.CSR.SATP => self.satp = val,

            riscv.CSR.STIMECMP => {
                self.vstimecmp = (self.vstimecmp & HIGH_WORD_MASK) | val;
            },
            riscv.CSR.STIMECMPH => {
                self.vstimecmp = (self.vstimecmp & LOW_WORD_MASK) |
                    (@as(u64, val) << HIGH_WORD_SHIFT);
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
        clearReservation(@intCast(self.id));
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
};

test "VCpu GPR sign-extension, CSR delegation, and exception injection" {
    const testing = std.testing;
    testing.refAllDecls(@This());
    _ = reservation;

    var cpu = VCpu{};

    // x0 is hardwired to 0.
    cpu.setGpr(0, 0x12345678);
    try testing.expectEqual(@as(u64, 0), cpu.getGpr(0));

    // RV32 values with bit 31 set are sign-extended to 64 bits.
    cpu.setGpr(5, 0x80000001);
    try testing.expectEqual(@as(u64, 0xffffffff80000001), cpu.getGpr(5));

    // Delegated page fault from U-mode enters S-mode at stvec.
    cpu.privilege_mode = PRIV_USER;
    cpu.medeleg = DELEGATE_ALL_MASK;
    cpu.stvec = 0x80001000;
    const load_pf = @backingInt(riscv.Cause.load_page_fault);
    cpu.injectException(load_pf, 0x10002000, 0xdeadbeef);
    try testing.expectEqual(@as(u8, PRIV_SUPERVISOR), cpu.privilege_mode);
    try testing.expectEqual(@as(u32, 0x80001000), cpu.pc);
    try testing.expectEqual(@as(u32, 0x10002000), cpu.sepc);
    try testing.expectEqual(@as(u32, load_pf), cpu.scause);
    try testing.expectEqual(@as(u32, 0xdeadbeef), cpu.stval);
}
