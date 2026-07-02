// Architecture-specific emulation handler for 64-bit Arm (AArch64) guests.
//
// Handles instruction decoding, exception classification, PSCI call
// forwarding, generic timer emulation, and AArch64 page table translation.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const emulation = @import("../../emulation.zig");
const glue = @import("../../unicorn.zig");
const vcore = @import("../../vcore.zig");
const debug = @import("../../debug.zig");
const psci = @import("psci.zig");
const pcore = @import("../../pcore.zig");

pub const ExceptionAction = emulation.ExceptionAction;

// Unicorn register ID aliases for readability.
const REG = glue.uc_arm64_reg;

// ---- AArch64 Instruction Encodings ----

/// HVC #0 instruction (32-bit encoding): 0xD4000002.
const INSN_HVC: u32 = 0xD4000002;

/// SMC #0 instruction (32-bit encoding): 0xD4000003.
const INSN_SMC: u32 = 0xD4000003;

/// WFI instruction (32-bit encoding): 0xD503207F.
const INSN_WFI: u32 = 0xD503207F;

/// WFE instruction (32-bit encoding): 0xD503205F.
const INSN_WFE: u32 = 0xD503205F;

// ---- AArch64 PSTATE / Exception Constants ----

/// PSTATE value for EL1h (EL1 with SP_EL1): 0x3C5.
/// Bits: M[3:0]=0b0101 (EL1h), D=1, A=1, I=1, F=1 (all exceptions masked).
const PSTATE_EL1H_ALL_MASKED: u64 = 0x3C5;

// ---- AArch64 Exception Syndrome (ESR_EL1) EC values ----
pub const EC_UNKNOWN: u32 = 0x00;
pub const EC_WFI_WFE: u32 = 0x01;
pub const EC_SVC64: u32 = 0x15;
pub const EC_HVC64: u32 = 0x16;
pub const EC_SMC64: u32 = 0x17;
pub const EC_MSR_MRS: u32 = 0x18;
pub const EC_INSN_ABORT_LOWER: u32 = 0x20;
pub const EC_INSN_ABORT_SAME: u32 = 0x21;
pub const EC_DATA_ABORT_LOWER: u32 = 0x24;
pub const EC_DATA_ABORT_SAME: u32 = 0x25;

// ---- PL011 UART Constants ----
/// QEMU virt ARM PL011 UART base address.
pub const PL011_UART_BASE: u64 = 0x09000000;
/// PL011 register space size.
pub const PL011_UART_SIZE: u64 = 0x1000;

/// Set up initial AArch64 register state for a new emulated vcore.
///
/// ARM64 Linux boot protocol (Documentation/arm64/booting.rst):
///   - X0 = physical address of the device tree blob (DTB)
///   - X1-X3 = 0 (reserved)
///   - PC = kernel entry point
///   - MMU off, D-cache off, I-cache on or off
///   - FP/SIMD enabled
///   - Little endian
pub fn initRegisters(uc: ?*anyopaque, entry: usize, dtb: usize, _: usize) void {
    // Set PC to kernel entry.
    var pc_val: u64 = entry;
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_ARM64_REG_PC), &pc_val);

    // X0 = DTB address (ARM64 boot protocol).
    var dtb_val: u64 = dtb;
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_ARM64_REG_X0), &dtb_val);

    // X1-X3 must be zero.
    var zero: u64 = 0;
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_ARM64_REG_X1), &zero);
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_ARM64_REG_X2), &zero);
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_ARM64_REG_X3), &zero);

    // Enable FP/SIMD access: CPACR_EL1.FPEN = 0b11 (bits 21:20).
    var cpacr: u64 = (3 << 20);
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_ARM64_REG_CPACR_EL1), &cpacr);

    // Set PSTATE for EL1h with all exceptions masked.
    // Unicorn's ARM64 starts at EL1 by default; this ensures a clean state.
    var pstate: u64 = PSTATE_EL1H_ALL_MASKED;
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_ARM64_REG_PSTATE), &pstate);
}

