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

pub fn runBlock(regs: *[32]u64, host_code_ptr: usize) usize {
    if (comptime builtin.target.cpu.arch.isRISCV()) {
        const ext = struct {
            extern fn hw_dynarec_run_block(r: *[32]u64, ptr: usize) callconv(.c) usize;
        };
        return ext.hw_dynarec_run_block(regs, host_code_ptr);
    } else {
        return 0;
    }
}

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
    pc_history: [8]u32 = std.mem.zeroes([8]u32),
    history_idx: usize = 0,
    jit_cycles: u64 = 0,
    engine_cycles: u64 = 0,

    pub fn initOnPtr(self: *Engine, buffer: []u8, vcpu: *vcpu_mod.VCpu, tlb: *softtlb_mod.SoftTlb, bus: *bus_mod.Bus) void {
        self.vcpu = vcpu;
        self.tlb = tlb;
        self.bus = bus;
        self.last_pc = 0;
        self.last_fault_pc = 0;
        self.last_fault_cause = 0;
        self.last_fault_val = 0;
        self.last_valid_pc = 0;
        self.zero_setter_pc = 0;
        self.last_timer_inject_count = 0;
        self.total_insn_count = 0;
        self.last_irq_pc = 0;
        self.pc_history = std.mem.zeroes([8]u32);
        self.history_idx = 0;
        self.jit_cycles = 0;
        self.engine_cycles = 0;
        self.cache.initOnPtr(buffer);
    }

    pub fn trap(self: *Engine, cause: u32, fault_pc: u32, stval: u32) void {
        self.vcpu.injectException(cause, fault_pc, stval);
        self.tlb.privilege_mode = self.vcpu.privilege_mode;
        self.tlb.mstatus = self.vcpu.mstatus;
        if (self.bus.uart.out_fn) |f| {
            const hex = "0123456789ABCDEF";
            f('\n');
            f('['); f('T'); f('R'); f('A'); f('P'); f(']');
            f(' '); f('c'); f('a'); f('u'); f('s'); f('e'); f('=');
            var s: u5 = 28;
            while (true) {
                f(hex[(cause >> s) & 0xF]);
                if (s == 0) break;
                s -= 4;
            }
            f(' '); f('p'); f('c'); f('=');
            s = 28;
            while (true) {
                f(hex[(fault_pc >> s) & 0xF]);
                if (s == 0) break;
                s -= 4;
            }
            f(' '); f('v'); f('a'); f('l'); f('=');
            s = 28;
            while (true) {
                f(hex[(stval >> s) & 0xF]);
                if (s == 0) break;
                s -= 4;
            }
            f(' '); f('h'); f('i'); f('s'); f('t'); f(':');
            var hi: usize = 0;
            while (hi < 8) : (hi += 1) {
                const idx = (self.history_idx + hi) & 7;
                const hpc = self.pc_history[idx];
                f(' ');
                s = 28;
                while (true) {
                    f(hex[(hpc >> s) & 0xF]);
                    if (s == 0) break;
                    s -= 4;
                }
            }
            f(' '); f('r'); f('a'); f('=');
            const ra_val = @as(u32, @truncate(self.vcpu.getGpr(1)));
            s = 28;
            while (true) {
                f(hex[(ra_val >> s) & 0xF]);
                if (s == 0) break;
                s -= 4;
            }
            f(' '); f('s'); f('t'); f('v'); f('e'); f('c'); f('=');
            s = 28;
            while (true) {
                f(hex[(self.vcpu.stvec >> s) & 0xF]);
                if (s == 0) break;
                s -= 4;
            }
            f(' '); f('s'); f('5'); f('=');
            const s5_val = @as(u32, @truncate(self.vcpu.getGpr(21)));
            s = 28;
            while (true) { f(hex[(s5_val >> s) & 0xF]); if (s == 0) break; s -= 4; }
            f(' '); f('a'); f('5'); f('=');
            const a5_val = @as(u32, @truncate(self.vcpu.getGpr(15)));
            s = 28;
            while (true) { f(hex[(a5_val >> s) & 0xF]); if (s == 0) break; s -= 4; }
            f(' '); f('s'); f('p'); f('=');
            const sp_val = @as(u32, @truncate(self.vcpu.getGpr(2)));
            s = 28;
            while (true) {
                f(hex[(sp_val >> s) & 0xF]);
                if (s == 0) break;
                s -= 4;
            }
            f(' '); f('s'); f('t'); f('a'); f('c'); f('k'); f(':');
            var off: u32 = 0;
            while (off < 128) : (off += 4) {
                const w_res = self.tlb.readU32(sp_val +% off, self.bus);
                if (w_res.trap == null) {
                    f(' ');
                    s = 28;
                    while (true) {
                        f(hex[(w_res.val >> s) & 0xF]);
                        if (s == 0) break;
                        s -= 4;
                    }
                }
            }
            f('\n');
        }
        self.vcpu.injectException(cause, fault_pc, stval);
    }

    fn emitExit(tb: *block_mod.TranslationBlock, host_offset: *usize, target_pc: u32) block_mod.ExitBranch {
        const pc_i32 = @as(i32, @bitCast(target_pc));
        const upper = @as(i20, @truncate((pc_i32 +% 0x800) >> 12));
        const lower = @as(i12, @bitCast(@as(u12, @truncate(target_pc & 0xFFF))));

        // csrw sscratch, t0 (x5) - preserves original guest t0
        emitter_rv64.emit(tb.host_code, host_offset, 0x14029073);
        // lui t0, upper
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.lui(5, upper));
        // addiw t0, t0, lower
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 5, lower));
        // csrw sepc, t0 (0x141) - saves target_pc into sepc
        emitter_rv64.emit(tb.host_code, host_offset, 0x14129073);

        // Now t0 is free! Jump directly to hw_dynarec_exit using auipc + jalr (±2GB reach)
        const exit_addr = cache_mod.getExitAddr();
        const patch_off = host_offset.*;
        const src = @intFromPtr(tb.host_code.ptr) + patch_off;
        const rel = @as(isize, @bitCast(exit_addr)) - @as(isize, @bitCast(src));
        const j_upper = @as(i20, @truncate((rel + 0x800) >> 12));
        const j_lower = @as(i12, @bitCast(@as(u12, @truncate(@as(usize, @bitCast(rel)) & 0xFFF))));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.auipc(5, j_upper));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.jalr(0, 5, j_lower));

        return block_mod.ExitBranch{
            .patch_offset = patch_off,
            .target_guest_pc = target_pc,
            .is_direct = true,
        };
    }

    fn emitDirectLoad(tb: *block_mod.TranslationBlock, host_offset: *usize, op: u3, rd: u5, rs1: u5, imm: i12) void {
        if (rd == 0) return;

        if (rd != 5 and rs1 != 5) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x14029073); // csrw sscratch, t0
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(rd, rs1, imm));
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(rd, rd, 32));
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(rd, rd, 32));
            
            // Host Physical Address = (vaddr & 0x1FFFFFFF) + 0x00000000E0000000
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(rd, rd, 35));
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(rd, rd, 35));
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.lui(5, @as(i20, @bitCast(@as(u20, 0xE0000)))));
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(5, 5, 32));
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(5, 5, 32));
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.add(rd, rd, 5));

            const load_insn: u32 = switch (op) {
                0 => emitter_rv64.lb(rd, rd, 0),
                1 => emitter_rv64.lh(rd, rd, 0),
                2 => emitter_rv64.lw(rd, rd, 0),
                4 => emitter_rv64.lbu(rd, rd, 0),
                5 => emitter_rv64.lhu(rd, rd, 0),
                else => emitter_rv64.lw(rd, rd, 0),
            };
            emitter_rv64.emit(tb.host_code, host_offset, load_insn);
            emitter_rv64.emit(tb.host_code, host_offset, 0x140022f3); // csrr t0, sscratch
        } else {
            emitter_rv64.emit(tb.host_code, host_offset, 0x14029073); // csrw sscratch, t0
            emitter_rv64.emit(tb.host_code, host_offset, 0x14231073); // csrw scause, t1 (0x142)

            if (rs1 == 5) {
                emitter_rv64.emit(tb.host_code, host_offset, 0x140022f3); // csrr t0, sscratch
                emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 5, imm));
            } else if (rs1 == 6) {
                emitter_rv64.emit(tb.host_code, host_offset, 0x14202373); // csrr t1, scause
                emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 6, imm));
            } else {
                emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, rs1, imm));
            }

            // Host Physical Address = (vaddr & 0x1FFFFFFF) + 0x00000000E0000000
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(5, 5, 35));
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(5, 5, 35));
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.lui(6, @as(i20, @bitCast(@as(u20, 0xE0000)))));
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(6, 6, 32));
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(6, 6, 32));
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.add(5, 5, 6));

            const target_reg: u5 = if (rd == 5 or rd == 6) 6 else rd;
            const load_insn: u32 = switch (op) {
                0 => emitter_rv64.lb(target_reg, 5, 0),
                1 => emitter_rv64.lh(target_reg, 5, 0),
                2 => emitter_rv64.lw(target_reg, 5, 0),
                4 => emitter_rv64.lbu(target_reg, 5, 0),
                5 => emitter_rv64.lhu(target_reg, 5, 0),
                else => emitter_rv64.lw(target_reg, 5, 0),
            };
            emitter_rv64.emit(tb.host_code, host_offset, load_insn);

            if (rd == 5) {
                emitter_rv64.emit(tb.host_code, host_offset, 0x14031073); // csrw sscratch, t1
                emitter_rv64.emit(tb.host_code, host_offset, 0x14202373); // csrr t1, scause
                emitter_rv64.emit(tb.host_code, host_offset, 0x140022f3); // csrr t0, sscratch
            } else if (rd == 6) {
                emitter_rv64.emit(tb.host_code, host_offset, 0x140022f3); // csrr t0, sscratch
            } else {
                emitter_rv64.emit(tb.host_code, host_offset, 0x14202373); // csrr t1, scause
                emitter_rv64.emit(tb.host_code, host_offset, 0x140022f3); // csrr t0, sscratch
            }
        }
    }

    fn emitDirectStore(tb: *block_mod.TranslationBlock, host_offset: *usize, op: u3, rs1: u5, rs2: u5, imm: i12) void {
        emitter_rv64.emit(tb.host_code, host_offset, 0x14029073); // csrw sscratch, t0
        emitter_rv64.emit(tb.host_code, host_offset, 0x14231073); // csrw scause, t1 (0x142)

        if (rs1 == 5) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x140022f3); // csrr t0, sscratch
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 5, imm));
        } else if (rs1 == 6) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x14202373); // csrr t1, scause
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 6, imm));
        } else {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, rs1, imm));
        }

        // Host Physical Address = (vaddr & 0x1FFFFFFF) + 0x00000000E0000000
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(5, 5, 35));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(5, 5, 35));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.lui(6, @as(i20, @bitCast(@as(u20, 0xE0000)))));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(6, 6, 32));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(6, 6, 32));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.add(5, 5, 6));

        const src_reg: u5 = if (rs2 == 5) blk: {
            emitter_rv64.emit(tb.host_code, host_offset, 0x14002373); // csrr t1, sscratch
            break :blk 6;
        } else if (rs2 == 6) blk: {
            emitter_rv64.emit(tb.host_code, host_offset, 0x14202373); // csrr t1, scause
            break :blk 6;
        } else rs2;

        const store_insn: u32 = switch (op) {
            0 => emitter_rv64.sb(5, src_reg, 0),
            1 => emitter_rv64.sh(5, src_reg, 0),
            2 => emitter_rv64.sw(5, src_reg, 0),
            else => emitter_rv64.sw(5, src_reg, 0),
        };
        emitter_rv64.emit(tb.host_code, host_offset, store_insn);

        emitter_rv64.emit(tb.host_code, host_offset, 0x14202373); // csrr t1, scause
        emitter_rv64.emit(tb.host_code, host_offset, 0x140022f3); // csrr t0, sscratch
    }

    fn emitAtomic(tb: *block_mod.TranslationBlock, host_offset: *usize, op: u5, rd: u5, rs1: u5, rs2: u5) void {
        // 1. Save guest t0 (x5) and t1 (x6)
        emitter_rv64.emit(tb.host_code, host_offset, 0x14029073); // csrw sscratch, t0
        emitter_rv64.emit(tb.host_code, host_offset, 0x14231073); // csrw scause, t1 (0x142)

        // 2. Compute address in t0 (x5)
        if (rs1 == 5) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x140022f3); // csrr t0, sscratch
        } else if (rs1 == 6) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x14202373); // csrr t1, scause
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 6, 0));
        } else {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, rs1, 0));
        }

        // 3. Host Physical Address = (vaddr & 0x1FFFFFFF) + 0x00000000E0000000
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(5, 5, 35));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(5, 5, 35));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.lui(6, @as(i20, @bitCast(@as(u20, 0xE0000)))));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(6, 6, 32));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(6, 6, 32));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.add(5, 5, 6));

        // 4. Source register for atomic operand (rs2)
        const src_reg: u5 = if (rs2 == 5) blk: {
            emitter_rv64.emit(tb.host_code, host_offset, 0x14002373); // csrr t1, sscratch
            break :blk 6;
        } else if (rs2 == 6) blk: {
            emitter_rv64.emit(tb.host_code, host_offset, 0x14202373); // csrr t1, scause
            break :blk 6;
        } else rs2;

        // 5. Destination register
        const dest_reg: u5 = if (rd == 5 or rd == 6) 6 else rd;

        // 6. Emit RV64 atomic instruction
        const atomic_insn = emitter_rv64.encodeA(op, 0, 0, dest_reg, 5, src_reg);
        emitter_rv64.emit(tb.host_code, host_offset, atomic_insn);

        // 7. Handle rd return value and restore t0/t1
        if (rd == 5) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x14031073); // csrw sscratch, t1 (save loaded value for t0)
            emitter_rv64.emit(tb.host_code, host_offset, 0x14202373); // csrr t1, scause (restore t1)
            emitter_rv64.emit(tb.host_code, host_offset, 0x140022f3); // csrr t0, sscratch (restore new t0)
        } else if (rd == 6) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x140022f3); // csrr t0, sscratch (restore t0)
        } else {
            emitter_rv64.emit(tb.host_code, host_offset, 0x14202373); // csrr t1, scause (restore t1)
            emitter_rv64.emit(tb.host_code, host_offset, 0x140022f3); // csrr t0, sscratch (restore t0)
        }
    }

    inline fn isRamPointer(reg: u5) bool {
        return reg == 2 or reg == 3 or reg == 4 or reg == 8 or reg == 9 or (reg >= 18 and reg <= 27);
    }

    /// Compile guest basic block starting at `guest_pc` directly into RV64 machine code
    pub fn translateBlock(self: *Engine, start_pc: u32) !*block_mod.TranslationBlock {
        if (self.cache.lookup(start_pc)) |existing| return existing;

        const max_instructions: usize = 64;
        const max_host_bytes: usize = max_instructions * 32;
        const tb = try self.cache.allocateBlock(start_pc, max_host_bytes);

        var current_pc = start_pc;
        var host_offset: usize = 0;

        // Block prologue: restore guest t0 (x5) from sscratch
        emitter_rv64.emit(tb.host_code, &host_offset, 0x140022f3); // csrr t0, sscratch

        while ((current_pc - start_pc) < (max_instructions * 4)) {
            const fetch_res = self.tlb.readU32(current_pc, self.bus);
            if (fetch_res.trap) |cause| {
                self.vcpu.injectException(cause, current_pc, current_pc);
                return error.GuestFetchFault;
            }

            const raw_insn = fetch_res.val;
            const decoded = decoder_rv32.decode(raw_insn);

            switch (decoded.insn) {
                // ---- R-Type Integer Operations ----
                .add => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addw(d.rd, d.rs1, d.rs2)),
                .sub => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.subw(d.rd, d.rs1, d.rs2)),
                .sll => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.sllw(d.rd, d.rs1, d.rs2)),
                .slt => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.slt(d.rd, d.rs1, d.rs2)),
                .sltu => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.sltu(d.rd, d.rs1, d.rs2)),
                .xor_ => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.xor_(d.rd, d.rs1, d.rs2)),
                .srl => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.srlw(d.rd, d.rs1, d.rs2)),
                .sra => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.sraw(d.rd, d.rs1, d.rs2)),
                .or_ => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.or_(d.rd, d.rs1, d.rs2)),
                .and_ => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.and_(d.rd, d.rs1, d.rs2)),

                // ---- M-Extension Multiply & Divide Operations ----
                .mul => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.mulw(d.rd, d.rs1, d.rs2)),
                .mulh => break,
                .mulhu => break,
                .mulhsu => break,
                .div => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.divw(d.rd, d.rs1, d.rs2)),
                .divu => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.divuw(d.rd, d.rs1, d.rs2)),
                .rem => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.remw(d.rd, d.rs1, d.rs2)),
                .remu => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.remuw(d.rd, d.rs1, d.rs2)),

                // ---- I-Type Integer Operations ----
                .addi => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rs1, @as(i12, @truncate(d.imm)))),
                .slli => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.slliw(d.rd, d.rs1, @as(u5, @truncate(d.shamt)))),
                .srli => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.srliw(d.rd, d.rs1, @as(u5, @truncate(d.shamt)))),
                .srai => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.sraiw(d.rd, d.rs1, @as(u5, @truncate(d.shamt)))),
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

                // ---- Direct-Mapped RAM Load & Store Operations (for sp, gp, s0 pointers) ----
                .lw => |d| if (d.rs1 == 2 or d.rs1 == 3 or d.rs1 == 8) emitDirectLoad(tb, &host_offset, 2, d.rd, d.rs1, @as(i12, @truncate(d.offset))) else break,
                .lh => |d| if (d.rs1 == 2 or d.rs1 == 3 or d.rs1 == 8) emitDirectLoad(tb, &host_offset, 1, d.rd, d.rs1, @as(i12, @truncate(d.offset))) else break,
                .lb => |d| if (d.rs1 == 2 or d.rs1 == 3 or d.rs1 == 8) emitDirectLoad(tb, &host_offset, 0, d.rd, d.rs1, @as(i12, @truncate(d.offset))) else break,
                .lhu => |d| if (d.rs1 == 2 or d.rs1 == 3 or d.rs1 == 8) emitDirectLoad(tb, &host_offset, 5, d.rd, d.rs1, @as(i12, @truncate(d.offset))) else break,
                .lbu => |d| if (d.rs1 == 2 or d.rs1 == 3 or d.rs1 == 8) emitDirectLoad(tb, &host_offset, 4, d.rd, d.rs1, @as(i12, @truncate(d.offset))) else break,

                .sw => |d| if (d.rs1 == 2 or d.rs1 == 3 or d.rs1 == 8) emitDirectStore(tb, &host_offset, 2, d.rs1, d.rs2, @as(i12, @truncate(d.offset))) else break,
                .sh => |d| if (d.rs1 == 2 or d.rs1 == 3 or d.rs1 == 8) emitDirectStore(tb, &host_offset, 1, d.rs1, d.rs2, @as(i12, @truncate(d.offset))) else break,
                .sb => |d| if (d.rs1 == 2 or d.rs1 == 3 or d.rs1 == 8) emitDirectStore(tb, &host_offset, 0, d.rs1, d.rs2, @as(i12, @truncate(d.offset))) else break,

                // ---- Atomic Operations (A-Extension) ----
                .lr_w => |d| emitAtomic(tb, &host_offset, 0x02, d.rd, d.rs1, 0),
                .sc_w => |d| emitAtomic(tb, &host_offset, 0x03, d.rd, d.rs1, d.rs2),
                .amoswap_w => |d| emitAtomic(tb, &host_offset, 0x01, d.rd, d.rs1, d.rs2),
                .amoadd_w => |d| emitAtomic(tb, &host_offset, 0x00, d.rd, d.rs1, d.rs2),
                .amoxor_w => |d| emitAtomic(tb, &host_offset, 0x04, d.rd, d.rs1, d.rs2),
                .amoand_w => |d| emitAtomic(tb, &host_offset, 0x0C, d.rd, d.rs1, d.rs2),
                .amoor_w => |d| emitAtomic(tb, &host_offset, 0x08, d.rd, d.rs1, d.rs2),
                .amomin_w => |d| emitAtomic(tb, &host_offset, 0x10, d.rd, d.rs1, d.rs2),
                .amomax_w => |d| emitAtomic(tb, &host_offset, 0x14, d.rd, d.rs1, d.rs2),
                .amominu_w => |d| emitAtomic(tb, &host_offset, 0x18, d.rd, d.rs1, d.rs2),
                .amomaxu_w => |d| emitAtomic(tb, &host_offset, 0x1C, d.rd, d.rs1, d.rs2),

                // ---- Barriers & CSRs ----
                .fence => emitter_rv64.emit(tb.host_code, &host_offset, 0x0ff0000f),
                .fence_i => emitter_rv64.emit(tb.host_code, &host_offset, 0x0000100f),

                .csrrs => |d| {
                    if (d.csr == 0xC01 or d.csr == 0xC00) { // rdtime / rdcycle
                        if (d.rd != 0) {
                            emitter_rv64.emit(tb.host_code, &host_offset, 0xc0102073 | (@as(u32, d.rd) << 7));
                            emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rd, 0));
                        }
                    } else if (d.csr == 0xC81 or d.csr == 0xC80) { // rdtimeh / rdcycleh
                        if (d.rd != 0) {
                            emitter_rv64.emit(tb.host_code, &host_offset, 0xc0102073 | (@as(u32, d.rd) << 7));
                            emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.srli(d.rd, d.rd, 32));
                            emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rd, 0));
                        }
                    } else {
                        break;
                    }
                },

                // ---- Control Flow & End of Basic Block ----
                .jal => |d| {
                    const target = current_pc +% @as(u32, @bitCast(d.offset));
                    if (d.rd != 0) {
                        const link_pc = current_pc + decoded.len;
                        const link_offset = link_pc +% 0x800;
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.lui(d.rd, @as(i20, @truncate(@as(i32, @bitCast(link_offset >> 12))))));
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rd, @as(i12, @truncate(@as(i32, @bitCast(link_pc & 0xFFF))))));
                    }
                    tb.exit_branch1 = emitExit(tb, &host_offset, target);
                    current_pc += decoded.len;
                    break;
                },

                .jalr => |d| {
                    // 1. Preserve original guest t0 (x5) into sscratch
                    emitter_rv64.emit(tb.host_code, &host_offset, 0x14029073); // csrw sscratch, t0

                    // 2. Calculate target PC into t0 (x5): (rs1 + offset) & ~1
                    if (d.rs1 == 5) {
                        emitter_rv64.emit(tb.host_code, &host_offset, 0x140022f3); // csrr t0, sscratch
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(5, 5, @as(i12, @truncate(d.offset))));
                    } else if (d.rs1 != 0) {
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(5, d.rs1, @as(i12, @truncate(d.offset))));
                    } else {
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(5, 0, @as(i12, @truncate(d.offset))));
                    }
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.andi(5, 5, -2));

                    // 3. Save target_pc into sepc (CSR 0x141)
                    emitter_rv64.emit(tb.host_code, &host_offset, 0x14129073); // csrw sepc, t0

                    // 4. Save link PC into rd
                    if (d.rd != 0 and d.rd != 5) {
                        const link_pc = current_pc + decoded.len;
                        const link_offset = link_pc +% 0x800;
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.lui(d.rd, @as(i20, @truncate(@as(i32, @bitCast(link_offset >> 12))))));
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rd, @as(i12, @truncate(@as(i32, @bitCast(link_pc & 0xFFF))))));
                    } else if (d.rd == 5) {
                        const link_pc = current_pc + decoded.len;
                        const link_offset = link_pc +% 0x800;
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.lui(5, @as(i20, @truncate(@as(i32, @bitCast(link_offset >> 12))))));
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(5, 5, @as(i12, @truncate(@as(i32, @bitCast(link_pc & 0xFFF))))));
                        emitter_rv64.emit(tb.host_code, &host_offset, 0x14029073); // csrw sscratch, t0 (store link_pc as guest t0)
                    }

                    // 5. Jump to hw_dynarec_exit using auipc + jalr
                    const exit_addr = cache_mod.getExitAddr();
                    const patch_off = host_offset;
                    const src = @intFromPtr(tb.host_code.ptr) + patch_off;
                    const rel = @as(isize, @bitCast(exit_addr)) - @as(isize, @bitCast(src));
                    const j_upper = @as(i20, @truncate((rel + 0x800) >> 12));
                    const j_lower = @as(i12, @bitCast(@as(u12, @truncate(@as(usize, @bitCast(rel)) & 0xFFF))));
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.auipc(5, j_upper));
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.jalr(0, 5, j_lower));

                    current_pc += decoded.len;
                    break;
                },

                .beq => |d| {
                    const target = current_pc +% @as(u32, @bitCast(d.offset));
                    const fallthrough = current_pc + decoded.len;
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.beq(d.rs1, d.rs2, 28));
                    tb.exit_branch2 = emitExit(tb, &host_offset, fallthrough);
                    tb.exit_branch1 = emitExit(tb, &host_offset, target);
                    current_pc += decoded.len;
                    break;
                },

                .bne => |d| {
                    const target = current_pc +% @as(u32, @bitCast(d.offset));
                    const fallthrough = current_pc + decoded.len;
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.bne(d.rs1, d.rs2, 28));
                    tb.exit_branch2 = emitExit(tb, &host_offset, fallthrough);
                    tb.exit_branch1 = emitExit(tb, &host_offset, target);
                    current_pc += decoded.len;
                    break;
                },

                .blt => |d| {
                    const target = current_pc +% @as(u32, @bitCast(d.offset));
                    const fallthrough = current_pc + decoded.len;
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.blt(d.rs1, d.rs2, 28));
                    tb.exit_branch2 = emitExit(tb, &host_offset, fallthrough);
                    tb.exit_branch1 = emitExit(tb, &host_offset, target);
                    current_pc += decoded.len;
                    break;
                },

                .bge => |d| {
                    const target = current_pc +% @as(u32, @bitCast(d.offset));
                    const fallthrough = current_pc + decoded.len;
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.bge(d.rs1, d.rs2, 28));
                    tb.exit_branch2 = emitExit(tb, &host_offset, fallthrough);
                    tb.exit_branch1 = emitExit(tb, &host_offset, target);
                    current_pc += decoded.len;
                    break;
                },

                .bltu => |d| {
                    const target = current_pc +% @as(u32, @bitCast(d.offset));
                    const fallthrough = current_pc + decoded.len;
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.bltu(d.rs1, d.rs2, 28));
                    tb.exit_branch2 = emitExit(tb, &host_offset, fallthrough);
                    tb.exit_branch1 = emitExit(tb, &host_offset, target);
                    current_pc += decoded.len;
                    break;
                },

                .bgeu => |d| {
                    const target = current_pc +% @as(u32, @bitCast(d.offset));
                    const fallthrough = current_pc + decoded.len;
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.bgeu(d.rs1, d.rs2, 28));
                    tb.exit_branch2 = emitExit(tb, &host_offset, fallthrough);
                    tb.exit_branch1 = emitExit(tb, &host_offset, target);
                    current_pc += decoded.len;
                    break;
                },

                .ecall, .ebreak, .mret, .sret => break,

                else => break,
            }

            current_pc += decoded.len;
        }

        if (current_pc == start_pc or host_offset <= 4) {
            self.cache.cancelBlock();
            return error.CannotTranslate;
        }

        if ((tb.host_code[host_offset - 4] & 0x7F) != 0x67) {
            _ = emitExit(tb, &host_offset, current_pc);
        }

        tb.guest_size = current_pc - start_pc;
        tb.host_len = host_offset;
        self.cache.commitBlock(tb, host_offset);
        self.cache.chainBlock(tb);
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
                const val1 = @as(u64, @as(u32, @truncate(self.vcpu.getGpr(d.rs1))));
                const val2 = @as(u64, @as(u32, @truncate(self.vcpu.getGpr(d.rs2))));
                const p = val1 *% val2;
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
                const val2 = @as(u64, @as(u32, @truncate(self.vcpu.getGpr(d.rs2))));
                const p = @as(u64, @bitCast(s1 *% @as(i64, @bitCast(val2))));
                self.vcpu.setGpr(d.rd, @as(u32, @truncate(p >> 32)));
            },
            .mulhu => |d| {
                const val1 = @as(u64, @as(u32, @truncate(self.vcpu.getGpr(d.rs1))));
                const val2 = @as(u64, @as(u32, @truncate(self.vcpu.getGpr(d.rs2))));
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
            .auipc => |d| self.vcpu.setGpr(d.rd, pc_before +% @as(u32, @bitCast(d.imm << 12))),

            // ---- Loads ----
            .lb => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) +% @as(u32, @bitCast(d.offset));
                const res = self.tlb.readU8(vaddr, self.bus);
                if (res.trap) |cause| {
                    self.trap(cause, pc_before, vaddr);
                    return true;
                }
                const sval = @as(i8, @bitCast(@as(u8, @truncate(res.val))));
                self.vcpu.setGpr(d.rd, @as(u32, @bitCast(@as(i32, sval))));
            },
            .lbu => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) +% @as(u32, @bitCast(d.offset));
                const res = self.tlb.readU8(vaddr, self.bus);
                if (res.trap) |cause| {
                    self.trap(cause, pc_before, vaddr);
                    return true;
                }
                self.vcpu.setGpr(d.rd, res.val);
            },
            .lh => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) +% @as(u32, @bitCast(d.offset));
                const res = self.tlb.readU16(vaddr, self.bus);
                if (res.trap) |cause| {
                    self.trap(cause, pc_before, vaddr);
                    return true;
                }
                const sval = @as(i16, @bitCast(@as(u16, @truncate(res.val))));
                self.vcpu.setGpr(d.rd, @as(u32, @bitCast(@as(i32, sval))));
            },
            .lhu => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) +% @as(u32, @bitCast(d.offset));
                const res = self.tlb.readU16(vaddr, self.bus);
                if (res.trap) |cause| {
                    self.trap(cause, pc_before, vaddr);
                    return true;
                }
                self.vcpu.setGpr(d.rd, res.val);
            },
            .lw => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) +% @as(u32, @bitCast(d.offset));
                const res = self.tlb.readU32(vaddr, self.bus);
                if (res.trap) |cause| {
                    self.trap(cause, pc_before, vaddr);
                    return true;
                }
                self.vcpu.setGpr(d.rd, res.val);
            },

            // ---- Stores ----
            .sb => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) +% @as(u32, @bitCast(d.offset));
                const trap_cause = self.tlb.writeU8(vaddr, @truncate(self.vcpu.getGpr(d.rs2)), self.bus);
                if (trap_cause) |cause| {
                    self.trap(cause, pc_before, vaddr);
                    return true;
                }
            },
            .sh => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) +% @as(u32, @bitCast(d.offset));
                const trap_cause = self.tlb.writeU16(vaddr, @truncate(self.vcpu.getGpr(d.rs2)), self.bus);
                if (trap_cause) |cause| {
                    self.trap(cause, pc_before, vaddr);
                    return true;
                }
            },
            .sw => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) +% @as(u32, @bitCast(d.offset));
                const val = @as(u32, @truncate(self.vcpu.getGpr(d.rs2)));
                const trap_cause = self.tlb.writeU32(vaddr, val, self.bus);
                if (trap_cause) |cause| {
                    self.trap(cause, pc_before, vaddr);
                    return true;
                }
            },

            // ---- Control Flow ----
            .jal => |d| {
                const target = pc_before +% @as(u32, @bitCast(d.offset));
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
                    self.vcpu.pc = pc_before +% @as(u32, @bitCast(d.offset));
                    return true;
                }
            },
            .bne => |d| {
                if (self.vcpu.getGpr(d.rs1) != self.vcpu.getGpr(d.rs2)) {
                    self.vcpu.pc = pc_before +% @as(u32, @bitCast(d.offset));
                    return true;
                }
            },
            .blt => |d| {
                const s1 = @as(i32, @bitCast(@as(u32, @truncate(self.vcpu.getGpr(d.rs1)))));
                const s2 = @as(i32, @bitCast(@as(u32, @truncate(self.vcpu.getGpr(d.rs2)))));
                if (s1 < s2) {
                    self.vcpu.pc = pc_before +% @as(u32, @bitCast(d.offset));
                    return true;
                }
            },
            .bge => |d| {
                const s1 = @as(i32, @bitCast(@as(u32, @truncate(self.vcpu.getGpr(d.rs1)))));
                const s2 = @as(i32, @bitCast(@as(u32, @truncate(self.vcpu.getGpr(d.rs2)))));
                if (s1 >= s2) {
                    self.vcpu.pc = pc_before +% @as(u32, @bitCast(d.offset));
                    return true;
                }
            },
            .bltu => |d| {
                const val1 = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const val2 = @as(u32, @truncate(self.vcpu.getGpr(d.rs2)));
                if (val1 < val2) {
                    self.vcpu.pc = pc_before +% @as(u32, @bitCast(d.offset));
                    return true;
                }
            },
            .bgeu => |d| {
                const val1 = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const val2 = @as(u32, @truncate(self.vcpu.getGpr(d.rs2)));
                if (val1 >= val2) {
                    self.vcpu.pc = pc_before +% @as(u32, @bitCast(d.offset));
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
                    self.vcpu.injectException(2, pc_before, 0);
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
                    self.vcpu.injectException(2, pc_before, 0);
                    return true;
                }
                const base_vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const count = if (self.vcpu.vl == 0) 32 else self.vcpu.vl;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const res = self.tlb.readU8(base_vaddr + i, self.bus);
                    if (res.trap) |cause| {
                        self.vcpu.injectException(cause, pc_before, base_vaddr + i);
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
                    self.vcpu.injectException(2, pc_before, 0);
                    return true;
                }
                const base_vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const count = if (self.vcpu.vl == 0) 32 else self.vcpu.vl;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const byte = self.vcpu.vregs[d.vs3][i];
                    const trap_res = self.tlb.writeU8(base_vaddr + i, byte, self.bus);
                    if (trap_res) |cause| {
                        self.trap(cause, pc_before, base_vaddr + i);
                        return true;
                    }
                }
                self.vcpu.pc = next_pc;
                return true;
            },
            .vector_op => |d| {
                const vs_enabled = ((self.vcpu.mstatus >> 9) & 3) != 0;
                if (!vs_enabled) {
                    self.vcpu.injectException(2, pc_before, 0);
                    return true;
                }
                @memcpy(self.vcpu.vregs[d.rd][0..], self.vcpu.vregs[d.rs1][0..]);
                self.vcpu.pc = next_pc;
                return true;
            },

            // ---- Atomic Instructions ----
            .lr_w => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const res = self.tlb.lrU32(vaddr, self.vcpu.id, self.bus);
                if (res.trap) |cause| {
                    self.trap(cause, pc_before, vaddr);
                    return true;
                }
                if (d.rd != 0) self.vcpu.setGpr(d.rd, res.val);
                self.vcpu.pc = next_pc;
            },
            .sc_w => |d| {
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1)));
                const val = @as(u32, @truncate(self.vcpu.getGpr(d.rs2)));
                const res = self.tlb.scU32(vaddr, val, self.vcpu.id, self.bus);
                if (res.trap) |cause| {
                    self.trap(cause, pc_before, vaddr);
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
                    self.trap(cause, pc_before, vaddr);
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
                    self.trap(cause, pc_before, vaddr);
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
                    self.trap(cause, pc_before, vaddr);
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
                    self.trap(cause, pc_before, vaddr);
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
                    self.trap(cause, pc_before, vaddr);
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
                    self.trap(cause, pc_before, vaddr);
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
                    self.trap(cause, pc_before, vaddr);
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
                    self.trap(cause, pc_before, vaddr);
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
                    self.trap(cause, pc_before, vaddr);
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
                const pc_trap = pc_before;
                const cause: u32 = switch (self.vcpu.privilege_mode) {
                    0 => 8, // User ecall
                    1 => 9, // Supervisor ecall
                    else => 11, // Machine ecall
                };
                self.trap(cause, pc_trap, 0);
                return true;
            },
            .ebreak => {
                const pc_trap = pc_before;
                self.trap(3, pc_trap, 0);
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
                self.vcpu.pc = next_pc;
                return true;
            },
            .fence => {
                if (comptime builtin.target.cpu.arch.isRISCV()) {
                    asm volatile ("fence rw, rw");
                }
                self.vcpu.pc = next_pc;
                return true;
            },
            .fence_i => {
                if (comptime builtin.target.cpu.arch.isRISCV()) {
                    asm volatile ("fence.i");
                }
                self.tlb.flush();
                self.cache.flush();
                self.vcpu.pc = next_pc;
                return true;
            },

            // Unknown instruction -> Illegal Instruction Trap
            else => {
                const pc_trap = pc_before;
                self.last_fault_pc = pc_trap;
                self.last_fault_cause = 2;
                self.last_fault_val = raw_insn;
                self.trap(2, pc_trap, raw_insn); // Illegal Instruction
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
        const run_start = vcpu_mod.readHostTime();
        defer {
            const run_end = vcpu_mod.readHostTime();
            self.engine_cycles +%= (run_end -% run_start);
        }

        var count: usize = 0;
        while (count < budget) : ({
            count += 1;
            self.total_insn_count +%= 1;
        }) {
            if (self.vcpu.needs_tlb_flush.swap(false, .acquire)) {
                self.tlb.flush();
            }
            if (self.vcpu.needs_cache_flush.swap(false, .acquire)) {
                self.cache.flush();
            }
            if (self.tlb.satp != self.vcpu.satp) {
                self.tlb.satp = self.vcpu.satp;
                self.tlb.flush();
            }
            self.tlb.privilege_mode = self.vcpu.privilege_mode;
            self.tlb.mstatus = self.vcpu.mstatus;
            const pc_before = self.vcpu.pc;
            self.pc_history[self.history_idx & 7] = pc_before;
            self.history_idx += 1;
            self.last_pc = pc_before;

            // Check virtual timer interrupt (throttle timer checks to once per 64 instructions)
            if ((count & 63) == 0) {
                const now = vcpu_mod.VCpu.readGuestTime();
                const vtimecmp = self.vcpu.vstimecmp;
                const mtimecmp = if (self.vcpu.id < 4) self.bus.timer.mtimecmp[self.vcpu.id] else ~@as(u64, 0);
                const timer_target = @min(vtimecmp, mtimecmp);
                if (timer_target != ~@as(u64, 0)) {
                    if (now >= timer_target) {
                        self.vcpu.setMipBit(5); // STIP
                    } else {
                        self.vcpu.clearMipBit(5);
                    }
                } else {
                    self.vcpu.clearMipBit(5);
                }
            }

            if (self.vcpu.satp != 0 and pc_before >= 0xC0000000) {
                const gp = @as(u32, @truncate(self.vcpu.getGpr(3)));
                if (gp >= 0x80000000 and gp < 0xC0000000) {
                    self.vcpu.setGpr(3, gp +% 0x40000000);
                }
            }

            // Check if supervisor interrupts can be delivered (only when stvec is set and an interrupt is pending)
            const sie = (self.vcpu.mstatus >> 1) & 1;
            if (self.vcpu.stvec != 0 and (self.vcpu.privilege_mode == 0 or (self.vcpu.privilege_mode == 1 and sie != 0))) {
                const cur_mip = self.vcpu.getMip();
                const pending = (cur_mip & self.vcpu.sie & self.vcpu.mideleg);
                if (pending != 0) {
                    if ((pending & (1 << 1)) != 0) {
                        self.vcpu.clearMipBit(1);
                        self.vcpu.injectException(0x80000001, pc_before, 0);
                        continue;
                    } else if ((pending & (1 << 5)) != 0) {
                        self.vcpu.clearMipBit(5);
                        self.last_timer_inject_count = self.total_insn_count;
                        self.last_irq_pc = pc_before;
                        self.vcpu.injectException(0x80000005, pc_before, 0);
                        continue;
                    } else if ((pending & (1 << 9)) != 0) {
                        self.vcpu.clearMipBit(9);
                        self.vcpu.injectException(0x80000009, pc_before, 0);
                        continue;
                    }
                }
            }
            // ---- Tier 1 Dynarec: Lookup or translate basic block ----
            if (self.cache.lookup(pc_before)) |tb| {
                const t0 = vcpu_mod.readHostTime();
                const ret_pc = @as(u32, @truncate(runBlock(&self.vcpu.regs, @intFromPtr(tb.host_code.ptr))));
                const t1 = vcpu_mod.readHostTime();
                self.jit_cycles +%= (t1 -% t0);
                self.vcpu.pc = ret_pc;
                const insn_approx = @max(1, tb.guest_size / 2);
                count += insn_approx;
                self.total_insn_count +%= insn_approx;
                continue;
            }

            const fetch_res = self.tlb.fetchU32(pc_before, self.bus);
            if (pc_before != 0) {
                self.last_fault_val = fetch_res.val;
            }
            if (fetch_res.trap) |cause| {
                self.last_fault_pc = pc_before;
                self.last_fault_cause = cause;
                self.last_fault_val = fetch_res.val;
                self.trap(cause, pc_before, pc_before);
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

            // Attempt basic block compilation for ALU/branch sequence
            if (self.translateBlock(pc_before)) |tb| {
                if (tb.guest_size > 0 and tb.host_len > 0) {
                    const t0 = vcpu_mod.readHostTime();
                    const ret_pc = @as(u32, @truncate(runBlock(&self.vcpu.regs, @intFromPtr(tb.host_code.ptr))));
                    const t1 = vcpu_mod.readHostTime();
                    self.jit_cycles +%= (t1 -% t0);
                    self.vcpu.pc = ret_pc;
                    const insn_approx = @max(1, tb.guest_size / 2);
                    count += insn_approx;
                    self.total_insn_count +%= insn_approx;
                    continue;
                }
            } else |_| {}

            if (!self.executeDecoded(decoded, fetch_res.val, pc_before)) return ExitReason.unhandled;
        }
        return ExitReason.normal;
    }
};

