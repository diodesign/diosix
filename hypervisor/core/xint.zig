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

// Decode mcause and return an IRQ structure.
fn dispatch(context: *riscv.ThreadContext) IRQ {
    const mcause = riscv.readMcause();
    const mepc = riscv.readMepc();
    const sp = context[@intFromEnum(riscv.Register.sp)];

    const is_interrupt = (mcause & Cause.INTERRUPT_BIT) != 0;
    const cause_type: Type = if (is_interrupt) .interrupt else .exception;
    const mtval = riscv.readMtval();
    const cause = riscv.toCause(mcause);

    return IRQ{
        .severity = if (cause_type == .interrupt) .non_fatal else .fatal,
        .privilege_mode = riscv.getPreviousPrivilege(),
        .irq_type = cause_type,
        .cause = cause,
        .pc = mepc,
        .sp = sp,
        .val = mtval,
    };
}

// Our centralized high-level entry point for handling xints.
pub export fn xint_handler(context: *riscv.ThreadContext) void {
    if (builtin.is_test) return;

    const pcpu = pcore.this();
    const irq = dispatch(context);

    // Log every trap for debugging purposes
    // debug.printf("Trapped: core={} mode={s} pc=0x{x} cause=0x{x} val=0x{x}\n", .{
    //     pcpu.cpu_core_id, 
    //     @tagName(irq.privilege_mode), 
    //     irq.pc, 
    //     @intFromEnum(irq.cause), 
    //     irq.val
    // });

    // If we're coming from a guest, save its context
    if (irq.privilege_mode != .machine) {
        if (pcpu.active_vcore) |vc_raw| {
            const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
            @memcpy(&vc.context, context);
            vc.mepc = irq.pc;
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
        pcore.contextSwitch(vc); // This handles CSRs including mepc
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
                vc.mepc = irq.pc + 4; // Advance guest PC past ecall
            }
        },
        .guest_instruction_page_fault, .guest_load_page_fault, .guest_store_page_fault, .unknown => {
            // Some implementations might use 21 (unknown) for other guest faults.
            // Only handle as fault if it's within the known guest fault range or matches unknown.
            if (@intFromEnum(irq.cause) == 21 or irq.irq_type == .exception) {
            const pcpu = pcore.this();
            if (pcpu.active_vcore) |vc_raw| {
                const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
                const htval = riscv.readHtval();
                const gpa = if (htval == 0) irq.val else htval; // Fallback to mtval if htval is zero
                const g = vc.getGuest();
                g.space.handleFault(vc, gpa, @intFromEnum(irq.cause)) catch |err| {
                    debug.printf("Fault: GPA 0x{x} resolution failed: {s}\n", .{gpa, @errorName(err)});
                    fatal_exception(irq);
                };
            }
            }
        },
        else => {
            if (irq.severity == .fatal) {
                fatal_exception(irq);
            }
        },
    }
}

fn handle_interrupt(irq: IRQ, context: *riscv.ThreadContext) void {
    _ = context;
    // Clear/acknowledge the interrupt condition.
    // TODO: Implement acknowledge().
    debug.printf("Unhandled interrupt: 0x{x}\n", .{@intFromEnum(irq.cause)});
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
