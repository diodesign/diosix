// Cross-architecture guest VM emulation layer using Unicorn Engine.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const vcore = @import("vcore.zig");
const guest = @import("guest.zig");
const glue = @import("unicorn_glue.zig");
const riscv = @import("riscv.zig");
const debug = @import("debug.zig");
const sbi = @import("sbi.zig");

// Initialize Unicorn context for the given virtual core
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

        // Map the guest physical RAM contiguously
    // We map from GPA base address directly to host physical memory where RAM is allocated
    const ram_size = vc.guest.space.range_size;
    const gpa_base = vc.guest.space.base_gpa;
    const hpa_base = vc.guest.space.base_hpa;

    const map_err = glue.uc_mem_map_ptr(uc, gpa_base, ram_size, glue.uc_prot.UC_PROT_ALL, @ptrFromInt(hpa_base));
    if (map_err != .UC_ERR_OK) {
        debug.printf("Unicorn: failed to map GPA 0x{x} to HPA 0x{x}, err={}\n", .{ gpa_base, hpa_base, map_err });
        _ = glue.uc_close(uc);
        em.uc = null;
        return error.UnicornMapFailed;
    }

    // Register hooks
    var hook_intr: glue.uc_hook = null;
    const hook_err = glue.uc_hook_add(uc, &hook_intr, 1, @as(?*const anyopaque, @ptrCast(&intrCallback)), @as(?*anyopaque, @ptrCast(vc)), @as(u64, 0), @as(u64, 0xffffffffffffffff));
    if (hook_err != .UC_ERR_OK) {
        debug.printf("Unicorn: failed to add interrupt hook, err={}\n", .{hook_err});
    }

    var hook_mem: glue.uc_hook = null;
    const mem_hook_err = glue.uc_hook_add(uc, &hook_mem, glue.UC_HOOK_MEM_UNMAPPED, @as(?*const anyopaque, @ptrCast(&memCallback)), @as(?*anyopaque, @ptrCast(vc)), @as(u64, 0), @as(u64, 0xffffffffffffffff));
    if (mem_hook_err != .UC_ERR_OK) {
        debug.printf("Unicorn: failed to add unmapped memory hook, err={}\n", .{mem_hook_err});
    }

    // Set initial register states
    switch (em.target_arch) {
        .riscv32 => {
            const pc_val = @as(u32, @intCast(em.entry));
            _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_PC), &pc_val);
            const a0_val = @as(u32, @intCast(vc.id));
            _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X10), &a0_val); // a0
            const a1_val = @as(u32, @intCast(em.dtb));
            _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X11), &a1_val); // a1
        },
        .aarch64 => {
            _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_arm64_reg.UC_ARM64_REG_PC), &em.entry);
            _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_arm64_reg.UC_ARM64_REG_X0), &em.dtb); // x0 = DTB
        },
        .x86_64 => {
            _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_x86_reg.UC_X86_REG_RIP), &em.entry);
        },
        else => {},
    }
}

// Stop execution of the emulated vcore
pub fn stop(vc: *vcore.VirtualCore) void {
    const em = &vc.exec_path.emulated;
    if (em.uc) |uc| {
        _ = glue.uc_emu_stop(uc);
    }
}

// Run the emulation loop
pub fn run(vc: *vcore.VirtualCore) void {
    init(vc) catch return;

    const em = &vc.exec_path.emulated;
    const uc = em.uc.?;

    // Read PC to know where we are starting
    var pc: u64 = 0;
    switch (em.target_arch) {
        .riscv32 => {
            var temp_pc: u32 = 0;
            _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_PC), &temp_pc);
            pc = temp_pc;
        },
        .aarch64 => {
            _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_arm64_reg.UC_ARM64_REG_PC), &pc);
        },
        .x86_64 => {
            _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_x86_reg.UC_X86_REG_RIP), &pc);
        },
        else => return,
    }

    // Start emulation (timeout=0, count=0 for infinite execution until stopped/preempted)
    const err = glue.uc_emu_start(uc, pc, 0xffffffffffffffff, 0, 0);
    if (err != .UC_ERR_OK) {
        debug.printf("Unicorn: execution stopped with error: {}\n", .{err});
    }
}

