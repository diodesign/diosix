// Architecture-specific emulation handler for 32-bit RISC-V guests.
//
// Handles instruction decoding, exception classification, CSR emulation,
// Sv32 page table translation, and SBI ECALL forwarding.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const emulation = @import("../emulation.zig");
const vcore = @import("../vcore.zig");
const guest = @import("../guest.zig");
const glue = @import("../unicorn.zig");
const riscv = @import("../riscv.zig");
const debug = @import("../debug.zig");
const sbi = @import("../sbi.zig");

pub const ExceptionAction = emulation.ExceptionAction;

// Unicorn register IDs for RISC-V S-mode CSRs (from riscv.h uc_riscv_reg).
pub const UC_REG_SSTATUS: c_int = 133;
pub const UC_REG_STVEC: c_int = 137;
pub const UC_REG_SEPC: c_int = 140;
pub const UC_REG_SCAUSE: c_int = 141;
pub const UC_REG_STVAL: c_int = 142;
pub const UC_REG_SATP: c_int = 146;

// Unicorn register IDs for RISC-V M-mode CSRs.
pub const UC_REG_MEDELEG: c_int = 118;
pub const UC_REG_MIDELEG: c_int = 119;

// Unicorn register IDs for unprivileged counters.
pub const UC_REG_TIME: c_int = 46;
pub const UC_REG_TIMEH: c_int = 78;

// Unicorn register ID for mcounteren.
pub const UC_REG_MCOUNTEREN: c_int = 120;



/// Set up initial RISC-V register state for a new emulated vcore.
pub fn initRegisters(uc: ?*anyopaque, entry: usize, dtb: usize, vcore_id: usize) void {
    var pc_val: u64 = entry;
    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_PC), &pc_val);

    var a0_val: u64 = vcore_id;
    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X10), &a0_val);

    var a1_val: u64 = dtb;
    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X11), &a1_val);

    // Set privilege mode to S-mode (1)
    var priv_val: u32 = 1;
    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_PRIV), &priv_val);

    // Delegate all exceptions to S-mode EXCEPT exception 9 (ECALL from S-mode).
    var deleg_val: u64 = 0xfdff;
    _ = glue.uc_reg_write(uc, UC_REG_MEDELEG, &deleg_val);
    var int_deleg_val: u64 = 0xffff;
    _ = glue.uc_reg_write(uc, UC_REG_MIDELEG, &int_deleg_val);

    // Pre-load the TIME CSR so Unicorn can execute rdtime natively.
    // If this succeeds, rdtime won't trap and we avoid the stop/restart overhead.
    var time_val: u64 = glue.readSModeTime();
    _ = glue.uc_reg_write(uc, UC_REG_TIME, &time_val);

    // Enable S-mode access to time/cycle/instret CSRs via mcounteren.
    // Bit 0 (CY) = cycle, bit 1 (TM) = time, bit 2 (IR) = instret.
    var mcounteren_val: u64 = 0x7;
    _ = glue.uc_reg_write(uc, UC_REG_MCOUNTEREN, &mcounteren_val);
}

/// Read the program counter from Unicorn.
pub fn readPC(uc: ?*anyopaque) u64 {
    var pc: u64 = 0;
    _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_PC), &pc);
    return pc;
}

/// Write the program counter to Unicorn.
pub fn writePC(uc: ?*anyopaque, pc: u64) void {
    var val: u64 = pc;
    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_PC), &val);
}

