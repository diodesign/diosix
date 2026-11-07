// x86_64 Instruction Decoder for Diosix Hypervisor
//
// Decodes variable-length x86_64 instructions (1..4 bytes per parcel) into
// the common Diosix emulation IR (`encoding.DecodedInsn`) consumed by both
// the single-step interpreter and the RV64 dynamic binary translator.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const encoding = @import("rv32/encoding.zig");

pub const Instruction = encoding.Instruction;
pub const DecodedInsn = encoding.DecodedInsn;

// Mapped x86_64 GPR indices in VCpu.regs (offset by +1 so x0 remains 0):
// RAX=1, RCX=2, RDX=3, RBX=4, RSP=5, RBP=6, RSI=7, RDI=8, R8..R15=9..16.
pub const REG_RAX: u5 = 1;
pub const REG_RCX: u5 = 2;
pub const REG_RDX: u5 = 3;
pub const REG_RBX: u5 = 4;
pub const REG_RSP: u5 = 5;
pub const REG_RBP: u5 = 6;
pub const REG_RSI: u5 = 7;
pub const REG_RDI: u5 = 8;
pub const REG_RA: u5 = 31;

pub inline fn mapX86Reg(reg3: u3, rex_ext: bool) u5 {
    const ext: u5 = if (rex_ext) 8 else 0;
    return @as(u5, reg3) + ext + 1;
}

fn decodeTwoByteOpcode(
    bytes: []const u8,
    idx: usize,
    rex_r: bool,
    rex_b: bool,
) ?DecodedInsn {
    if (idx + 1 >= bytes.len) return null;
    const op2 = bytes[idx + 1];
    switch (op2) {
        // SYSCALL (0f 05).
        0x05 => return .{ .insn = .ecall, .len = @intCast(idx + 2) },
        // SYSRET (0f 07).
        0x07 => return .{ .insn = .sret, .len = @intCast(idx + 2) },
        // WRMSR (0f 30).
        0x30 => return .{
            .insn = .{ .csrrw = .{ .rd = 0, .rs1 = REG_RAX, .csr = 0 } },
            .len = @intCast(idx + 2),
        },
        // RDMSR (0f 32).
        0x32 => return .{
            .insn = .{ .csrrs = .{ .rd = REG_RAX, .rs1 = 0, .csr = 0 } },
            .len = @intCast(idx + 2),
        },
        // VMCALL (0f 01 c1).
        0x01 => {
            if (idx + 2 < bytes.len and bytes[idx + 2] == 0xc1) {
                return .{ .insn = .ecall, .len = @intCast(idx + 3) };
            }
            return null;
        },
        // LFENCE / MFENCE / SFENCE (0f ae /5..7).
        0xae => {
            if (idx + 2 < bytes.len) {
                return .{ .insn = .fence, .len = @intCast(idx + 3) };
            }
            return null;
        },
        // IMUL r, r/m (0f af /r).
        0xaf => {
            if (idx + 2 >= bytes.len) return null;
            const modrm = bytes[idx + 2];
            if ((modrm >> 6) != 0b11) return null;
            const reg = mapX86Reg(@truncate((modrm >> 3) & 0x7), rex_r);
            const rm = mapX86Reg(@truncate(modrm & 0x7), rex_b);
            return .{
                .insn = .{ .mul = .{ .rd = reg, .rs1 = reg, .rs2 = rm } },
                .len = @intCast(idx + 3),
            };
        },
        else => return null,
    }
}