test "Dynarec RV32I Arithmetic & Immediate Emission" {
    var raw_pool: [4096]u8 align(4096) = undefined;
    var cache_inst = block_mod.Cache.init(&raw_pool);
    const tb = try cache_inst.allocateBlock(0x80000000, 512);
    var host_offset: usize = 0;

    // Test addw emission (add a0, a1, a2)
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addw(10, 11, 12));
    try std.testing.expectEqual(@as(usize, 4), host_offset);
    try std.testing.expectEqual(@as(u32, 0x00c5853b), @as(*const align(1) u32, @ptrCast(&tb.host_code[0])).*);

    // Test subw emission (sub a0, a1, a2)
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.subw(10, 11, 12));
    try std.testing.expectEqual(@as(usize, 8), host_offset);
    try std.testing.expectEqual(@as(u32, 0x40c5853b), @as(*const align(1) u32, @ptrCast(&tb.host_code[4])).*);

    // Test addiw emission (addi sp, sp, -16)
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(2, 2, -16));
    try std.testing.expectEqual(@as(usize, 12), host_offset);
    try std.testing.expectEqual(@as(u32, 0xff01011b), @as(*const align(1) u32, @ptrCast(&tb.host_code[8])).*);
}

test "Dynarec RV32M Multiply & Divide Emission" {
    var raw_pool: [4096]u8 align(4096) = undefined;
    var cache_inst = block_mod.Cache.init(&raw_pool);
    const tb = try cache_inst.allocateBlock(0x80000000, 512);
    var host_offset: usize = 0;

    // mulw (mul a0, a1, a2)
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.mulw(10, 11, 12));
    try std.testing.expectEqual(@as(u32, 0x02c5853b), @as(*const align(1) u32, @ptrCast(&tb.host_code[0])).*);

    // divw (div a0, a1, a2)
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.divw(10, 11, 12));
    try std.testing.expectEqual(@as(u32, 0x02c5c53b), @as(*const align(1) u32, @ptrCast(&tb.host_code[4])).*);

    // divuw (divu a0, a1, a2)
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.divuw(10, 11, 12));
    try std.testing.expectEqual(@as(u32, 0x02c5d53b), @as(*const align(1) u32, @ptrCast(&tb.host_code[8])).*);

    // remw (rem a0, a1, a2)
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.remw(10, 11, 12));
    try std.testing.expectEqual(@as(u32, 0x02c5e53b), @as(*const align(1) u32, @ptrCast(&tb.host_code[12])).*);

    // remuw (remu a0, a1, a2)
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.remuw(10, 11, 12));
    try std.testing.expectEqual(@as(u32, 0x02c5f53b), @as(*const align(1) u32, @ptrCast(&tb.host_code[16])).*);
}

