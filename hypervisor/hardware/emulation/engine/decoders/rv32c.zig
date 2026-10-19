// RV32C 16-bit Compressed Instruction Decompressor for Diosix Hypervisor.
//
// Decompresses 16-bit RV32C instructions into standard 32-bit RV32I/F/D
// instruction encodings.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const rv32 = @import("rv32.zig");

/// Sign-extend a bit field of length `bits` to `i32`.
pub fn signExtend(val: u32, bits: u6) i32 {
    const shift: u5 = @truncate(32 - bits);
    const signed_val = @as(i32, @bitCast(val << shift));
    return signed_val >> shift;
}

fn encodeCJ(rd: u5, code16: u16) u32 {
    const offset: u32 = (((code16 >> 3) & 7) << 1) |
        (((code16 >> 11) & 1) << 4) |
        (((code16 >> 2) & 1) << 5) |
        (((code16 >> 7) & 1) << 6) |
        (((code16 >> 6) & 1) << 7) |
        (((code16 >> 9) & 3) << 8) |
        (((code16 >> 8) & 1) << 10) |
        (((code16 >> 12) & 1) << 11);
    const imm = signExtend(offset, 12);
    const uimm = @as(u32, @bitCast(imm)) & 0x1fffff;
    const imm20: u32 = (uimm >> 20) & 1;
    const imm10_1: u32 = (uimm >> 1) & 0x3ff;
    const imm11: u32 = (uimm >> 11) & 1;
    const imm19_12: u32 = (uimm >> 12) & 0xff;
    return 0x6f | (@as(u32, rd) << 7) | (imm19_12 << 12) |
        (imm11 << 20) | (imm10_1 << 21) | (imm20 << 31);
}

fn encodeCB(funct3: u3, code16: u16) u32 {
    const offset: u32 = (((code16 >> 3) & 3) << 1) |
        (((code16 >> 10) & 3) << 3) |
        (((code16 >> 2) & 1) << 5) |
        (((code16 >> 5) & 3) << 6) |
        (((code16 >> 12) & 1) << 8);
    const rs1 = @as(u5, @truncate((code16 >> 7) & 0x7)) + 8;
    const imm = signExtend(offset, 9);
    const uimm = @as(u32, @bitCast(imm)) & 0x1fff;
    const imm11: u32 = (uimm >> 11) & 1;
    const imm4_1: u32 = (uimm >> 1) & 0xf;
    const imm10_5: u32 = (uimm >> 5) & 0x3f;
    const imm12: u32 = (uimm >> 12) & 1;
    return 0x63 | (imm11 << 7) | (imm4_1 << 8) |
        (@as(u32, funct3) << 12) | (@as(u32, rs1) << 15) |
        (imm10_5 << 25) | (imm12 << 31);
}