fn decodeModRmAluAndMov(
    op: u8,
    bytes: []const u8,
    idx: usize,
    rex_r: bool,
    rex_b: bool,
) ?DecodedInsn {
    if (idx + 1 >= bytes.len) return null;
    const modrm = bytes[idx + 1];
    const mod: u2 = @truncate(modrm >> 6);
    const reg_field: u3 = @truncate((modrm >> 3) & 0x7);
    const rm_field: u3 = @truncate(modrm & 0x7);
    const reg = mapX86Reg(reg_field, rex_r);
    const rm = mapX86Reg(rm_field, rex_b);

    // Memory addressing: [rm] (mod == 00) or [rm + disp8] (mod == 01).
    if (mod == 0b00 or mod == 0b01) {
        if (rm_field == 0b100 or (mod == 0b00 and rm_field == 0b101)) {
            return null;
        }
        const has_disp8 = (mod == 0b01);
        const insn_len: u8 = @intCast(idx + 2 + @intFromBool(has_disp8));
        if (insn_len > bytes.len) return null;
        const disp: i32 = if (has_disp8)
            @as(i8, @bitCast(bytes[idx + 2]))
        else
            0;
        return switch (op) {
            0x88 => .{
                .insn = .{ .sb = .{ .rs1 = rm, .rs2 = reg, .offset = disp } },
                .len = insn_len,
            },
            0x89 => .{
                .insn = .{ .sw = .{ .rs1 = rm, .rs2 = reg, .offset = disp } },
                .len = insn_len,
            },
            0x8a => .{
                .insn = .{ .lbu = .{ .rd = reg, .rs1 = rm, .offset = disp } },
                .len = insn_len,
            },
            0x8b => .{
                .insn = .{ .lw = .{ .rd = reg, .rs1 = rm, .offset = disp } },
                .len = insn_len,
            },
            else => null,
        };
    }

    if (mod != 0b11) return null;
    const reg_len: u8 = @intCast(idx + 2);

    return switch (op) {
        0x89 => .{
            .insn = .{ .addi = .{ .rd = rm, .rs1 = reg, .imm = 0 } },
            .len = reg_len,
        },
        0x8b => .{
            .insn = .{ .addi = .{ .rd = reg, .rs1 = rm, .imm = 0 } },
            .len = reg_len,
        },
        0x01 => .{
            .insn = .{ .add = .{ .rd = rm, .rs1 = rm, .rs2 = reg } },
            .len = reg_len,
        },
        0x03 => .{
            .insn = .{ .add = .{ .rd = reg, .rs1 = reg, .rs2 = rm } },
            .len = reg_len,
        },
        0x29 => .{
            .insn = .{ .sub = .{ .rd = rm, .rs1 = rm, .rs2 = reg } },
            .len = reg_len,
        },
        0x2b => .{
            .insn = .{ .sub = .{ .rd = reg, .rs1 = reg, .rs2 = rm } },
            .len = reg_len,
        },
        0x21 => .{
            .insn = .{ .and_ = .{ .rd = rm, .rs1 = rm, .rs2 = reg } },
            .len = reg_len,
        },
        0x23 => .{
            .insn = .{ .and_ = .{ .rd = reg, .rs1 = reg, .rs2 = rm } },
            .len = reg_len,
        },
        0x09 => .{
            .insn = .{ .or_ = .{ .rd = rm, .rs1 = rm, .rs2 = reg } },
            .len = reg_len,
        },
        0x0b => .{
            .insn = .{ .or_ = .{ .rd = reg, .rs1 = reg, .rs2 = rm } },
            .len = reg_len,
        },
        0x31 => .{
            .insn = if (rm == reg)
                .{ .addi = .{ .rd = rm, .rs1 = 0, .imm = 0 } }
            else
                .{ .xor_ = .{ .rd = rm, .rs1 = rm, .rs2 = reg } },
            .len = reg_len,
        },
        0x33 => .{
            .insn = if (rm == reg)
                .{ .addi = .{ .rd = reg, .rs1 = 0, .imm = 0 } }
            else
                .{ .xor_ = .{ .rd = reg, .rs1 = reg, .rs2 = rm } },
            .len = reg_len,
        },
        0x83 => {
            if (idx + 2 >= bytes.len) return null;
            const imm8: i32 = @as(i8, @bitCast(bytes[idx + 2]));
            const imm_len: u8 = @intCast(idx + 3);
            return switch (reg_field) {
                0b000 => .{
                    .insn = .{ .addi = .{ .rd = rm, .rs1 = rm, .imm = imm8 } },
                    .len = imm_len,
                },
                0b001 => .{
                    .insn = .{ .ori = .{ .rd = rm, .rs1 = rm, .imm = imm8 } },
                    .len = imm_len,
                },
                0b100 => .{
                    .insn = .{ .andi = .{ .rd = rm, .rs1 = rm, .imm = imm8 } },
                    .len = imm_len,
                },
                0b101 => .{
                    .insn = .{ .addi = .{ .rd = rm, .rs1 = rm, .imm = -imm8 } },
                    .len = imm_len,
                },
                0b110 => .{
                    .insn = .{ .xori = .{ .rd = rm, .rs1 = rm, .imm = imm8 } },
                    .len = imm_len,
                },
                0b111 => .{
                    .insn = .{
                        .addi = .{ .rd = REG_RAX, .rs1 = rm, .imm = -imm8 },
                    },
                    .len = imm_len,
                },
                else => null,
            };
        },
        0xc1 => {
            if (idx + 2 >= bytes.len) return null;
            const shamt: u5 = @truncate(bytes[idx + 2] & 0x1f);
            const sh_len: u8 = @intCast(idx + 3);
            return switch (reg_field) {
                0b100 => .{
                    .insn = .{
                        .slli = .{ .rd = rm, .rs1 = rm, .shamt = shamt },
                    },
                    .len = sh_len,
                },
                0b101 => .{
                    .insn = .{
                        .srli = .{ .rd = rm, .rs1 = rm, .shamt = shamt },
                    },
                    .len = sh_len,
                },
                0b111 => .{
                    .insn = .{
                        .srai = .{ .rd = rm, .rs1 = rm, .shamt = shamt },
                    },
                    .len = sh_len,
                },
                else => null,
            };
        },
        else => null,
    };
}

