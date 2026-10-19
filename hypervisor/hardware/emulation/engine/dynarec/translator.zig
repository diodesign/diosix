// RV32 Basic-Block to RV64 Machine-Code JIT Translator.
//
// Compiles guest RV32 basic blocks directly into host RV64 machine code
// with slli+add and lui+addi instruction fusion.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const decoder_rv32 = @import("../decoders/rv32.zig");
const rv64 = @import("../emitters/rv64.zig");
const cache_mod = @import("cache.zig");
const block_mod = @import("block.zig");
const emit_alu = @import("emit/alu.zig");
const emit_mem = @import("emit/mem.zig");

const TranslationBlock = block_mod.TranslationBlock;

inline fn emit(tb: *TranslationBlock, off: *usize, insn: u32) void {
    rv64.emit(tb.host_code, off, insn);
}

fn emitLoad(
    eng: anytype,
    tb: *TranslationBlock,
    off: *usize,
    pc: u32,
    op: u3,
    rd: u5,
    rs1: u5,
    offset: i32,
) void {
    const imm = @as(i12, @truncate(offset));
    const tlb_addr = @intFromPtr(&eng.tlb.entries[0]);
    if (eng.tlb.getDirectMappingRegion(pc)) |region| {
        tb.is_fast_path = true;
        if (rs1 == 2 or rs1 == 8) {
            emit_mem.emitFastLoad(tb, off, op, rd, rs1, imm, region.delta);
        } else {
            emit_mem.emitFastLoadWithFallback(
                tlb_addr,
                tb,
                off,
                pc,
                op,
                rd,
                rs1,
                imm,
                region.vaddr_start,
                region.vaddr_end,
                region.hpa_start,
            );
        }
    } else {
        emit_mem.emitSoftTlbLoad(tlb_addr, tb, off, pc, op, rd, rs1, imm);
    }
}

fn emitStore(
    eng: anytype,
    tb: *TranslationBlock,
    off: *usize,
    pc: u32,
    op: u3,
    rs1: u5,
    rs2: u5,
    offset: i32,
) void {
    const imm = @as(i12, @truncate(offset));
    const tlb_addr = @intFromPtr(&eng.tlb.entries[0]);
    if (eng.tlb.getDirectMappingRegion(pc)) |region| {
        tb.is_fast_path = true;
        if (rs1 == 2 or rs1 == 8) {
            emit_mem.emitFastStore(tb, off, op, rs1, rs2, imm, region.delta);
        } else {
            emit_mem.emitFastStoreWithFallback(
                tlb_addr,
                tb,
                off,
                pc,
                op,
                rs1,
                rs2,
                imm,
                region.vaddr_start,
                region.vaddr_end,
                region.hpa_start,
            );
        }
    } else {
        emit_mem.emitSoftTlbStore(tlb_addr, tb, off, pc, op, rs1, rs2, imm);
    }
}

fn emitAmo(
    tlb_addr: usize,
    tb: *TranslationBlock,
    off: *usize,
    pc: u32,
    funct5: u5,
    d: decoder_rv32.AmoType,
) void {
    emit_mem.emitSoftTlbAtomic(
        tlb_addr,
        tb,
        off,
        pc,
        funct5,
        d.aq,
        d.rl,
        d.rd,
        d.rs1,
        d.rs2,
    );
}

