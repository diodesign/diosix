// RV32 Single-Step Interpreter & Instruction Dispatcher.
//
// Executes decoded guest RV32 instructions when stepping or handling JIT
// fallbacks.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const decoder_rv32 = @import("../decoders/rv32.zig");
const vcpu_mod = @import("../../vcpu.zig");
const sys = @import("interpreter/sys.zig");
const mem = @import("interpreter/mem.zig");
const riscv = @import("interface").riscv;

const u32Gpr = sys.u32Gpr;
const i32Gpr = sys.i32Gpr;
const execCsr = sys.execCsr;
const execAmo = mem.execAmo;
const execFpLoad = sys.execFpLoad;
const execFpStore = sys.execFpStore;
const execVecMem = sys.execVecMem;

pub const SHIFT_MASK_32: u32 = 0x1f;
pub const WORD_BITS: u6 = 32;
pub const DIV_BY_ZERO_RESULT: u32 = 0xffff_ffff;
pub const DIV_OVERFLOW_RESULT: u32 = 0x8000_0000;
pub const UPPER20_MASK: u32 = 0xfffff;
pub const PAGE_SHIFT: u5 = 12;

inline fn csrR(
    self: anytype,
    pc: u32,
    d: decoder_rv32.CsrRType,
    w: bool,
    op: sys.CsrOp,
) bool {
    return execCsr(self, pc, d.csr, d.rd, u32Gpr(self, d.rs1), w, op);
}

inline fn csrI(
    self: anytype,
    pc: u32,
    d: decoder_rv32.CsrIType,
    w: bool,
    op: sys.CsrOp,
) bool {
    return execCsr(self, pc, d.csr, d.rd, d.uimm, w, op);
}

/// Single-step interpretation/dispatch step for guest virtual CPU.
pub fn step(self: anytype) bool {
    self.tlb.syncCpuState(
        self.vcpu.satp,
        self.vcpu.privilege_mode,
        self.vcpu.mstatus,
    );

    const pc_before = self.vcpu.pc;
    const fetch_res = self.tlb.fetchU32(pc_before, self.bus);
    if (fetch_res.trap) |cause| {
        self.trap(cause, pc_before, pc_before);
        return true;
    }

    const decoded = decoder_rv32.decode(fetch_res.val);
    return executeDecoded(self, decoded, fetch_res.val, pc_before);
}

