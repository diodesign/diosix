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
const loader = @import("../../loader.zig");

extern const __rootvm_start: anyopaque;
extern const __rootvm_end: anyopaque;

pub const ExceptionAction = emulation.ExceptionAction;

// ---- x86_64 register ID aliases for readability ----
const REG = glue.uc_x86_reg;

// ---- x86_64 Segment Selector Indices ----
const GDT_CS_INDEX: u16 = 2;
const GDT_DS_INDEX: u16 = 3;

// ---- x86_64 RFLAGS bits ----
const RFLAGS_IF: u64 = 1 << 9; // Interrupt flag
const RFLAGS_TF: u64 = 1 << 8; // Trap flag

/// Set up initial x86_64 register state for a new emulated vcore.
pub fn initRegisters(uc: ?*anyopaque, entry: usize, ram_base: usize, ram_size: usize, early_pgt_gpa: usize, cpu_count: usize) void {
    var rip_val: u64 = entry;
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_RIP), &rip_val);

    // Set up standard GDT segment selectors to execute flat 64-bit mode code.
    var cs_val: u64 = (GDT_CS_INDEX << 3);
    var ds_val: u64 = (GDT_DS_INDEX << 3);
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_CS), &cs_val);
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_DS), &ds_val);
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_SS), &ds_val);

    // Set RFLAGS = 0x2 (Interrupts disabled, IF=0)
    var rflags_val: u64 = 0x2;
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_EFLAGS), &rflags_val);

    // Zero general-purpose registers
    var zero_val: u64 = 0;
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_RAX), &zero_val);
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_RBX), &zero_val);
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_RCX), &zero_val);
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_RDX), &zero_val);
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_RBP), &zero_val);
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_RSP), &zero_val);
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_RDI), &zero_val);

    if (early_pgt_gpa != 0) {
        const entry_va: u64 = if (entry >= 0xffffffff80000000) entry else 0xffffffff80000000 + (entry -% ram_base);
        setupBootPageTables(uc, ram_base, ram_size, ram_base + 0x10000, entry_va);

        var efer_msr = glue.uc_x86_msr{
            .rid = 0xc0000080, // IA32_EFER
            .value = 0x500, // LME | LMA
        };
        _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_MSR), &efer_msr);

        var cr3_val: u64 = ram_base + 0x10000;
        var cr4_val: u64 = 0x20; // PAE
        var cr0_val: u64 = 0x80010011; // PG, WP, PE, ET
        _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_CR3), &cr3_val);
        _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_CR4), &cr4_val);
        _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_CR0), &cr0_val);

        // RSI must point to boot_params GPA (0x90000 in low 1MB memory) for the 64-bit boot protocol.
        var rsi_val: u64 = 0x90000;
        _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_RSI), &rsi_val);

        var apic_base_msr = glue.uc_x86_msr{
            .rid = 0x1b, // IA32_APIC_BASE
            .value = 0xfee00900, // base=0xfee00000, enable=1, bsp=1
        };
        _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_MSR), &apic_base_msr);
    }

    // Setup boot_params for the guest Linux kernel
    setupBootParams(uc, ram_base, ram_size);

    // Generate and write ACPI tables below 1MB (at 0xe0000 physical)
    writeAcpiTables(uc, cpu_count);
}

const BootPageAllocator = struct {
    next_gpa: u64,
    limit_gpa: u64,

    pub fn allocPage(self: *@This(), uc: ?*anyopaque) !u64 {
        if (self.next_gpa >= self.limit_gpa) return error.OutOfMemory;
        const page_gpa = self.next_gpa;
        self.next_gpa += 4096;
        var zero_buf = std.mem.zeroes([4096]u8);
        _ = glue.uc_mem_write(uc, page_gpa, @ptrCast(&zero_buf), 4096);
        return page_gpa;
    }
};

