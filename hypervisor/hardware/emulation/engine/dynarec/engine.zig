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

fn printUart(msg: []const u8) void {
    if (comptime builtin.target.cpu.arch.isRISCV()) {
        const uart_ptr: *volatile u8 = @ptrFromInt(0x10000000);
        for (msg) |c| {
            uart_ptr.* = c;
        }
    }
}

fn printHex(val: u32) void {
    const hex = "0123456789abcdef";
    var buf: [10]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';
    var v = val;
    var i: usize = 9;
    while (i >= 2) : (i -= 1) {
        buf[i] = hex[v & 0xf];
        v >>= 4;
    }
    printUart(&buf);
}

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
        self.vcpu.tlb_entries_ptr = @intFromPtr(&tlb.entries[0]);
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
        printUart("\n[VCPU_LAYOUT] vcpu=");
        printHex(@as(u32, @truncate(@intFromPtr(vcpu))));
        printUart(" regs=");
        printHex(@as(u32, @truncate(@intFromPtr(&vcpu.regs[0]))));
        printUart(" pc=");
        printHex(@as(u32, @truncate(@intFromPtr(&vcpu.pc))));
        printUart(" sscratch=");
        printHex(@as(u32, @truncate(@intFromPtr(&vcpu.sscratch))));
        printUart(" host_sp=");
        printHex(@as(u32, @truncate(@intFromPtr(&vcpu.host_sp))));
        printUart(" scratch_t1=");
        printHex(@as(u32, @truncate(@intFromPtr(&vcpu.scratch_t1))));
        printUart("\n");
        self.cache.initOnPtr(buffer);
    }

    pub fn trap(self: *Engine, cause: u32, fault_pc: u32, stval: u32) void {
        if (cause != 8 and cause != 9) {
            printUart("\n[TRAP] cause=");
            printHex(cause);
            printUart(" pc=");
            printHex(fault_pc);
            printUart(" stval=");
            printHex(stval);
            printUart(" stvec=");
            printHex(self.vcpu.stvec);
            printUart(" tp=");
            printHex(@as(u32, @truncate(self.vcpu.regs[4])));
            printUart(" sscratch=");
            printHex(self.vcpu.sscratch);
            printUart(" sepc=");
            printHex(self.vcpu.sepc);
            printUart(" sp=");
            printHex(@as(u32, @truncate(self.vcpu.regs[2])));
            printUart(" ra=");
            printHex(@as(u32, @truncate(self.vcpu.regs[1])));
            printUart(" a0=");
            printHex(@as(u32, @truncate(self.vcpu.regs[10])));
            printUart(" a1=");
            printHex(@as(u32, @truncate(self.vcpu.regs[11])));
            printUart(" a5=");
            printHex(@as(u32, @truncate(self.vcpu.regs[15])));
            printUart(" s0=");
            printHex(@as(u32, @truncate(self.vcpu.regs[8])));
            printUart(" s1=");
            printHex(@as(u32, @truncate(self.vcpu.regs[9])));
            printUart(" t0=");
            printHex(@as(u32, @truncate(self.vcpu.regs[5])));
            printUart(" t1=");
            printHex(@as(u32, @truncate(self.vcpu.regs[6])));
            printUart(" satp=");
            printHex(self.tlb.satp);
            printUart(" priv=");
            printHex(self.tlb.privilege_mode);
            printUart(" pte1=");
            printHex(self.tlb.last_null_pte1);
            printUart(" pte0=");
            printHex(self.tlb.last_null_pte0);
            printUart(" pte_fl=");
            printHex(self.tlb.last_null_pte_flags);
            printUart(" req_fl=");
            printHex(self.tlb.last_null_req_flag);
            printUart("\n");
        }

        self.vcpu.injectException(cause, fault_pc, stval);
        self.tlb.privilege_mode = self.vcpu.privilege_mode;
        self.tlb.mstatus = self.vcpu.mstatus;
        self.tlb.flush();
    }

    fn emitExit(tb: *block_mod.TranslationBlock, host_offset: *usize, target_pc: u32) block_mod.ExitBranch {
        const pc_i32 = @as(i32, @bitCast(target_pc));
        const upper = @as(i20, @truncate((pc_i32 +% 0x800) >> 12));
        const lower = @as(i12, @bitCast(@as(u12, @truncate(target_pc & 0xFFF))));

        // 1. csrw vsscratch, t0 (x5) - preserves original guest t0
        emitter_rv64.emit(tb.host_code, host_offset, 0x24029073);
        // 2. csrr t0, vstval (loads &vcpu.regs into t0)
        emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3);
        // 3. sd t1, 288(t0) (saves guest t1)
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.sd(5, 6, 288));
        // 4. lui t1, upper + addiw t1, t1, lower
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.lui(6, upper));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(6, 6, lower));
        // 5. sw t1, 256(t0) (saves target_pc directly into vcpu.pc!)
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.sw(5, 6, 256));
        // 6. ld t1, 288(t0) (restores guest t1)
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 5, 288));

        // 7. Jump directly to hw_dynarec_exit using auipc + jalr (±2GB reach)
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
            emitter_rv64.emit(tb.host_code, host_offset, 0x24029073); // csrw vsscratch, t0
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
            emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch
        } else {
            emitter_rv64.emit(tb.host_code, host_offset, 0x24029073); // csrw vsscratch, t0
            emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval (t0 = &vcpu.regs)
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.sd(5, 6, 288)); // sd t1, 288(t0) (save t1)

            if (rs1 == 5) {
                emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch
                emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 5, imm));
            } else if (rs1 == 6) {
                emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
                emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0)
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
                emitter_rv64.emit(tb.host_code, host_offset, 0x24031073); // csrw vsscratch, t1 (save loaded value for t0)
                emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
                emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0) (restore t1)
                emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch (restore loaded val to t0)
            } else if (rd == 6) {
                emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch (restore t0)
            } else {
                emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
                emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0) (restore t1)
                emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch (restore t0)
            }
        }
    }

    fn emitDirectStore(tb: *block_mod.TranslationBlock, host_offset: *usize, op: u3, rs1: u5, rs2: u5, imm: i12) void {
        emitter_rv64.emit(tb.host_code, host_offset, 0x24029073); // csrw vsscratch, t0
        emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval (t0 = &vcpu.regs)
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.sd(5, 6, 288)); // sd t1, 288(t0) (save t1)

        if (rs1 == 5) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 5, imm));
        } else if (rs1 == 6) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0)
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
            emitter_rv64.emit(tb.host_code, host_offset, 0x24002373); // csrr t1, vsscratch
            break :blk 6;
        } else if (rs2 == 6) blk: {
            emitter_rv64.emit(tb.host_code, host_offset, 0x24302373); // csrr t1, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 6, 288)); // ld t1, 288(t1)
            break :blk 6;
        } else rs2;

        const store_insn: u32 = switch (op) {
            0 => emitter_rv64.sb(5, src_reg, 0),
            1 => emitter_rv64.sh(5, src_reg, 0),
            2 => emitter_rv64.sw(5, src_reg, 0),
            else => emitter_rv64.sw(5, src_reg, 0),
        };
        emitter_rv64.emit(tb.host_code, host_offset, store_insn);

        emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0) (restore t1)
        emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch (restore t0)
    }

    fn emitSoftTlbLoad(self: *Engine, tb: *block_mod.TranslationBlock, host_offset: *usize, current_pc: u32, op: u3, rd: u5, rs1: u5, imm: i12) void {
        if (rd == 0) return;

        const tlb_addr = @intFromPtr(&self.tlb.entries[0]);
        const tlb_upper = @as(i20, @truncate((@as(i32, @bitCast(@as(u32, @truncate(tlb_addr)))) +% 0x800) >> 12));
        const tlb_lower = @as(i12, @bitCast(@as(u12, @truncate(tlb_addr & 0xFFF))));

        // 1. Save host t0 (x5) and t1 (x6)
        emitter_rv64.emit(tb.host_code, host_offset, 0x24029073); // csrw vsscratch, t0
        emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval (t0 = &vcpu.regs)
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.sd(5, 6, 288)); // sd t1, 288(t0) (save t1)

        // 2. Compute effective GVA into t0 (x5)
        if (rs1 == 5) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 5, imm));
        } else if (rs1 == 6) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0)
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 6, imm));
        } else if (rs1 == 0) {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 0, imm));
        } else {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, rs1, imm));
        }

        // 3. Extract GVA page number into t0: page = (GVA >> 12)
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srliw(5, 5, 12));

        // 4. Compute slot offset in t1 (x6): (page & 0xFFF) << 4
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(6, 5, 52));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(6, 6, 48));

        // 5. Add tlb_entries_ptr: t1 = &tlb.entries[slot]
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.lui(5, tlb_upper));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 5, tlb_lower));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(5, 5, 32));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(5, 5, 32));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.add(6, 6, 5)); // t1 = &tlb.entries[slot]

        // 6. Load cached guest_vaddr_page from entry: t0 = entry.guest_vaddr_page
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.lw(5, 6, 0));

        // 7. Compute expected GVA page number into t1 (x6)
        if (rs1 == 5) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x24002373); // csrr t1, vsscratch
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(6, 6, imm));
        } else if (rs1 == 6) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x24302373); // csrr t1, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 6, 288)); // ld t1, 288(t1)
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(6, 6, imm));
        } else if (rs1 == 0) {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(6, 0, imm));
        } else {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(6, rs1, imm));
        }
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srliw(6, 6, 12));

        // 8. Tag Check: bne t0, t1, slow_exit_offset
        const bne_patch_pos = host_offset.*;
        emitter_rv64.emit(tb.host_code, host_offset, 0); // placeholder

        // ---- HIT PATH ----
        // 9. Recompute slot in t1 and load entry.host_paddr_page:
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(6, 6, 52));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(6, 6, 48));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.lui(5, tlb_upper));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 5, tlb_lower));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(5, 5, 32));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(5, 5, 32));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.add(6, 6, 5));

        // Permission check: flags (offset 4) must have Read bit (1 << 1 = 2)
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.lbu(5, 6, 4));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.andi(5, 5, 2));
        const beqz_patch_pos = host_offset.*;
        emitter_rv64.emit(tb.host_code, host_offset, 0); // placeholder for beqz t0, slow_exit

        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 6, 8)); // t1 = entry.host_paddr_page

        // 10. Recompute GVA and add page offset to t1: HPA = host_paddr_page + (GVA & 0xFFF)
        if (rs1 == 5) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 5, imm));
        } else if (rs1 == 6) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(5, 5, 288)); // ld t0, 288(t0) (original t1)
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 5, imm));
        } else if (rs1 == 0) {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 0, imm));
        } else {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, rs1, imm));
        }
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(5, 5, 52));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(5, 5, 52)); // t0 = GVA & 0xFFF
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.add(5, 5, 6)); // t0 = HPA!

        // 11. Perform hardware load into target_reg
        if (op == 6) {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.flw(rd, 5, 0));
        } else if (op == 7) {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.fld(rd, 5, 0));
        } else {
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
        }

        // 12. Restore scratch registers and write back rd
        if (op == 6 or op == 7) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0) (restore t1)
            emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch (restore t0)
        } else if (rd == 5) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x24031073); // csrw vsscratch, t1 (save loaded val for t0)
            emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0) (restore t1)
            emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch (restore loaded val to t0)
        } else if (rd == 6) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch (restore t0)
        } else {
            emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0) (restore t1)
            emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch (restore t0)
        }


        // 13. Jump over slow_exit
        const jal_patch_pos = host_offset.*;
        emitter_rv64.emit(tb.host_code, host_offset, 0); // placeholder

        // ---- SLOW EXIT (TLB Miss / Permission Fault) ----
        const slow_exit_pos = host_offset.*;
        const bne_rel = @as(i13, @truncate(@as(isize, @intCast(slow_exit_pos - bne_patch_pos))));
        std.mem.writeInt(u32, tb.host_code[bne_patch_pos..][0..4], emitter_rv64.bne(5, 6, bne_rel), .little);
        const beqz_rel = @as(i13, @truncate(@as(isize, @intCast(slow_exit_pos - beqz_patch_pos))));
        std.mem.writeInt(u32, tb.host_code[beqz_patch_pos..][0..4], emitter_rv64.beq(5, 0, beqz_rel), .little);

        emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0) (restore original guest t1)
        emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch (restore original guest t0)
        _ = emitExit(tb, host_offset, current_pc);

        const cont_pos = host_offset.*;
        const jal_rel = @as(i21, @truncate(@as(isize, @intCast(cont_pos - jal_patch_pos))));
        std.mem.writeInt(u32, tb.host_code[jal_patch_pos..][0..4], emitter_rv64.jal(0, jal_rel), .little);
    }

    fn emitSoftTlbStore(self: *Engine, tb: *block_mod.TranslationBlock, host_offset: *usize, current_pc: u32, op: u3, rs1: u5, rs2: u5, imm: i12) void {
        const tlb_addr = @intFromPtr(&self.tlb.entries[0]);
        const tlb_upper = @as(i20, @truncate((@as(i32, @bitCast(@as(u32, @truncate(tlb_addr)))) +% 0x800) >> 12));
        const tlb_lower = @as(i12, @bitCast(@as(u12, @truncate(tlb_addr & 0xFFF))));

        // 1. Save host t0 (x5) and t1 (x6)
        emitter_rv64.emit(tb.host_code, host_offset, 0x24029073); // csrw vsscratch, t0
        emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval (t0 = &vcpu.regs)
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.sd(5, 6, 288)); // sd t1, 288(t0) (save t1)

        // 2. Compute effective GVA into t0 (x5)
        if (rs1 == 5) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 5, imm));
        } else if (rs1 == 6) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0)
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 6, imm));
        } else if (rs1 == 0) {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 0, imm));
        } else {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, rs1, imm));
        }

        // 3. Extract GVA page number into t0: page = (GVA >> 12)
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srliw(5, 5, 12));

        // 4. Compute slot offset in t1 (x6): (page & 0xFFF) << 4
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(6, 5, 52));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(6, 6, 48));

        // 5. Add tlb_entries_ptr: t1 = &tlb.entries[slot]
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.lui(5, tlb_upper));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 5, tlb_lower));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(5, 5, 32));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(5, 5, 32));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.add(6, 6, 5)); // t1 = &tlb.entries[slot]

        // 6. Load cached guest_vaddr_page from entry: t0 = entry.guest_vaddr_page
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.lw(5, 6, 0));

        // 7. Compute expected GVA page number into t1 (x6)
        if (rs1 == 5) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x24002373); // csrr t1, vsscratch
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(6, 6, imm));
        } else if (rs1 == 6) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x24302373); // csrr t1, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 6, 288)); // ld t1, 288(t1)
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(6, 6, imm));
        } else if (rs1 == 0) {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(6, 0, imm));
        } else {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(6, rs1, imm));
        }
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srliw(6, 6, 12));

        // 8. Tag Check: bne t0, t1, slow_exit_offset
        const bne_patch_pos = host_offset.*;
        emitter_rv64.emit(tb.host_code, host_offset, 0); // placeholder

        // ---- HIT PATH ----
        // 9. Recompute slot in t1 and load entry.host_paddr_page:
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(6, 6, 52));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(6, 6, 48));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.lui(5, tlb_upper));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 5, tlb_lower));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(5, 5, 32));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(5, 5, 32));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.add(6, 6, 5));

        // Permission check: flags (offset 4) must have Write bit (1 << 2 = 4)
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.lbu(5, 6, 4));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.andi(5, 5, 4));
        const beqz_patch_pos = host_offset.*;
        emitter_rv64.emit(tb.host_code, host_offset, 0); // placeholder for beqz t0, slow_exit

        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 6, 8)); // t1 = entry.host_paddr_page

        // 10. Recompute GVA and add page offset to t1: HPA = host_paddr_page + (GVA & 0xFFF)
        if (rs1 == 5) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 5, imm));
        } else if (rs1 == 6) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(5, 5, 288)); // ld t0, 288(t0) (original t1)
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 5, imm));
        } else if (rs1 == 0) {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 0, imm));
        } else {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, rs1, imm));
        }
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(5, 5, 52));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(5, 5, 52)); // t0 = GVA & 0xFFF
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.add(5, 5, 6)); // t0 = HPA!

        // 11. Prepare source data register and perform store
        if (op == 6) {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.fsw(5, rs2, 0));
        } else if (op == 7) {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.fsd(5, rs2, 0));
        } else {
            const src_reg: u5 = if (rs2 == 5) blk: {
                emitter_rv64.emit(tb.host_code, host_offset, 0x24002373); // csrr t1, vsscratch
                break :blk 6;
            } else if (rs2 == 6) blk: {
                emitter_rv64.emit(tb.host_code, host_offset, 0x24302373); // csrr t1, vstval
                emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 6, 288)); // ld t1, 288(t1)
                break :blk 6;
            } else rs2;

            const store_insn: u32 = switch (op) {
                0 => emitter_rv64.sb(5, src_reg, 0),
                1 => emitter_rv64.sh(5, src_reg, 0),
                2 => emitter_rv64.sw(5, src_reg, 0),
                else => emitter_rv64.sw(5, src_reg, 0),
            };
            emitter_rv64.emit(tb.host_code, host_offset, store_insn);
        }


        // 12. Restore scratch registers
        emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0) (restore t1)
        emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch (restore t0)

        // 13. Jump over slow_exit
        const jal_patch_pos = host_offset.*;
        emitter_rv64.emit(tb.host_code, host_offset, 0); // placeholder

        // ---- SLOW EXIT (TLB Miss / Permission Fault) ----
        const slow_exit_pos = host_offset.*;
        const bne_rel = @as(i13, @truncate(@as(isize, @intCast(slow_exit_pos - bne_patch_pos))));
        std.mem.writeInt(u32, tb.host_code[bne_patch_pos..][0..4], emitter_rv64.bne(5, 6, bne_rel), .little);
        const beqz_rel = @as(i13, @truncate(@as(isize, @intCast(slow_exit_pos - beqz_patch_pos))));
        std.mem.writeInt(u32, tb.host_code[beqz_patch_pos..][0..4], emitter_rv64.beq(5, 0, beqz_rel), .little);

        emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0) (restore original guest t1)
        emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch (restore original guest t0)
        _ = emitExit(tb, host_offset, current_pc);

        const cont_pos = host_offset.*;
        const jal_rel = @as(i21, @truncate(@as(isize, @intCast(cont_pos - jal_patch_pos))));
        std.mem.writeInt(u32, tb.host_code[jal_patch_pos..][0..4], emitter_rv64.jal(0, jal_rel), .little);
    }

    fn emitMulh(tb: *block_mod.TranslationBlock, host_offset: *usize, rd: u5, rs1: u5, rs2: u5) void {
        if (rd == 0) return;
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.mul(rd, rs1, rs2));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srai(rd, rd, 32));
    }

    fn emitMulhu(tb: *block_mod.TranslationBlock, host_offset: *usize, rd: u5, rs1: u5, rs2: u5) void {
        if (rd == 0) return;
        // 1. Save host t0 (x5) and t1 (x6)
        emitter_rv64.emit(tb.host_code, host_offset, 0x24029073); // csrw vsscratch, t0
        emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval (t0 = &vcpu.regs)
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.sd(5, 6, 288)); // sd t1, 288(t0) (save t1)

        // 2. Zero-extend rs1 into t0
        if (rs1 == 5) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(5, 5, 32));
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(5, 5, 32));
        } else if (rs1 == 6) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(5, 5, 288)); // ld t0, 288(t0) (original t1)
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(5, 5, 32));
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(5, 5, 32));
        } else if (rs1 == 0) {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 0, 0));
        } else {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(5, rs1, 32));
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(5, 5, 32));
        }

        // 3. Zero-extend rs2 into t1
        if (rs2 == 5) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x24002373); // csrr t1, vsscratch
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(6, 6, 32));
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(6, 6, 32));
        } else if (rs2 == 6) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x24302373); // csrr t1, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 6, 288)); // ld t1, 288(t1)
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(6, 6, 32));
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(6, 6, 32));
        } else if (rs2 == 0) {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(6, 0, 0));
        } else {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(6, rs2, 32));
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(6, 6, 32));
        }

        // 4. Multiply and extract upper 32 bits
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.mul(5, 5, 6));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srai(5, 5, 32));

        // 5. Write back to rd and restore scratch
        if (rd == 5) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x24029073); // csrw vsscratch, t0 (save computed result as t0)
            emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0) (restore t1)
            emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch (restore result to t0)
        } else if (rd == 6) {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(6, 5, 0)); // t1 = result
            emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch (restore t0)
        } else {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(rd, 5, 0));
            emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0) (restore t1)
            emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch (restore t0)
        }
    }

    fn emitMulhsu(tb: *block_mod.TranslationBlock, host_offset: *usize, rd: u5, rs1: u5, rs2: u5) void {
        if (rd == 0) return;
        // 1. Save host t0 (x5) and t1 (x6)
        emitter_rv64.emit(tb.host_code, host_offset, 0x24029073); // csrw vsscratch, t0
        emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval (t0 = &vcpu.regs)
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.sd(5, 6, 288)); // sd t1, 288(t0) (save t1)

        // 2. Sign-extend rs1 (signed) into t0
        if (rs1 == 5) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 5, 0));
        } else if (rs1 == 6) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(5, 5, 288)); // ld t0, 288(t0) (original t1)
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 5, 0));
        } else if (rs1 == 0) {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 0, 0));
        } else {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, rs1, 0));
        }

        // 3. Zero-extend rs2 (unsigned) into t1
        if (rs2 == 5) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x24002373); // csrr t1, vsscratch
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(6, 6, 32));
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(6, 6, 32));
        } else if (rs2 == 6) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x24302373); // csrr t1, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 6, 288)); // ld t1, 288(t1)
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(6, 6, 32));
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(6, 6, 32));
        } else if (rs2 == 0) {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(6, 0, 0));
        } else {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(6, rs2, 32));
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(6, 6, 32));
        }

        // 4. Multiply and extract upper 32 bits
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.mul(5, 5, 6));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srai(5, 5, 32));

        // 5. Write back to rd and restore scratch
        if (rd == 5) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x24029073); // csrw vsscratch, t0 (save computed result as t0)
            emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0) (restore t1)
            emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch (restore result to t0)
        } else if (rd == 6) {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(6, 5, 0)); // t1 = result
            emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch (restore t0)
        } else {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(rd, 5, 0));
            emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0) (restore t1)
            emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch (restore t0)
        }
    }

    fn emitSoftTlbAtomic(self: *Engine, tb: *block_mod.TranslationBlock, host_offset: *usize, current_pc: u32, funct5: u5, aq: u1, rl: u1, rd: u5, rs1: u5, rs2: u5) void {
        const tlb_addr = @intFromPtr(&self.tlb.entries[0]);
        const tlb_upper = @as(i20, @truncate((@as(i32, @bitCast(@as(u32, @truncate(tlb_addr)))) +% 0x800) >> 12));
        const tlb_lower = @as(i12, @bitCast(@as(u12, @truncate(tlb_addr & 0xFFF))));

        // 1. Save host t0 (x5) and t1 (x6)
        emitter_rv64.emit(tb.host_code, host_offset, 0x24029073); // csrw vsscratch, t0
        emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval (t0 = &vcpu.regs)
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.sd(5, 6, 288)); // sd t1, 288(t0) (save t1)

        // 2. Compute effective GVA into t0 (x5)
        if (rs1 == 5) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 5, 0));
        } else if (rs1 == 6) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0)
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 6, 0));
        } else if (rs1 == 0) {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 0, 0));
        } else {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, rs1, 0));
        }

        // 3. Extract GVA page number into t0: page = (GVA >> 12)
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srliw(5, 5, 12));

        // 4. Compute slot offset in t1 (x6): (page & 0xFFF) << 4
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(6, 5, 52));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(6, 6, 48));

        // 5. Add tlb_entries_ptr: t1 = &tlb.entries[slot]
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.lui(5, tlb_upper));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 5, tlb_lower));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(5, 5, 32));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(5, 5, 32));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.add(6, 6, 5)); // t1 = &tlb.entries[slot]

        // 6. Load cached guest_vaddr_page from entry: t0 = entry.guest_vaddr_page
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.lw(5, 6, 0));

        // 7. Compute expected GVA page number into t1 (x6)
        if (rs1 == 5) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x24002373); // csrr t1, vsscratch
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(6, 6, 0));
        } else if (rs1 == 6) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x24302373); // csrr t1, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 6, 288)); // ld t1, 288(t1)
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(6, 6, 0));
        } else if (rs1 == 0) {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(6, 0, 0));
        } else {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(6, rs1, 0));
        }
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srliw(6, 6, 12));

        // 8. Tag Check: bne t0, t1, slow_exit_offset
        const bne_patch_pos = host_offset.*;
        emitter_rv64.emit(tb.host_code, host_offset, 0); // placeholder

        // ---- HIT PATH ----
        // 9. Recompute slot in t1 and load entry.host_paddr_page:
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(6, 6, 52));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(6, 6, 48));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.lui(5, tlb_upper));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 5, tlb_lower));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(5, 5, 32));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(5, 5, 32));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.add(6, 6, 5));

        // Permission check:
        // lr_w: Read bit (2)
        // sc_w: Write bit (4)
        // amo: Read + Write bits (6)
        const req_mask: i12 = if (funct5 == 0x02) 2 else if (funct5 == 0x03) 4 else 6;
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.lbu(5, 6, 4));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.andi(5, 5, req_mask));
        if (req_mask == 6) {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 5, -6));
        }
        const beqz_patch_pos = host_offset.*;
        emitter_rv64.emit(tb.host_code, host_offset, 0); // placeholder for beqz/bnez t0, slow_exit

        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 6, 8)); // t1 = entry.host_paddr_page

        // 10. Recompute GVA and add page offset to t1: HPA = host_paddr_page + (GVA & 0xFFF)
        if (rs1 == 5) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 5, 0));
        } else if (rs1 == 6) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(5, 5, 288)); // ld t0, 288(t0) (original t1)
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 5, 0));
        } else if (rs1 == 0) {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, 0, 0));
        } else {
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.addiw(5, rs1, 0));
        }
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.slli(5, 5, 52));
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.srli(5, 5, 52)); // t0 = GVA & 0xFFF
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.add(5, 5, 6)); // t0 = HPA!

        // 11. Prepare source operand register (rs2) if needed
        const src_reg: u5 = if (funct5 == 0x02) 0 else if (rs2 == 5) blk: {
            emitter_rv64.emit(tb.host_code, host_offset, 0x24002373); // csrr t1, vsscratch
            break :blk 6;
        } else if (rs2 == 6) blk: {
            emitter_rv64.emit(tb.host_code, host_offset, 0x24302373); // csrr t1, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 6, 288)); // ld t1, 288(t1)
            break :blk 6;
        } else rs2;

        // Destination register
        const dest_reg: u5 = if (rd == 5 or rd == 6 or rd == 0) 6 else rd;

        // Perform atomic instruction: base address is in t0 (x5)
        const atomic_insn = emitter_rv64.encodeA(funct5, aq, rl, dest_reg, 5, src_reg);
        emitter_rv64.emit(tb.host_code, host_offset, atomic_insn);

        // 12. Restore scratch registers and write back rd
        if (rd == 5) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x24031073); // csrw vsscratch, t1 (save loaded val for t0)
            emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0) (restore t1)
            emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch (restore loaded val to t0)
        } else if (rd == 6) {
            emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch (restore t0)
        } else {
            emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
            emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0) (restore t1)
            emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch (restore t0)
        }

        // 13. Jump over slow_exit
        const jal_patch_pos = host_offset.*;
        emitter_rv64.emit(tb.host_code, host_offset, 0); // placeholder

        // ---- SLOW EXIT (TLB Miss / Permission Fault) ----
        const slow_exit_pos = host_offset.*;
        const bne_rel = @as(i13, @truncate(@as(isize, @intCast(slow_exit_pos - bne_patch_pos))));
        std.mem.writeInt(u32, tb.host_code[bne_patch_pos..][0..4], emitter_rv64.bne(5, 6, bne_rel), .little);
        const beqz_rel = @as(i13, @truncate(@as(isize, @intCast(slow_exit_pos - beqz_patch_pos))));
        if (req_mask == 6) {
            std.mem.writeInt(u32, tb.host_code[beqz_patch_pos..][0..4], emitter_rv64.bne(5, 0, beqz_rel), .little);
        } else {
            std.mem.writeInt(u32, tb.host_code[beqz_patch_pos..][0..4], emitter_rv64.beq(5, 0, beqz_rel), .little);
        }

        emitter_rv64.emit(tb.host_code, host_offset, 0x243022f3); // csrr t0, vstval
        emitter_rv64.emit(tb.host_code, host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0) (restore original guest t1)
        emitter_rv64.emit(tb.host_code, host_offset, 0x240022f3); // csrr t0, vsscratch (restore original guest t0)
        _ = emitExit(tb, host_offset, current_pc);

        const cont_pos = host_offset.*;
        const jal_rel = @as(i21, @truncate(@as(isize, @intCast(cont_pos - jal_patch_pos))));
        std.mem.writeInt(u32, tb.host_code[jal_patch_pos..][0..4], emitter_rv64.jal(0, jal_rel), .little);
    }

    inline fn isRamPointer(reg: u5) bool {
        return reg == 2 or reg == 3 or reg == 4 or reg == 8 or reg == 9 or (reg >= 18 and reg <= 27);
    }

    /// Compile guest basic block starting at `guest_pc` directly into RV64 machine code
    pub fn translateBlock(self: *Engine, start_pc: u32) !*block_mod.TranslationBlock {
        if (self.cache.lookup(start_pc)) |existing| return existing;

        const max_instructions: usize = 32;
        const max_host_bytes: usize = max_instructions * 200 + 512;
        const tb = try self.cache.allocateBlock(start_pc, max_host_bytes);

        var current_pc = start_pc;
        var host_offset: usize = 0;
        var has_explicit_exit: bool = false;

        // Block prologue: restore guest t0 (x5) from vsscratch
        emitter_rv64.emit(tb.host_code, &host_offset, 0x240022f3); // csrr t0, vsscratch

        while ((current_pc - start_pc) < (max_instructions * 4)) {
            if (host_offset + 256 >= tb.host_code.len) break;

            const fetch_res = self.tlb.fetchU32(current_pc, self.bus);
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
                .xor_ => |d| {
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.xor_(d.rd, d.rs1, d.rs2));
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rd, 0));
                },
                .srl => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.srlw(d.rd, d.rs1, d.rs2)),
                .sra => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.sraw(d.rd, d.rs1, d.rs2)),
                .or_ => |d| {
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.or_(d.rd, d.rs1, d.rs2));
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rd, 0));
                },
                .and_ => |d| {
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.and_(d.rd, d.rs1, d.rs2));
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rd, 0));
                },

                // ---- M-Extension Multiply & Divide Operations ----
                .mul => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.mulw(d.rd, d.rs1, d.rs2)),
                .mulh => |d| emitMulh(tb, &host_offset, d.rd, d.rs1, d.rs2),
                .mulhu => |d| emitMulhu(tb, &host_offset, d.rd, d.rs1, d.rs2),
                .mulhsu => |d| emitMulhsu(tb, &host_offset, d.rd, d.rs1, d.rs2),
                .div => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.divw(d.rd, d.rs1, d.rs2)),
                .divu => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.divuw(d.rd, d.rs1, d.rs2)),
                .rem => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.remw(d.rd, d.rs1, d.rs2)),
                .remu => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.remuw(d.rd, d.rs1, d.rs2)),

                // ---- I-Type Integer Operations ----
                .addi => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rs1, @as(i12, @truncate(d.imm)))),
                .slli => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.slliw(d.rd, d.rs1, @as(u5, @truncate(d.shamt)))),
                .srli => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.srliw(d.rd, d.rs1, @as(u5, @truncate(d.shamt)))),
                .srai => |d| emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.sraiw(d.rd, d.rs1, @as(u5, @truncate(d.shamt)))),
                .andi => |d| {
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.andi(d.rd, d.rs1, @as(i12, @truncate(d.imm))));
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rd, 0));
                },
                .ori => |d| {
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.ori(d.rd, d.rs1, @as(i12, @truncate(d.imm))));
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rd, 0));
                },
                .xori => |d| {
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.xori(d.rd, d.rs1, @as(i12, @truncate(d.imm))));
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rd, 0));
                },
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

                // ---- Inlined SoftTLB Fast-Path Load & Store Operations ----
                .lw => |d| self.emitSoftTlbLoad(tb, &host_offset, current_pc, 2, d.rd, d.rs1, @as(i12, @truncate(d.offset))),
                .lh => |d| self.emitSoftTlbLoad(tb, &host_offset, current_pc, 1, d.rd, d.rs1, @as(i12, @truncate(d.offset))),
                .lb => |d| self.emitSoftTlbLoad(tb, &host_offset, current_pc, 0, d.rd, d.rs1, @as(i12, @truncate(d.offset))),
                .lhu => |d| self.emitSoftTlbLoad(tb, &host_offset, current_pc, 5, d.rd, d.rs1, @as(i12, @truncate(d.offset))),
                .lbu => |d| self.emitSoftTlbLoad(tb, &host_offset, current_pc, 4, d.rd, d.rs1, @as(i12, @truncate(d.offset))),
                .flw => |d| self.emitSoftTlbLoad(tb, &host_offset, current_pc, 6, d.rd, d.rs1, @as(i12, @truncate(d.offset))),
                .fld => |d| self.emitSoftTlbLoad(tb, &host_offset, current_pc, 7, d.rd, d.rs1, @as(i12, @truncate(d.offset))),

                .sw => |d| self.emitSoftTlbStore(tb, &host_offset, current_pc, 2, d.rs1, d.rs2, @as(i12, @truncate(d.offset))),
                .sh => |d| self.emitSoftTlbStore(tb, &host_offset, current_pc, 1, d.rs1, d.rs2, @as(i12, @truncate(d.offset))),
                .sb => |d| self.emitSoftTlbStore(tb, &host_offset, current_pc, 0, d.rs1, d.rs2, @as(i12, @truncate(d.offset))),
                .fsw => |d| self.emitSoftTlbStore(tb, &host_offset, current_pc, 6, d.rs1, d.rs2, @as(i12, @truncate(d.offset))),
                .fsd => |d| self.emitSoftTlbStore(tb, &host_offset, current_pc, 7, d.rs1, d.rs2, @as(i12, @truncate(d.offset))),

                // ---- Floating-Point Operations (Direct Native JIT Execution) ----
                .fp_op => |d| emitter_rv64.emit(tb.host_code, &host_offset, d.raw),

                // ---- Atomic Operations (A-Extension) via Inlined SoftTLB ----
                .lr_w => |d| self.emitSoftTlbAtomic(tb, &host_offset, current_pc, 0x02, d.aq, d.rl, d.rd, d.rs1, 0),
                .sc_w => |d| self.emitSoftTlbAtomic(tb, &host_offset, current_pc, 0x03, d.aq, d.rl, d.rd, d.rs1, d.rs2),
                .amoswap_w => |d| self.emitSoftTlbAtomic(tb, &host_offset, current_pc, 0x01, d.aq, d.rl, d.rd, d.rs1, d.rs2),
                .amoadd_w => |d| self.emitSoftTlbAtomic(tb, &host_offset, current_pc, 0x00, d.aq, d.rl, d.rd, d.rs1, d.rs2),
                .amoxor_w => |d| self.emitSoftTlbAtomic(tb, &host_offset, current_pc, 0x04, d.aq, d.rl, d.rd, d.rs1, d.rs2),
                .amoand_w => |d| self.emitSoftTlbAtomic(tb, &host_offset, current_pc, 0x0C, d.aq, d.rl, d.rd, d.rs1, d.rs2),
                .amoor_w => |d| self.emitSoftTlbAtomic(tb, &host_offset, current_pc, 0x08, d.aq, d.rl, d.rd, d.rs1, d.rs2),
                .amomin_w => |d| self.emitSoftTlbAtomic(tb, &host_offset, current_pc, 0x10, d.aq, d.rl, d.rd, d.rs1, d.rs2),
                .amomax_w => |d| self.emitSoftTlbAtomic(tb, &host_offset, current_pc, 0x14, d.aq, d.rl, d.rd, d.rs1, d.rs2),
                .amominu_w => |d| self.emitSoftTlbAtomic(tb, &host_offset, current_pc, 0x18, d.aq, d.rl, d.rd, d.rs1, d.rs2),
                .amomaxu_w => |d| self.emitSoftTlbAtomic(tb, &host_offset, current_pc, 0x1C, d.aq, d.rl, d.rd, d.rs1, d.rs2),

                // ---- Barriers & CSRs ----
                .fence => emitter_rv64.emit(tb.host_code, &host_offset, 0x0ff0000f),
                .fence_i => emitter_rv64.emit(tb.host_code, &host_offset, 0x0000100f),

                .csrrs => |d| {
                    if (d.csr == 0xC01 or d.csr == 0xC00 or d.csr == 0xC02) { // rdtime / rdcycle / rdinstret
                        if (d.rd != 0) {
                            const host_csr: u32 = if (d.csr == 0xC00) 0xC00 else if (d.csr == 0xC02) 0xC02 else 0xC01;
                            emitter_rv64.emit(tb.host_code, &host_offset, (host_csr << 20) | (@as(u32, d.rd) << 7) | 0x2073);
                            emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rd, 0));
                        }
                    } else if (d.csr == 0xC81 or d.csr == 0xC80 or d.csr == 0xC82) { // rdtimeh / rdcycleh / rdinstreth
                        if (d.rd != 0) {
                            const host_csr: u32 = if (d.csr == 0xC80) 0xC00 else if (d.csr == 0xC82) 0xC02 else 0xC01;
                            emitter_rv64.emit(tb.host_code, &host_offset, (host_csr << 20) | (@as(u32, d.rd) << 7) | 0x2073);
                            emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.srli(d.rd, d.rd, 32));
                            emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rd, 0));
                        }
                    } else {
                        break;
                    }
                },
                .csrrw => |d| {
                    if (d.rs1 == 0 and (d.csr == 0xC01 or d.csr == 0xC00 or d.csr == 0xC02)) {
                        if (d.rd != 0) {
                            const host_csr: u32 = if (d.csr == 0xC00) 0xC00 else if (d.csr == 0xC02) 0xC02 else 0xC01;
                            emitter_rv64.emit(tb.host_code, &host_offset, (host_csr << 20) | (@as(u32, d.rd) << 7) | 0x2073);
                            emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rd, 0));
                        }
                    } else if (d.rs1 == 0 and (d.csr == 0xC81 or d.csr == 0xC80 or d.csr == 0xC82)) {
                        if (d.rd != 0) {
                            const host_csr: u32 = if (d.csr == 0xC80) 0xC00 else if (d.csr == 0xC82) 0xC02 else 0xC01;
                            emitter_rv64.emit(tb.host_code, &host_offset, (host_csr << 20) | (@as(u32, d.rd) << 7) | 0x2073);
                            emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.srli(d.rd, d.rd, 32));
                            emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rd, 0));
                        }
                    } else {
                        break;
                    }
                },
                .csrrc => |d| {
                    if (d.rs1 == 0 and (d.csr == 0xC01 or d.csr == 0xC00 or d.csr == 0xC02)) {
                        if (d.rd != 0) {
                            const host_csr: u32 = if (d.csr == 0xC00) 0xC00 else if (d.csr == 0xC02) 0xC02 else 0xC01;
                            emitter_rv64.emit(tb.host_code, &host_offset, (host_csr << 20) | (@as(u32, d.rd) << 7) | 0x2073);
                            emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rd, 0));
                        }
                    } else if (d.rs1 == 0 and (d.csr == 0xC81 or d.csr == 0xC80 or d.csr == 0xC82)) {
                        if (d.rd != 0) {
                            const host_csr: u32 = if (d.csr == 0xC80) 0xC00 else if (d.csr == 0xC82) 0xC02 else 0xC01;
                            emitter_rv64.emit(tb.host_code, &host_offset, (host_csr << 20) | (@as(u32, d.rd) << 7) | 0x2073);
                            emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.srli(d.rd, d.rd, 32));
                            emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rd, 0));
                        }
                    } else {
                        break;
                    }
                },
                .csrrsi => |d| {
                    if (d.uimm == 0 and (d.csr == 0xC01 or d.csr == 0xC00 or d.csr == 0xC02)) {
                        if (d.rd != 0) {
                            const host_csr: u32 = if (d.csr == 0xC00) 0xC00 else if (d.csr == 0xC02) 0xC02 else 0xC01;
                            emitter_rv64.emit(tb.host_code, &host_offset, (host_csr << 20) | (@as(u32, d.rd) << 7) | 0x2073);
                            emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rd, 0));
                        }
                    } else if (d.uimm == 0 and (d.csr == 0xC81 or d.csr == 0xC80 or d.csr == 0xC82)) {
                        if (d.rd != 0) {
                            const host_csr: u32 = if (d.csr == 0xC80) 0xC00 else if (d.csr == 0xC82) 0xC02 else 0xC01;
                            emitter_rv64.emit(tb.host_code, &host_offset, (host_csr << 20) | (@as(u32, d.rd) << 7) | 0x2073);
                            emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.srli(d.rd, d.rd, 32));
                            emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rd, 0));
                        }
                    } else {
                        break;
                    }
                },
                .csrrci => |d| {
                    if (d.uimm == 0 and (d.csr == 0xC01 or d.csr == 0xC00 or d.csr == 0xC02)) {
                        if (d.rd != 0) {
                            const host_csr: u32 = if (d.csr == 0xC00) 0xC00 else if (d.csr == 0xC02) 0xC02 else 0xC01;
                            emitter_rv64.emit(tb.host_code, &host_offset, (host_csr << 20) | (@as(u32, d.rd) << 7) | 0x2073);
                            emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rd, 0));
                        }
                    } else if (d.uimm == 0 and (d.csr == 0xC81 or d.csr == 0xC80 or d.csr == 0xC82)) {
                        if (d.rd != 0) {
                            const host_csr: u32 = if (d.csr == 0xC80) 0xC00 else if (d.csr == 0xC82) 0xC02 else 0xC01;
                            emitter_rv64.emit(tb.host_code, &host_offset, (host_csr << 20) | (@as(u32, d.rd) << 7) | 0x2073);
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
                    has_explicit_exit = true;
                    current_pc += decoded.len;
                    break;
                },

                .jalr => |d| {
                    // 1. Preserve original guest t0 (x5) into vsscratch
                    emitter_rv64.emit(tb.host_code, &host_offset, 0x24029073); // csrw vsscratch, t0
                    // 2. Load &vcpu.regs into t0
                    emitter_rv64.emit(tb.host_code, &host_offset, 0x243022f3); // csrr t0, vstval
                    // 3. Save guest t1 (x6) to 288(t0)
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.sd(5, 6, 288));

                    // 4. Calculate target PC into t1 (x6): (rs1 + offset) & ~1
                    if (d.rs1 == 5) {
                        emitter_rv64.emit(tb.host_code, &host_offset, 0x24002373); // csrr t1, vsscratch
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(6, 6, @as(i12, @truncate(d.offset))));
                    } else if (d.rs1 == 6) {
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0)
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(6, 6, @as(i12, @truncate(d.offset))));
                    } else if (d.rs1 != 0) {
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(6, d.rs1, @as(i12, @truncate(d.offset))));
                    } else {
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(6, 0, @as(i12, @truncate(d.offset))));
                    }
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.andi(6, 6, -2));

                    // 5. Save target_pc directly into vcpu.pc (offset 256)
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.sw(5, 6, 256));

                    // 6. Save link PC into rd
                    const link_pc = current_pc + decoded.len;
                    const link_offset = link_pc +% 0x800;
                    if (d.rd == 5) {
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.lui(6, @as(i20, @truncate(@as(i32, @bitCast(link_offset >> 12))))));
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(6, 6, @as(i12, @truncate(@as(i32, @bitCast(link_pc & 0xFFF))))));
                        emitter_rv64.emit(tb.host_code, &host_offset, 0x24031073); // csrw vsscratch, t1 (store link_pc as guest t0)
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0) (restore original guest t1)
                    } else if (d.rd == 6) {
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.lui(6, @as(i20, @truncate(@as(i32, @bitCast(link_offset >> 12))))));
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(6, 6, @as(i12, @truncate(@as(i32, @bitCast(link_pc & 0xFFF))))));
                        // t1 already has link_pc which will be saved to vcpu.regs[6] by hw_dynarec_exit!
                    } else if (d.rd != 0) {
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.lui(d.rd, @as(i20, @truncate(@as(i32, @bitCast(link_offset >> 12))))));
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.addiw(d.rd, d.rd, @as(i12, @truncate(@as(i32, @bitCast(link_pc & 0xFFF))))));
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0) (restore original guest t1)
                    } else {
                        emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.ld(6, 5, 288)); // ld t1, 288(t0) (restore original guest t1)
                    }

                    // 7. Jump to hw_dynarec_exit using auipc + jalr (t0 is free)
                    const exit_addr = cache_mod.getExitAddr();
                    const patch_off = host_offset;
                    const src = @intFromPtr(tb.host_code.ptr) + patch_off;
                    const rel = @as(isize, @bitCast(exit_addr)) - @as(isize, @bitCast(src));
                    const j_upper = @as(i20, @truncate((rel + 0x800) >> 12));
                    const j_lower = @as(i12, @bitCast(@as(u12, @truncate(@as(usize, @bitCast(rel)) & 0xFFF))));
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.auipc(5, j_upper));
                    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.jalr(0, 5, j_lower));

                    has_explicit_exit = true;
                    current_pc += decoded.len;
                    break;
                },

                .beq => |d| {
                    const target = current_pc +% @as(u32, @bitCast(d.offset));
                    const fallthrough = current_pc + decoded.len;
                    const branch_patch_pos = host_offset;
                    emitter_rv64.emit(tb.host_code, &host_offset, 0); // placeholder
                    tb.exit_branch2 = emitExit(tb, &host_offset, fallthrough);
                    const target_pos = host_offset;
                    const branch_rel = @as(i13, @truncate(@as(isize, @intCast(target_pos - branch_patch_pos))));
                    std.mem.writeInt(u32, tb.host_code[branch_patch_pos..][0..4], emitter_rv64.beq(d.rs1, d.rs2, branch_rel), .little);
                    tb.exit_branch1 = emitExit(tb, &host_offset, target);
                    has_explicit_exit = true;
                    current_pc += decoded.len;
                    break;
                },

                .bne => |d| {
                    const target = current_pc +% @as(u32, @bitCast(d.offset));
                    const fallthrough = current_pc + decoded.len;
                    const branch_patch_pos = host_offset;
                    emitter_rv64.emit(tb.host_code, &host_offset, 0); // placeholder
                    tb.exit_branch2 = emitExit(tb, &host_offset, fallthrough);
                    const target_pos = host_offset;
                    const branch_rel = @as(i13, @truncate(@as(isize, @intCast(target_pos - branch_patch_pos))));
                    std.mem.writeInt(u32, tb.host_code[branch_patch_pos..][0..4], emitter_rv64.bne(d.rs1, d.rs2, branch_rel), .little);
                    tb.exit_branch1 = emitExit(tb, &host_offset, target);
                    has_explicit_exit = true;
                    current_pc += decoded.len;
                    break;
                },

                .blt => |d| {
                    const target = current_pc +% @as(u32, @bitCast(d.offset));
                    const fallthrough = current_pc + decoded.len;
                    const branch_patch_pos = host_offset;
                    emitter_rv64.emit(tb.host_code, &host_offset, 0); // placeholder
                    tb.exit_branch2 = emitExit(tb, &host_offset, fallthrough);
                    const target_pos = host_offset;
                    const branch_rel = @as(i13, @truncate(@as(isize, @intCast(target_pos - branch_patch_pos))));
                    std.mem.writeInt(u32, tb.host_code[branch_patch_pos..][0..4], emitter_rv64.blt(d.rs1, d.rs2, branch_rel), .little);
                    tb.exit_branch1 = emitExit(tb, &host_offset, target);
                    has_explicit_exit = true;
                    current_pc += decoded.len;
                    break;
                },

                .bge => |d| {
                    const target = current_pc +% @as(u32, @bitCast(d.offset));
                    const fallthrough = current_pc + decoded.len;
                    const branch_patch_pos = host_offset;
                    emitter_rv64.emit(tb.host_code, &host_offset, 0); // placeholder
                    tb.exit_branch2 = emitExit(tb, &host_offset, fallthrough);
                    const target_pos = host_offset;
                    const branch_rel = @as(i13, @truncate(@as(isize, @intCast(target_pos - branch_patch_pos))));
                    std.mem.writeInt(u32, tb.host_code[branch_patch_pos..][0..4], emitter_rv64.bge(d.rs1, d.rs2, branch_rel), .little);
                    tb.exit_branch1 = emitExit(tb, &host_offset, target);
                    has_explicit_exit = true;
                    current_pc += decoded.len;
                    break;
                },

                .bltu => |d| {
                    const target = current_pc +% @as(u32, @bitCast(d.offset));
                    const fallthrough = current_pc + decoded.len;
                    const branch_patch_pos = host_offset;
                    emitter_rv64.emit(tb.host_code, &host_offset, 0); // placeholder
                    tb.exit_branch2 = emitExit(tb, &host_offset, fallthrough);
                    const target_pos = host_offset;
                    const branch_rel = @as(i13, @truncate(@as(isize, @intCast(target_pos - branch_patch_pos))));
                    std.mem.writeInt(u32, tb.host_code[branch_patch_pos..][0..4], emitter_rv64.bltu(d.rs1, d.rs2, branch_rel), .little);
                    tb.exit_branch1 = emitExit(tb, &host_offset, target);
                    has_explicit_exit = true;
                    current_pc += decoded.len;
                    break;
                },

                .bgeu => |d| {
                    const target = current_pc +% @as(u32, @bitCast(d.offset));
                    const fallthrough = current_pc + decoded.len;
                    const branch_patch_pos = host_offset;
                    emitter_rv64.emit(tb.host_code, &host_offset, 0); // placeholder
                    tb.exit_branch2 = emitExit(tb, &host_offset, fallthrough);
                    const target_pos = host_offset;
                    const branch_rel = @as(i13, @truncate(@as(isize, @intCast(target_pos - branch_patch_pos))));
                    std.mem.writeInt(u32, tb.host_code[branch_patch_pos..][0..4], emitter_rv64.bgeu(d.rs1, d.rs2, branch_rel), .little);
                    tb.exit_branch1 = emitExit(tb, &host_offset, target);
                    has_explicit_exit = true;
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

        if (!has_explicit_exit) {
            tb.exit_branch1 = emitExit(tb, &host_offset, current_pc);
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

            // ---- Floating-Point Loads & Stores ----
            .flw => |d| {
                const fs_enabled = ((self.vcpu.mstatus >> 13) & 3) != 0;
                if (!fs_enabled) {
                    self.vcpu.injectException(2, pc_before, 0);
                    return true;
                }
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) +% @as(u32, @bitCast(d.offset));
                const res = self.tlb.readU32(vaddr, self.bus);
                if (res.trap) |cause| {
                    self.trap(cause, pc_before, vaddr);
                    return true;
                }
                self.vcpu.fpregs[d.rd] = 0xFFFFFFFF00000000 | @as(u64, res.val);
                self.vcpu.mstatus |= (3 << 13);
            },
            .fld => |d| {
                const fs_enabled = ((self.vcpu.mstatus >> 13) & 3) != 0;
                if (!fs_enabled) {
                    self.vcpu.injectException(2, pc_before, 0);
                    return true;
                }
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) +% @as(u32, @bitCast(d.offset));
                const res_lo = self.tlb.readU32(vaddr, self.bus);
                if (res_lo.trap) |cause| {
                    self.trap(cause, pc_before, vaddr);
                    return true;
                }
                const res_hi = self.tlb.readU32(vaddr + 4, self.bus);
                if (res_hi.trap) |cause| {
                    self.trap(cause, pc_before, vaddr + 4);
                    return true;
                }
                self.vcpu.fpregs[d.rd] = @as(u64, res_lo.val) | (@as(u64, res_hi.val) << 32);
                self.vcpu.mstatus |= (3 << 13);
            },
            .fsw => |d| {
                const fs_enabled = ((self.vcpu.mstatus >> 13) & 3) != 0;
                if (!fs_enabled) {
                    self.vcpu.injectException(2, pc_before, 0);
                    return true;
                }
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) +% @as(u32, @bitCast(d.offset));
                const val = @as(u32, @truncate(self.vcpu.fpregs[d.rs2]));
                const trap_cause = self.tlb.writeU32(vaddr, val, self.bus);
                if (trap_cause) |cause| {
                    self.trap(cause, pc_before, vaddr);
                    return true;
                }
                self.vcpu.mstatus |= (3 << 13);
            },
            .fsd => |d| {
                const fs_enabled = ((self.vcpu.mstatus >> 13) & 3) != 0;
                if (!fs_enabled) {
                    self.vcpu.injectException(2, pc_before, 0);
                    return true;
                }
                const vaddr = @as(u32, @truncate(self.vcpu.getGpr(d.rs1))) +% @as(u32, @bitCast(d.offset));
                const val_lo = @as(u32, @truncate(self.vcpu.fpregs[d.rs2]));
                const val_hi = @as(u32, @truncate(self.vcpu.fpregs[d.rs2] >> 32));
                const trap_lo = self.tlb.writeU32(vaddr, val_lo, self.bus);
                if (trap_lo) |cause| {
                    self.trap(cause, pc_before, vaddr);
                    return true;
                }
                const trap_hi = self.tlb.writeU32(vaddr + 4, val_hi, self.bus);
                if (trap_hi) |cause| {
                    self.trap(cause, pc_before, vaddr + 4);
                    return true;
                }
                self.vcpu.mstatus |= (3 << 13);
            },
            .fp_op => {
                const fs_enabled = ((self.vcpu.mstatus >> 13) & 3) != 0;
                if (!fs_enabled) {
                    self.vcpu.injectException(2, pc_before, 0);
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
                } else if (d.csr == 0x100 or d.csr == 0x300) {
                    const mask: u32 = (1 << 18) | (1 << 19) | (1 << 17) | (3 << 11);
                    if (((self.tlb.mstatus ^ self.vcpu.mstatus) & mask) != 0) {
                        self.tlb.mstatus = self.vcpu.mstatus;
                        self.tlb.flush();
                    } else {
                        self.tlb.mstatus = self.vcpu.mstatus;
                    }
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
                    } else if (d.csr == 0x100 or d.csr == 0x300) {
                        const mask: u32 = (1 << 18) | (1 << 19) | (1 << 17) | (3 << 11);
                        if (((self.tlb.mstatus ^ self.vcpu.mstatus) & mask) != 0) {
                            self.tlb.mstatus = self.vcpu.mstatus;
                            self.tlb.flush();
                        } else {
                            self.tlb.mstatus = self.vcpu.mstatus;
                        }
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
                    } else if (d.csr == 0x100 or d.csr == 0x300) {
                        const mask: u32 = (1 << 18) | (1 << 19) | (1 << 17) | (3 << 11);
                        if (((self.tlb.mstatus ^ self.vcpu.mstatus) & mask) != 0) {
                            self.tlb.mstatus = self.vcpu.mstatus;
                            self.tlb.flush();
                        } else {
                            self.tlb.mstatus = self.vcpu.mstatus;
                        }
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
                } else if (d.csr == 0x100 or d.csr == 0x300) {
                    const mask: u32 = (1 << 18) | (1 << 19) | (1 << 17) | (3 << 11);
                    if (((self.tlb.mstatus ^ self.vcpu.mstatus) & mask) != 0) {
                        self.tlb.mstatus = self.vcpu.mstatus;
                        self.tlb.flush();
                    } else {
                        self.tlb.mstatus = self.vcpu.mstatus;
                    }
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
                    } else if (d.csr == 0x100 or d.csr == 0x300) {
                        const mask: u32 = (1 << 18) | (1 << 19) | (1 << 17) | (3 << 11);
                        if (((self.tlb.mstatus ^ self.vcpu.mstatus) & mask) != 0) {
                            self.tlb.mstatus = self.vcpu.mstatus;
                            self.tlb.flush();
                        } else {
                            self.tlb.mstatus = self.vcpu.mstatus;
                        }
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
                    } else if (d.csr == 0x100 or d.csr == 0x300) {
                        const mask: u32 = (1 << 18) | (1 << 19) | (1 << 17) | (3 << 11);
                        if (((self.tlb.mstatus ^ self.vcpu.mstatus) & mask) != 0) {
                            self.tlb.mstatus = self.vcpu.mstatus;
                            self.tlb.flush();
                        } else {
                            self.tlb.mstatus = self.vcpu.mstatus;
                        }
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
                const mask: u32 = (1 << 18) | (1 << 19) | (1 << 17) | (3 << 11);
                if (self.vcpu.privilege_mode != new_priv or self.tlb.satp != self.vcpu.satp or ((self.tlb.mstatus ^ self.vcpu.mstatus) & mask) != 0) {
                    self.tlb.privilege_mode = new_priv;
                    self.tlb.satp = self.vcpu.satp;
                    self.tlb.mstatus = self.vcpu.mstatus;
                    self.tlb.flush();
                } else {
                    self.tlb.mstatus = self.vcpu.mstatus;
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
                const mask: u32 = (1 << 18) | (1 << 19) | (1 << 17) | (3 << 11);
                if (self.vcpu.privilege_mode != new_priv or self.tlb.satp != self.vcpu.satp or ((self.tlb.mstatus ^ self.vcpu.mstatus) & mask) != 0) {
                    self.tlb.privilege_mode = new_priv;
                    self.tlb.satp = self.vcpu.satp;
                    self.tlb.mstatus = self.vcpu.mstatus;
                    self.tlb.flush();
                } else {
                    self.tlb.mstatus = self.vcpu.mstatus;
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
            if (self.vcpu.checkAndClearTlbFlush()) {
                self.tlb.flush();
            }
            if (self.vcpu.checkAndClearCacheFlush()) {
                self.cache.flush();
            }
            const mask: u32 = (1 << 18) | (1 << 19) | (1 << 17) | (3 << 11);
            if (self.tlb.satp != self.vcpu.satp or self.tlb.privilege_mode != self.vcpu.privilege_mode or ((self.tlb.mstatus ^ self.vcpu.mstatus) & mask) != 0) {
                self.tlb.satp = self.vcpu.satp;
                self.tlb.privilege_mode = self.vcpu.privilege_mode;
                self.tlb.mstatus = self.vcpu.mstatus;
                self.tlb.flush();
            } else {
                self.tlb.mstatus = self.vcpu.mstatus;
            }
            const pc_before = self.vcpu.pc;
            self.pc_history[self.history_idx & 7] = pc_before;
            self.history_idx += 1;
            self.last_pc = pc_before;

            if (self.vcpu.satp != 0 and pc_before >= 0xC0000000) {
                const gp = @as(u32, @truncate(self.vcpu.getGpr(3)));
                if (gp >= 0x80000000 and gp < 0xC0000000) {
                    self.vcpu.setGpr(3, gp +% 0x40000000);
                }
                const tp = @as(u32, @truncate(self.vcpu.getGpr(4)));
                if (tp >= 0x80000000 and tp < 0xC0000000) {
                    self.vcpu.setGpr(4, tp +% 0x40000000);
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
                const ret_pc = @as(u32, @truncate(runBlock(&self.vcpu.regs, @intFromPtr(tb.host_code.ptr))));
                const insn_approx = @max(1, tb.guest_size / 2);
                self.jit_cycles +%= insn_approx;
                self.vcpu.pc = ret_pc;
                count += insn_approx;
                self.total_insn_count +%= insn_approx;

                // If block exited on first instruction due to TLB miss, single-step to refill TLB
                if (ret_pc == pc_before) {
                    const fetch_step = self.tlb.fetchU32(ret_pc, self.bus);
                    if (fetch_step.trap) |cause| {
                        self.trap(cause, ret_pc, ret_pc);
                        continue;
                    }
                    const dec_step = decoder_rv32.decode(fetch_step.val);
                    if (dec_step.insn == .ecall or dec_step.insn == .wfi) {
                        // Handled in regular loop
                    } else {
                        _ = self.executeDecoded(dec_step, fetch_step.val, ret_pc);
                    }
                }
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
                    const ret_pc = @as(u32, @truncate(runBlock(&self.vcpu.regs, @intFromPtr(tb.host_code.ptr))));
                    const insn_approx = @max(1, tb.guest_size / 2);
                    self.jit_cycles +%= insn_approx;
                    self.vcpu.pc = ret_pc;
                    count += insn_approx;
                    self.total_insn_count +%= insn_approx;

                    if (ret_pc == pc_before) {
                        const fetch_step = self.tlb.fetchU32(ret_pc, self.bus);
                        if (fetch_step.trap) |cause| {
                            self.trap(cause, ret_pc, ret_pc);
                            continue;
                        }
                        const dec_step = decoder_rv32.decode(fetch_step.val);
                        if (dec_step.insn == .ecall or dec_step.insn == .wfi) {
                            // Handled in regular loop
                        } else {
                            _ = self.executeDecoded(dec_step, fetch_step.val, ret_pc);
                        }
                    }
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

    // Verify vsscratch (0x240) and vstval (0x243) + scratch_t1 saving
    const save_t0 = @as(*const align(1) u32, @ptrCast(&tb.host_code[0])).* ;
    const load_stval = @as(*const align(1) u32, @ptrCast(&tb.host_code[4])).* ;
    const save_t1 = @as(*const align(1) u32, @ptrCast(&tb.host_code[8])).* ;
    try std.testing.expectEqual(@as(u32, 0x24029073), save_t0); // csrw vsscratch, t0
    try std.testing.expectEqual(@as(u32, 0x243022f3), load_stval); // csrr t0, vstval
    try std.testing.expectEqual(emitter_rv64.sd(5, 6, 288), save_t1); // sd t1, 288(t0)
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

test "Dynarec Inlined SoftTLB Fast-Path Load & Store Emission" {
    var raw_pool: [4096]u8 align(4096) = undefined;
    var cache_inst = block_mod.Cache.init(&raw_pool);
    const tb = try cache_inst.allocateBlock(0x80000000, 1024);
    var host_offset: usize = 0;

    // Emit lw a0, 0(a1) via SoftTLB Fast-Path
    Engine.emitSoftTlbLoad(tb, &host_offset, 0x80000000, 2, 10, 11, 0);
    try std.testing.expect(host_offset > 0);

    // Verify scratch register saves:
    try std.testing.expectEqual(@as(u32, 0x24029073), @as(*const align(1) u32, @ptrCast(&tb.host_code[0])).*); // csrw vsscratch, t0
    try std.testing.expectEqual(@as(u32, 0x243022f3), @as(*const align(1) u32, @ptrCast(&tb.host_code[4])).*); // csrr t0, vstval
    try std.testing.expectEqual(emitter_rv64.sd(5, 6, 288), @as(*const align(1) u32, @ptrCast(&tb.host_code[8])).*); // sd t1, 288(t0)

    // Emit sw a0, 4(a1) via SoftTLB Fast-Path
    const prev_offset = host_offset;
    Engine.emitSoftTlbStore(tb, &host_offset, 0x80000004, 2, 11, 10, 4);
    try std.testing.expect(host_offset > prev_offset);
}

test "Dynarec RV32I Logical, Shift & Comparison Emission" {
    var raw_pool: [4096]u8 align(4096) = undefined;
    var cache_inst = block_mod.Cache.init(&raw_pool);
    const tb = try cache_inst.allocateBlock(0x80000000, 512);
    var host_offset: usize = 0;

    // sllw (sll a0, a1, a2)
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.sllw(10, 11, 12));
    try std.testing.expectEqual(@as(u32, 0x00c5953b), @as(*const align(1) u32, @ptrCast(&tb.host_code[0])).*);

    // srlw (srl a0, a1, a2)
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.srlw(10, 11, 12));
    try std.testing.expectEqual(@as(u32, 0x00c5d53b), @as(*const align(1) u32, @ptrCast(&tb.host_code[4])).*);

    // sraw (sra a0, a1, a2)
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.sraw(10, 11, 12));
    try std.testing.expectEqual(@as(u32, 0x40c5d53b), @as(*const align(1) u32, @ptrCast(&tb.host_code[8])).*);

    // slliw (slli a0, a1, 4)
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.slliw(10, 11, 4));
    try std.testing.expectEqual(@as(u32, 0x0045951b), @as(*const align(1) u32, @ptrCast(&tb.host_code[12])).*);

    // srliw (srli a0, a1, 4)
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.srliw(10, 11, 4));
    try std.testing.expectEqual(@as(u32, 0x0045d51b), @as(*const align(1) u32, @ptrCast(&tb.host_code[16])).*);

    // sraiw (srai a0, a1, 4)
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.sraiw(10, 11, 4));
    try std.testing.expectEqual(@as(u32, 0x4045d51b), @as(*const align(1) u32, @ptrCast(&tb.host_code[20])).*);

    // slt (slt a0, a1, a2)
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.slt(10, 11, 12));
    try std.testing.expectEqual(@as(u32, 0x00c5a533), @as(*const align(1) u32, @ptrCast(&tb.host_code[24])).*);

    // sltu (sltu a0, a1, a2)
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.sltu(10, 11, 12));
    try std.testing.expectEqual(@as(u32, 0x00c5b533), @as(*const align(1) u32, @ptrCast(&tb.host_code[28])).*);

    // xor (xor a0, a1, a2)
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.xor_(10, 11, 12));
    try std.testing.expectEqual(@as(u32, 0x00c5c533), @as(*const align(1) u32, @ptrCast(&tb.host_code[32])).*);

    // or (or a0, a1, a2)
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.or_(10, 11, 12));
    try std.testing.expectEqual(@as(u32, 0x00c5e533), @as(*const align(1) u32, @ptrCast(&tb.host_code[36])).*);

    // and (and a0, a1, a2)
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.and_(10, 11, 12));
    try std.testing.expectEqual(@as(u32, 0x00c5f533), @as(*const align(1) u32, @ptrCast(&tb.host_code[40])).*);
}