// Emulate MMIO for unmapped memory regions (UART/PLIC/CLINT/etc.)
fn memCallback(uc: ?*anyopaque, mem_type: glue.uc_mem_type, address: u64, size: c_int, value: i64, user_data: ?*anyopaque) callconv(.c) bool {
    _ = uc;
    const vc = @as(*vcore.VirtualCore, @ptrCast(@alignCast(user_data)));

    // Standard UART/console address mapping (commonly 0x10000000 in QEMU virt)
    const uart_base = 0x10000000;
    if (address >= uart_base and address < uart_base + 8) {
        if (mem_type == .UC_MEM_WRITE_UNMAPPED) {
            const char = @as(u8, @intCast(value & 0xff));
            debug.putcharFromGuest(vc.guest_id, char);
        }
        return true;
    }

    debug.printf("Unicorn MMIO: unmapped access of type {} at address 0x{x} (size {})\n", .{ mem_type, address, size });
    return false; // Stop emulation on other unmapped access
}

// Emulate system calls (ECALL/SVC/INT) inside Unicorn
fn intrCallback(uc: ?*anyopaque, intno: u32, user_data: ?*anyopaque) callconv(.c) void {
    const vc = @as(*vcore.VirtualCore, @ptrCast(@alignCast(user_data)));
    const em = &vc.exec_path.emulated;

    switch (em.target_arch) {
        .riscv32 => {
            // Check if it's an ECALL (interrupt number 8 or 9 or exception cause for environment calls)
            // On RISC-V, ECALL generally triggers exception / callback
            var a7: u32 = 0;
            var a0: u32 = 0;
            var a1: u32 = 0;
            _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X17), &a7); // a7
            _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X10), &a0); // a0
            _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X11), &a1); // a1

            // Mock a thread context to pass to the native SBI handler
            var mock_context = std.mem.zeroes(riscv.ThreadContext);
            mock_context[@intFromEnum(riscv.Register.a7)] = a7;
            mock_context[@intFromEnum(riscv.Register.a0)] = a0;
            mock_context[@intFromEnum(riscv.Register.a1)] = a1;

            sbi.handle(vc, &mock_context);

            // Write results back
            const res_a0 = @as(u32, @intCast(mock_context[@intFromEnum(riscv.Register.a0)]));
            const res_a1 = @as(u32, @intCast(mock_context[@intFromEnum(riscv.Register.a1)]));
            _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X10), &res_a0);
            _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X11), &res_a1);

            // Skip ECALL instruction (PC += 4)
            var pc: u32 = 0;
            _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_PC), &pc);
            pc += 4;
            _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_PC), &pc);
        },
        .aarch64 => {
            // AArch64 SVC call
            debug.printf("Unicorn AArch64: SVC call exception {} occurred\n", .{intno});
        },
        .x86_64 => {
            // x86 interrupt
            debug.printf("Unicorn x86_64: Interrupt {} occurred\n", .{intno});
        },
        else => {},
    }
}

// S-mode runner entry point for the emulated Virtual Core.
// a0 is mapped to `vc_ptr` on entry.
pub fn emulatedRunnerSMode(vc_ptr: usize) callconv(.c) noreturn {
    const vc: *vcore.VirtualCore = @ptrFromInt(vc_ptr);
    while (vc.state != .stopped) {
        run(vc);
        
        // Trap back to M-mode via ECALL to yield or handle exit
        if (comptime @import("builtin").is_test) {
            break;
        } else {
            asm volatile ("ecall");
        }
    }
    
    // Final yield on exit
    if (comptime @import("builtin").is_test) {} else {
        asm volatile ("ecall");
    }
    
    while (true) {}
}
