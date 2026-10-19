// Virtual CPU Context & CSR State for Diosix Non-Native Emulated Guests
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
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
    user = 0,
    supervisor = 1,
    machine = 3,
};

/// CSR Addresses for RISC-V 32-bit CPU.
pub const CsrAddr = struct {
    pub const mstatus: u12 = 0x300;
    pub const misa: u12 = 0x301;
    pub const medeleg: u12 = 0x302;
    pub const mideleg: u12 = 0x303;
    pub const mie: u12 = 0x304;
    pub const mtvec: u12 = 0x305;
    pub const mscratch: u12 = 0x340;
    pub const mepc: u12 = 0x341;
    pub const mcause: u12 = 0x342;
    pub const mtval: u12 = 0x343;
    pub const mip: u12 = 0x344;

    pub const sstatus: u12 = 0x100;
    pub const sie: u12 = 0x104;
    pub const stvec: u12 = 0x105;
    pub const sscratch: u12 = 0x140;
    pub const sepc: u12 = 0x141;
    pub const scause: u12 = 0x142;
    pub const stval: u12 = 0x143;
    pub const sip: u12 = 0x144;
    pub const satp: u12 = 0x180;
};

pub const PRIV_USER: u2 = 0;
pub const PRIV_SUPERVISOR: u2 = 1;
pub const PRIV_MACHINE: u2 = 3;

/// Default RV32IMAFDC misa encoding.
pub const DEFAULT_MISA_RV32: u32 = (1 << 30) | (1 << 8) | (1 << 12) |
    (1 << 0) | (1 << 5) | (1 << 3) | (1 << 2);

