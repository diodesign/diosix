// Cross-architecture guest VM emulation layer using Unicorn Engine.
//
// This module provides the architecture-independent emulation loop.
// Architecture-specific instruction handling (exception classification,
// CSR emulation, page table translation, syscall forwarding) is delegated
// to handlers in the arch/ directory.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const vcore = @import("vcore.zig");
const guest = @import("guest.zig");
const glue = @import("unicorn.zig");
const riscv = @import("arch/riscv64/riscv.zig");
const debug = @import("debug.zig");
const sbi = @import("arch/riscv32/sbi.zig");
const psci = @import("arch/aarch64/psci.zig");
const pcore = @import("pcore.zig");
const loader = @import("loader.zig");

extern const __rootvm_start: u8;
extern const __rootvm_end: u8;

/// Result of handling an exception from Unicorn.
pub const ExceptionAction = enum {
    /// Exception was emulated (e.g., CSR read). Resume at updated PC.
    emulated,
    /// Exception was delivered to the guest's trap handler via stvec/vbar.
    delivered,
    /// Exception could not be handled. Stop emulation.
    unhandled,
    /// Guest requested a wait-for-interrupt.
    wfi,
};

// Architecture-specific handlers
const rv32 = @import("arch/riscv32/riscv32.zig");
const aarch64 = @import("arch/aarch64/aarch64.zig");
const x86_64 = @import("arch/x86_64/x86_64.zig");

// ---- Named constants (avoid magic numbers) ----

/// Unicorn control command to set the TCG translation buffer size.
/// Encoded as UC_CTL_WRITE | UC_CTL_TB_REQUEST_CACHE (0x0d).
const UC_CTL_TB_CACHE_SIZE: c_uint = 0x4400000d;

/// QEMU virt platform UART base address (NS16550A).
const QEMU_VIRT_UART_BASE: u64 = 0x10000000;

/// Maximum number of exception-stop cycles before the emulation loop
/// yields back to the scheduler. Prevents runaway exception storms.
const EXCEPTION_BUDGET: u32 = 1_000_000;

const UC_HOOK_CODE: c_int = 4;

fn scHookCallback(uc: ?*anyopaque, address: u64, size: u32, user_data: ?*anyopaque) callconv(.c) void {
    _ = size;
    _ = user_data;
    const guard = glue.TpGuard.init();
    defer guard.deinit();

    // Read the instruction at the current PC (which is address)
    var insn: u32 = 0;
    if (glue.uc_mem_read(uc, address, @ptrCast(&insn), 4) != .UC_ERR_OK) return;

    // Decode sc.w:
    // Format: 00011 aq rl rs2 rs1 funct3 rd opcode
    // rs2 is bits 20-24 (source register to store)
    // rs1 is bits 15-19 (base pointer register)
    // rd is bits 7-11 (destination success/failure register)
    const rs2 = (insn >> 20) & 0x1f;
    const rs1 = (insn >> 15) & 0x1f;
    const rd = (insn >> 7) & 0x1f;

    // Map register index (0..31) to Unicorn register enum (UC_RISCV_REG_X0 = 1, etc.)
    const uc_rs1 = @as(c_int, @intCast(rs1)) + 1;
    const uc_rs2 = @as(c_int, @intCast(rs2)) + 1;
    const uc_rd = @as(c_int, @intCast(rd)) + 1;

    // Read register values
    var rs1_val: u32 = 0;
    var rs2_val: u32 = 0;
    _ = glue.uc_reg_read(uc, uc_rs1, &rs1_val);
    _ = glue.uc_reg_read(uc, uc_rs2, &rs2_val);

    // Emulate the store: write rs2_val to address in rs1_val
    _ = glue.uc_mem_write(uc, rs1_val, @ptrCast(&rs2_val), 4);

    // Set destination register rd to 0 (success status for sc.w)
    var zero: u32 = 0;
    _ = glue.uc_reg_write(uc, uc_rd, &zero);

    // Advance PC by 4 to skip the sc.w instruction
    const next_pc = address + 4;
    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_PC), &next_pc);
}

fn idleEnableInterruptsHook(uc: ?*anyopaque, address: u64, size: u32, user_data: ?*anyopaque) callconv(.c) void {
    _ = size;
    _ = address;
    const guard = glue.TpGuard.init();
    defer guard.deinit();

    const vc = @as(*vcore.VirtualCore, @ptrCast(@alignCast(user_data)));
    const em = &vc.exec_path.emulated;
    const sub = &em.sub_vcores[em.active_sub_vcore];

    var current_priv: u32 = 0;
    _ = glue.uc_reg_read(uc, rv32.UC_REG_PRIV, &current_priv);

    var m_priv: u32 = 3;
    _ = glue.uc_reg_write(uc, rv32.UC_REG_PRIV, &m_priv);

    var mstatus: u64 = 0;
    var sie: u64 = 0;
    _ = glue.uc_reg_read(uc, rv32.UC_REG_MSTATUS, &mstatus);
    _ = glue.uc_reg_read(uc, rv32.UC_REG_SIE, &sie);

    const SSTATUS_SIE: u64 = 1 << 1;
    const sie_enabled = ((mstatus & SSTATUS_SIE) != 0);

    if (sie_enabled) {
        const SIE_STIE: u64 = 1 << 5;
        const SIE_SSIE: u64 = 1 << 1;
        const timer_pending = sub.timer_scheduled and (em.virtual_time >= sub.timer_target);
        const ipi_pending = @atomicLoad(bool, &sub.pending_ipi, .acquire);

        var mip: u64 = 0;
        _ = glue.uc_reg_read(uc, rv32.UC_REG_MIP, &mip);

        var changed = false;
        if (timer_pending and (sie & SIE_STIE) != 0) {
            mip |= 1 << 5; // MIP_STIP
            changed = true;
        }
        if (ipi_pending and (sie & SIE_SSIE) != 0) {
            mip |= 1 << 1; // MIP_SSIP
            _ = @atomicRmw(bool, &sub.pending_ipi, .Xchg, false, .acq_rel);
            changed = true;
        }

        if (changed) {
            _ = glue.uc_reg_write(uc, rv32.UC_REG_MIP, &mip);
        }
    }

    _ = glue.uc_reg_write(uc, rv32.UC_REG_PRIV, &current_priv);
}

fn x86_64CopyBootdataTrace(uc: ?*anyopaque, address: u64, size: u32, user_data: ?*anyopaque) callconv(.c) void {
    const guard = glue.TpGuard.init();
    defer guard.deinit();
    _ = size;
    _ = user_data;
    var rsi: u64 = 0;
    var rdi: u64 = 0;
    var rsp: u64 = 0;
    var cr3: u64 = 0;
    var cr2: u64 = 0;
    _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_x86_reg.UC_X86_REG_RSI), &rsi);
    _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_x86_reg.UC_X86_REG_RDI), &rdi);
    _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_x86_reg.UC_X86_REG_RSP), &rsp);
    _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_x86_reg.UC_X86_REG_CR3), &cr3);
    _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_x86_reg.UC_X86_REG_CR2), &cr2);
    var pte_273: u64 = 0;
    _ = glue.uc_mem_read(uc, cr3 + 273 * 8, @ptrCast(&pte_273), 8);
    if (pte_273 == 0) {
        pte_273 = 0x80011007; // (ram_base + 0x11000) | 7
        _ = glue.uc_mem_write(uc, cr3 + 273 * 8, @ptrCast(&pte_273), 8);
        debug.printf("emulation: dynamically mapped CR3[273] = 0x80011007\n", .{});
    }
    debug.printf("x86_64 copy_bootdata trace: pc=0x{x} RSI=0x{x} RDI=0x{x} RSP=0x{x} CR3=0x{x} CR2=0x{x} PML4[273]=0x{x}\n", .{ address, rsi, rdi, rsp, cr3, cr2, pte_273 });
}

