// Direct RV64 Machine Code Emitter for Diosix Dynamic Recompiler
//
// Encodes RISC-V 64-bit machine instructions directly into memory buffers
// without an intermediate representation stage.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

/// Bitfield encodings for RISC-V opcodes
pub const Opcode = enum(u7) {
    load = 0x03,
    op_imm = 0x13,
    auipc = 0x17,
    op_imm_32 = 0x1B,
    store = 0x23,
    op = 0x33,
    lui = 0x37,
    op_32 = 0x3B,
    branch = 0x63,
    jalr = 0x67,
    jal = 0x6F,
    system = 0x73,
};

/// Helper to write a 32-bit instruction into a byte slice at offset.
pub fn emit(buf: []u8, offset: *usize, insn: u32) void {
    if (offset.* + 4 <= buf.len) {
        std.mem.writeInt(u32, buf[offset.*..][0..4], insn, .little);
        offset.* += 4;
    }
}

/// Generic R-Type encoder
/// opcode [6:0], rd [11:7], funct3 [14:12], rs1 [19:15], rs2 [24:20], funct7 [31:25]
pub fn encodeR(opcode: u7, rd: u5, funct3: u3, rs1: u5, rs2: u5, funct7: u7) u32 {
    return @as(u32, opcode) |
        (@as(u32, rd) << 7) |
        (@as(u32, funct3) << 12) |
        (@as(u32, rs1) << 15) |
        (@as(u32, rs2) << 20) |
        (@as(u32, funct7) << 25);
}

/// Generic I-Type encoder
/// opcode [6:0], rd [11:7], funct3 [14:12], rs1 [19:15], imm [31:20]
pub fn encodeI(opcode: u7, rd: u5, funct3: u3, rs1: u5, imm: i12) u32 {
    const uimm = @as(u32, @bitCast(@as(i32, imm))) & 0xFFF;
    return @as(u32, opcode) |
        (@as(u32, rd) << 7) |
        (@as(u32, funct3) << 12) |
        (@as(u32, rs1) << 15) |
        (uimm << 20);
}

/// Generic S-Type encoder
/// opcode [6:0], imm[4:0] [11:7], funct3 [14:12], rs1 [19:15], rs2 [24:20], imm[11:5] [31:25]
pub fn encodeS(opcode: u7, funct3: u3, rs1: u5, rs2: u5, imm: i12) u32 {
    const uimm = @as(u32, @bitCast(@as(i32, imm))) & 0xFFF;
    const imm_4_0 = uimm & 0x1F;
    const imm_11_5 = (uimm >> 5) & 0x7F;
    return @as(u32, opcode) |
        (imm_4_0 << 7) |
        (@as(u32, funct3) << 12) |
        (@as(u32, rs1) << 15) |
        (@as(u32, rs2) << 20) |
        (imm_11_5 << 25);
}

/// Generic B-Type encoder
/// opcode [6:0], imm[11] [7], imm[4:1] [11:8], funct3 [14:12], rs1 [19:15], rs2 [24:20], imm[10:5] [30:25], imm[12] [31]
pub fn encodeB(opcode: u7, funct3: u3, rs1: u5, rs2: u5, imm: i13) u32 {
    const uimm = @as(u32, @bitCast(@as(i32, imm))) & 0x1FFF;
    const imm_11 = (uimm >> 11) & 1;
    const imm_4_1 = (uimm >> 1) & 0xF;
    const imm_10_5 = (uimm >> 5) & 0x3F;
    const imm_12 = (uimm >> 12) & 1;
    return @as(u32, opcode) |
        (imm_11 << 7) |
        (imm_4_1 << 8) |
        (@as(u32, funct3) << 12) |
        (@as(u32, rs1) << 15) |
        (@as(u32, rs2) << 20) |
        (imm_10_5 << 25) |
        (imm_12 << 31);
}

/// Generic U-Type encoder
/// opcode [6:0], rd [11:7], imm[31:12] [31:12]
pub fn encodeU(opcode: u7, rd: u5, imm: i20) u32 {
    const uimm = @as(u32, @bitCast(@as(i32, imm))) & 0xFFFFF;
    return @as(u32, opcode) |
        (@as(u32, rd) << 7) |
        (uimm << 12);
}

/// Generic J-Type encoder
/// opcode [6:0], rd [11:7], imm[19:12] [19:12], imm[11] [20], imm[10:1] [30:21], imm[20] [31]
pub fn encodeJ(opcode: u7, rd: u5, imm: i21) u32 {
    const uimm = @as(u32, @bitCast(@as(i32, imm))) & 0x1FFFFF;
    const imm_19_12 = (uimm >> 12) & 0xFF;
    const imm_11 = (uimm >> 11) & 1;
    const imm_10_1 = (uimm >> 1) & 0x3FF;
    const imm_20 = (uimm >> 20) & 1;
    return @as(u32, opcode) |
        (@as(u32, rd) << 7) |
        (imm_19_12 << 12) |
        (imm_11 << 20) |
        (imm_10_1 << 21) |
        (imm_20 << 31);
}