/// Decompress 16-bit RV32C compressed instruction to 32-bit encoding.
pub fn decompressRvc(code16: u16) ?u32 {
    const op = code16 & 0x3;
    const funct3 = (code16 >> 13) & 0x7;

    return switch (op) {
        0b00 => switch (funct3) {
            0b000 => {
                // C.ADDI4SPN: addi rd', x2, nzuimm.
                const nzuimm: u32 = (((code16 >> 6) & 1) << 2) |
                    (((code16 >> 5) & 1) << 3) |
                    (((code16 >> 11) & 3) << 4) |
                    (((code16 >> 7) & 15) << 6);
                const rd = @as(u5, @truncate((code16 >> 2) & 0x7)) + 8;
                if (nzuimm == 0) return null;
                return 0x13 | (@as(u32, rd) << 7) | (2 << 15) |
                    (nzuimm << 20);
            },
            0b001 => {
                // C.FLD: fld rd', offset(rs1').
                const offset: u32 = (((code16 >> 10) & 7) << 3) |
                    (((code16 >> 5) & 3) << 6);
                const rs1 = @as(u5, @truncate((code16 >> 7) & 0x7)) + 8;
                const rd = @as(u5, @truncate((code16 >> 2) & 0x7)) + 8;
                return 0x07 | (@as(u32, rd) << 7) | (0x3 << 12) |
                    (@as(u32, rs1) << 15) | (offset << 20);
            },
            0b010, 0b011 => {
                // C.LW (0b010) / C.FLW (0b011).
                const offset: u32 = (((code16 >> 6) & 1) << 2) |
                    (((code16 >> 10) & 7) << 3) |
                    (((code16 >> 5) & 1) << 6);
                const rs1 = @as(u5, @truncate((code16 >> 7) & 0x7)) + 8;
                const rd = @as(u5, @truncate((code16 >> 2) & 0x7)) + 8;
                const opc: u32 = if (funct3 == 0b010) 0x03 else 0x07;
                return opc | (@as(u32, rd) << 7) | (0x2 << 12) |
                    (@as(u32, rs1) << 15) | (offset << 20);
            },
            0b101 => {
                // C.FSD: fsd rs2', offset(rs1').
                const offset: u32 = (((code16 >> 10) & 7) << 3) |
                    (((code16 >> 5) & 3) << 6);
                const rs1 = @as(u5, @truncate((code16 >> 7) & 0x7)) + 8;
                const rs2 = @as(u5, @truncate((code16 >> 2) & 0x7)) + 8;
                const imm5 = offset & 0x1f;
                const imm7 = (offset >> 5) & 0x7f;
                return 0x27 | (imm5 << 7) | (0x3 << 12) |
                    (@as(u32, rs1) << 15) | (@as(u32, rs2) << 20) |
                    (imm7 << 25);
            },
            0b110, 0b111 => {
                // C.SW (0b110) / C.FSW (0b111).
                const offset: u32 = (((code16 >> 6) & 1) << 2) |
                    (((code16 >> 10) & 7) << 3) |
                    (((code16 >> 5) & 1) << 6);
                const rs1 = @as(u5, @truncate((code16 >> 7) & 0x7)) + 8;
                const rs2 = @as(u5, @truncate((code16 >> 2) & 0x7)) + 8;
                const imm5 = offset & 0x1f;
                const imm7 = (offset >> 5) & 0x7f;
                const opc: u32 = if (funct3 == 0b110) 0x23 else 0x27;
                return opc | (imm5 << 7) | (0x2 << 12) |
                    (@as(u32, rs1) << 15) | (@as(u32, rs2) << 20) |
                    (imm7 << 25);
            },
            else => return null,
        },

        0b01 => switch (funct3) {
            0b000 => {
                // C.NOP / C.ADDI: addi rd, rd, imm.
                const rd = @as(u5, @truncate((code16 >> 7) & 0x1f));
                const imm6 = ((code16 >> 2) & 0x1f) |
                    (((code16 >> 12) & 0x1) << 5);
                const imm = signExtend(imm6, 6);
                const uimm = @as(u32, @bitCast(imm)) & 0xfff;
                return 0x13 | (@as(u32, rd) << 7) |
                    (@as(u32, rd) << 15) | (uimm << 20);
            },
            0b001 => encodeCJ(1, code16), // C.JAL: jal x1, offset.
            0b010 => {
                // C.LI: addi rd, x0, imm.
                const rd = @as(u5, @truncate((code16 >> 7) & 0x1f));
                const imm6 = ((code16 >> 2) & 0x1f) |
                    (((code16 >> 12) & 0x1) << 5);
                const imm = signExtend(imm6, 6);
                const uimm = @as(u32, @bitCast(imm)) & 0xfff;
                return 0x13 | (@as(u32, rd) << 7) | (uimm << 20);
            },
            0b011 => {
                const rd = @as(u5, @truncate((code16 >> 7) & 0x1f));
                if (rd == 0) return null;
                if (rd == 2) {
                    // C.ADDI16SP: addi x2, x2, nzimm.
                    const offset: u32 = (((code16 >> 6) & 1) << 4) |
                        (((code16 >> 2) & 1) << 5) |
                        (((code16 >> 5) & 1) << 6) |
                        (((code16 >> 3) & 3) << 7) |
                        (((code16 >> 4) & 1) << 8) |
                        (((code16 >> 12) & 1) << 9);
                    if (offset == 0) return null;
                    const imm = signExtend(offset, 10);
                    const uimm = @as(u32, @bitCast(imm)) & 0xfff;
                    return 0x13 | (2 << 7) | (2 << 15) | (uimm << 20);
                } else {
                    // C.LUI: lui rd, nzimm.
                    const imm6 = ((code16 >> 2) & 0x1f) |
                        (((code16 >> 12) & 0x1) << 5);
                    if (imm6 == 0) return null;
                    const imm = signExtend(imm6, 6);
                    const uimm = @as(u32, @bitCast(imm)) & 0xfffff;
                    return 0x37 | (@as(u32, rd) << 7) | (uimm << 12);
                }
            },
            0b100 => {
                const funct2 = @as(u2, @truncate((code16 >> 10) & 0x3));
                const rd = @as(u5, @truncate((code16 >> 7) & 0x7)) + 8;
                const imm6: u32 = ((code16 >> 2) & 0x1f) |
                    (((code16 >> 12) & 0x1) << 5);
                switch (funct2) {
                    0b00 => {
                        // C.SRLI: srli rd', rd', shamt.
                        return 0x13 | (@as(u32, rd) << 7) | (0x5 << 12) |
                            (@as(u32, rd) << 15) | (imm6 << 20);
                    },
                    0b01 => {
                        // C.SRAI: srai rd', rd', shamt.
                        return 0x13 | (@as(u32, rd) << 7) | (0x5 << 12) |
                            (@as(u32, rd) << 15) | (imm6 << 20) |
                            (0x20 << 25);
                    },
                    0b10 => {
                        // C.ANDI: andi rd', rd', imm.
                        const imm = signExtend(imm6, 6);
                        const uimm = @as(u32, @bitCast(imm)) & 0xfff;
                        return 0x13 | (@as(u32, rd) << 7) | (0x7 << 12) |
                            (@as(u32, rd) << 15) | (uimm << 20);
                    },
                    0b11 => {
                        const rs2 =
                            @as(u5, @truncate((code16 >> 2) & 0x7)) + 8;
                        const sub_op = (code16 >> 5) & 0x3;
                        const base = 0x33 | (@as(u32, rd) << 7) |
                            (@as(u32, rd) << 15) | (@as(u32, rs2) << 20);
                        return switch (sub_op) {
                            0b00 => base | (0x20 << 25), // sub.
                            0b01 => base | (0x4 << 12), // xor.
                            0b10 => base | (0x6 << 12), // or.
                            0b11 => base | (0x7 << 12), // and.
                            else => null,
                        };
                    },
                }
            },
            0b101 => encodeCJ(0, code16), // C.J: jal x0, offset.
            0b110 => encodeCB(0x0, code16), // C.BEQZ: beq rs1', x0, offset.
            0b111 => encodeCB(0x1, code16), // C.BNEZ: bne rs1', x0, offset.
            else => return null,
        },

        0b10 => switch (funct3) {
            0b000 => {
                // C.SLLI: slli rd, rd, shamt.
                const rd = @as(u5, @truncate((code16 >> 7) & 0x1f));
                const shamt: u32 = ((code16 >> 2) & 0x1f) |
                    (((code16 >> 12) & 0x1) << 5);
                return 0x13 | (@as(u32, rd) << 7) | (0x1 << 12) |
                    (@as(u32, rd) << 15) | (shamt << 20);
            },
            0b001 => {
                // C.FLDSP: fld rd, offset(x2).
                const rd = @as(u5, @truncate((code16 >> 7) & 0x1f));
                const offset: u32 = (((code16 >> 5) & 3) << 3) |
                    (((code16 >> 12) & 1) << 5) |
                    (((code16 >> 2) & 7) << 6);
                return 0x07 | (@as(u32, rd) << 7) | (0x3 << 12) |
                    (2 << 15) | (offset << 20);
            },
            0b010, 0b011 => {
                // C.LWSP (0b010) / C.FLWSP (0b011).
                const rd = @as(u5, @truncate((code16 >> 7) & 0x1f));
                if (funct3 == 0b010 and rd == 0) return null;
                const offset: u32 = (((code16 >> 4) & 7) << 2) |
                    (((code16 >> 12) & 1) << 5) |
                    (((code16 >> 2) & 3) << 6);
                const opc: u32 = if (funct3 == 0b010) 0x03 else 0x07;
                return opc | (@as(u32, rd) << 7) | (0x2 << 12) |
                    (2 << 15) | (offset << 20);
            },
            0b100 => {
                const bit12 = (code16 >> 12) & 0x1;
                const rs1 = @as(u5, @truncate((code16 >> 7) & 0x1f));
                const rs2 = @as(u5, @truncate((code16 >> 2) & 0x1f));
                if (bit12 == 0) {
                    if (rs2 == 0) {
                        if (rs1 == 0) return null;
                        // C.JR: jalr x0, rs1, 0.
                        return 0x67 | (@as(u32, rs1) << 15);
                    } else {
                        // C.MV: add rd, x0, rs2.
                        return 0x33 | (@as(u32, rs1) << 7) |
                            (@as(u32, rs2) << 20);
                    }
                } else {
                    if (rs1 == 0 and rs2 == 0) {
                        // C.EBREAK.
                        return 0x00100073;
                    } else if (rs2 == 0) {
                        // C.JALR: jalr x1, rs1, 0.
                        return 0x67 | (1 << 7) | (@as(u32, rs1) << 15);
                    } else {
                        // C.ADD: add rd, rd, rs2.
                        return 0x33 | (@as(u32, rs1) << 7) |
                            (@as(u32, rs1) << 15) | (@as(u32, rs2) << 20);
                    }
                }
            },
            0b101 => {
                // C.FSDSP: fsd rs2, offset(x2).
                const rs2 = @as(u5, @truncate((code16 >> 2) & 0x1f));
                const offset: u32 = (((code16 >> 10) & 7) << 3) |
                    (((code16 >> 7) & 7) << 6);
                const imm5: u32 = offset & 0x1f;
                const imm7: u32 = (offset >> 5) & 0x7f;
                return 0x27 | (imm5 << 7) | (0x3 << 12) |
                    (2 << 15) | (@as(u32, rs2) << 20) | (imm7 << 25);
            },
            0b110, 0b111 => {
                // C.SWSP (0b110) / C.FSWSP (0b111).
                const rs2 = @as(u5, @truncate((code16 >> 2) & 0x1f));
                const offset: u32 = (((code16 >> 9) & 15) << 2) |
                    (((code16 >> 7) & 3) << 6);
                const imm5: u32 = offset & 0x1f;
                const imm7: u32 = (offset >> 5) & 0x7f;
                const opc: u32 = if (funct3 == 0b110) 0x23 else 0x27;
                return opc | (imm5 << 7) | (0x2 << 12) |
                    (2 << 15) | (@as(u32, rs2) << 20) | (imm7 << 25);
            },
            else => return null,
        },

        else => return null,
    };
}

