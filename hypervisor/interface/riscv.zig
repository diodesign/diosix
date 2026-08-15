// RISC-V definitions shareable between hypervisor and other software
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

pub const Register = enum(usize) {
    zero = 0,
    ra = 1,
    sp = 2,
    gp = 3,
    tp = 4,
    t0 = 5,
    t1 = 6,
    t2 = 7,
    s0 = 8,
    s1 = 9,
    a0 = 10,
    a1 = 11,
    a2 = 12,
    a3 = 13,
    a4 = 14,
    a5 = 15,
    a6 = 16,
    a7 = 17,
    s2 = 18,
    s3 = 19,
    s4 = 20,
    s5 = 21,
    s6 = 22,
    s7 = 23,
    s8 = 24,
    s9 = 25,
    s10 = 26,
    s11 = 27,
    t3 = 28,
    t4 = 29,
    t5 = 30,
    t6 = 31,
};

pub const PrivilegeMode = enum(u2) {
    user = 0,
    supervisor = 1,
    machine = 3,
};

pub const IsaExtension = struct {
    pub const a: usize = 1 << 0;
    pub const c: usize = 1 << 2;
    pub const d: usize = 1 << 3;
    pub const f: usize = 1 << 5;
    pub const i: usize = 1 << 8;
    pub const m: usize = 1 << 12;
    pub const s: usize = 1 << 18;
    pub const u: usize = 1 << 20;
    pub const h: usize = 1 << 7;

    pub const g: usize = i | m | a | f | d; // G = IMAFD
    pub const gc: usize = g | c;
};

// CSR Bit-fields
pub const MSTATUS = struct {
    pub const MPP_SHIFT = 11;
    pub const MPP_MASK = 0b11 << MPP_SHIFT;
    pub const MIE = 1 << 3;
    pub const MPIE = 1 << 7;
    pub const SIE = 1 << 1;
    pub const MPV: u64 = 1 << 39;

    // Vector State (VS) and Floating-point State (FS) field definitions
    pub const VS_SHIFT = 9;
    pub const VS_MASK = 0b11 << VS_SHIFT;
    pub const FS_SHIFT = 13;
    pub const FS_MASK = 0b11 << FS_SHIFT;
};

pub const SSTATUS = struct {
    pub const SPP_SHIFT = 8;
    pub const SIE = 1 << 1;
    pub const SPIE = 1 << 5;
};

pub const HSTATUS = struct {
    pub const GVA = 1 << 6;
    pub const SPV = 1 << 7;
    pub const SPVP = 1 << 8;
};

pub const HVIP = struct {
    pub const VSSIP: usize = 1 << 2;
    pub const VSTIP: usize = 1 << 6;
    pub const VSEIP: usize = 1 << 10;
};

pub const Cause = enum(usize) {
    pub const INTERRUPT_BIT = 1 << 63;

    // Exceptions
    instruction_alignment = 0,
    instruction_access = 1,
    illegal_instruction = 2,
    breakpoint = 3,
    load_alignment = 4,
    load_access = 5,
    store_alignment = 6,
    store_access = 7,
    user_environment_call = 8,
    supervisor_environment_call = 9,
    virtual_supervisor_environment_call = 10,
    machine_environment_call = 11,
    instruction_page_fault = 12,
    load_page_fault = 13,
    store_page_fault = 15,
    guest_instruction_page_fault = 20,
    guest_load_page_fault = 21,
    virtual_instruction = 22,
    guest_store_page_fault = 23,

    // Interrupts (exception number with interrupt bit set)
    user_swi = INTERRUPT_BIT | 0,
    supervisor_swi = INTERRUPT_BIT | 1,
    machine_swi = INTERRUPT_BIT | 3,
    user_timer = INTERRUPT_BIT | 4,
    supervisor_timer = INTERRUPT_BIT | 5,
    machine_timer = INTERRUPT_BIT | 7,
    user_interrupt = INTERRUPT_BIT | 8,
    supervisor_interrupt = INTERRUPT_BIT | 9,
    machine_interrupt = INTERRUPT_BIT | 11,

    unknown = 0xffffffffffffffff,
};

pub fn toCause(val: usize) Cause {
    return switch (val) {
        0 => .instruction_alignment,
        1 => .instruction_access,
        2 => .illegal_instruction,
        3 => .breakpoint,
        4 => .load_alignment,
        5 => .load_access,
        6 => .store_alignment,
        7 => .store_access,
        8 => .user_environment_call,
        9 => .supervisor_environment_call,
        10 => .virtual_supervisor_environment_call,
        11 => .machine_environment_call,
        12 => .instruction_page_fault,
        13 => .load_page_fault,
        15 => .store_page_fault,
        20 => .guest_instruction_page_fault,
        21 => .guest_load_page_fault,
        22 => .virtual_instruction,
        23 => .guest_store_page_fault,

        Cause.INTERRUPT_BIT | 0 => .user_swi,
        Cause.INTERRUPT_BIT | 1 => .supervisor_swi,
        Cause.INTERRUPT_BIT | 3 => .machine_swi,
        Cause.INTERRUPT_BIT | 4 => .user_timer,
        Cause.INTERRUPT_BIT | 5 => .supervisor_timer,
        Cause.INTERRUPT_BIT | 7 => .machine_timer,
        Cause.INTERRUPT_BIT | 8 => .user_interrupt,
        Cause.INTERRUPT_BIT | 9 => .supervisor_interrupt,
        Cause.INTERRUPT_BIT | 11 => .machine_interrupt,

        else => .unknown,
    };
}

// Standard RISC-V CSR Numbers
pub const CSR = struct {
    // Entropy Source (Zkr)
    pub const SEED = 0x015;

    // Advanced Interrupt Architecture (AIA) CSRs
    pub const SISELECT_LEGACY = 0x015;
    pub const SIREG_LEGACY = 0x016;
    pub const VSISELECT_LEGACY = 0x215;
    pub const VSIREG_LEGACY = 0x216;

    pub const SISELECT = 0x150;
    pub const SIREG = 0x151;
    pub const VSISELECT = 0x250;
    pub const VSIREG = 0x251;

    pub const SISELECTH = 0xdb0;
    pub const SIREGH = 0xdb4;
    pub const VSISELECTH = 0xeb0;
    pub const VSIREGH = 0xeb4;

    // Execution Environment Config
    pub const SENVCFG = 0x10a;
    pub const VSENVCFG = 0x20a;

    // Timer/Counter CSRs
    pub const TIME = 0xc01;
    pub const STIMECMP = 0x14d;
};

// RISC-V Instruction Decoding Constants
pub const Instr = struct {
    pub const OPCODE_MASK = 0x7f;
    pub const CSR_MASK = 0xfff;
    pub const RD_MASK = 0x1f;
    pub const RS1_MASK = 0x1f;
    pub const FUNCT3_MASK = 0x7;

    pub const OPCODE_SYSTEM = 0x73;
    pub const OPCODE_MISC_MEM = 0x0f;

    // CSR Instruction Types (funct3)
    pub const FUNCT3_CSRRW = 1;
    pub const FUNCT3_CSRRS = 2;
    pub const FUNCT3_CSRRC = 3;
    pub const FUNCT3_CSRRWI = 5;
    pub const FUNCT3_CSRRSI = 6;
    pub const FUNCT3_CSRRCI = 7;

    // Specific standard instruction encodings
    pub const WFI = 0x10500073;
    pub const FENCE_I = 0x0000100f;
    pub const FUNCT3_FENCE = 0;
};

// (End of interface/riscv.zig)

