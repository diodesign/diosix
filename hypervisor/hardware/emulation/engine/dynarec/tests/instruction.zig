// Unit Tests for RV32 Instruction Decoding, Encoding & Arithmetic Semantics.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const decoder_rv32 = @import("../../decoders/rv32.zig");
const emitter_rv64 = @import("../../emitters/rv64.zig");
const cache_mod = @import("../cache.zig");
const interpreter = @import("../interpreter.zig");
const softtlb_mod = @import("../../../softtlb.zig");
const vcpu_mod = @import("../../../vcpu.zig");
const bus_mod = @import("../../../devices/bus.zig");
const vuart_mod = @import("../../../devices/vuart.zig");
const vtimer_mod = @import("../../../devices/vtimer.zig");
const vpic_mod = @import("../../../devices/vpic.zig");
const engine_mod = @import("../engine.zig");

test "RV32I arithmetic and logic instruction decoding and emission" {
    std.testing.refAllDecls(@This());
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
    std.testing.refAllDecls(@This());
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
    std.testing.refAllDecls(@This());
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
    std.testing.refAllDecls(@This());
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
    std.testing.refAllDecls(@This());
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
    var vcpu = vcpu_mod.VCpu{ .id = 0, .pc = 0x8000_0000 };
    var tlb: softtlb_mod.SoftTlb = undefined;
    tlb.initOnPtr(0x8000_0000, 0x8000_0000, 16 * 1024 * 1024);
    var uart = vuart_mod.VirtualUart{};
    var timer = vtimer_mod.VirtualTimer{};
    var pic = vpic_mod.VirtualPlic{};
    var bus = bus_mod.Bus{ .uart = &uart, .timer = &timer, .pic = &pic };
    const eng = try std.testing.allocator.create(engine_mod.Engine);
    defer std.testing.allocator.destroy(eng);
    var jit_buffer: [4096]u8 align(4096) = undefined;
    eng.initOnPtr(&jit_buffer, &vcpu, &tlb, &bus);

    const Helper = struct {
        engine: *engine_mod.Engine,
        pub fn exec(self: *@This(), raw: u32, rs1: u32, rs2: u32) !u32 {
            self.engine.vcpu.setGpr(11, rs1);
            self.engine.vcpu.setGpr(12, rs2);
            const dec = decoder_rv32.decode(raw);
            try std.testing.expect(
                self.engine.executeDecoded(dec, raw, 0x8000_0000),
            );
            return @truncate(self.engine.vcpu.getGpr(10));
        }
    };
    var env = Helper{ .engine = eng };

    // Encodings for rd=10 (a0), rs1=11 (a1), rs2=12 (a2).
    const div_raw: u32 = 0x02c5_c533;
    const divu_raw: u32 = 0x02c5_d533;
    const rem_raw: u32 = 0x02c5_e533;
    const remu_raw: u32 = 0x02c5_f533;

    // 1. Division and remainder by zero.
    try std.testing.expectEqual(
        @as(u32, 0xffff_ffff),
        try env.exec(div_raw, 42, 0),
    );
    try std.testing.expectEqual(
        @as(u32, 0xffff_ffff),
        try env.exec(divu_raw, 42, 0),
    );
    try std.testing.expectEqual(@as(u32, 42), try env.exec(rem_raw, 42, 0));
    try std.testing.expectEqual(@as(u32, 42), try env.exec(remu_raw, 42, 0));

    // 2. Signed overflow: -2^31 / -1 = -2^31, -2^31 % -1 = 0.
    try std.testing.expectEqual(
        @as(u32, 0x8000_0000),
        try env.exec(div_raw, 0x8000_0000, 0xffff_ffff),
    );
    try std.testing.expectEqual(
        @as(u32, 0),
        try env.exec(rem_raw, 0x8000_0000, 0xffff_ffff),
    );

    // 3. Normal signed and unsigned division/remainder.
    const neg20: u32 = @bitCast(@as(i32, -20));
    try std.testing.expectEqual(
        @as(i32, -6),
        @as(i32, @bitCast(try env.exec(div_raw, neg20, 3))),
    );
    try std.testing.expectEqual(
        @as(i32, -2),
        @as(i32, @bitCast(try env.exec(rem_raw, neg20, 3))),
    );
    try std.testing.expectEqual(@as(u32, 6), try env.exec(divu_raw, 20, 3));
    try std.testing.expectEqual(@as(u32, 2), try env.exec(remu_raw, 20, 3));
    std.testing.refAllDecls(@This());
}