test "Dynarec RV32 Branch & Control Flow Emission" {
    var raw_pool: [4096]u8 align(4096) = undefined;
    var cache_inst = block_mod.Cache.init(&raw_pool);
    const tb = try cache_inst.allocateBlock(0x80000000, 512);
    var host_offset: usize = 0;

    // beq a0, a1, +28
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.beq(10, 11, 28));
    try std.testing.expectEqual(@as(u32, 0x00b50e63), @as(*const align(1) u32, @ptrCast(&tb.host_code[0])).*);

    // bne a0, a1, +28
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.bne(10, 11, 28));
    try std.testing.expectEqual(@as(u32, 0x00b51e63), @as(*const align(1) u32, @ptrCast(&tb.host_code[4])).*);

    // blt a0, a1, +28
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.blt(10, 11, 28));
    try std.testing.expectEqual(@as(u32, 0x00b54e63), @as(*const align(1) u32, @ptrCast(&tb.host_code[8])).*);

    // bge a0, a1, +28
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.bge(10, 11, 28));
    try std.testing.expectEqual(@as(u32, 0x00b55e63), @as(*const align(1) u32, @ptrCast(&tb.host_code[12])).*);

    // bltu a0, a1, +28
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.bltu(10, 11, 28));
    try std.testing.expectEqual(@as(u32, 0x00b56e63), @as(*const align(1) u32, @ptrCast(&tb.host_code[16])).*);

    // bgeu a0, a1, +28
    emitter_rv64.emit(tb.host_code, &host_offset, emitter_rv64.bgeu(10, 11, 28));
    try std.testing.expectEqual(@as(u32, 0x00b57e63), @as(*const align(1) u32, @ptrCast(&tb.host_code[20])).*);
}

comptime {
    _ = @import("instruction_tests.zig");
}


