// RV32 Basic-Block to RV64 Machine-Code JIT Translator.
//
// Compiles guest RV32 basic blocks directly into host RV64 machine code
// with slli+add and lui+addi instruction fusion.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("interface").riscv;
const vcpu_mod = @import("../../vcpu.zig");
const decoder_rv32 = @import("../decoders/rv32.zig");
const rv64 = @import("../emitters/rv64.zig");
const block_mod = @import("block.zig");
const emit_alu = @import("emit/alu.zig");
const emit_mem = @import("emit/mem.zig");

const TranslationBlock = block_mod.TranslationBlock;
const T0 = block_mod.HOST_REG_T0;
const S11 = block_mod.HOST_REG_S11;
const OFF_T0 = block_mod.VCPU_OFF_T0;
const OFF_S11 = block_mod.VCPU_OFF_S11;
const Op = emit_mem.MemOp;
const AmoFunct5 = rv64.AmoFunct5;

pub const emitLoad = emit_mem.emitLoad;
pub const emitStore = emit_mem.emitStore;
pub const emitAmo = emit_mem.emitAmo;

pub const MAX_BLOCK_INSNS: usize = 32;
pub const HOST_BYTES_PER_GUEST_INSN: usize = 200;
pub const HOST_EPILOGUE_PAD_BYTES: usize = 512;
pub const HOST_LOOP_GUARD_BYTES: usize = 256;
pub const U_IMM_MASK: u32 = 0xfffff;
pub const U_IMM_SHIFT: u5 = 12;

inline fn emit(tb: *TranslationBlock, off: *usize, insn: u32) void {
    rv64.emit(tb.host_code, off, insn);
}