pub fn executeDecoded(
    self: anytype,
    decoded: anytype,
    raw_insn: u32,
    pc_before: u32,
) bool {
    const next_pc = pc_before + decoded.len;
    const vcpu = self.vcpu;

    switch (decoded.insn) {
        .add => |d| {
            vcpu.setGpr(d.rd, u32Gpr(self, d.rs1) +% u32Gpr(self, d.rs2));
        },
        .sub => |d| {
            vcpu.setGpr(d.rd, u32Gpr(self, d.rs1) -% u32Gpr(self, d.rs2));
        },
        .sll => |d| {
            const sh: u5 = @truncate(u32Gpr(self, d.rs2) & SHIFT_MASK_32);
            vcpu.setGpr(d.rd, u32Gpr(self, d.rs1) *% (@as(u32, 1) << sh));
        },
        .slt => |d| vcpu.setGpr(
            d.rd,
            if (i32Gpr(self, d.rs1) < i32Gpr(self, d.rs2)) 1 else 0,
        ),
        .sltu => |d| vcpu.setGpr(
            d.rd,
            if (u32Gpr(self, d.rs1) < u32Gpr(self, d.rs2)) 1 else 0,
        ),
        .xor_ => |d| {
            vcpu.setGpr(d.rd, u32Gpr(self, d.rs1) ^ u32Gpr(self, d.rs2));
        },
        .srl => |d| {
            const sh: u5 = @truncate(u32Gpr(self, d.rs2) & SHIFT_MASK_32);
            vcpu.setGpr(d.rd, u32Gpr(self, d.rs1) >> sh);
        },
        .sra => |d| {
            const sh: u5 = @truncate(u32Gpr(self, d.rs2) & SHIFT_MASK_32);
            vcpu.setGpr(d.rd, @as(u32, @bitCast(i32Gpr(self, d.rs1) >> sh)));
        },
        .or_ => |d| {
            vcpu.setGpr(d.rd, u32Gpr(self, d.rs1) | u32Gpr(self, d.rs2));
        },
        .and_ => |d| {
            vcpu.setGpr(d.rd, u32Gpr(self, d.rs1) & u32Gpr(self, d.rs2));
        },

        .mul => |d| {
            const p = @as(u64, u32Gpr(self, d.rs1)) *%
                @as(u64, u32Gpr(self, d.rs2));
            vcpu.setGpr(d.rd, @as(u32, @truncate(p)));
        },
        .mulh => |d| {
            const p = @as(
                u64,
                @bitCast(@as(i64, i32Gpr(self, d.rs1)) *%
                    @as(i64, i32Gpr(self, d.rs2))),
            );
            vcpu.setGpr(d.rd, @as(u32, @truncate(p >> WORD_BITS)));
        },
        .mulhsu => |d| {
            const s1 = @as(i64, i32Gpr(self, d.rs1));
            const val2 = @as(i64, @bitCast(@as(u64, u32Gpr(self, d.rs2))));
            const p = @as(u64, @bitCast(s1 *% val2));
            vcpu.setGpr(d.rd, @as(u32, @truncate(p >> WORD_BITS)));
        },
        .mulhu => |d| {
            const p = @as(u64, u32Gpr(self, d.rs1)) *%
                @as(u64, u32Gpr(self, d.rs2));
            vcpu.setGpr(d.rd, @as(u32, @truncate(p >> WORD_BITS)));
        },
        .div => |d| {
            const num = i32Gpr(self, d.rs1);
            const den = i32Gpr(self, d.rs2);
            if (den == 0) {
                vcpu.setGpr(d.rd, DIV_BY_ZERO_RESULT);
            } else if (num == std.math.minInt(i32) and den == -1) {
                vcpu.setGpr(d.rd, DIV_OVERFLOW_RESULT);
            } else {
                vcpu.setGpr(d.rd, @as(u32, @bitCast(@divTrunc(num, den))));
            }
        },
        .divu => |d| {
            const num = u32Gpr(self, d.rs1);
            const den = u32Gpr(self, d.rs2);
            vcpu.setGpr(d.rd, if (den == 0) DIV_BY_ZERO_RESULT else num / den);
        },
        .rem => |d| {
            const num = i32Gpr(self, d.rs1);
            const den = i32Gpr(self, d.rs2);
            if (den == 0) {
                vcpu.setGpr(d.rd, @as(u32, @bitCast(num)));
            } else if (num == std.math.minInt(i32) and den == -1) {
                vcpu.setGpr(d.rd, 0);
            } else {
                vcpu.setGpr(d.rd, @as(u32, @bitCast(@rem(num, den))));
            }
        },
        .remu => |d| {
            const num = u32Gpr(self, d.rs1);
            const den = u32Gpr(self, d.rs2);
            vcpu.setGpr(d.rd, if (den == 0) num else num % den);
        },

        .addi => |d| vcpu.setGpr(
            d.rd,
            u32Gpr(self, d.rs1) +% @as(u32, @bitCast(d.imm)),
        ),
        .slti => |d| vcpu.setGpr(
            d.rd,
            if (i32Gpr(self, d.rs1) < d.imm) 1 else 0,
        ),
        .sltiu => |d| vcpu.setGpr(
            d.rd,
            if (u32Gpr(self, d.rs1) < @as(u32, @bitCast(d.imm))) 1 else 0,
        ),
        .xori => |d| vcpu.setGpr(
            d.rd,
            u32Gpr(self, d.rs1) ^ @as(u32, @bitCast(d.imm)),
        ),
        .ori => |d| vcpu.setGpr(
            d.rd,
            u32Gpr(self, d.rs1) | @as(u32, @bitCast(d.imm)),
        ),
        .andi => |d| vcpu.setGpr(
            d.rd,
            u32Gpr(self, d.rs1) & @as(u32, @bitCast(d.imm)),
        ),
        .slli => |d| vcpu.setGpr(
            d.rd,
            u32Gpr(self, d.rs1) *% (@as(u32, 1) << d.shamt),
        ),
        .srli => |d| vcpu.setGpr(d.rd, u32Gpr(self, d.rs1) >> d.shamt),
        .srai => |d| vcpu.setGpr(
            d.rd,
            @as(u32, @bitCast(i32Gpr(self, d.rs1) >> d.shamt)),
        ),

        .lui => |d| vcpu.setGpr(
            d.rd,
            (@as(u32, @bitCast(d.imm)) & UPPER20_MASK) << PAGE_SHIFT,
        ),
        .auipc => |d| vcpu.setGpr(
            d.rd,
            pc_before +%
                ((@as(u32, @bitCast(d.imm)) & UPPER20_MASK) << PAGE_SHIFT),
        ),

        .lb => |d| if (!mem.execLb(self, pc_before, d)) return true,
        .lbu => |d| if (!mem.execLbu(self, pc_before, d)) return true,
        .lh => |d| if (!mem.execLh(self, pc_before, d)) return true,
        .lhu => |d| if (!mem.execLhu(self, pc_before, d)) return true,
        .lw => |d| if (!mem.execLw(self, pc_before, d)) return true,
        .sb => |d| if (!mem.execSb(self, pc_before, d)) return true,
        .sh => |d| if (!mem.execSh(self, pc_before, d)) return true,
        .sw => |d| if (!mem.execSw(self, pc_before, d)) return true,

        .flw => |d| if (!execFpLoad(self, pc_before, d, false)) return true,
        .fld => |d| if (!execFpLoad(self, pc_before, d, true)) return true,
        .fsw => |d| if (!execFpStore(self, pc_before, d, false)) return true,
        .fsd => |d| if (!execFpStore(self, pc_before, d, true)) return true,
        .fp_op => if ((vcpu.mstatus & vcpu_mod.MSTATUS_FS_MASK_U32) == 0) {
            self.trap(sys.CAUSE_ILLEGAL_INSN, pc_before, 0);
            return true;
        },

        .jal => |d| {
            if (d.rd != 0) vcpu.setGpr(d.rd, next_pc);
            vcpu.pc = pc_before +% @as(u32, @bitCast(d.offset));
            return true;
        },
        .jalr => |d| {
            const target = (u32Gpr(self, d.rs1) +%
                @as(u32, @bitCast(d.offset))) & ~@as(u32, 1);
            if (d.rd != 0) vcpu.setGpr(d.rd, next_pc);
            vcpu.pc = target;
            return true;
        },
        .beq => |d| if (vcpu.getGpr(d.rs1) == vcpu.getGpr(d.rs2)) {
            vcpu.pc = pc_before +% @as(u32, @bitCast(d.offset));
            return true;
        },
        .bne => |d| if (vcpu.getGpr(d.rs1) != vcpu.getGpr(d.rs2)) {
            vcpu.pc = pc_before +% @as(u32, @bitCast(d.offset));
            return true;
        },
        .blt => |d| if (i32Gpr(self, d.rs1) < i32Gpr(self, d.rs2)) {
            vcpu.pc = pc_before +% @as(u32, @bitCast(d.offset));
            return true;
        },
        .bge => |d| if (i32Gpr(self, d.rs1) >= i32Gpr(self, d.rs2)) {
            vcpu.pc = pc_before +% @as(u32, @bitCast(d.offset));
            return true;
        },
        .bltu => |d| if (u32Gpr(self, d.rs1) < u32Gpr(self, d.rs2)) {
            vcpu.pc = pc_before +% @as(u32, @bitCast(d.offset));
            return true;
        },
        .bgeu => |d| if (u32Gpr(self, d.rs1) >= u32Gpr(self, d.rs2)) {
            vcpu.pc = pc_before +% @as(u32, @bitCast(d.offset));
            return true;
        },

        .csrrw => |d| if (!csrR(self, pc_before, d, true, .write)) return true,
        .csrrs => |d| {
            if (!csrR(self, pc_before, d, d.rs1 != 0, .set)) return true;
        },
        .csrrc => |d| {
            if (!csrR(self, pc_before, d, d.rs1 != 0, .clear)) return true;
        },
        .csrrwi => |d| if (!csrI(self, pc_before, d, true, .write)) return true,
        .csrrsi => |d| {
            if (!csrI(self, pc_before, d, d.uimm != 0, .set)) return true;
        },
        .csrrci => |d| {
            if (!csrI(self, pc_before, d, d.uimm != 0, .clear)) return true;
        },

        .vsetvli => |d| {
            if ((vcpu.mstatus & vcpu_mod.MSTATUS_VS_MASK_U32) == 0) {
                self.trap(sys.CAUSE_ILLEGAL_INSN, pc_before, 0);
                return true;
            }
            const req = if (d.rs1 != 0) u32Gpr(self, d.rs1) else sys.VREG_BYTES;
            vcpu.vl = @min(req, sys.VREG_BYTES);
            if (d.rd != 0) vcpu.setGpr(d.rd, vcpu.vl);
            vcpu.pc = next_pc;
            return true;
        },
        .vload => |d| {
            execVecMem(self, pc_before, next_pc, d.rs1, d.vd, false);
            return true;
        },
        .vstore => |d| {
            execVecMem(self, pc_before, next_pc, d.rs1, d.vs3, true);
            return true;
        },
        .vector_op => |d| {
            if ((vcpu.mstatus & vcpu_mod.MSTATUS_VS_MASK_U32) == 0) {
                self.trap(sys.CAUSE_ILLEGAL_INSN, pc_before, 0);
                return true;
            }
            if (d.rd != d.rs1) {
                @memcpy(vcpu.vregs[d.rd][0..], vcpu.vregs[d.rs1][0..]);
            }
            vcpu.pc = next_pc;
            return true;
        },

        .lr_w => |d| {
            mem.execLrW(self, pc_before, next_pc, d);
            return true;
        },
        .sc_w => |d| {
            mem.execScW(self, pc_before, next_pc, d);
            return true;
        },
        .amoswap_w => |d| execAmo(self, pc_before, next_pc, d, .swap),
        .amoadd_w => |d| execAmo(self, pc_before, next_pc, d, .add),
        .amoxor_w => |d| execAmo(self, pc_before, next_pc, d, .xor),
        .amoand_w => |d| execAmo(self, pc_before, next_pc, d, .and_op),
        .amoor_w => |d| execAmo(self, pc_before, next_pc, d, .or_op),
        .amomin_w => |d| execAmo(self, pc_before, next_pc, d, .min),
        .amomax_w => |d| execAmo(self, pc_before, next_pc, d, .max),
        .amominu_w => |d| execAmo(self, pc_before, next_pc, d, .minu),
        .amomaxu_w => |d| execAmo(self, pc_before, next_pc, d, .maxu),

        .sret => {
            sys.execSret(self, pc_before);
            return true;
        },
        .mret => {
            sys.execMret(self, pc_before);
            return true;
        },
        .ecall => {
            const cause: u32 = switch (vcpu.privilege_mode) {
                vcpu_mod.PRIV_USER => sys.CAUSE_USER_ECALL,
                vcpu_mod.PRIV_SUPERVISOR => sys.CAUSE_SUPERVISOR_ECALL,
                else => sys.CAUSE_MACHINE_ECALL,
            };
            self.trap(cause, pc_before, 0);
            return true;
        },
        .ebreak => {
            self.trap(sys.CAUSE_BREAKPOINT, pc_before, 0);
            return true;
        },
        .wfi => {
            if (vcpu.privilege_mode == vcpu_mod.PRIV_USER or
                (vcpu.privilege_mode == vcpu_mod.PRIV_SUPERVISOR and
                    (vcpu.mstatus & riscv.MSTATUS.TW) != 0))
            {
                self.trap(sys.CAUSE_ILLEGAL_INSN, pc_before, 0);
                return true;
            }
            vcpu.pc = next_pc;
            return false;
        },
        .sfence_vma => {
            if (vcpu.privilege_mode == vcpu_mod.PRIV_USER or
                (vcpu.privilege_mode == vcpu_mod.PRIV_SUPERVISOR and
                    (vcpu.mstatus & riscv.MSTATUS.TVM) != 0))
            {
                self.trap(sys.CAUSE_ILLEGAL_INSN, pc_before, 0);
                return true;
            }
            if (comptime builtin.target.cpu.arch.isRISCV()) {
                asm volatile ("sfence.vma");
            }
            self.tlb.flush();
            vcpu.pc = next_pc;
            return true;
        },
        .fence => {
            if (comptime builtin.target.cpu.arch.isRISCV()) {
                asm volatile ("fence rw, rw");
            }
            vcpu.pc = next_pc;
            return true;
        },
        .fence_i => {
            if (comptime builtin.target.cpu.arch.isRISCV()) {
                asm volatile ("fence.i");
            }
            self.tlb.flush();
            self.cache.flush();
            vcpu.pc = next_pc;
            return true;
        },
        .pause => {
            std.atomic.spinLoopHint();
            vcpu.pc = next_pc;
            return true;
        },
        else => {
            self.last_fault_pc = pc_before;
            self.last_fault_cause = sys.CAUSE_ILLEGAL_INSN;
            self.last_fault_val = raw_insn;
            self.trap(sys.CAUSE_ILLEGAL_INSN, pc_before, raw_insn);
            return true;
        },
    }
    vcpu.pc = next_pc;
    return true;
}

