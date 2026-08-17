// RV32 Instruction Decoder & Bitfield Unpacker for Diosix Hypervisor
//
// Decodes 32-bit RV32I instructions and handles 16-bit RV32C compressed
// instruction decompression.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

/// Parsed RV32 instruction representation
pub const Instruction = union(enum) {
    // R-Type instructions
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

    // I-Type instructions
    addi: struct { rd: u5, rs1: u5, imm: i32 },
    slti: struct { rd: u5, rs1: u5, imm: i32 },
    sltiu: struct { rd: u5, rs1: u5, imm: i32 },
    xori: struct { rd: u5, rs1: u5, imm: i32 },
    ori: struct { rd: u5, rs1: u5, imm: i32 },
    andi: struct { rd: u5, rs1: u5, imm: i32 },
    slli: struct { rd: u5, rs1: u5, shamt: u5 },
    srli: struct { rd: u5, rs1: u5, shamt: u5 },
    srai: struct { rd: u5, rs1: u5, shamt: u5 },

    // Loads
    lb: struct { rd: u5, rs1: u5, offset: i32 },
    lh: struct { rd: u5, rs1: u5, offset: i32 },
    lw: struct { rd: u5, rs1: u5, offset: i32 },
    lbu: struct { rd: u5, rs1: u5, offset: i32 },
    lhu: struct { rd: u5, rs1: u5, offset: i32 },

    // Stores
    sb: struct { rs1: u5, rs2: u5, offset: i32 },
    sh: struct { rs1: u5, rs2: u5, offset: i32 },
    sw: struct { rs1: u5, rs2: u5, offset: i32 },

    // Branches
    beq: struct { rs1: u5, rs2: u5, offset: i32 },
    bne: struct { rs1: u5, rs2: u5, offset: i32 },
    blt: struct { rs1: u5, rs2: u5, offset: i32 },
    bge: struct { rs1: u5, rs2: u5, offset: i32 },
    bltu: struct { rs1: u5, rs2: u5, offset: i32 },
    bgeu: struct { rs1: u5, rs2: u5, offset: i32 },

    // Jump & Link
    jal: struct { rd: u5, offset: i32 },
    jalr: struct { rd: u5, rs1: u5, offset: i32 },

    // Upper Immediates
    lui: struct { rd: u5, imm: i32 },
    auipc: struct { rd: u5, imm: i32 },

    // System & Traps
    ecall,
    ebreak,
    fence,
    fence_i,
    pause,
    mret,
    sret,
    wfi,
    sfence_vma: struct { rs1: u5, rs2: u5 },

    // CSR instructions
    csrrw: struct { rd: u5, rs1: u5, csr: u12 },
    csrrs: struct { rd: u5, rs1: u5, csr: u12 },
    csrrc: struct { rd: u5, rs1: u5, csr: u12 },
    csrrwi: struct { rd: u5, uimm: u5, csr: u12 },
    csrrsi: struct { rd: u5, uimm: u5, csr: u12 },
    csrrci: struct { rd: u5, uimm: u5, csr: u12 },

    // Atomic instructions (A-extension)
    lr_w: struct { rd: u5, rs1: u5, aq: u1, rl: u1 },
    sc_w: struct { rd: u5, rs1: u5, rs2: u5, aq: u1, rl: u1 },
    amoswap_w: struct { rd: u5, rs1: u5, rs2: u5, aq: u1, rl: u1 },
    amoadd_w: struct { rd: u5, rs1: u5, rs2: u5, aq: u1, rl: u1 },
    amoxor_w: struct { rd: u5, rs1: u5, rs2: u5, aq: u1, rl: u1 },
    amoand_w: struct { rd: u5, rs1: u5, rs2: u5, aq: u1, rl: u1 },
    amoor_w: struct { rd: u5, rs1: u5, rs2: u5, aq: u1, rl: u1 },
    amomin_w: struct { rd: u5, rs1: u5, rs2: u5, aq: u1, rl: u1 },
    amomax_w: struct { rd: u5, rs1: u5, rs2: u5, aq: u1, rl: u1 },
    amominu_w: struct { rd: u5, rs1: u5, rs2: u5, aq: u1, rl: u1 },
    amomaxu_w: struct { rd: u5, rs1: u5, rs2: u5, aq: u1, rl: u1 },

    // Floating-Point instructions (F/D extensions)
    flw: struct { rd: u5, rs1: u5, offset: i32 },
    fld: struct { rd: u5, rs1: u5, offset: i32 },
    fsw: struct { rs1: u5, rs2: u5, offset: i32 },
    fsd: struct { rs1: u5, rs2: u5, offset: i32 },
    fp_op: struct { raw: u32 },

    // Vector instructions
    vsetvli: struct { rd: u5, rs1: u5, vtype: u12 },
    vload: struct { vd: u5, rs1: u5, width: u3 },
    vstore: struct { vs3: u5, rs1: u5, width: u3 },
    vector_op: struct { rd: u5, rs1: u5, rs2: u5 },

    unknown: u32,
};


pub const DecodedInsn = struct {
    insn: Instruction,
    len: u8, // 2 for 16-bit compressed instruction, 4 for standard 32-bit
};

/// Sign-extend a bit field of length `bits` to `i32`
fn signExtend(val: u32, bits: u6) i32 {
    const shift: u5 = @truncate(32 - bits);
    const signed_val = @as(i32, @bitCast(val << shift));
    return signed_val >> shift;
}