/// Decode up to 4 bytes of x86_64 machine code into `DecodedInsn`.
pub fn decode(bytes: []const u8) DecodedInsn {
    if (bytes.len == 0) {
        return .{ .insn = .{ .unknown = 0 }, .len = 1 };
    }
    // PAUSE (f3 90).
    if (bytes.len >= 2 and bytes[0] == 0xf3 and bytes[1] == 0x90) {
        return .{ .insn = .pause, .len = 2 };
    }

    var idx: usize = 0;
    var rex_r = false;
    var rex_b = false;

    if (bytes[idx] == 0x66 and idx + 1 < bytes.len) {
        idx += 1;
    }
    if ((bytes[idx] & 0xf0) == 0x40 and idx + 1 < bytes.len) {
        const rex = bytes[idx];
        rex_r = (rex & 0x04) != 0;
        rex_b = (rex & 0x01) != 0;
        idx += 1;
    }

    const op = bytes[idx];
    const len1: u8 = @intCast(idx + 1);

    switch (op) {
        0x90 => return .{
            .insn = .{ .addi = .{ .rd = 0, .rs1 = 0, .imm = 0 } },
            .len = len1,
        },
        0xf4 => return .{ .insn = .wfi, .len = len1 },
        0xcc => return .{ .insn = .ebreak, .len = len1 },
        0xc3 => return .{
            .insn = .{ .jalr = .{ .rd = 0, .rs1 = REG_RA, .offset = 0 } },
            .len = len1,
        },
        0xcf => return .{ .insn = .sret, .len = len1 },
        0xcd => {
            if (idx + 1 < bytes.len) {
                const imm8 = bytes[idx + 1];
                return .{
                    .insn = if (imm8 == 3) .ebreak else .ecall,
                    .len = @intCast(idx + 2),
                };
            }
        },
        0x0f => {
            if (decodeTwoByteOpcode(bytes, idx, rex_r, rex_b)) |dec| {
                return dec;
            }
        },
        0xeb, 0x72, 0x73, 0x74, 0x75, 0x7c, 0x7d => {
            if (idx + 1 < bytes.len) {
                const jlen: u8 = @intCast(idx + 2);
                const rel8: i32 = @as(i8, @bitCast(bytes[idx + 1]));
                const target_off: i32 = @as(i32, jlen) + rel8;
                const insn: Instruction = switch (op) {
                    0xeb => .{ .jal = .{ .rd = 0, .offset = target_off } },
                    0x72 => .{
                        .bltu = .{
                            .rs1 = REG_RAX,
                            .rs2 = 0,
                            .offset = target_off,
                        },
                    },
                    0x73 => .{
                        .bgeu = .{
                            .rs1 = REG_RAX,
                            .rs2 = 0,
                            .offset = target_off,
                        },
                    },
                    0x74 => .{
                        .beq = .{
                            .rs1 = REG_RAX,
                            .rs2 = 0,
                            .offset = target_off,
                        },
                    },
                    0x75 => .{
                        .bne = .{
                            .rs1 = REG_RAX,
                            .rs2 = 0,
                            .offset = target_off,
                        },
                    },
                    0x7c => .{
                        .blt = .{
                            .rs1 = REG_RAX,
                            .rs2 = 0,
                            .offset = target_off,
                        },
                    },
                    else => .{
                        .bge = .{
                            .rs1 = REG_RAX,
                            .rs2 = 0,
                            .offset = target_off,
                        },
                    },
                };
                return .{ .insn = insn, .len = jlen };
            }
        },
        0xb0...0xb7 => {
            if (idx + 1 < bytes.len) {
                const reg = mapX86Reg(@truncate(op - 0xb0), rex_b);
                const imm8: i32 = bytes[idx + 1];
                return .{
                    .insn = .{ .addi = .{ .rd = reg, .rs1 = 0, .imm = imm8 } },
                    .len = @intCast(idx + 2),
                };
            }
        },
        else => {
            if (decodeModRmAluAndMov(op, bytes, idx, rex_r, rex_b)) |dec| {
                return dec;
            }
        },
    }

    var raw: u32 = 0;
    const copy_len = @min(bytes.len, 4);
    for (0..copy_len) |i| {
        raw |= @as(u32, bytes[i]) << @intCast(i * 8);
    }
    return .{ .insn = .{ .unknown = raw }, .len = 1 };
}