fn x86_64IdtTrace(uc: ?*anyopaque, address: u64, size: u32, user_data: ?*anyopaque) callconv(.c) void {
    const guard = glue.TpGuard.init();
    defer guard.deinit();
    _ = uc;
    _ = size;
    _ = user_data;
    debug.printf("x86_64 IDT trace: pc=0x{x}\n", .{ address });
}

fn x86_64SyscallCallback(uc: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const guard = glue.TpGuard.init();
    defer guard.deinit();
    const vc: *vcore.VirtualCore = @ptrCast(@alignCast(user_data.?));
    const rip = x86_64.readPC(uc);
    if (x86_64.handleCleanStop(uc, vc, rip)) {
        _ = glue.uc_emu_stop(uc);
    }
}

fn x86_64OutCallback(uc: ?*anyopaque, port: u32, size: c_int, value: u32, user_data: ?*anyopaque) callconv(.c) void {
    const guard = glue.TpGuard.init();
    defer guard.deinit();
    _ = size;
    const vc = @as(*vcore.VirtualCore, @ptrCast(@alignCast(user_data.?)));

    // COM1 (0x3f8) serial output
    if (port == 0x3f8) {
        debug.putcharFromGuest(vc.guest_id, @as(u8, @intCast(value & 0xff)));
    }

    x86_64.advanceInsnPC(uc);
}

fn x86_64InCallback(uc: ?*anyopaque, port: u32, size: c_int, user_data: ?*anyopaque) callconv(.c) u32 {
    const guard = glue.TpGuard.init();
    defer guard.deinit();
    _ = size;
    _ = user_data;

    var result: u32 = 0;
    // COM1 (0x3f8) line status register (LSR) read
    if (port == 0x3f8 + 5) {
        result = 0x20; // LSR empty status (0x20)
    }

    x86_64.advanceInsnPC(uc);
    return result;
}