/// Decompress 16-bit RV32C compressed instruction to standard 32-bit instruction encoding
pub fn decompressRvc(code16: u16) ?u32 {
    const op = code16 & 0x3;
    const funct3 = (code16 >> 13) & 0x7;

    return switch (op) {
        0b00 => switch (funct3) {
            0b000 => {
                // C.ADDI4SPN
                const nzuimm: u32 = (((code16 >> 6) & 1) << 2) |
                                    (((code16 >> 5) & 1) << 3) |
                                    (((code16 >> 11) & 3) << 4) |
                                    (((code16 >> 7) & 15) << 6);
                const rd = @as(u5, @truncate((code16 >> 2) & 0x7)) + 8;
                if (nzuimm == 0) return null;
                // addi rd, x2, nzuimm
                return 0x13 | (@as(u32, rd) << 7) | (2 << 15) | (@as(u32, nzuimm) << 20);
            },
            0b001 => {
                // C.FLD
                const offset: u32 = (((code16 >> 10) & 7) << 3) |
                                    (((code16 >> 5) & 3) << 6);
                const rs1 = @as(u5, @truncate((code16 >> 7) & 0x7)) + 8;
                const rd = @as(u5, @truncate((code16 >> 2) & 0x7)) + 8;
                // fld rd, offset(rs1)
                return 0x07 | (@as(u32, rd) << 7) | (0x3 << 12) | (@as(u32, rs1) << 15) | (offset << 20);
            },
            0b010 => {
                // C.LW
                const offset: u32 = (((code16 >> 6) & 1) << 2) |
                                    (((code16 >> 10) & 7) << 3) |
                                    (((code16 >> 5) & 1) << 6);
                const rs1 = @as(u5, @truncate((code16 >> 7) & 0x7)) + 8;
                const rd = @as(u5, @truncate((code16 >> 2) & 0x7)) + 8;
                // lw rd, offset(rs1)
                return 0x03 | (@as(u32, rd) << 7) | (0x2 << 12) | (@as(u32, rs1) << 15) | (offset << 20);
            },
            0b011 => {
                // C.FLW (in RV32)
                const offset: u32 = (((code16 >> 6) & 1) << 2) |
                                    (((code16 >> 10) & 7) << 3) |
                                    (((code16 >> 5) & 1) << 6);
                const rs1 = @as(u5, @truncate((code16 >> 7) & 0x7)) + 8;
                const rd = @as(u5, @truncate((code16 >> 2) & 0x7)) + 8;
                // flw rd, offset(rs1)
                return 0x07 | (@as(u32, rd) << 7) | (0x2 << 12) | (@as(u32, rs1) << 15) | (offset << 20);
            },
            0b101 => {
                // C.FSD
                const offset: u32 = (((code16 >> 10) & 7) << 3) |
                                    (((code16 >> 5) & 3) << 6);
                const rs1 = @as(u5, @truncate((code16 >> 7) & 0x7)) + 8;
                const rs2 = @as(u5, @truncate((code16 >> 2) & 0x7)) + 8;
                // fsd rs2, offset(rs1)
                const imm5 = offset & 0x1F;
                const imm7 = (offset >> 5) & 0x7F;
                return 0x27 | (imm5 << 7) | (0x3 << 12) | (@as(u32, rs1) << 15) | (@as(u32, rs2) << 20) | (imm7 << 25);
            },
            0b110 => {
                // C.SW
                const offset: u32 = (((code16 >> 6) & 1) << 2) |
                                    (((code16 >> 10) & 7) << 3) |
                                    (((code16 >> 5) & 1) << 6);
                const rs1 = @as(u5, @truncate((code16 >> 7) & 0x7)) + 8;
                const rs2 = @as(u5, @truncate((code16 >> 2) & 0x7)) + 8;
                // sw rs2, offset(rs1)
                const imm5 = offset & 0x1F;
                const imm7 = (offset >> 5) & 0x7F;
                return 0x23 | (imm5 << 7) | (0x2 << 12) | (@as(u32, rs1) << 15) | (@as(u32, rs2) << 20) | (imm7 << 25);
            },
            0b111 => {
                // C.FSW (in RV32)
                const offset: u32 = (((code16 >> 6) & 1) << 2) |
                                    (((code16 >> 10) & 7) << 3) |
                                    (((code16 >> 5) & 1) << 6);
                const rs1 = @as(u5, @truncate((code16 >> 7) & 0x7)) + 8;
                const rs2 = @as(u5, @truncate((code16 >> 2) & 0x7)) + 8;
                // fsw rs2, offset(rs1)
                const imm5 = offset & 0x1F;
                const imm7 = (offset >> 5) & 0x7F;
                return 0x27 | (imm5 << 7) | (0x2 << 12) | (@as(u32, rs1) << 15) | (@as(u32, rs2) << 20) | (imm7 << 25);
            },
            else => return null,
        },

        0b01 => switch (funct3) {
            0b000 => {
                // C.NOP / C.ADDI
                const rd = @as(u5, @truncate((code16 >> 7) & 0x1F));
                const imm6 = ((code16 >> 2) & 0x1F) | (((code16 >> 12) & 0x1) << 5);
                const imm = signExtend(imm6, 6);
                const uimm = @as(u32, @bitCast(imm)) & 0xFFF;
                return 0x13 | (@as(u32, rd) << 7) | (@as(u32, rd) << 15) | (uimm << 20);
            },
            0b001 => {
                // C.JAL
                const offset: u32 = (((code16 >> 3) & 7) << 1) |
                                    (((code16 >> 11) & 1) << 4) |
                                    (((code16 >> 2) & 1) << 5) |
                                    (((code16 >> 7) & 1) << 6) |
                                    (((code16 >> 6) & 1) << 7) |
                                    (((code16 >> 9) & 3) << 8) |
                                    (((code16 >> 8) & 1) << 10) |
                                    (((code16 >> 12) & 1) << 11);
                const imm = signExtend(offset, 12);
                const uimm = @as(u32, @bitCast(imm)) & 0x1FFFFF;
                const imm20: u32 = (uimm >> 20) & 1;
                const imm10_1: u32 = (uimm >> 1) & 0x3FF;
                const imm11: u32 = (uimm >> 11) & 1;
                const imm19_12: u32 = (uimm >> 12) & 0xFF;
                // jal x1, offset
                return 0x6F | (1 << 7) | (imm19_12 << 12) | (imm11 << 20) | (imm10_1 << 21) | (imm20 << 31);
            },
            0b010 => {
                // C.LI
                const rd = @as(u5, @truncate((code16 >> 7) & 0x1F));
                const imm6 = ((code16 >> 2) & 0x1F) | (((code16 >> 12) & 0x1) << 5);
                const imm = signExtend(imm6, 6);
                const uimm = @as(u32, @bitCast(imm)) & 0xFFF;
                // addi rd, x0, imm
                return 0x13 | (@as(u32, rd) << 7) | (0 << 15) | (uimm << 20);
            },
            0b011 => {
                const rd = @as(u5, @truncate((code16 >> 7) & 0x1F));
                if (rd == 2) {
                    // C.ADDI16SP
                    const offset: u32 = (((code16 >> 6) & 1) << 4) |
                                        (((code16 >> 2) & 1) << 5) |
                                        (((code16 >> 5) & 1) << 6) |
                                        (((code16 >> 3) & 3) << 7) |
                                        (((code16 >> 4) & 1) << 8) |
                                        (((code16 >> 12) & 1) << 9);
                    const imm = signExtend(offset, 10);
                    const uimm = @as(u32, @bitCast(imm)) & 0xFFF;
                    return 0x13 | (2 << 7) | (2 << 15) | (uimm << 20);
                } else {
                    // C.LUI
                    const imm6 = ((code16 >> 2) & 0x1F) | (((code16 >> 12) & 0x1) << 5);
                    const imm = signExtend(imm6, 6);
                    const uimm = @as(u32, @bitCast(imm)) & 0xFFFFF;
                    return 0x37 | (@as(u32, rd) << 7) | (uimm << 12);
                }
            },
            0b100 => {
                const funct2 = @as(u2, @truncate((code16 >> 10) & 0x3));
                const rd = @as(u5, @truncate((code16 >> 7) & 0x7)) + 8;
                switch (funct2) {
                    0b00 => {
                        // C.SRLI: srli rd', rd', shamt
                        const shamt: u32 = ((code16 >> 2) & 0x1F) | (((code16 >> 12) & 0x1) << 5);
                        return 0x13 | (@as(u32, rd) << 7) | (0x5 << 12) | (@as(u32, rd) << 15) | (shamt << 20);
                    },
                    0b01 => {
                        // C.SRAI: srai rd', rd', shamt
                        const shamt: u32 = ((code16 >> 2) & 0x1F) | (((code16 >> 12) & 0x1) << 5);
                        return 0x13 | (@as(u32, rd) << 7) | (0x5 << 12) | (@as(u32, rd) << 15) | (shamt << 20) | (0x20 << 25);
                    },
                    0b10 => {
                        // C.ANDI: andi rd', rd', imm
                        const imm6 = ((code16 >> 2) & 0x1F) | (((code16 >> 12) & 0x1) << 5);
                        const imm = signExtend(imm6, 6);
                        const uimm = @as(u32, @bitCast(imm)) & 0xFFF;
                        return 0x13 | (@as(u32, rd) << 7) | (0x7 << 12) | (@as(u32, rd) << 15) | (uimm << 20);
                    },
                    0b11 => {
                        const rs2 = @as(u5, @truncate((code16 >> 2) & 0x7)) + 8;
                        const sub_op = (code16 >> 5) & 0x3;
                        return switch (sub_op) {
                            0b00 => 0x33 | (@as(u32, rd) << 7) | (0x0 << 12) | (@as(u32, rd) << 15) | (@as(u32, rs2) << 20) | (0x20 << 25), // sub
                            0b01 => 0x33 | (@as(u32, rd) << 7) | (0x4 << 12) | (@as(u32, rd) << 15) | (@as(u32, rs2) << 20), // xor
                            0b10 => 0x33 | (@as(u32, rd) << 7) | (0x6 << 12) | (@as(u32, rd) << 15) | (@as(u32, rs2) << 20), // or
                            0b11 => 0x33 | (@as(u32, rd) << 7) | (0x7 << 12) | (@as(u32, rd) << 15) | (@as(u32, rs2) << 20), // and
                            else => null,
                        };
                    },
                }
            },
            0b101 => {
                // C.J
                const offset: u32 = (((code16 >> 3) & 7) << 1) |
                                    (((code16 >> 11) & 1) << 4) |
                                    (((code16 >> 2) & 1) << 5) |
                                    (((code16 >> 7) & 1) << 6) |
                                    (((code16 >> 6) & 1) << 7) |
                                    (((code16 >> 9) & 3) << 8) |
                                    (((code16 >> 8) & 1) << 10) |
                                    (((code16 >> 12) & 1) << 11);
                const imm = signExtend(offset, 12);
                const uimm = @as(u32, @bitCast(imm)) & 0x1FFFFF;
                const imm20: u32 = (uimm >> 20) & 1;
                const imm10_1: u32 = (uimm >> 1) & 0x3FF;
                const imm11: u32 = (uimm >> 11) & 1;
                const imm19_12: u32 = (uimm >> 12) & 0xFF;
                // jal x0, offset
                return 0x6F | (0 << 7) | (imm19_12 << 12) | (imm11 << 20) | (imm10_1 << 21) | (imm20 << 31);
            },
            0b110 => {
                // C.BEQZ
                const offset: u32 = (((code16 >> 3) & 3) << 1) |
                                    (((code16 >> 10) & 3) << 3) |
                                    (((code16 >> 2) & 1) << 5) |
                                    (((code16 >> 5) & 3) << 6) |
                                    (((code16 >> 12) & 1) << 8);
                const rs1 = @as(u5, @truncate((code16 >> 7) & 0x7)) + 8;
                const imm = signExtend(offset, 9);
                const uimm = @as(u32, @bitCast(imm)) & 0x1FFF;
                const imm11: u32 = (uimm >> 11) & 1;
                const imm4_1: u32 = (uimm >> 1) & 0xF;
                const imm10_5: u32 = (uimm >> 5) & 0x3F;
                const imm12: u32 = (uimm >> 12) & 1;
                // beq rs1, x0, offset
                return 0x63 | (imm11 << 7) | (imm4_1 << 8) | (@as(u32, rs1) << 15) | (0 << 20) | (imm10_5 << 25) | (imm12 << 31);
            },
            0b111 => {
                // C.BNEZ
                const offset: u32 = (((code16 >> 3) & 3) << 1) |
                                    (((code16 >> 10) & 3) << 3) |
                                    (((code16 >> 2) & 1) << 5) |
                                    (((code16 >> 5) & 3) << 6) |
                                    (((code16 >> 12) & 1) << 8);
                const rs1 = @as(u5, @truncate((code16 >> 7) & 0x7)) + 8;
                const imm = signExtend(offset, 9);
                const uimm = @as(u32, @bitCast(imm)) & 0x1FFF;
                const imm11: u32 = (uimm >> 11) & 1;
                const imm4_1: u32 = (uimm >> 1) & 0xF;
                const imm10_5: u32 = (uimm >> 5) & 0x3F;
                const imm12: u32 = (uimm >> 12) & 1;
                // bne rs1, x0, offset
                return 0x63 | (imm11 << 7) | (imm4_1 << 8) | (0x1 << 12) | (@as(u32, rs1) << 15) | (0 << 20) | (imm10_5 << 25) | (imm12 << 31);
            },
            else => return null,
        },
        0b10 => switch (funct3) {
            0b000 => {
                // C.SLLI
                const rd = @as(u5, @truncate((code16 >> 7) & 0x1F));
                const shamt: u32 = ((code16 >> 2) & 0x1F) | (((code16 >> 12) & 0x1) << 5);
                // slli rd, rd, shamt
                return 0x13 | (@as(u32, rd) << 7) | (0x1 << 12) | (@as(u32, rd) << 15) | (shamt << 20);
            },
            0b001 => {
                // C.FLDSP
                const rd = @as(u5, @truncate((code16 >> 7) & 0x1F));
                const offset: u32 = (((code16 >> 5) & 3) << 3) |
                                    (((code16 >> 12) & 1) << 5) |
                                    (((code16 >> 2) & 7) << 6);
                // fld rd, offset(x2)
                return 0x07 | (@as(u32, rd) << 7) | (0x3 << 12) | (2 << 15) | (offset << 20);
            },
            0b010 => {
                // C.LWSP
                const rd = @as(u5, @truncate((code16 >> 7) & 0x1F));
                const offset: u32 = (((code16 >> 4) & 7) << 2) |
                                    (((code16 >> 12) & 1) << 5) |
                                    (((code16 >> 2) & 3) << 6);
                // lw rd, offset(x2)
                return 0x03 | (@as(u32, rd) << 7) | (0x2 << 12) | (2 << 15) | (offset << 20);
            },
            0b011 => {
                // C.FLWSP (in RV32)
                const rd = @as(u5, @truncate((code16 >> 7) & 0x1F));
                const offset: u32 = (((code16 >> 4) & 7) << 2) |
                                    (((code16 >> 12) & 1) << 5) |
                                    (((code16 >> 2) & 3) << 6);
                // flw rd, offset(x2)
                return 0x07 | (@as(u32, rd) << 7) | (0x2 << 12) | (2 << 15) | (offset << 20);
            },
            0b100 => {
                const bit12 = (code16 >> 12) & 0x1;
                const rs1 = @as(u5, @truncate((code16 >> 7) & 0x1F));
                const rs2 = @as(u5, @truncate((code16 >> 2) & 0x1F));
                if (bit12 == 0) {
                    if (rs2 == 0) {
                        // C.JR (jalr x0, rs1, 0)
                        return 0x67 | (0 << 7) | (@as(u32, rs1) << 15) | (0 << 20);
                    } else {
                        // C.MV (add rd, x0, rs2)
                        return 0x33 | (@as(u32, rs1) << 7) | (0 << 15) | (@as(u32, rs2) << 20);
                    }
                } else {
                    if (rs1 == 0 and rs2 == 0) {
                        // C.EBREAK (ebreak)
                        return 0x00100073;
                    } else if (rs2 == 0) {
                        // C.JALR (jalr x1, rs1, 0)
                        return 0x67 | (1 << 7) | (@as(u32, rs1) << 15) | (0 << 20);
                    } else {
                        // C.ADD (add rd, rd, rs2)
                        return 0x33 | (@as(u32, rs1) << 7) | (@as(u32, rs1) << 15) | (@as(u32, rs2) << 20);
                    }
                }
            },
            0b101 => {
                // C.FSDSP
                const rs2 = @as(u5, @truncate((code16 >> 2) & 0x1F));
                const offset: u32 = (((code16 >> 10) & 7) << 3) |
                                    (((code16 >> 7) & 7) << 6);
                const imm5: u32 = offset & 0x1F;
                const imm7: u32 = (offset >> 5) & 0x7F;
                // fsd rs2, offset(x2)
                return 0x27 | (imm5 << 7) | (0x3 << 12) | (@as(u32, 2) << 15) | (@as(u32, rs2) << 20) | (imm7 << 25);
            },
            0b110 => {
                // C.SWSP
                const rs2 = @as(u5, @truncate((code16 >> 2) & 0x1F));
                const offset: u32 = (((code16 >> 9) & 15) << 2) |
                                    (((code16 >> 7) & 3) << 6);
                const imm5: u32 = offset & 0x1F;
                const imm7: u32 = (offset >> 5) & 0x7F;
                // sw rs2, offset(x2)
                return 0x23 | (imm5 << 7) | (0x2 << 12) | (@as(u32, 2) << 15) | (@as(u32, rs2) << 20) | (imm7 << 25);
            },
            0b111 => {
                // C.FSWSP (in RV32)
                const rs2 = @as(u5, @truncate((code16 >> 2) & 0x1F));
                const offset: u32 = (((code16 >> 9) & 15) << 2) |
                                    (((code16 >> 7) & 3) << 6);
                const imm5: u32 = offset & 0x1F;
                const imm7: u32 = (offset >> 5) & 0x7F;
                // fsw rs2, offset(x2)
                return 0x27 | (imm5 << 7) | (0x2 << 12) | (@as(u32, 2) << 15) | (@as(u32, rs2) << 20) | (imm7 << 25);
            },
            else => return null,
        },

        else => return null,
    };
}

