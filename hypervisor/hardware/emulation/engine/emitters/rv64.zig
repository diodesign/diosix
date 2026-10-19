// Direct RV64 Machine Code Emitter for Diosix Dynamic Recompiler.
//
// Encodes RISC-V 64-bit machine instructions directly into memory buffers
// without an intermediate representation stage.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

/// Bitfield encodings for RISC-V opcodes.
pub const Opcode = enum(u7) {
    load = 0x03,
    load_fp = 0x07,
    op_imm = 0x13,
    auipc = 0x17,
    op_imm_32 = 0x1b,
    store = 0x23,
    store_fp = 0x27,
    amo = 0x2f,
    op = 0x33,
    lui = 0x37,
    op_32 = 0x3b,
    branch = 0x63,
    jalr = 0x67,
    jal = 0x6f,
    system = 0x73,
};

/// Helper to write a 32-bit instruction into a byte slice at offset.
pub fn emit(buf: []u8, offset: *usize, insn: u32) void {
    if (offset.* + 4 <= buf.len) {
        std.mem.writeInt(u32, buf[offset.*..][0..4], insn, .little);
        offset.* += 4;
    }
}

/// Generic R-Type encoder: opcode [6:0], rd [11:7], funct3 [14:12],
/// rs1 [19:15], rs2 [24:20], funct7 [31:25].
pub fn encodeR(
    opcode: u7,
    rd: u5,
    funct3: u3,
    rs1: u5,
    rs2: u5,
    funct7: u7,
) u32 {
    return @as(u32, opcode) | (@as(u32, rd) << 7) | (@as(u32, funct3) << 12) |
        (@as(u32, rs1) << 15) | (@as(u32, rs2) << 20) |
        (@as(u32, funct7) << 25);
}

/// Generic I-Type encoder: opcode [6:0], rd [11:7], funct3 [14:12],
/// rs1 [19:15], imm [31:20].
pub fn encodeI(opcode: u7, rd: u5, funct3: u3, rs1: u5, imm: i12) u32 {
    const uimm = @as(u32, @bitCast(@as(i32, imm))) & 0xfff;
    return @as(u32, opcode) | (@as(u32, rd) << 7) | (@as(u32, funct3) << 12) |
        (@as(u32, rs1) << 15) | (uimm << 20);
}

/// Generic S-Type encoder: opcode [6:0], imm[4:0] [11:7], funct3 [14:12],
/// rs1 [19:15], rs2 [24:20], imm[11:5] [31:25].
pub fn encodeS(opcode: u7, funct3: u3, rs1: u5, rs2: u5, imm: i12) u32 {
    const uimm = @as(u32, @bitCast(@as(i32, imm))) & 0xfff;
    const imm_4_0 = uimm & 0x1f;
    const imm_11_5 = (uimm >> 5) & 0x7f;
    return @as(u32, opcode) | (imm_4_0 << 7) | (@as(u32, funct3) << 12) |
        (@as(u32, rs1) << 15) | (@as(u32, rs2) << 20) | (imm_11_5 << 25);
}

/// Generic B-Type encoder: opcode [6:0], imm[11] [7], imm[4:1] [11:8],
/// funct3 [14:12], rs1 [19:15], rs2 [24:20], imm[10:5] [30:25], imm[12] [31].
pub fn encodeB(opcode: u7, funct3: u3, rs1: u5, rs2: u5, imm: i13) u32 {
    const uimm = @as(u32, @bitCast(@as(i32, imm))) & 0x1fff;
    const imm_11 = (uimm >> 11) & 1;
    const imm_4_1 = (uimm >> 1) & 0xf;
    const imm_10_5 = (uimm >> 5) & 0x3f;
    const imm_12 = (uimm >> 12) & 1;
    return @as(u32, opcode) | (imm_11 << 7) | (imm_4_1 << 8) |
        (@as(u32, funct3) << 12) | (@as(u32, rs1) << 15) |
        (@as(u32, rs2) << 20) | (imm_10_5 << 25) | (imm_12 << 31);
}