/// Decode a 32-bit little-endian instruction parcel fetched from `SoftTlb`.
pub fn decodeU32(raw_code: u32) DecodedInsn {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, raw_code, .little);
    return decode(&bytes);
}

test "x86_64 decoder: system, branches, ModRM ALU, and memory ops" {
    const testing = std.testing;
    testing.refAllDecls(@This());

    // NOP (0x90), HLT (0xf4), SYSCALL (0x0f 0x05), PAUSE (0xf3 0x90).
    try testing.expectEqual(@as(u8, 1), decode(&[_]u8{0x90}).len);
    try testing.expect(decode(&[_]u8{0xf4}).insn == .wfi);
    try testing.expect(decode(&[_]u8{ 0x0f, 0x05 }).insn == .ecall);
    try testing.expect(decode(&[_]u8{ 0xf3, 0x90 }).insn == .pause);

    // ADD RAX, RCX (48 01 c8).
    const add_dec = decode(&[_]u8{ 0x48, 0x01, 0xc8 });
    try testing.expectEqual(@as(u8, 3), add_dec.len);
    try testing.expectEqual(REG_RAX, add_dec.insn.add.rd);
    try testing.expectEqual(REG_RAX, add_dec.insn.add.rs1);
    try testing.expectEqual(REG_RCX, add_dec.insn.add.rs2);

    // ADD RAX, 16 (48 83 c0 10).
    const addi_dec = decode(&[_]u8{ 0x48, 0x83, 0xc0, 0x10 });
    try testing.expectEqual(@as(u8, 4), addi_dec.len);
    try testing.expectEqual(REG_RAX, addi_dec.insn.addi.rd);
    try testing.expectEqual(@as(i32, 16), addi_dec.insn.addi.imm);

    // MOV EAX, [RCX + 8] (8b 41 08).
    const lw_dec = decode(&[_]u8{ 0x8b, 0x41, 0x08 });
    try testing.expectEqual(@as(u8, 3), lw_dec.len);
    try testing.expectEqual(REG_RAX, lw_dec.insn.lw.rd);
    try testing.expectEqual(REG_RCX, lw_dec.insn.lw.rs1);
    try testing.expectEqual(@as(i32, 8), lw_dec.insn.lw.offset);

    // JMP +4 (eb 04): offset relative to pc_before is 2 + 4 = 6.
    const jmp_dec = decode(&[_]u8{ 0xeb, 0x04 });
    try testing.expectEqual(@as(u8, 2), jmp_dec.len);
    try testing.expectEqual(@as(i32, 6), jmp_dec.insn.jal.offset);
}
