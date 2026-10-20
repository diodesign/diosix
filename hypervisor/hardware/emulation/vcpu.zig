// Virtual CPU Context & CSR State for Diosix Non-Native Emulated Guests
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const riscv = @import("interface").riscv;
const reservation = @import("reservation.zig");
const csr_mod = @import("vcpu/csr.zig");

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

pub const GPR_COUNT: usize = 32;
pub const FPREG_COUNT: usize = 32;
pub const VREG_COUNT: usize = 32;
pub const VREG_BYTES: usize = 32;

pub const DEFAULT_MISA_RV32 = csr_mod.DEFAULT_MISA_RV32;
pub const MISA_FD_MASK = csr_mod.MISA_FD_MASK;
pub const MSTATUS_VS_MASK_U32 = csr_mod.MSTATUS_VS_MASK_U32;
pub const MSTATUS_FS_MASK_U32 = csr_mod.MSTATUS_FS_MASK_U32;
pub const MSTATUS_FS_DIRTY_U32 = csr_mod.MSTATUS_FS_DIRTY_U32;
pub const MSTATUS_UBE_U32 = csr_mod.MSTATUS_UBE_U32;
pub const MSTATUS_XS_MASK_U32 = csr_mod.MSTATUS_XS_MASK_U32;
pub const SSTATUS_WRITABLE_MASK = csr_mod.SSTATUS_WRITABLE_MASK;

pub const CAUSE_INTERRUPT_RV32 = csr_mod.CAUSE_INTERRUPT_RV32;
pub const CAUSE_CODE_MASK_RV32 = csr_mod.CAUSE_CODE_MASK_RV32;
pub const FCSR_FFLAGS_MASK = csr_mod.FCSR_FFLAGS_MASK;
pub const FCSR_FRM_SHIFT = csr_mod.FCSR_FRM_SHIFT;
pub const FCSR_FRM_MASK = csr_mod.FCSR_FRM_MASK;
pub const FCSR_FRM_FIELD_MASK = csr_mod.FCSR_FRM_FIELD_MASK;
pub const FCSR_MASK = csr_mod.FCSR_MASK;
pub const SIP_WRITABLE_MASK = csr_mod.SIP_WRITABLE_MASK;
pub const MIP_STIP_U32 = csr_mod.MIP_STIP_U32;
pub const TVEC_MODE_MASK = csr_mod.TVEC_MODE_MASK;
pub const TVEC_MODE_VECTORED = csr_mod.TVEC_MODE_VECTORED;
pub const DELEGATE_ALL_MASK = csr_mod.DELEGATE_ALL_MASK;
pub const INITIAL_GUEST_INSN_TIME: u64 = 10_000_000;
pub const TIMER_INFINITY = csr_mod.TIMER_INFINITY;
pub const HIGH_WORD_SHIFT = csr_mod.HIGH_WORD_SHIFT;

/// Virtual CPU State.
pub const VCpu = extern struct {
    /// Guest general purpose registers x0-x31 -> offset 0..256.
    regs: [GPR_COUNT]u64 = std.mem.zeroes([GPR_COUNT]u64),
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
    vregs: [VREG_COUNT][VREG_BYTES]u8 =
        std.mem.zeroes([VREG_COUNT][VREG_BYTES]u8),
    vl: u32 = VREG_BYTES,
    fpregs: [FPREG_COUNT]u64 = std.mem.zeroes([FPREG_COUNT]u64),
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
        std.debug.assert(@offsetOf(VCpu, "tlb_entries_ptr") == 272);
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

    pub const readCsr = csr_mod.readCsr;
    pub const writeCsr = csr_mod.writeCsr;
    pub const injectException = csr_mod.injectException;
};

test "VCpu GPR sign-extension, CSR delegation, and exception injection" {
    const testing = std.testing;
    testing.refAllDecls(@This());
    _ = reservation;
    _ = csr_mod;

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