/// Generic U-Type encoder: opcode [6:0], rd [11:7], imm[31:12] [31:12].
pub fn encodeU(opcode: u7, rd: u5, imm: i20) u32 {
    const uimm = @as(u32, @bitCast(@as(i32, imm))) & 0xfffff;
    return @as(u32, opcode) | (@as(u32, rd) << 7) | (uimm << 12);
}

/// Generic J-Type encoder: opcode [6:0], rd [11:7], imm[19:12] [19:12],
/// imm[11] [20], imm[10:1] [30:21], imm[20] [31].
pub fn encodeJ(opcode: u7, rd: u5, imm: i21) u32 {
    const uimm = @as(u32, @bitCast(@as(i32, imm))) & 0x1fffff;
    const imm_19_12 = (uimm >> 12) & 0xff;
    const imm_11 = (uimm >> 11) & 1;
    const imm_10_1 = (uimm >> 1) & 0x3ff;
    const imm_20 = (uimm >> 20) & 1;
    return @as(u32, opcode) | (@as(u32, rd) << 7) | (imm_19_12 << 12) |
        (imm_11 << 20) | (imm_10_1 << 21) | (imm_20 << 31);
}

// Specific R-Type RV64 instructions.
pub fn add(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op), rd, 0x0, rs1, rs2, 0x00);
}
pub fn sub(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op), rd, 0x0, rs1, rs2, 0x20);
}
pub fn sll(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op), rd, 0x1, rs1, rs2, 0x00);
}
pub fn slt(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op), rd, 0x2, rs1, rs2, 0x00);
}
pub fn sltu(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op), rd, 0x3, rs1, rs2, 0x00);
}
pub fn xor_(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op), rd, 0x4, rs1, rs2, 0x00);
}
pub fn srl(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op), rd, 0x5, rs1, rs2, 0x00);
}
pub fn sra(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op), rd, 0x5, rs1, rs2, 0x20);
}
pub fn or_(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op), rd, 0x6, rs1, rs2, 0x00);
}
pub fn and_(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op), rd, 0x7, rs1, rs2, 0x00);
}

// RV64 32-bit word variant R-Type instructions.
pub fn addw(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op_32), rd, 0x0, rs1, rs2, 0x00);
}
pub fn subw(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op_32), rd, 0x0, rs1, rs2, 0x20);
}
pub fn sllw(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op_32), rd, 0x1, rs1, rs2, 0x00);
}
pub fn srlw(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op_32), rd, 0x5, rs1, rs2, 0x00);
}
pub fn sraw(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op_32), rd, 0x5, rs1, rs2, 0x20);
}

// RV64 M-extension instructions.
pub fn mul(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op), rd, 0x0, rs1, rs2, 0x01);
}
pub fn mulw(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op_32), rd, 0x0, rs1, rs2, 0x01);
}
pub fn div(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op), rd, 0x4, rs1, rs2, 0x01);
}
pub fn divw(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op_32), rd, 0x4, rs1, rs2, 0x01);
}
pub fn divu(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op), rd, 0x5, rs1, rs2, 0x01);
}
pub fn divuw(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op_32), rd, 0x5, rs1, rs2, 0x01);
}
pub fn rem(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op), rd, 0x6, rs1, rs2, 0x01);
}
pub fn remw(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op_32), rd, 0x6, rs1, rs2, 0x01);
}
pub fn remu(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op), rd, 0x7, rs1, rs2, 0x01);
}
pub fn remuw(rd: u5, rs1: u5, rs2: u5) u32 {
    return encodeR(@backingInt(Opcode.op_32), rd, 0x7, rs1, rs2, 0x01);
}

pub const SRA_IMM_BIT10: i12 = 0x400;
pub const IMM12_SIGN_BIT: i32 = 0x800;
pub const IMM12_BITS: u5 = 12;
pub const IMM12_MASK: u32 = 0xfff;
pub const FUNCT3_AMO_W: u3 = 0x2;

