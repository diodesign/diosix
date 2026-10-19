// RV32 Instruction Decoder & Bitfield Unpacker for Diosix Hypervisor.
//
// Decodes 32-bit RV32I/M/A/F/D/V instructions and delegates 16-bit RV32C
// compressed instruction decompression to rv32c.zig.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const rv32c = @import("rv32c.zig");

pub const decompressRvc = rv32c.decompressRvc;
const signExtend = rv32c.signExtend;

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

/// Decode standard 32-bit RV32I or decompressed 16-bit RV32C instruction.
pub fn decode(raw_code: u32) DecodedInsn {
    var code = raw_code;
    var len: u8 = 4;

    // Check if 16-bit compressed instruction (bits [1:0] != 0b11).
    if ((code & 0x3) != 0x3) {
        if (decompressRvc(@as(u16, @truncate(code)))) |decompressed| {
            code = decompressed;
            len = 2;
        } else {
            return .{ .insn = .{ .unknown = code }, .len = 2 };
        }
    }

    const opcode = code & 0x7f;
    const rd = @as(u5, @truncate((code >> 7) & 0x1f));
    const funct3 = @as(u3, @truncate((code >> 12) & 0x7));
    const rs1 = @as(u5, @truncate((code >> 15) & 0x1f));
    const rs2 = @as(u5, @truncate((code >> 20) & 0x1f));
    const funct7 = @as(u7, @truncate((code >> 25) & 0x7f));

    const i_imm = signExtend((code >> 20) & 0xfff, 12);
    const s_imm = signExtend(
        ((code >> 7) & 0x1f) | (((code >> 25) & 0x7f) << 5),
        12,
    );
    const b_imm = signExtend(
        (((code >> 8) & 0xf) << 1) |
            (((code >> 25) & 0x3f) << 5) |
            (((code >> 7) & 0x1) << 11) |
            (((code >> 31) & 0x1) << 12),
        13,
    );
    const u_imm = signExtend((code >> 12) & 0xfffff, 20);
    const j_imm = signExtend(
        (((code >> 21) & 0x3ff) << 1) |
            (((code >> 20) & 0x1) << 11) |
            (((code >> 12) & 0xff) << 12) |
            (((code >> 31) & 0x1) << 20),
        21,
    );
    const csr_id: u12 = @truncate(@as(u32, @bitCast(i_imm)));

    const parsed: Instruction = switch (opcode) {
        0x33 => switch (funct3) {
            0x0 => if (funct7 == 0x20)
                .{ .sub = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else if (funct7 == 0x01)
                .{ .mul = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else if (funct7 == 0x00)
                .{ .add = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else
                .{ .unknown = code },
            0x1 => if (funct7 == 0x01)
                .{ .mulh = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else if (funct7 == 0x00)
                .{ .sll = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else
                .{ .unknown = code },
            0x2 => if (funct7 == 0x01)
                .{ .mulhsu = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else if (funct7 == 0x00)
                .{ .slt = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else
                .{ .unknown = code },
            0x3 => if (funct7 == 0x01)
                .{ .mulhu = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else if (funct7 == 0x00)
                .{ .sltu = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else
                .{ .unknown = code },
            0x4 => if (funct7 == 0x01)
                .{ .div = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else if (funct7 == 0x00)
                .{ .xor_ = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else
                .{ .unknown = code },
            0x5 => if (funct7 == 0x20)
                .{ .sra = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else if (funct7 == 0x01)
                .{ .divu = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else if (funct7 == 0x00)
                .{ .srl = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else
                .{ .unknown = code },
            0x6 => if (funct7 == 0x01)
                .{ .rem = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else if (funct7 == 0x00)
                .{ .or_ = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else
                .{ .unknown = code },
            0x7 => if (funct7 == 0x01)
                .{ .remu = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else if (funct7 == 0x00)
                .{ .and_ = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else
                .{ .unknown = code },
        },
        0x13 => switch (funct3) {
            0x0 => .{ .addi = .{ .rd = rd, .rs1 = rs1, .imm = i_imm } },
            0x1 => if (funct7 == 0x00)
                .{ .slli = .{ .rd = rd, .rs1 = rs1, .shamt = @truncate(rs2) } }
            else
                .{ .unknown = code },
            0x2 => .{ .slti = .{ .rd = rd, .rs1 = rs1, .imm = i_imm } },
            0x3 => .{ .sltiu = .{ .rd = rd, .rs1 = rs1, .imm = i_imm } },
            0x4 => .{ .xori = .{ .rd = rd, .rs1 = rs1, .imm = i_imm } },
            0x5 => if (funct7 == 0x20)
                .{ .srai = .{ .rd = rd, .rs1 = rs1, .shamt = @truncate(rs2) } }
            else if (funct7 == 0x00)
                .{ .srli = .{ .rd = rd, .rs1 = rs1, .shamt = @truncate(rs2) } }
            else
                .{ .unknown = code },
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
        0x53, 0x43, 0x47, 0x4b, 0x4f => .{ .fp_op = .{ .raw = code } },

        0x63 => switch (funct3) {
            0x0 => .{ .beq = .{ .rs1 = rs1, .rs2 = rs2, .offset = b_imm } },
            0x1 => .{ .bne = .{ .rs1 = rs1, .rs2 = rs2, .offset = b_imm } },
            0x4 => .{ .blt = .{ .rs1 = rs1, .rs2 = rs2, .offset = b_imm } },
            0x5 => .{ .bge = .{ .rs1 = rs1, .rs2 = rs2, .offset = b_imm } },
            0x6 => .{ .bltu = .{ .rs1 = rs1, .rs2 = rs2, .offset = b_imm } },
            0x7 => .{ .bgeu = .{ .rs1 = rs1, .rs2 = rs2, .offset = b_imm } },
            else => .{ .unknown = code },
        },
        0x6f => .{ .jal = .{ .rd = rd, .offset = j_imm } },
        0x67 => .{ .jalr = .{ .rd = rd, .rs1 = rs1, .offset = i_imm } },
        0x37 => .{ .lui = .{ .rd = rd, .imm = u_imm } },
        0x17 => .{ .auipc = .{ .rd = rd, .imm = u_imm } },
        0x73 => switch (funct3) {
            0x0 => switch (i_imm >> 5) {
                0x000 => switch (i_imm & 0x1f) {
                    0x00 => .ecall,
                    0x01 => .ebreak,
                    else => .{ .unknown = code },
                },
                0x008 => switch (i_imm & 0x1f) {
                    0x02 => .sret,
                    0x05 => .wfi,
                    else => .{ .unknown = code },
                },
                0x018 => switch (i_imm & 0x1f) {
                    0x02 => .mret,
                    else => .{ .unknown = code },
                },
                0x009 => .{ .sfence_vma = .{ .rs1 = rs1, .rs2 = rs2 } },
                else => .{ .unknown = code },
            },
            0x1 => .{ .csrrw = .{ .rd = rd, .rs1 = rs1, .csr = csr_id } },
            0x2 => .{ .csrrs = .{ .rd = rd, .rs1 = rs1, .csr = csr_id } },
            0x3 => .{ .csrrc = .{ .rd = rd, .rs1 = rs1, .csr = csr_id } },
            0x5 => .{ .csrrwi = .{ .rd = rd, .uimm = rs1, .csr = csr_id } },
            0x6 => .{ .csrrsi = .{ .rd = rd, .uimm = rs1, .csr = csr_id } },
            0x7 => .{ .csrrci = .{ .rd = rd, .uimm = rs1, .csr = csr_id } },
            else => .{ .unknown = code },
        },
        0x0f => switch (funct3) {
            0x0 => if (code == 0x0100000f) .pause else .fence,
            0x1 => .fence_i,
            else => .{ .unknown = code },
        },
        0x57 => switch (funct3) {
            0x7 => .{ .vsetvli = .{ .rd = rd, .rs1 = rs1, .vtype = csr_id } },
            else => .{ .vector_op = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } },
        },
        0x2f => {
            if (funct3 != 0x2) {
                return .{ .insn = .{ .unknown = code }, .len = len };
            }
            const funct5 = @as(u5, @truncate((code >> 27) & 0x1f));
            const aq = @as(u1, @truncate((code >> 26) & 0x1));
            const rl = @as(u1, @truncate((code >> 25) & 0x1));
            const amo = AmoType{
                .rd = rd,
                .rs1 = rs1,
                .rs2 = rs2,
                .aq = aq,
                .rl = rl,
            };
            const lr = LrType{ .rd = rd, .rs1 = rs1, .aq = aq, .rl = rl };
            const amo_insn: Instruction = switch (funct5) {
                0x01 => .{ .amoswap_w = amo },
                0x00 => .{ .amoadd_w = amo },
                0x02 => .{ .lr_w = lr },
                0x03 => .{ .sc_w = amo },
                0x04 => .{ .amoxor_w = amo },
                0x0c => .{ .amoand_w = amo },
                0x08 => .{ .amoor_w = amo },
                0x10 => .{ .amomin_w = amo },
                0x14 => .{ .amomax_w = amo },
                0x18 => .{ .amominu_w = amo },
                0x1c => .{ .amomaxu_w = amo },
                else => .{ .unknown = code },
            };
            return .{ .insn = amo_insn, .len = len };
        },
        else => .{ .unknown = code },
    };

    return .{ .insn = parsed, .len = len };
}

test "RV32I Base Integer Instructions Decoding" {
    // add a0, a1, a2 (0x00c58533: rd=10, rs1=11, rs2=12).
    const add_dec = decode(0x00c58533);
    try std.testing.expectEqual(@as(usize, 4), add_dec.len);
    try std.testing.expectEqual(@as(u5, 10), add_dec.insn.add.rd);
    try std.testing.expectEqual(@as(u5, 11), add_dec.insn.add.rs1);
    try std.testing.expectEqual(@as(u5, 12), add_dec.insn.add.rs2);

    // sub a0, a1, a2 (0x40c58533).
    const sub_dec = decode(0x40c58533);
    try std.testing.expectEqual(@as(u5, 10), sub_dec.insn.sub.rd);

    // sll, slt, sltu, xor, srl, sra, or, and.
    try std.testing.expectEqual(@as(u5, 10), decode(0x00c59533).insn.sll.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x00c5a533).insn.slt.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x00c5b533).insn.sltu.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x00c5c533).insn.xor_.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x00c5d533).insn.srl.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x40c5d533).insn.sra.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x00c5e533).insn.or_.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x00c5f533).insn.and_.rd);

    // Unrecognized R-type funct7 (e.g., 0x7f) must decode to .unknown.
    try std.testing.expect(decode(0xfe000033).insn == .unknown);

    // addi sp, sp, -16 (0xff010113).
    const addi_dec = decode(0xff010113);
    try std.testing.expectEqual(@as(u5, 2), addi_dec.insn.addi.rd);
    try std.testing.expectEqual(@as(u5, 2), addi_dec.insn.addi.rs1);
    try std.testing.expectEqual(@as(i32, -16), addi_dec.insn.addi.imm);

    // lui a0, 0x12345 (0x12345537).
    const lui_dec = decode(0x12345537);
    try std.testing.expectEqual(@as(u5, 10), lui_dec.insn.lui.rd);
    try std.testing.expectEqual(@as(i32, 0x12345), lui_dec.insn.lui.imm);

    // auipc a0, 0x1000 (0x01000517).
    const auipc_dec = decode(0x01000517);
    try std.testing.expectEqual(@as(u5, 10), auipc_dec.insn.auipc.rd);
    try std.testing.expectEqual(@as(i32, 0x1000), auipc_dec.insn.auipc.imm);

    // lw a0, 8(sp) (0x00812503).
    const lw_dec = decode(0x00812503);
    try std.testing.expectEqual(@as(u5, 10), lw_dec.insn.lw.rd);
    try std.testing.expectEqual(@as(u5, 2), lw_dec.insn.lw.rs1);
    try std.testing.expectEqual(@as(i32, 8), lw_dec.insn.lw.offset);

    // sw a0, 12(sp) (0x00a12623).
    const sw_dec = decode(0x00a12623);
    try std.testing.expectEqual(@as(u5, 2), sw_dec.insn.sw.rs1);
    try std.testing.expectEqual(@as(u5, 10), sw_dec.insn.sw.rs2);
    try std.testing.expectEqual(@as(i32, 12), sw_dec.insn.sw.offset);
}

test "RV32M Multiply & Divide Decoding" {
    // mul a0, a1, a2 (0x02c58533).
    const mul_dec = decode(0x02c58533);
    try std.testing.expectEqual(@as(u5, 10), mul_dec.insn.mul.rd);
    try std.testing.expectEqual(@as(u5, 11), mul_dec.insn.mul.rs1);
    try std.testing.expectEqual(@as(u5, 12), mul_dec.insn.mul.rs2);

    // mulh, mulhsu, mulhu.
    try std.testing.expectEqual(@as(u5, 10), decode(0x02c59533).insn.mulh.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x02c5a533).insn.mulhsu.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x02c5b533).insn.mulhu.rd);

    // div, divu, rem, remu.
    try std.testing.expectEqual(@as(u5, 10), decode(0x02c5c533).insn.div.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x02c5d533).insn.divu.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x02c5e533).insn.rem.rd);
    try std.testing.expectEqual(@as(u5, 10), decode(0x02c5f533).insn.remu.rd);
}

test "RV32A Atomic Memory Instructions Decoding" {
    const eq = std.testing.expectEqual;
    const rd10: u5 = 10;

    // lr.w a0, (a1) (0x1005a52f).
    const lr_dec = decode(0x1005a52f);
    try eq(rd10, lr_dec.insn.lr_w.rd);
    try eq(@as(u5, 11), lr_dec.insn.lr_w.rs1);

    // sc.w a0, a2, (a1) (0x18c5a52f).
    const sc_dec = decode(0x18c5a52f);
    try eq(rd10, sc_dec.insn.sc_w.rd);
    try eq(@as(u5, 11), sc_dec.insn.sc_w.rs1);
    try eq(@as(u5, 12), sc_dec.insn.sc_w.rs2);

    // amoswap.w, amoadd.w, amoxor.w, amoand.w, amoor.w, amomin/max.
    try eq(rd10, decode(0x08c5a52f).insn.amoswap_w.rd);
    try eq(rd10, decode(0x00c5a52f).insn.amoadd_w.rd);
    try eq(rd10, decode(0x20c5a52f).insn.amoxor_w.rd);
    try eq(rd10, decode(0x60c5a52f).insn.amoand_w.rd);
    try eq(rd10, decode(0x40c5a52f).insn.amoor_w.rd);
    try eq(rd10, decode(0x80c5a52f).insn.amomin_w.rd);
    try eq(rd10, decode(0xa0c5a52f).insn.amomax_w.rd);
    try eq(rd10, decode(0xc0c5a52f).insn.amominu_w.rd);
    try eq(rd10, decode(0xe0c5a52f).insn.amomaxu_w.rd);

    // Non-word AMO funct3 (e.g., RV64A .d) must decode to .unknown.
    try std.testing.expect(decode(0x00c5b52f).insn == .unknown);
}

test "Barriers & CSR Instructions Decoding" {
    // fence (0x0ff0000f).
    const fence_dec = decode(0x0ff0000f);
    try std.testing.expect(fence_dec.insn == .fence);

    // fence.i (0x0000100f).
    const fence_i_dec = decode(0x0000100f);
    try std.testing.expect(fence_i_dec.insn == .fence_i);

    // csrrs a0, time, x0 (0xc0102573: rd=10, rs1=0, csr=0xC01).
    const csr_dec = decode(0xc0102573);
    try std.testing.expectEqual(@as(u5, 10), csr_dec.insn.csrrs.rd);
    try std.testing.expectEqual(@as(u5, 0), csr_dec.insn.csrrs.rs1);
    try std.testing.expectEqual(@as(u12, 0xc01), csr_dec.insn.csrrs.csr);
}
