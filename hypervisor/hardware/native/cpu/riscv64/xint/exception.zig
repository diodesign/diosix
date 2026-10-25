// Exception handling, G-stage fault dispatch, and guest reflection on RISC-V.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const debug = @import("../../../../../core/debug.zig");
const interface = @import("interface").riscv;
const riscv = @import("../mod.zig");
const xint = @import("../xint.zig");
const csr_emu = @import("csr.zig");
const pcore = @import("../../../../../core/pcore.zig");
const vcore = @import("../../../../../core/vcore.zig");
const sbi = @import("../../../../../core/sbi.zig");
const scheduler = @import("../../../../../core/scheduler.zig");

/// Handle a synchronous exception trapped to M-mode.
pub fn handleException(irq: xint.IRQ, context: *riscv.ThreadContext) void {
    if (irq.privilege_mode == .machine) {
        if (irq.irq_type == .exception and
            irq.cause != .machine_environment_call)
        {
            const pcpu = pcore.this();
            if (pcpu.probing_active) {
                pcpu.probe_failed = true;
                // Advance PC past the 4-byte probing instruction.
                riscv.writeMepc(irq.pc + riscv.Instr.INSN_SIZE_BYTES);
                return;
            }
            fatalException(irq, context);
            return;
        }
    }

    switch (irq.cause) {
        .illegal_instruction, .virtual_instruction => {
            const pcpu = pcore.this();
            const vc_raw = pcpu.active_vcore orelse {
                fatalException(irq, context);
                return;
            };
            const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));

            const instr: usize = blk: {
                if (irq.val != 0) break :blk irq.val;
                if (riscv.hasHExtension()) {
                    break :blk csr_emu.fetchGuestInstruction(irq.pc);
                }
                break :blk 0;
            };

            if (csr_emu.emulateInstruction(
                vc,
                instr,
                context,
                irq.privilege_mode,
            ) == .handled) {
                return;
            }

            var reflect_irq = irq;
            reflect_irq.val = instr;
            reflectExceptionToGuest(vc, reflect_irq) catch |err| {
                debug.printf("Reflection failed: {s}\n", .{@errorName(err)});
                fatalException(irq, context);
            };
        },
        .machine_environment_call,
        .supervisor_environment_call,
        .virtual_supervisor_environment_call,
        => {
            const pcpu = pcore.this();
            if (pcpu.active_vcore) |vc_raw| {
                const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
                if (vc.exec_path == .emulated) {
                    // Emulator runner yielding: advance PC past ECALL.
                    vc.getNativeMachine().mepc += riscv.Instr.INSN_SIZE_BYTES;
                    scheduler.schedule();
                } else if (irq.cause == .machine_environment_call) {
                    debug.printf(
                        "Unhandled M-mode ecall from native guest\n",
                        .{},
                    );
                    fatalException(irq, context);
                } else {
                    sbi.handle(vc, 0, context);
                }
            }
        },
        .guest_instruction_page_fault,
        .guest_load_page_fault,
        .guest_store_page_fault,
        .unknown,
        => {
            if (irq.irq_type == .exception) {
                handleGuestPageFault(irq, context);
            }
        },
        else => {
            if (irq.irq_type == .exception) {
                const pcpu = pcore.this();
                if (pcpu.active_vcore) |vc_raw| {
                    const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
                    reflectExceptionToGuest(vc, irq) catch |err| {
                        debug.printf(
                            "Reflection failed: {s}\n",
                            .{@errorName(err)},
                        );
                        fatalException(irq, context);
                    };
                } else {
                    fatalException(irq, context);
                }
            }
        },
    }
}

const STVEC_MODE_MASK: usize = 0b11;