pub const AmoFunct5 = struct {
    pub const ADD: u5 = 0x00;
    pub const SWAP: u5 = 0x01;
    pub const LR: u5 = 0x02;
    pub const SC: u5 = 0x03;
    pub const XOR: u5 = 0x04;
    pub const OR: u5 = 0x08;
    pub const AND: u5 = 0x0c;
    pub const MIN: u5 = 0x10;
    pub const MAX: u5 = 0x14;
    pub const MINU: u5 = 0x18;
    pub const MAXU: u5 = 0x1c;
};

const OPC_IMM: u7 = @backingInt(Opcode.op_imm);
const OPC_IMM32: u7 = @backingInt(Opcode.op_imm_32);

// Specific I-Type RV64 instructions.
pub fn addi(rd: u5, rs1: u5, imm: i12) u32 {
    return encodeI(OPC_IMM, rd, 0x0, rs1, imm);
}
pub fn slti(rd: u5, rs1: u5, imm: i12) u32 {
    return encodeI(OPC_IMM, rd, 0x2, rs1, imm);
}
pub fn sltiu(rd: u5, rs1: u5, imm: i12) u32 {
    return encodeI(OPC_IMM, rd, 0x3, rs1, imm);
}
pub fn xori(rd: u5, rs1: u5, imm: i12) u32 {
    return encodeI(OPC_IMM, rd, 0x4, rs1, imm);
}
pub fn ori(rd: u5, rs1: u5, imm: i12) u32 {
    return encodeI(OPC_IMM, rd, 0x6, rs1, imm);
}
pub fn andi(rd: u5, rs1: u5, imm: i12) u32 {
    return encodeI(OPC_IMM, rd, 0x7, rs1, imm);
}
pub fn slli(rd: u5, rs1: u5, shamt: u6) u32 {
    return encodeI(OPC_IMM, rd, 0x1, rs1, @as(i12, shamt));
}
pub fn srli(rd: u5, rs1: u5, shamt: u6) u32 {
    return encodeI(OPC_IMM, rd, 0x5, rs1, @as(i12, shamt));
}
pub fn srai(rd: u5, rs1: u5, shamt: u6) u32 {
    return encodeI(OPC_IMM, rd, 0x5, rs1, @as(i12, shamt) | SRA_IMM_BIT10);
}

// RV64 32-bit word variant I-Type instructions.
pub fn addiw(rd: u5, rs1: u5, imm: i12) u32 {
    return encodeI(OPC_IMM32, rd, 0x0, rs1, imm);
}
pub fn slliw(rd: u5, rs1: u5, shamt: u5) u32 {
    return encodeI(OPC_IMM32, rd, 0x1, rs1, @as(i12, shamt));
}
pub fn srliw(rd: u5, rs1: u5, shamt: u5) u32 {
    return encodeI(OPC_IMM32, rd, 0x5, rs1, @as(i12, shamt));
}
pub fn sraiw(rd: u5, rs1: u5, shamt: u5) u32 {
    return encodeI(OPC_IMM32, rd, 0x5, rs1, @as(i12, shamt) | SRA_IMM_BIT10);
}

// Load and store instructions.
pub fn lb(rd: u5, rs1: u5, imm: i12) u32 {
    return encodeI(@backingInt(Opcode.load), rd, 0x0, rs1, imm);
}
pub fn lh(rd: u5, rs1: u5, imm: i12) u32 {
    return encodeI(@backingInt(Opcode.load), rd, 0x1, rs1, imm);
}
pub fn lw(rd: u5, rs1: u5, imm: i12) u32 {
    return encodeI(@backingInt(Opcode.load), rd, 0x2, rs1, imm);
}
pub fn ld(rd: u5, rs1: u5, imm: i12) u32 {
    return encodeI(@backingInt(Opcode.load), rd, 0x3, rs1, imm);
}
pub fn lbu(rd: u5, rs1: u5, imm: i12) u32 {
    return encodeI(@backingInt(Opcode.load), rd, 0x4, rs1, imm);
}
pub fn lhu(rd: u5, rs1: u5, imm: i12) u32 {
    return encodeI(@backingInt(Opcode.load), rd, 0x5, rs1, imm);
}
pub fn lwu(rd: u5, rs1: u5, imm: i12) u32 {
    return encodeI(@backingInt(Opcode.load), rd, 0x6, rs1, imm);
}