test "Dynarec RV32A Atomic Memory Instructions Emission" {
    var raw_pool: [4096]u8 align(4096) = undefined;
    var cache_inst = block_mod.Cache.init(&raw_pool);
    const tb = try cache_inst.allocateBlock(0x80000000, 512);
    var host_offset: usize = 0;

    // Emit atomic amoadd.w a0, a2, (a1)
    Engine.emitAtomic(tb, &host_offset, 0x00, 10, 11, 12);
    try std.testing.expect(host_offset > 0);

    // Verify sscratch (0x140) and scause (0x142) saving
    const save_t0 = @as(*const align(1) u32, @ptrCast(&tb.host_code[0])).* ;
    const save_t1 = @as(*const align(1) u32, @ptrCast(&tb.host_code[4])).* ;
    try std.testing.expectEqual(@as(u32, 0x14029073), save_t0); // csrw sscratch, t0
    try std.testing.expectEqual(@as(u32, 0x14231073), save_t1); // csrw scause, t1
}

test "Dynarec Direct Stack Load & Store 512MB Windowing" {
    var raw_pool: [4096]u8 align(4096) = undefined;
    var cache_inst = block_mod.Cache.init(&raw_pool);
    const tb = try cache_inst.allocateBlock(0x80000000, 512);
    var host_offset: usize = 0;

    // Emit lw a0, 8(sp)
    Engine.emitDirectLoad(tb, &host_offset, 2, 10, 2, 8);
    try std.testing.expect(host_offset > 0);

    // Verify 35-bit shift (512MB RAM mask)
    // slli a0, a0, 35 -> 0x02351513
    // srli a0, a0, 35 -> 0x02355513
    try std.testing.expectEqual(@as(u32, 0x02351513), @as(*const align(1) u32, @ptrCast(&tb.host_code[16])).*);
    try std.testing.expectEqual(@as(u32, 0x02355513), @as(*const align(1) u32, @ptrCast(&tb.host_code[20])).*);
}