/// Main entry point: Decode standard 32-bit RV32I or decompressed 16-bit RV32C instruction
pub fn decode(raw_code: u32) DecodedInsn {
    var code = raw_code;
    var len: u8 = 4;

    // Check if 16-bit compressed instruction (bits [1:0] != 0b11)
    if ((code & 0x3) != 0x3) {
        if (decompressRvc(@as(u16, @truncate(code)))) |decompressed| {
            code = decompressed;
            len = 2;
        } else {
            return .{ .insn = .{ .unknown = code }, .len = 2 };
        }
    }

    const opcode = code & 0x7F;
    const rd = @as(u5, @truncate((code >> 7) & 0x1F));
    const funct3 = @as(u3, @truncate((code >> 12) & 0x7));
    const rs1 = @as(u5, @truncate((code >> 15) & 0x1F));
    const rs2 = @as(u5, @truncate((code >> 20) & 0x1F));
    const funct7 = @as(u7, @truncate((code >> 25) & 0x7F));

    const i_imm = signExtend((code >> 20) & 0xFFF, 12);
    const s_imm = signExtend(((code >> 7) & 0x1F) | (((code >> 25) & 0x7F) << 5), 12);
    const b_imm = signExtend(
        (((code >> 8) & 0xF) << 1) |
            (((code >> 25) & 0x3F) << 5) |
            (((code >> 7) & 0x1) << 11) |
            (((code >> 31) & 0x1) << 12),
        13,
    );
    const u_imm = signExtend((code >> 12) & 0xFFFFF, 20);
    const j_imm = signExtend(
        (((code >> 21) & 0x3FF) << 1) |
            (((code >> 20) & 0x1) << 11) |
            (((code >> 12) & 0xFF) << 12) |
            (((code >> 31) & 0x1) << 20),
        21,
    );

    const parsed: Instruction = switch (opcode) {
        0x33 => switch (funct3) {
            0x0 => if (funct7 == 0x20) .{ .sub = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } } else if (funct7 == 0x01) .{ .mul = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } } else .{ .add = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } },
            0x1 => if (funct7 == 0x01) .{ .mulh = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } } else .{ .sll = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } },
            0x2 => if (funct7 == 0x01) .{ .mulhsu = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } } else .{ .slt = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } },
            0x3 => if (funct7 == 0x01) .{ .mulhu = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } } else .{ .sltu = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } },
            0x4 => if (funct7 == 0x01) .{ .div = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } } else .{ .xor_ = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } },
            0x5 => if (funct7 == 0x20) .{ .sra = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } } else if (funct7 == 0x01) .{ .divu = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } } else .{ .srl = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } },
            0x6 => if (funct7 == 0x01) .{ .rem = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } } else .{ .or_ = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } },
            0x7 => if (funct7 == 0x01) .{ .remu = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } } else .{ .and_ = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } },
        },
        0x13 => switch (funct3) {
            0x0 => .{ .addi = .{ .rd = rd, .rs1 = rs1, .imm = i_imm } },
            0x1 => .{ .slli = .{ .rd = rd, .rs1 = rs1, .shamt = @truncate(rs2) } },
            0x2 => .{ .slti = .{ .rd = rd, .rs1 = rs1, .imm = i_imm } },
            0x3 => .{ .sltiu = .{ .rd = rd, .rs1 = rs1, .imm = i_imm } },
            0x4 => .{ .xori = .{ .rd = rd, .rs1 = rs1, .imm = i_imm } },
            0x5 => if (funct7 == 0x20) .{ .srai = .{ .rd = rd, .rs1 = rs1, .shamt = @truncate(rs2) } } else .{ .srli = .{ .rd = rd, .rs1 = rs1, .shamt = @truncate(rs2) } },
            0x6 => .{ .ori = .{ .rd = rd, .rs1 = rs1, .imm = i_imm } },
            0x7 => .{ .andi = .{ .rd = rd, .rs1 = rs1, .imm = i_imm } },
        },
        0x03 => switch (funct3) {
            0x0 => .{ .lb = .{ .rd = rd, .rs1 = rs1, .offset = i_imm } },
            0x1 => .{ .lh = .{ .rd = rd, .rs1 = rs1, .offset = i_imm } },
            0x2 => .{ .lw = .{ .rd = rd, .rs1 = rs1, .offset = i_imm } },
            0x4 => .{ .lbu = .{ .rd = rd, .rs1 = rs1, .offset = i_imm } },
            0x5 => .{ .lhu = .{ .rd = rd, .rs1 = rs1, .offset = i_imm } },
            else => .{ .unknown = code },
        },
        0x07 => switch (funct3) {
            0x2 => .{ .flw = .{ .rd = rd, .rs1 = rs1, .offset = i_imm } },
            0x3 => .{ .fld = .{ .rd = rd, .rs1 = rs1, .offset = i_imm } },
            else => .{ .vload = .{ .vd = rd, .rs1 = rs1, .width = funct3 } },
        },
        0x23 => switch (funct3) {
            0x0 => .{ .sb = .{ .rs1 = rs1, .rs2 = rs2, .offset = s_imm } },
            0x1 => .{ .sh = .{ .rs1 = rs1, .rs2 = rs2, .offset = s_imm } },
            0x2 => .{ .sw = .{ .rs1 = rs1, .rs2 = rs2, .offset = s_imm } },
            else => .{ .unknown = code },
        },
        0x27 => switch (funct3) {
            0x2 => .{ .fsw = .{ .rs1 = rs1, .rs2 = rs2, .offset = s_imm } },
            0x3 => .{ .fsd = .{ .rs1 = rs1, .rs2 = rs2, .offset = s_imm } },
            else => .{ .vstore = .{ .vs3 = rd, .rs1 = rs1, .width = funct3 } },
        },
        0x53, 0x43, 0x47, 0x4B, 0x4F => .{ .fp_op = .{ .raw = code } },


        0x63 => switch (funct3) {
            0x0 => .{ .beq = .{ .rs1 = rs1, .rs2 = rs2, .offset = b_imm } },
            0x1 => .{ .bne = .{ .rs1 = rs1, .rs2 = rs2, .offset = b_imm } },
            0x4 => .{ .blt = .{ .rs1 = rs1, .rs2 = rs2, .offset = b_imm } },
            0x5 => .{ .bge = .{ .rs1 = rs1, .rs2 = rs2, .offset = b_imm } },
            0x6 => .{ .bltu = .{ .rs1 = rs1, .rs2 = rs2, .offset = b_imm } },
            0x7 => .{ .bgeu = .{ .rs1 = rs1, .rs2 = rs2, .offset = b_imm } },
            else => .{ .unknown = code },
        },
        0x6F => .{ .jal = .{ .rd = rd, .offset = j_imm } },
        0x67 => .{ .jalr = .{ .rd = rd, .rs1 = rs1, .offset = i_imm } },
        0x37 => .{ .lui = .{ .rd = rd, .imm = u_imm } },
        0x17 => .{ .auipc = .{ .rd = rd, .imm = u_imm } },
        0x73 => switch (funct3) {
            0x0 => switch (i_imm >> 5) {
                0x000 => switch (i_imm & 0x1F) {
                    0x00 => .ecall,
                    0x01 => .ebreak,
                    else => .{ .unknown = code },
                },
                0x008 => switch (i_imm & 0x1F) {
                    0x02 => .sret,
                    0x05 => .wfi,
                    else => .{ .unknown = code },
                },
                0x018 => switch (i_imm & 0x1F) {
                    0x02 => .mret,
                    else => .{ .unknown = code },
                },
                0x009 => .{ .sfence_vma = .{ .rs1 = rs1, .rs2 = rs2 } },
                else => .{ .unknown = code },
            },
            0x1 => .{ .csrrw = .{ .rd = rd, .rs1 = rs1, .csr = @truncate(@as(u32, @bitCast(i_imm))) } },
            0x2 => .{ .csrrs = .{ .rd = rd, .rs1 = rs1, .csr = @truncate(@as(u32, @bitCast(i_imm))) } },
            0x3 => .{ .csrrc = .{ .rd = rd, .rs1 = rs1, .csr = @truncate(@as(u32, @bitCast(i_imm))) } },
            0x5 => .{ .csrrwi = .{ .rd = rd, .uimm = rs1, .csr = @truncate(@as(u32, @bitCast(i_imm))) } },
            0x6 => .{ .csrrsi = .{ .rd = rd, .uimm = rs1, .csr = @truncate(@as(u32, @bitCast(i_imm))) } },
            0x7 => .{ .csrrci = .{ .rd = rd, .uimm = rs1, .csr = @truncate(@as(u32, @bitCast(i_imm))) } },
            else => .{ .unknown = code },
        },
        0x0F => switch (funct3) {
            0x0 => if (code == 0x0100000F) .pause else .fence,
            0x1 => .fence_i,
            else => .{ .unknown = code },
        },
        0x57 => switch (funct3) {

            0x7 => .{ .vsetvli = .{ .rd = rd, .rs1 = rs1, .vtype = @truncate(@as(u32, @bitCast(i_imm))) } },
            else => .{ .vector_op = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } },
        },
        0x2F => {
            const funct5 = @as(u5, @truncate((code >> 27) & 0x1F));
            const aq = @as(u1, @truncate((code >> 26) & 0x1));
            const rl = @as(u1, @truncate((code >> 25) & 0x1));
            return switch (funct5) {
                0x01 => .{ .insn = .{ .amoswap_w = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2, .aq = aq, .rl = rl } }, .len = len },
                0x00 => .{ .insn = .{ .amoadd_w = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2, .aq = aq, .rl = rl } }, .len = len },
                0x02 => .{ .insn = .{ .lr_w = .{ .rd = rd, .rs1 = rs1, .aq = aq, .rl = rl } }, .len = len },
                0x03 => .{ .insn = .{ .sc_w = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2, .aq = aq, .rl = rl } }, .len = len },
                0x04 => .{ .insn = .{ .amoxor_w = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2, .aq = aq, .rl = rl } }, .len = len },
                0x0C => .{ .insn = .{ .amoand_w = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2, .aq = aq, .rl = rl } }, .len = len },
                0x08 => .{ .insn = .{ .amoor_w = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2, .aq = aq, .rl = rl } }, .len = len },
                0x10 => .{ .insn = .{ .amomin_w = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2, .aq = aq, .rl = rl } }, .len = len },
                0x14 => .{ .insn = .{ .amomax_w = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2, .aq = aq, .rl = rl } }, .len = len },
                0x18 => .{ .insn = .{ .amominu_w = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2, .aq = aq, .rl = rl } }, .len = len },
                0x1C => .{ .insn = .{ .amomaxu_w = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2, .aq = aq, .rl = rl } }, .len = len },
                else => .{ .insn = .{ .unknown = code }, .len = len },
            };
        },
        else => .{ .unknown = code },
    };

    return .{ .insn = parsed, .len = len };
}

