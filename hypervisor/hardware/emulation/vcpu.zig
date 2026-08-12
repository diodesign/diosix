// Virtual CPU Context & CSR State for Diosix Non-Native Emulated Guests
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

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
    /// Current privilege level
    privilege_mode: u2 = 3,
    priv_mode: u2 = 3, // Alias for compatibility
    softtlb: struct { privilege_mode: u2 = 1 } = .{},
    time: u64 = 0,
    running: bool = true,

    // Machine-mode CSRs
    mstatus: u32 = 0,
    misa: u32 = (1 << 30) | (1 << 8) | (1 << 12) | (1 << 0) | (1 << 5) | (1 << 3) | (1 << 2), // RV32IMAFDC
    medeleg: u32 = 0,
    mideleg: u32 = 0,
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

    pub fn getGpr(self: *const VCpu, reg: u5) u64 {
        if (reg == 0) return 0;
        return self.regs[reg];
    }

    pub fn getReg(self: *const VCpu, reg: u5) u64 {
        return self.getGpr(reg);
    }

    pub fn setGpr(self: *VCpu, reg: u5, val: u64) void {
        if (reg == 0) return;
        self.regs[reg] = @as(u64, @as(u32, @truncate(val)));
    }

    pub fn setReg(self: *VCpu, reg: u5, val: u64) void {
        self.setGpr(reg, val);
    }

    pub fn readCsr(self: *const VCpu, csr: u12) u32 {
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
            CsrAddr.mip => self.mip,

            CsrAddr.sstatus => self.mstatus & 0x000DE162,
            CsrAddr.sie => self.mie & self.medeleg,
            CsrAddr.stvec => self.stvec,
            CsrAddr.sscratch => self.sscratch,
            CsrAddr.sepc => self.sepc,
            CsrAddr.scause => self.scause,
            CsrAddr.stval => self.stval,
            CsrAddr.sip => self.mip & self.mideleg,
            CsrAddr.satp => self.satp,

            else => 0,
        };
    }

    pub fn writeCsr(self: *VCpu, csr: u12, val: u32) void {
        switch (csr) {
            CsrAddr.mstatus => self.mstatus = val,
            CsrAddr.medeleg => self.medeleg = val,
            CsrAddr.mideleg => self.mideleg = val,
            CsrAddr.mie => self.mie = val,
            CsrAddr.mtvec => self.mtvec = val,
            CsrAddr.mscratch => self.mscratch = val,
            CsrAddr.mepc => self.mepc = val,
            CsrAddr.mcause => self.mcause = val,
            CsrAddr.mtval => self.mtval = val,
            CsrAddr.mip => self.mip = val,

            CsrAddr.stvec => self.stvec = val,
            CsrAddr.sscratch => self.sscratch = val,
            CsrAddr.sepc => self.sepc = val,
            CsrAddr.scause => self.scause = val,
            CsrAddr.stval => self.stval = val,
            CsrAddr.satp => self.satp = val,

            else => {},
        }
    }

    pub fn injectException(self: *VCpu, cause: u32, badaddr: u32) void {
        const delegate_to_s = (self.privilege_mode <= 1) and ((self.medeleg & (@as(u32, 1) << @as(u5, @truncate(cause)))) != 0);

        if (delegate_to_s) {
            self.sepc = self.pc;
            self.scause = cause;
            self.stval = badaddr;
            self.privilege_mode = 1; // Supervisor mode
            self.pc = self.stvec;
        } else {
            self.mepc = self.pc;
            self.mcause = cause;
            self.mtval = badaddr;
            self.privilege_mode = 3; // Machine mode
            self.pc = self.mtvec;
        }
    }
};
