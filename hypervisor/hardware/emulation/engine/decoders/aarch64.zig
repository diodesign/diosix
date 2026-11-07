// AArch64 (ARM64) Instruction Decoder for Diosix Hypervisor
//
// Decodes 32-bit A64 instructions into the common Diosix emulation IR
// (`encoding.DecodedInsn`) consumed by both the single-step interpreter
// and the RV64 dynamic binary translator.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const encoding = @import("rv32/encoding.zig");

pub const Instruction = encoding.Instruction;
pub const DecodedInsn = encoding.DecodedInsn;

pub const INSN_NOP: u32 = 0xd503201f;
pub const INSN_YIELD: u32 = 0xd503203f;
pub const INSN_WFE: u32 = 0xd503205f;
pub const INSN_WFI: u32 = 0xd503207f;
pub const INSN_SEV: u32 = 0xd503209f;
pub const INSN_SEVL: u32 = 0xd50320bf;
pub const INSN_ERET: u32 = 0xd69f03e0;

pub const REG_LR: u5 = 30;
pub const REG_X0_MAPPED: u5 = 31;

/// Map AArch64 register index where 31 represents XZR/WZR (zero register).
/// Maps XZR (31) -> x0 (0), X0 (0) -> x31 (31), and X1..X30 -> x1..x30.
pub inline fn mapZeroReg(r: u5) u5 {
    return switch (r) {
        0 => REG_X0_MAPPED,
        31 => 0,
        else => r,
    };
}

/// Map AArch64 register index where 31 represents SP (stack pointer).
/// Maps X0 (0) -> x31 (31), SP (31) -> x2 (2), and X1..X30 -> x1..x30.
pub inline fn mapSpReg(r: u5) u5 {
    return switch (r) {
        0 => REG_X0_MAPPED,
        31 => 2,
        else => r,
    };
}

fn decodeSystemAndBranchReg(raw_code: u32) ?Instruction {
    if (raw_code == INSN_NOP) {
        return .{ .addi = .{ .rd = 0, .rs1 = 0, .imm = 0 } };
    }
    if (raw_code == INSN_WFI or raw_code == INSN_WFE) {
        return .wfi;
    }
    if (raw_code == INSN_YIELD or
        raw_code == INSN_SEV or
        raw_code == INSN_SEVL)
    {
        return .pause;
    }
    if (raw_code == INSN_ERET) {
        return .sret;
    }
    // DSB / DMB barriers.
    if ((raw_code & 0xfffff09f) == 0xd503309f) {
        return .fence;
    }
    // ISB instruction synchronization barrier.
    if ((raw_code & 0xfffff0ff) == 0xd50330df) {
        return .fence_i;
    }
    // SVC / HVC / SMC supervisor/hypervisor/secure monitor calls.
    if ((raw_code & 0xffe0001f) == 0xd4000001 or
        (raw_code & 0xffe0001f) == 0xd4000002 or
        (raw_code & 0xffe0001f) == 0xd4000003)
    {
        return .ecall;
    }
    // BRK software breakpoint.
    if ((raw_code & 0xffe0001f) == 0xd4200000) {
        return .ebreak;
    }
    // MSR / MRS system register access.
    if ((raw_code & 0xfff00000) == 0xd5100000) {
        const rt = mapZeroReg(@truncate(raw_code & 0x1f));
        const sysreg: u12 = @truncate((raw_code >> 5) & 0xfff);
        return .{ .csrrw = .{ .rd = 0, .rs1 = rt, .csr = sysreg } };
    }
    if ((raw_code & 0xfff00000) == 0xd5300000) {
        const rt = mapZeroReg(@truncate(raw_code & 0x1f));
        const sysreg: u12 = @truncate((raw_code >> 5) & 0xfff);
        return .{ .csrrs = .{ .rd = rt, .rs1 = 0, .csr = sysreg } };
    }
    // Unconditional register branch: BR Xn, BLR Xn, RET Xn.
    const rn = mapZeroReg(@truncate((raw_code >> 5) & 0x1f));
    if ((raw_code & 0xfffffc1f) == 0xd61f0000 or
        (raw_code & 0xfffffc1f) == 0xd65f0000)
    {
        return .{ .jalr = .{ .rd = 0, .rs1 = rn, .offset = 0 } };
    }
    if ((raw_code & 0xfffffc1f) == 0xd63f0000) {
        return .{ .jalr = .{ .rd = REG_LR, .rs1 = rn, .offset = 0 } };
    }
    return null;
}