test "interpreter u32Gpr, i32Gpr, and self-referential vector_op" {
    std.testing.refAllDecls(@This());
    _ = mem;

    var vcpu = vcpu_mod.VCpu{
        .id = 0,
        .pc = 0x8000_0000,
        .mstatus = vcpu_mod.MSTATUS_VS_MASK_U32,
    };
    vcpu.setGpr(10, 0xffff_fffe);
    vcpu.vregs[5][0] = 0x42;

    const softtlb_mod = @import("../../softtlb.zig");
    const bus_mod = @import("../../devices/bus.zig");
    const cache_mod = @import("cache.zig");
    const MockEnv = struct {
        vcpu: *vcpu_mod.VCpu,
        tlb: *softtlb_mod.SoftTlb = undefined,
        bus: *bus_mod.Bus = undefined,
        cache: cache_mod.Cache = undefined,
        last_fault_pc: u32 = 0,
        last_fault_cause: u32 = 0,
        last_fault_val: u32 = 0,
        pub fn trap(_: *@This(), _: u32, _: u32, _: u32) void {}
    };
    var env = MockEnv{ .vcpu = &vcpu };

    try std.testing.expectEqual(@as(u32, 0xffff_fffe), u32Gpr(&env, 10));
    try std.testing.expectEqual(@as(i32, -2), i32Gpr(&env, 10));

    // Verify vector_op with rd == rs1 does not panic on overlapping @memcpy.
    const vec_dec = decoder_rv32.DecodedInsn{
        .insn = .{ .vector_op = .{ .rd = 5, .rs1 = 5, .rs2 = 5 } },
        .len = 4,
    };
    try std.testing.expect(executeDecoded(&env, vec_dec, 0, 0x8000_0000));
    try std.testing.expectEqual(@as(u8, 0x42), vcpu.vregs[5][0]);
}
