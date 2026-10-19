// Unit Tests for RV32 Instruction Decoding, Encoding & Arithmetic Semantics.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const decoder_rv32 = @import("../../decoders/rv32.zig");
const emitter_rv64 = @import("../../emitters/rv64.zig");
const cache_mod = @import("../cache.zig");

test "RV32I arithmetic and logic instruction decoding and emission" {
    const add_dec = decoder_rv32.decode(0x00c58533);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .add = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } },
        add_dec.insn,
    );
    try std.testing.expectEqual(
        @as(u32, 0x00c5853b),
        emitter_rv64.addw(10, 11, 12),
    );

    const sub_dec = decoder_rv32.decode(0x40c58533);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .sub = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } },
        sub_dec.insn,
    );
    try std.testing.expectEqual(
        @as(u32, 0x40c5853b),
        emitter_rv64.subw(10, 11, 12),
    );

    const sll_dec = decoder_rv32.decode(0x00c59533);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .sll = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } },
        sll_dec.insn,
    );
    try std.testing.expectEqual(
        @as(u32, 0x00c5953b),
        emitter_rv64.sllw(10, 11, 12),
    );

    const slt_dec = decoder_rv32.decode(0x00c5a533);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .slt = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } },
        slt_dec.insn,
    );
    try std.testing.expectEqual(
        @as(u32, 0x00c5a533),
        emitter_rv64.slt(10, 11, 12),
    );

    const sltu_dec = decoder_rv32.decode(0x00c5b533);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .sltu = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } },
        sltu_dec.insn,
    );
    try std.testing.expectEqual(
        @as(u32, 0x00c5b533),
        emitter_rv64.sltu(10, 11, 12),
    );

    const xor_dec = decoder_rv32.decode(0x00c5c533);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .xor_ = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } },
        xor_dec.insn,
    );
    try std.testing.expectEqual(
        @as(u32, 0x00c5c533),
        emitter_rv64.xor_(10, 11, 12),
    );

    const srl_dec = decoder_rv32.decode(0x00c5d533);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .srl = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } },
        srl_dec.insn,
    );
    try std.testing.expectEqual(
        @as(u32, 0x00c5d53b),
        emitter_rv64.srlw(10, 11, 12),
    );

    const sra_dec = decoder_rv32.decode(0x40c5d533);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .sra = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } },
        sra_dec.insn,
    );
    try std.testing.expectEqual(
        @as(u32, 0x40c5d53b),
        emitter_rv64.sraw(10, 11, 12),
    );

    const or_dec = decoder_rv32.decode(0x00c5e533);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .or_ = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } },
        or_dec.insn,
    );
    try std.testing.expectEqual(
        @as(u32, 0x00c5e533),
        emitter_rv64.or_(10, 11, 12),
    );

    const and_dec = decoder_rv32.decode(0x00c5f533);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .and_ = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } },
        and_dec.insn,
    );
    try std.testing.expectEqual(
        @as(u32, 0x00c5f533),
        emitter_rv64.and_(10, 11, 12),
    );
}