fn mapRange2MB(uc: ?*anyopaque, page_alloc: *BootPageAllocator, pml4_gpa: u64, va_start: u64, pa_start: u64, size: u64, flags_page: u64) void {
    const flags_dir: u64 = 7; // Present | Write | User
    var offset: u64 = 0;
    while (offset < size) : (offset += 0x200000) {
        const va = va_start + offset;
        const pa = pa_start + offset;

        // Level 4 (PML4)
        const pml4_idx = (va >> 39) & 0x1ff;
        var pml4_entry: u64 = 0;
        _ = glue.uc_mem_read(uc, pml4_gpa + pml4_idx * 8, @ptrCast(&pml4_entry), 8);
        var pdpt_gpa: u64 = 0;
        if ((pml4_entry & 1) == 0) {
            pdpt_gpa = page_alloc.allocPage(uc) catch return;
            pml4_entry = pdpt_gpa | flags_dir;
            _ = glue.uc_mem_write(uc, pml4_gpa + pml4_idx * 8, @ptrCast(&pml4_entry), 8);
        } else {
            pdpt_gpa = pml4_entry & 0x000ffffffffff000;
        }

        // Level 3 (PDPT)
        const pdpt_idx = (va >> 30) & 0x1ff;
        var pdpt_entry: u64 = 0;
        _ = glue.uc_mem_read(uc, pdpt_gpa + pdpt_idx * 8, @ptrCast(&pdpt_entry), 8);
        var pd_gpa: u64 = 0;
        if ((pdpt_entry & 1) == 0) {
            pd_gpa = page_alloc.allocPage(uc) catch return;
            pdpt_entry = pd_gpa | flags_dir;
            _ = glue.uc_mem_write(uc, pdpt_gpa + pdpt_idx * 8, @ptrCast(&pdpt_entry), 8);
        } else {
            pd_gpa = pdpt_entry & 0x000ffffffffff000;
        }

        // Level 2 (PD)
        const pd_idx = (va >> 21) & 0x1ff;
        const pd_entry = pa | flags_page; // 0x83 = Present | Write | PageSize
        _ = glue.uc_mem_write(uc, pd_gpa + pd_idx * 8, @ptrCast(&pd_entry), 8);
    }
}

fn setupBootPageTables(uc: ?*anyopaque, ram_base: u64, ram_size: u64, early_pgt_gpa: u64, entry_va: u64) void {
    const pml4_gpa = early_pgt_gpa;
    var page_alloc = BootPageAllocator{
        .next_gpa = early_pgt_gpa,
        .limit_gpa = early_pgt_gpa + 0x100000, // 1MB buffer for boot page tables
    };
    _ = page_alloc.allocPage(uc) catch return; // Allocate PML4 root page at early_pgt_gpa

    const flags_2mb: u64 = 0x83; // Present | Write | PageSize (bit 7)

    // 1. Identity map low 256MB (for BIOS / real-mode headers / ACPI / boot_params)
    mapRange2MB(uc, &page_alloc, pml4_gpa, 0, 0, 256 * 1024 * 1024, flags_2mb);

    // 2. Identity map full RAM (ram_base .. ram_base + ram_size)
    mapRange2MB(uc, &page_alloc, pml4_gpa, ram_base, ram_base, ram_size, flags_2mb);

    // 3. Direct physical mapping for all standard 64-bit Linux kernel offsets
    const direct_vas = [_]u64{
        0xffff888000000000,
        0xffff880000000000,
        0xffff800000000000,
    };
    for (direct_vas) |dva| {
        mapRange2MB(uc, &page_alloc, pml4_gpa, dva, 0, 256 * 1024 * 1024, flags_2mb);
        mapRange2MB(uc, &page_alloc, pml4_gpa, dva + ram_base, ram_base, ram_size, flags_2mb);
    }

    // 4. Kernel virtual mapping (entry_va & 0xffffffff80000000 ..)
    const kernel_va: u64 = entry_va & 0xffffffff80000000;
    mapRange2MB(uc, &page_alloc, pml4_gpa, kernel_va, ram_base, ram_size, flags_2mb);

    const entry_va_trunc = entry_va & 0xfffffffffffff;
    const trunc_kernel_va = entry_va_trunc & 0xffffffff80000000;
    if (trunc_kernel_va != kernel_va) {
        mapRange2MB(uc, &page_alloc, pml4_gpa, trunc_kernel_va, ram_base, ram_size, flags_2mb);
    }
}

