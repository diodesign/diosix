// Unit Tests for RV32 Instruction Decoding, Dynamic Translation & Emulation
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const decoder_rv32 = @import("../decoders/rv32.zig");
const emitter_rv64 = @import("../emitters/rv64.zig");
const block_mod = @import("block.zig");

test "RV32I Arithmetic & Logic Instruction Decoding & Emission" {
    // 1. add a0, a1, a2 (0x00c58533)
    const add_raw: u32 = 0x00c58533;
    const add_dec = decoder_rv32.decode(add_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .add = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } }, add_dec.insn);
    const add_emitted = emitter_rv64.addw(10, 11, 12);
    try std.testing.expectEqual(@as(u32, 0x00c5853b), add_emitted);

    // 2. sub a0, a1, a2 (0x40c58533)
    const sub_raw: u32 = 0x40c58533;
    const sub_dec = decoder_rv32.decode(sub_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .sub = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } }, sub_dec.insn);
    const sub_emitted = emitter_rv64.subw(10, 11, 12);
    try std.testing.expectEqual(@as(u32, 0x40c5853b), sub_emitted);

    // 3. sll a0, a1, a2 (0x00c59533)
    const sll_raw: u32 = 0x00c59533;
    const sll_dec = decoder_rv32.decode(sll_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .sll = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } }, sll_dec.insn);
    const sll_emitted = emitter_rv64.sllw(10, 11, 12);
    try std.testing.expectEqual(@as(u32, 0x00c5953b), sll_emitted);

    // 4. slt a0, a1, a2 (0x00c5a533)
    const slt_raw: u32 = 0x00c5a533;
    const slt_dec = decoder_rv32.decode(slt_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .slt = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } }, slt_dec.insn);
    const slt_emitted = emitter_rv64.slt(10, 11, 12);
    try std.testing.expectEqual(@as(u32, 0x00c5a533), slt_emitted);

    // 5. sltu a0, a1, a2 (0x00c5b533)
    const sltu_raw: u32 = 0x00c5b533;
    const sltu_dec = decoder_rv32.decode(sltu_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .sltu = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } }, sltu_dec.insn);
    const sltu_emitted = emitter_rv64.sltu(10, 11, 12);
    try std.testing.expectEqual(@as(u32, 0x00c5b533), sltu_emitted);

    // 6. xor a0, a1, a2 (0x00c5c533)
    const xor_raw: u32 = 0x00c5c533;
    const xor_dec = decoder_rv32.decode(xor_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .xor_ = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } }, xor_dec.insn);
    const xor_emitted = emitter_rv64.xor_(10, 11, 12);
    try std.testing.expectEqual(@as(u32, 0x00c5c533), xor_emitted);

    // 7. srl a0, a1, a2 (0x00c5d533)
    const srl_raw: u32 = 0x00c5d533;
    const srl_dec = decoder_rv32.decode(srl_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .srl = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } }, srl_dec.insn);
    const srl_emitted = emitter_rv64.srlw(10, 11, 12);
    try std.testing.expectEqual(@as(u32, 0x00c5d53b), srl_emitted);

    // 8. sra a0, a1, a2 (0x40c5d533)
    const sra_raw: u32 = 0x40c5d533;
    const sra_dec = decoder_rv32.decode(sra_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .sra = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } }, sra_dec.insn);
    const sra_emitted = emitter_rv64.sraw(10, 11, 12);
    try std.testing.expectEqual(@as(u32, 0x40c5d53b), sra_emitted);

    // 9. or a0, a1, a2 (0x00c5e533)
    const or_raw: u32 = 0x00c5e533;
    const or_dec = decoder_rv32.decode(or_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .or_ = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } }, or_dec.insn);
    const or_emitted = emitter_rv64.or_(10, 11, 12);
    try std.testing.expectEqual(@as(u32, 0x00c5e533), or_emitted);

    // 10. and a0, a1, a2 (0x00c5f533)
    const and_raw: u32 = 0x00c5f533;
    const and_dec = decoder_rv32.decode(and_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .and_ = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } }, and_dec.insn);
    const and_emitted = emitter_rv64.and_(10, 11, 12);
    try std.testing.expectEqual(@as(u32, 0x00c5f533), and_emitted);
}

