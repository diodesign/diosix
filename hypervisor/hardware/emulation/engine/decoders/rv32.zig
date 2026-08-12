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

    switch (op) {
        0b00 => switch (funct3) {
            0b000 => {
                // C.ADDI4SPN
                const nzuimm = (((code16 >> 7) & 0x3B) | ((code16 >> 11) & 0x4) | ((code16 >> 5) & 0x1) | ((code16 >> 6) & 0x2)) << 2;
                const rd = @as(u5, @truncate((code16 >> 2) & 0x7)) + 8;
                if (nzuimm == 0) return null;
                // addi rd, x2, nzuimm
                return 0x13 | (@as(u32, rd) << 7) | (2 << 15) | (@as(u32, nzuimm) << 20);
            },
            0b010 => {
                // C.LW
                const offset: u32 = (((code16 >> 6) & 0x1) | ((code16 >> 10) & 0x7) | ((code16 >> 5) & 0x1)) << 2;
                const rs1 = @as(u5, @truncate((code16 >> 7) & 0x7)) + 8;
                const rd = @as(u5, @truncate((code16 >> 2) & 0x7)) + 8;
                // lw rd, offset(rs1)
                return 0x03 | (@as(u32, rd) << 7) | (0x2 << 12) | (@as(u32, rs1) << 15) | (offset << 20);
            },
            0b110 => {
                // C.SW
                const offset: u32 = (((code16 >> 6) & 0x1) | ((code16 >> 10) & 0x7) | ((code16 >> 5) & 0x1)) << 2;
                const rs1 = @as(u5, @truncate((code16 >> 7) & 0x7)) + 8;
                const rs2 = @as(u5, @truncate((code16 >> 2) & 0x7)) + 8;
                // sw rs2, offset(rs1)
                const imm5 = offset & 0x1F;
                const imm7 = (offset >> 5) & 0x7F;
                return 0x23 | (imm5 << 7) | (0x2 << 12) | (@as(u32, rs1) << 15) | (@as(u32, rs2) << 20) | (imm7 << 25);
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
                const offset = (((code16 >> 3) & 0x7) | ((code16 >> 11) & 0x1) | ((code16 >> 2) & 0x1) | ((code16 >> 7) & 0x1) | ((code16 >> 6) & 0x1) | ((code16 >> 9) & 0x2) | ((code16 >> 8) & 0x1) | ((code16 >> 12) & 0x1)) << 1;
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
                    const offset = (((code16 >> 6) & 0x1) | ((code16 >> 2) & 0x1) | ((code16 >> 5) & 0x1) | ((code16 >> 3) & 0x3) | ((code16 >> 12) & 0x1)) << 4;
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
            0b101 => {
                // C.J
                const offset = (((code16 >> 3) & 0x7) | ((code16 >> 11) & 0x1) | ((code16 >> 2) & 0x1) | ((code16 >> 7) & 0x1) | ((code16 >> 6) & 0x1) | ((code16 >> 9) & 0x2) | ((code16 >> 8) & 0x1) | ((code16 >> 12) & 0x1)) << 1;
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
                const offset = (((code16 >> 3) & 0x3) | ((code16 >> 10) & 0x3) | ((code16 >> 2) & 0x1) | ((code16 >> 5) & 0x2) | ((code16 >> 12) & 0x1)) << 1;
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
                const offset = (((code16 >> 3) & 0x3) | ((code16 >> 10) & 0x3) | ((code16 >> 2) & 0x1) | ((code16 >> 5) & 0x2) | ((code16 >> 12) & 0x1)) << 1;
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
            0b010 => {
                // C.LWSP
                const rd = @as(u5, @truncate((code16 >> 7) & 0x1F));
                const offset: u32 = (((code16 >> 4) & 0x7) | ((code16 >> 12) & 0x1) | ((code16 >> 2) & 0x3)) << 2;
                // lw rd, offset(x2)
                return 0x03 | (@as(u32, rd) << 7) | (0x2 << 12) | (2 << 15) | (offset << 20);
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
                    if (rs2 == 0) {
                        // C.JALR (jalr x1, rs1, 0)
                        return 0x67 | (1 << 7) | (@as(u32, rs1) << 15) | (0 << 20);
                    } else {
                        // C.ADD (add rd, rd, rs2)
                        return 0x33 | (@as(u32, rs1) << 7) | (@as(u32, rs1) << 15) | (@as(u32, rs2) << 20);
                    }
                }
            },
            0b110 => {
                // C.SWSP
                const rs2 = @as(u5, @truncate((code16 >> 2) & 0x1F));
                const offset = (((code16 >> 9) & 0x3) | ((code16 >> 7) & 0xF)) << 2;
                const imm5: u32 = offset & 0x1F;
                const imm7: u32 = (offset >> 5) & 0x7F;
                // sw rs2, offset(x2)
                return 0x23 | (imm5 << 7) | (0x2 << 12) | (@as(u32, 2) << 15) | (@as(u32, rs2) << 20) | (imm7 << 25);
            },
            else => return null,
        },
        else => return null,
    }
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
            return .{ .insn = .{ .unknown = raw_code }, .len = 2 };
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
            0x1 => .{ .sll = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } },
            0x2 => .{ .slt = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } },
            0x3 => .{ .sltu = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } },
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
        0x23 => switch (funct3) {
            0x0 => .{ .sb = .{ .rs1 = rs1, .rs2 = rs2, .offset = s_imm } },
            0x1 => .{ .sh = .{ .rs1 = rs1, .rs2 = rs2, .offset = s_imm } },
            0x2 => .{ .sw = .{ .rs1 = rs1, .rs2 = rs2, .offset = s_imm } },
            else => .{ .unknown = code },
        },
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
            0x0 => switch (i_imm) {
                0x000 => .ecall,
                0x001 => .ebreak,
                0x102 => .sret,
                0x302 => .mret,
                0x105 => .{ .sfence_vma = .{ .rs1 = rs1, .rs2 = rs2 } },
                0x104 => .wfi,
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
            0x0 => .fence,
            0x1 => .fence_i,
            else => .{ .unknown = code },
        },
        else => .{ .unknown = code },
    };

    return .{ .insn = parsed, .len = len };
}