fn decodeBranches(raw_code: u32) ?Instruction {
    // Unconditional B / BL (imm26).
    const top6 = raw_code >> 26;
    if (top6 == 0b000101 or top6 == 0b100101) {
        const imm26 = raw_code & 0x03ff_ffff;
        const offset = encoding.signExtend(imm26 << 2, 28);
        const rd: u5 = if (top6 == 0b100101) REG_LR else 0;
        return .{ .jal = .{ .rd = rd, .offset = offset } };
    }
    // CBZ / CBNZ (imm19).
    if ((raw_code & 0x7e000000) == 0x34000000) {
        const rt = mapZeroReg(@truncate(raw_code & 0x1f));
        const imm19 = (raw_code >> 5) & 0x7ffff;
        const offset = encoding.signExtend(imm19 << 2, 21);
        const is_cbnz = ((raw_code >> 24) & 1) != 0;
        return if (is_cbnz)
            .{ .bne = .{ .rs1 = rt, .rs2 = 0, .offset = offset } }
        else
            .{ .beq = .{ .rs1 = rt, .rs2 = 0, .offset = offset } };
    }
    // Conditional B.cond (imm19).
    if ((raw_code & 0xff000010) == 0x54000000) {
        const cond: u4 = @truncate(raw_code & 0xf);
        const imm19 = (raw_code >> 5) & 0x7ffff;
        const offset = encoding.signExtend(imm19 << 2, 21);
        const b = encoding.BType{
            .rs1 = REG_X0_MAPPED,
            .rs2 = 0,
            .offset = offset,
        };
        return switch (cond) {
            0x0 => .{ .beq = b },
            0x1 => .{ .bne = b },
            0x2 => .{ .bgeu = b },
            0x3 => .{ .bltu = b },
            0xa => .{ .bge = b },
            0xb => .{ .blt = b },
            else => null,
        };
    }
    return null;
}

fn decodeDataProcImm(raw_code: u32) ?Instruction {
    const rd_raw: u5 = @truncate(raw_code & 0x1f);
    const rn_raw: u5 = @truncate((raw_code >> 5) & 0x1f);

    // ADR / ADRP (PC-relative address generation).
    if ((raw_code & 0x1f000000) == 0x10000000) {
        const rd = mapZeroReg(rd_raw);
        const immlo = (raw_code >> 29) & 0x3;
        const immhi = (raw_code >> 5) & 0x7ffff;
        const imm21 = encoding.signExtend((immhi << 2) | immlo, 21);
        const is_adrp = (raw_code & 0x80000000) != 0;
        if (is_adrp) {
            return .{ .auipc = .{ .rd = rd, .imm = imm21 } };
        }
        return .{ .addi = .{ .rd = rd, .rs1 = 0, .imm = imm21 } };
    }

    // ADD / SUB (immediate): bits [28:23] == 0b100010.
    if ((raw_code & 0x1f800000) == 0x11000000) {
        const is_sub = (raw_code & 0x40000000) != 0;
        const sets_flags = (raw_code & 0x20000000) != 0;
        const sh = ((raw_code >> 22) & 1) != 0;
        const imm12: i32 = @intCast((raw_code >> 10) & 0xfff);
        const imm: i32 = if (sh) imm12 << 12 else imm12;
        const rd = if (sets_flags) mapZeroReg(rd_raw) else mapSpReg(rd_raw);
        const rn = mapSpReg(rn_raw);
        return .{
            .addi = .{
                .rd = rd,
                .rs1 = rn,
                .imm = if (is_sub) -imm else imm,
            },
        };
    }

    // MOVZ / MOVN / MOVK (wide immediate): bits [28:23] == 0b100101.
    if ((raw_code & 0x1f800000) == 0x12800000) {
        const opc: u2 = @truncate((raw_code >> 29) & 0x3);
        const hw: u2 = @truncate((raw_code >> 21) & 0x3);
        const imm16: u32 = (raw_code >> 5) & 0xffff;
        const rd = mapZeroReg(rd_raw);
        if (opc == 0b10) {
            // MOVZ
            if (hw == 0) {
                return .{
                    .addi = .{ .rd = rd, .rs1 = 0, .imm = @bitCast(imm16) },
                };
            } else if (hw == 1) {
                return .{
                    .lui = .{ .rd = rd, .imm = @bitCast(imm16 << 4) },
                };
            }
        } else if (opc == 0b00 and hw == 0) {
            // MOVN
            const inv_imm: i32 = ~@as(i32, @bitCast(imm16));
            return .{
                .addi = .{ .rd = rd, .rs1 = 0, .imm = inv_imm },
            };
        }
    }

    // UBFM / SBFM (shifts: LSL, LSR, ASR): bits [28:23] == 0b100110.
    if ((raw_code & 0x1f800000) == 0x13000000) {
        const opc: u2 = @truncate((raw_code >> 29) & 0x3);
        const immr: u6 = @truncate((raw_code >> 16) & 0x3f);
        const imms: u6 = @truncate((raw_code >> 10) & 0x3f);
        const rd = mapZeroReg(rd_raw);
        const rn = mapZeroReg(rn_raw);
        const shamt: u5 = @truncate(immr);
        if (opc == 0b10) {
            if (imms == 31 or imms == 63) {
                return .{ .srli = .{ .rd = rd, .rs1 = rn, .shamt = shamt } };
            }
            const lsl_shamt: u5 = @truncate(0 -% immr);
            return .{ .slli = .{ .rd = rd, .rs1 = rn, .shamt = lsl_shamt } };
        } else if (opc == 0b00 and (imms == 31 or imms == 63)) {
            return .{ .srai = .{ .rd = rd, .rs1 = rn, .shamt = shamt } };
        }
    }

    return null;
}

