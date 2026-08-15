// Dynamic Binary Translation & Execution Engine Loop
//
// Translates target non-native basic blocks into host RV64 machine instructions
// directly without IR pass overhead.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
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
    last_pc: u32 = 0,
    last_fault_pc: u32 = 0,
    last_fault_cause: u32 = 0,
    last_fault_val: u32 = 0,
    last_valid_pc: u32 = 0,
    zero_setter_pc: u32 = 0,
    last_timer_inject_count: usize = 0,
    total_insn_count: usize = 0,
    last_irq_pc: u32 = 0,

    pub fn init(buffer: []u8, vcpu: *vcpu_mod.VCpu, tlb: *softtlb_mod.SoftTlb, bus: *bus_mod.Bus) Engine {
        return Engine{
            .cache = cache_mod.Cache.init(buffer),
            .vcpu = vcpu,
            .tlb = tlb,
            .bus = bus,
        };
    }

    pub fn initOnPtr(self: *Engine, buffer: []u8, vcpu: *vcpu_mod.VCpu, tlb: *softtlb_mod.SoftTlb, bus: *bus_mod.Bus) void {
        self.* = init(buffer, vcpu, tlb, bus);
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
                self.vcpu.injectException(cause, current_pc, current_pc);
                return error.GuestFetchFault;
            }

            // Trace setup_vm

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
                    const val = @as(u32, @bitCast(@as(i32, @bitCast(current_pc)) +% (d.imm << 12)));
                    const val_offset = val +% 0x800;
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.lui(d.rd, @as(i20, @truncate(@as(i32, @bitCast(val_offset >> 12))))));
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rd, @as(i12, @truncate(@as(i32, @bitCast(val & 0xFFF))))));
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
                        const link_offset = link_pc +% 0x800;
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.lui(d.rd, @as(i20, @truncate(@as(i32, @bitCast(link_offset >> 12))))));
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
                        const link_offset = link_pc +% 0x800;
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.lui(d.rd, @as(i20, @truncate(@as(i32, @bitCast(link_offset >> 12))))));
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
        if (self.tlb.satp != self.vcpu.satp) {
            self.tlb.satp = self.vcpu.satp;
            self.tlb.flush();
        }
        self.tlb.privilege_mode = self.vcpu.privilege_mode;
        self.tlb.mstatus = self.vcpu.mstatus;

        const pc_before = self.vcpu.pc;
        const fetch_res = self.tlb.fetchU32(pc_before, self.bus);
        if (fetch_res.trap) |cause| {
            self.vcpu.injectException(cause, pc_before, pc_before);
            return true;
        }

        const decoded = decoder_rv32.decode(fetch_res.val);
        return self.executeDecoded(decoded, fetch_res.val, pc_before);
    }

    pub fn executeDecoded(self: *Engine, decoded: anytype, raw_insn: u32, pc_before: u32) bool {
        const next_pc = pc_before + decoded.len;

        switch (decoded.insn) {
            // ---- R-Type ----
            .add => |d| self.vcpu.setGpr(d.rd, @as(u32, @truncate(self.vcpu.getGpr(d.rs1) +% self.vcpu.getGpr(d.rs2)))),
            .sub => |d| self.vcpu.setGpr(d.rd, @as(u32, @truncate(self.vcpu.getGpr(d.rs1) -% self.vcpu.getGpr(d.rs2)))),
            .sll => |d| {
                const shift: u5 = @truncate(self.vcpu.getGpr(d.rs2) & 0x1F);
                self.vcpu.setGpr(d.rd, @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) << shift);
            },
            .slt => |d| {
                const s1 = @as(i32, @bitCast(@as(u32, @truncate(self.vcpu.getGpr(d.rs1)))));
                const s2 = @as(i32, @bitCast(@as(u32, @truncate(self.vcpu.getGpr(d.rs2)))));
                self.vcpu.setGpr(d.rd, if (s1 < s2) 1 else 0);
            },
            .sltu => |d| {
                const val1 = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const val2 = @as(u32, @truncate(self.vcpu.getGpr(d.rs2)));
                self.vcpu.setGpr(d.rd, if (val1 < val2) 1 else 0);
            },
            .xor_ => |d| self.vcpu.setGpr(d.rd, @as(u32, @truncate(self.vcpu.getGpr(d.rs1) ^ self.vcpu.getGpr(d.rs2)))),
            .srl => |d| {
                const shift: u5 = @truncate(self.vcpu.getGpr(d.rs2) & 0x1F);
                self.vcpu.setGpr(d.rd, @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) >> shift);
            },
            .sra => |d| {
                const shift: u5 = @truncate(self.vcpu.getGpr(d.rs2) & 0x1F);
                const val = @as(i32, @bitCast(@as(u32, @truncate(self.vcpu.getGpr(d.rs1)))));
                self.vcpu.setGpr(d.rd, @as(u32, @bitCast(val >> shift)));
            },
            .or_ => |d| self.vcpu.setGpr(d.rd, @as(u32, @truncate(self.vcpu.getGpr(d.rs1) | self.vcpu.getGpr(d.rs2)))),
            .and_ => |d| self.vcpu.setGpr(d.rd, @as(u32, @truncate(self.vcpu.getGpr(d.rs1) & self.vcpu.getGpr(d.rs2)))),

            // ---- Multiply / Divide ----
            .mul => |d| {
                const p = @as(u64, @truncate(self.vcpu.getGpr(d.rs1))) *% @as(u64, @truncate(self.vcpu.getGpr(d.rs2)));
                self.vcpu.setGpr(d.rd, @as(u32, @truncate(p)));
            },
            .mulh => |d| {
                const s1 = @as(i64, @as(i32, @bitCast(@as(u32, @truncate(self.vcpu.getGpr(d.rs1))))));
                const s2 = @as(i64, @as(i32, @bitCast(@as(u32, @truncate(self.vcpu.getGpr(d.rs2))))));
                const p = @as(u64, @bitCast(s1 *% s2));
                self.vcpu.setGpr(d.rd, @as(u32, @truncate(p >> 32)));
            },
            .mulhsu => |d| {
                const s1 = @as(i64, @as(i32, @bitCast(@as(u32, @truncate(self.vcpu.getGpr(d.rs1))))));
                const val2 = @as(u64, @truncate(self.vcpu.getGpr(d.rs2)));
                const p = @as(u64, @bitCast(s1 *% @as(i64, @bitCast(val2))));
                self.vcpu.setGpr(d.rd, @as(u32, @truncate(p >> 32)));
            },
            .mulhu => |d| {
                const val1 = @as(u64, @truncate(self.vcpu.getGpr(d.rs1)));
                const val2 = @as(u64, @truncate(self.vcpu.getGpr(d.rs2)));
                const p = val1 *% val2;
                self.vcpu.setGpr(d.rd, @as(u32, @truncate(p >> 32)));
            },
            .div => |d| {
                const num = @as(i32, @bitCast(@as(u32, @truncate(self.vcpu.getGpr(d.rs1)))));
                const den = @as(i32, @bitCast(@as(u32, @truncate(self.vcpu.getGpr(d.rs2)))));
                if (den == 0) {
                    self.vcpu.setGpr(d.rd, 0xFFFFFFFF);
                } else if (num == std.math.minInt(i32) and den == -1) {
                    self.vcpu.setGpr(d.rd, 0x80000000);
                } else {
                    self.vcpu.setGpr(d.rd, @as(u32, @bitCast(@divTrunc(num, den))));
                }
            },
            .divu => |d| {
                const num = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const den = @as(u32, @truncate(self.vcpu.getGpr(d.rs2)));
                if (den == 0) {
                    self.vcpu.setGpr(d.rd, 0xFFFFFFFF);
                } else {
                    self.vcpu.setGpr(d.rd, num / den);
                }
            },
            .rem => |d| {
                const num = @as(i32, @bitCast(@as(u32, @truncate(self.vcpu.getGpr(d.rs1)))));
                const den = @as(i32, @bitCast(@as(u32, @truncate(self.vcpu.getGpr(d.rs2)))));
                if (den == 0) {
                    self.vcpu.setGpr(d.rd, @as(u32, @bitCast(num)));
                } else if (num == std.math.minInt(i32) and den == -1) {
                    self.vcpu.setGpr(d.rd, 0);
                } else {
                    self.vcpu.setGpr(d.rd, @as(u32, @bitCast(@rem(num, den))));
                }
            },
            .remu => |d| {
                const num = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const den = @as(u32, @truncate(self.vcpu.getGpr(d.rs2)));
                if (den == 0) {
                    self.vcpu.setGpr(d.rd, num);
                } else {
                    self.vcpu.setGpr(d.rd, num % den);
                }
            },

            // ---- I-Type ----
            .addi => |d| self.vcpu.setGpr(d.rd, @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) +% @as(u32, @bitCast(d.imm))),
            .slti => |d| {
                const s1 = @as(i32, @bitCast(@as(u32, @truncate(self.vcpu.getGpr(d.rs1)))));
                self.vcpu.setGpr(d.rd, if (s1 < d.imm) 1 else 0);
            },
            .sltiu => |d| {
                const val1 = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const uimm = @as(u32, @bitCast(d.imm));
                self.vcpu.setGpr(d.rd, if (val1 < uimm) 1 else 0);
            },
            .xori => |d| {
                const uimm = @as(u32, @bitCast(d.imm));
                self.vcpu.setGpr(d.rd, @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) ^ uimm);
            },
            .ori => |d| {
                const uimm = @as(u32, @bitCast(d.imm));
                self.vcpu.setGpr(d.rd, @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) | uimm);
            },
            .andi => |d| {
                const uimm = @as(u32, @bitCast(d.imm));
                self.vcpu.setGpr(d.rd, @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) & uimm);
            },
            .slli => |d| self.vcpu.setGpr(d.rd, @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) << d.shamt),
            .srli => |d| self.vcpu.setGpr(d.rd, @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) >> d.shamt),
            .srai => |d| {
                const val = @as(i32, @bitCast(@as(u32, @truncate(self.vcpu.getGpr(d.rs1)))));
                self.vcpu.setGpr(d.rd, @as(u32, @bitCast(val >> d.shamt)));
            },

            // ---- Upper Immediates ----
            .lui => |d| self.vcpu.setGpr(d.rd, @as(u32, @bitCast(d.imm << 12))),
            .auipc => |d| self.vcpu.setGpr(d.rd, self.vcpu.pc +% @as(u32, @bitCast(d.imm << 12))),

            // ---- Loads ----
            .lb => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) +% @as(u32, @bitCast(d.offset));
                const res = self.tlb.readU8(vaddr, self.bus);
                if (res.trap) |cause| {
                    self.vcpu.injectException(cause, self.vcpu.pc, vaddr);
                    return true;
                }
                const sval = @as(i8, @bitCast(@as(u8, @truncate(res.val))));
                self.vcpu.setGpr(d.rd, @as(u32, @bitCast(@as(i32, sval))));
            },
            .lbu => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) +% @as(u32, @bitCast(d.offset));
                const res = self.tlb.readU8(vaddr, self.bus);
                if (res.trap) |cause| {
                    self.vcpu.injectException(cause, self.vcpu.pc, vaddr);
                    return true;
                }
                self.vcpu.setGpr(d.rd, res.val);
            },
            .lh => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) +% @as(u32, @bitCast(d.offset));
                const res = self.tlb.readU16(vaddr, self.bus);
                if (res.trap) |cause| {
                    self.vcpu.injectException(cause, self.vcpu.pc, vaddr);
                    return true;
                }
                const sval = @as(i16, @bitCast(@as(u16, @truncate(res.val))));
                self.vcpu.setGpr(d.rd, @as(u32, @bitCast(@as(i32, sval))));
            },
            .lhu => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) +% @as(u32, @bitCast(d.offset));
                const res = self.tlb.readU16(vaddr, self.bus);
                if (res.trap) |cause| {
                    self.vcpu.injectException(cause, self.vcpu.pc, vaddr);
                    return true;
                }
                self.vcpu.setGpr(d.rd, res.val);
            },
            .lw => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) +% @as(u32, @bitCast(d.offset));
                const res = self.tlb.readU32(vaddr, self.bus);
                if (res.trap) |cause| {
                    self.vcpu.injectException(cause, self.vcpu.pc, vaddr);
                    return true;
                }
                self.vcpu.setGpr(d.rd, res.val);
            },

            // ---- Stores ----
            .sb => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) +% @as(u32, @bitCast(d.offset));
                const trap = self.tlb.writeU8(vaddr, @truncate(self.vcpu.getGpr(d.rs2)), self.bus);
                if (trap) |cause| {
                    self.vcpu.injectException(cause, self.vcpu.pc, vaddr);
                    return true;
                }
            },
            .sh => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) +% @as(u32, @bitCast(d.offset));
                const trap = self.tlb.writeU16(vaddr, @truncate(self.vcpu.getGpr(d.rs2)), self.bus);
                if (trap) |cause| {
                    self.vcpu.injectException(cause, self.vcpu.pc, vaddr);
                    return true;
                }
            },
            .sw => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) +% @as(u32, @bitCast(d.offset));
                const trap = self.tlb.writeU32(vaddr, @truncate(self.vcpu.getGpr(d.rs2)), self.bus);
                if (trap) |cause| {
                    self.vcpu.injectException(cause, self.vcpu.pc, vaddr);
                    return true;
                }
            },

            // ---- Control Flow ----
            .jal => |d| {
                const target = self.vcpu.pc +% @as(u32, @bitCast(d.offset));
                if (d.rd != 0) self.vcpu.setGpr(d.rd, next_pc);
                self.vcpu.pc = target;
                return true;
            },
            .jalr => |d| {
                const target = (@as(u32, @truncate(self.vcpu.getGpr(d.rs1))) +% @as(u32, @bitCast(d.offset))) & ~@as(u32, 1);
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
            .blt => |d| {
                const s1 = @as(i32, @bitCast(@as(u32, @truncate(self.vcpu.getGpr(d.rs1)))));
                const s2 = @as(i32, @bitCast(@as(u32, @truncate(self.vcpu.getGpr(d.rs2)))));
                if (s1 < s2) {
                    self.vcpu.pc = self.vcpu.pc +% @as(u32, @bitCast(d.offset));
                    return true;
                }
            },
            .bge => |d| {
                const s1 = @as(i32, @bitCast(@as(u32, @truncate(self.vcpu.getGpr(d.rs1)))));
                const s2 = @as(i32, @bitCast(@as(u32, @truncate(self.vcpu.getGpr(d.rs2)))));
                if (s1 >= s2) {
                    self.vcpu.pc = self.vcpu.pc +% @as(u32, @bitCast(d.offset));
                    return true;
                }
            },
            .bltu => |d| {
                const val1 = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const val2 = @as(u32, @truncate(self.vcpu.getGpr(d.rs2)));
                if (val1 < val2) {
                    self.vcpu.pc = self.vcpu.pc +% @as(u32, @bitCast(d.offset));
                    return true;
                }
            },
            .bgeu => |d| {
                const val1 = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const val2 = @as(u32, @truncate(self.vcpu.getGpr(d.rs2)));
                if (val1 >= val2) {
                    self.vcpu.pc = self.vcpu.pc +% @as(u32, @bitCast(d.offset));
                    return true;
                }
            },

            // ---- CSR Instructions ----
            .csrrw => |d| {
                const old = self.vcpu.readCsr(d.csr);
                self.vcpu.writeCsr(d.csr, @truncate(self.vcpu.getGpr(d.rs1)));
                if (d.rd != 0) self.vcpu.setGpr(d.rd, old);
                if (d.csr == 0x180) {
                    self.tlb.satp = self.vcpu.satp;
                    self.tlb.flush();
                }
            },
            .csrrs => |d| {
                const old = self.vcpu.readCsr(d.csr);
                if (d.rs1 != 0) {
                    const new_val = old | @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                    self.vcpu.writeCsr(d.csr, new_val);
                    if (d.csr == 0x180) {
                        self.tlb.satp = self.vcpu.satp;
                        self.tlb.flush();
                    }
                }
                if (d.rd != 0) self.vcpu.setGpr(d.rd, old);
            },
            .csrrc => |d| {
                const old = self.vcpu.readCsr(d.csr);
                if (d.rs1 != 0) {
                    const new_val = old & ~@as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                    self.vcpu.writeCsr(d.csr, new_val);
                    if (d.csr == 0x180) {
                        self.tlb.satp = self.vcpu.satp;
                        self.tlb.flush();
                    }
                }
                if (d.rd != 0) self.vcpu.setGpr(d.rd, old);
            },
            .csrrwi => |d| {
                const old = self.vcpu.readCsr(d.csr);
                self.vcpu.writeCsr(d.csr, d.uimm);
                if (d.rd != 0) self.vcpu.setGpr(d.rd, old);
                if (d.csr == 0x180) {
                    self.tlb.satp = self.vcpu.satp;
                    self.tlb.flush();
                }
            },
            .csrrsi => |d| {
                const old = self.vcpu.readCsr(d.csr);
                if (d.uimm != 0) {
                    const new_val = old | d.uimm;
                    self.vcpu.writeCsr(d.csr, new_val);
                    if (d.csr == 0x180) {
                        self.tlb.satp = self.vcpu.satp;
                        self.tlb.flush();
                    }
                }
                if (d.rd != 0) self.vcpu.setGpr(d.rd, old);
            },
            .csrrci => |d| {
                const old = self.vcpu.readCsr(d.csr);
                if (d.uimm != 0) {
                    const new_val = old & ~@as(u32, d.uimm);
                    self.vcpu.writeCsr(d.csr, new_val);
                    if (d.csr == 0x180) {
                        self.tlb.satp = self.vcpu.satp;
                        self.tlb.flush();
                    }
                }
                if (d.rd != 0) self.vcpu.setGpr(d.rd, old);
            },

            // ---- Vector Instructions ----
            .vsetvli => |d| {
                const vs_enabled = ((self.vcpu.mstatus >> 9) & 3) != 0;
                if (!vs_enabled) {
                    self.vcpu.injectException(2, self.vcpu.pc, 0);
                    return true;
                }
                const req = if (d.rs1 != 0) @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) else 32;
                self.vcpu.vl = @min(req, 32);
                if (d.rd != 0) self.vcpu.setGpr(d.rd, self.vcpu.vl);
                self.vcpu.pc = next_pc;
                return true;
            },
            .vload => |d| {
                const vs_enabled = ((self.vcpu.mstatus >> 9) & 3) != 0;
                if (!vs_enabled) {
                    self.vcpu.injectException(2, self.vcpu.pc, 0);
                    return true;
                }
                const base_vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const count = if (self.vcpu.vl == 0) 32 else self.vcpu.vl;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const res = self.tlb.readU8(base_vaddr + i, self.bus);
                    if (res.trap) |cause| {
                        self.vcpu.injectException(cause, self.vcpu.pc, base_vaddr + i);
                        return true;
                    }
                    self.vcpu.vregs[d.vd][i] = @truncate(res.val);
                }
                self.vcpu.pc = next_pc;
                return true;
            },
            .vstore => |d| {
                const vs_enabled = ((self.vcpu.mstatus >> 9) & 3) != 0;
                if (!vs_enabled) {
                    self.vcpu.injectException(2, self.vcpu.pc, 0);
                    return true;
                }
                const base_vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const count = if (self.vcpu.vl == 0) 32 else self.vcpu.vl;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const byte = self.vcpu.vregs[d.vs3][i];
                    const trap = self.tlb.writeU8(base_vaddr + i, byte, self.bus);
                    if (trap) |cause| {
                        self.vcpu.injectException(cause, self.vcpu.pc, base_vaddr + i);
                        return true;
                    }
                }
                self.vcpu.pc = next_pc;
                return true;
            },
            .vector_op => |d| {
                const vs_enabled = ((self.vcpu.mstatus >> 9) & 3) != 0;
                if (!vs_enabled) {
                    self.vcpu.injectException(2, self.vcpu.pc, 0);
                    return true;
                }
                @memcpy(self.vcpu.vregs[d.rd][0..], self.vcpu.vregs[d.rs1][0..]);
                self.vcpu.pc = next_pc;
                return true;
            },

            // ---- Atomic Instructions ----
            .lr_w => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const res = self.tlb.lrU32(vaddr, self.bus);
                if (res.trap) |cause| {
                    self.vcpu.injectException(cause, self.vcpu.pc, vaddr);
                    return true;
                }
                self.vcpu.load_res_addr = res.paddr;
                self.vcpu.load_res_val = res.val;
                if (d.rd != 0) self.vcpu.setGpr(d.rd, res.val);
                self.vcpu.pc = next_pc;
            },
            .sc_w => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const val = @as(u32, @truncate(self.vcpu.getGpr(d.rs2)));
                const res = self.tlb.scU32(vaddr, val, self.vcpu.load_res_addr, self.vcpu.load_res_val, self.bus);
                self.vcpu.load_res_addr = 0; // Invalidate reservation on SC
                if (res.trap) |cause| {
                    self.vcpu.injectException(cause, self.vcpu.pc, vaddr);
                    return true;
                }
                if (d.rd != 0) self.vcpu.setGpr(d.rd, if (res.success) 0 else 1);
                self.vcpu.pc = next_pc;
            },
            .amoswap_w => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const val = @as(u32, @truncate(self.vcpu.getGpr(d.rs2)));
                const res = self.tlb.amoU32(vaddr, val, .swap, self.bus);
                if (res.trap) |cause| {
                    self.vcpu.injectException(cause, self.vcpu.pc, vaddr);
                    return true;
                }
                if (d.rd != 0) self.vcpu.setGpr(d.rd, res.val);
                self.vcpu.pc = next_pc;
            },
            .amoadd_w => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const val = @as(u32, @truncate(self.vcpu.getGpr(d.rs2)));
                const res = self.tlb.amoU32(vaddr, val, .add, self.bus);
                if (res.trap) |cause| {
                    self.vcpu.injectException(cause, self.vcpu.pc, vaddr);
                    return true;
                }
                if (d.rd != 0) self.vcpu.setGpr(d.rd, res.val);
                self.vcpu.pc = next_pc;
            },
            .amoxor_w => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const val = @as(u32, @truncate(self.vcpu.getGpr(d.rs2)));
                const res = self.tlb.amoU32(vaddr, val, .xor, self.bus);
                if (res.trap) |cause| {
                    self.vcpu.injectException(cause, self.vcpu.pc, vaddr);
                    return true;
                }
                if (d.rd != 0) self.vcpu.setGpr(d.rd, res.val);
                self.vcpu.pc = next_pc;
            },
            .amoand_w => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const val = @as(u32, @truncate(self.vcpu.getGpr(d.rs2)));
                const res = self.tlb.amoU32(vaddr, val, .and_op, self.bus);
                if (res.trap) |cause| {
                    self.vcpu.injectException(cause, self.vcpu.pc, vaddr);
                    return true;
                }
                if (d.rd != 0) self.vcpu.setGpr(d.rd, res.val);
                self.vcpu.pc = next_pc;
            },
            .amoor_w => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const val = @as(u32, @truncate(self.vcpu.getGpr(d.rs2)));
                const res = self.tlb.amoU32(vaddr, val, .or_op, self.bus);
                if (res.trap) |cause| {
                    self.vcpu.injectException(cause, self.vcpu.pc, vaddr);
                    return true;
                }
                if (d.rd != 0) self.vcpu.setGpr(d.rd, res.val);
                self.vcpu.pc = next_pc;
            },
            .amomin_w => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const val = @as(u32, @truncate(self.vcpu.getGpr(d.rs2)));
                const res = self.tlb.amoU32(vaddr, val, .min, self.bus);
                if (res.trap) |cause| {
                    self.vcpu.injectException(cause, self.vcpu.pc, vaddr);
                    return true;
                }
                if (d.rd != 0) self.vcpu.setGpr(d.rd, res.val);
                self.vcpu.pc = next_pc;
            },
            .amomax_w => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const val = @as(u32, @truncate(self.vcpu.getGpr(d.rs2)));
                const res = self.tlb.amoU32(vaddr, val, .max, self.bus);
                if (res.trap) |cause| {
                    self.vcpu.injectException(cause, self.vcpu.pc, vaddr);
                    return true;
                }
                if (d.rd != 0) self.vcpu.setGpr(d.rd, res.val);
                self.vcpu.pc = next_pc;
            },
            .amominu_w => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const val = @as(u32, @truncate(self.vcpu.getGpr(d.rs2)));
                const res = self.tlb.amoU32(vaddr, val, .minu, self.bus);
                if (res.trap) |cause| {
                    self.vcpu.injectException(cause, self.vcpu.pc, vaddr);
                    return true;
                }
                if (d.rd != 0) self.vcpu.setGpr(d.rd, res.val);
                self.vcpu.pc = next_pc;
            },
            .amomaxu_w => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const val = @as(u32, @truncate(self.vcpu.getGpr(d.rs2)));
                const res = self.tlb.amoU32(vaddr, val, .maxu, self.bus);
                if (res.trap) |cause| {
                    self.vcpu.injectException(cause, self.vcpu.pc, vaddr);
                    return true;
                }
                if (d.rd != 0) self.vcpu.setGpr(d.rd, res.val);
                self.vcpu.pc = next_pc;
            },

            // ---- Traps & Returns ----
            .sret => {
                const spp = (self.vcpu.mstatus >> 8) & 1;
                const spie = (self.vcpu.mstatus >> 5) & 1;
                var mstatus = self.vcpu.mstatus;
                mstatus = (mstatus & ~@as(u32, 0x02)) | (spie << 1);
                mstatus |= (1 << 5);
                mstatus &= ~@as(u32, 1 << 8);
                self.vcpu.mstatus = mstatus;

                const new_priv: u2 = @truncate(spp);
                if (self.vcpu.privilege_mode != new_priv or self.tlb.satp != self.vcpu.satp) {
                    self.tlb.privilege_mode = new_priv;
                    self.tlb.satp = self.vcpu.satp;
                    self.tlb.flush();
                }
                self.vcpu.privilege_mode = new_priv;
                self.vcpu.priv_mode = new_priv;

                self.vcpu.scause = 0;
                self.vcpu.stval = 0;
                self.vcpu.pc = self.vcpu.sepc;
                return true;
            },
            .mret => {
                const mpp = (self.vcpu.mstatus >> 11) & 3;
                const mpie = (self.vcpu.mstatus >> 7) & 1;
                var mstatus = self.vcpu.mstatus;
                mstatus = (mstatus & ~@as(u32, 0x08)) | (mpie << 3);
                mstatus |= (1 << 7);
                mstatus &= ~@as(u32, 3 << 11);
                self.vcpu.mstatus = mstatus;

                const new_priv: u2 = @truncate(mpp);
                if (self.vcpu.privilege_mode != new_priv or self.tlb.satp != self.vcpu.satp) {
                    self.tlb.privilege_mode = new_priv;
                    self.tlb.satp = self.vcpu.satp;
                    self.tlb.flush();
                }
                self.vcpu.privilege_mode = new_priv;
                self.vcpu.priv_mode = new_priv;

                self.vcpu.pc = self.vcpu.mepc;
                return true;
            },
            .ecall => {
                const pc_trap = self.vcpu.pc;
                const cause: u32 = switch (self.vcpu.privilege_mode) {
                    0 => 8, // User ecall
                    1 => 9, // Supervisor ecall
                    else => 11, // Machine ecall
                };
                self.vcpu.injectException(cause, pc_trap, 0);
                return true;
            },
            .ebreak => {
                const pc_trap = self.vcpu.pc;
                self.vcpu.injectException(3, pc_trap, 0);
                return true;
            },
            .wfi => {
                self.vcpu.pc = next_pc;
                return false;
            },
            .sfence_vma => {
                if (comptime builtin.target.cpu.arch.isRISCV()) {
                    asm volatile ("sfence.vma");
                }
                self.tlb.flush();
                self.cache.flush();
                self.vcpu.pc = next_pc;
            },
            .fence => {
                if (comptime builtin.target.cpu.arch.isRISCV()) {
                    asm volatile ("fence rw, rw");
                }
                self.vcpu.pc = next_pc;
            },
            .fence_i => {
                if (comptime builtin.target.cpu.arch.isRISCV()) {
                    asm volatile ("fence.i");
                }
                self.tlb.flush();
                self.cache.flush();
                self.vcpu.pc = next_pc;
            },

            // Unknown instruction -> Illegal Instruction Trap
            else => {
                const pc_trap = pc_before;
                self.last_fault_pc = pc_trap;
                self.last_fault_cause = 2;
                self.last_fault_val = raw_insn;
                self.vcpu.injectException(2, pc_trap, raw_insn); // Illegal Instruction
                return true;
            },
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
        while (count < budget) : ({
            count += 1;
            self.total_insn_count +%= 1;
        }) {
            if (self.tlb.satp != self.vcpu.satp) {
                self.tlb.satp = self.vcpu.satp;
                self.tlb.flush();
            }
            self.tlb.privilege_mode = self.vcpu.privilege_mode;
            self.tlb.mstatus = self.vcpu.mstatus;
            const pc_before = self.vcpu.pc;
            if (pc_before != 0) {
                self.last_valid_pc = pc_before;
            } else if (self.zero_setter_pc == 0) {
                self.zero_setter_pc = self.last_pc;
            }
            self.last_pc = pc_before;

            // Check virtual timer interrupt (throttle timer checks to once per 64 instructions and require minimum 50,000 instructions between ticks)
            if ((count & 63) == 0 and (self.total_insn_count -% self.last_timer_inject_count >= 50_000)) {
                const now = vcpu_mod.VCpu.readGuestTime();
                const vtimecmp = self.vcpu.vstimecmp;
                const mtimecmp = if (self.vcpu.id < 4) self.bus.timer.mtimecmp[self.vcpu.id] else ~@as(u64, 0);
                const timer_target = @min(vtimecmp, mtimecmp);
                if (timer_target != ~@as(u64, 0)) {
                    if (now >= timer_target) {
                        self.vcpu.mip |= (1 << 5); // STIP
                    } else {
                        self.vcpu.mip &= ~@as(u32, 1 << 5);
                    }
                }
            }

            // Check if supervisor interrupts can be delivered (only when stvec is set and an interrupt is pending)
            const sie = (self.vcpu.mstatus >> 1) & 1;
            if (self.vcpu.stvec != 0 and (self.vcpu.privilege_mode == 0 or (self.vcpu.privilege_mode == 1 and sie != 0))) {
                const pending = (self.vcpu.mip & self.vcpu.sie & self.vcpu.mideleg);
                if (pending != 0) {
                    const stvec_base = self.vcpu.stvec & ~@as(u32, 3);
                    const stvec_check = self.tlb.fetchU32(stvec_base, self.bus);
                    if (stvec_check.trap == null and stvec_check.val != 0) {
                        if ((pending & (1 << 1)) != 0) {
                            self.vcpu.mip &= ~@as(u32, 1 << 1);
                            self.vcpu.injectException(0x80000001, pc_before, 0);
                            continue;
                        } else if ((pending & (1 << 5)) != 0) {
                            self.vcpu.mip &= ~@as(u32, 1 << 5);
                            self.last_timer_inject_count = self.total_insn_count;
                            self.last_irq_pc = pc_before;
                            self.vcpu.injectException(0x80000005, pc_before, 0);
                            continue;
                        } else if ((pending & (1 << 9)) != 0) {
                            self.vcpu.mip &= ~@as(u32, 1 << 9);
                            self.vcpu.injectException(0x80000009, pc_before, 0);
                            continue;
                        }
                    }
                }
            }
            const fetch_res = self.tlb.fetchU32(pc_before, self.bus);
            if (pc_before != 0) {
                self.last_fault_val = fetch_res.val;
            }
            if (fetch_res.trap) |cause| {
                self.last_fault_pc = pc_before;
                self.last_fault_cause = cause;
                self.last_fault_val = fetch_res.val;
                self.vcpu.injectException(cause, pc_before, pc_before);
                self.tlb.privilege_mode = self.vcpu.privilege_mode;
                continue;
            }

            const decoded = decoder_rv32.decode(fetch_res.val);
            if (decoded.insn == .ecall) {
                if (self.vcpu.privilege_mode == 1) {
                    self.vcpu.pc = pc_before + decoded.len;
                    return ExitReason.ecall;
                } else {
                    self.vcpu.injectException(8, pc_before, 0);
                    self.tlb.privilege_mode = self.vcpu.privilege_mode;
                    continue;
                }
            }
            if (decoded.insn == .wfi) {
                self.vcpu.pc = pc_before + decoded.len;
                return ExitReason.wfi;
            }

            if (!self.executeDecoded(decoded, fetch_res.val, pc_before)) return ExitReason.unhandled;
        }
        return ExitReason.normal;
    }
};
