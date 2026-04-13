// High-level exception and interrupt (xint) handling on RISC-V.
//
// Copyright (c) 2024, 2025, 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const main = @import("main.zig");
const builtin = @import("builtin");
const debug = @import("debug.zig");
const riscv = @import("riscv.zig");
const pcore = @import("pcore.zig");
const vcore = @import("vcore.zig");
const sbi = @import("sbi.zig");
const vm_space = @import("vm_space.zig");

fn raw_print_char(c: u8) void {
    debug.hw_putchar(c);
}

fn raw_print_hex(val: usize) void {
    const chars = "0123456789abcdef";
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        raw_print_char(chars[(val >> @intCast(i * 4)) & 0xf]);
    }
}

extern fn hw_xint_init() void;

// Initialize hardware-dependent xint handling.
pub fn init() void {
    hw_xint_init();
}

pub const Type = enum {
    exception,
    interrupt,
};

pub const Severity = enum {
    fatal,
    non_fatal,
};

pub const Cause = riscv.Cause;

pub const IRQ = struct {
    severity: Severity,
    privilege_mode: riscv.PrivilegeMode,
    irq_type: Type,
    cause: Cause,
    pc: usize,
    sp: usize,
    val: usize,
};

const MAX_TRAP_LOGS = 100;

// Decode mcause and return an IRQ structure.
fn dispatch(context: *riscv.ThreadContext) IRQ {
    const mcause = riscv.readMcause();
    const mepc = riscv.readMepc();
    const sp = context[@intFromEnum(riscv.Register.sp)];

    const is_interrupt = (mcause & Cause.INTERRUPT_BIT) != 0;
    const cause_type: Type = if (is_interrupt) .interrupt else .exception;
    const mtval = riscv.readMtval();
    const cause = riscv.toCause(mcause);

    const irq = IRQ{
        .severity = if (cause_type == .interrupt) .non_fatal else .fatal,
        .privilege_mode = riscv.getPreviousPrivilege(),
        .irq_type = cause_type,
        .cause = cause,
        .pc = mepc,
        .sp = sp,
        .val = mtval,
    };

    // Explicitly handle unknown/unexpected traps with more verbosity
    if (irq.cause == .unknown) {
        debug.printf("!!! UNKNOWN TRAP on Core {}: mcause=0x{x} mtval=0x{x} mepc=0x{x} mstatus=0x{x}\n", .{
            pcore.this().cpu_core_id,
            mcause,
            mtval,
            riscv.readMepc(),
            riscv.readMstatus(),
        });
    }

    const cpu = pcore.this();
    if (cpu.trap_count < MAX_TRAP_LOGS) {
        // Always log non-page-fault exceptions, and only log page faults if we haven't hit the limit
        const is_page_fault = switch (irq.cause) {
            .guest_instruction_page_fault, .guest_load_page_fault, .guest_store_page_fault => true,
            else => false,
        };

        if (!is_page_fault or (cpu.trap_count % 10 == 0)) {
            debug.printf("Trapped: core={} mode={s} pc=0x{x} cause={s} (0x{x}) val=0x{x}\n", .{ cpu.cpu_core_id, @tagName(irq.privilege_mode), irq.pc, @tagName(irq.cause), @intFromEnum(irq.cause), irq.val });
            cpu.trap_count += 1;
        }
    }

    return irq;
}