fn setupBootParams(uc: ?*anyopaque, ram_base: u64, ram_size: u64) void {
    const boot_params_gpa: u64 = 0x90000; // 576KB offset in low 1MB memory
    const cmdline_gpa: u64 = boot_params_gpa + 4096;

    // 1. Write the command line string
    const cmdline = "console=ttyS0 earlyprintk=serial,ttyS0,115200,keep loglevel=8 root=/dev/ram0 rw mitigations=off";
    _ = glue.uc_mem_write(uc, cmdline_gpa, @ptrCast(cmdline.ptr), cmdline.len + 1);

    // 2. Setup boot_params buffer
    var params = std.mem.zeroes([4096]u8);

    // 64-Bit Boot Protocol Specification Overrides:
    params[0x210] = 0xFF; // type_of_loader = 0xFF (custom bootloader)
    params[0x211] |= 0x01; // loadflags: LOADED_HIGH = 1

    // Set e820_entries = 2
    params[0x1e8] = 2;

    // Set cmd_line_ptr
    const cmdline_ptr_u32 = @as(u32, @truncate(cmdline_gpa));
    std.mem.writeInt(u32, params[0x228..0x22c], cmdline_ptr_u32, .little);

    // E820 Entry 0: Low RAM (0x0 .. 0x9f000)
    var entry_offset: usize = 0x2d0;
    std.mem.writeInt(u64, params[entry_offset..][0..8], 0, .little);
    std.mem.writeInt(u64, params[entry_offset + 8..][0..8], 0x9f000, .little);
    std.mem.writeInt(u32, params[entry_offset + 16..][0..4], @as(u32, 1), .little);

    // E820 Entry 1: Main VM RAM (ram_base .. ram_base + ram_size)
    entry_offset += 20;
    std.mem.writeInt(u64, params[entry_offset..][0..8], ram_base, .little);
    std.mem.writeInt(u64, params[entry_offset + 8..][0..8], ram_size, .little);
    std.mem.writeInt(u32, params[entry_offset + 16..][0..4], @as(u32, 1), .little);

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
pub fn handleInvalidInsn(uc: ?*anyopaque, vc: *vcore.VirtualCore) bool {
    const rip = readPC(uc);
    var insn: [15]u8 = undefined;
    var ok = glue.uc_mem_read(uc, rip, &insn, 15) == .UC_ERR_OK;
    if (!ok) {
        if (translateVA(uc, vc.guest.space.base_hpa, rip)) |phys| {
            ok = readPhysMem(vc.guest.space.base_hpa, phys, &insn);
        }
    }
    if (!ok) return false;

    // Scan past prefix bytes
    var idx: usize = 0;
    while (idx < 15) {
        const byte = insn[idx];
        if (byte == 0x66 or byte == 0x67 or (byte >= 0x40 and byte <= 0x4f) or byte == 0xf0 or byte == 0xf2 or byte == 0xf3) {
            idx += 1;
        } else {
            break;
        }
    }

    if (idx < 14) {
        const op0 = insn[idx];
        const op1 = insn[idx + 1];
        // Check for UD2 (0x0F 0x0B)
        if (op0 == 0x0F and op1 == 0x0B) {
            debug.printf("Hypervisor: handled guest UD2 warning trap at PC 0x{x}\n", .{rip});
            writePC(uc, rip + idx + 2);
            return true;
        }
        // Check for UD1 (0x0F 0xb9)
        if (op0 == 0x0F and op1 == 0xb9) {
            debug.printf("Hypervisor: handled guest UD1 warning trap at PC 0x{x}\n", .{rip});
            writePC(uc, rip + idx + 3); // 2 bytes opcode + 1 ModR/M byte
            return true;
        }
    }

    if (insn[0] == 0x0F and (insn[1] == 0x31 or (insn[1] == 0x01 and insn[2] == 0xF9))) {
        const tsc = emulation.getVirtualSModeTime(vc) * 250;

        const eax: u32 = @truncate(tsc);
        const edx: u32 = @truncate(tsc >> 32);
        var eax_val: u64 = eax;
        var edx_val: u64 = edx;
        _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_RAX), &eax_val);
        _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_RDX), &edx_val);

        if (insn[1] == 0x31) {
            writePC(uc, rip + 2);
        } else {
            var ecx_val: u64 = 0; // IA32_TSC_AUX = 0
            _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_RCX), &ecx_val);
            writePC(uc, rip + 3);
        }
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
        if (translateVA(uc, vc.guest.space.base_hpa, pc)) |phys| {
            ok = readPhysMem(vc.guest.space.base_hpa, phys, &insn);
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

fn readPhysMem(hpa_base: u64, phys_addr: u64, buf: []u8) bool {
    const host_ptr = @as([*]const u8, @ptrFromInt(hpa_base + phys_addr));
    @memcpy(buf, host_ptr[0..buf.len]);
    return true;
}

fn writePhysMem(hpa_base: u64, phys_addr: u64, buf: []const u8) bool {
    const host_ptr = @as([*]u8, @ptrFromInt(hpa_base + phys_addr));
    @memcpy(host_ptr[0..buf.len], buf);
    return true;
}

/// Translate a virtual address using the 4-level x86_64 page tables.
pub fn translateVA(uc: ?*anyopaque, hpa_base: u64, va: u64) ?u64 {
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
    if (!readPhysMem(hpa_base, pml4_base + pml4_idx * 8, std.mem.asBytes(&pml4_entry))) return null;
    if ((pml4_entry & 1) == 0) return null;

    // PDPT (Level 3): bits 38:30
    const pdpt_base = pml4_entry & 0x000FFFFFFFFFF000;
    const pdpt_idx = (va >> 30) & 0x1FF;
    var pdpt_entry: u64 = 0;
    if (!readPhysMem(hpa_base, pdpt_base + pdpt_idx * 8, std.mem.asBytes(&pdpt_entry))) return null;
    if ((pdpt_entry & 1) == 0) return null;

    // 1GB huge page check (bit 7 of PDPT entry).
    if ((pdpt_entry & (1 << 7)) != 0) {
        return (pdpt_entry & 0x000FFFFFC0000000) | (va & 0x3FFFFFFF);
    }

    // PD (Level 2): bits 29:21
    const pd_base = pdpt_entry & 0x000FFFFFFFFFF000;
    const pd_idx = (va >> 21) & 0x1FF;
    var pd_entry: u64 = 0;
    if (!readPhysMem(hpa_base, pd_base + pd_idx * 8, std.mem.asBytes(&pd_entry))) return null;
    if ((pd_entry & 1) == 0) return null;

    // 2MB large page check (bit 7 of PD entry).
    if ((pd_entry & (1 << 7)) != 0) {
        return (pd_entry & 0x000FFFFFFFE00000) | (va & 0x1FFFFF);
    }

    // PT (Level 1): bits 20:12
    const pt_base = pd_entry & 0x000FFFFFFFFFF000;
    const pt_idx = (va >> 12) & 0x1FF;
    var pt_entry: u64 = 0;
    if (!readPhysMem(hpa_base, pt_base + pt_idx * 8, std.mem.asBytes(&pt_entry))) return null;
    if ((pt_entry & 1) == 0) return null;

    return (pt_entry & 0x000FFFFFFFFFF000) | (va & 0xFFF);
}

/// Deliver a hardware interrupt to the x86_64 guest using the IDT.
///
/// Pushes the SS, RSP, RFLAGS, CS, and RIP interrupt frame onto the stack,
/// reads the vector descriptor from the IDT, and branches to it.
pub fn deliverInterrupt(uc: ?*anyopaque, hpa_base: u64, pc: u64, cause: u32) void {
    var idtr = glue.uc_x86_mmr{};
    _ = glue.uc_reg_read(uc, @intFromEnum(REG.UC_X86_REG_IDTR), &idtr);

    const vector = cause;
    if (vector * 16 > idtr.limit) {
        debug.printf("deliverInterrupt FAILED: vector {} exceeds IDT limit {}\n", .{vector, idtr.limit});
        return;
    }

    const gate_addr = idtr.base + vector * 16;
    var gate: [16]u8 = undefined;
    var ok = glue.uc_mem_read(uc, gate_addr, &gate, 16) == .UC_ERR_OK;
    if (!ok) {
        if (translateVA(uc, hpa_base, gate_addr)) |phys| {
            ok = readPhysMem(hpa_base, phys, &gate);
        }
    }
    if (!ok) {
        debug.printf("deliverInterrupt FAILED: failed to read IDT gate for vector {}\n", .{vector});
        return;
    }

    // Check if Present bit (bit 7 of byte 5) is 1.
    if ((gate[5] & 0x80) == 0) {
        debug.printf("deliverInterrupt FAILED: IDT gate for vector {} is not present (gate[5]=0x{x})\n", .{vector, gate[5]});
        return;
    }

    const offset_low = @as(u64, gate[0]) | (@as(u64, gate[1]) << 8);
    const selector = @as(u16, gate[2]) | (@as(u16, gate[3]) << 8);
    const offset_mid = @as(u64, gate[6]) | (@as(u64, gate[7]) << 8);
    const offset_high = @as(u64, gate[8]) | (@as(u64, gate[9]) << 8) | (@as(u64, gate[10]) << 16) | (@as(u64, gate[11]) << 24);

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
    const stack_size = 40;
    const target_rsp = rsp - stack_size;

    var frame: [5]u64 = undefined;
    frame[0] = pc;
    frame[1] = cs;
    frame[2] = rflags;
    frame[3] = rsp;
    frame[4] = ss;

    var write_ok = glue.uc_mem_write(uc, target_rsp, @ptrCast(&frame), 40) == .UC_ERR_OK;
    if (!write_ok) {
        if (translateVA(uc, hpa_base, target_rsp)) |phys_rsp| {
            write_ok = writePhysMem(hpa_base, phys_rsp, std.mem.asBytes(&frame)[0..stack_size]);
        }
    }
    if (!write_ok) {
        debug.printf("deliverInterrupt FAILED: stack write failed to target_rsp=0x{x}\n", .{target_rsp});
        return;
    }

    // Load new segment state and update flags.
    var new_cs: u64 = selector;
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_CS), &new_cs);
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_RSP), &target_rsp);
    writePC(uc, target_rip);

    var new_rflags = rflags & ~(RFLAGS_IF | RFLAGS_TF);
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_EFLAGS), &new_rflags);
}