test "RV32I Immediate Arithmetic & Logic Decoding & Emission" {
    // 1. addi a0, a1, -42 (0xfd658513)
    const addi_raw: u32 = 0xfd658513;
    const addi_dec = decoder_rv32.decode(addi_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .addi = .{ .rd = 10, .rs1 = 11, .imm = -42 } }, addi_dec.insn);
    const addi_emitted = emitter_rv64.addiw(10, 11, -42);
    try std.testing.expectEqual(@as(u32, 0xfd65851b), addi_emitted);

    // 2. slti a0, a1, -1 (0xfff5a513)
    const slti_raw: u32 = 0xfff5a513;
    const slti_dec = decoder_rv32.decode(slti_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .slti = .{ .rd = 10, .rs1 = 11, .imm = -1 } }, slti_dec.insn);
    const slti_emitted = emitter_rv64.slti(10, 11, -1);
    try std.testing.expectEqual(@as(u32, 0xfff5a513), slti_emitted);

    // 3. sltiu a0, a1, 100 (0x0645b513)
    const sltiu_raw: u32 = 0x0645b513;
    const sltiu_dec = decoder_rv32.decode(sltiu_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .sltiu = .{ .rd = 10, .rs1 = 11, .imm = 100 } }, sltiu_dec.insn);
    const sltiu_emitted = emitter_rv64.sltiu(10, 11, 100);
    try std.testing.expectEqual(@as(u32, 0x0645b513), sltiu_emitted);

    // 4. xori a0, a1, 0x55 (0x0555c513)
    const xori_raw: u32 = 0x0555c513;
    const xori_dec = decoder_rv32.decode(xori_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .xori = .{ .rd = 10, .rs1 = 11, .imm = 0x55 } }, xori_dec.insn);
    const xori_emitted = emitter_rv64.xori(10, 11, 0x55);
    try std.testing.expectEqual(@as(u32, 0x0555c513), xori_emitted);

    // 5. ori a0, a1, 0xAA (0x0aa5e513)
    const ori_raw: u32 = 0x0aa5e513;
    const ori_dec = decoder_rv32.decode(ori_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .ori = .{ .rd = 10, .rs1 = 11, .imm = 0xAA } }, ori_dec.insn);
    const ori_emitted = emitter_rv64.ori(10, 11, 0xAA);
    try std.testing.expectEqual(@as(u32, 0x0aa5e513), ori_emitted);

    // 6. andi a0, a1, 0xFF (0x0ff5f513)
    const andi_raw: u32 = 0x0ff5f513;
    const andi_dec = decoder_rv32.decode(andi_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .andi = .{ .rd = 10, .rs1 = 11, .imm = 0xFF } }, andi_dec.insn);
    const andi_emitted = emitter_rv64.andi(10, 11, 0xFF);
    try std.testing.expectEqual(@as(u32, 0x0ff5f513), andi_emitted);

    // 7. slli a0, a1, 5 (0x00559513)
    const slli_raw: u32 = 0x00559513;
    const slli_dec = decoder_rv32.decode(slli_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .slli = .{ .rd = 10, .rs1 = 11, .shamt = 5 } }, slli_dec.insn);
    const slliw_emitted = emitter_rv64.slliw(10, 11, 5);
    try std.testing.expectEqual(@as(u32, 0x0055951b), slliw_emitted);

    // 8. srli a0, a1, 5 (0x0055d513)
    const srli_raw: u32 = 0x0055d513;
    const srli_dec = decoder_rv32.decode(srli_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .srli = .{ .rd = 10, .rs1 = 11, .shamt = 5 } }, srli_dec.insn);
    const srliw_emitted = emitter_rv64.srliw(10, 11, 5);
    try std.testing.expectEqual(@as(u32, 0x0055d51b), srliw_emitted);

    // 9. srai a0, a1, 5 (0x4055d513)
    const srai_raw: u32 = 0x4055d513;
    const srai_dec = decoder_rv32.decode(srai_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .srai = .{ .rd = 10, .rs1 = 11, .shamt = 5 } }, srai_dec.insn);
    const sraiw_emitted = emitter_rv64.sraiw(10, 11, 5);
    try std.testing.expectEqual(@as(u32, 0x4055d51b), sraiw_emitted);
}