// Initialize Unicorn context for the given virtual core.
pub fn init(vc: *vcore.VirtualCore) !void {
    const em = &vc.exec_path.emulated;
    if (em.uc != null) return;

    var uc: ?*anyopaque = null;
    const arch: glue.uc_arch = switch (em.target_arch) {
        .riscv32 => .UC_ARCH_RISCV,
        .aarch64 => .UC_ARCH_ARM64,
        .x86_64 => .UC_ARCH_X86,
        else => return error.UnsupportedArch,
    };
    const mode: glue.uc_mode = switch (em.target_arch) {
        .riscv32 => glue.UC_MODE_RISCV32,
        .aarch64 => glue.UC_MODE_ARM,
        .x86_64 => glue.UC_MODE_64,
        else => return error.UnsupportedArch,
    };

    const err = glue.uc_open(arch, mode, &uc);
    if (err != .UC_ERR_OK) {
        debug.printf("Unicorn: failed to open engine, err={}\n", .{err});
        return error.UnicornOpenFailed;
    }
    em.uc = uc;

    // Set TCG buffer to 4MB to fit within the per-CPU heap allocation.
    // This call triggers UC_INIT which creates the CPU — must happen before
    // accessing internal CPU state (e.g., rdtime_fn registration below).
    const ctl_err = glue.uc_ctl(uc, UC_CTL_TB_CACHE_SIZE, @as(c_uint, 4 * 1024 * 1024));
    if (ctl_err != .UC_ERR_OK) {
        debug.printf("Unicorn: failed to set TCG buffer size, err={}\n", .{ctl_err});
        _ = glue.uc_close(uc);
        em.uc = null;
        return error.UnicornOpenFailed;
    }

    // Map the guest physical RAM.
    const ram_size = vc.guest.space.range_size;
    const gpa_base = vc.guest.space.base_gpa;
    const hpa_base = vc.guest.space.base_hpa;

    const map_err = glue.uc_mem_map_ptr(uc, gpa_base, ram_size, glue.uc_prot.UC_PROT_ALL, @ptrFromInt(hpa_base));
    if (map_err != .UC_ERR_OK) {
        debug.printf("Unicorn: failed to map GPA, err={}\n", .{map_err});
        _ = glue.uc_close(uc);
        em.uc = null;
        return error.UnicornMapFailed;
    }

    // Map a physical alias at GPA 0 for guests whose page tables reference
    // physical addresses starting at 0 (e.g., ELF PHDR addresses).
    // Cap the alias to avoid covering MMIO regions.
    if (gpa_base > 0) {
        const alias_size = if (ram_size > QEMU_VIRT_UART_BASE) QEMU_VIRT_UART_BASE else ram_size;
        _ = glue.uc_mem_map_ptr(uc, 0, alias_size, glue.uc_prot.UC_PROT_ALL, @ptrFromInt(hpa_base));
        // Non-fatal: the guest may not need this mapping.
    }

    // AArch64 kernel virtual address alias: Linux maps kernel memory at
    // VA 0xffff800080000000 (TTBR1 region). After the kernel enables the
    // MMU, instruction fetches and data accesses use these virtual addresses.
    // Map the kernel VA range directly so Unicorn resolves them without
    // needing page table walks (which require additional QEMU softmmu state).
    if (em.target_arch == .aarch64 and gpa_base > 0) {
        const kernel_va_base: u64 = 0xffff800000000000 + gpa_base;
        _ = glue.uc_mem_map_ptr(uc, kernel_va_base, ram_size, glue.uc_prot.UC_PROT_ALL, @ptrFromInt(hpa_base));
        // Also map the low identity range used during MMU transition.
        const identity_va_base: u64 = 0xffff800000000000;
        const identity_size = if (ram_size > QEMU_VIRT_UART_BASE) QEMU_VIRT_UART_BASE else ram_size;
        _ = glue.uc_mem_map_ptr(uc, identity_va_base, identity_size, glue.uc_prot.UC_PROT_ALL, @ptrFromInt(hpa_base));
    } else if (em.target_arch == .riscv32) {
        // Dummy alias mapping to satisfy Unicorn's memory_check() when restarting
        // execution at a virtual address. Unicorn checks the flat memory map
        // before evaluating the guest MMU.
        const kernel_va_base: u64 = 0xc0000000;
        const max_alias_size = 0xffffffff - kernel_va_base;
        const alias_size = if (ram_size > max_alias_size) max_alias_size else ram_size;
        _ = glue.uc_mem_map_ptr(uc, kernel_va_base, alias_size, glue.uc_prot.UC_PROT_ALL, @ptrFromInt(hpa_base));
    }

    // Register hooks.
    var hook_mem: glue.uc_hook = null;
    _ = glue.uc_hook_add(uc, &hook_mem, glue.UC_HOOK_MEM_UNMAPPED, @as(?*const anyopaque, @ptrCast(&memCallback)), @as(?*anyopaque, @ptrCast(vc)), @as(u64, 0), @as(u64, 0xffffffffffffffff));

    // Invalid-instruction hook: intercepts instructions Unicorn cannot
    // handle natively (e.g., rdtime/rdtimeh when rdtime_fn is unset).
    // Runs inside the emulation loop so there is no stop/restart overhead.
    var hook_insn_invalid: glue.uc_hook = null;
    _ = glue.uc_hook_add(uc, &hook_insn_invalid, glue.UC_HOOK_INSN_INVALID, @as(?*const anyopaque, @ptrCast(&insnInvalidCallback)), @as(?*anyopaque, @ptrCast(vc)), @as(u64, 0), @as(u64, 0xffffffffffffffff));

    // Interrupt/exception hook: intercepts ecall (and other exceptions)
    // before QEMU delivers them to mtvec/stvec. This is critical for
    // SBI call handling — without it, ecall from S-mode silently jumps
    // to mtvec (address 0) and the guest resets.
    var hook_intr: glue.uc_hook = null;
    _ = glue.uc_hook_add(uc, &hook_intr, glue.UC_HOOK_INTR, @as(?*const anyopaque, @ptrCast(&intrCallback)), @as(?*anyopaque, @ptrCast(vc)), @as(u64, 0), @as(u64, 0xffffffffffffffff));

    // Register sc.w and idle loop emulator hooks for RISC-V 32-bit
    if (em.target_arch == .riscv32) {
        const elf_base = @intFromPtr(&__rootvm_start);
        const elf_size = @intFromPtr(&__rootvm_end) - elf_base;
        const elf_bytes = @as([*]const u8, @ptrFromInt(elf_base))[0..elf_size];

        var sc_hook_addr: u64 = 0xc0021618; // Default fallback
        var idle_hook_addr: u64 = 0xc0640728; // Default fallback

        if (loader.Loader.findSymbol(elf_bytes, "cpuhp_wait_for_sync_state")) |cpuhp_gva| {
            const hpa = hpa_base + (cpuhp_gva - 0xc0000000);
            const ptr = @as([*]const u32, @ptrFromInt(hpa));
            var j: usize = 0;
            while (j < 128) : (j += 1) {
                const insn = ptr[j];
                if ((insn & 0xfc00707f) == 0x1800202f) { // sc.w.rl
                    sc_hook_addr = cpuhp_gva + j * 4;
                    break;
                }
            }
        }

        if (loader.Loader.findSymbol(elf_bytes, "default_idle_call")) |idle_gva| {
            const hpa = hpa_base + (idle_gva - 0xc0000000);
            const ptr = @as([*]const u32, @ptrFromInt(hpa));
            var j: usize = 0;
            while (j < 128) : (j += 1) {
                const insn = ptr[j];
                if (insn == 0x10016073) { // csrsi sstatus, 2
                    idle_hook_addr = idle_gva + (j + 1) * 4;
                    break;
                }
            }
        }

        em.sc_hook_addr = sc_hook_addr;
        em.idle_hook_addr = idle_hook_addr;

        var hook_sc: glue.uc_hook = null;
        _ = glue.uc_hook_add(uc, &hook_sc, UC_HOOK_CODE, @as(?*const anyopaque, @ptrCast(&scHookCallback)), null, sc_hook_addr, sc_hook_addr);

        var hook_idle: glue.uc_hook = null;
        _ = glue.uc_hook_add(uc, &hook_idle, UC_HOOK_CODE, @as(?*const anyopaque, @ptrCast(&idleEnableInterruptsHook)), @as(?*anyopaque, @ptrCast(vc)), idle_hook_addr, idle_hook_addr);
    }

    if (em.target_arch == .x86_64) {
        var hook_syscall: glue.uc_hook = null;
        _ = glue.uc_hook_add(uc, &hook_syscall, glue.UC_HOOK_INSN, @as(?*const anyopaque, @ptrCast(&x86_64SyscallCallback)), @as(?*anyopaque, @ptrCast(vc)), @as(u64, 1), @as(u64, 0), glue.UC_X86_INS_SYSCALL);

        var hook_out: glue.uc_hook = null;
        _ = glue.uc_hook_add(uc, &hook_out, glue.UC_HOOK_INSN, @as(?*const anyopaque, @ptrCast(&x86_64OutCallback)), @as(?*anyopaque, @ptrCast(vc)), @as(u64, 1), @as(u64, 0), glue.UC_X86_INS_OUT);

        var hook_in: glue.uc_hook = null;
        _ = glue.uc_hook_add(uc, &hook_in, glue.UC_HOOK_INSN, @as(?*const anyopaque, @ptrCast(&x86_64InCallback)), @as(?*anyopaque, @ptrCast(vc)), @as(u64, 1), @as(u64, 0), glue.UC_X86_INS_IN);

        var hook_trace: glue.uc_hook = null;
        _ = glue.uc_hook_add(uc, &hook_trace, glue.UC_HOOK_CODE, @as(?*const anyopaque, @ptrCast(&x86_64CopyBootdataTrace)), @as(?*anyopaque, @ptrCast(vc)), @as(u64, 0xffffffff82267800), @as(u64, 0xffffffff82267820));

        var hook_idt_trace: glue.uc_hook = null;
        _ = glue.uc_hook_add(uc, &hook_idt_trace, glue.UC_HOOK_CODE, @as(?*const anyopaque, @ptrCast(&x86_64IdtTrace)), @as(?*anyopaque, @ptrCast(vc)), @as(u64, 0xffffffff822675b0), @as(u64, 0xffffffff82267790));
    }

    // Block hook: DISABLED — using uc_emu_start count parameter for
    // bounded execution instead. Timer/preemption checks happen in
    // the outer loop between uc_emu_start calls.
    // var hook_block: glue.uc_hook = null;
    // _ = glue.uc_hook_add(uc, &hook_block, glue.UC_HOOK_BLOCK, @as(?*const anyopaque, @ptrCast(&blockCallback)), @as(?*anyopaque, @ptrCast(vc)), @as(u64, 0), @as(u64, 0xffffffffffffffff));

    // Initialize cleanly isolated contexts for all sub-vcores
    for (&em.sub_vcores, 0..) |*sub, i| {
        _ = glue.uc_context_alloc(uc, &sub.context);
        switch (em.target_arch) {
            .riscv32 => {
                var m_priv: u32 = 3;
                _ = glue.uc_reg_write(uc, rv32.UC_REG_PRIV, &m_priv);
                rv32.initRegisters(uc, em.entry, em.dtb, i);
            },
            .aarch64 => aarch64.initRegisters(uc, em.entry, em.dtb, i),
            .x86_64 => x86_64.initRegisters(uc, em.entry, vc.guest.space.base_gpa, vc.guest.space.range_size, vc.guest.early_pgt_gpa),
            else => {},
        }
        _ = glue.uc_context_save(uc, sub.context.?);

        if (i == 0) {
            sub.state = .ready;
        } else {
            sub.state = .stopped;
        }
    }

    // Restore CPU0 to begin execution cleanly
    _ = glue.uc_context_restore(uc, em.sub_vcores[0].context.?);

    // Register the rdtime callback so guest rdtime/rdtimeh instructions
    // execute inside the JIT loop, reading the real host timer directly.
    // Must be after initRegisters above, which triggers UC_INIT (CPU
    // creation) via uc_reg_write. Before UC_INIT, uc->cpu is NULL.
    if (em.target_arch == .riscv32) {
        glue.diosix_uc_set_rdtime_fn(uc, &glue.rdtimeCallback);
    }
}

// Stop execution of the emulated vcore.
pub fn stop(vc: *vcore.VirtualCore) void {
    const em = &vc.exec_path.emulated;
    em.preempt_pending = true;
    // uc_emu_stop from M-mode doesn't reliably interrupt the JIT because
    // Unicorn's quit_request flag isn't checked between TBs in this build.
    if (em.emu_running) {
        if (em.uc) |uc| {
            _ = glue.uc_emu_stop(uc);
        }
    }
}