test "RV32I Base Integer Instructions Decoding" {
    // add a0, a1, a2 (0x00c58533: rd=10, rs1=11, rs2=12)
    const add_dec = decode(0x00c58533);
    try std.testing.expectEqual(@as(usize, 4), add_dec.len);
    try std.testing.expectEqual(@as(u5, 10), add_dec.insn.add.rd);
    try std.testing.expectEqual(@as(u5, 11), add_dec.insn.add.rs1);
    try std.testing.expectEqual(@as(u5, 12), add_dec.insn.add.rs2);

    // sub a0, a1, a2 (0x40c58533)
    const sub_dec = decode(0x40c58533);
    try std.testing.expectEqual(@as(u5, 10), sub_dec.insn.sub.rd);

    // sll, slt, sltu, xor, srl, sra, or, and
    try std.testing.expectEqual(@as(u5, 10), decode(0x00c59533).insn.sll.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x00c5a533).insn.slt.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x00c5b533).insn.sltu.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x00c5c533).insn.xor_.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x00c5d533).insn.srl.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x40c5d533).insn.sra.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x00c5e533).insn.or_.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x00c5f533).insn.and_.rd);

    // addi sp, sp, -16 (0xff010113)
    const addi_dec = decode(0xff010113);
    try std.testing.expectEqual(@as(u5, 2), addi_dec.insn.addi.rd);
    try std.testing.expectEqual(@as(u5, 2), addi_dec.insn.addi.rs1);
    try std.testing.expectEqual(@as(i32, -16), addi_dec.insn.addi.imm);

    // lui a0, 0x12345 (0x12345537)
    const lui_dec = decode(0x12345537);
    try std.testing.expectEqual(@as(u5, 10), lui_dec.insn.lui.rd);
    try std.testing.expectEqual(@as(i32, 0x12345), lui_dec.insn.lui.imm);

    // auipc a0, 0x1000 (0x01000517)
    const auipc_dec = decode(0x01000517);
    try std.testing.expectEqual(@as(u5, 10), auipc_dec.insn.auipc.rd);
    try std.testing.expectEqual(@as(i32, 0x1000), auipc_dec.insn.auipc.imm);

    // lw a0, 8(sp) (0x00812503)
    const lw_dec = decode(0x00812503);
    try std.testing.expectEqual(@as(u5, 10), lw_dec.insn.lw.rd);
    try std.testing.expectEqual(@as(u5, 2), lw_dec.insn.lw.rs1);
    try std.testing.expectEqual(@as(i32, 8), lw_dec.insn.lw.offset);

    // sw a0, 12(sp) (0x00a12623)
    const sw_dec = decode(0x00a12623);
    try std.testing.expectEqual(@as(u5, 2), sw_dec.insn.sw.rs1);
    try std.testing.expectEqual(@as(u5, 10), sw_dec.insn.sw.rs2);
    try std.testing.expectEqual(@as(i32, 12), sw_dec.insn.sw.offset);
}