fn decodeDataProcReg(raw_code: u32) ?Instruction {
    const rd = mapZeroReg(@truncate(raw_code & 0x1f));
    const rn = mapZeroReg(@truncate((raw_code >> 5) & 0x1f));
    const rm = mapZeroReg(@truncate((raw_code >> 16) & 0x1f));

    // Logical shifted register: AND, ORR, EOR, ANDS.
    if ((raw_code & 0x1f000000) == 0x0a000000) {
        const opc: u2 = @truncate((raw_code >> 29) & 0x3);
        return switch (opc) {
            0b00, 0b11 => .{ .and_ = .{ .rd = rd, .rs1 = rn, .rs2 = rm } },
            0b01 => .{ .or_ = .{ .rd = rd, .rs1 = rn, .rs2 = rm } },
            0b10 => .{ .xor_ = .{ .rd = rd, .rs1 = rn, .rs2 = rm } },
        };
    }

    // Add/subtract shifted register: ADD, ADDS, SUB, SUBS.
    if ((raw_code & 0x1f200000) == 0x0b000000) {
        const is_sub = (raw_code & 0x40000000) != 0;
        return if (is_sub)
            .{ .sub = .{ .rd = rd, .rs1 = rn, .rs2 = rm } }
        else
            .{ .add = .{ .rd = rd, .rs1 = rn, .rs2 = rm } };
    }

    // Data-processing (2 source): UDIV, SDIV, LSLV, LSRV, ASRV.
    if ((raw_code & 0x5fe00000) == 0x1ac00000) {
        const opcode2: u6 = @truncate((raw_code >> 10) & 0x3f);
        return switch (opcode2) {
            0b000010 => .{ .divu = .{ .rd = rd, .rs1 = rn, .rs2 = rm } },
            0b000011 => .{ .div = .{ .rd = rd, .rs1 = rn, .rs2 = rm } },
            0b001000 => .{ .sll = .{ .rd = rd, .rs1 = rn, .rs2 = rm } },
            0b001001 => .{ .srl = .{ .rd = rd, .rs1 = rn, .rs2 = rm } },
            0b001010 => .{ .sra = .{ .rd = rd, .rs1 = rn, .rs2 = rm } },
            else => null,
        };
    }

    // Data-processing (3 source): MADD / MUL.
    if ((raw_code & 0x5fe08000) == 0x1b000000) {
        return .{ .mul = .{ .rd = rd, .rs1 = rn, .rs2 = rm } };
    }

    return null;
}

fn decodeLoadStore(raw_code: u32) ?Instruction {
    const rt = mapZeroReg(@truncate(raw_code & 0x1f));
    const rn = mapSpReg(@truncate((raw_code >> 5) & 0x1f));

    // Exclusive load/store: LDXR / STXR (32-bit and 64-bit).
    if ((raw_code & 0xbffffc00) == 0x885f7c00) {
        return .{ .lr_w = .{ .rd = rt, .rs1 = rn, .aq = 1, .rl = 1 } };
    }
    if ((raw_code & 0xbfe0fc00) == 0x88007c00) {
        const rs = mapZeroReg(@truncate((raw_code >> 16) & 0x1f));
        return .{
            .sc_w = .{ .rd = rs, .rs1 = rn, .rs2 = rt, .aq = 1, .rl = 1 },
        };
    }

    // Unsigned immediate offset Load/Store: bits [29:24] == 0b111001.
    if ((raw_code & 0x3b000000) == 0x39000000) {
        const size: u2 = @truncate((raw_code >> 30) & 0x3);
        const opc: u2 = @truncate((raw_code >> 22) & 0x3);
        const imm12: u32 = (raw_code >> 10) & 0xfff;
        const offset: i32 = @intCast(imm12 << size);

        return switch (size) {
            0b00 => switch (opc) {
                0b00 => .{ .sb = .{ .rs1 = rn, .rs2 = rt, .offset = offset } },
                0b01 => .{ .lbu = .{ .rd = rt, .rs1 = rn, .offset = offset } },
                else => .{ .lb = .{ .rd = rt, .rs1 = rn, .offset = offset } },
            },
            0b01 => switch (opc) {
                0b00 => .{ .sh = .{ .rs1 = rn, .rs2 = rt, .offset = offset } },
                0b01 => .{ .lhu = .{ .rd = rt, .rs1 = rn, .offset = offset } },
                else => .{ .lh = .{ .rd = rt, .rs1 = rn, .offset = offset } },
            },
            0b10, 0b11 => switch (opc) {
                0b00 => .{ .sw = .{ .rs1 = rn, .rs2 = rt, .offset = offset } },
                0b01 => .{ .lw = .{ .rd = rt, .rs1 = rn, .offset = offset } },
                else => null,
            },
        };
    }

    return null;
}

