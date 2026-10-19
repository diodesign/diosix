// RV32 Instruction Encoding Constants, Types, and Immediate Helpers.
//
// Shared definitions for RV32I/M/A/F/D/V/C instruction decoding.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const rv64 = @import("../../emitters/rv64.zig");

pub const AmoFunct5 = rv64.AmoFunct5;
pub const FUNCT3_AMO_W = rv64.FUNCT3_AMO_W;

// RV32 primary opcodes (bits [6:0]).
pub const OPC_LOAD: u32 = 0x03;
pub const OPC_LOAD_FP: u32 = 0x07;
pub const OPC_MISC_MEM: u32 = 0x0f;
pub const OPC_OP_IMM: u32 = 0x13;
pub const OPC_AUIPC: u32 = 0x17;
pub const OPC_STORE: u32 = 0x23;
pub const OPC_STORE_FP: u32 = 0x27;
pub const OPC_AMO: u32 = 0x2f;
pub const OPC_OP: u32 = 0x33;
pub const OPC_LUI: u32 = 0x37;
pub const OPC_MADD: u32 = 0x43;
pub const OPC_MSUB: u32 = 0x47;
pub const OPC_NMSUB: u32 = 0x4b;
pub const OPC_NMADD: u32 = 0x4f;
pub const OPC_OP_FP: u32 = 0x53;
pub const OPC_OP_V: u32 = 0x57;
pub const OPC_BRANCH: u32 = 0x63;
pub const OPC_JALR: u32 = 0x67;
pub const OPC_JAL: u32 = 0x6f;
pub const OPC_SYSTEM: u32 = 0x73;

// R-type and I-type shift funct7 values (bits [31:25]).
pub const FUNCT7_BASE: u7 = 0x00;
pub const FUNCT7_MULDIV: u7 = 0x01;
pub const FUNCT7_SUB_SRA: u7 = 0x20;

// System instruction funct7 and rs2 sub-opcodes.
pub const FUNCT7_SYS_PRIV: i32 = 0x000;
pub const FUNCT7_SYS_SRET_WFI: i32 = 0x008;
pub const FUNCT7_SYS_SFENCE_VMA: i32 = 0x009;
pub const FUNCT7_SYS_MRET: i32 = 0x018;
pub const SYS_RS2_ECALL: i32 = 0x00;
pub const SYS_RS2_EBREAK: i32 = 0x01;
pub const SYS_RS2_RET: i32 = 0x02;
pub const SYS_RS2_WFI: i32 = 0x05;

// Zihintpause encoding (FENCE with pred=W, succ=0).
pub const INSN_PAUSE: u32 = 0x0100000f;

// Instruction length constants.
pub const INSN_LEN_COMPRESSED: u8 = 2;
pub const INSN_LEN_STANDARD: u8 = 4;
pub const RVC_QUADRANT_MASK: u32 = 0x3;
pub const RVC_QUADRANT_32BIT: u32 = 0x3;

pub const LoadType = struct { rd: u5, rs1: u5, offset: i32 };
pub const BType = struct { rs1: u5, rs2: u5, offset: i32 };
pub const StoreType = BType;
pub const CsrRType = struct { rd: u5, rs1: u5, csr: u12 };
pub const CsrIType = struct { rd: u5, uimm: u5, csr: u12 };
pub const LrType = struct { rd: u5, rs1: u5, aq: u1, rl: u1 };
pub const AmoType = struct { rd: u5, rs1: u5, rs2: u5, aq: u1, rl: u1 };