// Run the emulation loop.
//
// Executes the guest until an ECALL (which needs SBI/HVC/syscall handling),
// an unrecoverable error, or the exception budget is exhausted. S-mode
// exceptions are decoded and re-delivered to the guest's trap handler,
// matching real hardware behavior.
pub fn run(vc: *vcore.VirtualCore) void {
    init(vc) catch |e| {
        debug.printf("Unicorn init failed: {s}\n", .{@errorName(e)});
        return;
    };

    const em = &vc.exec_path.emulated;
    const uc = em.uc.?;
    em.preempt_pending = false;

    // Read the current PC via the architecture handler.
    var pc: u64 = switch (em.target_arch) {
        .riscv32 => rv32.readPC(uc),
        .aarch64 => aarch64.readPC(uc),
        .x86_64 => x86_64.readPC(uc),
        else => return,
    };

    // One-shot trace for aarch64 to verify initial guest state.
    if (em.target_arch == .aarch64) {
        const S_trace = struct {
            var traced: bool = false;
        };
        if (!S_trace.traced) {
            S_trace.traced = true;
            var x0: u64 = 0;
            _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_arm64_reg.UC_ARM64_REG_X0), &x0);
            debug.printf("aarch64: first run PC=0x{x} X0(DTB)=0x{x}\n", .{ pc, x0 });
        }
    }

    var exception_budget: u32 = EXCEPTION_BUDGET;

    // Synchronize virtual time with host physical time on entry
    em.virtual_time = glue.readSModeTime();

    while (exception_budget > 0) {
        if (em.preempt_pending) {
            break;
        }

        // ---- MICRO-SCHEDULER LOGIC ----
        var found_ready = false;
        var curr_idx = em.active_sub_vcore;
        var checked: usize = 0;
        var sub: *vcore.SubVcoreState = undefined;
        while (checked < em.sub_vcore_count) : (checked += 1) {
            curr_idx = (curr_idx + 1) % em.sub_vcore_count;
            sub = &em.sub_vcores[curr_idx];
            if (sub.state == .ready or sub.state == .running) {
                if (!sub.wfi_blocked or sub.pending_ipi or (sub.timer_scheduled and em.virtual_time >= sub.timer_target)) {
                    sub.wfi_blocked = false;
                    em.active_sub_vcore = curr_idx;
                    found_ready = true;
                    break;
                }
            }
        }

        if (!found_ready) {
            var nearest_timer: u64 = ~@as(u64, 0);
            var any_timer_scheduled = false;
            for (0..em.sub_vcore_count) |i| {
                const s = &em.sub_vcores[i];
                if (s.timer_scheduled and s.timer_target < nearest_timer) {
                    nearest_timer = s.timer_target;
                    any_timer_scheduled = true;
                }
            }
            if (any_timer_scheduled) {
                vc.timer_target = nearest_timer;
                vc.timer_scheduled = true;
            } else {
                vc.timer_scheduled = false;
            }

            // All sub_vcores are blocked or stopped.
            // Block the entire VirtualCore so the physical core can sleep.

            const pcpu = pcore.this();
            vc.blocked_node.contents = vc;
            pcpu.blocked_queue.pushStart(&vc.blocked_node);
            vc.blocked_on_cpu = pcpu.cpu_core_id;

            @atomicStore(bool, &vc.wfi_blocked, true, .release);
            break;
        }
        vc.exec_path.emulated.active_sub_vcore = em.active_sub_vcore;

        if (sub.context) |ctx| {
            var prev_satp: u64 = 0;
            if (em.target_arch == .riscv32) {
                _ = glue.uc_reg_read(uc, rv32.UC_REG_SATP, &prev_satp);
            }

            _ = glue.uc_context_restore(uc, ctx);

            // Workaround: Unicorn's uc_context_restore (with UC_CTL_CONTEXT_CPU) does not flush
            // QEMU's TLB. This causes instruction page faults when switching from a sub-vcore with
            // paging enabled to one with paging disabled (like during SMP secondary core boot).
            // QEMU's write_satp only flushes the TLB if the ASID changes. We toggle the MODE bit
            // and write back the actual value to force a TLB flush.
            if (em.target_arch == .riscv32) {
                var actual_satp: u64 = 0;
                _ = glue.uc_reg_read(uc, rv32.UC_REG_SATP, &actual_satp);

                // Optimization: Only force a QEMU TLB flush if the page table actually changed
                if (actual_satp != prev_satp) {
                    var dummy_satp: u64 = actual_satp ^ (@as(u64, 1) << 31); // Toggle MODE bit (Sv32)
                    _ = glue.uc_reg_write(uc, rv32.UC_REG_SATP, &dummy_satp);
                    _ = glue.uc_reg_write(uc, rv32.UC_REG_SATP, &actual_satp);
                }
            }

            // First time running? Apply HART_START parameters
            if (sub.state == .ready) {
                if (em.target_arch == .riscv32) {
                    var start_pc: u64 = sub.start_pc;
                    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_PC), &start_pc);
                    var a0: u64 = sub.start_a0;
                    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X10), &a0);
                    var a1: u64 = sub.start_a1;
                    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X11), &a1);
                }
                sub.state = .running;
            }

            pc = switch (em.target_arch) {
                .riscv32 => rv32.readPC(uc),
                .aarch64 => aarch64.readPC(uc),
                .x86_64 => x86_64.readPC(uc),
                else => 0,
            };
        } else {
            @panic("Uninitialized uc_context in single-engine emulation");
        }

        // Sync pending interrupts for THIS sub-vCPU
        if (em.target_arch == .riscv32) {
            var current_priv: u32 = 0;
            _ = glue.uc_reg_read(uc, rv32.UC_REG_PRIV, &current_priv);

            var m_priv: u32 = 3;
            _ = glue.uc_reg_write(uc, rv32.UC_REG_PRIV, &m_priv);

            var mip: u64 = 0;
            _ = glue.uc_reg_read(uc, rv32.UC_REG_MIP, &mip);

            var mstatus: u64 = 0;
            _ = glue.uc_reg_read(uc, rv32.UC_REG_MSTATUS, &mstatus);

            _ = glue.uc_reg_write(uc, rv32.UC_REG_PRIV, &current_priv);

            const SSTATUS_SIE: u64 = 1 << 1;
            const sie_enabled = (current_priv < 1) or ((mstatus & SSTATUS_SIE) != 0);

            const MIP_SSIP: u64 = 1 << 1;
            const MIP_STIP: u64 = 1 << 5;

            if (sie_enabled) {
                if (@atomicLoad(bool, &sub.pending_ipi, .acquire)) {
                    mip |= MIP_SSIP;
                } else {
                    mip &= ~MIP_SSIP;
                }

                if (sub.timer_scheduled) {
                    const now = em.virtual_time;
                    if (now >= sub.timer_target) {
                        mip |= MIP_STIP;
                    } else {
                        mip &= ~MIP_STIP;
                    }
                } else {
                    mip &= ~MIP_STIP;
                }
            } else {
                mip &= ~MIP_SSIP;
                mip &= ~MIP_STIP;
            }

            m_priv = 3;
            _ = glue.uc_reg_write(uc, rv32.UC_REG_PRIV, &m_priv);
            _ = glue.uc_reg_write(uc, rv32.UC_REG_MIP, &mip);
            _ = glue.uc_reg_write(uc, rv32.UC_REG_PRIV, &current_priv);
        } else if (em.target_arch == .aarch64) {
            var pstate: u64 = 0;
            _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_arm64_reg.UC_ARM64_REG_PSTATE), &pstate);
            const irq_enabled = (pstate & (1 << 7)) == 0;
            if (irq_enabled and sub.timer_scheduled and em.virtual_time >= sub.timer_target) {
                sub.timer_scheduled = false;
                aarch64.deliverInterrupt(uc, pc, 0);
            }
        } else if (em.target_arch == .x86_64) {
            var rflags: u64 = 0;
            _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_x86_reg.UC_X86_REG_EFLAGS), &rflags);
            const irq_enabled = (rflags & (1 << 9)) != 0;
            if (irq_enabled and sub.timer_scheduled and em.virtual_time >= sub.timer_target) {
                sub.timer_scheduled = false;
                x86_64.deliverInterrupt(uc, pc, 32);
            }
        }

        em.emu_running = true;
        const current_pc = switch (em.target_arch) {
            .riscv32 => rv32.readPC(uc),
            .aarch64 => aarch64.readPC(uc),
            .x86_64 => x86_64.readPC(uc),
            else => return,
        };

        var saved_tp: usize = undefined;
        var err: glue.uc_err = undefined;
        if (comptime @import("builtin").is_test) {
            err = glue.uc_emu_start(uc, current_pc, 0xffffffffffffffff, 0, vcore.emulation_timeslice_instructions);
        } else {
            asm volatile (
                \\mv %[saved], tp
                : [saved] "=r" (saved_tp),
            );
            err = glue.uc_emu_start(uc, current_pc, 0xffffffffffffffff, 0, vcore.emulation_timeslice_instructions);
            asm volatile (
                \\mv tp, %[saved]
                :
                : [saved] "r" (saved_tp),
            );
        }
        em.emu_running = false;

        glue.diosix_uc_clear_stop(uc);
        var new_pc: u64 = switch (em.target_arch) {
            .riscv32 => rv32.readPC(uc),
            .aarch64 => aarch64.readPC(uc),
            .x86_64 => x86_64.readPC(uc),
            else => 0,
        };
        sub.last_pc = new_pc;
        em.virtual_time = glue.readSModeTime();

        if (err == .UC_ERR_OK) {
            if (em.target_arch == .riscv32) {
                var current_priv: u32 = 0;
                _ = glue.uc_reg_read(uc, rv32.UC_REG_PRIV, &current_priv);
                var m_priv: u32 = 3;
                _ = glue.uc_reg_write(uc, rv32.UC_REG_PRIV, &m_priv);

                var mstatus: u64 = 0;
                var sie: u64 = 0;
                _ = glue.uc_reg_read(uc, rv32.UC_REG_MSTATUS, &mstatus);
                _ = glue.uc_reg_read(uc, rv32.UC_REG_SIE, &sie);

                _ = glue.uc_reg_write(uc, rv32.UC_REG_PRIV, &current_priv);

                const SSTATUS_SIE: u64 = 1 << 1;
                const SIE_STIE: u64 = 1 << 5;
                const SIE_SSIE: u64 = 1 << 1;

                const sie_enabled = (current_priv < 1) or ((mstatus & SSTATUS_SIE) != 0);

                if (sie_enabled) {
                    const timer_pending = sub.timer_scheduled and (em.virtual_time >= sub.timer_target);
                    const ipi_pending = @atomicLoad(bool, &sub.pending_ipi, .acquire);

                    if (timer_pending and (sie & SIE_STIE) != 0) {
                        rv32.deliverInterrupt(uc, new_pc, 5);
                        new_pc = rv32.readPC(uc);
                        sub.last_pc = new_pc;
                    } else if (ipi_pending and (sie & SIE_SSIE) != 0) {
                        _ = @atomicRmw(bool, &sub.pending_ipi, .Xchg, false, .acq_rel);
                        rv32.deliverInterrupt(uc, new_pc, 1);
                        new_pc = rv32.readPC(uc);
                        sub.last_pc = new_pc;
                    }
                }
            } else if (em.target_arch == .aarch64) {
                var pstate: u64 = 0;
                _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_arm64_reg.UC_ARM64_REG_PSTATE), &pstate);
                const irq_enabled = (pstate & (1 << 7)) == 0;
                if (irq_enabled and sub.timer_scheduled and em.virtual_time >= sub.timer_target) {
                    sub.timer_scheduled = false;
                    aarch64.deliverInterrupt(uc, new_pc, 0);
                    new_pc = aarch64.readPC(uc);
                    sub.last_pc = new_pc;
                }
            } else if (em.target_arch == .x86_64) {
                var rflags: u64 = 0;
                _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_x86_reg.UC_X86_REG_EFLAGS), &rflags);
                const irq_enabled = (rflags & (1 << 9)) != 0;
                if (irq_enabled and sub.timer_scheduled and em.virtual_time >= sub.timer_target) {
                    sub.timer_scheduled = false;
                    x86_64.deliverInterrupt(uc, new_pc, 32);
                    new_pc = x86_64.readPC(uc);
                    sub.last_pc = new_pc;
                }
            }

            const handled = switch (em.target_arch) {
                .riscv32 => rv32.handleCleanStop(uc, vc, em.active_sub_vcore, new_pc),
                .aarch64 => aarch64.handleCleanStop(uc, vc, new_pc),
                .x86_64 => x86_64.handleCleanStop(uc, vc, new_pc),
                else => false,
            };

            _ = glue.uc_context_save(uc, sub.context.?);

            if (handled) {
                pc = switch (em.target_arch) {
                    .riscv32 => rv32.readPC(uc),
                    .aarch64 => aarch64.readPC(uc),
                    .x86_64 => x86_64.readPC(uc),
                    else => 0,
                };
            }

            // We do not need to manually check interrupts here because we sync MIP
            // right before uc_emu_start. Any pending interrupts will be
            // natively delivered by Unicorn during the next timeslice.
            continue;
        }

        if (err == .UC_ERR_EXCEPTION) {

            const action = switch (em.target_arch) {
                .riscv32 => rv32.handleException(uc, new_pc),
                .aarch64 => aarch64.handleException(uc, new_pc),
                .x86_64 => x86_64.handleException(uc, new_pc),
                else => ExceptionAction.unhandled,
            };

            switch (action) {
                .emulated => {
                    _ = glue.uc_context_save(uc, sub.context.?);
                    continue;
                },
                .wfi => {
                    var current_priv: u32 = 0;
                    _ = glue.uc_reg_read(uc, rv32.UC_REG_PRIV, &current_priv);
                    var m_priv: u32 = 3;
                    _ = glue.uc_reg_write(uc, rv32.UC_REG_PRIV, &m_priv);

                    var mstatus: u64 = 0;
                    var sie: u64 = 0;
                    _ = glue.uc_reg_read(uc, rv32.UC_REG_MSTATUS, &mstatus);
                    _ = glue.uc_reg_read(uc, rv32.UC_REG_SIE, &sie);

                    _ = glue.uc_reg_write(uc, rv32.UC_REG_PRIV, &current_priv);

                    const SSTATUS_SIE: u64 = 1 << 1;
                    const sie_enabled = ((mstatus & SSTATUS_SIE) != 0);

                    const SIE_STIE: u64 = 1 << 5;
                    const SIE_SSIE: u64 = 1 << 1;

                    const timer_pending = sub.timer_scheduled and (em.virtual_time >= sub.timer_target);
                    const ipi_pending = @atomicLoad(bool, &sub.pending_ipi, .acquire);

                    if (timer_pending and (sie & SIE_STIE) != 0) {
                        if (sie_enabled) {
                            rv32.deliverInterrupt(uc, new_pc + 4, 5);
                        } else {
                            var pc_val = new_pc + 4;
                            _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_PC), &pc_val);
                        }
                        _ = glue.uc_context_save(uc, sub.context.?);
                        continue;
                    } else if (ipi_pending and (sie & SIE_SSIE) != 0) {
                        if (sie_enabled) {
                            _ = @atomicRmw(bool, &sub.pending_ipi, .Xchg, false, .acq_rel);
                            rv32.deliverInterrupt(uc, new_pc + 4, 1);
                        } else {
                            var pc_val = new_pc + 4;
                            _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_PC), &pc_val);
                        }
                        _ = glue.uc_context_save(uc, sub.context.?);
                        continue;
                    }

                    // Otherwise, block the sub-vcore on WFI
                    sub.wfi_blocked = true;
                    var pc_val = new_pc + 4;
                    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_PC), &pc_val);
                    _ = glue.uc_context_save(uc, sub.context.?);
                    continue;
                },
                .delivered => {
                    exception_budget -= 1;
                    _ = glue.uc_context_save(uc, sub.context.?);
                    continue;
                },
                .unhandled => {
                    debug.printf("Unhandled exception {} at PC 0x{x}\n", .{ em.exception_cause, pc });
                    vc.state = .stopped;
                    return;
                },
            }
        }

        if (em.target_arch == .x86_64) {
            var cr0: u64 = 0;
            var cr3: u64 = 0;
            var eflags: u64 = 0;
            _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_x86_reg.UC_X86_REG_CR0), &cr0);
            _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_x86_reg.UC_X86_REG_CR3), &cr3);
            _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_x86_reg.UC_X86_REG_EFLAGS), &eflags);
            debug.printf("x86_64 registers: CR0=0x{x} CR3=0x{x} EFLAGS=0x{x}\n", .{ cr0, cr3, eflags });
        }
        debug.printf("Unicorn: execution error {} at PC 0x{x}\n", .{ err, new_pc });
        vc.state = .stopped;
        return;
    }
}