pub fn deliverFault(uc: ?*anyopaque, hpa_base: u64, pc: u64, vector: u32, error_code: ?u32, cr2: ?u64) void {
    var idtr = glue.uc_x86_mmr{};
    _ = glue.uc_reg_read(uc, @intFromEnum(REG.UC_X86_REG_IDTR), &idtr);

    if (vector * 16 > idtr.limit) return;

    const gate_addr = idtr.base + vector * 16;
    var gate: [16]u8 = undefined;
    var ok = glue.uc_mem_read(uc, gate_addr, &gate, 16) == .UC_ERR_OK;
    if (!ok) {
        if (translateVA(uc, hpa_base, gate_addr)) |phys| {
            ok = readPhysMem(hpa_base, phys, &gate);
        }
    }
    if (!ok) return;

    // Check if Present bit (bit 7 of byte 5) is 1.
    if ((gate[5] & 0x80) == 0) return;

    const offset_low = @as(u64, gate[0]) | (@as(u64, gate[1]) << 8);
    const selector = @as(u16, gate[2]) | (@as(u16, gate[3]) << 8);
    const offset_mid = @as(u64, gate[6]) | (@as(u64, gate[7]) << 8);
    const offset_high = @as(u64, gate[8]) | (@as(u64, gate[9]) << 8) | (@as(u64, gate[10]) << 16) | (@as(u64, gate[11]) << 24);

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

    // Push SS, RSP, RFLAGS, CS, RIP, and optionally error code onto the stack.
    const has_error = error_code != null;
    const stack_size: u64 = if (has_error) 48 else 40;
    const target_rsp = rsp - stack_size;

    var frame: [6]u64 = undefined;
    if (has_error) {
        frame[0] = error_code.?;
        frame[1] = pc;
        frame[2] = cs;
        frame[3] = rflags;
        frame[4] = rsp;
        frame[5] = ss;
    } else {
        frame[0] = pc;
        frame[1] = cs;
        frame[2] = rflags;
        frame[3] = rsp;
        frame[4] = ss;
        frame[5] = 0;
    }

    var write_ok = glue.uc_mem_write(uc, target_rsp, @ptrCast(&frame), stack_size) == .UC_ERR_OK;
    if (!write_ok) {
        if (translateVA(uc, hpa_base, target_rsp)) |phys_rsp| {
            write_ok = writePhysMem(hpa_base, phys_rsp, std.mem.asBytes(&frame)[0..stack_size]);
        }
    }
    if (!write_ok) return;

    if (cr2) |val| {
        var cr2_val = val;
        _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_CR2), &cr2_val);
    }

    // Load new segment state and update flags.
    var new_cs: u64 = selector;
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_CS), &new_cs);
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_RSP), &target_rsp);
    writePC(uc, target_rip);

    var new_rflags = rflags & ~(RFLAGS_IF | RFLAGS_TF);
    _ = glue.uc_reg_write(uc, @intFromEnum(REG.UC_X86_REG_EFLAGS), &new_rflags);
}