/// Virtual CPU State.
pub const VCpu = extern struct {
    /// Guest general purpose registers x0-x31 -> offset 0..256.
    regs: [32]u64 = std.mem.zeroes([32]u64),
    /// Guest program counter -> offset 256..260.
    pc: u32 = 0,
    _pad0: u32 = 0,
    id: usize = 0, // offset 264..272.
    tlb_entries_ptr: usize = 0, // offset 272..280.
    host_sp: usize = 0, // offset 280..288.
    scratch_t1: u64 = 0, // offset 288..296.
    scratch_t2: u64 = 0, // offset 296..304.
    privilege_mode: u8 = 3,
    priv_mode: u8 = 3,
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
    medeleg: u32 = 0xffff,
    mideleg: u32 = 0xffff,
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
    vstimecmp: u64 = 0xffffffffffffffff,
    load_res_addr: usize = 0,
    load_res_val: u32 = 0,
    needs_tlb_flush_flag: bool = false,
    needs_cache_flush_flag: bool = false,
    _pad8: u16 = 0,
    softtlb: extern struct { privilege_mode: u8 = 1 } = .{},

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
    }

    pub var time_offset = std.atomic.Value(u64).init(0);
    pub var max_guest_time = std.atomic.Value(u64).init(0);
    pub var guest_insn_time = std.atomic.Value(u64).init(10_000_000);

    pub fn setMipBit(self: *VCpu, bit: u5) void {
        _ = @atomicRmw(u32, &self.mip, .Or, @as(u32, 1) << bit, .seq_cst);
    }

    pub fn clearMipBit(self: *VCpu, bit: u5) void {
        _ = @atomicRmw(u32, &self.mip, .And, ~(@as(u32, 1) << bit), .seq_cst);
    }

    pub fn getMip(self: *const VCpu) u32 {
        var m = @atomicLoad(u32, &self.mip, .seq_cst);
        const now = readGuestTime();
        if (self.vstimecmp != ~@as(u64, 0) and now >= self.vstimecmp) {
            m |= (1 << 5); // STIP.
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
        if (self.vstimecmp != ~@as(u64, 0) and now >= self.vstimecmp) {
            m |= (1 << 5);
        } else if (self.vstimecmp != ~@as(u64, 0)) {
            m &= ~@as(u32, 1 << 5);
        }
        return m;
    }

    pub fn readCsr(self: *VCpu, csr: u12) u32 {
        return switch (csr) {
            CsrAddr.mstatus => blk: {
                var m = self.mstatus;
                if ((self.misa & ((1 << 5) | (1 << 3))) == 0) {
                    m &= ~@as(u32, 3 << 13);
                }
                break :blk m;
            },
            CsrAddr.misa => self.misa,
            CsrAddr.medeleg => self.medeleg,
            CsrAddr.mideleg => self.mideleg,
            CsrAddr.mie => self.mie,
            CsrAddr.mtvec => self.mtvec,
            CsrAddr.mscratch => self.mscratch,
            CsrAddr.mepc => self.mepc,
            CsrAddr.mcause => self.mcause,
            CsrAddr.mtval => self.mtval,
            CsrAddr.mip => self.computeEffectiveMip(),

            CsrAddr.sstatus => blk: {
                var m = self.mstatus & 0x800de762;
                if ((self.misa & ((1 << 5) | (1 << 3))) == 0) {
                    m &= ~@as(u32, 3 << 13);
                }
                break :blk m;
            },
            CsrAddr.sie => self.mie & self.mideleg,
            CsrAddr.stvec => self.stvec,
            CsrAddr.sscratch => self.sscratch,
            CsrAddr.sepc => self.sepc,
            CsrAddr.scause => self.scause,
            CsrAddr.stval => self.stval,
            CsrAddr.sip => self.computeEffectiveMip() & self.mideleg,
            CsrAddr.satp => self.satp,

            0x001 => self.fcsr & 0x1f, // fflags.
            0x002 => (self.fcsr >> 5) & 0x7, // frm.
            0x003 => self.fcsr & 0xff, // fcsr.

            0x14d => @truncate(self.vstimecmp),
            0x15d => @truncate(self.vstimecmp >> 32),

            0xc00, 0xc01, 0xc02 => @truncate(readGuestTime()),
            0xc80, 0xc81, 0xc82 => @truncate(readGuestTime() >> 32),

            else => 0,
        };
    }

    pub fn writeCsr(self: *VCpu, csr: u12, val: u32) void {
        switch (csr) {
            0x001 => { // fflags.
                self.fcsr = (self.fcsr & ~@as(u32, 0x1f)) | (val & 0x1f);
                self.mstatus |= (3 << 13); // Mark FS dirty.
            },
            0x002 => { // frm.
                self.fcsr =
                    (self.fcsr & ~@as(u32, 0xe0)) | ((val & 0x7) << 5);
                self.mstatus |= (3 << 13); // Mark FS dirty.
            },
            0x003 => { // fcsr.
                self.fcsr = val & 0xff;
                self.mstatus |= (3 << 13); // Mark FS dirty.
            },

            CsrAddr.mstatus => {
                var v = val;
                if ((self.misa & ((1 << 5) | (1 << 3))) == 0) {
                    v &= ~@as(u32, 3 << 13);
                }
                self.mstatus = v;
            },
            CsrAddr.medeleg => self.medeleg = val,
            CsrAddr.mideleg => {
                self.mideleg = val;
                self.sie = self.mie & val;
            },
            CsrAddr.mie => {
                self.mie = val;
                self.sie = val & self.mideleg;
            },
            CsrAddr.mtvec => self.mtvec = val,
            CsrAddr.mscratch => self.mscratch = val,
            CsrAddr.mepc => self.mepc = val,
            CsrAddr.mcause => self.mcause = val,
            CsrAddr.mtval => self.mtval = val,
            CsrAddr.mip => @atomicStore(u32, &self.mip, val, .seq_cst),

            CsrAddr.sstatus => {
                var mask: u32 = 0x800de762;
                if ((self.misa & ((1 << 5) | (1 << 3))) == 0) {
                    mask &= ~@as(u32, 3 << 13);
                }
                self.mstatus = (self.mstatus & ~mask) | (val & mask);
            },
            CsrAddr.sie => {
                self.mie = (self.mie & ~self.mideleg) | (val & self.mideleg);
                self.sie = self.mie & self.mideleg;
            },
            CsrAddr.stvec => self.stvec = val,
            CsrAddr.sscratch => self.sscratch = val,
            CsrAddr.sepc => self.sepc = val,
            CsrAddr.scause => self.scause = val,
            CsrAddr.stval => self.stval = val,
            CsrAddr.sip => {
                const mask = self.mideleg & 0x222; // SSIP, STIP, SEIP.
                const prev = @atomicLoad(u32, &self.mip, .seq_cst);
                @atomicStore(
                    u32,
                    &self.mip,
                    (prev & ~mask) | (val & mask),
                    .seq_cst,
                );
            },
            CsrAddr.satp => self.satp = val,

            0x14d => {
                self.vstimecmp =
                    (self.vstimecmp & 0xffffffff00000000) | val;
            },
            0x15d => {
                self.vstimecmp = (self.vstimecmp & 0x00000000ffffffff) |
                    (@as(u64, val) << 32);
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
        clearReservation(self.id);
        self.load_res_addr = 0;
        const is_interrupt = (cause & 0x80000000) != 0;
        const code = cause & 0x7fffffff;
        const delegate_to_s = if (self.privilege_mode < 3 and code < 32) blk: {
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

            const sie = (self.mstatus >> 1) & 1;
            var mstatus = self.mstatus;
            mstatus &= ~@as(u32, 1 << 8);
            mstatus |= (@as(u32, self.privilege_mode & 1) << 8);
            mstatus &= ~@as(u32, 1 << 5);
            mstatus |= (sie << 5);
            mstatus &= ~@as(u32, 1 << 1); // Disable interrupts in S-mode.
            self.mstatus = mstatus;

            self.privilege_mode = 1; // Supervisor mode.
            self.priv_mode = 1;
            self.softtlb.privilege_mode = 1;

            const mode = self.stvec & 3;
            const base = self.stvec & ~@as(u32, 3);
            self.pc = if (is_interrupt and mode == 1)
                base +% (4 *% code)
            else
                base;
        } else {
            self.mepc = fault_pc;
            self.mcause = cause;
            self.mtval = stval;

            const mie = (self.mstatus >> 3) & 1;
            var mstatus = self.mstatus;
            mstatus &= ~@as(u32, 3 << 11);
            mstatus |= (@as(u32, self.privilege_mode & 3) << 11);
            mstatus &= ~@as(u32, 1 << 7);
            mstatus |= (mie << 7);
            mstatus &= ~@as(u32, 1 << 3); // Disable interrupts in M-mode.
            self.mstatus = mstatus;

            self.privilege_mode = 3; // Machine mode.
            self.priv_mode = 3;
            self.softtlb.privilege_mode = 3;

            const mode = self.mtvec & 3;
            const base = self.mtvec & ~@as(u32, 3);
            self.pc = if (is_interrupt and mode == 1)
                base +% (4 *% code)
            else
                base;
        }
    }
};

test "VCpu GPR sign-extension, CSR delegation, and exception injection" {
    const testing = std.testing;
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
    cpu.priv_mode = PRIV_USER;
    cpu.medeleg = 0xffff;
    cpu.stvec = 0x80001000;
    cpu.injectException(13, 0x10002000, 0xdeadbeef);
    try testing.expectEqual(@as(u8, PRIV_SUPERVISOR), cpu.privilege_mode);
    try testing.expectEqual(@as(u32, 0x80001000), cpu.pc);
    try testing.expectEqual(@as(u32, 0x10002000), cpu.sepc);
    try testing.expectEqual(@as(u32, 13), cpu.scause);
    try testing.expectEqual(@as(u32, 0xdeadbeef), cpu.stval);
}