/// Compile guest basic block starting at `start_pc` directly into RV64 machine
/// code.
pub fn translateBlock(
    self: anytype,
    start_pc: u32,
) !*TranslationBlock {
    const priv = self.vcpu.privilege_mode;
    if (self.cache.lookup(start_pc, self.vcpu.satp, priv)) |existing| {
        return existing;
    }

    const max_host_bytes: usize =
        MAX_BLOCK_INSNS * HOST_BYTES_PER_GUEST_INSN + HOST_EPILOGUE_PAD_BYTES;
    const is_global = (priv != riscv.PRIV_USER);
    const tb = try self.cache.allocateBlock(
        start_pc,
        self.vcpu.satp,
        is_global,
        max_host_bytes,
    );
    tb.priv = priv;

    var pc = start_pc;
    var host_offset: usize = 0;
    const off = &host_offset;
    var has_explicit_exit: bool = false;
    const tlb_addr = @intFromPtr(&self.tlb.entries[0]);

    const rType = emit_alu.emitRType;
    const bitR = emit_alu.emitBitwiseR;
    const iType = emit_alu.emitIType;
    const shiftI = emit_alu.emitShiftI;
    const bitI = emit_alu.emitBitwiseI;

    // Restore guest t0 from VCPU_OFF_T0(s11) at block start.
    emit(tb, off, rv64.ld(T0, S11, OFF_T0));

    while ((pc - start_pc) < (MAX_BLOCK_INSNS * 4)) {
        if (host_offset + HOST_LOOP_GUARD_BYTES >= tb.host_code.len) break;

        const fetch_res = self.tlb.fetchU32(pc, self.bus);
        if (fetch_res.trap != null) {
            if (pc == start_pc) {
                self.cache.cancelBlock();
                return error.GuestFetchFault;
            }
            break;
        }

        const decoded = decoder_rv32.decode(fetch_res.val);

        switch (decoded.insn) {
            .add => |d| rType(tb, off, rv64.addw, d.rd, d.rs1, d.rs2),
            .sub => |d| rType(tb, off, rv64.subw, d.rd, d.rs1, d.rs2),
            .sll => |d| rType(tb, off, rv64.sllw, d.rd, d.rs1, d.rs2),
            .slt => |d| rType(tb, off, rv64.slt, d.rd, d.rs1, d.rs2),
            .sltu => |d| rType(tb, off, rv64.sltu, d.rd, d.rs1, d.rs2),
            .xor_ => |d| bitR(tb, off, rv64.xor_, d.rd, d.rs1, d.rs2),
            .srl => |d| rType(tb, off, rv64.srlw, d.rd, d.rs1, d.rs2),
            .sra => |d| rType(tb, off, rv64.sraw, d.rd, d.rs1, d.rs2),
            .or_ => |d| bitR(tb, off, rv64.or_, d.rd, d.rs1, d.rs2),
            .and_ => |d| bitR(tb, off, rv64.and_, d.rd, d.rs1, d.rs2),

            .mul => |d| rType(tb, off, rv64.mulw, d.rd, d.rs1, d.rs2),
            .mulh => |d| emit_alu.emitMulh(tb, off, d.rd, d.rs1, d.rs2),
            .mulhu => |d| emit_alu.emitMulhu(tb, off, d.rd, d.rs1, d.rs2),
            .mulhsu => |d| emit_alu.emitMulhsu(tb, off, d.rd, d.rs1, d.rs2),
            .div => |d| rType(tb, off, rv64.divw, d.rd, d.rs1, d.rs2),
            .divu => |d| rType(tb, off, rv64.divuw, d.rd, d.rs1, d.rs2),
            .rem => |d| rType(tb, off, rv64.remw, d.rd, d.rs1, d.rs2),
            .remu => |d| rType(tb, off, rv64.remuw, d.rd, d.rs1, d.rs2),

            .addi => |d| iType(
                tb,
                off,
                rv64.addiw,
                d.rd,
                d.rs1,
                @truncate(d.imm),
            ),
            .slli => |d| {
                const next_pc = pc + decoded.len;
                var fused = false;
                if (d.rd != 0 and
                    (d.shamt == 1 or d.shamt == 2 or d.shamt == 3) and
                    (next_pc - start_pc) < (MAX_BLOCK_INSNS * 4))
                {
                    const nf = self.tlb.fetchU32(next_pc, self.bus);
                    if (nf.trap == null) {
                        const nd = decoder_rv32.decode(nf.val);
                        if (nd.insn == .add and nd.insn.add.rd == d.rd and
                            (nd.insn.add.rs1 == d.rd or
                                nd.insn.add.rs2 == d.rd))
                        {
                            const other: u5 = if (nd.insn.add.rs1 == d.rd)
                                nd.insn.add.rs2
                            else
                                nd.insn.add.rs1;
                            shiftI(tb, off, rv64.slliw, d.rd, d.rs1, d.shamt);
                            rType(tb, off, rv64.addw, d.rd, d.rd, other);
                            pc += nd.len;
                            fused = true;
                        }
                    }
                }
                if (!fused) shiftI(tb, off, rv64.slliw, d.rd, d.rs1, d.shamt);
            },
            .srli => |d| shiftI(tb, off, rv64.srliw, d.rd, d.rs1, d.shamt),
            .srai => |d| shiftI(tb, off, rv64.sraiw, d.rd, d.rs1, d.shamt),
            .andi => |d| {
                bitI(tb, off, rv64.andi, d.rd, d.rs1, @truncate(d.imm));
            },
            .ori => |d| bitI(tb, off, rv64.ori, d.rd, d.rs1, @truncate(d.imm)),
            .xori => |d| {
                bitI(tb, off, rv64.xori, d.rd, d.rs1, @truncate(d.imm));
            },
            .slti => |d| iType(
                tb,
                off,
                rv64.slti,
                d.rd,
                d.rs1,
                @truncate(d.imm),
            ),
            .sltiu => |d| iType(
                tb,
                off,
                rv64.sltiu,
                d.rd,
                d.rs1,
                @truncate(d.imm),
            ),

            .lui => |d| {
                if (d.rd != 0) {
                    const next_pc = pc + decoded.len;
                    var fused = false;
                    if ((next_pc - start_pc) < (MAX_BLOCK_INSNS * 4)) {
                        const nf = self.tlb.fetchU32(next_pc, self.bus);
                        if (nf.trap == null) {
                            const nd = decoder_rv32.decode(nf.val);
                            if (nd.insn == .addi and
                                nd.insn.addi.rd == d.rd and
                                nd.insn.addi.rs1 == d.rd)
                            {
                                const hi = (@as(u32, @bitCast(d.imm)) &
                                    U_IMM_MASK) << U_IMM_SHIFT;
                                const lo = @as(
                                    u32,
                                    @bitCast(@as(i32, nd.insn.addi.imm)),
                                );
                                emit_alu.emitLoadImm32(tb, off, d.rd, hi +% lo);
                                pc += nd.len;
                                fused = true;
                            }
                        }
                    }
                    if (!fused) {
                        if (d.rd == S11) {
                            emit(tb, off, rv64.sd(S11, T0, OFF_T0));
                            emit(tb, off, rv64.lui(T0, @truncate(d.imm)));
                            emit(tb, off, rv64.sd(S11, T0, OFF_S11));
                            emit(tb, off, rv64.ld(T0, S11, OFF_T0));
                        } else {
                            emit(tb, off, rv64.lui(d.rd, @truncate(d.imm)));
                        }
                    }
                }
            },
            .auipc => |d| {
                const val = pc +% ((@as(u32, @bitCast(d.imm)) &
                    U_IMM_MASK) << U_IMM_SHIFT);
                emit_alu.emitLoadImm32(tb, off, d.rd, val);
            },

            .lw => |d| {
                emitLoad(self, tb, off, pc, Op.LW, d.rd, d.rs1, d.offset);
            },
            .lh => |d| {
                emitLoad(self, tb, off, pc, Op.LH, d.rd, d.rs1, d.offset);
            },
            .lb => |d| {
                emitLoad(self, tb, off, pc, Op.LB, d.rd, d.rs1, d.offset);
            },
            .lhu => |d| {
                emitLoad(self, tb, off, pc, Op.LHU, d.rd, d.rs1, d.offset);
            },
            .lbu => |d| {
                emitLoad(self, tb, off, pc, Op.LBU, d.rd, d.rs1, d.offset);
            },
            .flw => |d| {
                if ((self.vcpu.mstatus & vcpu_mod.MSTATUS_FS_MASK_U32) == 0) {
                    break;
                }
                self.vcpu.mstatus |= vcpu_mod.MSTATUS_FS_DIRTY_U32;
                emitLoad(self, tb, off, pc, Op.FLW, d.rd, d.rs1, d.offset);
            },
            .fld => |d| {
                if ((self.vcpu.mstatus & vcpu_mod.MSTATUS_FS_MASK_U32) == 0) {
                    break;
                }
                self.vcpu.mstatus |= vcpu_mod.MSTATUS_FS_DIRTY_U32;
                emitLoad(self, tb, off, pc, Op.FLD, d.rd, d.rs1, d.offset);
            },

            .sw => |d| {
                emitStore(self, tb, off, pc, Op.SW, d.rs1, d.rs2, d.offset);
            },
            .sh => |d| {
                emitStore(self, tb, off, pc, Op.SH, d.rs1, d.rs2, d.offset);
            },
            .sb => |d| {
                emitStore(self, tb, off, pc, Op.SB, d.rs1, d.rs2, d.offset);
            },
            .fsw => |d| {
                if ((self.vcpu.mstatus & vcpu_mod.MSTATUS_FS_MASK_U32) == 0) {
                    break;
                }
                self.vcpu.mstatus |= vcpu_mod.MSTATUS_FS_DIRTY_U32;
                emitStore(self, tb, off, pc, Op.FSW, d.rs1, d.rs2, d.offset);
            },
            .fsd => |d| {
                if ((self.vcpu.mstatus & vcpu_mod.MSTATUS_FS_MASK_U32) == 0) {
                    break;
                }
                self.vcpu.mstatus |= vcpu_mod.MSTATUS_FS_DIRTY_U32;
                emitStore(self, tb, off, pc, Op.FSD, d.rs1, d.rs2, d.offset);
            },

            .fp_op => |d| {
                if ((self.vcpu.mstatus & vcpu_mod.MSTATUS_FS_MASK_U32) == 0) {
                    break;
                }
                self.vcpu.mstatus |= vcpu_mod.MSTATUS_FS_DIRTY_U32;
                emit(tb, off, d.raw);
            },

            .lr_w, .sc_w => break,
            .amoswap_w => |d| emitAmo(tlb_addr, tb, off, pc, AmoFunct5.SWAP, d),
            .amoadd_w => |d| emitAmo(tlb_addr, tb, off, pc, AmoFunct5.ADD, d),
            .amoxor_w => |d| emitAmo(tlb_addr, tb, off, pc, AmoFunct5.XOR, d),
            .amoand_w => |d| emitAmo(tlb_addr, tb, off, pc, AmoFunct5.AND, d),
            .amoor_w => |d| emitAmo(tlb_addr, tb, off, pc, AmoFunct5.OR, d),
            .amomin_w => |d| emitAmo(tlb_addr, tb, off, pc, AmoFunct5.MIN, d),
            .amomax_w => |d| emitAmo(tlb_addr, tb, off, pc, AmoFunct5.MAX, d),
            .amominu_w => |d| emitAmo(tlb_addr, tb, off, pc, AmoFunct5.MINU, d),
            .amomaxu_w => |d| emitAmo(tlb_addr, tb, off, pc, AmoFunct5.MAXU, d),

            .fence => emit(tb, off, rv64.FENCE_IORW),
            .fence_i, .pause, .sfence_vma => break,

            .csrrs => |d| {
                if (emit_alu.mapPerformanceCounterCsr(d.csr)) |c| {
                    emit_alu.emitCsrRead(tb, off, d.rd, c.host_csr, c.is_high);
                } else break;
            },
            .csrrw, .csrrc => |d| if (d.rs1 == 0) {
                if (emit_alu.mapPerformanceCounterCsr(d.csr)) |c| {
                    emit_alu.emitCsrRead(tb, off, d.rd, c.host_csr, c.is_high);
                } else break;
            } else break,
            .csrrsi, .csrrci => |d| if (d.uimm == 0) {
                if (emit_alu.mapPerformanceCounterCsr(d.csr)) |c| {
                    emit_alu.emitCsrRead(tb, off, d.rd, c.host_csr, c.is_high);
                } else break;
            } else break,

            .jal => |d| {
                const target = pc +% @as(u32, @bitCast(d.offset));
                emit_alu.emitLoadImm32(tb, off, d.rd, pc + decoded.len);
                tb.exit_branch1 = emit_alu.emitExit(tb, off, target);
                has_explicit_exit = true;
                pc += decoded.len;
                break;
            },
            .jalr => |d| {
                emit_alu.emitJalrExit(
                    tb,
                    off,
                    pc,
                    decoded.len,
                    d.rd,
                    d.rs1,
                    d.offset,
                );
                has_explicit_exit = true;
                pc += decoded.len;
                break;
            },

            .beq => |d| {
                emit_alu.emitBranchExit(tb, off, pc, decoded.len, d, rv64.beq);
                has_explicit_exit = true;
                pc += decoded.len;
                break;
            },
            .bne => |d| {
                emit_alu.emitBranchExit(tb, off, pc, decoded.len, d, rv64.bne);
                has_explicit_exit = true;
                pc += decoded.len;
                break;
            },
            .blt => |d| {
                emit_alu.emitBranchExit(tb, off, pc, decoded.len, d, rv64.blt);
                has_explicit_exit = true;
                pc += decoded.len;
                break;
            },
            .bge => |d| {
                emit_alu.emitBranchExit(tb, off, pc, decoded.len, d, rv64.bge);
                has_explicit_exit = true;
                pc += decoded.len;
                break;
            },
            .bltu => |d| {
                emit_alu.emitBranchExit(tb, off, pc, decoded.len, d, rv64.bltu);
                has_explicit_exit = true;
                pc += decoded.len;
                break;
            },
            .bgeu => |d| {
                emit_alu.emitBranchExit(tb, off, pc, decoded.len, d, rv64.bgeu);
                has_explicit_exit = true;
                pc += decoded.len;
                break;
            },

            .ecall, .ebreak, .mret, .sret => break,
            else => break,
        }

        pc += decoded.len;
    }

    if (pc == start_pc or host_offset <= 4) {
        self.cache.cancelBlock();
        return error.CannotTranslate;
    }

    if (!has_explicit_exit) {
        tb.exit_branch1 = emit_alu.emitExit(tb, off, pc);
    }

    tb.guest_size = pc - start_pc;
    tb.host_len = host_offset;
    self.cache.commitBlock(tb, host_offset);
    self.cache.chainBlock(tb);
    return tb;
}