/// Parsed RV32 instruction representation.
pub const Instruction = union(enum) {
    // R-Type instructions.
    add: struct { rd: u5, rs1: u5, rs2: u5 },
    sub: struct { rd: u5, rs1: u5, rs2: u5 },
    sll: struct { rd: u5, rs1: u5, rs2: u5 },
    slt: struct { rd: u5, rs1: u5, rs2: u5 },
    sltu: struct { rd: u5, rs1: u5, rs2: u5 },
    xor_: struct { rd: u5, rs1: u5, rs2: u5 },
    srl: struct { rd: u5, rs1: u5, rs2: u5 },
    sra: struct { rd: u5, rs1: u5, rs2: u5 },
    or_: struct { rd: u5, rs1: u5, rs2: u5 },
    and_: struct { rd: u5, rs1: u5, rs2: u5 },
    mul: struct { rd: u5, rs1: u5, rs2: u5 },
    mulh: struct { rd: u5, rs1: u5, rs2: u5 },
    mulhsu: struct { rd: u5, rs1: u5, rs2: u5 },
    mulhu: struct { rd: u5, rs1: u5, rs2: u5 },
    div: struct { rd: u5, rs1: u5, rs2: u5 },
    divu: struct { rd: u5, rs1: u5, rs2: u5 },
    rem: struct { rd: u5, rs1: u5, rs2: u5 },
    remu: struct { rd: u5, rs1: u5, rs2: u5 },

    // I-Type instructions.
    addi: struct { rd: u5, rs1: u5, imm: i32 },
    slti: struct { rd: u5, rs1: u5, imm: i32 },
    sltiu: struct { rd: u5, rs1: u5, imm: i32 },
    xori: struct { rd: u5, rs1: u5, imm: i32 },
    ori: struct { rd: u5, rs1: u5, imm: i32 },
    andi: struct { rd: u5, rs1: u5, imm: i32 },
    slli: struct { rd: u5, rs1: u5, shamt: u5 },
    srli: struct { rd: u5, rs1: u5, shamt: u5 },
    srai: struct { rd: u5, rs1: u5, shamt: u5 },

    // Loads.
    lb: LoadType,
    lh: LoadType,
    lw: LoadType,
    lbu: LoadType,
    lhu: LoadType,

    // Stores.
    sb: StoreType,
    sh: StoreType,
    sw: StoreType,

    // Branches.
    beq: BType,
    bne: BType,
    blt: BType,
    bge: BType,
    bltu: BType,
    bgeu: BType,

    // Jump & Link.
    jal: struct { rd: u5, offset: i32 },
    jalr: LoadType,

    // Upper Immediates.
    lui: struct { rd: u5, imm: i32 },
    auipc: struct { rd: u5, imm: i32 },

    // System & Traps.
    ecall,
    ebreak,
    fence,
    fence_i,
    pause,
    mret,
    sret,
    wfi,
    sfence_vma: struct { rs1: u5, rs2: u5 },

    // CSR instructions.
    csrrw: CsrRType,
    csrrs: CsrRType,
    csrrc: CsrRType,
    csrrwi: CsrIType,
    csrrsi: CsrIType,
    csrrci: CsrIType,

    // Atomic instructions (A-extension).
    lr_w: LrType,
    sc_w: AmoType,
    amoswap_w: AmoType,
    amoadd_w: AmoType,
    amoxor_w: AmoType,
    amoand_w: AmoType,
    amoor_w: AmoType,
    amomin_w: AmoType,
    amomax_w: AmoType,
    amominu_w: AmoType,
    amomaxu_w: AmoType,

    // Floating-Point instructions (F/D extensions).
    flw: LoadType,
    fld: LoadType,
    fsw: StoreType,
    fsd: StoreType,
    fp_op: struct { raw: u32 },

    // Vector instructions.
    vsetvli: struct { rd: u5, rs1: u5, vtype: u12 },
    vload: struct { vd: u5, rs1: u5, width: u3 },
    vstore: struct { vs3: u5, rs1: u5, width: u3 },
    vector_op: struct { rd: u5, rs1: u5, rs2: u5 },

    unknown: u32,
};

pub const DecodedInsn = struct {
    insn: Instruction,
    len: u8, // 2 for 16-bit compressed instruction, 4 for standard 32-bit.
};

/// Sign-extend a bit field of length `bits` to `i32`.
pub fn signExtend(val: u32, bits: u6) i32 {
    const shift: u5 = @truncate(32 - bits);
    const signed_val = @as(i32, @bitCast(val << shift));
    return signed_val >> shift;
}

/// Extract sign-extended 12-bit I-type immediate from 32-bit instruction.
pub fn decodeIImm(code: u32) i32 {
    return signExtend((code >> 20) & 0xfff, 12);
}

/// Extract sign-extended 12-bit S-type immediate from 32-bit instruction.
pub fn decodeSImm(code: u32) i32 {
    return signExtend(
        ((code >> 7) & 0x1f) | (((code >> 25) & 0x7f) << 5),
        12,
    );
}

/// Extract sign-extended 13-bit B-type immediate from 32-bit instruction.
pub fn decodeBImm(code: u32) i32 {
    return signExtend(
        (((code >> 8) & 0xf) << 1) |
            (((code >> 25) & 0x3f) << 5) |
            (((code >> 7) & 0x1) << 11) |
            (((code >> 31) & 0x1) << 12),
        13,
    );
}

/// Extract sign-extended 20-bit U-type immediate from 32-bit instruction.
pub fn decodeUImm(code: u32) i32 {
    return signExtend((code >> 12) & 0xfffff, 20);
}

/// Extract sign-extended 21-bit J-type immediate from 32-bit instruction.
pub fn decodeJImm(code: u32) i32 {
    return signExtend(
        (((code >> 21) & 0x3ff) << 1) |
            (((code >> 20) & 0x1) << 11) |
            (((code >> 12) & 0xff) << 12) |
            (((code >> 31) & 0x1) << 20),
        21,
    );
}

test "RV32 immediate extraction and sign extension" {
    try std.testing.expectEqual(@as(i32, -16), signExtend(0xff0, 12));
    try std.testing.expectEqual(@as(i32, -16), decodeIImm(0xff010113));
    std.testing.refAllDecls(@This());
}
