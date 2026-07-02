// Architecture-specific emulation handler for 64-bit x86 guests.
//
// Handles register initialization, page table translation, syscall
// hypercalls, RDTSC/RDTSCP instruction emulation, and IDT-based interrupt delivery.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const emulation = @import("../../emulation.zig");
const glue = @import("../../unicorn.zig");
const vcore = @import("../../vcore.zig");
const debug = @import("../../debug.zig");

pub const ExceptionAction = emulation.ExceptionAction;

// ---- x86_64 register ID aliases for readability ----
const REG = glue.uc_x86_reg;

// ---- x86_64 Segment Selector Indices ----
const GDT_CS_INDEX: u16 = 1;
const GDT_DS_INDEX: u16 = 2;

// ---- x86_64 RFLAGS bits ----
const RFLAGS_IF: u64 = 1 << 9; // Interrupt flag
const RFLAGS_TF: u64 = 1 << 8; // Trap flag

/// Set up initial x86_64 register state for a new emulated vcore.
pub fn initRegisters(uc: ?*anyopaque, entry: usize, ram_base: usize, ram_size: usize, early_pgt_gpa: usize) void {
    var rip_val: u64 = entry;
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_RIP), &rip_val);

    // Set up standard GDT segment selectors to execute flat 64-bit mode code.
    var cs_val: u64 = (GDT_CS_INDEX << 3);
    var ds_val: u64 = (GDT_DS_INDEX << 3);
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_CS), &cs_val);
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_DS), &ds_val);
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_SS), &ds_val);

    if (early_pgt_gpa != 0) {
        setupBootPageTables(uc, ram_base, ram_base + 0x10000);
        var cr3_val: u64 = ram_base + 0x10000;
        var cr4_val: u64 = 0x20; // PAE
        var cr0_val: u64 = 0x80010011; // PG, WP, PE, ET
        _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_CR3), &cr3_val);
        _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_CR4), &cr4_val);
        _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_CR0), &cr0_val);

        // RSI must point to boot_params GPA for the 64-bit boot protocol.
        var rsi_val: u64 = ram_base + 0x90000;
        _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_RSI), &rsi_val);
    }

    // Setup boot_params for the guest Linux kernel
    setupBootParams(uc, ram_base, ram_size);
}