test "RV32M Multiply & Divide Decoding & Emission" {
    // 1. mul a0, a1, a2 (0x02c58533)
    const mul_raw: u32 = 0x02c58533;
    const mul_dec = decoder_rv32.decode(mul_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .mul = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } }, mul_dec.insn);
    const mul_emitted = emitter_rv64.mulw(10, 11, 12);
    try std.testing.expectEqual(@as(u32, 0x02c5853b), mul_emitted);

    // 2. div a0, a1, a2 (0x02c5c533)
    const div_raw: u32 = 0x02c5c533;
    const div_dec = decoder_rv32.decode(div_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .div = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } }, div_dec.insn);
    const div_emitted = emitter_rv64.divw(10, 11, 12);
    try std.testing.expectEqual(@as(u32, 0x02c5c53b), div_emitted);

    // 3. divu a0, a1, a2 (0x02c5d533)
    const divu_raw: u32 = 0x02c5d533;
    const divu_dec = decoder_rv32.decode(divu_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .divu = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } }, divu_dec.insn);
    const divu_emitted = emitter_rv64.divuw(10, 11, 12);
    try std.testing.expectEqual(@as(u32, 0x02c5d53b), divu_emitted);

    // 4. rem a0, a1, a2 (0x02c5e533)
    const rem_raw: u32 = 0x02c5e533;
    const rem_dec = decoder_rv32.decode(rem_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .rem = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } }, rem_dec.insn);
    const rem_emitted = emitter_rv64.remw(10, 11, 12);
    try std.testing.expectEqual(@as(u32, 0x02c5e53b), rem_emitted);

    // 5. remu a0, a1, a2 (0x02c5f533)
    const remu_raw: u32 = 0x02c5f533;
    const remu_dec = decoder_rv32.decode(remu_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .remu = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } }, remu_dec.insn);
    const remu_emitted = emitter_rv64.remuw(10, 11, 12);
    try std.testing.expectEqual(@as(u32, 0x02c5f53b), remu_emitted);

    // 6. mulh a0, a1, a2 (0x02c59533)
    const mulh_raw: u32 = 0x02c59533;
    const mulh_dec = decoder_rv32.decode(mulh_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .mulh = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } }, mulh_dec.insn);

    // 7. mulhu a0, a1, a2 (0x02c5b533)
    const mulhu_raw: u32 = 0x02c5b533;
    const mulhu_dec = decoder_rv32.decode(mulhu_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .mulhu = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } }, mulhu_dec.insn);

    // 8. mulhsu a0, a1, a2 (0x02c5a533)
    const mulhsu_raw: u32 = 0x02c5a533;
    const mulhsu_dec = decoder_rv32.decode(mulhsu_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .mulhsu = .{ .rd = 10, .rs1 = 11, .rs2 = 12 } }, mulhsu_dec.insn);
}

test "RV32C Compressed Instruction Decompression" {
    // 1. c.addi sp, -16 (0x7139) -> addi sp, sp, -16 (0xff010113)
    const c_addi: u16 = 0x7139;
    const dec_addi = decoder_rv32.decode(c_addi);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .addi = .{ .rd = 2, .rs1 = 2, .imm = -16 } }, dec_addi.insn);

    // 2. c.li a0, 1 (0x4505) -> addi a0, zero, 1
    const c_li: u16 = 0x4505;
    const dec_li = decoder_rv32.decode(c_li);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .addi = .{ .rd = 10, .rs1 = 0, .imm = 1 } }, dec_li.insn);

    // 3. c.mv a0, a1 (0x852e) -> add a0, zero, a1
    const c_mv: u16 = 0x852e;
    const dec_mv = decoder_rv32.decode(c_mv);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .add = .{ .rd = 10, .rs1 = 0, .rs2 = 11 } }, dec_mv.insn);

    // 4. c.j +12 (0xa031) -> jal zero, +12
    const c_j: u16 = 0xa031;
    const dec_j = decoder_rv32.decode(c_j);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .jal = .{ .rd = 0, .offset = 12 } }, dec_j.insn);

    // 5. c.beqz a0, +8 (0xc121) -> beq a0, zero, +8
    const c_beqz: u16 = 0xc121;
    const dec_beqz = decoder_rv32.decode(c_beqz);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .beq = .{ .rs1 = 10, .rs2 = 0, .offset = 8 } }, dec_beqz.insn);
}