/// Read the program counter from Unicorn.
pub fn readPC(uc: ?*anyopaque) u64 {
    var pc: u64 = 0;
    _ = glue.uc_reg_read(uc, @intFromEnum(REG.UC_ARM64_REG_PC), &pc);
    return pc;
}

/// Write the program counter to Unicorn.
pub fn writePC(uc: ?*anyopaque, pc: u64) void {
    var val: u64 = pc;
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_ARM64_REG_PC), &val);
}

/// Handle an invalid instruction intercepted by UC_HOOK_INSN_INVALID.
///
/// Checks for:
///   - MRS instructions reading timer registers (CNTPCT_EL0, CNTVCT_EL0,
///     CNTFRQ_EL0) — emulates using the host timer.
///   - MSR instructions writing timer control registers.
///   - WFI/WFE — treated as NOP.
///
/// Returns true if handled (resume emulation), false to let Unicorn
/// raise UC_ERR_INSN_INVALID.
pub fn handleInvalidInsn(uc: ?*anyopaque) bool {
    const pc = readPC(uc);

    var insn: u32 = 0;
    var ok = glue.uc_mem_read(uc, pc, @as([*]u8, @ptrCast(&insn)), 4) == .UC_ERR_OK;
    if (!ok) {
        if (translateVA(uc, pc)) |phys| {
            ok = glue.uc_mem_read(uc, phys, @as([*]u8, @ptrCast(&insn)), 4) == .UC_ERR_OK;
        }
    }
    if (!ok) return false;

    // WFI: treat as NOP, advance PC.
    if (insn == INSN_WFI or insn == INSN_WFE) {
        writePC(uc, pc + 4);
        return true;
    }

    // MRS Xt, <sysreg>: encoding 0xD5300000 | (op0:op1:CRn:CRm:op2 << 5) | Rt
    // MSR <sysreg>, Xt: encoding 0xD5100000 | (op0:op1:CRn:CRm:op2 << 5) | Rt
    const is_mrs = (insn & 0xFFF00000) == 0xD5300000;
    const is_msr = (insn & 0xFFF00000) == 0xD5100000;

    if (is_mrs or is_msr) {
        const rt: u5 = @truncate(insn & 0x1F);
        // Extract system register encoding: op0:op1:CRn:CRm:op2
        const sysreg = (insn >> 5) & 0x7FFF;

        // Decode known system registers by their op0:op1:CRn:CRm:op2 encoding.
        // CNTPCT_EL0:  op0=3, op1=3, CRn=14, CRm=0, op2=1 → 0x5E01
        // CNTVCT_EL0:  op0=3, op1=3, CRn=14, CRm=0, op2=2 → 0x5E02
        // CNTFRQ_EL0:  op0=3, op1=3, CRn=14, CRm=0, op2=0 → 0x5E00
        // CNTP_CTL_EL0: op0=3, op1=3, CRn=14, CRm=2, op2=1 → 0x5E21
        // CNTP_CVAL_EL0: op0=3, op1=3, CRn=14, CRm=2, op2=2 → 0x5E22
        // CNTP_TVAL_EL0: op0=3, op1=3, CRn=14, CRm=2, op2=0 → 0x5E20
        const SYSREG_CNTPCT_EL0: u15 = 0x5E01;
        const SYSREG_CNTVCT_EL0: u15 = 0x5E02;
        const SYSREG_CNTFRQ_EL0: u15 = 0x5E00;
        const SYSREG_CNTP_CTL_EL0: u15 = 0x5E21;
        const SYSREG_CNTP_CVAL_EL0: u15 = 0x5E22;
        const SYSREG_CNTP_TVAL_EL0: u15 = 0x5E20;

        if (is_mrs) {
            var val: u64 = 0;
            switch (@as(u15, @truncate(sysreg))) {
                SYSREG_CNTPCT_EL0, SYSREG_CNTVCT_EL0 => {
                    // Return host timer value.
                    val = glue.readSModeTime();
                },
                SYSREG_CNTFRQ_EL0 => {
                    // 10 MHz — matches the host timer frequency.
                    val = 10_000_000;
                },
                SYSREG_CNTP_CTL_EL0 => {
                    // Timer control: just return 0 (timer disabled).
                    val = 0;
                },
                SYSREG_CNTP_CVAL_EL0 => {
                    val = 0;
                },
                SYSREG_CNTP_TVAL_EL0 => {
                    val = 0;
                },
                else => {
                    const S = struct {
                        var log_count: u32 = 0;
                    };
                    if (S.log_count < 20) {
                        S.log_count += 1;
                        debug.printf("aarch64: unhandled MRS sysreg=0x{x} at PC=0x{x}\n", .{ sysreg, pc });
                    }
                    return false;
                },
            }
            if (rt != 31) { // XZR
                _ = glue.uc_reg_write(uc, regIdForX(rt), &val);
            }
            writePC(uc, pc + 4);
            return true;
        }

        if (is_msr) {
            var val: u64 = 0;
            if (rt != 31) {
                _ = glue.uc_reg_read(uc, regIdForX(rt), &val);
            }
            switch (@as(u15, @truncate(sysreg))) {
                SYSREG_CNTP_CTL_EL0 => {
                    // Timer control write: bit 0 = ENABLE, bit 1 = IMASK.
                    if (pcore.this().active_vcore) |opaque_vc| {
                        const vc: *vcore.VirtualCore = @ptrCast(@alignCast(opaque_vc));
                        const em = &vc.exec_path.emulated;
                        const sub = &em.sub_vcores[em.active_sub_vcore];
                        const enabled = (val & 1) != 0;
                        const masked = (val & 2) != 0;
                        sub.timer_scheduled = enabled and !masked;
                    }
                },
                SYSREG_CNTP_CVAL_EL0 => {
                    if (pcore.this().active_vcore) |opaque_vc| {
                        const vc: *vcore.VirtualCore = @ptrCast(@alignCast(opaque_vc));
                        const em = &vc.exec_path.emulated;
                        const sub = &em.sub_vcores[em.active_sub_vcore];
                        sub.timer_target = val;
                        sub.timer_scheduled = true;
                    }
                },
                SYSREG_CNTP_TVAL_EL0 => {
                    if (pcore.this().active_vcore) |opaque_vc| {
                        const vc: *vcore.VirtualCore = @ptrCast(@alignCast(opaque_vc));
                        const em = &vc.exec_path.emulated;
                        const sub = &em.sub_vcores[em.active_sub_vcore];
                        const offset = @as(i64, @bitCast(val));
                        const current_time = glue.readSModeTime();
                        sub.timer_target = @bitCast(@as(i64, @bitCast(current_time)) +% offset);
                        sub.timer_scheduled = true;
                    }
                },
                else => {
                    const S2 = struct {
                        var log_count: u32 = 0;
                    };
                    if (S2.log_count < 20) {
                        S2.log_count += 1;
                        debug.printf("aarch64: unhandled MSR sysreg=0x{x} val=0x{x} at PC=0x{x}\n", .{ sysreg, val, pc });
                    }
                    return false;
                },
            }
            writePC(uc, pc + 4);
            return true;
        }
    }

    // ISB / DSB / DMB: data/instruction barrier instructions.
    // encoding: 0xD5000000 class, CRn=3 for barriers.
    if ((insn & 0xFFFFF01F) == 0xD503301F) {
        // DSB/DMB variants: treat as NOP.
        writePC(uc, pc + 4);
        return true;
    }
    if (insn == 0xD5033FDF) {
        // ISB SY: treat as NOP.
        writePC(uc, pc + 4);
        return true;
    }

    // TLBI instructions: TLB invalidation. Encoded as MSR to TLBI space.
    // op0=1, op1=varies, CRn=8 for TLBI.
    if ((insn & 0xFFF80000) == 0xD5080000) {
        // Flush Unicorn's TLB.
        _ = glue.uc_ctl(uc, @as(c_uint, glue.UC_CTL_FLUSH_TLB));
        writePC(uc, pc + 4);
        return true;
    }

    // IC instructions: instruction cache maintenance. Treat as NOP + TB flush.
    if ((insn & 0xFFF80000) == 0xD5080000 or (insn & 0xFFFF0000) == 0xD50B0000) {
        _ = glue.uc_ctl(uc, @as(c_uint, glue.UC_CTL_FLUSH_TB));
        writePC(uc, pc + 4);
        return true;
    }

    const S3 = struct {
        var log_count: u32 = 0;
    };
    if (S3.log_count < 20) {
        S3.log_count += 1;
        debug.printf("aarch64: unhandled invalid insn 0x{x} at PC=0x{x}\n", .{ insn, pc });
    }
    return false;
}