pub fn sb(rs1: u5, rs2: u5, imm: i12) u32 {
    return encodeS(@backingInt(Opcode.store), 0x0, rs1, rs2, imm);
}
pub fn sh(rs1: u5, rs2: u5, imm: i12) u32 {
    return encodeS(@backingInt(Opcode.store), 0x1, rs1, rs2, imm);
}
pub fn sw(rs1: u5, rs2: u5, imm: i12) u32 {
    return encodeS(@backingInt(Opcode.store), 0x2, rs1, rs2, imm);
}
pub fn sd(rs1: u5, rs2: u5, imm: i12) u32 {
    return encodeS(@backingInt(Opcode.store), 0x3, rs1, rs2, imm);
}

// Floating-point load and store instructions.
pub fn flw(rd: u5, rs1: u5, imm: i12) u32 {
    return encodeI(@backingInt(Opcode.load_fp), rd, 0x2, rs1, imm);
}
pub fn fld(rd: u5, rs1: u5, imm: i12) u32 {
    return encodeI(@backingInt(Opcode.load_fp), rd, 0x3, rs1, imm);
}
pub fn fsw(rs1: u5, rs2: u5, imm: i12) u32 {
    return encodeS(@backingInt(Opcode.store_fp), 0x2, rs1, rs2, imm);
}
pub fn fsd(rs1: u5, rs2: u5, imm: i12) u32 {
    return encodeS(@backingInt(Opcode.store_fp), 0x3, rs1, rs2, imm);
}

// Branch and control flow instructions.
pub fn beq(rs1: u5, rs2: u5, imm: i13) u32 {
    return encodeB(@backingInt(Opcode.branch), 0x0, rs1, rs2, imm);
}
pub fn bne(rs1: u5, rs2: u5, imm: i13) u32 {
    return encodeB(@backingInt(Opcode.branch), 0x1, rs1, rs2, imm);
}
pub fn blt(rs1: u5, rs2: u5, imm: i13) u32 {
    return encodeB(@backingInt(Opcode.branch), 0x4, rs1, rs2, imm);
}
pub fn bge(rs1: u5, rs2: u5, imm: i13) u32 {
    return encodeB(@backingInt(Opcode.branch), 0x5, rs1, rs2, imm);
}
pub fn bltu(rs1: u5, rs2: u5, imm: i13) u32 {
    return encodeB(@backingInt(Opcode.branch), 0x6, rs1, rs2, imm);
}
pub fn bgeu(rs1: u5, rs2: u5, imm: i13) u32 {
    return encodeB(@backingInt(Opcode.branch), 0x7, rs1, rs2, imm);
}

pub fn jal(rd: u5, imm: i21) u32 {
    return encodeJ(@backingInt(Opcode.jal), rd, imm);
}
pub fn jalr(rd: u5, rs1: u5, imm: i12) u32 {
    return encodeI(@backingInt(Opcode.jalr), rd, 0x0, rs1, imm);
}

pub fn lui(rd: u5, imm: i20) u32 {
    return encodeU(@backingInt(Opcode.lui), rd, imm);
}
pub fn auipc(rd: u5, imm: i20) u32 {
    return encodeU(@backingInt(Opcode.auipc), rd, imm);
}

pub const Imm32Split = struct {
    upper: i20,
    lower: i12,
};

/// Split a 32-bit value into `upper` (20-bit signed for `lui`/`auipc`) and
/// `lower` (12-bit signed for `addi`/`addiw`/`jalr`), compensating for 12-bit
/// sign extension.
pub fn splitImm32(val: u32) Imm32Split {
    const val_i32 = @as(i32, @bitCast(val));
    const upper = @as(
        i20,
        @truncate((val_i32 +% IMM12_SIGN_BIT) >> IMM12_BITS),
    );
    const lower = @as(i12, @bitCast(@as(u12, @truncate(val & IMM12_MASK))));
    return .{ .upper = upper, .lower = lower };
}