// Invalid-instruction callback — intercepts instructions that Unicorn
// cannot execute natively and emulates them inline. This fires inside

// Invalid-instruction callback — intercepts instructions that Unicorn
// cannot execute natively and emulates them inline. This fires inside
fn insnInvalidCallback(uc: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) bool {
    const guard = glue.TpGuard.init();
    defer guard.deinit();
    const vc: *vcore.VirtualCore = @ptrCast(@alignCast(user_data.?));
    const em = &vc.exec_path.emulated;

    // Delegate to architecture-specific handler.
    return switch (em.target_arch) {
        .riscv32 => rv32.handleInvalidInsn(uc) == .emulated,
        .aarch64 => aarch64.handleInvalidInsn(uc),
        .x86_64 => x86_64.handleInvalidInsn(uc),
        else => false,
    };
}

// Interrupt/exception callback — intercepts CPU exceptions before QEMU
// delivers them to mtvec/stvec. This is the primary path for handling
// SBI calls (ecall from S-mode).
fn intrCallback(uc: ?*anyopaque, intno: u32, user_data: ?*anyopaque) callconv(.c) void {
    const guard = glue.TpGuard.init();
    defer guard.deinit();
    const vc: *vcore.VirtualCore = @ptrCast(@alignCast(user_data.?));
    const em = &vc.exec_path.emulated;

    switch (em.target_arch) {
        .riscv32 => intrCallbackRiscv32(uc, intno, vc),
        .aarch64 => intrCallbackAarch64(uc, intno, vc),
        .x86_64 => intrCallbackX86_64(uc, intno, vc),
        else => {},
    }
}