/// Handle a clean stop (UC_ERR_OK). Check if the instruction at `pc`
/// is an HVC or SMC and if so, forward to the PSCI handler.
/// Returns true if handled and PC was advanced.
pub fn handleCleanStop(uc: ?*anyopaque, vc: *vcore.VirtualCore, pc: u64) bool {
    var insn: u32 = 0;
    if (glue.uc_mem_read(uc, pc, @as([*]u8, @ptrCast(&insn)), 4) != .UC_ERR_OK) {
        if (translateVA(uc, pc)) |phys| {
            if (glue.uc_mem_read(uc, phys, @as([*]u8, @ptrCast(&insn)), 4) != .UC_ERR_OK) return false;
        } else return false;
    }

    // Check for HVC or SMC. The immediate field is in bits [20:5] but for
    // PSCI the standard encoding uses immediate 0 (HVC #0, SMC #0).
    const is_hvc = (insn & 0xFFE0001F) == 0xD4000002;
    const is_smc = (insn & 0xFFE0001F) == 0xD4000003;

    if (!is_hvc and !is_smc) return false;

    // Read PSCI arguments: func_id in W0, args in X1-X3.
    var x0: u64 = 0;
    var x1: u64 = 0;
    var x2: u64 = 0;
    var x3: u64 = 0;
    _ = glue.uc_reg_read(uc, @intFromEnum(REG.UC_ARM64_REG_X0), &x0);
    _ = glue.uc_reg_read(uc, @intFromEnum(REG.UC_ARM64_REG_X1), &x1);
    _ = glue.uc_reg_read(uc, @intFromEnum(REG.UC_ARM64_REG_X2), &x2);
    _ = glue.uc_reg_read(uc, @intFromEnum(REG.UC_ARM64_REG_X3), &x3);

    const func_id: u32 = @truncate(x0);
    const result = psci.handle(vc, func_id, x1, x2, x3);

    // Write result to X0.
    var res_val: u64 = @bitCast(result);
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_ARM64_REG_X0), &res_val);

    // Advance PC past the HVC/SMC instruction.
    var next_pc: u64 = pc + 4;
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_ARM64_REG_PC), &next_pc);

    return true;
}