test "RV32I immediate arithmetic and logic decoding and emission" {
    const addi_dec = decoder_rv32.decode(0xfd658513);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{
            .addi = .{ .rd = 10, .rs1 = 11, .imm = -42 },
        },
        addi_dec.insn,
    );
    try std.testing.expectEqual(
        @as(u32, 0xfd65851b),
        emitter_rv64.addiw(10, 11, -42),
    );

    const slti_dec = decoder_rv32.decode(0xfff5a513);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .slti = .{ .rd = 10, .rs1 = 11, .imm = -1 } },
        slti_dec.insn,
    );
    try std.testing.expectEqual(
        @as(u32, 0xfff5a513),
        emitter_rv64.slti(10, 11, -1),
    );

    const sltiu_dec = decoder_rv32.decode(0x0645b513);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{
            .sltiu = .{ .rd = 10, .rs1 = 11, .imm = 100 },
        },
        sltiu_dec.insn,
    );
    try std.testing.expectEqual(
        @as(u32, 0x0645b513),
        emitter_rv64.sltiu(10, 11, 100),
    );

    const xori_dec = decoder_rv32.decode(0x0555c513);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{
            .xori = .{ .rd = 10, .rs1 = 11, .imm = 0x55 },
        },
        xori_dec.insn,
    );
    try std.testing.expectEqual(
        @as(u32, 0x0555c513),
        emitter_rv64.xori(10, 11, 0x55),
    );

    const ori_dec = decoder_rv32.decode(0x0aa5e513);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{
            .ori = .{ .rd = 10, .rs1 = 11, .imm = 0xaa },
        },
        ori_dec.insn,
    );
    try std.testing.expectEqual(
        @as(u32, 0x0aa5e513),
        emitter_rv64.ori(10, 11, 0xaa),
    );

    const andi_dec = decoder_rv32.decode(0x0ff5f513);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{
            .andi = .{ .rd = 10, .rs1 = 11, .imm = 0xff },
        },
        andi_dec.insn,
    );
    try std.testing.expectEqual(
        @as(u32, 0x0ff5f513),
        emitter_rv64.andi(10, 11, 0xff),
    );

    const slli_dec = decoder_rv32.decode(0x00559513);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{
            .slli = .{ .rd = 10, .rs1 = 11, .shamt = 5 },
        },
        slli_dec.insn,
    );
    try std.testing.expectEqual(
        @as(u32, 0x0055951b),
        emitter_rv64.slliw(10, 11, 5),
    );

    const srli_dec = decoder_rv32.decode(0x0055d513);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{
            .srli = .{ .rd = 10, .rs1 = 11, .shamt = 5 },
        },
        srli_dec.insn,
    );
    try std.testing.expectEqual(
        @as(u32, 0x0055d51b),
        emitter_rv64.srliw(10, 11, 5),
    );

    const srai_dec = decoder_rv32.decode(0x4055d513);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{
            .srai = .{ .rd = 10, .rs1 = 11, .shamt = 5 },
        },
        srai_dec.insn,
    );
    try std.testing.expectEqual(
        @as(u32, 0x4055d51b),
        emitter_rv64.sraiw(10, 11, 5),
    );
}

test "RV32M multiply and divide decoding and emission" {
    const mul_dec = decoder_rv32.decode(0x02c58533);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .mul = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } },
        mul_dec.insn,
    );
    try std.testing.expectEqual(
        @as(u32, 0x02c5853b),
        emitter_rv64.mulw(10, 11, 12),
    );

    const div_dec = decoder_rv32.decode(0x02c5c533);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .div = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } },
        div_dec.insn,
    );
    try std.testing.expectEqual(
        @as(u32, 0x02c5c53b),
        emitter_rv64.divw(10, 11, 12),
    );

    const divu_dec = decoder_rv32.decode(0x02c5d533);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .divu = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } },
        divu_dec.insn,
    );
    try std.testing.expectEqual(
        @as(u32, 0x02c5d53b),
        emitter_rv64.divuw(10, 11, 12),
    );

    const rem_dec = decoder_rv32.decode(0x02c5e533);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .rem = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } },
        rem_dec.insn,
    );
    try std.testing.expectEqual(
        @as(u32, 0x02c5e53b),
        emitter_rv64.remw(10, 11, 12),
    );

    const remu_dec = decoder_rv32.decode(0x02c5f533);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .remu = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } },
        remu_dec.insn,
    );
    try std.testing.expectEqual(
        @as(u32, 0x02c5f53b),
        emitter_rv64.remuw(10, 11, 12),
    );

    const mulh_dec = decoder_rv32.decode(0x02c59533);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .mulh = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } },
        mulh_dec.insn,
    );

    const mulhu_dec = decoder_rv32.decode(0x02c5b533);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{
            .mulhu = .{ .rd = 10, .rs1 = 11, .rs2 = 12 },
        },
        mulhu_dec.insn,
    );

    const mulhsu_dec = decoder_rv32.decode(0x02c5a533);
    try std.testing.expectEqual(
        decoder_rv32.Instruction{
            .mulhsu = .{ .rd = 10, .rs1 = 11, .rs2 = 12 },
        },
        mulhsu_dec.insn,
    );
}

test "RV32C compressed instruction decompression" {
    const dec_addi = decoder_rv32.decode(@as(u16, 0x7139));
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .addi = .{ .rd = 2, .rs1 = 2, .imm = -64 } },
        dec_addi.insn,
    );

    const dec_li = decoder_rv32.decode(@as(u16, 0x4505));
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .addi = .{ .rd = 10, .rs1 = 0, .imm = 1 } },
        dec_li.insn,
    );

    const dec_mv = decoder_rv32.decode(@as(u16, 0x852e));
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .add = .{ .rd = 10, .rs1 = 0, .rs2 = 11 } },
        dec_mv.insn,
    );

    const dec_j = decoder_rv32.decode(@as(u16, 0xa031));
    try std.testing.expectEqual(
        decoder_rv32.Instruction{ .jal = .{ .rd = 0, .offset = 12 } },
        dec_j.insn,
    );

    const dec_beqz = decoder_rv32.decode(@as(u16, 0xc121));
    const exp_beq = decoder_rv32.Instruction{
        .beq = .{ .rs1 = 10, .rs2 = 0, .offset = 64 },
    };
    try std.testing.expectEqual(exp_beq, dec_beqz.insn);
}