fn setupBootPageTables(uc: ?*anyopaque, ram_base: u64, early_pgt_gpa: u64) void {
    const pml4_gpa = early_pgt_gpa;
    const id_pdpt_gpa = ram_base + 0x11000;
    const k_pdpt_gpa = ram_base + 0x12000;
    const id_pd_gpa = ram_base + 0x13000;
    const k_pd_gpa = ram_base + 0x14000;
    const id_pd_low_gpa = ram_base + 0x15000;

    // Zero out the pages first.
    var zero_buf = std.mem.zeroes([4096]u8);
    _ = glue.uc_mem_write(uc, pml4_gpa, @ptrCast(&zero_buf), 4096);
    _ = glue.uc_mem_write(uc, id_pdpt_gpa, @ptrCast(&zero_buf), 4096);
    _ = glue.uc_mem_write(uc, k_pdpt_gpa, @ptrCast(&zero_buf), 4096);
    _ = glue.uc_mem_write(uc, id_pd_gpa, @ptrCast(&zero_buf), 4096);
    _ = glue.uc_mem_write(uc, k_pd_gpa, @ptrCast(&zero_buf), 4096);
    _ = glue.uc_mem_write(uc, id_pd_low_gpa, @ptrCast(&zero_buf), 4096);

    // Flags: Present (1), Writable (2), User (4)
    const flags_dir: u64 = 7; // Present | Write | User
    const flags_page: u64 = 0x83; // Present | Write | PageSize (bit 7)

    // 1. PML4 setup
    // PML4[0] (identity mapping) points to id_pdpt
    var pte = id_pdpt_gpa | flags_dir;
    _ = glue.uc_mem_write(uc, pml4_gpa + 0 * 8, @ptrCast(&pte), 8);
    // PML4[273] (direct physical mapping) points to id_pdpt
    _ = glue.uc_mem_write(uc, pml4_gpa + 273 * 8, @ptrCast(&pte), 8);
    // PML4[511] (kernel mapping) points to k_pdpt
    pte = k_pdpt_gpa | flags_dir;
    _ = glue.uc_mem_write(uc, pml4_gpa + 511 * 8, @ptrCast(&pte), 8);

    // 2. Identity PDPT setup
    // PDPT[0] (for 0x00000000) points to id_pd_low
    pte = id_pd_low_gpa | flags_dir;
    _ = glue.uc_mem_write(uc, id_pdpt_gpa + 0 * 8, @ptrCast(&pte), 8);
    // PDPT[2] (for 0x80000000) points to id_pd
    pte = id_pd_gpa | flags_dir;
    _ = glue.uc_mem_write(uc, id_pdpt_gpa + 2 * 8, @ptrCast(&pte), 8);

    // 3. Kernel PDPT setup
    // PDPT[510] (for 0xffffffff80000000) points to k_pd
    pte = k_pd_gpa | flags_dir;
    _ = glue.uc_mem_write(uc, k_pdpt_gpa + 510 * 8, @ptrCast(&pte), 8);

    // 4. Identity PD setup: map 256MB starting at 0x80000000 (128 entries of 2MB)
    var i: u64 = 0;
    while (i < 128) : (i += 1) {
        const phys_addr = ram_base + (i * 0x200000);
        pte = phys_addr | flags_page;
        _ = glue.uc_mem_write(uc, id_pd_gpa + i * 8, @ptrCast(&pte), 8);
    }

    // 4b. Identity PD Low setup: map 256MB starting at 0x00000000 (128 entries of 2MB)
    i = 0;
    while (i < 128) : (i += 1) {
        const phys_addr = i * 0x200000;
        pte = phys_addr | flags_page;
        _ = glue.uc_mem_write(uc, id_pd_low_gpa + i * 8, @ptrCast(&pte), 8);
    }

    // 5. Kernel PD setup: map 256MB starting at 0xffffffff80000000 pointing to physical ram_base
    i = 0;
    while (i < 128) : (i += 1) {
        const phys_addr = ram_base + (i * 0x200000);
        pte = phys_addr | flags_page;
        _ = glue.uc_mem_write(uc, k_pd_gpa + i * 8, @ptrCast(&pte), 8);
    }
}

fn setupBootParams(uc: ?*anyopaque, ram_base: u64, ram_size: u64) void {
    const boot_params_gpa: u64 = ram_base + 0x90000; // 576KB offset (within first 1MB)
    const cmdline_gpa: u64 = boot_params_gpa + 4096;

    // 1. Write the command line string
    const cmdline = "console=ttyS0 earlyprintk=serial,ttyS0,115200 root=/dev/ram0 rw";
    _ = glue.uc_mem_write(uc, cmdline_gpa, @ptrCast(cmdline.ptr), cmdline.len + 1);

    // 2. Setup boot_params buffer
    var params = std.mem.zeroes([4096]u8);

    // Set e820_entries = 1
    params[0x1e8] = 1;

    // Set cmd_line_ptr
    const cmdline_ptr_u32 = @as(u32, @truncate(cmdline_gpa));
    std.mem.writeInt(u32, params[0x228..0x22c], cmdline_ptr_u32, .little);

    // Set e820_table[0] (RAM)
    const entry_offset = 0x2d0;
    std.mem.writeInt(u64, params[entry_offset .. entry_offset + 8], ram_base, .little); // addr
    std.mem.writeInt(u64, params[entry_offset + 8 .. entry_offset + 16], ram_size, .little); // size
    std.mem.writeInt(u32, params[entry_offset + 16 .. entry_offset + 20], @as(u32, 1), .little); // type = 1 (RAM)

    // Write boot_params to guest memory
    _ = glue.uc_mem_write(uc, boot_params_gpa, &params, params.len);

    // 3. Set %rsi to boot_params_gpa
    var rsi_val: u64 = boot_params_gpa;
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_RSI), &rsi_val);
}

