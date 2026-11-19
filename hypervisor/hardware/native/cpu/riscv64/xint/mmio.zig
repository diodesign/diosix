// Stage-2 MMIO load/store instruction trap-and-emulate for native RISC-V VMs.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const passthrough = @import("../../../../../core/passthrough.zig");
const riscv = @import("../mod.zig");
const xint = @import("../xint.zig");
const csr_emu = @import("csr.zig");
const pcore = @import("../../../../../core/pcore.zig");
const vcore = @import("../../../../../core/vcore.zig");
const guest_mod = @import("../../../../../core/guest.zig");
const emulation = @import("emulation");

pub const OPCODE_LOAD: usize = 0x03;
pub const OPCODE_STORE: usize = 0x23;

pub const FUNCT3_LB: usize = 0x0;
pub const FUNCT3_LH: usize = 0x1;
pub const FUNCT3_LW: usize = 0x2;
pub const FUNCT3_LD: usize = 0x3;
pub const FUNCT3_LBU: usize = 0x4;
pub const FUNCT3_LHU: usize = 0x5;
pub const FUNCT3_LWU: usize = 0x6;

pub const FUNCT3_SB: usize = 0x0;
pub const FUNCT3_SH: usize = 0x1;
pub const FUNCT3_SW: usize = 0x2;
pub const FUNCT3_SD: usize = 0x3;

pub const RVC_QUAD_MASK: usize = 0x3;
pub const RVC_QUAD_0: usize = 0x0;
pub const RVC_QUAD_2: usize = 0x2;
pub const RVC_FUNCT3_SHIFT: u5 = 13;
pub const RVC_FUNCT3_MASK: usize = 0x7;
pub const RVC_FUNCT3_LW: usize = 0x2;
pub const RVC_FUNCT3_LD: usize = 0x3;
pub const RVC_FUNCT3_SW: usize = 0x6;
pub const RVC_FUNCT3_SD: usize = 0x7;
pub const RVC_INSN_BYTES: usize = 2;
pub const RVC_PRIME_REG_BASE: usize = 8;
pub const RVC_PRIME_REG_MASK: usize = 0x7;
pub const WORD_ALIGN_MASK: usize = 0x3;
pub const HIGH_WORD_SHIFT: u6 = 32;
pub const LOW_WORD_MASK: u64 = 0xffff_ffff;

const AccessKind = enum { load, store };

const DecodedMemOp = struct {
    kind: AccessKind,
    reg: usize,
    rs1: usize,
    imm: isize,
    width: u8,
    unsigned: bool,
    insn_len: usize,
};

fn signExtend12(raw: usize) isize {
    const u12_val: u12 = @truncate(raw);
    const i12_val: i12 = @bitCast(u12_val);
    return @as(isize, i12_val);
}

fn decodeMemInstruction(instr: usize) ?DecodedMemOp {
    if ((instr & riscv.Instr.INSN_32BIT_MASK) != riscv.Instr.INSN_32BIT_MASK) {
        return decodeCompressedMemOp(instr & 0xffff);
    }
    const opcode = instr & riscv.Instr.OPCODE_MASK;
    const funct3 = (instr >> riscv.Instr.FUNCT3_SHIFT) &
        riscv.Instr.FUNCT3_MASK;
    const rs1 = (instr >> riscv.Instr.RS1_SHIFT) & riscv.Instr.RS1_MASK;

    if (opcode == OPCODE_LOAD) {
        const rd = (instr >> riscv.Instr.RD_SHIFT) & riscv.Instr.RD_MASK;
        const imm = signExtend12(instr >> riscv.Instr.CSR_SHIFT);
        const width: u8 = switch (funct3) {
            FUNCT3_LB, FUNCT3_LBU => 1,
            FUNCT3_LH, FUNCT3_LHU => 2,
            FUNCT3_LW, FUNCT3_LWU => 4,
            FUNCT3_LD => 8,
            else => return null,
        };
        const unsigned = switch (funct3) {
            FUNCT3_LBU, FUNCT3_LHU, FUNCT3_LWU => true,
            else => false,
        };
        return .{
            .kind = .load,
            .reg = rd,
            .rs1 = rs1,
            .imm = imm,
            .width = width,
            .unsigned = unsigned,
            .insn_len = riscv.Instr.INSN_SIZE_BYTES,
        };
    }

    if (opcode == OPCODE_STORE) {
        const rs2 = (instr >> riscv.Instr.RS2_SHIFT) & riscv.Instr.REG_MASK;
        const imm_lo = (instr >> riscv.Instr.RD_SHIFT) & riscv.Instr.RD_MASK;
        const imm_hi = (instr >> 25) & 0x7f;
        const imm = signExtend12((imm_hi << 5) | imm_lo);
        const width: u8 = switch (funct3) {
            FUNCT3_SB => 1,
            FUNCT3_SH => 2,
            FUNCT3_SW => 4,
            FUNCT3_SD => 8,
            else => return null,
        };
        return .{
            .kind = .store,
            .reg = rs2,
            .rs1 = rs1,
            .imm = imm,
            .width = width,
            .unsigned = true,
            .insn_len = riscv.Instr.INSN_SIZE_BYTES,
        };
    }

    return null;
}

