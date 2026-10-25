// Guest instruction and CSR trap-and-emulate routines for RISC-V.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("../mod.zig");
const pcore = @import("../../../../../core/pcore.zig");
const vcore = @import("../../../../../core/vcore.zig");
const scheduler = @import("../../../../../core/scheduler.zig");

/// Outcome of attempting to emulate a trapped instruction from a guest.
pub const EmulationOutcome = enum {
    /// Instruction is not an emulated CSR/system instruction; reflect to guest.
    not_handled,
    /// Instruction was emulated and `mepc` advanced; resume guest execution.
    handled,
};

const CSR_PRIV_SHIFT: u4 = 8;
const CSR_PRIV_MASK: usize = 0x3;

/// Safely fetch an instruction from guest memory, accounting for potential
/// 2-byte parcel alignment if the guest PC is not 4-byte aligned.
pub fn fetchGuestInstruction(pc: usize) usize {
    const pcpu = pcore.this();
    pcpu.probing_active = true;
    pcpu.probe_failed = false;
    defer pcpu.probing_active = false;

    var instr: usize = 0;

    if ((pc & riscv.Instr.PARCEL_ALIGN_MASK) != 0) {
        // Misaligned PC: fetch as 16-bit parcels to avoid alignment faults.
        const lower = riscv.hlv_hu(pc);
        if (pcpu.probe_failed) return 0;
        instr = lower;

        // Check if it is a 32-bit instruction (lowest 2 bits are 0b11).
        if ((lower & riscv.Instr.INSN_32BIT_MASK) ==
            riscv.Instr.INSN_32BIT_MASK)
        {
            const upper = riscv.hlv_hu(pc + riscv.Instr.PARCEL_ALIGN_MASK);
            if (pcpu.probe_failed) return 0;
            instr |= (@as(usize, upper) << 16);
        }
    } else {
        // Aligned PC: safe to fetch 32-bit word directly.
        instr = riscv.hlv_wu(pc);
        if (pcpu.probe_failed) return 0;
    }

    return instr;
}

fn isSiselectCsr(csr: usize) bool {
    return switch (csr) {
        riscv.CSR.VSISELECT_LEGACY,
        riscv.CSR.SISELECT,
        riscv.CSR.VSISELECT,
        riscv.CSR.SISELECTH,
        riscv.CSR.VSISELECTH,
        => true,
        else => false,
    };
}

fn isEnvcfgCsr(csr: usize) bool {
    return csr == riscv.CSR.SENVCFG;
}

pub fn isEmulatedCsr(csr: usize) bool {
    return switch (csr) {
        riscv.CSR.SEED,
        riscv.CSR.SIREG_LEGACY,
        riscv.CSR.VSISELECT_LEGACY,
        riscv.CSR.VSIREG_LEGACY,
        riscv.CSR.SISELECT,
        riscv.CSR.SIREG,
        riscv.CSR.VSISELECT,
        riscv.CSR.VSIREG,
        riscv.CSR.SISELECTH,
        riscv.CSR.SIREGH,
        riscv.CSR.VSISELECTH,
        riscv.CSR.VSIREGH,
        riscv.CSR.SENVCFG,
        riscv.CSR.STIMECMP,
        => true,
        else => false,
    };
}

const SEED_OPST_ES16: usize = 0x80000000;
const SEED_ENTROPY_MASK: usize = 0xffff;

fn readEmulatedCsr(vc: *vcore.VirtualCore, csr: usize) usize {
    if (csr == riscv.CSR.SEED) {
        // RISC-V Entropy Source Extension (Zkr): return ES16 status
        // (0x80000000) combined with 16 bits of hardware timer entropy.
        const time_now = riscv.readTime();
        const entropy = (time_now ^ (time_now >> 16)) & SEED_ENTROPY_MASK;
        return SEED_OPST_ES16 | entropy;
    }
    if (isSiselectCsr(csr)) return vc.getNativeSiselect().*;
    if (isEnvcfgCsr(csr)) return vc.getNativeGuestState().vsenvcfg;
    if (csr == riscv.CSR.STIMECMP) return vc.getNativeGuestState().vstimecmp;
    return 0;
}

fn writeEmulatedCsr(vc: *vcore.VirtualCore, csr: usize, new_val: usize) void {
    if (isSiselectCsr(csr)) {
        vc.getNativeSiselect().* = new_val;
    } else if (isEnvcfgCsr(csr)) {
        vc.getNativeGuestState().vsenvcfg = new_val;
    } else if (csr == riscv.CSR.STIMECMP) {
        vc.getNativeGuestState().vstimecmp = new_val;
        vc.getNativeMachine().hvip &= ~@as(usize, riscv.HVIP.VSTIP);
    }
}