test "RV32M Multiply & Divide Decoding" {
    // mul a0, a1, a2 (0x02c58533)
    const mul_dec = decode(0x02c58533);
    try std.testing.expectEqual(@as(u5, 10), mul_dec.insn.mul.rd);
    try std.testing.expectEqual(@as(u5, 11), mul_dec.insn.mul.rs1);
    try std.testing.expectEqual(@as(u5, 12), mul_dec.insn.mul.rs2);

    // mulh, mulhsu, mulhu
    try std.testing.expectEqual(@as(u5, 10), decode(0x02c59533).insn.mulh.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x02c5a533).insn.mulhsu.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x02c5b533).insn.mulhu.rd);

    // div, divu, rem, remu
    try std.testing.expectEqual(@as(u5, 10), decode(0x02c5c533).insn.div.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x02c5d533).insn.divu.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x02c5e533).insn.rem.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x02c5f533).insn.remu.rd);
}

test "RV32A Atomic Memory Instructions Decoding" {
    // lr.w a0, (a1) (0x1005a52f)
    const lr_dec = decode(0x1005a52f);
    try std.testing.expectEqual(@as(u5, 10), lr_dec.insn.lr_w.rd);
    try std.testing.expectEqual(@as(u5, 11), lr_dec.insn.lr_w.rs1);

    // sc.w a0, a2, (a1) (0x18c5a52f)
    const sc_dec = decode(0x18c5a52f);
    try std.testing.expectEqual(@as(u5, 10), sc_dec.insn.sc_w.rd);
    try std.testing.expectEqual(@as(u5, 11), sc_dec.insn.sc_w.rs1);
    try std.testing.expectEqual(@as(u5, 12), sc_dec.insn.sc_w.rs2);

    // amoswap.w, amoadd.w, amoxor.w, amoand.w, amoor.w, amomin.w, amomax.w, amominu.w, amomaxu.w
    try std.testing.expectEqual(@as(u5, 10), decode(0x08c5a52f).insn.amoswap_w.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x00c5a52f).insn.amoadd_w.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x20c5a52f).insn.amoxor_w.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x60c5a52f).insn.amoand_w.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x40c5a52f).insn.amoor_w.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x80c5a52f).insn.amomin_w.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0xa0c5a52f).insn.amomax_w.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0xc0c5a52f).insn.amominu_w.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0xe0c5a52f).insn.amomaxu_w.rd);
}