fn handleGuestPageFault(irq: xint.IRQ, context: *riscv.ThreadContext) void {
    const pcpu = pcore.this();
    const vc_raw = pcpu.active_vcore orelse return;
    const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));

    var gpa: usize = 0;
    if (riscv.hasHExtension()) {
        const mtval2 = riscv.readMtval2();
        const htval_val = riscv.readHtval();
        gpa = if (mtval2 != 0) mtval2 else htval_val;
        // Per the RISC-V Hypervisor specification, mtval2 and htval hold
        // the guest physical address shifted right by 2 bits.
        if (gpa != 0) gpa <<= interface.HTVAL_GPA_SHIFT;
    } else {
        gpa = irq.val;
    }

    if (!riscv.hasHExtension()) {
        var reflected_irq = irq;
        reflected_irq.cause = switch (irq.cause) {
            .guest_instruction_page_fault => .instruction_page_fault,
            .guest_load_page_fault => .load_page_fault,
            .guest_store_page_fault => .store_page_fault,
            else => irq.cause,
        };
        reflectExceptionToGuest(vc, reflected_irq) catch |err| {
            debug.printf("Reflection failed: {s}\n", .{@errorName(err)});
            fatalException(irq, context);
        };
        return;
    }

    const g = vc.getGuest();
    const is_anon_dram = (g.space.base_hpa == 0 and
        gpa >= g.space.base_gpa and
        (gpa - g.space.base_gpa) < g.space.range_size);
    const was_unmapped = is_anon_dram and
        ((g.space.translateGPA(gpa) catch null) == null);
    if (was_unmapped and !g.checkRamQuota(1)) {
        debug.printf("Fault: GPA 0x{x} exceeded guest RAM quota\n", .{gpa});
        g.onMemoryPoolExhausted();
        if (!g.is_root) {
            scheduler.schedule();
            return;
        }
        fatalException(irq, context);
        return;
    }
    g.space.handleFault(vc, gpa, @backingInt(irq.cause)) catch |err| {
        if (was_unmapped and err == error.OutOfMemory) {
            g.onMemoryPoolExhausted();
            if (!g.is_root) {
                scheduler.schedule();
                return;
            }
        }
        debug.printf(
            "Fault: GPA 0x{x} resolution failed: {s}\n",
            .{ gpa, @errorName(err) },
        );
        fatalException(irq, context);
        return;
    };
    if (was_unmapped) g.consumeQuota(1, 0);
    pcpu.gstage_dirty = true;
}

/// Reflect a synchronous exception back to the guest supervisor (VS/S-mode).
pub fn reflectExceptionToGuest(
    vc: *vcore.VirtualCore,
    irq: xint.IRQ,
) !void {
    if (vc.exec_path == .emulated) {
        debug.printf(
            "FATAL: reflectExceptionToGuest called for emulated vCore! " ++
                "cause={}\n",
            .{irq.cause},
        );
        fatalException(irq, null);
        return error.EmulatedVCoreFault;
    }

    const ms = vc.getNativeMachine();
    const gs = vc.getNativeGuestState();

    gs.vsepc = irq.pc;
    // Virtual instruction exceptions (cause 22) must be reflected to the
    // guest as illegal instruction (cause 2) per the RISC-V H-extension spec.
    gs.vscause = if (irq.cause == .virtual_instruction)
        @backingInt(riscv.Cause.illegal_instruction)
    else
        @backingInt(irq.cause);
    gs.vstval = irq.val;

    // Update VSSTATUS/SSTATUS: SPP = prev priv, SPIE = old SIE, SIE = 0.
    const sie_active = (gs.vsstatus & riscv.SSTATUS.SIE) != 0;
    gs.vsstatus &= ~@as(
        usize,
        riscv.SSTATUS.SIE | riscv.SSTATUS.SPIE | riscv.MSTATUS.SPP,
    );
    if (irq.privilege_mode == .supervisor) {
        gs.vsstatus |= riscv.MSTATUS.SPP;
    }
    if (sie_active) {
        gs.vsstatus |= riscv.SSTATUS.SPIE;
    }

    // Enter Supervisor mode (MPP = 1) on mret.
    ms.mstatus &= ~@as(usize, riscv.MSTATUS.MPP_MASK);
    ms.mstatus |= riscv.MSTATUS.MPP_SUPERVISOR;

    if (riscv.hasHExtension()) {
        ms.mstatus |= riscv.MSTATUS.MPV;
    }

    const base = gs.vstvec & ~STVEC_MODE_MASK;
    if (base == 0) {
        debug.printf(
            "FATAL: Reflecting exception to NULL vstvec — terminating guest.\n",
            .{},
        );
        vc.getGuest().terminate();
        return error.InvalidAddress;
    }

    // Synchronous exceptions always jump to the base address.
    ms.mepc = base;

    if (riscv.hasHExtension()) {
        ms.hstatus &= ~riscv.HSTATUS.SPVP;
        if (irq.privilege_mode == .supervisor) {
            ms.hstatus |= riscv.HSTATUS.SPVP;
        }
    }
}

var fatal_exception_active = std.atomic.Value(bool).init(false);
var cpu_in_fatal = std.mem.zeroes([pcore.MAX_SYSTEM_CORES]bool);

