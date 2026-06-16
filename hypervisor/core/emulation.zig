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
const sbi = @import("sbi.zig");

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

// ---- Named constants (avoid magic numbers) ----

/// Unicorn control command to set the TCG translation buffer size.
/// Encoded as UC_CTL_WRITE | UC_CTL_TB_REQUEST_CACHE (0x0d).
const UC_CTL_TB_CACHE_SIZE: c_uint = 0x4400000d;

/// QEMU virt platform UART base address (NS16550A).
const QEMU_VIRT_UART_BASE: u64 = 0x10000000;

/// Maximum number of exception-stop cycles before the emulation loop
/// yields back to the scheduler. Prevents runaway exception storms.
const EXCEPTION_BUDGET: u32 = 1_000_000;


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

    // Block hook: DISABLED — using uc_emu_start count parameter for
    // bounded execution instead. Timer/preemption checks happen in
    // the outer loop between uc_emu_start calls.
    // var hook_block: glue.uc_hook = null;
    // _ = glue.uc_hook_add(uc, &hook_block, glue.UC_HOOK_BLOCK, @as(?*const anyopaque, @ptrCast(&blockCallback)), @as(?*anyopaque, @ptrCast(vc)), @as(u64, 0), @as(u64, 0xffffffffffffffff));

    // Delegate to architecture-specific register initialization.
    switch (em.target_arch) {
        .riscv32 => rv32.initRegisters(uc, em.entry, em.dtb, vc.id),
        .aarch64 => aarch64.initRegisters(uc, em.entry, em.dtb, vc.id),
        .x86_64 => x86_64.initRegisters(uc, em.entry, em.dtb, vc.id),
        else => {},
    }

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
    // Set preempt flag — checked by blockCallback inside the JIT loop.
    // uc_emu_stop from M-mode doesn't reliably interrupt the JIT because
    // Unicorn's quit_request flag isn't checked between TBs in this build.
    em.preempt_pending = true;
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

    // Read the current PC via the architecture handler.
    var pc: u64 = switch (em.target_arch) {
        .riscv32 => rv32.readPC(uc),
        .aarch64 => aarch64.readPC(uc),
        .x86_64 => x86_64.readPC(uc),
        else => return,
    };


    var exception_budget: u32 = EXCEPTION_BUDGET;

    while (exception_budget > 0) {

        // Check for pending timer interrupt before (re-)entering the guest.
        // The guest calls SBI SET_TIMER which sets vc.timer_target. If the
        // current time has passed the target, deliver a supervisor timer
        // interrupt through the guest's stvec. This is the emulated
        // equivalent of the hardware STIP interrupt.
        if (em.target_arch == .riscv32 and vc.timer_scheduled) {
            const now = glue.readSModeTime();
            if (now >= vc.timer_target) {
                // Timer has expired. Only deliver if the guest has interrupts
                // enabled (SIE bit) and has the timer interrupt enabled in sie.
                var sstatus: u64 = 0;
                _ = glue.uc_reg_read(uc, rv32.UC_REG_SSTATUS, &sstatus);
                var sie: u64 = 0;
                _ = glue.uc_reg_read(uc, rv32.UC_REG_SIE, &sie);

                const SSTATUS_SIE: u64 = 1 << 1;
                const SIE_STIE: u64 = 1 << 5; // Supervisor timer interrupt enable

                if ((sstatus & SSTATUS_SIE) != 0 and (sie & SIE_STIE) != 0) {
                    vc.timer_scheduled = false;
                    vc.timer_skip_blocks = 0;
                    // Deliver timer interrupt: save state, set scause, jump to stvec.
                    rv32.deliverInterrupt(uc, pc, 5); // cause 5 = supervisor timer interrupt
                    pc = rv32.readPC(uc);
                    continue;
                } else {
                    // Interrupts disabled — let the kernel execute ~1000 blocks
                    // before we stop and re-check. This prevents a busy loop
                    // when the kernel is in a critical section with SIE=0.
                    vc.timer_skip_blocks = 1000;
                }
            }
        }

        // Run the guest with a bounded instruction count. The count
        // parameter limits instructions per call, ensuring uc_emu_start
        // returns periodically so we can check timers and handle
        // preemption. Without this, QEMU's TB chaining can keep the
        // JIT running indefinitely in tight loops.
        em.preempt_pending = false;
        em.emu_running = true;
        const err = glue.uc_emu_start(uc, pc, 0xffffffffffffffff, 0, 100_000);
        em.emu_running = false;
        // Clear stale CPU exit flags left by asynchronous uc_emu_stop
        // (called from M-mode timer handler). Without this, the JIT
        // immediately exits on the next uc_emu_start call.
        glue.diosix_uc_clear_stop(uc);

        const new_pc: u64 = switch (em.target_arch) {
            .riscv32 => rv32.readPC(uc),
            .aarch64 => aarch64.readPC(uc),
            .x86_64 => x86_64.readPC(uc),
            else => 0,
        };

        if (err == .UC_ERR_OK) {

            // Clean stop — check for ECALL/HVC/SYSCALL via arch handler.
            // Note: if blockCallback stopped us (for timer), the current PC
            // is at a random TB boundary, not necessarily an ecall. If
            // intrCallback handled an ecall, PC is already past it (ecall+4).
            const handled = switch (em.target_arch) {
                .riscv32 => rv32.handleCleanStop(uc, vc, new_pc),
                .aarch64 => aarch64.handleCleanStop(uc, vc, new_pc),
                .x86_64 => x86_64.handleCleanStop(uc, vc, new_pc),
                else => false,
            };
            if (handled) return; // ECALL handled; yield to outer loop.
            // Clean stop from timer preemption or block yield.
            // The timer is reprogrammed by xint_handler (M-mode), so we
            // just continue the emulation loop.
            pc = new_pc;
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
                    pc = switch (em.target_arch) {
                        .riscv32 => rv32.readPC(uc),
                        .aarch64 => aarch64.readPC(uc),
                        .x86_64 => x86_64.readPC(uc),
                        else => 0,
                    };
                    continue;
                },
                .delivered => {
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
// Block callback — fires at the start of each translation block inside
// the JIT loop. Used to check for pending timer interrupts since neither
// count nor timeout parameters work in our bare-metal environment.
//
// IMPORTANT: Must NOT call uc_reg_read/uc_reg_write here because those
// functions call restore_jit_state() which corrupts JIT execution state
// when invoked from within the JIT loop. Instead, only check the timer
// target against rdtime and stop the engine if it has expired. The
// actual CSR checks and interrupt delivery happen in the outer loop.
fn blockCallback(uc: ?*anyopaque, _: u64, _: u32, user_data: ?*anyopaque) callconv(.c) void {
    const vc: *vcore.VirtualCore = @ptrCast(@alignCast(user_data.?));
    const em = &vc.exec_path.emulated;

    // Check preemption: the M-mode timer handler sets this flag when
    // the timeslice expires. We stop from within the JIT (guaranteed
    // safe) rather than relying on uc_emu_stop from M-mode context.
    if (em.preempt_pending) {
        _ = glue.uc_emu_stop(uc);
        return;
    }

    // Check guest timer: if the emulated kernel set a supervisor timer
    // via SBI SET_TIMER, stop the engine when it expires so the outer
    // loop can deliver the interrupt.
    if (!vc.timer_scheduled) return;

    const now = glue.readSModeTime();
    if (now >= vc.timer_target) {
        if (vc.timer_skip_blocks > 0) {
            vc.timer_skip_blocks -= 1;
            return;
        }
        _ = glue.uc_emu_stop(uc);
    }
}

// Invalid-instruction callback — intercepts instructions that Unicorn
// cannot execute natively and emulates them inline. This fires inside
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

// Interrupt/exception callback — intercepts CPU exceptions before QEMU
// delivers them to mtvec/stvec. This is the primary path for handling
// SBI calls (ecall from S-mode).
fn intrCallback(uc: ?*anyopaque, intno: u32, user_data: ?*anyopaque) callconv(.c) void {
    const vc: *vcore.VirtualCore = @ptrCast(@alignCast(user_data.?));
    const em = &vc.exec_path.emulated;
    if (em.target_arch != .riscv32) return;

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

        sbi.handle(vc, &mock_context);

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
    var info: glue.InterruptInfo = std.mem.zeroes(glue.InterruptInfo);
    glue.diosix_uc_do_interrupt(uc, @intCast(intno), &info);

    // Flush Unicorn TB cache so the next uc_emu_start generates fresh
    // translation blocks with the updated CSR/privilege state.
    _ = glue.uc_ctl(uc, @as(c_uint, glue.UC_CTL_FLUSH_TB));

    // Stop execution so that uc_emu_start returns. The run loop will
    // re-enter at the new PC (stvec), generating a fresh translation block
    // with the correct privilege and CSR state.
    _ = glue.uc_emu_stop(uc);
}

// Memory callback for unmapped regions — handles MMIO (UART, etc.).
fn memCallback(uc: ?*anyopaque, mem_type: glue.uc_mem_type, address: u64, size: c_int, value: i64, user_data: ?*anyopaque) callconv(.c) bool {
    _ = uc;
    _ = size;
    const vc = @as(*vcore.VirtualCore, @ptrCast(@alignCast(user_data.?)));

    // UART console output.
    if (address >= QEMU_VIRT_UART_BASE and address < QEMU_VIRT_UART_BASE + 8) {
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
