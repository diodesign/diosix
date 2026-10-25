// RISC-V definitions shareable between hypervisor and other software.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

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

    pub const PRIV_USER: u2 = 0;
    pub const PRIV_SUPERVISOR: u2 = 1;
    pub const PRIV_MACHINE: u2 = 3;
};

pub const PRIV_USER: u2 = PrivilegeMode.PRIV_USER;
pub const PRIV_SUPERVISOR: u2 = PrivilegeMode.PRIV_SUPERVISOR;
pub const PRIV_MACHINE: u2 = PrivilegeMode.PRIV_MACHINE;

pub const IsaExtension = struct {
    pub const a: usize = 1 << 0;
    pub const c: usize = 1 << 2;
    pub const d: usize = 1 << 3;
    pub const f: usize = 1 << 5;
    pub const i: usize = 1 << 8;
    pub const m: usize = 1 << 12;
    pub const s: usize = 1 << 18;
    pub const u: usize = 1 << 20;
    pub const v: usize = 1 << 21;
    pub const h: usize = 1 << 7;

    pub const g: usize = i | m | a | f | d; // G = IMAFD.
    pub const gc: usize = g | c;
    pub const MXL_64: usize = @as(usize, 2) << 62;
    pub const MXL_32: u32 = @as(u32, 1) << 30;
};

// CSR bit-fields.
pub const MSTATUS = struct {
    pub const MPP_SHIFT = 11;
    pub const MPP_MASK = 0b11 << MPP_SHIFT;
    pub const MPP_USER: usize = 0 << MPP_SHIFT;
    pub const MPP_SUPERVISOR: usize = 1 << MPP_SHIFT;
    pub const MPP_MACHINE: usize = 3 << MPP_SHIFT;
    pub const SPP = 1 << 8;
    pub const MPIE = 1 << 7;
    pub const SPIE = 1 << 5;
    pub const MIE = 1 << 3;
    pub const SIE = 1 << 1;
    pub const MPRV = 1 << 17; // Modify PRiVilege: alters data access privilege.
    pub const SUM = 1 << 18; // Permit Supervisor User Memory access.
    pub const MXR = 1 << 19; // Make eXecutable Readable.
    pub const TVM = 1 << 20; // Trap Virtual Memory: intercepts SATP in S-mode.
    pub const TW = 1 << 21; // Timeout Wait: intercepts WFI in S/VS mode.
    pub const TSR = 1 << 22; // Trap SRET: intercepts SRET in S-mode.
    pub const SD_RV32: u32 = 1 << 31;
    pub const MPV: u64 = 1 << 39;

    // Mask of flags affecting virtual memory translation & access permissions.
    pub const TRANSLATION_AFFECTING_MASK: u32 = MPRV | SUM | MXR | MPP_MASK;

    // Vector State (VS) and Floating-point State (FS) field definitions.
    pub const VS_SHIFT = 9;
    pub const VS_MASK = 0b11 << VS_SHIFT;
    pub const VS_DIRTY: usize = 0b11 << VS_SHIFT;
    pub const FS_SHIFT = 13;
    pub const FS_MASK = 0b11 << FS_SHIFT;
    pub const FS_DIRTY: usize = 0b11 << FS_SHIFT;
};

pub const SSTATUS = struct {
    pub const SPP_SHIFT = 8;
    pub const SIE = 1 << 1;
    pub const SPIE = 1 << 5;
};

pub const HSTATUS = struct {
    pub const GVA: usize = 1 << 6;
    pub const SPV: usize = 1 << 7;
    pub const SPVP: usize = 1 << 8;
    pub const HU: usize = 1 << 9;
    pub const VGEIN_MASK: usize = 0x3f << 12;
    pub const VGEIN_SHIFT: usize = 12;
    pub const VTVM: usize = 1 << 20;
    pub const VTW: usize = 1 << 21;
    pub const VTSR: usize = 1 << 22;
};

pub const HVIP = struct {
    pub const VSSIP: usize = 1 << 2;
    pub const VSTIP: usize = 1 << 6;
    pub const VSEIP: usize = 1 << 10;
};

pub const MIE = struct {
    pub const SSIE: usize = 1 << 1;
    pub const MSIE: usize = 1 << 3;
    pub const STIE: usize = 1 << 5;
    pub const MTIE: usize = 1 << 7;
    pub const SEIE: usize = 1 << 9;
    pub const MEIE: usize = 1 << 11;
    pub const SGEIE: usize = 1 << 12;
    pub const ALL_PHYSICAL: usize = MSIE | MTIE | MEIE | SEIE;
};