fn intrCallbackRiscv32(uc: ?*anyopaque, intno: u32, vc: *vcore.VirtualCore) void {
    const em = &vc.exec_path.emulated;
    _ = em;

    // EXCP_HALTED is 0x10003 (65539). QEMU throws this when it encounters WFI natively.
    if (intno == 65539) {
        // QEMU already advanced the PC past the WFI instruction natively, but Unicorn's
        // cpu_exec loop blindly adds 4 to env->pc before calling UC_HOOK_INTR.
        // We must subtract 4 to undo Unicorn's bogus addition, leaving us at the
        // correct next instruction.
        const pc = rv32.readPC(uc);
        rv32.writePC(uc, pc - 4);

        _ = glue.uc_emu_stop(uc);
        return;
    }
    // Cause 2: Illegal Instruction. QEMU throws this for rdtime/rdcycle
    // because we deliberately set MCOUNTEREN=0 to trap them.
    if (intno == 2) {
        const action = rv32.handleInvalidInsn(uc);
        switch (action) {
            .emulated => return, // PC advanced, continue
            .wfi => {
                // PC is already correctly advanced by Unicorn's +4 because
                // WFI is a 4-byte instruction and cpu_loop_exit_restore restored it.
                _ = glue.uc_emu_stop(uc);
                return;
            },
            .unhandled, .delivered => {}, // Fall through to standard exception delivery
        }
    }

    // RISC-V ecall exception causes: U-mode=8, S-mode=9, M-mode=11.
    if (intno == 8 or intno == 9 or intno == 11) {
        // SBI call — read a7/a6/a0/a1/a2, handle, write results back.
        var a7: u32 = 0;
        var a6: u32 = 0;
        var a0: u32 = 0;
        var a1: u32 = 0;
        var a2: u32 = 0;
        _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X17), &a7);
        _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X16), &a6);
        _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X10), &a0);
        _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X11), &a1);
        _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X12), &a2);

        var mock_context = std.mem.zeroes(riscv.ThreadContext);
        mock_context[@intFromEnum(riscv.Register.a7)] = a7;
        mock_context[@intFromEnum(riscv.Register.a6)] = a6;
        mock_context[@intFromEnum(riscv.Register.a0)] = a0;
        mock_context[@intFromEnum(riscv.Register.a1)] = a1;
        mock_context[@intFromEnum(riscv.Register.a2)] = a2;

        sbi.handle(vc, vc.exec_path.emulated.active_sub_vcore, &mock_context);

        const res_a0 = @as(u32, @truncate(mock_context[@intFromEnum(riscv.Register.a0)]));
        const res_a1 = @as(u32, @truncate(mock_context[@intFromEnum(riscv.Register.a1)]));
        _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X10), &res_a0);
        _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X11), &res_a1);

        // PC already advanced by QEMU. Stop so the outer loop can reschedule.
        _ = glue.uc_emu_stop(uc);
        return;
    }

    // All other exceptions: deliver to the guest's S-mode trap handler
    // via QEMU's native riscv_cpu_do_interrupt. This correctly handles
    // medeleg/mideleg delegation, sepc/scause/stval/sstatus manipulation,
    // privilege mode transitions, and PC = stvec.

    var pre_pc: u64 = 0;
    _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_PC), &pre_pc);
    var stvec: u64 = 0;
    _ = glue.uc_reg_read(uc, rv32.UC_REG_STVEC, &stvec);

    var info: glue.InterruptInfo = std.mem.zeroes(glue.InterruptInfo);
    glue.diosix_uc_do_interrupt(uc, @as(c_int, @bitCast(intno)), &info);

    // Flush Unicorn TB cache so the next uc_emu_start generates fresh
    // translation blocks with the updated CSR/privilege state.
    _ = glue.uc_ctl(uc, @as(c_uint, glue.UC_CTL_FLUSH_TB));

    // Stop execution so that uc_emu_start returns. The run loop will
    // re-enter at the new PC (stvec), generating a fresh translation block
    // with the correct privilege and CSR state.
    _ = glue.uc_emu_stop(uc);
}