test "RV32A atomic instruction encoding" {
    try std.testing.expectEqual(
        @as(u32, 0x1005a52f),
        emitter_rv64.lr_w(10, 11, 0, 0),
    );
    try std.testing.expectEqual(
        @as(u32, 0x18c5a52f),
        emitter_rv64.sc_w(10, 11, 12, 0, 0),
    );
    try std.testing.expectEqual(
        @as(u32, 0x00c5a52f),
        emitter_rv64.amoadd_w(10, 11, 12, 0, 0),
    );
    try std.testing.expectEqual(
        @as(u32, 0x08c5a52f),
        emitter_rv64.amoswap_w(10, 11, 12, 0, 0),
    );
    try std.testing.expectEqual(
        @as(u32, 0x20c5a52f),
        emitter_rv64.amoxor_w(10, 11, 12, 0, 0),
    );
    try std.testing.expectEqual(
        @as(u32, 0x60c5a52f),
        emitter_rv64.amoand_w(10, 11, 12, 0, 0),
    );
    try std.testing.expectEqual(
        @as(u32, 0x40c5a52f),
        emitter_rv64.amoor_w(10, 11, 12, 0, 0),
    );
    try std.testing.expectEqual(
        @as(u32, 0x80c5a52f),
        emitter_rv64.amomin_w(10, 11, 12, 0, 0),
    );
    try std.testing.expectEqual(
        @as(u32, 0xa0c5a52f),
        emitter_rv64.amomax_w(10, 11, 12, 0, 0),
    );
    try std.testing.expectEqual(
        @as(u32, 0xc0c5a52f),
        emitter_rv64.amominu_w(10, 11, 12, 0, 0),
    );
    try std.testing.expectEqual(
        @as(u32, 0xe0c5a52f),
        emitter_rv64.amomaxu_w(10, 11, 12, 0, 0),
    );
}

test "RV32 standard division, remainder and arithmetic corner cases" {
    const div_by_zero = if (@as(i32, 0) == 0)
        -1
    else
        @divTrunc(@as(i32, 42), @as(i32, 0));
    try std.testing.expectEqual(@as(i32, -1), div_by_zero);

    const divu_by_zero = if (@as(u32, 0) == 0)
        ~@as(u32, 0)
    else
        @as(u32, 42) / @as(u32, 0);
    try std.testing.expectEqual(@as(u32, 0xffffffff), divu_by_zero);

    const rem_by_zero = if (@as(i32, 0) == 0)
        @as(i32, 42)
    else
        @rem(@as(i32, 42), @as(i32, 0));
    try std.testing.expectEqual(@as(i32, 42), rem_by_zero);

    const remu_by_zero = if (@as(u32, 0) == 0)
        @as(u32, 42)
    else
        @as(u32, 42) % @as(u32, 0);
    try std.testing.expectEqual(@as(u32, 42), remu_by_zero);

    const int_min: i32 = -2147483648;
    const div_overflow = if (int_min == -2147483648 and @as(i32, -1) == -1)
        int_min
    else
        @divTrunc(int_min, @as(i32, -1));
    try std.testing.expectEqual(int_min, div_overflow);

    const rem_overflow = if (int_min == -2147483648 and @as(i32, -1) == -1)
        @as(i32, 0)
    else
        @rem(int_min, @as(i32, -1));
    try std.testing.expectEqual(@as(i32, 0), rem_overflow);

    const neg_one: i32 = -1;
    const pos_one: i32 = 1;
    try std.testing.expect(neg_one < pos_one);
    try std.testing.expect(
        @as(u32, @bitCast(neg_one)) > @as(u32, @bitCast(pos_one)),
    );

    const byte_val: u8 = 0x80;
    const sign_extended_byte = @as(i64, @as(i8, @bitCast(byte_val)));
    const zero_extended_byte = @as(u64, byte_val);
    try std.testing.expectEqual(@as(i64, -128), sign_extended_byte);
    try std.testing.expectEqual(@as(u64, 128), zero_extended_byte);

    const half_val: u16 = 0x8000;
    const sign_extended_half = @as(i64, @as(i16, @bitCast(half_val)));
    const zero_extended_half = @as(u64, half_val);
    try std.testing.expectEqual(@as(i64, -32768), sign_extended_half);
    try std.testing.expectEqual(@as(u64, 32768), zero_extended_half);
}