/// Handle a UC_ERR_EXCEPTION by reading ESR_EL1 to classify the fault,
/// then delivering the exception to the guest's VBAR_EL1 vector.
///
/// AArch64 exception vectors (VBAR_EL1 + offset):
///   0x000: Synchronous, current EL with SP_EL0
///   0x200: Synchronous, current EL with SP_ELx
///   0x400: Synchronous, lower EL using AArch64
///   0x600: Synchronous, lower EL using AArch32
/// Each vector entry is 0x80 bytes (32 instructions).
pub fn handleException(uc: ?*anyopaque, new_pc: u64) ExceptionAction {
    var vbar: u64 = 0;
    _ = glue.uc_reg_read(uc, @intFromEnum(REG.UC_ARM64_REG_VBAR_EL1), &vbar);
    if (vbar == 0) return .unhandled;

    // Read ESR_EL1 to classify the exception.
    var esr: u64 = 0;
    _ = glue.uc_reg_read(uc, @intFromEnum(REG.UC_ARM64_REG_ESR_EL1), &esr);

    // If ESR is 0, synthesize an instruction abort at new_pc.
    if (esr == 0) {
        // Instruction abort from same EL, IFSC = translation fault level 0.
        esr = (@as(u64, EC_INSN_ABORT_SAME) << 26) | 0x04;
    }

    // Read current PSTATE for saving to SPSR_EL1.
    var pstate: u64 = 0;
    _ = glue.uc_reg_read(uc, @intFromEnum(REG.UC_ARM64_REG_PSTATE), &pstate);

    // Save exception state:
    //   ELR_EL1 = faulting PC
    //   SPSR_EL1 = saved PSTATE (not directly accessible via Unicorn;
    //              we approximate by reading PSTATE before the exception)
    //   ESR_EL1 = already set by QEMU's exception handling
    //   FAR_EL1 = already set by QEMU for data/instruction aborts
    var elr_val: u64 = new_pc;
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_ARM64_REG_ELR_EL1), &elr_val);

    // Set new PSTATE: EL1h, all exceptions masked.
    var new_pstate: u64 = PSTATE_EL1H_ALL_MASKED;
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_ARM64_REG_PSTATE), &new_pstate);

    // Determine the exception vector offset.
    // For exceptions taken from EL1 to EL1 (current EL, SP_ELx): offset = 0x200.
    const vector_offset: u64 = 0x200;
    writePC(uc, vbar + vector_offset);

    // Flush TB cache so the next uc_emu_start generates fresh
    // translation blocks with the updated exception state.
    _ = glue.uc_ctl(uc, @as(c_uint, glue.UC_CTL_FLUSH_TB));

    return .delivered;
}

