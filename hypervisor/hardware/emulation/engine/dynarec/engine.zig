// Dynamic Binary Translation & Execution Engine Loop.
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
const emit_alu = @import("emit/alu.zig");
const emit_mem = @import("emit/mem.zig");
const translator = @import("translator.zig");
const interpreter = @import("interpreter.zig");
const vcpu_mod = @import("../../vcpu.zig");
const softtlb_mod = @import("../../softtlb.zig");
const bus_mod = @import("../../devices/bus.zig");
const riscv = @import("interface").riscv;

pub const PC_HISTORY_LEN: usize = 8;
pub const PC_HISTORY_MASK: usize = PC_HISTORY_LEN - 1;
pub const BACKWARD_JUMP_YIELD_THRESHOLD: u32 = 16384;
pub const MIN_GUEST_INSN_BYTES: u32 = 2;

pub fn runBlock(regs: *[32]u64, host_code_ptr: usize) usize {
    if (comptime builtin.target.cpu.arch.isRISCV()) {
        const ext = struct {
            extern fn hw_dynarec_run_block(
                r: *[32]u64,
                ptr: usize,
            ) callconv(.c) usize;
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
    pc_history: [PC_HISTORY_LEN]u32 = std.mem.zeroes([PC_HISTORY_LEN]u32),
    history_idx: usize = 0,
    jit_cycles: u64 = 0,
    engine_cycles: u64 = 0,
    consecutive_backward_jumps: u32 = 0,

    pub fn initOnPtr(
        self: *Engine,
        buffer: []u8,
        vcpu: *vcpu_mod.VCpu,
        tlb: *softtlb_mod.SoftTlb,
        bus: *bus_mod.Bus,
    ) void {
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
        self.pc_history = std.mem.zeroes([PC_HISTORY_LEN]u32);
        self.history_idx = 0;
        self.jit_cycles = 0;
        self.engine_cycles = 0;
        self.consecutive_backward_jumps = 0;
        self.cache.initOnPtr(buffer);
    }

    pub fn trap(self: *Engine, cause: u32, fault_pc: u32, stval: u32) void {
        self.vcpu.injectException(cause, fault_pc, stval);
        self.tlb.privilege_mode = self.vcpu.privilege_mode;
        self.tlb.mstatus = self.vcpu.mstatus;
        self.tlb.flush();
    }

    pub const emitExit = emit_alu.emitExit;
    pub const emitFastLoad = emit_mem.emitFastLoad;
    pub const emitFastStore = emit_mem.emitFastStore;

    pub fn emitSoftTlbLoad(
        self: *Engine,
        tb: *block_mod.TranslationBlock,
        host_offset: *usize,
        current_pc: u32,
        op: u3,
        rd: u5,
        rs1: u5,
        imm: i12,
    ) void {
        emit_mem.emitSoftTlbLoad(
            @intFromPtr(&self.tlb.entries[0]),
            tb,
            host_offset,
            current_pc,
            op,
            rd,
            rs1,
            imm,
        );
    }

    pub fn emitSoftTlbStore(
        self: *Engine,
        tb: *block_mod.TranslationBlock,
        host_offset: *usize,
        current_pc: u32,
        op: u3,
        rs1: u5,
        rs2: u5,
        imm: i12,
    ) void {
        emit_mem.emitSoftTlbStore(
            @intFromPtr(&self.tlb.entries[0]),
            tb,
            host_offset,
            current_pc,
            op,
            rs1,
            rs2,
            imm,
        );
    }

    pub fn emitSoftTlbAtomic(
        self: *Engine,
        tb: *block_mod.TranslationBlock,
        host_offset: *usize,
        current_pc: u32,
        funct5: u5,
        aq: u1,
        rl: u1,
        rd: u5,
        rs1: u5,
        rs2: u5,
    ) void {
        emit_mem.emitSoftTlbAtomic(
            @intFromPtr(&self.tlb.entries[0]),
            tb,
            host_offset,
            current_pc,
            funct5,
            aq,
            rl,
            rd,
            rs1,
            rs2,
        );
    }

    pub fn translateBlock(
        self: *Engine,
        start_pc: u32,
    ) !*block_mod.TranslationBlock {
        return translator.translateBlock(self, start_pc);
    }

    pub fn step(self: *Engine) bool {
        return interpreter.step(self);
    }

    pub fn executeDecoded(
        self: *Engine,
        decoded: anytype,
        raw_insn: u32,
        pc_before: u32,
    ) bool {
        return interpreter.executeDecoded(self, decoded, raw_insn, pc_before);
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

    fn runCompiledBlock(
        self: *Engine,
        tb: *block_mod.TranslationBlock,
        pc_before: u32,
        count: *usize,
    ) ?ExitReason {
        const ret_pc = @as(
            u32,
            @truncate(runBlock(&self.vcpu.regs, @intFromPtr(tb.host_code.ptr))),
        );
        // Conservative count estimate using 16-bit RVC minimum size.
        const insn_approx: usize = @max(
            1,
            tb.guest_size / MIN_GUEST_INSN_BYTES,
        );
        self.jit_cycles +%= insn_approx;
        self.vcpu.pc = ret_pc;
        count.* += insn_approx;
        self.total_insn_count +%= insn_approx;

        // Adaptive spinlock throttling: if looping backward extensively,
        // yield slice to other cores.
        if (ret_pc <= pc_before) {
            self.consecutive_backward_jumps += 1;
            if (self.consecutive_backward_jumps >=
                BACKWARD_JUMP_YIELD_THRESHOLD)
            {
                self.consecutive_backward_jumps = 0;
                return ExitReason.yield;
            }
        } else {
            self.consecutive_backward_jumps = 0;
        }

        // If block exited on first instruction due to TLB miss, single-step
        // to refill TLB.
        if (ret_pc == pc_before) {
            const fetch_step = self.tlb.fetchU32(ret_pc, self.bus);
            if (fetch_step.trap) |cause| {
                self.trap(cause, ret_pc, ret_pc);
                return null;
            }
            const dec_step = decoder_rv32.decode(fetch_step.val);
            if (dec_step.insn != .ecall and
                dec_step.insn != .wfi and
                dec_step.insn != .pause)
            {
                _ = self.executeDecoded(dec_step, fetch_step.val, ret_pc);
            }
        }
        return null;
    }

    /// Run JIT/stepped execution loop for a given instruction budget.
    pub fn run(self: *Engine, vcpu: *vcpu_mod.VCpu, budget: usize) ExitReason {
        std.debug.assert(vcpu == self.vcpu);
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
            self.tlb.syncCpuState(
                self.vcpu.satp,
                self.vcpu.privilege_mode,
                self.vcpu.mstatus,
            );

            const pc_before = self.vcpu.pc;
            self.pc_history[self.history_idx & PC_HISTORY_MASK] = pc_before;
            self.history_idx += 1;
            self.last_pc = pc_before;

            // Check if supervisor interrupts can be delivered.
            const sie = (self.vcpu.mstatus & riscv.MSTATUS.SIE) != 0;
            if (self.vcpu.stvec != 0 and
                (self.vcpu.privilege_mode == vcpu_mod.PRIV_USER or
                    (self.vcpu.privilege_mode == vcpu_mod.PRIV_SUPERVISOR and
                        sie)))
            {
                const cur_mip = self.vcpu.getMip();
                const pending = (cur_mip & self.vcpu.sie & self.vcpu.mideleg);
                if (pending != 0) {
                    const s_soft: u5 = riscv.MIP.SSIP_BIT;
                    const s_timer: u5 = riscv.MIP.STIP_BIT;
                    const s_ext: u5 = riscv.MIP.SEIP_BIT;
                    const irq_bit = vcpu_mod.CAUSE_INTERRUPT_RV32;
                    if ((pending & riscv.MIP.SSIP) != 0) {
                        self.vcpu.clearMipBit(s_soft);
                        self.trap(irq_bit | s_soft, pc_before, 0);
                        continue;
                    } else if ((pending & riscv.MIP.STIP) != 0) {
                        self.vcpu.clearMipBit(s_timer);
                        self.last_timer_inject_count = self.total_insn_count;
                        self.last_irq_pc = pc_before;
                        self.trap(irq_bit | s_timer, pc_before, 0);
                        continue;
                    } else if ((pending & riscv.MIP.SEIP) != 0) {
                        self.vcpu.clearMipBit(s_ext);
                        self.trap(irq_bit | s_ext, pc_before, 0);
                        continue;
                    }
                }
            }

            // Tier 1 Dynarec: lookup or translate basic block.
            if (self.cache.lookup(
                pc_before,
                self.vcpu.satp,
                self.vcpu.privilege_mode,
            )) |tb| {
                if (self.runCompiledBlock(tb, pc_before, &count)) |exit_res| {
                    return exit_res;
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
                if (self.vcpu.privilege_mode == vcpu_mod.PRIV_SUPERVISOR) {
                    self.vcpu.pc = pc_before + decoded.len;
                    return ExitReason.ecall;
                }
                const cause: u32 = if (self.vcpu.privilege_mode ==
                    vcpu_mod.PRIV_USER)
                    @backingInt(riscv.Cause.user_environment_call)
                else
                    @backingInt(riscv.Cause.machine_environment_call);
                self.trap(cause, pc_before, 0);
                continue;
            }
            if (decoded.insn == .wfi) {
                if (self.vcpu.privilege_mode == vcpu_mod.PRIV_USER or
                    (self.vcpu.privilege_mode == vcpu_mod.PRIV_SUPERVISOR and
                        (self.vcpu.mstatus & riscv.MSTATUS.TW) != 0))
                {
                    const ill: u32 =
                        @backingInt(riscv.Cause.illegal_instruction);
                    self.trap(ill, pc_before, 0);
                    continue;
                }
                self.vcpu.pc = pc_before + decoded.len;
                return ExitReason.wfi;
            }
            if (decoded.insn == .pause) {
                self.vcpu.pc = pc_before + decoded.len;
                return ExitReason.yield;
            }

            if (self.translateBlock(pc_before)) |tb| {
                if (tb.guest_size > 0 and tb.host_len > 0) {
                    if (self.runCompiledBlock(
                        tb,
                        pc_before,
                        &count,
                    )) |exit_res| {
                        return exit_res;
                    }
                    continue;
                }
            } else |_| {}

            if (!self.executeDecoded(decoded, fetch_res.val, pc_before)) {
                return ExitReason.wfi;
            }
        }
        return ExitReason.normal;
    }
};

fn readInsnAt(buf: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, buf[offset..][0..4], .little);
}

test "Dynarec RV32A atomic and inlined SoftTLB fast-path emission" {
    std.testing.refAllDecls(@This());
    _ = @import("regalloc.zig");
    _ = @import("tests/instruction.zig");
    _ = @import("tests/privilege.zig");
    var vcpu = vcpu_mod.VCpu{ .id = 0, .pc = 0x8000_0000 };
    var tlb: softtlb_mod.SoftTlb = undefined;
    tlb.initOnPtr(0x8000_0000, 0x8000_0000, 4096);
    var bus = bus_mod.Bus{
        .uart = undefined,
        .timer = undefined,
        .pic = undefined,
    };
    const eng = try std.testing.allocator.create(Engine);
    defer std.testing.allocator.destroy(eng);

    var raw_pool: [4096]u8 align(4096) = undefined;
    eng.initOnPtr(&raw_pool, &vcpu, &tlb, &bus);

    const tb = try eng.cache.allocateBlock(0x8000_0000, 0, false, 1024);
    var off: usize = 0;
    const add_op = emitter_rv64.AmoFunct5.ADD;
    eng.emitSoftTlbAtomic(tb, &off, 0x8000_0000, add_op, 0, 0, 10, 11, 12);
    try std.testing.expect(off > 0);
    const s11 = block_mod.HOST_REG_S11;
    try std.testing.expectEqual(
        emitter_rv64.sd(s11, block_mod.HOST_REG_T0, block_mod.VCPU_OFF_T0),
        readInsnAt(tb.host_code, 0),
    );
    try std.testing.expectEqual(
        emitter_rv64.sd(s11, block_mod.HOST_REG_T1, block_mod.VCPU_OFF_T1),
        readInsnAt(tb.host_code, 4),
    );

    const prev_offset = off;
    eng.emitSoftTlbLoad(tb, &off, 0x8000_0000, emit_mem.MemOp.LW, 10, 11, 0);
    try std.testing.expect(off > prev_offset);

    const prev_store = off;
    eng.emitSoftTlbStore(tb, &off, 0x8000_0004, emit_mem.MemOp.SW, 11, 10, 4);
    try std.testing.expect(off > prev_store);
}

test "Dynarec fast stack load and store emission" {
    const cache_inst = try std.testing.allocator.create(cache_mod.Cache);
    defer std.testing.allocator.destroy(cache_inst);
    var raw_pool: [4096]u8 align(4096) = undefined;
    cache_inst.initOnPtr(&raw_pool);
    const tb = try cache_inst.allocateBlock(0x8000_0000, 0, false, 512);
    var host_offset: usize = 0;

    // Emit lw a0, 8(sp) with direct delta 0.
    Engine.emitFastLoad(tb, &host_offset, emit_mem.MemOp.LW, 10, 2, 8, 0);
    try std.testing.expect(host_offset > 0);
    const s11 = block_mod.HOST_REG_S11;
    try std.testing.expectEqual(
        emitter_rv64.sd(s11, block_mod.HOST_REG_T0, block_mod.VCPU_OFF_T0),
        readInsnAt(tb.host_code, 0),
    );
    std.testing.refAllDecls(@This());
}