/// Handle an invalid instruction intercepted by UC_HOOK_INSN_INVALID.
/// Checks if the instruction is rdtime/rdtimeh/rdcycle/rdinstret, reads
/// the real host timer, writes it to the destination register, and
/// advances PC. Returns true if handled (resume emulation), false to
/// let Unicorn raise UC_ERR_INSN_INVALID.
pub fn handleInvalidInsn(uc: ?*anyopaque) bool {
    const pc = readPC(uc);

    // Read the instruction at PC. Try flat addressing first,
    // fall back to Sv32 page table walk if flat read fails.
    var insn: u32 = 0;
    var ok = glue.uc_mem_read(uc, pc, @as([*]u8, @ptrCast(&insn)), 4) == .UC_ERR_OK;
    if (!ok) {
        if (translateVA(uc, pc)) |phys| {
            ok = glue.uc_mem_read(uc, phys, @as([*]u8, @ptrCast(&insn)), 4) == .UC_ERR_OK;
        }
    }
    if (!ok) return false;

    // Match CSR read instructions: opcode 0x73, funct3 != 0.
    if (insn & 0x7F != 0x73) return false;
    const funct3 = (insn >> 12) & 0x7;
    if (funct3 == 0) return false;

    const csr = insn >> 20;
    const rd: u5 = @truncate((insn >> 7) & 0x1F);

    switch (csr) {
        0xC01, 0xC00, 0xC02 => {
            // time / cycle / instret (lower 32 bits).
            if (rd != 0) {
                var val: u64 = glue.readSModeTime();
                _ = glue.uc_reg_write(uc, @as(c_int, @intCast(1 + @as(u32, rd))), &val);
            }
        },
        0xC81, 0xC80, 0xC82 => {
            // timeh / cycleh / instreth (upper 32 bits for RV32).
            if (rd != 0) {
                var val: u64 = glue.readSModeTime() >> 32;
                _ = glue.uc_reg_write(uc, @as(c_int, @intCast(1 + @as(u32, rd))), &val);
            }
        },
        else => return false,
    }

    writePC(uc, pc + 4);
    return true;
}

/// Handle a clean stop (UC_ERR_OK). Check if the instruction at `pc`
/// is an ECALL and if so, forward it to the SBI layer.
/// Returns true if an ECALL was handled and PC was advanced.
pub fn handleCleanStop(uc: ?*anyopaque, vc: *vcore.VirtualCore, pc: u64) bool {
    var insn: u32 = 0;
    if (glue.uc_mem_read(uc, pc, @as([*]u8, @ptrCast(&insn)), 4) != .UC_ERR_OK) {
        // Try Sv32 translation if flat read fails
        if (translateVA(uc, pc)) |phys| {
            if (glue.uc_mem_read(uc, phys, @as([*]u8, @ptrCast(&insn)), 4) != .UC_ERR_OK) return false;
        } else return false;
    }
    if (insn != 0x00000073) return false; // Not ECALL

    var a7: u32 = 0;
    var a0: u32 = 0;
    var a1: u32 = 0;
    _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X17), &a7);
    _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X10), &a0);
    _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X11), &a1);

    var mock_context = std.mem.zeroes(riscv.ThreadContext);
    mock_context[@intFromEnum(riscv.Register.a7)] = a7;
    mock_context[@intFromEnum(riscv.Register.a0)] = a0;
    mock_context[@intFromEnum(riscv.Register.a1)] = a1;

    sbi.handle(vc, &mock_context);

    const res_a0 = @as(u32, @intCast(mock_context[@intFromEnum(riscv.Register.a0)]));
    const res_a1 = @as(u32, @intCast(mock_context[@intFromEnum(riscv.Register.a1)]));
    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X10), &res_a0);
    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X11), &res_a1);

    var next_pc: u64 = pc + 4;
    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_PC), &next_pc);
    return true;
}