fn decodeCompressedMemOp(c_insn: usize) ?DecodedMemOp {
    const quad = c_insn & RVC_QUAD_MASK;
    const funct3 = (c_insn >> RVC_FUNCT3_SHIFT) & RVC_FUNCT3_MASK;

    if (quad == RVC_QUAD_0) {
        const rs1 = RVC_PRIME_REG_BASE + ((c_insn >> 7) & RVC_PRIME_REG_MASK);
        const r_d_s2 = RVC_PRIME_REG_BASE +
            ((c_insn >> 2) & RVC_PRIME_REG_MASK);
        if (funct3 == RVC_FUNCT3_LW or funct3 == RVC_FUNCT3_SW) {
            const uimm = (((c_insn >> 6) & 0x1) << 2) |
                (((c_insn >> 10) & 0x7) << 3) |
                (((c_insn >> 5) & 0x1) << 6);
            return .{
                .kind = if (funct3 == RVC_FUNCT3_LW) .load else .store,
                .reg = r_d_s2,
                .rs1 = rs1,
                .imm = @intCast(uimm),
                .width = 4,
                .unsigned = false,
                .insn_len = RVC_INSN_BYTES,
            };
        }
        if (funct3 == RVC_FUNCT3_LD or funct3 == RVC_FUNCT3_SD) {
            const uimm = (((c_insn >> 10) & 0x7) << 3) |
                (((c_insn >> 5) & 0x3) << 6);
            return .{
                .kind = if (funct3 == RVC_FUNCT3_LD) .load else .store,
                .reg = r_d_s2,
                .rs1 = rs1,
                .imm = @intCast(uimm),
                .width = 8,
                .unsigned = false,
                .insn_len = RVC_INSN_BYTES,
            };
        }
    } else if (quad == RVC_QUAD_2) {
        const sp_reg = @backingInt(riscv.Register.sp);
        if (funct3 == RVC_FUNCT3_LW) {
            const rd = (c_insn >> 7) & riscv.Instr.REG_MASK;
            if (rd == 0) return null;
            const uimm = (((c_insn >> 4) & 0x7) << 2) |
                (((c_insn >> 12) & 0x1) << 5) |
                (((c_insn >> 2) & 0x3) << 6);
            return .{
                .kind = .load,
                .reg = rd,
                .rs1 = sp_reg,
                .imm = @intCast(uimm),
                .width = 4,
                .unsigned = false,
                .insn_len = RVC_INSN_BYTES,
            };
        }
        if (funct3 == RVC_FUNCT3_LD) {
            const rd = (c_insn >> 7) & riscv.Instr.REG_MASK;
            if (rd == 0) return null;
            const uimm = (((c_insn >> 5) & 0x3) << 3) |
                (((c_insn >> 12) & 0x1) << 5) |
                (((c_insn >> 2) & 0x7) << 6);
            return .{
                .kind = .load,
                .reg = rd,
                .rs1 = sp_reg,
                .imm = @intCast(uimm),
                .width = 8,
                .unsigned = false,
                .insn_len = RVC_INSN_BYTES,
            };
        }
        if (funct3 == RVC_FUNCT3_SW) {
            const rs2 = (c_insn >> 2) & riscv.Instr.REG_MASK;
            const uimm = (((c_insn >> 9) & 0xf) << 2) |
                (((c_insn >> 7) & 0x3) << 6);
            return .{
                .kind = .store,
                .reg = rs2,
                .rs1 = sp_reg,
                .imm = @intCast(uimm),
                .width = 4,
                .unsigned = true,
                .insn_len = RVC_INSN_BYTES,
            };
        }
        if (funct3 == RVC_FUNCT3_SD) {
            const rs2 = (c_insn >> 2) & riscv.Instr.REG_MASK;
            const uimm = (((c_insn >> 10) & 0x7) << 3) |
                (((c_insn >> 7) & 0x7) << 6);
            return .{
                .kind = .store,
                .reg = rs2,
                .rs1 = sp_reg,
                .imm = @intCast(uimm),
                .width = 8,
                .unsigned = true,
                .insn_len = RVC_INSN_BYTES,
            };
        }
    }
    return null;
}