// AArch64 specific interrupt handling.
fn intrCallbackAarch64(uc: ?*anyopaque, intno: u32, vc: *vcore.VirtualCore) void {

    // EXCP_HALTED is 0x10003 (65539). QEMU throws this when it encounters WFI.
    if (intno == 65539) {
        @atomicStore(bool, &vc.wfi_blocked, true, .release);
        _ = glue.uc_emu_stop(uc);
        return;
    }

    // QEMU ARM64 exception numbers (from target/arm/cpu.h):
    //   EXCP_SWI  = 2  (SVC from AArch64)
    //   EXCP_HVC  = 11 (HyperVisor Call)
    //   EXCP_SMC  = 13 (Secure Monitor Call)
    const EXCP_HVC: u32 = 11;
    const EXCP_SMC: u32 = 13;

    if (intno == EXCP_HVC or intno == EXCP_SMC) {
        // PSCI call via HVC/SMC.
        var x0: u64 = 0;
        var x1: u64 = 0;
        var x2: u64 = 0;
        var x3: u64 = 0;
        _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_arm64_reg.UC_ARM64_REG_X0), &x0);
        _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_arm64_reg.UC_ARM64_REG_X1), &x1);
        _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_arm64_reg.UC_ARM64_REG_X2), &x2);
        _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_arm64_reg.UC_ARM64_REG_X3), &x3);

        const func_id: u32 = @truncate(x0);
        const result = psci.handle(vc, func_id, x1, x2, x3);

        var res_val: u64 = @bitCast(result);
        _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_arm64_reg.UC_ARM64_REG_X0), &res_val);

        // PC already advanced by QEMU. Stop so the outer loop can reschedule.
        _ = glue.uc_emu_stop(uc);
        return;
    }

    // Other exceptions (data abort, prefetch abort, SVC, etc.):
    //
    // Read the faulting PC (cpu-exec.c added +4 before the hook).
    var faulting_pc: u64 = 0;
    _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_arm64_reg.UC_ARM64_REG_PC), &faulting_pc);
    faulting_pc -= 4; // Undo the +4 from cpu-exec.c.

    // Read VBAR_EL1 to determine if the kernel has set up exception vectors.
    var vbar: u64 = 0;
    _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_arm64_reg.UC_ARM64_REG_VBAR_EL1), &vbar);

    if (vbar == 0) {
        // VBAR not yet set up (early boot). This is likely a prefetch
        // abort after `msr sctlr_el1` enables the MMU. Sync the MMU
        // state (SCTLR/TTBR banked→el[] + hflags rebuild) and retry.
        const S_early = struct {
            var synced: bool = false;
            var count: u32 = 0;
        };
        if (!S_early.synced) {
            S_early.synced = true;

            // Diagnostic: read TTBR0 via BOTH paths BEFORE sync
            var ttbr0_before_cp: u64 = 0;
            var ttbr0_before_el: u64 = 0;
            {
                var cp_ttbr0 = std.mem.zeroes(glue.uc_arm64_cp_reg);
                cp_ttbr0.crn = 2;
                cp_ttbr0.crm = 0;
                cp_ttbr0.op0 = 3;
                cp_ttbr0.op1 = 0;
                cp_ttbr0.op2 = 0;
                _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_arm64_reg.UC_ARM64_REG_CP_REG), &cp_ttbr0);
                ttbr0_before_cp = cp_ttbr0.val;
                _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_arm64_reg.UC_ARM64_REG_TTBR0_EL1), &ttbr0_before_el);
            }
            debug.printf("BEFORE sync: TTBR0 cp_reg=0x{x} el1=0x{x}\n", .{ ttbr0_before_cp, ttbr0_before_el });

            glue.diosix_uc_arm64_sync_mmu_state(uc);

            // Diagnostic: read TTBR0 via BOTH paths AFTER sync
            var ttbr0_after_cp: u64 = 0;
            var ttbr0_after_el: u64 = 0;
            {
                var cp_ttbr0 = std.mem.zeroes(glue.uc_arm64_cp_reg);
                cp_ttbr0.crn = 2;
                cp_ttbr0.crm = 0;
                cp_ttbr0.op0 = 3;
                cp_ttbr0.op1 = 0;
                cp_ttbr0.op2 = 0;
                _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_arm64_reg.UC_ARM64_REG_CP_REG), &cp_ttbr0);
                ttbr0_after_cp = cp_ttbr0.val;
                _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_arm64_reg.UC_ARM64_REG_TTBR0_EL1), &ttbr0_after_el);
            }
            debug.printf("AFTER sync:  TTBR0 cp_reg=0x{x} el1=0x{x}\n", .{ ttbr0_after_cp, ttbr0_after_el });
            debug.printf("aarch64: synced MMU state at PC=0x{x}\n", .{faulting_pc});
        }
        if (S_early.count < 5) {
            S_early.count += 1;
            debug.printf("aarch64: early intno={} raw_pc=0x{x}, skipping\n", .{ intno, faulting_pc });
        }
        // After sync, don't touch the PC — let cpu-exec.c's +4 advance
        // past the faulting instruction (the ISB or MSR that triggered
        // the MMU walk). The next uc_emu_start will resume from there.
        _ = glue.uc_ctl(uc, @as(c_uint, glue.UC_CTL_FLUSH_TB));
        _ = glue.uc_emu_stop(uc);
        return;
    }

    // VBAR is set up — deliver a proper exception to the guest's handler.
    // ARM64 EL1 synchronous exception entry:
    //   SPSR_EL1 = PSTATE (saved — we skip this, no Unicorn API for it)
    //   ELR_EL1  = faulting PC
    //   ESR_EL1  = exception syndrome
    //   FAR_EL1  = faulting address
    //   PSTATE   = DAIF masked + EL1h
    //   PC       = VBAR_EL1 + 0x200 (synchronous, same EL, SP_EL1)

    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_arm64_reg.UC_ARM64_REG_ELR_EL1), &faulting_pc);

    const ec: u32 = switch (intno) {
        3 => aarch64.EC_INSN_ABORT_SAME,
        4 => aarch64.EC_DATA_ABORT_SAME,
        2 => aarch64.EC_SVC64,
        else => aarch64.EC_UNKNOWN,
    };
    var esr: u64 = (@as(u64, ec) << 26) | (1 << 25) | 0x04;
    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_arm64_reg.UC_ARM64_REG_ESR_EL1), &esr);
    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_arm64_reg.UC_ARM64_REG_FAR_EL1), &faulting_pc);

    var new_pstate: u32 = 0x3C5;
    _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_arm64_reg.UC_ARM64_REG_PSTATE), &new_pstate);

    const vector_pc = vbar + 0x200;
    aarch64.writePC(uc, vector_pc);

    const S_excp3 = struct {
        var count: u32 = 0;
    };
    if (S_excp3.count < 10) {
        S_excp3.count += 1;
        debug.printf("aarch64 exception: intno={} PC=0x{x}->0x{x}\n", .{ intno, faulting_pc, vector_pc });
    }

    _ = glue.uc_ctl(uc, @as(c_uint, glue.UC_CTL_FLUSH_TB));
    _ = glue.uc_emu_stop(uc);
}