// ---- Specific R-Type RV64 Instructions ----
pub fn add(rd: u5, rs1: u5, rs2: u5) u32 { return encodeR(@intFromEnum(Opcode.op), rd, 0x0, rs1, rs2, 0x00); }
pub fn sub(rd: u5, rs1: u5, rs2: u5) u32 { return encodeR(@intFromEnum(Opcode.op), rd, 0x0, rs1, rs2, 0x20); }
pub fn sll(rd: u5, rs1: u5, rs2: u5) u32 { return encodeR(@intFromEnum(Opcode.op), rd, 0x1, rs1, rs2, 0x00); }
pub fn slt(rd: u5, rs1: u5, rs2: u5) u32 { return encodeR(@intFromEnum(Opcode.op), rd, 0x2, rs1, rs2, 0x00); }
pub fn sltu(rd: u5, rs1: u5, rs2: u5) u32 { return encodeR(@intFromEnum(Opcode.op), rd, 0x3, rs1, rs2, 0x00); }
pub fn xor_(rd: u5, rs1: u5, rs2: u5) u32 { return encodeR(@intFromEnum(Opcode.op), rd, 0x4, rs1, rs2, 0x00); }
pub fn srl(rd: u5, rs1: u5, rs2: u5) u32 { return encodeR(@intFromEnum(Opcode.op), rd, 0x5, rs1, rs2, 0x00); }
pub fn sra(rd: u5, rs1: u5, rs2: u5) u32 { return encodeR(@intFromEnum(Opcode.op), rd, 0x5, rs1, rs2, 0x20); }
pub fn or_(rd: u5, rs1: u5, rs2: u5) u32 { return encodeR(@intFromEnum(Opcode.op), rd, 0x6, rs1, rs2, 0x00); }
pub fn and_(rd: u5, rs1: u5, rs2: u5) u32 { return encodeR(@intFromEnum(Opcode.op), rd, 0x7, rs1, rs2, 0x00); }

// ---- RV64 32-bit Word Variant R-Type Instructions ----
pub fn addw(rd: u5, rs1: u5, rs2: u5) u32 { return encodeR(@intFromEnum(Opcode.op_32), rd, 0x0, rs1, rs2, 0x00); }
pub fn subw(rd: u5, rs1: u5, rs2: u5) u32 { return encodeR(@intFromEnum(Opcode.op_32), rd, 0x0, rs1, rs2, 0x20); }
pub fn sllw(rd: u5, rs1: u5, rs2: u5) u32 { return encodeR(@intFromEnum(Opcode.op_32), rd, 0x1, rs1, rs2, 0x00); }
pub fn srlw(rd: u5, rs1: u5, rs2: u5) u32 { return encodeR(@intFromEnum(Opcode.op_32), rd, 0x5, rs1, rs2, 0x00); }
pub fn sraw(rd: u5, rs1: u5, rs2: u5) u32 { return encodeR(@intFromEnum(Opcode.op_32), rd, 0x5, rs1, rs2, 0x20); }

// ---- Specific I-Type RV64 Instructions ----
pub fn addi(rd: u5, rs1: u5, imm: i12) u32 { return encodeI(@intFromEnum(Opcode.op_imm), rd, 0x0, rs1, imm); }
pub fn slti(rd: u5, rs1: u5, imm: i12) u32 { return encodeI(@intFromEnum(Opcode.op_imm), rd, 0x2, rs1, imm); }
pub fn sltiu(rd: u5, rs1: u5, imm: i12) u32 { return encodeI(@intFromEnum(Opcode.op_imm), rd, 0x3, rs1, imm); }
pub fn xori(rd: u5, rs1: u5, imm: i12) u32 { return encodeI(@intFromEnum(Opcode.op_imm), rd, 0x4, rs1, imm); }
pub fn ori(rd: u5, rs1: u5, imm: i12) u32 { return encodeI(@intFromEnum(Opcode.op_imm), rd, 0x6, rs1, imm); }
pub fn andi(rd: u5, rs1: u5, imm: i12) u32 { return encodeI(@intFromEnum(Opcode.op_imm), rd, 0x7, rs1, imm); }

// ---- RV64 32-bit Word Variant I-Type Instructions ----
pub fn addiw(rd: u5, rs1: u5, imm: i12) u32 { return encodeI(@intFromEnum(Opcode.op_imm_32), rd, 0x0, rs1, imm); }
pub fn slliw(rd: u5, rs1: u5, shamt: u5) u32 { return encodeI(@intFromEnum(Opcode.op_imm_32), rd, 0x1, rs1, @as(i12, shamt)); }
pub fn srliw(rd: u5, rs1: u5, shamt: u5) u32 { return encodeI(@intFromEnum(Opcode.op_imm_32), rd, 0x5, rs1, @as(i12, shamt)); }
pub fn sraiw(rd: u5, rs1: u5, shamt: u5) u32 { return encodeI(@intFromEnum(Opcode.op_imm_32), rd, 0x5, rs1, @as(i12, shamt) | 0x400); }