test "RV32C Compressed Instruction Decompression" {
    // c.li a0, 5 (0x4515) -> addi a0, x0, 5 (len=2)
    const cli_dec = decode(0x4515);
    try std.testing.expectEqual(@as(usize, 2), cli_dec.len);
    try std.testing.expectEqual(@as(u5, 10), cli_dec.insn.addi.rd);
    try std.testing.expectEqual(@as(u5, 0), cli_dec.insn.addi.rs1);
    try std.testing.expectEqual(@as(i32, 5), cli_dec.insn.addi.imm);

    // c.addi sp, -16 (0x1141) -> addi sp, sp, -16
    const caddi16sp_dec = decode(0x7179);
    try std.testing.expectEqual(@as(usize, 2), caddi16sp_dec.len);
    try std.testing.expectEqual(@as(u5, 2), caddi16sp_dec.insn.addi.rd);
    try std.testing.expectEqual(@as(u5, 2), caddi16sp_dec.insn.addi.rs1);

    // c.mv a0, a1 (0x852e) -> addi a0, a1, 0
    const cmv_dec = decode(0x852e);
    try std.testing.expectEqual(@as(usize, 2), cmv_dec.len);
    try std.testing.expectEqual(@as(u5, 10), cmv_dec.insn.addi.rd);
    try std.testing.expectEqual(@as(u5, 11), cmv_dec.insn.addi.rs1);
    try std.testing.expectEqual(@as(i32, 0), cmv_dec.insn.addi.imm);

    // c.jr ra (0x8082) -> jalr x0, 0(ra)
    const cjr_dec = decode(0x8082);
    try std.testing.expectEqual(@as(usize, 2), cjr_dec.len);
    try std.testing.expectEqual(@as(u5, 0), cjr_dec.insn.jalr.rd);
    try std.testing.expectEqual(@as(u5, 1), cjr_dec.insn.jalr.rs1);

    // c.jalr a5 (0x9782) -> jalr ra, 0(a5)
    const cjalr_dec = decode(0x9782);
    try std.testing.expectEqual(@as(usize, 2), cjalr_dec.len);
    try std.testing.expectEqual(@as(u5, 1), cjalr_dec.insn.jalr.rd);
    try std.testing.expectEqual(@as(u5, 15), cjalr_dec.insn.jalr.rs1);

    // c.ebreak (0x9002) -> ebreak
    const cebreak_dec = decode(0x9002);
    try std.testing.expectEqual(@as(usize, 2), cebreak_dec.len);
    try std.testing.expect(switch (cebreak_dec.insn) {
        .ebreak => true,
        else => false,
    });
}

test "Barriers & CSR Instructions Decoding" {
    // fence (0x0ff0000f)
    const fence_dec = decode(0x0ff0000f);
    try std.testing.expect(switch (fence_dec.insn) {
        .fence => true,
        else => false,
    });

    // fence.i (0x0000100f)
    const fence_i_dec = decode(0x0000100f);
    try std.testing.expect(switch (fence_i_dec.insn) {
        .fence_i => true,
        else => false,
    });

    // csrrs a0, time, x0 (0xc0102573: rd=10, rs1=0, csr=0xC01)
    const csr_dec = decode(0xc0102573);
    try std.testing.expectEqual(@as(u5, 10), csr_dec.insn.csrrs.rd);
    try std.testing.expectEqual(@as(u5, 0), csr_dec.insn.csrrs.rs1);
    try std.testing.expectEqual(@as(u12, 0xC01), csr_dec.insn.csrrs.csr);
}