/// Handle an unrecoverable exception in M-mode or an unhandled guest crash.
pub fn fatalException(
    irq: xint.IRQ,
    context: ?*riscv.ThreadContext,
) void {
    if (irq.privilege_mode != .machine) {
        const pcpu = pcore.this();
        if (pcpu.active_vcore) |vc_raw| {
            const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
            const g = vc.getGuest();
            if (!g.is_root) {
                debug.printf(
                    "\nChild guest VM (ID {}) crashed at PC 0x{x} " ++
                        "(cause: {s}, MTVAL: 0x{x}). Terminating subtree.\n",
                    .{
                        g.id,
                        irq.pc,
                        @tagName(irq.cause),
                        riscv.readMtval(),
                    },
                );
                g.terminate();
                return;
            }
        }
    }

    const cpu_id = pcore.this().cpu_core_id;
    if (cpu_id < cpu_in_fatal.len) {
        if (cpu_in_fatal[cpu_id]) {
            const rec_msg = "\n!REC!\n";
            for (rec_msg) |ch| debug.hw_putchar(ch);
            while (true) {}
        }
        cpu_in_fatal[cpu_id] = true;
    }

    if (fatal_exception_active.swap(true, .seq_cst)) {
        while (true) {}
    }

    debug.releaseLocksForCrash();
    debug.printf("\nBug! Fatal exception\n", .{});
    debug.printf(
        "Cause: {s} (0x{x})\n",
        .{ @tagName(irq.cause), @backingInt(irq.cause) },
    );
    debug.printf("Privilege: {s}\n", .{@tagName(irq.privilege_mode)});
    debug.printf("PC: 0x{x}, SP: 0x{x}\n", .{ irq.pc, irq.sp });
    debug.printf(
        "HTVAL: 0x{x}, MTVAL: 0x{x}\n",
        .{ riscv.readHtval(), riscv.readMtval() },
    );

    if (context) |ctx| {
        debug.printf("Registers:\n", .{});
        debug.printf(
            " ra: 0x{x}, gp: 0x{x}, tp: 0x{x}\n",
            .{ ctx[1], ctx[3], ctx[4] },
        );
        debug.printf(
            " t0: 0x{x}, t1: 0x{x}, t2: 0x{x}\n",
            .{ ctx[5], ctx[6], ctx[7] },
        );
        debug.printf(" s0/fp: 0x{x}, s1: 0x{x}\n", .{ ctx[8], ctx[9] });
        debug.printf(
            " a0: 0x{x}, a1: 0x{x}, a2: 0x{x}, a3: 0x{x}\n",
            .{ ctx[10], ctx[11], ctx[12], ctx[13] },
        );
        debug.printf(
            " a4: 0x{x}, a5: 0x{x}, a6: 0x{x}, a7: 0x{x}\n",
            .{ ctx[14], ctx[15], ctx[16], ctx[17] },
        );
        debug.printf(
            " s2-s11: 0x{x} 0x{x} 0x{x} 0x{x} 0x{x} " ++
                "0x{x} 0x{x} 0x{x} 0x{x} 0x{x}\n",
            .{
                ctx[18], ctx[19], ctx[20], ctx[21], ctx[22],
                ctx[23], ctx[24], ctx[25], ctx[26], ctx[27],
            },
        );
        debug.printf(
            " t3-t6: 0x{x} 0x{x} 0x{x} 0x{x}\n",
            .{ ctx[28], ctx[29], ctx[30], ctx[31] },
        );
    }

    if (irq.privilege_mode == .machine) {
        debug.printf("Hypervisor crashed. Halting.\n", .{});
        while (true) {}
    } else {
        debug.printf("Guest environment crashed. Terminating subtree.\n", .{});
        const pcpu = pcore.this();
        if (pcpu.active_vcore) |vc_raw| {
            const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
            const g = vc.getGuest();
            g.terminate();
            if (g.is_root) {
                debug.printf("Root VM crashed. Halting host.\n", .{});
                while (true) {}
            }
        } else {
            debug.printf(
                "No active vcore found for guest crash. Halting.\n",
                .{},
            );
            while (true) {}
        }
    }
}

test "exception: reflectExceptionToGuest maps virtual_instruction" {
    std.testing.refAllDecls(@This());
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
    vc.getNativeGuestState().vstvec = 0x80200001; // vectored mode bit set
    vc.getNativeGuestState().vsstatus = riscv.SSTATUS.SIE;

    const irq = xint.IRQ{
        .severity = .fatal,
        .privilege_mode = .supervisor,
        .irq_type = .exception,
        .cause = .virtual_instruction,
        .pc = 0x80001234,
        .sp = 0x80009000,
        .val = riscv.Instr.WFI,
    };

    try reflectExceptionToGuest(&vc, irq);
    const gs = vc.getNativeGuestState();
    try std.testing.expectEqual(@as(u64, 0x80001234), gs.vsepc);
    try std.testing.expectEqual(
        @as(u64, @backingInt(riscv.Cause.illegal_instruction)),
        gs.vscause,
    );
    try std.testing.expectEqual(@as(u64, riscv.Instr.WFI), gs.vstval);
    try std.testing.expectEqual(
        @as(u64, 0x80200000),
        vc.getNativeMachine().mepc,
    );
    try std.testing.expect((gs.vsstatus & riscv.SSTATUS.SIE) == 0);
    try std.testing.expect((gs.vsstatus & riscv.SSTATUS.SPIE) != 0);
}
