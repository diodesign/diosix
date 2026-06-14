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
const riscv = @import("riscv.zig");
const debug = @import("debug.zig");

/// Result of handling an exception from Unicorn.
pub const ExceptionAction = enum {
    /// Exception was emulated (e.g., CSR read). Resume at updated PC.
    emulated,
    /// Exception was delivered to the guest's trap handler via stvec/vbar.
    delivered,
    /// Exception could not be handled. Stop emulation.
    unhandled,
};

// Architecture-specific handlers
const rv32 = @import("arch/riscv32.zig");
const aarch64 = @import("arch/aarch64.zig");
const x86_64 = @import("arch/x86_64.zig");


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
        .aarch64 => glue.UC_MODE_64,
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
    const ctl_err = glue.uc_ctl(uc, @as(c_uint, 0x4400000d), @as(c_uint, 4 * 1024 * 1024));
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
    if (gpa_base > 0) {
        _ = glue.uc_mem_map_ptr(uc, 0, ram_size, glue.uc_prot.UC_PROT_ALL, @ptrFromInt(hpa_base));
        // Non-fatal: the guest may not need this mapping.
    }

    // Register hooks.
    var hook_mem: glue.uc_hook = null;
    _ = glue.uc_hook_add(uc, &hook_mem, glue.UC_HOOK_MEM_UNMAPPED, @as(?*const anyopaque, @ptrCast(&memCallback)), @as(?*anyopaque, @ptrCast(vc)), @as(u64, 0), @as(u64, 0xffffffffffffffff));

    // Invalid-instruction hook: intercepts instructions Unicorn cannot
    // handle natively (e.g., rdtime/rdtimeh when rdtime_fn is unset).
    // Runs inside the emulation loop so there is no stop/restart overhead.
    var hook_insn_invalid: glue.uc_hook = null;
    _ = glue.uc_hook_add(uc, &hook_insn_invalid, glue.UC_HOOK_INSN_INVALID, @as(?*const anyopaque, @ptrCast(&insnInvalidCallback)), @as(?*anyopaque, @ptrCast(vc)), @as(u64, 0), @as(u64, 0xffffffffffffffff));

    // Delegate to architecture-specific register initialization.
    switch (em.target_arch) {
        .riscv32 => rv32.initRegisters(uc, em.entry, em.dtb, vc.id),
        .aarch64 => aarch64.initRegisters(uc, em.entry, em.dtb, vc.id),
        .x86_64 => x86_64.initRegisters(uc, em.entry, em.dtb, vc.id),
        else => {},
    }
}

// Stop execution of the emulated vcore.
pub fn stop(vc: *vcore.VirtualCore) void {
    const em = &vc.exec_path.emulated;
    if (em.uc) |uc| {
        _ = glue.uc_emu_stop(uc);
    }
}

