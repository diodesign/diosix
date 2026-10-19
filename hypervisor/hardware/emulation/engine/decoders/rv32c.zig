// RV32C 16-bit Compressed Instruction Decompressor for Diosix Hypervisor.
//
// Decompresses 16-bit RV32C instructions into standard 32-bit RV32I/F/D
// instruction encodings.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const rv32 = @import("rv32.zig");
const encoding = @import("rv32/encoding.zig");
const rv64 = @import("../emitters/rv64.zig");

pub const signExtend = encoding.signExtend;

pub const RVC_PRIME_REG_BASE: u5 = 8;
pub const REG_ZERO: u5 = 0;
pub const REG_RA: u5 = 1;
pub const REG_SP: u5 = 2;

fn primeReg(bits: u16) u5 {
    return @as(u5, @truncate(bits & 0x7)) + RVC_PRIME_REG_BASE;
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
    const imm: i21 = @intCast(signExtend(offset, 12));
    return rv64.jal(rd, imm);
}

fn encodeCB(is_bne: bool, code16: u16) u32 {
    const offset: u32 = (((code16 >> 3) & 3) << 1) |
        (((code16 >> 10) & 3) << 3) |
        (((code16 >> 2) & 1) << 5) |
        (((code16 >> 5) & 3) << 6) |
        (((code16 >> 12) & 1) << 8);
    const rs1 = primeReg(code16 >> 7);
    const imm: i13 = @intCast(signExtend(offset, 9));
    return if (is_bne)
        rv64.bne(rs1, REG_ZERO, imm)
    else
        rv64.beq(rs1, REG_ZERO, imm);
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
                const rd = primeReg(code16 >> 2);
                if (nzuimm == 0) return null;
                return rv64.addi(rd, REG_SP, @intCast(nzuimm));
            },
            0b001 => {
                // C.FLD: fld rd', offset(rs1').
                const offset: u32 = (((code16 >> 10) & 7) << 3) |
                    (((code16 >> 5) & 3) << 6);
                const rs1 = primeReg(code16 >> 7);
                const rd = primeReg(code16 >> 2);
                return rv64.fld(rd, rs1, @intCast(offset));
            },
            0b010, 0b011 => {
                // C.LW (0b010) / C.FLW (0b011).
                const offset: u32 = (((code16 >> 6) & 1) << 2) |
                    (((code16 >> 10) & 7) << 3) |
                    (((code16 >> 5) & 1) << 6);
                const rs1 = primeReg(code16 >> 7);
                const rd = primeReg(code16 >> 2);
                const imm: i12 = @intCast(offset);
                return if (funct3 == 0b010)
                    rv64.lw(rd, rs1, imm)
                else
                    rv64.flw(rd, rs1, imm);
            },
            0b101 => {
                // C.FSD: fsd rs2', offset(rs1').
                const offset: u32 = (((code16 >> 10) & 7) << 3) |
                    (((code16 >> 5) & 3) << 6);
                const rs1 = primeReg(code16 >> 7);
                const rs2 = primeReg(code16 >> 2);
                return rv64.fsd(rs1, rs2, @intCast(offset));
            },
            0b110, 0b111 => {
                // C.SW (0b110) / C.FSW (0b111).
                const offset: u32 = (((code16 >> 6) & 1) << 2) |
                    (((code16 >> 10) & 7) << 3) |
                    (((code16 >> 5) & 1) << 6);
                const rs1 = primeReg(code16 >> 7);
                const rs2 = primeReg(code16 >> 2);
                const imm: i12 = @intCast(offset);
                return if (funct3 == 0b110)
                    rv64.sw(rs1, rs2, imm)
                else
                    rv64.fsw(rs1, rs2, imm);
            },
            else => return null,
        },

        0b01 => switch (funct3) {
            0b000 => {
                // C.NOP / C.ADDI: addi rd, rd, imm.
                const rd = @as(u5, @truncate((code16 >> 7) & 0x1f));
                const imm6 = ((code16 >> 2) & 0x1f) |
                    (((code16 >> 12) & 0x1) << 5);
                const imm: i12 = @intCast(signExtend(imm6, 6));
                return rv64.addi(rd, rd, imm);
            },
            0b001 => encodeCJ(REG_RA, code16), // C.JAL: jal x1, offset.
            0b010 => {
                // C.LI: addi rd, x0, imm.
                const rd = @as(u5, @truncate((code16 >> 7) & 0x1f));
                const imm6 = ((code16 >> 2) & 0x1f) |
                    (((code16 >> 12) & 0x1) << 5);
                const imm: i12 = @intCast(signExtend(imm6, 6));
                return rv64.addi(rd, REG_ZERO, imm);
            },
            0b011 => {
                const rd = @as(u5, @truncate((code16 >> 7) & 0x1f));
                if (rd == REG_ZERO) return null;
                if (rd == REG_SP) {
                    // C.ADDI16SP: addi x2, x2, nzimm.
                    const offset: u32 = (((code16 >> 6) & 1) << 4) |
                        (((code16 >> 2) & 1) << 5) |
                        (((code16 >> 5) & 1) << 6) |
                        (((code16 >> 3) & 3) << 7) |
                        (((code16 >> 4) & 1) << 8) |
                        (((code16 >> 12) & 1) << 9);
                    if (offset == 0) return null;
                    const imm: i12 = @intCast(signExtend(offset, 10));
                    return rv64.addi(REG_SP, REG_SP, imm);
                } else {
                    // C.LUI: lui rd, nzimm.
                    const imm6 = ((code16 >> 2) & 0x1f) |
                        (((code16 >> 12) & 0x1) << 5);
                    if (imm6 == 0) return null;
                    const imm: i20 = @intCast(signExtend(imm6, 6));
                    return rv64.lui(rd, imm);
                }
            },
            0b100 => {
                const funct2 = @as(u2, @truncate((code16 >> 10) & 0x3));
                const rd = primeReg(code16 >> 7);
                const imm6: u32 = ((code16 >> 2) & 0x1f) |
                    (((code16 >> 12) & 0x1) << 5);
                switch (funct2) {
                    0b00 => {
                        // C.SRLI: srli rd', rd', shamt.
                        return rv64.srli(rd, rd, @intCast(imm6));
                    },
                    0b01 => {
                        // C.SRAI: srai rd', rd', shamt.
                        return rv64.srai(rd, rd, @intCast(imm6));
                    },
                    0b10 => {
                        // C.ANDI: andi rd', rd', imm.
                        const imm: i12 = @intCast(signExtend(imm6, 6));
                        return rv64.andi(rd, rd, imm);
                    },
                    0b11 => {
                        const rs2 = primeReg(code16 >> 2);
                        const sub_op = (code16 >> 5) & 0x3;
                        return switch (sub_op) {
                            0b00 => rv64.sub(rd, rd, rs2),
                            0b01 => rv64.xor_(rd, rd, rs2),
                            0b10 => rv64.or_(rd, rd, rs2),
                            0b11 => rv64.and_(rd, rd, rs2),
                            else => null,
                        };
                    },
                }
            },
            0b101 => encodeCJ(REG_ZERO, code16), // C.J: jal x0, offset.
            0b110 => encodeCB(false, code16), // C.BEQZ: beq rs1', x0, offset.
            0b111 => encodeCB(true, code16), // C.BNEZ: bne rs1', x0, offset.
            else => return null,
        },

        0b10 => switch (funct3) {
            0b000 => {
                // C.SLLI: slli rd, rd, shamt.
                const rd = @as(u5, @truncate((code16 >> 7) & 0x1f));
                const shamt: u32 = ((code16 >> 2) & 0x1f) |
                    (((code16 >> 12) & 0x1) << 5);
                return rv64.slli(rd, rd, @intCast(shamt));
            },
            0b001 => {
                // C.FLDSP: fld rd, offset(x2).
                const rd = @as(u5, @truncate((code16 >> 7) & 0x1f));
                const offset: u32 = (((code16 >> 5) & 3) << 3) |
                    (((code16 >> 12) & 1) << 5) |
                    (((code16 >> 2) & 7) << 6);
                return rv64.fld(rd, REG_SP, @intCast(offset));
            },
            0b010, 0b011 => {
                // C.LWSP (0b010) / C.FLWSP (0b011).
                const rd = @as(u5, @truncate((code16 >> 7) & 0x1f));
                if (funct3 == 0b010 and rd == REG_ZERO) return null;
                const offset: u32 = (((code16 >> 4) & 7) << 2) |
                    (((code16 >> 12) & 1) << 5) |
                    (((code16 >> 2) & 3) << 6);
                const imm: i12 = @intCast(offset);
                return if (funct3 == 0b010)
                    rv64.lw(rd, REG_SP, imm)
                else
                    rv64.flw(rd, REG_SP, imm);
            },
            0b100 => {
                const bit12 = (code16 >> 12) & 0x1;
                const rs1 = @as(u5, @truncate((code16 >> 7) & 0x1f));
                const rs2 = @as(u5, @truncate((code16 >> 2) & 0x1f));
                if (bit12 == 0) {
                    if (rs2 == REG_ZERO) {
                        if (rs1 == REG_ZERO) return null;
                        // C.JR: jalr x0, rs1, 0.
                        return rv64.jalr(REG_ZERO, rs1, 0);
                    } else {
                        // C.MV: add rd, x0, rs2.
                        return rv64.add(rs1, REG_ZERO, rs2);
                    }
                } else {
                    if (rs1 == REG_ZERO and rs2 == REG_ZERO) {
                        // C.EBREAK.
                        return rv64.ebreak();
                    } else if (rs2 == REG_ZERO) {
                        // C.JALR: jalr x1, rs1, 0.
                        return rv64.jalr(REG_RA, rs1, 0);
                    } else {
                        // C.ADD: add rd, rd, rs2.
                        return rv64.add(rs1, rs1, rs2);
                    }
                }
            },
            0b101 => {
                // C.FSDSP: fsd rs2, offset(x2).
                const rs2 = @as(u5, @truncate((code16 >> 2) & 0x1f));
                const offset: u32 = (((code16 >> 10) & 7) << 3) |
                    (((code16 >> 7) & 7) << 6);
                return rv64.fsd(REG_SP, rs2, @intCast(offset));
            },
            0b110, 0b111 => {
                // C.SWSP (0b110) / C.FSWSP (0b111).
                const rs2 = @as(u5, @truncate((code16 >> 2) & 0x1f));
                const offset: u32 = (((code16 >> 9) & 15) << 2) |
                    (((code16 >> 7) & 3) << 6);
                const imm: i12 = @intCast(offset);
                return if (funct3 == 0b110)
                    rv64.sw(REG_SP, rs2, imm)
                else
                    rv64.fsw(REG_SP, rs2, imm);
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
    std.testing.refAllDecls(@This());
}