/// Decode a 32-bit AArch64 instruction into `DecodedInsn`.
pub fn decode(raw_code: u32) DecodedInsn {
    if (decodeSystemAndBranchReg(raw_code)) |insn| {
        return .{ .insn = insn, .len = encoding.INSN_LEN_STANDARD };
    }
    if (decodeBranches(raw_code)) |insn| {
        return .{ .insn = insn, .len = encoding.INSN_LEN_STANDARD };
    }
    if (decodeDataProcImm(raw_code)) |insn| {
        return .{ .insn = insn, .len = encoding.INSN_LEN_STANDARD };
    }
    if (decodeDataProcReg(raw_code)) |insn| {
        return .{ .insn = insn, .len = encoding.INSN_LEN_STANDARD };
    }
    if (decodeLoadStore(raw_code)) |insn| {
        return .{ .insn = insn, .len = encoding.INSN_LEN_STANDARD };
    }
    return .{
        .insn = .{ .unknown = raw_code },
        .len = encoding.INSN_LEN_STANDARD,
    };
}

test "AArch64 decoder: system, branches, ALU, and load/store" {
    const testing = std.testing;
    testing.refAllDecls(@This());

    // NOP (0xd503201f) -> addi x0, x0, 0.
    const nop = decode(INSN_NOP);
    try testing.expectEqual(@as(u8, 4), nop.len);
    try testing.expectEqual(@as(u5, 0), nop.insn.addi.rd);

    // WFI (0xd503207f), ERET (0xd69f03e0), HVC #0 (0xd4000002).
    try testing.expect(decode(INSN_WFI).insn == .wfi);
    try testing.expect(decode(INSN_ERET).insn == .sret);
    try testing.expect(decode(0xd4000002).insn == .ecall);

    // B +16 (0x14000004) and BL +32 (0x94000008).
    const b_dec = decode(0x14000004);
    try testing.expectEqual(@as(u5, 0), b_dec.insn.jal.rd);
    try testing.expectEqual(@as(i32, 16), b_dec.insn.jal.offset);
    const bl_dec = decode(0x94000008);
    try testing.expectEqual(REG_LR, bl_dec.insn.jal.rd);
    try testing.expectEqual(@as(i32, 32), bl_dec.insn.jal.offset);

    // ADD X1, X2, #16 (0x91004041).
    const add_imm = decode(0x91004041);
    try testing.expectEqual(@as(u5, 1), add_imm.insn.addi.rd);
    try testing.expectEqual(@as(u5, 2), add_imm.insn.addi.rs1);
    try testing.expectEqual(@as(i32, 16), add_imm.insn.addi.imm);

    // ADD X3, X4, X5 (0x8b050083) and SUB X3, X4, X5 (0xcb050083).
    const add_reg = decode(0x8b050083);
    try testing.expectEqual(@as(u5, 3), add_reg.insn.add.rd);
    try testing.expectEqual(@as(u5, 4), add_reg.insn.add.rs1);
    try testing.expectEqual(@as(u5, 5), add_reg.insn.add.rs2);
    try testing.expectEqual(@as(u5, 3), decode(0xcb050083).insn.sub.rd);

    // LDR W1, [X2, #8] (0xb9400841) and STR W1, [X2, #12] (0xb9000c41).
    const ldr = decode(0xb9400841);
    try testing.expectEqual(@as(u5, 1), ldr.insn.lw.rd);
    try testing.expectEqual(@as(u5, 2), ldr.insn.lw.rs1);
    try testing.expectEqual(@as(i32, 8), ldr.insn.lw.offset);

    const str = decode(0xb9000c41);
    try testing.expectEqual(@as(u5, 2), str.insn.sw.rs1);
    try testing.expectEqual(@as(u5, 1), str.insn.sw.rs2);
    try testing.expectEqual(@as(i32, 12), str.insn.sw.offset);
}