/// Emulate a trapped CSR read/modify/write instruction.
pub fn emulateCsrAccess(
    vc: *vcore.VirtualCore,
    instr: usize,
    context: *riscv.ThreadContext,
) void {
    const csr = (instr >> riscv.Instr.CSR_SHIFT) & riscv.Instr.CSR_MASK;
    const rd = (instr >> riscv.Instr.RD_SHIFT) & riscv.Instr.RD_MASK;
    const rs1 = (instr >> riscv.Instr.RS1_SHIFT) & riscv.Instr.RS1_MASK;
    const funct3 = (instr >> riscv.Instr.FUNCT3_SHIFT) &
        riscv.Instr.FUNCT3_MASK;

    const old_val = readEmulatedCsr(vc, csr);
    const operand: usize = switch (funct3) {
        riscv.Instr.FUNCT3_CSRRW,
        riscv.Instr.FUNCT3_CSRRS,
        riscv.Instr.FUNCT3_CSRRC,
        => if (rs1 == 0) 0 else context[rs1],
        else => rs1,
    };

    switch (funct3) {
        riscv.Instr.FUNCT3_CSRRW, riscv.Instr.FUNCT3_CSRRWI => {
            writeEmulatedCsr(vc, csr, operand);
        },
        riscv.Instr.FUNCT3_CSRRS, riscv.Instr.FUNCT3_CSRRSI => {
            if (rs1 != 0) writeEmulatedCsr(vc, csr, old_val | operand);
        },
        riscv.Instr.FUNCT3_CSRRC, riscv.Instr.FUNCT3_CSRRCI => {
            if (rs1 != 0) writeEmulatedCsr(vc, csr, old_val & ~operand);
        },
        else => {},
    }

    if (rd != 0) {
        context[rd] = old_val;
        vc.getNativeContext()[rd] = old_val;
    }

    vc.getNativeMachine().mepc += riscv.Instr.INSN_SIZE_BYTES;
    riscv.writeMepc(vc.getNativeMachine().mepc);
    pcore.this().trap_loop_count = 0;

    if (csr == riscv.CSR.STIMECMP) {
        const vstc = vc.getNativeGuestState().vstimecmp;
        if (riscv.riscv_supports_sstc) {
            riscv.writeVstimecmp(vstc);
            const hvip = riscv.readHvip() & ~@as(usize, riscv.HVIP.VSTIP);
            riscv.writeHvip(hvip);
        }
        if (vstc != 0 and vstc != riscv.TIMER_INFINITY) {
            riscv.setTimer(vstc);
        }
    }
}