// Our centralized high-level entry point for handling xints.
pub export fn xint_handler(context: *riscv.ThreadContext) void {
    if (builtin.is_test) return;

    const pcpu = pcore.this();
    const irq = dispatch(context);

    // Trap detail logging
    if (irq.privilege_mode != .machine) {
        const is_page_fault = switch (irq.cause) {
            .guest_instruction_page_fault, .guest_load_page_fault, .guest_store_page_fault => true,
            else => false,
        };

        if (!is_page_fault or (pcpu.trap_count % 10 == 0)) {
            debug.printf("Trapped: core={} mode={s} pc=0x{x} cause={s} (0x{x}) val=0x{x}\n", .{ pcpu.cpu_core_id, @tagName(irq.privilege_mode), irq.pc, @tagName(irq.cause), @intFromEnum(irq.cause), irq.val });
            
            // Log translation state for debugging isolation failures
            const hgatp = riscv.readHgatp();
            const hstatus = riscv.readHstatus();
            const vsatp = riscv.readVsatp();
            const htval = riscv.readHtval();
            const mstatus = riscv.readMstatus();
            debug.printf("[HV] State: hgatp=0x{x} hstatus=0x{x} vsatp=0x{x} mstatus=0x{x} htval=0x{x}\n", .{ hgatp, hstatus, vsatp, mstatus, htval });
            debug.printf("[HV] Virtualization: MPV={} GVA={} SPV={} SPVP={}\n", .{ 
                (mstatus & riscv.MSTATUS.MPV) != 0,
                (hstatus & riscv.HSTATUS.GVA) != 0,
                (hstatus & riscv.HSTATUS.SPV) != 0,
                (hstatus & riscv.HSTATUS.SPVP) != 0
            });
            
            pcpu.trap_count += 1;
        }
    }

    // Creative diagnostic: If it's an illegal instruction, try reading it from guest memory
    if (irq.cause == .illegal_instruction) {
        const instr = riscv.hlv_wu(irq.pc);
        debug.printf("GUEST BUG: Illegal instruction 0x{x} at 0x{x} (GPA)\n", .{ instr, irq.pc });
    }

    // If we're coming from a guest, save its context
    if (irq.privilege_mode != .machine) {
        if (pcpu.active_vcore) |vc_raw| {
            const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
            @memcpy(&vc.context, context);
            vc.machine.mepc = irq.pc;
            vc.machine.mstatus = riscv.readMstatus();
            if (riscv.hasHExtension()) {
                vc.machine.hvip = riscv.readHvip();
                const gs = &vc.guest_state;
                gs.vsstatus = riscv.readVsstatus();
                gs.vsie = riscv.readVsie();
                gs.vstvec = riscv.readVstvec();
                gs.vsscratch = riscv.readVsscratch();
                gs.vsepc = riscv.readVsepc();
                gs.vscause = riscv.readVscause();
                gs.vstval = riscv.readVstval();
                gs.vsatp = riscv.readVsatp();
            }
        }
    }

    switch (irq.irq_type) {
        .exception => handle_exception(irq, context),
        .interrupt => handle_interrupt(irq, context),
    }

    // Refresh context if we're running a vcore
    if (pcpu.active_vcore) |vc_raw| {
        const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
        @memcpy(context, &vc.context);
        pcore.contextSwitch(vc); 
        syncGuestStateToHardware(vc);
    }
}

// Synchronize the virtual core's architecture state to the physical hardware CSRs.
// This is required before returning to guest mode (mret) if the state has changed.
fn syncGuestStateToHardware(vc: *vcore.VirtualCore) void {
    const ms = &vc.machine;
    const gs = &vc.guest_state;

    riscv.writeMepc(ms.mepc);
    riscv.writeMstatus(ms.mstatus);

    if (riscv.hasHExtension()) {
        riscv.writeHstatus(ms.hstatus);
        riscv.writeHgatp(ms.hgatp);
        riscv.writeHvip(ms.hvip);
        riscv.writeHedeleg(ms.hedeleg);
        riscv.writeHideleg(ms.hideleg);

        // Sync VS-mode (Guest Supervisor) CSRs
        riscv.writeVsstatus(gs.vsstatus);
        riscv.writeVsie(gs.vsie);
        riscv.writeVstvec(gs.vstvec);
        riscv.writeVsscratch(gs.vsscratch);
        riscv.writeVsepc(gs.vsepc);
        riscv.writeVscause(gs.vscause);
        riscv.writeVstval(gs.vstval);
        riscv.writeVsatp(gs.vsatp);
    }
}

fn handle_exception(irq: IRQ, context: *riscv.ThreadContext) void {
    switch (irq.cause) {
        .supervisor_environment_call, .virtual_supervisor_environment_call => {
            // HS-mode or VS-mode ecall is an SBI call from the guest supervisor.
            const pcpu = pcore.this();
            if (pcpu.active_vcore) |vc_raw| {
                const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
                sbi.handle(vc, context);
            }
        },
        .guest_instruction_page_fault, .guest_load_page_fault, .guest_store_page_fault, .unknown => {
            // Some implementations might use 21 (unknown) for other guest faults.
            // Only handle as fault if it's within the known guest fault range or matches unknown.
            if (@intFromEnum(irq.cause) == 21 or irq.irq_type == .exception) {
                const pcpu = pcore.this();
                if (pcpu.active_vcore) |vc_raw| {
                    const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
                    // Try to get Guest Physical Address from mtval2 or htval
                    var gpa = riscv.readMtval2();
                    if (gpa == 0) gpa = riscv.readHtval();
                    if (gpa == 0) gpa = irq.val; // Fallback to mtval

                    const g = vc.getGuest();
                    g.space.handleFault(vc, gpa, @intFromEnum(irq.cause)) catch |err| {
                        debug.printf("Fault: GPA 0x{x} resolution failed: {s}\n", .{ gpa, @errorName(err) });
                        fatal_exception(irq);
                    };
                }
            }
        },
        else => {
            if (irq.irq_type == .exception) {
                const pcpu = pcore.this();
                if (pcpu.active_vcore) |vc_raw| {
                    const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
                    debug.printf("Guest Exception: core={} pc=0x{x} cause={s} (0x{x}) val=0x{x} - reflecting\n", .{ pcpu.cpu_core_id, irq.pc, @tagName(irq.cause), @intFromEnum(irq.cause), irq.val });
                    reflectExceptionToGuest(vc, irq) catch |err| {
                        debug.printf("Reflection failed: {s}\n", .{@errorName(err)});
                        fatal_exception(irq);
                    };
                } else {
                    fatal_exception(irq);
                }
            }
        },
    }
}