pub const MIP = struct {
    pub const SSIP_BIT: u6 = 1;
    pub const MSIE_BIT: u6 = 3;
    pub const STIP_BIT: u6 = 5;
    pub const MTIE_BIT: u6 = 7;
    pub const SEIP_BIT: u6 = 9;
    pub const MEIP_BIT: u6 = 11;

    pub const SSIP: usize = 1 << SSIP_BIT;
    pub const MSIP: usize = 1 << MSIE_BIT;
    pub const STIP: usize = 1 << STIP_BIT;
    pub const MTIP: usize = 1 << MTIE_BIT;
    pub const SEIP: usize = 1 << SEIP_BIT;
    pub const MEIP: usize = 1 << MEIP_BIT;
};

pub const MCOUNTEREN = struct {
    pub const CY: usize = 1 << 0;
    pub const TM: usize = 1 << 1;
    pub const IR: usize = 1 << 2;
    pub const DEFAULT_COUNTERS: usize = CY | TM | IR;
};

pub const ENVCFG = struct {
    pub const FIOM: usize = 1 << 0;
    pub const CBIE_SHIFT: u6 = 4;
    pub const CBIE_MASK: usize = 0b11 << CBIE_SHIFT;
    pub const CBIE_ALL: usize = 0b11 << CBIE_SHIFT;
    pub const CBCFE: usize = 1 << 6;
    pub const CBZE: usize = 1 << 7;
    pub const STCE: usize = @as(usize, 1) << 63;
    pub const CACHE_OPS_ALL: usize = CBZE | CBCFE | CBIE_ALL;
};

pub const STATEEN = struct {
    pub const C: usize = 1 << 0;
    pub const FCSR: usize = 1 << 1;
    pub const V: usize = 1 << 2;
    pub const IMSIC: usize = @as(usize, 1) << 58;
    pub const AIA: usize = @as(usize, 1) << 59;
    pub const CSRIND: usize = @as(usize, 1) << 60;
    pub const ENVCFG: usize = @as(usize, 1) << 62;
    pub const SE0: usize = @as(usize, 1) << 63;
    pub const BASE_FEATURES: usize = STATEEN.ENVCFG | STATEEN.CSRIND |
        STATEEN.AIA | STATEEN.IMSIC | STATEEN.V | STATEEN.FCSR | STATEEN.C;
};

pub const Cause = enum(usize) {
    pub const INTERRUPT_BIT = 1 << 63;

    // Exceptions.
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

    // Interrupts (exception number with interrupt bit set).
    user_swi = INTERRUPT_BIT | 0,
    supervisor_swi = INTERRUPT_BIT | 1,
    machine_swi = INTERRUPT_BIT | 3,
    user_timer = INTERRUPT_BIT | 4,
    supervisor_timer = INTERRUPT_BIT | 5,
    machine_timer = INTERRUPT_BIT | 7,
    user_interrupt = INTERRUPT_BIT | 8,
    supervisor_interrupt = INTERRUPT_BIT | 9,
    machine_interrupt = INTERRUPT_BIT | 11,

    unknown = std.math.maxInt(usize),
};

// Trap delegation masks derived from Cause, HVIP, and MIE bit positions.
pub const DELEGATED_EXCEPTIONS: usize =
    (1 << @backingInt(Cause.instruction_alignment)) |
    (1 << @backingInt(Cause.instruction_access)) |
    (1 << @backingInt(Cause.breakpoint)) |
    (1 << @backingInt(Cause.load_alignment)) |
    (1 << @backingInt(Cause.load_access)) |
    (1 << @backingInt(Cause.store_alignment)) |
    (1 << @backingInt(Cause.store_access)) |
    (1 << @backingInt(Cause.user_environment_call)) |
    (1 << @backingInt(Cause.instruction_page_fault)) |
    (1 << @backingInt(Cause.load_page_fault)) |
    (1 << @backingInt(Cause.store_page_fault));
pub const HEDELEG_DELEGATED: usize = DELEGATED_EXCEPTIONS;
pub const MEDELEG_DELEGATED: usize = DELEGATED_EXCEPTIONS;
pub const MIDELEG_DELEGATED: usize = HVIP.VSSIP | HVIP.VSTIP | HVIP.VSEIP;
pub const HIDELEG_DELEGATED: usize = MIE.SSIE | HVIP.VSSIP | MIE.STIE |
    HVIP.VSTIP | MIE.SEIE | HVIP.VSEIP | MIE.SGEIE;

pub fn toCause(val: usize) Cause {
    return std.enums.fromInt(Cause, val) orelse .unknown;
}

pub const HTVAL_GPA_SHIFT: u6 = 2;