// ---- Load & Store Instructions ----
pub fn lb(rd: u5, rs1: u5, imm: i12) u32 { return encodeI(@intFromEnum(Opcode.load), rd, 0x0, rs1, imm); }
pub fn lh(rd: u5, rs1: u5, imm: i12) u32 { return encodeI(@intFromEnum(Opcode.load), rd, 0x1, rs1, imm); }
pub fn lw(rd: u5, rs1: u5, imm: i12) u32 { return encodeI(@intFromEnum(Opcode.load), rd, 0x2, rs1, imm); }
pub fn ld(rd: u5, rs1: u5, imm: i12) u32 { return encodeI(@intFromEnum(Opcode.load), rd, 0x3, rs1, imm); }
pub fn lbu(rd: u5, rs1: u5, imm: i12) u32 { return encodeI(@intFromEnum(Opcode.load), rd, 0x4, rs1, imm); }
pub fn lhu(rd: u5, rs1: u5, imm: i12) u32 { return encodeI(@intFromEnum(Opcode.load), rd, 0x5, rs1, imm); }
pub fn lwu(rd: u5, rs1: u5, imm: i12) u32 { return encodeI(@intFromEnum(Opcode.load), rd, 0x6, rs1, imm); }

pub fn sb(rs1: u5, rs2: u5, imm: i12) u32 { return encodeS(@intFromEnum(Opcode.store), 0x0, rs1, rs2, imm); }
pub fn sh(rs1: u5, rs2: u5, imm: i12) u32 { return encodeS(@intFromEnum(Opcode.store), 0x1, rs1, rs2, imm); }
pub fn sw(rs1: u5, rs2: u5, imm: i12) u32 { return encodeS(@intFromEnum(Opcode.store), 0x2, rs1, rs2, imm); }
pub fn sd(rs1: u5, rs2: u5, imm: i12) u32 { return encodeS(@intFromEnum(Opcode.store), 0x3, rs1, rs2, imm); }

// ---- Branch & Control Flow Instructions ----
pub fn beq(rs1: u5, rs2: u5, imm: i13) u32 { return encodeB(@intFromEnum(Opcode.branch), 0x0, rs1, rs2, imm); }
pub fn bne(rs1: u5, rs2: u5, imm: i13) u32 { return encodeB(@intFromEnum(Opcode.branch), 0x1, rs1, rs2, imm); }
pub fn blt(rs1: u5, rs2: u5, imm: i13) u32 { return encodeB(@intFromEnum(Opcode.branch), 0x4, rs1, rs2, imm); }
pub fn bge(rs1: u5, rs2: u5, imm: i13) u32 { return encodeB(@intFromEnum(Opcode.branch), 0x5, rs1, rs2, imm); }
pub fn bltu(rs1: u5, rs2: u5, imm: i13) u32 { return encodeB(@intFromEnum(Opcode.branch), 0x6, rs1, rs2, imm); }
pub fn bgeu(rs1: u5, rs2: u5, imm: i13) u32 { return encodeB(@intFromEnum(Opcode.branch), 0x7, rs1, rs2, imm); }

pub fn jal(rd: u5, imm: i21) u32 { return encodeJ(@intFromEnum(Opcode.jal), rd, imm); }
pub fn jalr(rd: u5, rs1: u5, imm: i12) u32 { return encodeI(@intFromEnum(Opcode.jalr), rd, 0x0, rs1, imm); }

pub fn lui(rd: u5, imm: i20) u32 { return encodeU(@intFromEnum(Opcode.lui), rd, imm); }
pub fn auipc(rd: u5, imm: i20) u32 { return encodeU(@intFromEnum(Opcode.auipc), rd, imm); }

// ---- System & Memory Synchronization ----
pub fn ecall() u32 { return encodeI(@intFromEnum(Opcode.system), 0, 0x0, 0, 0x000); }
pub fn ebreak() u32 { return encodeI(@intFromEnum(Opcode.system), 0, 0x0, 0, 0x001); }
pub fn fence_i() u32 { return encodeI(@intFromEnum(Opcode.system), 0, 0x1, 0, 0x000); }

pub inline fn fenceI() void {
    if (comptime @import("builtin").target.cpu.arch.isRISCV()) {
        asm volatile ("fence.i");
    }
}

test "RV64 instruction encoding" {
    const add_insn = add(10, 11, 12);
    try std.testing.expectEqual(@as(u32, 0x00c58533), add_insn);

    const addiw_insn = addiw(10, 11, 42);
    try std.testing.expectEqual(@as(u32, 0x02a5851b), addiw_insn);
}