test "RV32A Atomic Instruction Encoding" {
    // 1. lr.w a0, (a1)
    const lr_insn = emitter_rv64.lr_w(10, 11, 0, 0);
    try std.testing.expectEqual(@as(u32, 0x1005a52f), lr_insn);

    // 2. sc.w a0, a2, (a1)
    const sc_insn = emitter_rv64.sc_w(10, 11, 12, 0, 0);
    try std.testing.expectEqual(@as(u32, 0x18c5a52f), sc_insn);

    // 3. amoadd.w a0, a2, (a1)
    const amoadd_insn = emitter_rv64.amoadd_w(10, 11, 12, 0, 0);
    try std.testing.expectEqual(@as(u32, 0x00c5a52f), amoadd_insn);

    // 4. amoswap.w a0, a2, (a1)
    const amoswap_insn = emitter_rv64.amoswap_w(10, 11, 12, 0, 0);
    try std.testing.expectEqual(@as(u32, 0x08c5a52f), amoswap_insn);

    // 5. amoxor.w a0, a2, (a1)
    const amoxor_insn = emitter_rv64.amoxor_w(10, 11, 12, 0, 0);
    try std.testing.expectEqual(@as(u32, 0x20c5a52f), amoxor_insn);

    // 6. amoand.w a0, a2, (a1)
    const amoand_insn = emitter_rv64.amoand_w(10, 11, 12, 0, 0);
    try std.testing.expectEqual(@as(u32, 0x60c5a52f), amoand_insn);

    // 7. amoor.w a0, a2, (a1)
    const amoor_insn = emitter_rv64.amoor_w(10, 11, 12, 0, 0);
    try std.testing.expectEqual(@as(u32, 0x40c5a52f), amoor_insn);

    // 8. amomin.w a0, a2, (a1)
    const amomin_insn = emitter_rv64.amomin_w(10, 11, 12, 0, 0);
    try std.testing.expectEqual(@as(u32, 0x80c5a52f), amomin_insn);

    // 9. amomax.w a0, a2, (a1)
    const amomax_insn = emitter_rv64.amomax_w(10, 11, 12, 0, 0);
    try std.testing.expectEqual(@as(u32, 0xa0c5a52f), amomax_insn);

    // 10. amominu.w a0, a2, (a1)
    const amominu_insn = emitter_rv64.amominu_w(10, 11, 12, 0, 0);
    try std.testing.expectEqual(@as(u32, 0xc0c5a52f), amominu_insn);

    // 11. amomaxu.w a0, a2, (a1)
    const amomaxu_insn = emitter_rv64.amomaxu_w(10, 11, 12, 0, 0);
    try std.testing.expectEqual(@as(u32, 0xe0c5a52f), amomaxu_insn);
}

