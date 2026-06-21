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
    }

    if (em.target_arch == .riscv32 and gpa_base > 0) {
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

    while (exception_budget > 0) {


        // Sync pending interrupts to the guest's MIP register and manually inject
        // traps if interrupts are enabled.
        if (em.target_arch == .riscv32) {
            var mip: u64 = 0;
            _ = glue.uc_reg_read(uc, rv32.UC_REG_MIP, &mip);

            const MIP_SSIP: u64 = 1 << 1;




            // 1. Software Interrupts (IPIs)
            // SSIP is writable in Unicorn's mip, so we can set it via uc_reg_write.
            if (@atomicLoad(bool, &vc.pending_ipi, .acquire)) {
                mip |= MIP_SSIP;
            } else {
                mip &= ~MIP_SSIP;
            }

            // 2. Timer Interrupts
            // We set STIP in mip if a timer is pending. Unicorn allows this, and
            // it allows QEMU to naturally evaluate the interrupt once SIE becomes 1
            // without needing manual interrupt injection.
            if (vc.timer_scheduled) {
                const now = rv32.readVirtualTime(uc);
                if (now >= vc.timer_target) {
                    mip |= @as(u64, 1 << 5); // MIP_STIP
                } else {
                    mip &= ~@as(u64, 1 << 5); // Clear MIP_STIP
                }
            } else {
                mip &= ~@as(u64, 1 << 5); // Clear MIP_STIP
            }

            // Temporarily elevate to M-mode so the write to MIP (for SSIP and STIP) succeeds
            var current_priv: u32 = 0;
            _ = glue.uc_reg_read(uc, rv32.UC_REG_PRIV, &current_priv);
            var m_priv: u32 = 3; // PRV_M
            _ = glue.uc_reg_write(uc, rv32.UC_REG_PRIV, &m_priv);

            _ = glue.uc_reg_write(uc, rv32.UC_REG_MIP, &mip);

            // Restore previous privilege mode
            _ = glue.uc_reg_write(uc, rv32.UC_REG_PRIV, &current_priv);
        }

        // Run the guest infinitely (instruction count 0). Asynchronous preemption
        // via physical hardware timers (machine_timer in xint.zig) will
        // call uc_emu_stop() to break this loop when the hypervisor quantum expires
        // or a physical interrupt arrives.
        em.preempt_pending = false;
        em.emu_running = true;
        const err = glue.uc_emu_start(uc, pc, 0xffffffffffffffff, 0, 0);
        em.emu_running = false;

        // Clear stale CPU exit flags left by asynchronous uc_emu_stop
        // (called from M-mode timer handler). Without this, the JIT
        // immediately exits on the next uc_emu_start call.
        glue.diosix_uc_clear_stop(uc);



        // After returning from Unicorn, read back MIP to see if the guest cleared
        // the pending software interrupt (IPI).
        if (em.target_arch == .riscv32) {
            var mip: u64 = 0;
            _ = glue.uc_reg_read(uc, rv32.UC_REG_MIP, &mip);
            const MIP_SSIP: u64 = 1 << 1;
            if ((mip & MIP_SSIP) == 0) {
                _ = @atomicRmw(bool, &vc.pending_ipi, .Xchg, false, .acq_rel);
            }
        }

        const new_pc: u64 = switch (em.target_arch) {
            .riscv32 => rv32.readPC(uc),
            .aarch64 => aarch64.readPC(uc),
            .x86_64 => x86_64.readPC(uc),
            else => 0,
        };

        // Debug: log first 10 run iterations for aarch64.
        if (em.target_arch == .aarch64) {
            const S_run = struct {
                var run_count: u32 = 0;
            };
            if (S_run.run_count < 10) {
                S_run.run_count += 1;
                var x30: u64 = 0;
                _ = glue.uc_reg_read(uc, @intFromEnum(glue.uc_arm64_reg.UC_ARM64_REG_X30), &x30);
                var insn_bytes: u32 = 0;
                _ = glue.uc_mem_read(uc, new_pc, @as([*]u8, @ptrCast(&insn_bytes)), 4);
                debug.printf("aarch64 run #{}: err={} pc=0x{x}->0x{x} LR=0x{x} insn=0x{x}\n", .{ S_run.run_count, err, pc, new_pc, x30, insn_bytes });
            }
        }

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
            if (handled) return; // ECALL or WFI handled; yield to outer loop.

            // If we were preempted by a physical timer or IPI (via xint_handler),
            // yield the physical core so the scheduler can run.
            if (em.preempt_pending) {
                pc = new_pc;
                return;
            }

            // Normal completion of the execution slice (100k instructions).
            // Decrement the loop budget so we eventually yield the core.
            if (exception_budget > 100_000) {
                exception_budget -= 100_000;
            } else {
                exception_budget = 0;
            }
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
                        else => return,
                    };
                    exception_budget -= 1;
                    continue;
                },
                .unhandled => {
                    debug.printf("Unhandled exception {} at PC 0x{x}\n", .{em.exception_cause, pc});
                    vc.state = .stopped;
                    return;
                },
            }
        }

        // Any other error is fatal for this execution slice.
        debug.printf("Unicorn: execution error {} at PC 0x{x}\n", .{ err, new_pc });
        return;
    }
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

    const now = switch (em.target_arch) {
        .riscv32 => rv32.readVirtualTime(uc),
        else => glue.readSModeTime(),
    };
    if (now >= vc.timer_target) {
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

    switch (em.target_arch) {
        .riscv32 => intrCallbackRiscv32(uc, intno, vc),
        .aarch64 => intrCallbackAarch64(uc, intno, vc),
        else => {},
    }
}

// RISC-V specific interrupt handling.
fn intrCallbackRiscv32(uc: ?*anyopaque, intno: u32, vc: *vcore.VirtualCore) void {



    // Cause 2: Illegal Instruction. QEMU throws this for rdtime/rdcycle
    // because we deliberately set MCOUNTEREN=0 to trap them.
    if (intno == 2) {
        if (rv32.handleInvalidInsn(uc)) {
            // Emulation successful. PC was advanced. Continue execution.
            return;
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

// Memory callback for unmapped regions — handles MMIO (UART, etc.).
fn memCallback(uc: ?*anyopaque, mem_type: glue.uc_mem_type, address: u64, size: c_int, value: i64, user_data: ?*anyopaque) callconv(.c) bool {
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

    // Debug: log first few unmapped accesses to understand guest behavior.
    const S2 = struct {
        var unmapped_log_count: u32 = 0;
    };
    if (S2.unmapped_log_count < 20) {
        S2.unmapped_log_count += 1;
        debug.printf("MMIO: {} addr=0x{x} size={} val=0x{x}\n", .{ mem_type, address, size, value });
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
        if (map_err == .UC_ERR_OK) {
            return true; // Retry the access — it should succeed now.
        }
        // If mapping failed (e.g., overlap), still return true to avoid crash.
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