fn handle_interrupt(irq: IRQ, context: *riscv.ThreadContext) void {
    _ = context;
    const pcpu = pcore.this();

    switch (irq.cause) {
        .machine_timer => {
            if (pcpu.active_vcore) |vc_raw| {
                const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
                vc.machine.hvip |= riscv.HVIP.VSTIP;
            }
            // Clear hardware timer condition by setting it far into the future
            // until the guest (or hypervisor) sets a new one.
            riscv.setTimer(0xffffffffffffffff);
        },
        else => {
            debug.printf("Unhandled interrupt: 0x{x}\n", .{@intFromEnum(irq.cause)});
        },
    }
}

// Reflect an exception back to the guest supervisor
fn reflectExceptionToGuest(vc: *vcore.VirtualCore, irq: IRQ) !void {
    if (!riscv.hasHExtension()) return error.NoHExtension;

    const ms = &vc.machine;
    const gs = &vc.guest_state;

    // 1. Save fault context in VS-mode registers
    gs.vsepc = irq.pc;
    gs.vscause = @intFromEnum(irq.cause);
    gs.vstval = irq.val;

    // 2. Modify SSTATUS/VSSTATUS:
    // - Set SPP to previous privilege (0 for User, 1 for Supervisor)
    // - Set SPIE to current SIE
    // - Clear SIE
    const spp: usize = if (irq.privilege_mode == .supervisor) 1 else 0;
    const sie: usize = (gs.vsstatus & riscv.SSTATUS.SIE) >> 1;
    gs.vsstatus &= ~@as(usize, riscv.SSTATUS.SIE); // Clear SIE
    gs.vsstatus &= ~(@as(usize, 1) << riscv.SSTATUS.SPP_SHIFT); // Clear SPP
    gs.vsstatus |= (spp << riscv.SSTATUS.SPP_SHIFT);
    gs.vsstatus |= (sie << 5); // SPIE is bit 5 in sstatus

    // 2b. Ensure we enter VS-mode (Supervisor + Virtualization)
    ms.mstatus &= ~@as(usize, riscv.MSTATUS.MPP_MASK);
    ms.mstatus |= (@as(usize, 1) << riscv.MSTATUS.MPP_SHIFT);
    ms.mstatus |= riscv.MSTATUS.MPV;

    // Handle both direct and vectored modes
    const base = gs.vstvec & ~@as(usize, 0b11);
    const mode = gs.vstvec & 0b11;

    if (base == 0) {
        debug.printf("WARNING: Reflecting exception to NULL vstvec! This will likely crash the guest.\n", .{});
    }

    if (mode == 0) {
        ms.mepc = base;
    } else {
        // Vectored mode: base + 4 * cause
        ms.mepc = base + 4 * (@intFromEnum(irq.cause) & 0x7FFFFFFFFFFFFFFF);
    }

    // 4. Update hstatus.SPVP to reflect the privilege mode we're coming from
    ms.hstatus &= ~riscv.HSTATUS.SPVP;
    if (irq.privilege_mode == .supervisor) {
        ms.hstatus |= riscv.HSTATUS.SPVP;
    }
}

fn fatal_exception(irq: IRQ) void {
    debug.printf("\n*** FATAL EXCEPTION ***\n", .{});
    debug.printf("Cause: {s} (0x{x})\n", .{ @tagName(irq.cause), @intFromEnum(irq.cause) });
    debug.printf("Privilege: {s}\n", .{@tagName(irq.privilege_mode)});
    debug.printf("PC: 0x{x}, SP: 0x{x}\n", .{ irq.pc, irq.sp });
    debug.printf("HTVAL: 0x{x}, MTVAL: 0x{x}\n", .{ riscv.readHtval(), riscv.readMtval() });

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
        } else {
            // Should not happen if privilege_mode was not machine.
            debug.printf("No active vcore found for guest crash. Halting.\n", .{});
            while (true) {}
        }
    }
}