fn emulateWfi(vc: *vcore.VirtualCore) void {
    const pcpu = pcore.this();
    pcpu.trap_loop_count = 0;
    vc.getNativeMachine().mepc += riscv.Instr.INSN_SIZE_BYTES;

    // Route physical PLIC interrupts pending on this hart to Root VSEIP.
    const mip_val = riscv.readMip();
    const raw_ext = (mip_val & (riscv.MIP.SEIP | riscv.MIP.MEIP)) != 0;
    const ext_pending = raw_ext and vc.guest.is_root;
    if (raw_ext) {
        if (vc.guest.is_root) {
            vc.getNativeMachine().hvip |= riscv.HVIP.VSEIP;
            const mask = ~@as(usize, riscv.MIE.MEIE | riscv.MIE.SEIE);
            riscv.writeMie(riscv.MIE.ALL_PHYSICAL & mask);
        } else {
            _ = @import("interrupt.zig").deliverRootExternalIrq(pcpu);
        }
    } else if (vc.guest.is_root) {
        vc.getNativeMachine().hvip &= ~@as(usize, riscv.HVIP.VSEIP);
        riscv.writeMie(riscv.MIE.ALL_PHYSICAL);
    }

    // Do not block if virtual or physical interrupts are already pending.
    const gs = vc.getNativeGuestState();
    const timer_expired = (gs.vstimecmp != 0 and
        gs.vstimecmp != riscv.TIMER_INFINITY and
        riscv.readTime() >= gs.vstimecmp);
    const virt_mask =
        riscv.HVIP.VSSIP | riscv.HVIP.VSTIP | riscv.HVIP.VSEIP;
    const has_ipi = @atomicLoad(bool, &vc.pending_ipi, .acquire);
    const ipi_bit: usize = if (has_ipi) riscv.HVIP.VSSIP else 0;
    const pending_virt =
        (((vc.getNativeMachine().hvip | ipi_bit) & virt_mask) != 0) or
        ext_pending;

    if (pending_virt or timer_expired) {
        if (timer_expired and !riscv.riscv_supports_sstc) {
            vc.getNativeMachine().hvip |= riscv.HVIP.VSTIP;
        }
        if (@atomicRmw(bool, &vc.pending_ipi, .Xchg, false, .acq_rel)) {
            vc.getNativeMachine().hvip |= riscv.HVIP.VSSIP;
        }
        if (riscv.hasHExtension()) {
            riscv.writeHvip(vc.getNativeMachine().hvip);
        }
        riscv.writeMepc(vc.getNativeMachine().mepc);
        return;
    }

    // Block this vCore on the current physical CPU's blocked queue.
    // Deschedule from this physical CPU before publishing wfi_blocked = true
    // so a concurrent tryWake() + scheduler.queue() on another core never
    // sees running_on_cpu != null.
    scheduler.accountRuntime(vc);
    vc.running_on_cpu = null;
    pcpu.active_vcore = null;
    vc.last_queued_time = riscv.readTime();
    const b_wfi_prev = pcpu.blocked_lock.lock();
    if (@atomicRmw(bool, &vc.pending_ipi, .Xchg, false, .acq_rel)) {
        pcpu.blocked_lock.unlock(b_wfi_prev);
        vc.getNativeMachine().hvip |= riscv.HVIP.VSSIP;
        if (riscv.hasHExtension()) {
            riscv.writeHvip(vc.getNativeMachine().hvip);
        }
        riscv.writeMepc(vc.getNativeMachine().mepc);
        vc.state = .ready;
        scheduler.queue(vc);
        scheduler.schedule();
        return;
    }
    vc.blocked_node.contents = vc;
    pcpu.blocked_queue.pushStart(&vc.blocked_node);
    vc.blocked_on_cpu = pcpu.cpu_core_id;
    @atomicStore(bool, &vc.wfi_blocked, true, .release);
    pcpu.blocked_lock.unlock(b_wfi_prev);
    scheduler.schedule();
}

/// Attempt to emulate a trapped guest instruction.
pub fn emulateInstruction(
    vc: *vcore.VirtualCore,
    instr: usize,
    context: *riscv.ThreadContext,
    privilege_mode: riscv.PrivilegeMode,
) EmulationOutcome {
    const opcode = instr & riscv.Instr.OPCODE_MASK;
    const csr = (instr >> riscv.Instr.CSR_SHIFT) & riscv.Instr.CSR_MASK;

    if (opcode == riscv.Instr.OPCODE_SYSTEM and isEmulatedCsr(csr)) {
        if (privilege_mode == .user and
            ((csr >> CSR_PRIV_SHIFT) & CSR_PRIV_MASK) != 0)
        {
            return .not_handled;
        }
        emulateCsrAccess(vc, instr, context);
        return .handled;
    }

    // Emulate rdtime / csrr rd, time.
    const rdtime_inst: u32 = (riscv.CSR.TIME << riscv.Instr.CSR_SHIFT) |
        (riscv.Instr.FUNCT3_CSRRS << riscv.Instr.FUNCT3_SHIFT) |
        riscv.Instr.OPCODE_SYSTEM;
    const rdtime_mask: u32 =
        ~(@as(u32, riscv.Instr.RD_MASK) << riscv.Instr.RD_SHIFT);

    if ((instr & rdtime_mask) == rdtime_inst) {
        const time_now = @as(usize, riscv.readTime());
        const rd = (instr >> riscv.Instr.RD_SHIFT) & riscv.Instr.RD_MASK;
        if (rd != 0) {
            context[rd] = time_now;
            vc.getNativeContext()[rd] = time_now;
        }
        vc.getNativeMachine().mepc += riscv.Instr.INSN_SIZE_BYTES;
        pcore.this().trap_loop_count = 0;
        return .handled;
    }

    // Emulate FENCE.I as a no-op since I-cache coherency is maintained.
    if (instr == riscv.Instr.FENCE_I) {
        vc.getNativeMachine().mepc += riscv.Instr.INSN_SIZE_BYTES;
        pcore.this().trap_loop_count = 0;
        return .handled;
    }

    // Emulate WFI (Wait For Interrupt) only for privileged guest modes.
    if (instr == riscv.Instr.WFI) {
        if (privilege_mode == .user) return .not_handled;
        emulateWfi(vc);
        return .handled;
    }

    // Emulate Zawrs: WRS.NTO, WRS.STO, pause hint.
    if (instr == riscv.Instr.WRS_NTO or
        instr == riscv.Instr.WRS_STO or
        instr == riscv.Instr.PAUSE)
    {
        vc.getNativeMachine().mepc += riscv.Instr.INSN_SIZE_BYTES;
        riscv.writeMepc(vc.getNativeMachine().mepc);
        pcore.this().trap_loop_count = 0;
        return .handled;
    }

    // Emulate FENCE encodings that trap from VS-mode.
    const funct3 = (instr >> riscv.Instr.FUNCT3_SHIFT) &
        riscv.Instr.FUNCT3_MASK;
    if (opcode == riscv.Instr.OPCODE_MISC_MEM and
        funct3 == riscv.Instr.FUNCT3_FENCE)
    {
        vc.getNativeMachine().mepc += riscv.Instr.INSN_SIZE_BYTES;
        riscv.writeMepc(vc.getNativeMachine().mepc);
        pcore.this().trap_loop_count = 0;
        return .handled;
    }

    // Emulate read-only M-mode CSR reads (mhartid, mvendorid, marchid,
    // mimpid, misa) trapped from S-mode/VS-mode.
    if (privilege_mode != .user and
        opcode == riscv.Instr.OPCODE_SYSTEM and
        funct3 >= riscv.Instr.FUNCT3_CSRRW and
        funct3 <= riscv.Instr.FUNCT3_CSRRC)
    {
        const val: usize = switch (csr) {
            riscv.CSR.MHARTID => vc.id,
            riscv.CSR.MVENDORID,
            riscv.CSR.MARCHID,
            riscv.CSR.MIMPID,
            riscv.CSR.MISA,
            => 0,
            else => return .not_handled,
        };
        const rd = (instr >> riscv.Instr.RD_SHIFT) & riscv.Instr.RD_MASK;
        if (rd != 0) {
            context[rd] = val;
            vc.getNativeContext()[rd] = val;
        }
        vc.getNativeMachine().mepc += riscv.Instr.INSN_SIZE_BYTES;
        pcore.this().trap_loop_count = 0;
        return .handled;
    }

    return .not_handled;
}