/// Handle a UC_ERR_EXCEPTION by decoding the faulting instruction,
/// synthesizing scause/stval/sepc, and delivering the trap via stvec.
/// Returns the action taken.
pub fn handleException(uc: ?*anyopaque, new_pc: u64) ExceptionAction {
    var stvec: u64 = 0;
    _ = glue.uc_reg_read(uc, UC_REG_STVEC, &stvec);
    if (stvec == 0) return .unhandled;

    var scause: u64 = 12; // Default: instruction page fault
    var stval: u64 = new_pc;

    // Read the faulting instruction. uc_mem_read uses flat addressing,
    // so if the guest has enabled MMU, fall back to Sv32 page table walk.
    var insn: u32 = 0;
    var insn_read_ok = glue.uc_mem_read(uc, new_pc, @as([*]u8, @ptrCast(&insn)), 4) == .UC_ERR_OK;
    if (!insn_read_ok) {
        if (translateVA(uc, new_pc)) |phys_addr| {
            insn_read_ok = glue.uc_mem_read(uc, phys_addr, @as([*]u8, @ptrCast(&insn)), 4) == .UC_ERR_OK;
        }
    }

    if (insn_read_ok) {
        if (insn & 0x3 == 0x3) {
            // 32-bit instruction
            const opcode = insn & 0x7F;
            const funct3 = (insn >> 12) & 0x7;

            if (opcode == 0x73 and funct3 != 0) {
                // CSR instruction — emulate time/cycle/instret.
                const action = emulateCSR(uc, insn, new_pc);
                if (action != null) return action.?;

                // Unknown CSR: illegal instruction
                scause = 2;
                stval = insn;
            } else if (opcode == 0x03 or opcode == 0x07) {
                scause = 13; // Load fault
                stval = inferLoadAddress(uc, insn);
            } else if (opcode == 0x23 or opcode == 0x27) {
                scause = 15; // Store fault
                stval = inferStoreAddress(uc, insn);
            } else if (opcode == 0x2F) {
                scause = 15; // Atomic: store fault
                stval = inferLoadAddress(uc, insn);
            } else if (opcode == 0x73 and funct3 == 0) {
                const action = emulateSystem(uc, insn, new_pc);
                if (action != null) return action.?;

                scause = 2; // Illegal instruction
                stval = insn;
            }
        } else {
            // 16-bit compressed instruction
            classifyCompressedFault(&scause, @truncate(insn));
        }
    }
    // else: can't read instruction at PC → instruction page fault (12)

    // Deliver the trap to the guest's S-mode handler.
    _ = glue.uc_reg_write(uc, UC_REG_SCAUSE, &scause);
    _ = glue.uc_reg_write(uc, UC_REG_STVAL, &stval);
    var sepc_val: u64 = new_pc;
    _ = glue.uc_reg_write(uc, UC_REG_SEPC, &sepc_val);

    const stvec_base = stvec & ~@as(u64, 0x3);
    writePC(uc, stvec_base);

    // Flush Unicorn TLB/TB caches — Unicorn's TCG doesn't respond to
    // guest-issued sfence.vma, so we must flush manually after any trap
    // that may result in page table modifications.
    _ = glue.uc_ctl(uc, @as(c_uint, glue.UC_CTL_FLUSH_TLB));
    _ = glue.uc_ctl(uc, @as(c_uint, glue.UC_CTL_FLUSH_TB));

    return .delivered;
}

// --- Internal helpers ---

/// Emulate CSR read instructions (CSRRS/CSRRW/CSRRC with funct3 != 0).
/// Handles time/cycle/instret reads by returning the real host timer.
/// Returns .emulated if the CSR was handled, null otherwise.
fn emulateCSR(uc: ?*anyopaque, insn: u32, pc: u64) ?ExceptionAction {
    const csr = insn >> 20;
    const rd: u5 = @truncate((insn >> 7) & 0x1F);

    switch (csr) {
        0xC01, 0xC00, 0xC02 => {
            // time / cycle / instret (lower 32 bits).
            if (rd != 0) {
                var val: u64 = glue.readSModeTime();
                _ = glue.uc_reg_write(uc, @as(c_int, @intCast(1 + @as(u32, rd))), &val);
            }
            writePC(uc, pc + 4);
            return .emulated;
        },
        0xC81, 0xC80, 0xC82 => {
            // timeh / cycleh / instreth (upper 32 bits for RV32).
            if (rd != 0) {
                var val: u64 = glue.readSModeTime() >> 32;
                _ = glue.uc_reg_write(uc, @as(c_int, @intCast(1 + @as(u32, rd))), &val);
            }
            writePC(uc, pc + 4);
            return .emulated;
        },
        else => return null,
    }
}

/// Emulate SYSTEM instructions with funct3=0 (ECALL/EBREAK/xRET/SFENCE/WFI).
/// Returns .emulated if handled, null otherwise.
fn emulateSystem(uc: ?*anyopaque, insn: u32, pc: u64) ?ExceptionAction {
    const funct7 = insn >> 25;
    if (funct7 == 0x09) {
        // SFENCE.VMA: flush Unicorn's TLB and TB, skip instruction.
        _ = glue.uc_ctl(uc, @as(c_uint, glue.UC_CTL_FLUSH_TLB));
        _ = glue.uc_ctl(uc, @as(c_uint, glue.UC_CTL_FLUSH_TB));
        writePC(uc, pc + 4);
        return .emulated;
    }
    return null;
}