/// Read the program counter (RIP) from Unicorn.
pub fn readPC(uc: ?*anyopaque) u64 {
    var rip: u64 = 0;
    _ = glue.uc_reg_read(uc, @intFromEnum(REG.UC_X86_REG_RIP), &rip);
    return rip;
}

/// Write the program counter (RIP) to Unicorn.
pub fn writePC(uc: ?*anyopaque, rip: u64) void {
    var val: u64 = rip;
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_RIP), &val);
}

/// Advance the instruction pointer (RIP) past the current IN or OUT instruction.
pub fn advanceInsnPC(uc: ?*anyopaque) void {
    const pc = readPC(uc);
    var offset: u64 = 0;
    while (offset < 4) {
        var opcode: u8 = 0;
        const err = glue.uc_mem_read(uc, pc + offset, @ptrCast(&opcode), 1);
        if (err != .UC_ERR_OK) break;
        if (opcode == 0x66 or opcode == 0x67) {
            offset += 1;
            continue;
        }
        if (opcode >= 0xE4 and opcode <= 0xE7) {
            writePC(uc, pc + offset + 2);
        } else {
            writePC(uc, pc + offset + 1);
        }
        return;
    }
    writePC(uc, pc + 1);
}

/// Handle an invalid instruction intercepted by UC_HOOK_INSN_INVALID.
///
/// Emulates RDTSC and RDTSCP instructions.
/// Returns true if handled, false to let Unicorn raise UC_ERR_INSN_INVALID.
pub fn handleInvalidInsn(uc: ?*anyopaque) bool {
    const rip = readPC(uc);
    var insn: [3]u8 = undefined;
    var ok = glue.uc_mem_read(uc, rip, &insn, 3) == .UC_ERR_OK;
    if (!ok) {
        if (translateVA(uc, rip)) |phys| {
            ok = glue.uc_mem_read(uc, phys, &insn, 3) == .UC_ERR_OK;
        }
    }
    if (!ok) return false;

    if (insn[0] == 0x0F and insn[1] == 0x31) {
        // RDTSC: Read Time-Stamp Counter
        const tsc = glue.readSModeTime();
        const eax: u32 = @truncate(tsc);
        const edx: u32 = @truncate(tsc >> 32);
        var eax_val: u64 = eax;
        var edx_val: u64 = edx;
        _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_RAX), &eax_val);
        _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_RDX), &edx_val);
        writePC(uc, rip + 2);
        return true;
    } else if (insn[0] == 0x0F and insn[1] == 0x01 and insn[2] == 0xF9) {
        // RDTSCP: Read Time-Stamp Counter and Processor ID
        const tsc = glue.readSModeTime();
        const eax: u32 = @truncate(tsc);
        const edx: u32 = @truncate(tsc >> 32);
        var eax_val: u64 = eax;
        var edx_val: u64 = edx;
        var ecx_val: u64 = 0; // IA32_TSC_AUX = 0
        _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_RAX), &eax_val);
        _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_RDX), &edx_val);
        _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_RCX), &ecx_val);
        writePC(uc, rip + 3);
        return true;
    }
    return false;
}