/// Translate a virtual address using the AArch64 page table (4KB granule).
///
/// Reads TTBR0_EL1 (for lower VA range) or TTBR1_EL1 (for upper VA range)
/// and walks up to 4 levels of page tables.
///
/// Currently a stub — returns null (flat addressing only).
/// Will be implemented when the guest enables the MMU.
pub fn translateVA(uc: ?*anyopaque, va: u64) ?u64 {
    // Determine which translation table to use based on VA range.
    // VA[63] = 0 → TTBR0_EL1 (user space)
    // VA[63] = 1 → TTBR1_EL1 (kernel space)
    const use_ttbr1 = (va >> 63) != 0;

    var ttbr: u64 = 0;
    if (use_ttbr1) {
        _ = glue.uc_reg_read(uc, @intFromEnum(REG.UC_ARM64_REG_TTBR1_EL1), &ttbr);
    } else {
        _ = glue.uc_reg_read(uc, @intFromEnum(REG.UC_ARM64_REG_TTBR0_EL1), &ttbr);
    }

    // If TTBR is 0, MMU is not yet configured — fall back to flat addressing.
    if (ttbr == 0) return null;

    // AArch64 4KB granule, 4-level page table walk.
    // VA bits: [47:39]=L0, [38:30]=L1, [29:21]=L2, [20:12]=L3, [11:0]=offset
    const table_base = ttbr & 0x0000FFFFFFFFF000; // BADDR from TTBR

    // Level 0
    const l0_idx = (va >> 39) & 0x1FF;
    var l0_entry: u64 = 0;
    if (glue.uc_mem_read(uc, table_base + l0_idx * 8, @as([*]u8, @ptrCast(&l0_entry)), 8) != .UC_ERR_OK)
        return null;
    if (l0_entry & 1 == 0) return null; // Invalid
    if (l0_entry & 2 == 0) return null; // L0 block not valid in 4KB granule

    // Level 1
    const l1_table = l0_entry & 0x0000FFFFFFFFF000;
    const l1_idx = (va >> 30) & 0x1FF;
    var l1_entry: u64 = 0;
    if (glue.uc_mem_read(uc, l1_table + l1_idx * 8, @as([*]u8, @ptrCast(&l1_entry)), 8) != .UC_ERR_OK)
        return null;
    if (l1_entry & 1 == 0) return null;
    if (l1_entry & 2 == 0) {
        // 1GB block descriptor
        return (l1_entry & 0x0000FFFFC0000000) | (va & 0x3FFFFFFF);
    }

    // Level 2
    const l2_table = l1_entry & 0x0000FFFFFFFFF000;
    const l2_idx = (va >> 21) & 0x1FF;
    var l2_entry: u64 = 0;
    if (glue.uc_mem_read(uc, l2_table + l2_idx * 8, @as([*]u8, @ptrCast(&l2_entry)), 8) != .UC_ERR_OK)
        return null;
    if (l2_entry & 1 == 0) return null;
    if (l2_entry & 2 == 0) {
        // 2MB block descriptor
        return (l2_entry & 0x0000FFFFFFE00000) | (va & 0x1FFFFF);
    }

    // Level 3
    const l3_table = l2_entry & 0x0000FFFFFFFFF000;
    const l3_idx = (va >> 12) & 0x1FF;
    var l3_entry: u64 = 0;
    if (glue.uc_mem_read(uc, l3_table + l3_idx * 8, @as([*]u8, @ptrCast(&l3_entry)), 8) != .UC_ERR_OK)
        return null;
    if (l3_entry & 1 == 0) return null;
    // L3 entries must have bit[1]=1 for page descriptor.
    if (l3_entry & 2 == 0) return null;

    return (l3_entry & 0x0000FFFFFFFFF000) | (va & 0xFFF);
}

