// RV32 Instruction Decoder & Bitfield Unpacker for Diosix Hypervisor.
//
// Decodes 32-bit RV32I/M/A/F/D/V instructions and delegates 16-bit RV32C
// compressed instruction decompression to rv32c.zig.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const rv32c = @import("rv32c.zig");
const encoding = @import("rv32/encoding.zig");

pub const decompressRvc = rv32c.decompressRvc;
pub const signExtend = encoding.signExtend;
pub const LoadType = encoding.LoadType;
pub const BType = encoding.BType;
pub const StoreType = encoding.StoreType;
pub const CsrRType = encoding.CsrRType;
pub const CsrIType = encoding.CsrIType;
pub const LrType = encoding.LrType;
pub const AmoType = encoding.AmoType;
pub const Instruction = encoding.Instruction;
pub const DecodedInsn = encoding.DecodedInsn;

const AmoFunct5 = encoding.AmoFunct5;

/// Decode standard 32-bit RV32I or decompressed 16-bit RV32C instruction.
pub fn decode(raw_code: u32) DecodedInsn {
    const orig_code = raw_code;
    var code = raw_code;
    var len: u8 = encoding.INSN_LEN_STANDARD;

    // Check if 16-bit compressed instruction (bits [1:0] != 0b11).
    if ((code & encoding.RVC_QUADRANT_MASK) != encoding.RVC_QUADRANT_32BIT) {
        if (decompressRvc(@as(u16, @truncate(code)))) |decompressed| {
            code = decompressed;
            len = encoding.INSN_LEN_COMPRESSED;
        } else {
            return .{
                .insn = .{ .unknown = orig_code },
                .len = encoding.INSN_LEN_COMPRESSED,
            };
        }
    }

    const opcode = code & 0x7f;
    const rd = @as(u5, @truncate((code >> 7) & 0x1f));
    const funct3 = @as(u3, @truncate((code >> 12) & 0x7));
    const rs1 = @as(u5, @truncate((code >> 15) & 0x1f));
    const rs2 = @as(u5, @truncate((code >> 20) & 0x1f));
    const funct7 = @as(u7, @truncate((code >> 25) & 0x7f));

    const i_imm = encoding.decodeIImm(code);
    const s_imm = encoding.decodeSImm(code);
    const b_imm = encoding.decodeBImm(code);
    const u_imm = encoding.decodeUImm(code);
    const j_imm = encoding.decodeJImm(code);
    const csr_id: u12 = @truncate(@as(u32, @bitCast(i_imm)));

    const parsed: Instruction = switch (opcode) {
        encoding.OPC_OP => switch (funct3) {
            0x0 => if (funct7 == encoding.FUNCT7_SUB_SRA)
                .{ .sub = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else if (funct7 == encoding.FUNCT7_MULDIV)
                .{ .mul = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else if (funct7 == encoding.FUNCT7_BASE)
                .{ .add = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else
                .{ .unknown = orig_code },
            0x1 => if (funct7 == encoding.FUNCT7_MULDIV)
                .{ .mulh = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else if (funct7 == encoding.FUNCT7_BASE)
                .{ .sll = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else
                .{ .unknown = orig_code },
            0x2 => if (funct7 == encoding.FUNCT7_MULDIV)
                .{ .mulhsu = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else if (funct7 == encoding.FUNCT7_BASE)
                .{ .slt = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else
                .{ .unknown = orig_code },
            0x3 => if (funct7 == encoding.FUNCT7_MULDIV)
                .{ .mulhu = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else if (funct7 == encoding.FUNCT7_BASE)
                .{ .sltu = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else
                .{ .unknown = orig_code },
            0x4 => if (funct7 == encoding.FUNCT7_MULDIV)
                .{ .div = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else if (funct7 == encoding.FUNCT7_BASE)
                .{ .xor_ = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else
                .{ .unknown = orig_code },
            0x5 => if (funct7 == encoding.FUNCT7_SUB_SRA)
                .{ .sra = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else if (funct7 == encoding.FUNCT7_MULDIV)
                .{ .divu = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else if (funct7 == encoding.FUNCT7_BASE)
                .{ .srl = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else
                .{ .unknown = orig_code },
            0x6 => if (funct7 == encoding.FUNCT7_MULDIV)
                .{ .rem = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else if (funct7 == encoding.FUNCT7_BASE)
                .{ .or_ = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else
                .{ .unknown = orig_code },
            0x7 => if (funct7 == encoding.FUNCT7_MULDIV)
                .{ .remu = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else if (funct7 == encoding.FUNCT7_BASE)
                .{ .and_ = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } }
            else
                .{ .unknown = orig_code },
        },
        encoding.OPC_OP_IMM => switch (funct3) {
            0x0 => .{ .addi = .{ .rd = rd, .rs1 = rs1, .imm = i_imm } },
            0x1 => if (funct7 == encoding.FUNCT7_BASE)
                .{ .slli = .{ .rd = rd, .rs1 = rs1, .shamt = @truncate(rs2) } }
            else
                .{ .unknown = orig_code },
            0x2 => .{ .slti = .{ .rd = rd, .rs1 = rs1, .imm = i_imm } },
            0x3 => .{ .sltiu = .{ .rd = rd, .rs1 = rs1, .imm = i_imm } },
            0x4 => .{ .xori = .{ .rd = rd, .rs1 = rs1, .imm = i_imm } },
            0x5 => if (funct7 == encoding.FUNCT7_SUB_SRA)
                .{ .srai = .{ .rd = rd, .rs1 = rs1, .shamt = @truncate(rs2) } }
            else if (funct7 == encoding.FUNCT7_BASE)
                .{ .srli = .{ .rd = rd, .rs1 = rs1, .shamt = @truncate(rs2) } }
            else
                .{ .unknown = orig_code },
            0x6 => .{ .ori = .{ .rd = rd, .rs1 = rs1, .imm = i_imm } },
            0x7 => .{ .andi = .{ .rd = rd, .rs1 = rs1, .imm = i_imm } },
        },
        encoding.OPC_LOAD => switch (funct3) {
            0x0 => .{ .lb = .{ .rd = rd, .rs1 = rs1, .offset = i_imm } },
            0x1 => .{ .lh = .{ .rd = rd, .rs1 = rs1, .offset = i_imm } },
            0x2 => .{ .lw = .{ .rd = rd, .rs1 = rs1, .offset = i_imm } },
            0x4 => .{ .lbu = .{ .rd = rd, .rs1 = rs1, .offset = i_imm } },
            0x5 => .{ .lhu = .{ .rd = rd, .rs1 = rs1, .offset = i_imm } },
            else => .{ .unknown = orig_code },
        },
        encoding.OPC_LOAD_FP => switch (funct3) {
            0x2 => .{ .flw = .{ .rd = rd, .rs1 = rs1, .offset = i_imm } },
            0x3 => .{ .fld = .{ .rd = rd, .rs1 = rs1, .offset = i_imm } },
            else => .{ .vload = .{ .vd = rd, .rs1 = rs1, .width = funct3 } },
        },
        encoding.OPC_STORE => switch (funct3) {
            0x0 => .{ .sb = .{ .rs1 = rs1, .rs2 = rs2, .offset = s_imm } },
            0x1 => .{ .sh = .{ .rs1 = rs1, .rs2 = rs2, .offset = s_imm } },
            0x2 => .{ .sw = .{ .rs1 = rs1, .rs2 = rs2, .offset = s_imm } },
            else => .{ .unknown = orig_code },
        },
        encoding.OPC_STORE_FP => switch (funct3) {
            0x2 => .{ .fsw = .{ .rs1 = rs1, .rs2 = rs2, .offset = s_imm } },
            0x3 => .{ .fsd = .{ .rs1 = rs1, .rs2 = rs2, .offset = s_imm } },
            else => .{ .vstore = .{ .vs3 = rd, .rs1 = rs1, .width = funct3 } },
        },
        encoding.OPC_OP_FP,
        encoding.OPC_MADD,
        encoding.OPC_MSUB,
        encoding.OPC_NMSUB,
        encoding.OPC_NMADD,
        => .{ .fp_op = .{ .raw = code } },

        encoding.OPC_BRANCH => switch (funct3) {
            0x0 => .{ .beq = .{ .rs1 = rs1, .rs2 = rs2, .offset = b_imm } },
            0x1 => .{ .bne = .{ .rs1 = rs1, .rs2 = rs2, .offset = b_imm } },
            0x4 => .{ .blt = .{ .rs1 = rs1, .rs2 = rs2, .offset = b_imm } },
            0x5 => .{ .bge = .{ .rs1 = rs1, .rs2 = rs2, .offset = b_imm } },
            0x6 => .{ .bltu = .{ .rs1 = rs1, .rs2 = rs2, .offset = b_imm } },
            0x7 => .{ .bgeu = .{ .rs1 = rs1, .rs2 = rs2, .offset = b_imm } },
            else => .{ .unknown = orig_code },
        },
        encoding.OPC_JAL => .{ .jal = .{ .rd = rd, .offset = j_imm } },
        encoding.OPC_JALR => if (funct3 == 0x0) .{
            .jalr = .{ .rd = rd, .rs1 = rs1, .offset = i_imm },
        } else .{ .unknown = orig_code },
        encoding.OPC_LUI => .{ .lui = .{ .rd = rd, .imm = u_imm } },
        encoding.OPC_AUIPC => .{ .auipc = .{ .rd = rd, .imm = u_imm } },
        encoding.OPC_SYSTEM => switch (funct3) {
            0x0 => switch (i_imm >> 5) {
                encoding.FUNCT7_SYS_PRIV => switch (i_imm & 0x1f) {
                    encoding.SYS_RS2_ECALL => .ecall,
                    encoding.SYS_RS2_EBREAK => .ebreak,
                    else => .{ .unknown = orig_code },
                },
                encoding.FUNCT7_SYS_SRET_WFI => switch (i_imm & 0x1f) {
                    encoding.SYS_RS2_RET => .sret,
                    encoding.SYS_RS2_WFI => .wfi,
                    else => .{ .unknown = orig_code },
                },
                encoding.FUNCT7_SYS_MRET => switch (i_imm & 0x1f) {
                    encoding.SYS_RS2_RET => .mret,
                    else => .{ .unknown = orig_code },
                },
                encoding.FUNCT7_SYS_SFENCE_VMA => .{
                    .sfence_vma = .{ .rs1 = rs1, .rs2 = rs2 },
                },
                else => .{ .unknown = orig_code },
            },
            0x1 => .{ .csrrw = .{ .rd = rd, .rs1 = rs1, .csr = csr_id } },
            0x2 => .{ .csrrs = .{ .rd = rd, .rs1 = rs1, .csr = csr_id } },
            0x3 => .{ .csrrc = .{ .rd = rd, .rs1 = rs1, .csr = csr_id } },
            0x5 => .{ .csrrwi = .{ .rd = rd, .uimm = rs1, .csr = csr_id } },
            0x6 => .{ .csrrsi = .{ .rd = rd, .uimm = rs1, .csr = csr_id } },
            0x7 => .{ .csrrci = .{ .rd = rd, .uimm = rs1, .csr = csr_id } },
            else => .{ .unknown = orig_code },
        },
        encoding.OPC_MISC_MEM => switch (funct3) {
            0x0 => if (code == encoding.INSN_PAUSE) .pause else .fence,
            0x1 => .fence_i,
            else => .{ .unknown = orig_code },
        },
        encoding.OPC_OP_V => switch (funct3) {
            0x7 => .{ .vsetvli = .{ .rd = rd, .rs1 = rs1, .vtype = csr_id } },
            else => .{ .vector_op = .{ .rd = rd, .rs1 = rs1, .rs2 = rs2 } },
        },
        encoding.OPC_AMO => {
            if (funct3 != encoding.FUNCT3_AMO_W) {
                return .{ .insn = .{ .unknown = orig_code }, .len = len };
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
                AmoFunct5.SWAP => .{ .amoswap_w = amo },
                AmoFunct5.ADD => .{ .amoadd_w = amo },
                AmoFunct5.LR => if (rs2 == 0)
                    .{ .lr_w = lr }
                else
                    .{ .unknown = orig_code },
                AmoFunct5.SC => .{ .sc_w = amo },
                AmoFunct5.XOR => .{ .amoxor_w = amo },
                AmoFunct5.AND => .{ .amoand_w = amo },
                AmoFunct5.OR => .{ .amoor_w = amo },
                AmoFunct5.MIN => .{ .amomin_w = amo },
                AmoFunct5.MAX => .{ .amomax_w = amo },
                AmoFunct5.MINU => .{ .amominu_w = amo },
                AmoFunct5.MAXU => .{ .amomaxu_w = amo },
                else => .{ .unknown = orig_code },
            };
            return .{ .insn = amo_insn, .len = len };
        },
        else => .{ .unknown = orig_code },
    };

    return .{ .insn = parsed, .len = len };
}

test "RV32I Base Integer Instructions Decoding" {
    std.testing.refAllDecls(@This());
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
    std.testing.refAllDecls(@This());
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
    std.testing.refAllDecls(@This());
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
    _ = rv32c;
    _ = encoding;
    // fence (0x0ff0000f).
    const fence_dec = decode(0x0ff0000f);
    try std.testing.expect(fence_dec.insn == .fence);

    // fence.i (0x0000100f).
    const fence_i_dec = decode(0x0000100f);
    try std.testing.expect(fence_i_dec.insn == .fence_i);

    // csrrs a0, time, x0 (0xc0102573: rd=10, rs1=0, csr=0xc01).
    const csr_dec = decode(0xc0102573);
    try std.testing.expectEqual(@as(u5, 10), csr_dec.insn.csrrs.rd);
    try std.testing.expectEqual(@as(u5, 0), csr_dec.insn.csrrs.rs1);
    try std.testing.expectEqual(@as(u12, 0xc01), csr_dec.insn.csrrs.csr);
    std.testing.refAllDecls(@This());
}