/// Handle a clean stop (UC_ERR_OK). Check if the instruction at `pc`
/// is a guest syscall system call and if so, perform the hypercall.
/// Returns true if handled and PC was advanced.
pub fn handleCleanStop(uc: ?*anyopaque, vc: *vcore.VirtualCore, pc: u64) bool {
    var insn: [2]u8 = undefined;
    var ok = glue.uc_mem_read(uc, pc, &insn, 2) == .UC_ERR_OK;
    if (!ok) {
        if (translateVA(uc, pc)) |phys| {
            ok = glue.uc_mem_read(uc, phys, &insn, 2) == .UC_ERR_OK;
        }
    }
    if (!ok) return false;

    // Check for `syscall` instruction: `0x0F 0x05`
    if (insn[0] == 0x0F and insn[1] == 0x05) {
        var rax: u64 = 0;
        _ = glue.uc_reg_read(uc, @intFromEnum(REG.UC_X86_REG_RAX), &rax);

        const func_id = @as(u32, @truncate(rax));

        // System control hypercalls analogous to SBI/PSCI:
        // 0x84000008 = SYSTEM_OFF (shutdown guest)
        // 0x84000009 = SYSTEM_RESET (reset guest)
        if (func_id == 0x84000008) {
            debug.printf("x86_64: SYSTEM_OFF — shutting down guest {}\n", .{vc.guest_id});
            vc.guest.terminate();
            writePC(uc, pc + 2);
            return true;
        } else if (func_id == 0x84000009) {
            debug.printf("x86_64: SYSTEM_RESET — resetting guest {}\n", .{vc.guest_id});
            vc.guest.state = .restarting;
            writePC(uc, pc + 2);
            return true;
        }
    }
    return false;
}

/// Handle a guest exception. Currently a stub.
pub fn handleException(_: ?*anyopaque, pc: u64) ExceptionAction {
    debug.printf("x86_64: exception at PC 0x{x}, handler not yet implemented\n", .{pc});
    return .unhandled;
}

/// Translate a virtual address using the 4-level x86_64 page tables.
pub fn translateVA(uc: ?*anyopaque, va: u64) ?u64 {
    var cr0: u64 = 0;
    _ = glue.uc_reg_read(uc, @intFromEnum(REG.UC_X86_REG_CR0), &cr0);
    // PG bit is bit 31 of CR0.
    if ((cr0 & (1 << 31)) == 0) return va; // Paging disabled -> flat mapping.

    var cr3: u64 = 0;
    _ = glue.uc_reg_read(uc, @intFromEnum(REG.UC_X86_REG_CR3), &cr3);
    const pml4_base = cr3 & 0x000FFFFFFFFFF000;

    // PML4 (Level 4): bits 47:39
    const pml4_idx = (va >> 39) & 0x1FF;
    var pml4_entry: u64 = 0;
    if (glue.uc_mem_read(uc, pml4_base + pml4_idx * 8, @as([*]u8, @ptrCast(&pml4_entry)), 8) != .UC_ERR_OK) return null;
    if ((pml4_entry & 1) == 0) return null;

    // PDPT (Level 3): bits 38:30
    const pdpt_base = pml4_entry & 0x000FFFFFFFFFF000;
    const pdpt_idx = (va >> 30) & 0x1FF;
    var pdpt_entry: u64 = 0;
    if (glue.uc_mem_read(uc, pdpt_base + pdpt_idx * 8, @as([*]u8, @ptrCast(&pdpt_entry)), 8) != .UC_ERR_OK) return null;
    if ((pdpt_entry & 1) == 0) return null;

    // 1GB huge page check (bit 7 of PDPT entry).
    if ((pdpt_entry & (1 << 7)) != 0) {
        return (pdpt_entry & 0x000FFFFFC0000000) | (va & 0x3FFFFFFF);
    }

    // PD (Level 2): bits 29:21
    const pd_base = pdpt_entry & 0x000FFFFFFFFFF000;
    const pd_idx = (va >> 21) & 0x1FF;
    var pd_entry: u64 = 0;
    if (glue.uc_mem_read(uc, pd_base + pd_idx * 8, @as([*]u8, @ptrCast(&pd_entry)), 8) != .UC_ERR_OK) return null;
    if ((pd_entry & 1) == 0) return null;

    // 2MB large page check (bit 7 of PD entry).
    if ((pd_entry & (1 << 7)) != 0) {
        return (pd_entry & 0x000FFFFFFFE00000) | (va & 0x1FFFFF);
    }

    // PT (Level 1): bits 20:12
    const pt_base = pd_entry & 0x000FFFFFFFFFF000;
    const pt_idx = (va >> 12) & 0x1FF;
    var pt_entry: u64 = 0;
    if (glue.uc_mem_read(uc, pt_base + pt_idx * 8, @as([*]u8, @ptrCast(&pt_entry)), 8) != .UC_ERR_OK) return null;
    if ((pt_entry & 1) == 0) return null;

    return (pt_entry & 0x000FFFFFFFFFF000) | (va & 0xFFF);
}