test "RV32C Compressed Instruction Decompression" {
    // c.li a0, 5 (0x4515) -> addi a0, x0, 5 (len=2).
    const cli_dec = rv32.decode(0x4515);
    try std.testing.expectEqual(@as(usize, 2), cli_dec.len);
    try std.testing.expectEqual(@as(u5, 10), cli_dec.insn.addi.rd);
    try std.testing.expectEqual(@as(u5, 0), cli_dec.insn.addi.rs1);
    try std.testing.expectEqual(@as(i32, 5), cli_dec.insn.addi.imm);

    // c.addi16sp sp, -16 (0x7179) -> addi sp, sp, -16.
    const caddi16sp_dec = rv32.decode(0x7179);
    try std.testing.expectEqual(@as(usize, 2), caddi16sp_dec.len);
    try std.testing.expectEqual(@as(u5, 2), caddi16sp_dec.insn.addi.rd);
    try std.testing.expectEqual(@as(u5, 2), caddi16sp_dec.insn.addi.rs1);

    // c.mv a0, a1 (0x852e) -> add a0, x0, a1.
    const cmv_dec = rv32.decode(0x852e);
    try std.testing.expectEqual(@as(usize, 2), cmv_dec.len);
    try std.testing.expectEqual(@as(u5, 10), cmv_dec.insn.add.rd);
    try std.testing.expectEqual(@as(u5, 0), cmv_dec.insn.add.rs1);
    try std.testing.expectEqual(@as(u5, 11), cmv_dec.insn.add.rs2);

    // c.jr ra (0x8082) -> jalr x0, 0(ra).
    const cjr_dec = rv32.decode(0x8082);
    try std.testing.expectEqual(@as(usize, 2), cjr_dec.len);
    try std.testing.expectEqual(@as(u5, 0), cjr_dec.insn.jalr.rd);
    try std.testing.expectEqual(@as(u5, 1), cjr_dec.insn.jalr.rs1);

    // c.jalr a5 (0x9782) -> jalr ra, 0(a5).
    const cjalr_dec = rv32.decode(0x9782);
    try std.testing.expectEqual(@as(usize, 2), cjalr_dec.len);
    try std.testing.expectEqual(@as(u5, 1), cjalr_dec.insn.jalr.rd);
    try std.testing.expectEqual(@as(u5, 15), cjalr_dec.insn.jalr.rs1);

    // c.ebreak (0x9002) -> ebreak.
    const cebreak_dec = rv32.decode(0x9002);
    try std.testing.expectEqual(@as(usize, 2), cebreak_dec.len);
    try std.testing.expect(cebreak_dec.insn == .ebreak);

    // Reserved encodings: c.addi16sp with nzimm=0 (0x6101) and c.lui rd=0.
    try std.testing.expect(decompressRvc(0x6101) == null);
    try std.testing.expect(decompressRvc(0x6005) == null);
}