// Run the emulation loop.
//
// Executes the guest until an ECALL (which needs SBI/HVC/syscall handling),
// an unrecoverable error, or the exception budget is exhausted. S-mode
// exceptions are decoded and re-delivered to the guest's trap handler,
// matching real hardware behavior.
pub fn run(vc: *vcore.VirtualCore) void {
    init(vc) catch return;

    const em = &vc.exec_path.emulated;
    const uc = em.uc.?;

    // Read the current PC via the architecture handler.
    var pc: u64 = switch (em.target_arch) {
        .riscv32 => rv32.readPC(uc),
        .aarch64 => aarch64.readPC(uc),
        .x86_64 => x86_64.readPC(uc),
        else => return,
    };

    var exception_budget: u32 = 100000;
    while (exception_budget > 0) {

        const err = glue.uc_emu_start(uc, pc, 0xffffffffffffffff, 0, 0);

        const new_pc: u64 = switch (em.target_arch) {
            .riscv32 => rv32.readPC(uc),
            .aarch64 => aarch64.readPC(uc),
            .x86_64 => x86_64.readPC(uc),
            else => 0,
        };

        if (err == .UC_ERR_OK) {
            // Clean stop — check for ECALL/HVC/SYSCALL via arch handler.
            const handled = switch (em.target_arch) {
                .riscv32 => rv32.handleCleanStop(uc, vc, new_pc),
                .aarch64 => aarch64.handleCleanStop(uc, vc, new_pc),
                .x86_64 => x86_64.handleCleanStop(uc, vc, new_pc),
                else => false,
            };
            if (handled) return; // ECALL handled; yield to outer loop.
            return; // Clean stop with no ECALL — done.
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
                    // Instruction was emulated (CSR read, sfence, etc.).
                    // Resume at updated PC without consuming budget.
                    pc = switch (em.target_arch) {
                        .riscv32 => rv32.readPC(uc),
                        .aarch64 => aarch64.readPC(uc),
                        .x86_64 => x86_64.readPC(uc),
                        else => 0,
                    };
                    continue;
                },
                .delivered => {
                    // Trap delivered to guest handler via stvec/vbar.
                    pc = switch (em.target_arch) {
                        .riscv32 => rv32.readPC(uc),
                        .aarch64 => aarch64.readPC(uc),
                        .x86_64 => x86_64.readPC(uc),
                        else => 0,
                    };
                    exception_budget -= 1;
                    continue;
                },
                .unhandled => {
                    debug.printf("Unicorn: unhandled exception at PC 0x{x}\n", .{new_pc});
                    return;
                },
            }
        }

        // Any other error is fatal for this execution slice.
        debug.printf("Unicorn: execution error {} at PC 0x{x}\n", .{ err, new_pc });
        return;
    }

    debug.printf("Unicorn: exception budget exhausted\n", .{});
}

// Invalid-instruction callback — intercepts instructions that Unicorn
// cannot execute natively and emulates them inline. This fires inside
// the JIT loop so there is no engine stop/restart overhead.
//
// Currently handles RISC-V rdtime/rdtimeh/rdcycle/rdinstret by reading
// the real host timer and writing the result to the destination register.
fn insnInvalidCallback(uc: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) bool {
    const vc: *vcore.VirtualCore = @ptrCast(@alignCast(user_data.?));
    const em = &vc.exec_path.emulated;

    // Delegate to architecture-specific handler.
    return switch (em.target_arch) {
        .riscv32 => rv32.handleInvalidInsn(uc),
        .aarch64 => aarch64.handleInvalidInsn(uc),
        .x86_64 => x86_64.handleInvalidInsn(uc),
        else => false,
    };
}

// Memory callback for unmapped regions — handles MMIO (UART, etc.).
fn memCallback(uc: ?*anyopaque, mem_type: glue.uc_mem_type, address: u64, size: c_int, value: i64, user_data: ?*anyopaque) callconv(.c) bool {
    _ = uc;
    _ = size;
    const vc = @as(*vcore.VirtualCore, @ptrCast(@alignCast(user_data.?)));

    // UART console output (QEMU virt: 0x10000000).
    const uart_base = 0x10000000;
    if (address >= uart_base and address < uart_base + 8) {
        if (mem_type == .UC_MEM_WRITE_UNMAPPED) {
            debug.putcharFromGuest(vc.guest_id, @as(u8, @intCast(value & 0xff)));
        }
        return true;
    }

    return false; // Unmapped access — stop emulation.
}

// S-mode runner entry point for emulated Virtual Cores.
pub fn emulatedRunnerSMode(vc_ptr: usize) callconv(.c) noreturn {
    const vc: *vcore.VirtualCore = @ptrFromInt(vc_ptr);
    while (vc.state != .stopped) {
        run(vc);

        if (comptime @import("builtin").is_test) {
            break;
        } else {
            asm volatile ("ecall");
        }
    }

    if (comptime @import("builtin").is_test) {} else {
        asm volatile ("ecall");
    }

    while (true) {}
}