test "csr_emu: isEmulatedCsr and emulateInstruction" {
    std.testing.refAllDecls(@This());
    try std.testing.expect(isEmulatedCsr(riscv.CSR.SEED));
    try std.testing.expect(isEmulatedCsr(riscv.CSR.SISELECT));
    try std.testing.expect(isEmulatedCsr(riscv.CSR.VSISELECT));
    try std.testing.expect(isEmulatedCsr(riscv.CSR.SENVCFG));
    try std.testing.expect(isEmulatedCsr(riscv.CSR.STIMECMP));
    try std.testing.expect(!isEmulatedCsr(riscv.CSR.MSTATUS));

    riscv.initMockHardware();
    const physmem = @import("../../../../../core/physmem.zig");
    var phys_test = try physmem.initForTest(std.testing.allocator, 2048);
    defer phys_test.deinit();
    const guest_mod = @import("../../../../../core/guest.zig");
    const g = try guest_mod.createGuest(
        std.testing.allocator,
        false,
        false,
        null,
        0,
        0,
        0,
        .riscv64,
    );
    defer g.deinit();
    var vc = vcore.VirtualCore.init(0, g, 0x80000000, 0x80001000, .normal);
    var ctx = std.mem.zeroes(riscv.ThreadContext);
    ctx[11] = 0x70; // a1 = 0x70

    // CSRRW a0 (x10), vsiselect (0x250), a1 (x11)
    const csrrw_vsiselect: usize =
        (riscv.CSR.VSISELECT << riscv.Instr.CSR_SHIFT) |
        (11 << riscv.Instr.RS1_SHIFT) |
        (riscv.Instr.FUNCT3_CSRRW << riscv.Instr.FUNCT3_SHIFT) |
        (10 << riscv.Instr.RD_SHIFT) |
        riscv.Instr.OPCODE_SYSTEM;

    // Guest U-mode must not be allowed to access privileged CSRs or WFI.
    try std.testing.expectEqual(
        EmulationOutcome.not_handled,
        emulateInstruction(&vc, csrrw_vsiselect, &ctx, .user),
    );
    try std.testing.expectEqual(
        EmulationOutcome.not_handled,
        emulateInstruction(&vc, riscv.Instr.WFI, &ctx, .user),
    );

    const outcome = emulateInstruction(&vc, csrrw_vsiselect, &ctx, .supervisor);
    try std.testing.expectEqual(EmulationOutcome.handled, outcome);
    try std.testing.expectEqual(@as(usize, 0x70), vc.getNativeSiselect().*);
    try std.testing.expectEqual(
        @as(u64, 0x80000004),
        vc.getNativeMachine().mepc,
    );
}
