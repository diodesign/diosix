// Dynamic Binary Translation & Execution Engine Loop
//
// Translates target non-native basic blocks into host RV64 machine instructions
// directly without IR pass overhead.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const decoder_rv32 = @import("../decoders/rv32.zig");
const emitter_rv64 = @import("../emitters/rv64.zig");
const cache_mod = @import("cache.zig");
const block_mod = @import("block.zig");
const vcpu_mod = @import("../../vcpu.zig");
const softtlb_mod = @import("../../softtlb.zig");
const bus_mod = @import("../../devices/bus.zig");

pub const Engine = struct {
    cache: cache_mod.Cache,
    vcpu: *vcpu_mod.VCpu,
    tlb: *softtlb_mod.SoftTlb,
    bus: *bus_mod.Bus,

    pub fn init(buffer: []u8, vcpu: *vcpu_mod.VCpu, tlb: *softtlb_mod.SoftTlb, bus: *bus_mod.Bus) Engine {
        return Engine{
            .cache = cache_mod.Cache.init(buffer),
            .vcpu = vcpu,
            .tlb = tlb,
            .bus = bus,
        };
    }

    /// Compile guest basic block starting at `guest_pc` directly into RV64 machine code
    pub fn translateBlock(self: *Engine, start_pc: u32) !*block_mod.TranslationBlock {
        if (self.cache.lookup(start_pc)) |existing| return existing;

        const max_instructions: usize = 64;
        const max_host_bytes: usize = max_instructions * 16;
        const tb = try self.cache.allocateBlock(start_pc, max_host_bytes);

        var current_pc = start_pc;
        var host_offset: usize = 0;
        var stop_block = false;

        while (!stop_block and (current_pc - start_pc) < (max_instructions * 4)) {
            const fetch_res = self.tlb.readU32(current_pc, self.bus);
            if (fetch_res.trap) |cause| {
                self.vcpu.injectException(cause, current_pc);
                return error.GuestFetchFault;
            }

            const raw_insn = fetch_res.val;
            const decoded = decoder_rv32.decode(raw_insn);

            switch (decoded.insn) {
                // ---- R-Type Integer Operations ----
                .add => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addw(d.rd, d.rs1, d.rs2)),
                .sub => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.subw(d.rd, d.rs1, d.rs2)),
                .sll => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.sllw(d.rd, d.rs1, d.rs2)),
                .srl => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.srlw(d.rd, d.rs1, d.rs2)),
                .sra => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.sraw(d.rd, d.rs1, d.rs2)),
                .or_ => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.or_(d.rd, d.rs1, d.rs2)),
                .and_ => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.and_(d.rd, d.rs1, d.rs2)),
                .xor_ => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.xor_(d.rd, d.rs1, d.rs2)),
                .slt => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.slt(d.rd, d.rs1, d.rs2)),
                .sltu => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.sltu(d.rd, d.rs1, d.rs2)),

                // ---- I-Type Integer Operations ----
                .addi => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rs1, @as(i12, @truncate(d.imm)))),
                .slli => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.slliw(d.rd, d.rs1, d.shamt)),
                .srli => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.srliw(d.rd, d.rs1, d.shamt)),
                .srai => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.sraiw(d.rd, d.rs1, d.shamt)),
                .andi => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.andi(d.rd, d.rs1, @as(i12, @truncate(d.imm)))),
                .ori => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.ori(d.rd, d.rs1, @as(i12, @truncate(d.imm)))),
                .xori => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.xori(d.rd, d.rs1, @as(i12, @truncate(d.imm)))),
                .slti => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.slti(d.rd, d.rs1, @as(i12, @truncate(d.imm)))),
                .sltiu => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.sltiu(d.rd, d.rs1, @as(i12, @truncate(d.imm)))),

                // ---- Upper Immediate Operations ----
                .lui => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.lui(d.rd, @as(i20, @truncate(d.imm)))),
                .auipc => |d| {
                    const val = @as(i32, @bitCast(current_pc)) +% (d.imm << 12);
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.lui(d.rd, @as(i20, @truncate(val >> 12))));
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rd, @as(i12, @truncate(val & 0xFFF))));
                },

                // ---- Load & Store Operations ----
                .lw => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.lw(d.rd, d.rs1, @as(i12, @truncate(d.offset)))),
                .lh => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.lh(d.rd, d.rs1, @as(i12, @truncate(d.offset)))),
                .lb => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.lb(d.rd, d.rs1, @as(i12, @truncate(d.offset)))),
                .lhu => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.lhu(d.rd, d.rs1, @as(i12, @truncate(d.offset)))),
                .lbu => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.lbu(d.rd, d.rs1, @as(i12, @truncate(d.offset)))),

                .sw => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.sw(d.rs1, d.rs2, @as(i12, @truncate(d.offset)))),
                .sh => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.sh(d.rs1, d.rs2, @as(i12, @truncate(d.offset)))),
                .sb => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.sb(d.rs1, d.rs2, @as(i12, @truncate(d.offset)))),

                // ---- Control Flow & End of Basic Block ----
                .jal => |d| {
                    const target = current_pc +% @as(u32, @bitCast(d.offset));
                    if (d.rd != 0) {
                        const link_pc = current_pc + decoded.len;
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.lui(d.rd, @as(i20, @truncate(@as(i32, @bitCast(link_pc >> 12))))));
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rd, @as(i12, @truncate(@as(i32, @bitCast(link_pc & 0xFFF))))));
                    }
                    tb.exit_branch1 = .{
                        .patch_offset = host_offset,
                        .target_guest_pc = target,
                        .is_direct = true,
                    };
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.jal(0, 0)); // Will be patched
                    stop_block = true;
                },

                .jalr => |d| {
                    if (d.rd != 0) {
                        const link_pc = current_pc + decoded.len;
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.lui(d.rd, @as(i20, @truncate(@as(i32, @bitCast(link_pc >> 12))))));
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rd, @as(i12, @truncate(@as(i32, @bitCast(link_pc & 0xFFF))))));
                    }
                    stop_block = true;
                },

                .beq, .bne, .blt, .bge, .bltu, .bgeu => {
                    stop_block = true;
                },

                .ecall, .ebreak, .mret, .sret => {
                    stop_block = true;
                },

                else => {
                    stop_block = true;
                },
            }

            current_pc += decoded.len;
        }

        tb.guest_size = current_pc - start_pc;
        tb.host_len = host_offset;
        self.cache.commitBlock(host_offset);

        return tb;
    }

    /// Single-step interpretation/dispatch step for guest virtual CPU
    pub fn step(self: *Engine) bool {
        const fetch_res = self.tlb.readU32(self.vcpu.pc, self.bus);
        if (fetch_res.trap) |cause| {
            self.vcpu.injectException(cause, self.vcpu.pc);
            return false;
        }

        const decoded = decoder_rv32.decode(fetch_res.val);
        const next_pc = self.vcpu.pc + decoded.len;

        switch (decoded.insn) {
            .add => |d| self.vcpu.setGpr(d.rd, @as(u32, @truncate(self.vcpu.getGpr(d.rs1) +% self.vcpu.getGpr(d.rs2)))),
            .sub => |d| self.vcpu.setGpr(d.rd, @as(u32, @truncate(self.vcpu.getGpr(d.rs1) -% self.vcpu.getGpr(d.rs2)))),
            .addi => |d| self.vcpu.setGpr(d.rd, @as(u64, @bitCast(@as(i64, @bitCast(self.vcpu.getGpr(d.rs1))) +% d.imm))),

            .lw => |d| {
                const vaddr = @as(u32, @truncate(@as(u64, @bitCast(@as(i64, @bitCast(self.vcpu.getGpr(d.rs1))) +% d.offset))));
                const mem_res = self.tlb.readU32(vaddr, self.bus);
                if (mem_res.trap) |cause| {
                    self.vcpu.injectException(cause, vaddr);
                    return false;
                }
                self.vcpu.setGpr(d.rd, mem_res.val);
            },
            .sw => |d| {
                const vaddr = @as(u32, @truncate(@as(u64, @bitCast(@as(i64, @bitCast(self.vcpu.getGpr(d.rs1))) +% d.offset))));
                const trap = self.tlb.writeU32(vaddr, @truncate(self.vcpu.getGpr(d.rs2)), self.bus);
                if (trap) |cause| {
                    self.vcpu.injectException(cause, vaddr);
                    return false;
                }
            },

            .jal => |d| {
                const target = self.vcpu.pc +% @as(u32, @bitCast(d.offset));
                if (d.rd != 0) self.vcpu.setGpr(d.rd, next_pc);
                self.vcpu.pc = target;
                return true;
            },
            .jalr => |d| {
                const target = (@as(u32, @truncate(@as(u64, @bitCast(@as(i64, @bitCast(self.vcpu.getGpr(d.rs1))) +% d.offset))))) & ~@as(u32, 1);
                if (d.rd != 0) self.vcpu.setGpr(d.rd, next_pc);
                self.vcpu.pc = target;
                return true;
            },
            .beq => |d| {
                if (self.vcpu.getGpr(d.rs1) == self.vcpu.getGpr(d.rs2)) {
                    self.vcpu.pc = self.vcpu.pc +% @as(u32, @bitCast(d.offset));
                    return true;
                }
            },
            .bne => |d| {
                if (self.vcpu.getGpr(d.rs1) != self.vcpu.getGpr(d.rs2)) {
                    self.vcpu.pc = self.vcpu.pc +% @as(u32, @bitCast(d.offset));
                    return true;
                }
            },

            .ecall => {
                const cause: u32 = switch (self.vcpu.privilege_mode) {
                    0 => 8, // User ecall
                    1 => 9, // Supervisor ecall
                    else => 11, // Machine ecall
                };
                self.vcpu.injectException(cause, self.vcpu.pc);
                return false;
            },

            else => {},
        }

        self.vcpu.pc = next_pc;
        return true;
    }

pub const ExitReason = enum {
    normal,
    yield,
    wfi,
    ecall,
    page_fault,
    illegal_instruction,
    unhandled,
};

    /// Run JIT/stepped execution loop for a given instruction budget
    pub fn run(self: *Engine, vcpu: *vcpu_mod.VCpu, budget: usize) ExitReason {
        _ = vcpu;
        var count: usize = 0;
        while (count < budget) : (count += 1) {
            if (!self.step()) return ExitReason.unhandled;
        }
        return ExitReason.normal;
    }
};