/// Compile guest basic block starting at `start_pc` directly into RV64 machine
/// code.
pub fn translateBlock(
    self: anytype,
    start_pc: u32,
) !*TranslationBlock {
    if (self.cache.lookup(start_pc, self.vcpu.satp)) |existing| {
        return existing;
    }

    const max_insns: usize = 32;
    const max_host_bytes: usize = max_insns * 200 + 512;
    const is_global = (self.vcpu.privilege_mode != 0) or
        (self.tlb.getDirectMappingRegion(start_pc) != null);
    const tb = try self.cache.allocateBlock(
        start_pc,
        self.vcpu.satp,
        is_global,
        max_host_bytes,
    );

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

    // Restore guest t0 from 40(s11) at block start.
    emit(tb, off, rv64.ld(5, 27, 40));

    while ((pc - start_pc) < (max_insns * 4)) {
        if (host_offset + 256 >= tb.host_code.len) break;

        const fetch_res = self.tlb.fetchU32(pc, self.bus);
        if (fetch_res.trap) |cause| {
            self.trap(cause, pc, pc);
            return error.GuestFetchFault;
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
                    (next_pc - start_pc) < (max_insns * 4))
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
                    if ((next_pc - start_pc) < (max_insns * 4)) {
                        const nf = self.tlb.fetchU32(next_pc, self.bus);
                        if (nf.trap == null) {
                            const nd = decoder_rv32.decode(nf.val);
                            if (nd.insn == .addi and
                                nd.insn.addi.rd == d.rd and
                                nd.insn.addi.rs1 == d.rd)
                            {
                                const hi = (@as(u32, @bitCast(d.imm)) &
                                    0xfffff) << 12;
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
                        if (d.rd == 27) {
                            emit(tb, off, rv64.sd(27, 5, 40));
                            emit(tb, off, rv64.lui(5, @truncate(d.imm)));
                            emit(tb, off, rv64.sd(27, 5, 216));
                            emit(tb, off, rv64.ld(5, 27, 40));
                        } else {
                            emit(tb, off, rv64.lui(d.rd, @truncate(d.imm)));
                        }
                    }
                }
            },
            .auipc => |d| {
                const val = pc +% ((@as(u32, @bitCast(d.imm)) & 0xfffff) << 12);
                emit_alu.emitLoadImm32(tb, off, d.rd, val);
            },

            .lw => |d| emitLoad(self, tb, off, pc, 2, d.rd, d.rs1, d.offset),
            .lh => |d| emitLoad(self, tb, off, pc, 1, d.rd, d.rs1, d.offset),
            .lb => |d| emitLoad(self, tb, off, pc, 0, d.rd, d.rs1, d.offset),
            .lhu => |d| emitLoad(self, tb, off, pc, 5, d.rd, d.rs1, d.offset),
            .lbu => |d| emitLoad(self, tb, off, pc, 4, d.rd, d.rs1, d.offset),
            .flw => |d| {
                if (((self.vcpu.mstatus >> 13) & 3) == 0) break;
                self.vcpu.mstatus |= (3 << 13);
                emitLoad(self, tb, off, pc, 6, d.rd, d.rs1, d.offset);
            },
            .fld => |d| {
                if (((self.vcpu.mstatus >> 13) & 3) == 0) break;
                self.vcpu.mstatus |= (3 << 13);
                emitLoad(self, tb, off, pc, 7, d.rd, d.rs1, d.offset);
            },

            .sw => |d| emitStore(self, tb, off, pc, 2, d.rs1, d.rs2, d.offset),
            .sh => |d| emitStore(self, tb, off, pc, 1, d.rs1, d.rs2, d.offset),
            .sb => |d| emitStore(self, tb, off, pc, 0, d.rs1, d.rs2, d.offset),
            .fsw => |d| {
                if (((self.vcpu.mstatus >> 13) & 3) == 0) break;
                self.vcpu.mstatus |= (3 << 13);
                emitStore(self, tb, off, pc, 6, d.rs1, d.rs2, d.offset);
            },
            .fsd => |d| {
                if (((self.vcpu.mstatus >> 13) & 3) == 0) break;
                self.vcpu.mstatus |= (3 << 13);
                emitStore(self, tb, off, pc, 7, d.rs1, d.rs2, d.offset);
            },

            .fp_op => |d| {
                if (((self.vcpu.mstatus >> 13) & 3) == 0) break;
                self.vcpu.mstatus |= (3 << 13);
                emit(tb, off, d.raw);
            },

            .lr_w, .sc_w => break,
            .amoswap_w => |d| emitAmo(tlb_addr, tb, off, pc, 0x01, d),
            .amoadd_w => |d| emitAmo(tlb_addr, tb, off, pc, 0x00, d),
            .amoxor_w => |d| emitAmo(tlb_addr, tb, off, pc, 0x04, d),
            .amoand_w => |d| emitAmo(tlb_addr, tb, off, pc, 0x0c, d),
            .amoor_w => |d| emitAmo(tlb_addr, tb, off, pc, 0x08, d),
            .amomin_w => |d| emitAmo(tlb_addr, tb, off, pc, 0x10, d),
            .amomax_w => |d| emitAmo(tlb_addr, tb, off, pc, 0x14, d),
            .amominu_w => |d| emitAmo(tlb_addr, tb, off, pc, 0x18, d),
            .amomaxu_w => |d| emitAmo(tlb_addr, tb, off, pc, 0x1c, d),

            .fence => emit(tb, off, 0x0ff0000f),
            .fence_i, .pause, .sfence_vma => break,

            .csrrs => |d| {
                if (emit_alu.mapPerformanceCounterCsr(d.csr)) |c| {
                    emit_alu.emitCsrRead(tb, off, d.rd, c.host_csr, c.is_high);
                } else break;
            },
            .csrrw, .csrrc => |d| {
                if (d.rs1 == 0) {
                    if (emit_alu.mapPerformanceCounterCsr(d.csr)) |c| {
                        emit_alu.emitCsrRead(
                            tb,
                            off,
                            d.rd,
                            c.host_csr,
                            c.is_high,
                        );
                    } else break;
                } else break;
            },
            .csrrsi, .csrrci => |d| {
                if (d.uimm == 0) {
                    if (emit_alu.mapPerformanceCounterCsr(d.csr)) |c| {
                        emit_alu.emitCsrRead(
                            tb,
                            off,
                            d.rd,
                            c.host_csr,
                            c.is_high,
                        );
                    } else break;
                } else break;
            },

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

test "emitLoad dispatches SoftTLB load when no direct mapping region" {
    const vcpu_mod = @import("../../vcpu.zig");
    const softtlb_mod = @import("../../softtlb.zig");
    const bus_mod = @import("../../devices/bus.zig");
    const engine_mod = @import("engine.zig");

    var vcpu = vcpu_mod.VCpu{ .id = 0, .pc = 0x8000_0000 };
    var tlb: softtlb_mod.SoftTlb = undefined;
    tlb.initOnPtr(0x8000_0000, 0x8000_0000, 4096);
    var bus = bus_mod.Bus{
        .uart = undefined,
        .timer = undefined,
        .pic = undefined,
    };
    const eng = try std.testing.allocator.create(engine_mod.Engine);
    defer std.testing.allocator.destroy(eng);
    var raw_pool: [1024]u8 align(4096) = undefined;
    eng.initOnPtr(&raw_pool, &vcpu, &tlb, &bus);

    const tb = try eng.cache.allocateBlock(0x1000_0000, 0, false, 512);
    var off: usize = 0;
    emitLoad(eng, tb, &off, 0x1000_0000, 2, 10, 11, 0);
    try std.testing.expect(off > 0);
}