fn guestBus(g: *guest_mod.Guest) emulation.Bus {
    return .{
        .uart = &g.uart,
        .timer = &g.timer,
        .pic = &g.pic,
        .vsock = &g.vsock,
        .blk = &g.blk,
        .net = &g.net_dev,
    };
}

pub fn hasPendingDeviceIrqForHart(
    g: *guest_mod.Guest,
    hart_id: usize,
) bool {
    if (g.has_host_passthrough) return false;
    var bus = guestBus(g);
    _ = bus.syncDeviceIrqs();
    return g.pic.hasDeliverableIrqForHart(hart_id);
}

pub fn syncVirtualIrqs(vc: *vcore.VirtualCore, g: *guest_mod.Guest) void {
    if (g.has_host_passthrough) return;
    const any_pending = hasPendingDeviceIrqForHart(g, vc.id);
    if (vc.exec_path == .native) {
        if (any_pending) {
            vc.getNativeMachine().hvip |= riscv.HVIP.VSEIP;
        } else {
            vc.getNativeMachine().hvip &= ~@as(usize, riscv.HVIP.VSEIP);
        }
        if (riscv.hasHExtension()) {
            riscv.writeHvip(vc.getNativeMachine().hvip);
        }
    }
}

/// Emulate a Stage-2 guest load/store page fault targeting the virtual MMIO
/// bus on a non-root native guest VM. Returns `true` if handled.
pub fn emulateStage2MmioFault(
    vc: *vcore.VirtualCore,
    irq: xint.IRQ,
    gpa_raw: usize,
    context: *riscv.ThreadContext,
    instr_override: usize,
) bool {
    const g = vc.getGuest();
    if (g.has_host_passthrough or irq.privilege_mode == .user) return false;
    if (irq.cause != .guest_load_page_fault and
        irq.cause != .guest_store_page_fault)
    {
        return false;
    }

    const instr = if (instr_override != 0)
        instr_override
    else
        csr_emu.fetchGuestInstruction(irq.pc);
    if (instr == 0) return false;

    const op = decodeMemInstruction(instr) orelse return false;
    const expected_kind: AccessKind =
        if (irq.cause == .guest_load_page_fault) .load else .store;
    if (op.kind != expected_kind) return false;

    const base_val: usize = if (op.rs1 == 0) 0 else context[op.rs1];
    const eff_addr: usize = @bitCast(@as(isize, @bitCast(base_val)) +% op.imm);
    const gpa: usize = if (gpa_raw == 0)
        eff_addr
    else if ((gpa_raw & WORD_ALIGN_MASK) == 0)
        (gpa_raw | (eff_addr & WORD_ALIGN_MASK))
    else
        gpa_raw;

    const gpa32 = std.math.cast(u32, gpa) orelse return false;
    if (!emulation.Bus.isMmioAddr(gpa32)) return false;

    var bus = guestBus(g);

    if (op.kind == .load) {
        const result: usize = switch (op.width) {
            1 => blk: {
                const b: u8 = @truncate(bus.read(gpa32, 1));
                break :blk if (op.unsigned)
                    @as(usize, b)
                else
                    @bitCast(@as(isize, @as(i8, @bitCast(b))));
            },
            2 => blk: {
                const h: u16 = @truncate(bus.read(gpa32, 2));
                break :blk if (op.unsigned)
                    @as(usize, h)
                else
                    @bitCast(@as(isize, @as(i16, @bitCast(h))));
            },
            4 => blk: {
                const w: u32 = bus.read(gpa32, 4);
                break :blk if (op.unsigned)
                    @as(usize, w)
                else
                    @bitCast(@as(isize, @as(i32, @bitCast(w))));
            },
            8 => blk: {
                const lo: u64 = bus.read(gpa32, 4);
                const hi: u64 = bus.read(gpa32 +| 4, 4);
                break :blk @intCast(lo | (hi << HIGH_WORD_SHIFT));
            },
            else => return false,
        };
        if (op.reg != 0) {
            context[op.reg] = result;
            if (vc.exec_path == .native) {
                vc.getNativeContext()[op.reg] = result;
            }
        }
    } else {
        const val: u64 = if (op.reg == 0) 0 else context[op.reg];
        switch (op.width) {
            1 => bus.write(gpa32, @as(u8, @truncate(val)), 1),
            2 => bus.write(gpa32, @as(u16, @truncate(val)), 2),
            4 => bus.write(gpa32, @truncate(val), 4),
            8 => {
                bus.write(gpa32, @truncate(val & LOW_WORD_MASK), 4);
                bus.write(
                    gpa32 +| 4,
                    @truncate(val >> HIGH_WORD_SHIFT),
                    4,
                );
            },
            else => return false,
        }
        passthrough.maybeNotifyGuestPlicWrite(g, gpa32, @truncate(val));
    }

    syncVirtualIrqs(vc, g);

    if (vc.exec_path == .native) {
        vc.getNativeMachine().mepc = irq.pc + op.insn_len;
        riscv.writeMepc(vc.getNativeMachine().mepc);
    }
    pcore.this().trap_loop_count = 0;
    return true;
}