/// Classify a 16-bit compressed instruction fault into scause.
fn classifyCompressedFault(scause: *u64, c_insn: u16) void {
    const quadrant = c_insn & 0x3;
    const c_funct3 = (c_insn >> 13) & 0x7;
    if (quadrant == 0x0 and c_funct3 == 0x2) {
        scause.* = 13; // C.LW
    } else if (quadrant == 0x0 and c_funct3 == 0x6) {
        scause.* = 15; // C.SW
    } else if (quadrant == 0x2 and c_funct3 == 0x2) {
        scause.* = 13; // C.LWSP
    } else if (quadrant == 0x2 and c_funct3 == 0x6) {
        scause.* = 15; // C.SWSP
    }
}

/// Walk an Sv32 page table to translate a virtual address to physical.
/// Returns the physical address or null if translation fails.
pub fn translateVA(uc: ?*anyopaque, vaddr: u64) ?u64 {
    var satp: u64 = 0;
    _ = glue.uc_reg_read(uc, UC_REG_SATP, &satp);

    // Sv32 satp: bit 31 = MODE (1=Sv32), bits 21:0 = PPN
    if (satp & (1 << 31) == 0) return null; // MMU disabled

    const root_ppn: u32 = @truncate(satp & 0x3FFFFF);
    const va: u32 = @truncate(vaddr);
    const vpn1: u32 = (va >> 22) & 0x3FF;
    const vpn0: u32 = (va >> 12) & 0x3FF;
    const page_offset: u32 = va & 0xFFF;

    // Level 1: read PTE from root page table
    const l1_addr: u64 = (@as(u64, root_ppn) << 12) + (@as(u64, vpn1) * 4);
    var l1_pte: u32 = 0;
    if (glue.uc_mem_read(uc, l1_addr, @as([*]u8, @ptrCast(&l1_pte)), 4) != .UC_ERR_OK) return null;

    if (l1_pte & 0x1 == 0) return null; // Not valid
    if (l1_pte & 0xE != 0) {
        // Superpage (4MB): PPN[1] from PTE, VPN[0] from VA
        const ppn1: u32 = (l1_pte >> 20) & 0xFFF;
        return (@as(u64, ppn1) << 22) | (@as(u64, vpn0) << 12) | @as(u64, page_offset);
    }

    // Level 0: second-level page table
    const l0_ppn: u32 = (l1_pte >> 10) & 0x3FFFFF;
    const l0_addr: u64 = (@as(u64, l0_ppn) << 12) + (@as(u64, vpn0) * 4);
    var l0_pte: u32 = 0;
    if (glue.uc_mem_read(uc, l0_addr, @as([*]u8, @ptrCast(&l0_pte)), 4) != .UC_ERR_OK) return null;

    if (l0_pte & 0x1 == 0) return null;
    if (l0_pte & 0xE == 0) return null; // Pointer PTE at leaf level

    const phys_ppn: u32 = (l0_pte >> 10) & 0x3FFFFF;
    return (@as(u64, phys_ppn) << 12) | @as(u64, page_offset);
}

/// Read a RISC-V general purpose register (x0-x31) from Unicorn.
fn readGPR(uc: ?*anyopaque, reg_num: u5) u64 {
    if (reg_num == 0) return 0;
    var val: u64 = 0;
    _ = glue.uc_reg_read(uc, @as(c_int, @intCast(1 + @as(u32, reg_num))), &val);
    return val;
}

/// Compute the target address of an I-type load instruction.
fn inferLoadAddress(uc: ?*anyopaque, insn: u32) u64 {
    const rs1: u5 = @truncate((insn >> 15) & 0x1F);
    const imm_raw: u32 = insn >> 20;
    const imm: i32 = @bitCast(if (imm_raw & 0x800 != 0) imm_raw | 0xFFFFF000 else imm_raw);
    const base: i64 = @bitCast(readGPR(uc, rs1));
    return @bitCast(base +% @as(i64, imm));
}

/// Compute the target address of an S-type store instruction.
fn inferStoreAddress(uc: ?*anyopaque, insn: u32) u64 {
    const rs1: u5 = @truncate((insn >> 15) & 0x1F);
    const imm_lo: u32 = (insn >> 7) & 0x1F;
    const imm_hi: u32 = (insn >> 25) & 0x7F;
    const imm_raw: u32 = (imm_hi << 5) | imm_lo;
    const imm: i32 = @bitCast(if (imm_raw & 0x800 != 0) imm_raw | 0xFFFFF000 else imm_raw);
    const base: i64 = @bitCast(readGPR(uc, rs1));
    return @bitCast(base +% @as(i64, imm));
}
