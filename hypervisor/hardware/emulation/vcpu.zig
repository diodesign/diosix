// Virtual CPU Context & CSR State for Diosix Non-Native Emulated Guests
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");

pub inline fn readHostTime() u64 {
    var host_time: u64 = 0;
    if (comptime builtin.target.cpu.arch.isRISCV()) {
        asm volatile ("rdtime %[host_time]" : [host_time] "=r" (host_time));
    }
    return host_time;
}

/// Privilege levels for virtual CPU
pub const PrivilegeMode = enum(u2) {
    user = 0,
    supervisor = 1,
    machine = 3,
};

/// CSR Addresses for RISC-V 32-bit CPU
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

/// Virtual CPU State
pub const VCpu = struct {
    /// Guest general purpose registers x0-x31 (x0 is hardwired to 0)
    regs: [32]u64 = std.mem.zeroes([32]u64),
    /// Guest program counter
    pc: u32 = 0,
    id: usize = 0,
    /// Current privilege level
    privilege_mode: u2 = 3,
    priv_mode: u2 = 3, // Alias for compatibility
    softtlb: struct { privilege_mode: u2 = 1 } = .{},
    time: u64 = 0,
    running: bool = true,
    last_sepc_when_stvec_zero: u32 = 0,
    vregs: [32][32]u8 = std.mem.zeroes([32][32]u8),
    vl: u32 = 32,

    // Machine-mode CSRs
    mstatus: u32 = 0,
    misa: u32 = (1 << 30) | (1 << 8) | (1 << 12) | (1 << 0) | (1 << 5) | (1 << 3) | (1 << 2), // RV32IMAFDC
    medeleg: u32 = 0xffff,
    mideleg: u32 = 0xffff,
    mie: u32 = 0,
    mtvec: u32 = 0,
    mscratch: u32 = 0,
    mepc: u32 = 0,
    mcause: u32 = 0,
    mtval: u32 = 0,
    mip: u32 = 0,

    // Supervisor-mode CSRs
    stvec: u32 = 0,
    sscratch: u32 = 0,
    sepc: u32 = 0,
    scause: u32 = 0,
    stval: u32 = 0,
    satp: u32 = 0,
    sie: u32 = 0,
    vstimecmp: u64 = 0xffffffffffffffff,
    load_res_addr: usize = 0,
    load_res_val: u32 = 0,
    needs_tlb_flush: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    needs_cache_flush: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn getGpr(self: *const VCpu, reg: u5) u64 {
        if (reg == 0) return 0;
        return @as(u64, @bitCast(@as(i64, @as(i32, @truncate(@as(i64, @bitCast(self.regs[reg])))))));
    }

    pub fn getReg(self: *const VCpu, reg: u5) u64 {
        return self.getGpr(reg);
    }

    pub fn setGpr(self: *VCpu, reg: u5, val: u64) void {
        if (reg == 0) return;
        self.regs[reg] = @as(u64, @bitCast(@as(i64, @as(i32, @truncate(@as(i64, @bitCast(val)))))));
    }

    pub fn setReg(self: *VCpu, reg: u5, val: u64) void {
        self.setGpr(reg, val);
    }

    pub var time_offset: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var max_guest_time: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    pub var guest_insn_time: std.atomic.Value(u64) = std.atomic.Value(u64).init(10_000_000);

    pub var global_reservation_addr: [4]std.atomic.Value(usize) = .{
        std.atomic.Value(usize).init(0),
        std.atomic.Value(usize).init(0),
        std.atomic.Value(usize).init(0),
        std.atomic.Value(usize).init(0),
    };

    pub fn setReservation(hart_id: usize, paddr: usize) void {
        if (hart_id < 4) {
            global_reservation_addr[hart_id].store(paddr & ~@as(usize, 0x3F), .release);
        }
    }

    pub fn checkAndClearReservation(hart_id: usize, paddr: usize) bool {
        if (hart_id >= 4) return false;
        const line = paddr & ~@as(usize, 0x3F);
        const cur = global_reservation_addr[hart_id].swap(0, .acq_rel);
        return (cur == line and line != 0);
    }

    pub fn invalidateReservations(paddr: usize) void {
        const line = paddr & ~@as(usize, 0x3F);
        for (0..4) |i| {
            if (global_reservation_addr[i].load(.monotonic) == line) {
                global_reservation_addr[i].store(0, .monotonic);
            }
        }
    }

    pub fn setMipBit(self: *VCpu, bit: u5) void {
        _ = @atomicRmw(u32, &self.mip, .Or, @as(u32, 1) << bit, .seq_cst);
    }

    pub fn clearMipBit(self: *VCpu, bit: u5) void {
        _ = @atomicRmw(u32, &self.mip, .And, ~(@as(u32, 1) << bit), .seq_cst);
    }

    pub fn getMip(self: *const VCpu) u32 {
        return @atomicLoad(u32, &self.mip, .seq_cst);
    }

    pub fn readGuestTime() u64 {
        const now = readHostTime();
        const offset = time_offset.load(.monotonic);
        if (now >= offset) {
            return now - offset;
        } else {
            return 0;
        }
    }

    pub fn readCsr(self: *VCpu, csr: u12) u32 {
        return switch (csr) {
            CsrAddr.mstatus => self.mstatus,
            CsrAddr.misa => self.misa,
            CsrAddr.medeleg => self.medeleg,
            CsrAddr.mideleg => self.mideleg,
            CsrAddr.mie => self.mie,
            CsrAddr.mtvec => self.mtvec,
            CsrAddr.mscratch => self.mscratch,
            CsrAddr.mepc => self.mepc,
            CsrAddr.mcause => self.mcause,
            CsrAddr.mtval => self.mtval,
            CsrAddr.mip => blk: {
                const now = readGuestTime();
                var m = self.mip;
                if (self.vstimecmp != ~@as(u64, 0) and now >= self.vstimecmp) {
                    m |= (1 << 5);
                } else if (self.vstimecmp != ~@as(u64, 0)) {
                    m &= ~@as(u32, 1 << 5);
                }
                break :blk m;
            },

            CsrAddr.sstatus => self.mstatus & 0x800DE762,
            CsrAddr.sie => self.mie & self.mideleg,
            CsrAddr.stvec => self.stvec,
            CsrAddr.sscratch => self.sscratch,
            CsrAddr.sepc => self.sepc,
            CsrAddr.scause => self.scause,
            CsrAddr.stval => self.stval,
            CsrAddr.sip => blk: {
                const now = readGuestTime();
                var m = self.mip;
                if (self.vstimecmp != ~@as(u64, 0) and now >= self.vstimecmp) {
                    m |= (1 << 5);
                } else if (self.vstimecmp != ~@as(u64, 0)) {
                    m &= ~@as(u32, 1 << 5);
                }
                break :blk m & self.mideleg;
            },
            CsrAddr.satp => self.satp,

            0x14D => @truncate(self.vstimecmp),
            0x15D => @truncate(self.vstimecmp >> 32),

            0xC00, 0xC01, 0xC02 => blk: {
                const now = readGuestTime();
                break :blk @truncate(now);
            },
            0xC80, 0xC81, 0xC82 => blk: {
                const now = readGuestTime();
                break :blk @truncate(now >> 32);
            },

            else => 0,
        };
    }

    pub fn writeCsr(self: *VCpu, csr: u12, val: u32) void {
        switch (csr) {
            CsrAddr.mstatus => self.mstatus = val,
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
            CsrAddr.mip => self.mip = val,

            CsrAddr.sstatus => {
                const mask: u32 = 0x800DE762;
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
                // S-mode software interrupt flag (SSIP = bit 1) can be cleared by writing 0 to sip
                const mask = self.mideleg & 0x222; // SSIP, STIP, SEIP
                self.mip = (self.mip & ~mask) | (val & mask);
            },
            CsrAddr.satp => self.satp = val,

            0x14D => {
                self.vstimecmp = (self.vstimecmp & 0xFFFFFFFF00000000) | val;
            },
            0x15D => {
                self.vstimecmp = (self.vstimecmp & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
            },

            else => {},
        }
    }

    pub fn injectException(self: *VCpu, cause: u32, fault_pc: u32, stval: u32) void {
        if (self.id < 4) global_reservation_addr[self.id].store(0, .monotonic);
        self.load_res_addr = 0;
        const is_interrupt = (cause & 0x80000000) != 0;
        const code = cause & 0x7fffffff;
        const delegate_to_s = if (self.privilege_mode < 3)
            (if (is_interrupt) (self.mideleg & (@as(u32, 1) << @truncate(code))) != 0 else (self.medeleg & (@as(u32, 1) << @truncate(code))) != 0)
        else
            false;

        if (delegate_to_s) {
            self.sepc = fault_pc;
            self.scause = cause;
            self.stval = stval;
            if (self.stvec == 0) {
                self.last_sepc_when_stvec_zero = fault_pc;
            }

            // Update sstatus (mstatus):
            // Set SPP (bit 8) to current privilege mode (0 or 1)
            // Set SPIE (bit 5) to SIE (bit 1)
            // Clear SIE (bit 1)
            const sie = (self.mstatus >> 1) & 1;
            var mstatus = self.mstatus;
            mstatus &= ~@as(u32, 1 << 8);
            mstatus |= (@as(u32, self.privilege_mode & 1) << 8);
            mstatus &= ~@as(u32, 1 << 5);
            mstatus |= (sie << 5);
            mstatus &= ~@as(u32, 1 << 1); // Disable interrupts in S-mode
            self.mstatus = mstatus;

            self.privilege_mode = 1; // Supervisor mode
            self.priv_mode = 1;
            self.softtlb.privilege_mode = 1;

            const mode = self.stvec & 3;
            const base = self.stvec & ~@as(u32, 3);
            self.pc = if (is_interrupt and mode == 1) base + 4 * code else base;
        } else {
            self.mepc = fault_pc;
            self.mcause = cause;
            self.mtval = stval;

            // Update mstatus:
            // Set MPP (bits 12..11) to current privilege mode
            // Set MPIE (bit 7) to MIE (bit 3)
            // Clear MIE (bit 3)
            const mie = (self.mstatus >> 3) & 1;
            var mstatus = self.mstatus;
            mstatus &= ~@as(u32, 3 << 11);
            mstatus |= (@as(u32, self.privilege_mode & 3) << 11);
            mstatus &= ~@as(u32, 1 << 7);
            mstatus |= (mie << 7);
            mstatus &= ~@as(u32, 1 << 3); // Disable interrupts in M-mode
            self.mstatus = mstatus;

            self.privilege_mode = 3; // Machine mode
            self.priv_mode = 3;
            self.softtlb.privilege_mode = 3;

            const mode = self.mtvec & 3;
            const base = self.mtvec & ~@as(u32, 3);
            self.pc = if (is_interrupt and mode == 1) base + 4 * code else base;
        }
    }
};