pub fn writeAcpiTables(uc: ?*anyopaque, cpu_count: usize) void {
    var acpi_buf = std.mem.zeroes([512]u8);
    
    // Offset definitions relative to 0xe0000 physical
    const rsdp_offset = 0x0;
    const rsdt_offset = 0x20;
    const madt_offset = 0x60;
    
    // 1. Build MADT
    @memcpy(acpi_buf[madt_offset..madt_offset+4], "APIC");
    // Length: 36 (header) + 4 (local APIC addr) + 4 (flags) + cpu_count * 8 (local APIC) + 12 (IO APIC) + 10 (Interrupt Override)
    const madt_len = 36 + 8 + cpu_count * 8 + 12 + 10;
    std.mem.writeInt(u32, acpi_buf[madt_offset+4..][0..4], @as(u32, @intCast(madt_len)), .little);
    acpi_buf[madt_offset+8] = 1; // Revision
    @memcpy(acpi_buf[madt_offset+10..madt_offset+16], "DIOSIX");
    @memcpy(acpi_buf[madt_offset+16..madt_offset+24], "DIOSIX  ");
    std.mem.writeInt(u32, acpi_buf[madt_offset+24..][0..4], 1, .little); // OEM Revision
    @memcpy(acpi_buf[madt_offset+28..madt_offset+32], "DIOS");
    std.mem.writeInt(u32, acpi_buf[madt_offset+32..][0..4], 1, .little); // Creator Revision
    
    // Local APIC Address: 0xfee00000
    std.mem.writeInt(u32, acpi_buf[madt_offset+36..][0..4], 0xfee00000, .little);
    // Flags (PCAT compatible = 1)
    std.mem.writeInt(u32, acpi_buf[madt_offset+40..][0..4], 1, .little);
    
    var offset: usize = madt_offset + 44;
    // Local APIC entries
    var cpu_id: u8 = 0;
    while (cpu_id < cpu_count) : (cpu_id += 1) {
        acpi_buf[offset] = 0; // Type 0: Processor Local APIC
        acpi_buf[offset+1] = 8; // Length
        acpi_buf[offset+2] = cpu_id; // ACPI Processor ID
        acpi_buf[offset+3] = cpu_id; // APIC ID
        std.mem.writeInt(u32, acpi_buf[offset+4..][0..4], 1, .little); // Flags (Enabled = 1)
        offset += 8;
    }
    
    // I/O APIC entry
    acpi_buf[offset] = 1; // Type 1: I/O APIC
    acpi_buf[offset+1] = 12; // Length
    acpi_buf[offset+2] = @as(u8, @intCast(cpu_count)); // I/O APIC ID
    acpi_buf[offset+3] = 0; // Reserved
    std.mem.writeInt(u32, acpi_buf[offset+4..][0..4], 0xfec00000, .little); // Address
    std.mem.writeInt(u32, acpi_buf[offset+8..][0..4], 0, .little); // GSI Base
    offset += 12;
    
    // Interrupt Source Override (IRQ 0 to GSI 2)
    acpi_buf[offset] = 2; // Type 2: Interrupt Source Override
    acpi_buf[offset+1] = 10; // Length
    acpi_buf[offset+2] = 0; // Bus (ISA)
    acpi_buf[offset+3] = 0; // Source (IRQ 0)
    std.mem.writeInt(u32, acpi_buf[offset+4..][0..4], 2, .little); // Global System Interrupt (2)
    std.mem.writeInt(u16, acpi_buf[offset+8..][0..2], 0, .little); // Flags
    
    // Set MADT Checksum
    const madt_slice = acpi_buf[madt_offset..madt_offset+madt_len];
    var madt_sum: u8 = 0;
    for (madt_slice) |b| {
        madt_sum = madt_sum +% b;
    }
    acpi_buf[madt_offset+9] = 0 -% madt_sum;
    
    // 2. Build RSDT
    @memcpy(acpi_buf[rsdt_offset..rsdt_offset+4], "RSDT");
    const rsdt_len = 36 + 4; // Header + 1 entry pointer
    std.mem.writeInt(u32, acpi_buf[rsdt_offset+4..][0..4], rsdt_len, .little);
    acpi_buf[rsdt_offset+8] = 1; // Revision
    @memcpy(acpi_buf[rsdt_offset+10..rsdt_offset+16], "DIOSIX");
    @memcpy(acpi_buf[rsdt_offset+16..rsdt_offset+24], "DIOSIX  ");
    std.mem.writeInt(u32, acpi_buf[rsdt_offset+24..][0..4], 1, .little);
    @memcpy(acpi_buf[rsdt_offset+28..rsdt_offset+32], "DIOS");
    std.mem.writeInt(u32, acpi_buf[rsdt_offset+32..][0..4], 1, .little);
    // Entry 0: Pointer to MADT
    std.mem.writeInt(u32, acpi_buf[rsdt_offset+36..][0..4], 0x000e0060, .little);
    
    // Set RSDT Checksum
    const rsdt_slice = acpi_buf[rsdt_offset..rsdt_offset+rsdt_len];
    var rsdt_sum: u8 = 0;
    for (rsdt_slice) |b| {
        rsdt_sum = rsdt_sum +% b;
    }
    acpi_buf[rsdt_offset+9] = 0 -% rsdt_sum;
    
    // 3. Build RSDP
    @memcpy(acpi_buf[rsdp_offset..rsdp_offset+8], "RSD PTR ");
    acpi_buf[rsdp_offset+8] = 0; // Checksum (to be updated)
    @memcpy(acpi_buf[rsdp_offset+9..rsdp_offset+15], "DIOSIX");
    acpi_buf[rsdp_offset+15] = 0; // Revision (0 = ACPI 1.0)
    std.mem.writeInt(u32, acpi_buf[rsdp_offset+16..][0..4], 0x000e0020, .little); // RSDT Address
    
    // Set RSDP Checksum
    const rsdp_slice = acpi_buf[rsdp_offset..rsdp_offset+20];
    var rsdp_sum: u8 = 0;
    for (rsdp_slice) |b| {
        rsdp_sum = rsdp_sum +% b;
    }
    acpi_buf[rsdp_offset+8] = 0 -% rsdp_sum;
    
    // Write to guest RAM at physical 0xe0000
    _ = glue.uc_mem_write(uc, 0xe0000, &acpi_buf, acpi_buf.len);

    // Write MP tables at physical 0xf0000
    var mp_buf = std.mem.zeroes([512]u8);
    const mpp_offset = 0x0;
    const mpc_offset = 0x20;
    
    // 1. Build MP Configuration Table Header
    @memcpy(mp_buf[mpc_offset..mpc_offset+4], "PCMP");
    
    var mp_off: usize = mpc_offset + 44;
    // Processor Entries
    var id: u8 = 0;
    while (id < cpu_count) : (id += 1) {
        mp_buf[mp_off] = 0; // Type 0: Processor
        mp_buf[mp_off+1] = id; // Local APIC ID
        mp_buf[mp_off+2] = 0x15; // Local APIC Version
        mp_buf[mp_off+3] = if (id == 0) @as(u8, 3) else @as(u8, 1); // Flags (Enabled, BSP status)
        std.mem.writeInt(u32, mp_buf[mp_off+4..][0..4], 0x00000600, .little); // CPU Signature
        std.mem.writeInt(u32, mp_buf[mp_off+8..][0..4], 0x000001ff, .little); // Feature Flags
        mp_off += 20;
    }
    
    // Bus Entry
    mp_buf[mp_off] = 1; // Type 1: Bus
    mp_buf[mp_off+1] = 0; // Bus ID 0
    @memcpy(mp_buf[mp_off+2..mp_off+8], "ISA   ");
    mp_off += 8;
    
    // I/O APIC Entry
    mp_buf[mp_off] = 2; // Type 2: I/O APIC
    mp_buf[mp_off+1] = @as(u8, @intCast(cpu_count)); // ID
    mp_buf[mp_off+2] = 0x11; // Version
    mp_buf[mp_off+3] = 1; // Flags (Enabled)
    std.mem.writeInt(u32, mp_buf[mp_off+4..][0..4], 0xfec00000, .little); // Address
    mp_off += 8;
    
    // Interrupt Assignment Entries (route all ISA interrupts to IO APIC)
    var irq: u8 = 0;
    var mp_entry_count: u16 = @as(u16, @intCast(cpu_count)) + 2; // cpu_count + 1 Bus + 1 I/O APIC
    while (irq < 16) : (irq += 1) {
        if (irq == 2) continue; // Skip Cascade IRQ 2
        
        mp_buf[mp_off] = 3; // Type 3: I/O Interrupt Assignment
        mp_buf[mp_off+1] = 0; // INT
        std.mem.writeInt(u16, mp_buf[mp_off+2..][0..2], 0, .little); // Flags
        mp_buf[mp_off+4] = 0; // Source Bus ID
        mp_buf[mp_off+5] = irq; // Source Bus IRQ
        mp_buf[mp_off+6] = @as(u8, @intCast(cpu_count)); // Dest I/O APIC ID
        mp_buf[mp_off+7] = if (irq == 0) @as(u8, 2) else irq; // Dest I/O APIC INTIN# (Timer is GSI 2)
        mp_off += 8;
        mp_entry_count += 1;
    }
    
    const mpc_len = mp_off - mpc_offset;
    std.mem.writeInt(u16, mp_buf[mpc_offset+4..][0..2], @as(u16, @intCast(mpc_len)), .little);
    mp_buf[mpc_offset+6] = 4; // Spec Rev 4
    @memcpy(mp_buf[mpc_offset+8..mpc_offset+16], "DIOSIX  ");
    @memcpy(mp_buf[mpc_offset+16..mpc_offset+28], "0.1         ");
    std.mem.writeInt(u16, mp_buf[mpc_offset+32..][0..2], mp_entry_count, .little); // Entry count
    std.mem.writeInt(u32, mp_buf[mpc_offset+34..][0..4], 0xfee00000, .little); // Local APIC addr
    
    // Checksum MP Configuration Table
    const mpc_slice = mp_buf[mpc_offset..mpc_offset+mpc_len];
    var mpc_sum: u8 = 0;
    for (mpc_slice) |b| {
        mpc_sum = mpc_sum +% b;
    }
    mp_buf[mpc_offset+7] = 0 -% mpc_sum;
    
    // 2. Build MP Floating Pointer Structure
    @memcpy(mp_buf[mpp_offset..mpp_offset+4], "_MP_");
    std.mem.writeInt(u32, mp_buf[mpp_offset+4..][0..4], 0x000f0020, .little); // Configuration Table Address
    mp_buf[mpp_offset+8] = 1; // Length in paragraphs
    mp_buf[mpp_offset+9] = 4; // Spec Rev 4 (v1.4)
    
    // Checksum MP Floating Pointer Structure
    const mpp_slice = mp_buf[mpp_offset..mpp_offset+16];
    var mpp_sum: u8 = 0;
    for (mpp_slice) |b| {
        mpp_sum = mpp_sum +% b;
    }
    mp_buf[mpp_offset+10] = 0 -% mpp_sum;
    
    _ = glue.uc_mem_write(uc, 0xf0000, &mp_buf, mp_buf.len);
}