// Standard RISC-V CSR numbers.
pub const CSR = struct {
    // Floating-point control and status CSRs.
    pub const FFLAGS = 0x001;
    pub const FRM = 0x002;
    pub const FCSR = 0x003;

    // User / Supervisor / Machine standard CSRs.
    pub const CYCLE = 0xc00;
    pub const TIME = 0xc01;
    pub const INSTRET = 0xc02;
    pub const CYCLEH = 0xc80;
    pub const TIMEH = 0xc81;
    pub const INSTRETH = 0xc82;

    pub const SSTATUS = 0x100;
    pub const SIE = 0x104;
    pub const STVEC = 0x105;
    pub const SCOUNTEREN = 0x106;
    pub const SENVCFG = 0x10a;
    pub const SSCRATCH = 0x140;
    pub const SEPC = 0x141;
    pub const SCAUSE = 0x142;
    pub const STVAL = 0x143;
    pub const SIP = 0x144;
    pub const STIMECMP = 0x14d;
    pub const STIMECMPH = 0x15d;
    pub const SATP = 0x180;

    pub const MSTATUS = 0x300;
    pub const MISA = 0x301;
    pub const MEDELEG = 0x302;
    pub const MIDELEG = 0x303;
    pub const MIE = 0x304;
    pub const MTVEC = 0x305;
    pub const MCOUNTEREN = 0x306;
    pub const MENVCFG = 0x30a;
    pub const MSTATEEN0 = 0x30c;
    pub const MSCRATCH = 0x340;
    pub const MEPC = 0x341;
    pub const MCAUSE = 0x342;
    pub const MTVAL = 0x343;
    pub const MIP = 0x344;
    pub const MTINST = 0x34a;
    pub const MTVAL2 = 0x34b;

    // Machine Information Registers.
    pub const MVENDORID = 0xf11;
    pub const MARCHID = 0xf12;
    pub const MIMPID = 0xf13;
    pub const MHARTID = 0xf14;

    // Entropy Source (Zkr).
    pub const SEED = 0x015;

    // Advanced Interrupt Architecture (AIA) CSRs.
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

    // Execution environment configuration.
    pub const HENVCFG = 0x60a;
    pub const HSTATEEN0 = 0x60c;

    // Timer/Counter CSRs.
    pub const VSTIMECMP = 0x24d;
};

// RISC-V instruction decoding constants.
pub const Instr = struct {
    pub const PARCEL_ALIGN_MASK = 0x2;
    pub const INSN_32BIT_MASK = 0b11;
    pub const INSN_SIZE_BYTES = 4;

    pub const OPCODE_MASK = 0x7f;
    pub const CSR_MASK = 0xfff;
    pub const REG_MASK = 0x1f;
    pub const RD_MASK = 0x1f;
    pub const RS1_MASK = 0x1f;
    pub const FUNCT3_MASK = 0x7;

    pub const RD_SHIFT = 7;
    pub const FUNCT3_SHIFT = 12;
    pub const RS1_SHIFT = 15;
    pub const RS2_SHIFT = 20;
    pub const CSR_SHIFT = 20;

    pub const OPCODE_SYSTEM = 0x73;
    pub const OPCODE_MISC_MEM = 0x0f;

    // CSR instruction types (funct3).
    pub const FUNCT3_CSRRW = 1;
    pub const FUNCT3_CSRRS = 2;
    pub const FUNCT3_CSRRC = 3;
    pub const FUNCT3_CSRRWI = 5;
    pub const FUNCT3_CSRRSI = 6;
    pub const FUNCT3_CSRRCI = 7;

    // Specific standard instruction encodings.
    pub const WFI = 0x10500073;
    pub const WRS_NTO = 0x00d0_0073;
    pub const WRS_STO = 0x01d0_0073;
    pub const PAUSE = 0x0100_000f;
    pub const FENCE_I = 0x0000100f;
    pub const FUNCT3_FENCE = 0;
};

test "RISC-V cause decoding and CSR bitmask invariants" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;

    try testing.expectEqual(Cause.instruction_alignment, toCause(0));
    try testing.expectEqual(Cause.illegal_instruction, toCause(2));
    try testing.expectEqual(
        Cause.virtual_supervisor_environment_call,
        toCause(10),
    );
    try testing.expectEqual(Cause.guest_store_page_fault, toCause(23));
    try testing.expectEqual(
        Cause.machine_timer,
        toCause(Cause.INTERRUPT_BIT | 7),
    );
    try testing.expectEqual(
        Cause.supervisor_interrupt,
        toCause(Cause.INTERRUPT_BIT | 9),
    );
    try testing.expectEqual(Cause.unknown, toCause(14));
    try testing.expectEqual(Cause.unknown, toCause(99));

    try testing.expectEqual(@as(usize, 1 << 7), HSTATUS.SPV);
    try testing.expectEqual(@as(usize, 1 << 20), HSTATUS.VTVM);
    try testing.expectEqual(@as(usize, 0xa88), MIE.ALL_PHYSICAL);
    try testing.expectEqual(@as(usize, 0xf0), ENVCFG.CACHE_OPS_ALL);
    try testing.expectEqual(@as(usize, 0xb1fb), HEDELEG_DELEGATED);
    try testing.expectEqual(@as(usize, 0x1666), HIDELEG_DELEGATED);
    try testing.expectEqual(@as(usize, 0x0444), MIDELEG_DELEGATED);
}