fn intrCallbackX86_64(uc: ?*anyopaque, intno: u32, vc: *vcore.VirtualCore) void {
    // EXCP_HALTED is 65539. QEMU fires this when it encounters HLT.
    if (intno == 65539) {
        @atomicStore(bool, &vc.wfi_blocked, true, .release);
        _ = glue.uc_emu_stop(uc);
        return;
    }
    debug.printf("x86_64: unhandled interrupt/exception number {} at PC=0x{x}\n", .{ intno, x86_64.readPC(uc) });
    _ = glue.uc_emu_stop(uc);
}


// Memory callback for unmapped regions — handles MMIO (UART, etc.).
fn memCallback(uc: ?*anyopaque, mem_type: glue.uc_mem_type, address: u64, size: c_int, value: i64, user_data: ?*anyopaque) callconv(.c) bool {
    const guard = glue.TpGuard.init();
    defer guard.deinit();
    _ = size;
    const vc = @as(*vcore.VirtualCore, @ptrCast(@alignCast(user_data.?)));

    // NS16550A UART console output (RISC-V QEMU virt platform).
    if (address >= QEMU_VIRT_UART_BASE and address < QEMU_VIRT_UART_BASE + 8) {
        if (mem_type == .UC_MEM_WRITE_UNMAPPED) {
            debug.putcharFromGuest(vc.guest_id, @as(u8, @intCast(value & 0xff)));
        }
        return true;
    }

    // PL011 UART console output (ARM QEMU virt platform).
    // PL011 data register is at base+0x00 (UARTDR).
    if (address >= aarch64.PL011_UART_BASE and address < aarch64.PL011_UART_BASE + aarch64.PL011_UART_SIZE) {
        if (mem_type == .UC_MEM_WRITE_UNMAPPED) {
            if (address == aarch64.PL011_UART_BASE) {
                // UARTDR write: output the character.
                debug.putcharFromGuest(vc.guest_id, @as(u8, @intCast(value & 0xff)));
            }
            // Other PL011 register writes (control, baud, etc.) — ignore.
        }
        // For reads: UARTFR (base+0x18) bit 5 = TXFE (TX FIFO empty).
        // Returning 0 means "TX ready" which is sufficient for earlycon.
        return true; // Claim all PL011 MMIO accesses.
    }
    if (address < 0x80000000) {
        const page_size: u64 = 4096;
        const page_base = address & ~(page_size - 1);
        const map_err = glue.uc_mem_map(uc, page_base, page_size, glue.uc_prot.UC_PROT_ALL);
        if (map_err == .UC_ERR_OK or map_err == .UC_ERR_MAP) {
            const buf: [4096]u8 = @splat(0xff);
            _ = glue.uc_mem_write(uc, page_base, &buf, page_size);
            return true;
        }
        return false;
    }

    // Map local APIC (0xfee00000) and I/O APIC (0xfec00000) regions as dummy pages.
    if (address >= 0xfec00000 and address < 0xff000000) {
        const page_size: u64 = 4096;
        const page_base = address & ~(page_size - 1);
        const map_err = glue.uc_mem_map(uc, page_base, page_size, glue.uc_prot.UC_PROT_ALL);
        if (map_err == .UC_ERR_OK) {
            var apic_buf = std.mem.zeroes([4096]u8);
            
            // If mapping local APIC page (0xfee00000), set up realistic registers
            if (page_base == 0xfee00000) {
                // APIC ID register at offset 0x20: CPU ID 0
                std.mem.writeInt(u32, apic_buf[0x20..0x24], 0x00000000, .little);
                // APIC Version register at offset 0x30: version 0x14 (integrated APIC), max LVT 5
                std.mem.writeInt(u32, apic_buf[0x30..0x34], 0x00050014, .little);
                // Spurious Interrupt Vector register at offset 0xf0: default 0x000000ff after reset
                std.mem.writeInt(u32, apic_buf[0xf0..0xf4], 0x000000ff, .little);
            }
            
            _ = glue.uc_mem_write(uc, page_base, &apic_buf, page_size);
            return true;
        } else if (map_err == .UC_ERR_MAP) {
            return true;
        }
        return false;
    }

    // AArch64 kernel virtual address space: demand-map zero-filled pages
    // for per-CPU data, stacks, vmalloc, fixmap etc. that aren't in our
    // direct VA mapping. Unicorn requires actual mapped memory (not just
    // a callback returning true) for the JIT to re-execute the access.
    if (address >= 0xffff000000000000) {
        // Align down to 4KB page boundary and map a 2MB chunk.
        const page_size: u64 = 0x200000; // 2MB
        const page_base = address & ~(page_size - 1);
        const map_err = glue.uc_mem_map(uc, page_base, page_size, glue.uc_prot.UC_PROT_ALL);
        if (map_err == .UC_ERR_OK or map_err == .UC_ERR_MAP) {
            return true; // Retry the access — it should succeed now.
        }
        debug.printf("memCallback: ffff map failed at 0x{x} err={}\n", .{address, @intFromEnum(map_err)});
        return false;
    }

    debug.printf("UNMAPPED ACCESS: address=0x{x} type={}\n", .{address, @intFromEnum(mem_type)});
    return false; // Unmapped access — stop emulation.
}

// S-mode runner entry point for emulated Virtual Cores.
pub fn emulatedRunnerSMode(vc_ptr: usize) callconv(.c) noreturn {
    const vc: *vcore.VirtualCore = @ptrFromInt(vc_ptr);
    while (vc.state != .stopped) {
        run(vc);

        if (comptime @import("builtin").is_test) {
            // We no longer use a block hook for asynchronous preemption.
            // True preemption is achieved by the M-mode physical timer handler
            // directly calling uc_emu_stop(), allowing us to run the JIT
            // at maximum throughput without basic-block intercepts!
        } else {
            // DIOSIX.YIELD
            asm volatile (
                \\li a7, 0x0A000005
                \\li a6, 1
                \\ecall
            );
        }
    }

    if (comptime @import("builtin").is_test) {} else {
        asm volatile (
            \\li a7, 0x0A000005
            \\li a6, 1
            \\ecall
        );
    }

    while (true) {}
}

fn translateSv32(uc: ?*anyopaque, satp: u64, va: u32) u64 {
    const root_ppn = satp & 0x3fffff;
    const root_pa = root_ppn * 4096;

    const vpn1 = va >> 22;
    const vpn0 = (va >> 12) & 0x3ff;
    const offset = va & 0xfff;

    var pte1: u32 = 0;
    if (glue.uc_mem_read(uc, root_pa + vpn1 * 4, @ptrCast(&pte1), 4) != .UC_ERR_OK) return 0;

    if ((pte1 & 1) == 0) return 0; // Invalid

    // Check if it's a leaf (R/W/X bits not all 0)
    if ((pte1 & 0xe) != 0) {
        // Superpage
        const ppn1 = pte1 >> 20;
        const ppn0 = (pte1 >> 10) & 0x3ff;
        const pa = (ppn1 * 1024 + ppn0) * 4096 + (va & 0x3fffff);
        return pa;
    }

    const level0_ppn = pte1 >> 10;
    const level0_pa = level0_ppn * 4096;

    var pte0: u32 = 0;
    if (glue.uc_mem_read(uc, level0_pa + vpn0 * 4, @ptrCast(&pte0), 4) != .UC_ERR_OK) return 0;
    if ((pte0 & 1) == 0) return 0; // Invalid

    const ppn = pte0 >> 10;
    return ppn * 4096 + offset;
}