test "Stage-2 MMIO trap-and-emulate decodes RV64/RVC loads and stores" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    riscv.initMockHardware();

    const physmem = @import("../../../../../core/physmem.zig");
    var phys_test = try physmem.initForTest(testing.allocator, 512);
    defer phys_test.deinit();

    const g = try guest_mod.createGuest(
        testing.allocator,
        false,
        false,
        null,
        0x8000_0000,
        0,
        0x10_0000,
        .riscv64,
    );
    defer g.deinit();

    var vc = vcore.VirtualCore.init(0, g, 0x8000_0000, 0x8000_1000, .normal);
    var ctx: riscv.ThreadContext = @splat(0);

    // 1. LW a0 (x10), 0(a1 (x11)) reading VirtIO-Blk Magic at 0x10004000.
    ctx[11] = 0x1000_4000;
    const lw_a0_0_a1: usize = (FUNCT3_LW << riscv.Instr.FUNCT3_SHIFT) |
        (11 << riscv.Instr.RS1_SHIFT) |
        (10 << riscv.Instr.RD_SHIFT) |
        OPCODE_LOAD;
    const load_irq = xint.IRQ{
        .severity = .non_fatal,
        .privilege_mode = .supervisor,
        .irq_type = .exception,
        .cause = .guest_load_page_fault,
        .pc = 0x8000_0100,
        .sp = 0x8000_9000,
        .val = 0x1000_4000,
    };

    // U-mode faults must not be emulated as privileged MMIO.
    var user_irq = load_irq;
    user_irq.privilege_mode = .user;
    try testing.expect(!emulateStage2MmioFault(
        &vc,
        user_irq,
        0x1000_4000,
        &ctx,
        lw_a0_0_a1,
    ));

    try testing.expect(emulateStage2MmioFault(
        &vc,
        load_irq,
        0x1000_4000,
        &ctx,
        lw_a0_0_a1,
    ));
    try testing.expectEqual(@as(usize, 0x7472_6976), ctx[10]);
    try testing.expectEqual(
        @as(u64, 0x8000_0104),
        vc.getNativeMachine().mepc,
    );

    // 2. LBU a0 (x10), 5(a1 (x11)) reading UART LSR at 0x10000005 when
    // mtval2<<2 gives 4-byte aligned 0x10000004.
    ctx[11] = 0x1000_0000;
    const lbu_a0_5_a1: usize = (5 << riscv.Instr.CSR_SHIFT) |
        (11 << riscv.Instr.RS1_SHIFT) |
        (FUNCT3_LBU << riscv.Instr.FUNCT3_SHIFT) |
        (10 << riscv.Instr.RD_SHIFT) |
        OPCODE_LOAD;
    try testing.expect(emulateStage2MmioFault(
        &vc,
        load_irq,
        0x1000_0004,
        &ctx,
        lbu_a0_5_a1,
    ));
    try testing.expectEqual(@as(usize, 0x60), ctx[10]);

    // 3. SB a2 (x12), 0(a1 (x11)) writing 'Z' to UART THR at 0x10000000.
    ctx[11] = 0x1000_0000;
    ctx[12] = 'Z';
    const sb_a2_0_a1: usize = (12 << riscv.Instr.RS2_SHIFT) |
        (11 << riscv.Instr.RS1_SHIFT) |
        (FUNCT3_SB << riscv.Instr.FUNCT3_SHIFT) |
        OPCODE_STORE;
    const store_irq = xint.IRQ{
        .severity = .non_fatal,
        .privilege_mode = .supervisor,
        .irq_type = .exception,
        .cause = .guest_store_page_fault,
        .pc = 0x8000_0108,
        .sp = 0x8000_9000,
        .val = 0x1000_0000,
    };
    try testing.expect(emulateStage2MmioFault(
        &vc,
        store_irq,
        0x1000_0000,
        &ctx,
        sb_a2_0_a1,
    ));
    try testing.expectEqual(@as(?u8, 'Z'), g.console_tx.popByte());
}