/// Deliver a hardware interrupt to the x86_64 guest using the IDT.
///
/// Pushes the SS, RSP, RFLAGS, CS, and RIP interrupt frame onto the stack,
/// reads the vector descriptor from the IDT, and branches to it.
pub fn deliverInterrupt(uc: ?*anyopaque, pc: u64, cause: u32) void {
    var idtr = glue.uc_x86_mmr{};
    _ = glue.uc_reg_read(uc, @intFromEnum(REG.UC_X86_REG_IDTR), &idtr);

    const vector = cause;
    if (vector * 16 > idtr.limit) return;

    const gate_addr = idtr.base + vector * 16;
    var gate: [16]u8 = undefined;
    if (glue.uc_mem_read(uc, gate_addr, &gate, 16) != .UC_ERR_OK) return;

    // Check if Present bit (bit 7 of byte 5) is 1.
    if ((gate[5] & 0x80) == 0) return;

    const offset_low = @as(u64, gate[0]) | (@as(u64, gate[1]) << 8);
    const selector = @as(u16, gate[2]) | (@as(u16, gate[3]) << 8);
    const offset_mid = @as(u64, gate[6]) | (@as(u64, gate[7]) << 8);
    const offset_high = @as(u64, gate[8]) | (@as(u64, gate[9]) << 16) | (@as(u64, gate[10]) << 24) | (@as(u64, gate[11]) << 32);

    const target_rip = offset_low | (offset_mid << 16) | (offset_high << 32);

    // Read current stack frame registers.
    var rsp: u64 = 0;
    var ss: u64 = 0;
    var cs: u64 = 0;
    var rflags: u64 = 0;
    _ = glue.uc_reg_read(uc, @intFromEnum(REG.UC_X86_REG_RSP), &rsp);
    _ = glue.uc_reg_read(uc, @intFromEnum(REG.UC_X86_REG_SS), &ss);
    _ = glue.uc_reg_read(uc, @intFromEnum(REG.UC_X86_REG_CS), &cs);
    _ = glue.uc_reg_read(uc, @intFromEnum(REG.UC_X86_REG_EFLAGS), &rflags);

    // Push SS, RSP, RFLAGS, CS, RIP onto the stack.
    rsp -= 8;
    _ = glue.uc_mem_write(uc, rsp, @ptrCast(&ss), 8);
    
    const old_rsp = rsp + 8;
    rsp -= 8;
    _ = glue.uc_mem_write(uc, rsp, @ptrCast(&old_rsp), 8);

    rsp -= 8;
    _ = glue.uc_mem_write(uc, rsp, @ptrCast(&rflags), 8);

    rsp -= 8;
    _ = glue.uc_mem_write(uc, rsp, @ptrCast(&cs), 8);

    rsp -= 8;
    var rip_val = pc;
    _ = glue.uc_mem_write(uc, rsp, @ptrCast(&rip_val), 8);

    // Load new segment state and update flags.
    var new_cs: u64 = selector;
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_CS), &new_cs);
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_RSP), &rsp);
    writePC(uc, target_rip);

    var new_rflags = rflags & ~(RFLAGS_IF | RFLAGS_TF);
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_EFLAGS), &new_rflags);
}