// Atomic instructions (RV32A/RV64A).
pub fn encodeA(funct5: u5, aq: u1, rl: u1, rd: u5, rs1: u5, rs2: u5) u32 {
    const opcode: u7 = @backingInt(Opcode.amo);
    return @as(u32, opcode) |
        (@as(u32, rd) << 7) |
        (@as(u32, FUNCT3_AMO_W) << 12) |
        (@as(u32, rs1) << 15) |
        (@as(u32, rs2) << 20) |
        (@as(u32, rl) << 25) |
        (@as(u32, aq) << 26) |
        (@as(u32, funct5) << 27);
}

pub fn lr_w(rd: u5, rs1: u5, aq: u1, rl: u1) u32 {
    return encodeA(AmoFunct5.LR, aq, rl, rd, rs1, 0);
}
pub fn sc_w(rd: u5, rs1: u5, rs2: u5, aq: u1, rl: u1) u32 {
    return encodeA(AmoFunct5.SC, aq, rl, rd, rs1, rs2);
}
pub fn amoswap_w(rd: u5, rs1: u5, rs2: u5, aq: u1, rl: u1) u32 {
    return encodeA(AmoFunct5.SWAP, aq, rl, rd, rs1, rs2);
}
pub fn amoadd_w(rd: u5, rs1: u5, rs2: u5, aq: u1, rl: u1) u32 {
    return encodeA(AmoFunct5.ADD, aq, rl, rd, rs1, rs2);
}
pub fn amoxor_w(rd: u5, rs1: u5, rs2: u5, aq: u1, rl: u1) u32 {
    return encodeA(AmoFunct5.XOR, aq, rl, rd, rs1, rs2);
}
pub fn amoand_w(rd: u5, rs1: u5, rs2: u5, aq: u1, rl: u1) u32 {
    return encodeA(AmoFunct5.AND, aq, rl, rd, rs1, rs2);
}
pub fn amoor_w(rd: u5, rs1: u5, rs2: u5, aq: u1, rl: u1) u32 {
    return encodeA(AmoFunct5.OR, aq, rl, rd, rs1, rs2);
}
pub fn amomin_w(rd: u5, rs1: u5, rs2: u5, aq: u1, rl: u1) u32 {
    return encodeA(AmoFunct5.MIN, aq, rl, rd, rs1, rs2);
}
pub fn amomax_w(rd: u5, rs1: u5, rs2: u5, aq: u1, rl: u1) u32 {
    return encodeA(AmoFunct5.MAX, aq, rl, rd, rs1, rs2);
}
pub fn amominu_w(rd: u5, rs1: u5, rs2: u5, aq: u1, rl: u1) u32 {
    return encodeA(AmoFunct5.MINU, aq, rl, rd, rs1, rs2);
}
pub fn amomaxu_w(rd: u5, rs1: u5, rs2: u5, aq: u1, rl: u1) u32 {
    return encodeA(AmoFunct5.MAXU, aq, rl, rd, rs1, rs2);
}

// System and memory synchronization.
pub const FENCE_IORW: u32 = 0x0ff0000f;

pub fn csrrs(rd: u5, csr: u12, rs1: u5) u32 {
    return encodeI(@backingInt(Opcode.system), rd, 0x2, rs1, @bitCast(csr));
}
pub fn ecall() u32 {
    return encodeI(@backingInt(Opcode.system), 0, 0x0, 0, 0x000);
}
pub fn ebreak() u32 {
    return encodeI(@backingInt(Opcode.system), 0, 0x0, 0, 0x001);
}
pub fn fence_i() u32 {
    return encodeI(@backingInt(Opcode.system), 0, 0x1, 0, 0x000);
}

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

    const amoadd_insn = amoadd_w(10, 11, 12, 0, 0);
    try std.testing.expectEqual(@as(u32, 0x00c5a52f), amoadd_insn);
    std.testing.refAllDecls(@This());
}