/// Deliver a timer interrupt to the AArch64 guest.
///
/// Sets up the exception state and jumps to VBAR_EL1 + 0x280 (IRQ, current EL SP_ELx).
pub fn deliverInterrupt(uc: ?*anyopaque, pc: u64, _: u32) void {
    var vbar: u64 = 0;
    _ = glue.uc_reg_read(uc, @intFromEnum(REG.UC_ARM64_REG_VBAR_EL1), &vbar);
    if (vbar == 0) return;

    // Save return address.
    var elr_val: u64 = pc;
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_ARM64_REG_ELR_EL1), &elr_val);

    // Save PSTATE to SPSR_EL1 (approximated).
    var pstate: u64 = 0;
    _ = glue.uc_reg_read(uc, @intFromEnum(REG.UC_ARM64_REG_PSTATE), &pstate);

    var spsr = glue.uc_arm64_cp_reg{
        .crn = 4,
        .crm = 0,
        .op0 = 3,
        .op1 = 0,
        .op2 = 0,
        .val = pstate,
    };
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_ARM64_REG_CP_REG), &spsr);

    // Set PSTATE to EL1h with all exceptions masked.
    var new_pstate: u64 = PSTATE_EL1H_ALL_MASKED;
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_ARM64_REG_PSTATE), &new_pstate);

    // IRQ vector: VBAR + 0x280 (IRQ, current EL with SP_ELx).
    writePC(uc, vbar + 0x280);
}

// ---- Helper Functions ----

/// Map an X register index (0-30) to its Unicorn register ID.
fn regIdForX(rt: u5) c_int {
    return switch (rt) {
        0...28 => @as(c_int, @intFromEnum(REG.UC_ARM64_REG_X0)) + @as(c_int, rt),
        29 => @intFromEnum(REG.UC_ARM64_REG_X29),
        30 => @intFromEnum(REG.UC_ARM64_REG_X30),
        31 => @intFromEnum(REG.UC_ARM64_REG_SP), // XZR in most contexts
    };
}