test "emitLoad SoftTLB dispatch and cross-page fetch fault termination" {
    const softtlb_mod = @import("../../softtlb.zig");
    const bus_mod = @import("../../devices/bus.zig");
    const engine_mod = @import("engine.zig");

    var guest_ram: [4096]u8 align(4096) = std.mem.zeroes([4096]u8);
    // Write `addi a0, a0, 1` (0x00150513) at last word of mapped page.
    std.mem.writeInt(u32, guest_ram[0xffc..0x1000], 0x0015_0513, .little);

    var vcpu = vcpu_mod.VCpu{ .id = 0, .pc = 0x8000_0ffc };
    var tlb: softtlb_mod.SoftTlb = undefined;
    tlb.initOnPtr(0x8000_0000, @intFromPtr(&guest_ram), 4096);
    var bus = bus_mod.Bus{
        .uart = undefined,
        .timer = undefined,
        .pic = undefined,
    };
    const eng = try std.testing.allocator.create(engine_mod.Engine);
    defer std.testing.allocator.destroy(eng);
    var raw_pool: [32768]u8 align(4096) = undefined;
    eng.initOnPtr(&raw_pool, &vcpu, &tlb, &bus);

    const tb_boundary = try eng.translateBlock(0x8000_0ffc);
    try std.testing.expectEqual(@as(u32, 4), tb_boundary.guest_size);
    try std.testing.expectEqual(@as(u32, 0), vcpu.scause);
    try std.testing.expectEqual(@as(u32, 0), vcpu.mcause);

    const tb = try eng.cache.allocateBlock(0x1000_0000, 0, false, 512);
    var off: usize = 0;
    emitLoad(eng, tb, &off, 0x1000_0000, Op.LW, 10, 11, 0);
    try std.testing.expect(off > 0);
    std.testing.refAllDecls(@This());
}