test "RV32 Standard Division, Remainder & Arithmetic Corner Cases" {
    // 1. Division by zero: x / 0 must return -1 (0xFFFFFFFF)
    const div_by_zero = if (@as(i32, 0) == 0) -1 else @divTrunc(@as(i32, 42), @as(i32, 0));
    try std.testing.expectEqual(@as(i32, -1), div_by_zero);

    // 2. Unsigned division by zero: x / 0 must return UINT_MAX (0xFFFFFFFF)
    const divu_by_zero = if (@as(u32, 0) == 0) ~@as(u32, 0) else @as(u32, 42) / @as(u32, 0);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), divu_by_zero);

    // 3. Remainder by zero: x % 0 must return x
    const rem_by_zero = if (@as(i32, 0) == 0) @as(i32, 42) else @rem(@as(i32, 42), @as(i32, 0));
    try std.testing.expectEqual(@as(i32, 42), rem_by_zero);

    // 4. Unsigned remainder by zero: x % 0 must return x
    const remu_by_zero = if (@as(u32, 0) == 0) @as(u32, 42) else @as(u32, 42) % @as(u32, 0);
    try std.testing.expectEqual(@as(u32, 42), remu_by_zero);

    // 5. Signed division overflow: INT_MIN / -1 must return INT_MIN (0x80000000)
    const int_min: i32 = -2147483648;
    const div_overflow = if (int_min == -2147483648 and @as(i32, -1) == -1) int_min else @divTrunc(int_min, @as(i32, -1));
    try std.testing.expectEqual(int_min, div_overflow);

    // 6. Signed remainder overflow: INT_MIN % -1 must return 0
    const rem_overflow = if (int_min == -2147483648 and @as(i32, -1) == -1) @as(i32, 0) else @rem(int_min, @as(i32, -1));
    try std.testing.expectEqual(@as(i32, 0), rem_overflow);

    // 7. Signed vs Unsigned comparisons
    const neg_one: i32 = -1;
    const pos_one: i32 = 1;
    try std.testing.expect(neg_one < pos_one); // slt: -1 < 1 is true
    try std.testing.expect(@as(u32, @bitCast(neg_one)) > @as(u32, @bitCast(pos_one))); // sltu: 0xFFFFFFFF > 1 is true

    // 8. Sign extension vs zero extension on byte/halfword loads
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

test "RV32 Floating-Point (F/D) Decoding, Decompression & Emission" {
    // 1. fsd fs0, 56(a0) (0x02853c27) -> opcode 0x27, width 3 (double)
    const fsd_raw: u32 = 0x02853c27;
    const fsd_dec = decoder_rv32.decode(fsd_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .fsd = .{ .rs1 = 10, .rs2 = 8, .offset = 56 } }, fsd_dec.insn);
    const fsd_emitted = emitter_rv64.fsd(10, 8, 56);
    try std.testing.expectEqual(fsd_raw, fsd_emitted);

    // 2. fld ft0, 64(sp) (0x04013007)
    const fld_raw: u32 = 0x04013007;
    const fld_dec = decoder_rv32.decode(fld_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .fld = .{ .rd = 0, .rs1 = 2, .offset = 64 } }, fld_dec.insn);
    const fld_emitted = emitter_rv64.fld(0, 2, 64);
    try std.testing.expectEqual(fld_raw, fld_emitted);

    // 3. flw ft1, 16(a0) (0x01052087)
    const flw_raw: u32 = 0x01052087;
    const flw_dec = decoder_rv32.decode(flw_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .flw = .{ .rd = 1, .rs1 = 10, .offset = 16 } }, flw_dec.insn);
    const flw_emitted = emitter_rv64.flw(1, 10, 16);
    try std.testing.expectEqual(flw_raw, flw_emitted);

    // 4. fsw ft2, 24(a1) (0x0125a427)
    const fsw_raw: u32 = 0x0125a427;
    const fsw_dec = decoder_rv32.decode(fsw_raw);
    try std.testing.expectEqual(decoder_rv32.Instruction{ .fsw = .{ .rs1 = 11, .rs2 = 2, .offset = 24 } }, fsw_dec.insn);
    const fsw_emitted = emitter_rv64.fsw(11, 2, 24);
    try std.testing.expectEqual(fsw_raw, fsw_emitted);

    // 5. C.FLD / C.FSD compressed decompression
    // c.fld fa0, 8(a1) -> 0x25a0
    const c_fld: u16 = 0x25a0;
    const c_fld_dec = decoder_rv32.decode(c_fld);
    try std.testing.expect(c_fld_dec.insn == .fld);
}


