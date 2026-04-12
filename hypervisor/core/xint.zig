// High-level exception and interrupt (xint) handling on RISC-V
//
// Copyright (c) 2024, 2025, 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const main = @import("main.zig");
const builtin = @import("builtin");
const debug = @import("debug.zig");
const riscv = @import("riscv.zig");
const pcore = @import("pcore.zig");
const vcore = @import("vcore.zig");
const hypercall = @import("hypercall.zig");
const vm_space = @import("vm_space.zig");

extern fn hw_xint_init() void;

// initialize hardware-dependent xint handling
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

pub const Cause = enum(usize) {
    // Exceptions
    instruction_alignment = 0,
    instruction_access = 1,
    illegal_instruction = 2,
    breakpoint = 3,
    load_alignment = 4,
    load_access = 5,
    store_alignment = 6,
    store_access = 7,
    user_environment_call = 8,
    supervisor_environment_call = 9,
    machine_environment_call = 11,
    instruction_page_fault = 12,
    load_page_fault = 13,
    store_page_fault = 15,
    guest_instruction_page_fault = 20,
    guest_load_page_fault = 22,
    guest_store_page_fault = 23,

    // Interrupts (marker bit set below)
    user_swi = (1 << 63) | 0,
    supervisor_swi = (1 << 63) | 1,
    machine_swi = (1 << 63) | 3,
    user_timer = (1 << 63) | 4,
    supervisor_timer = (1 << 63) | 5,
    machine_timer = (1 << 63) | 7,
    user_interrupt = (1 << 63) | 8,
    supervisor_interrupt = (1 << 63) | 9,
    machine_interrupt = (1 << 63) | 11,

    unknown = 0xffffffffffffffff,
};

pub const IRQ = struct {
    severity: Severity,
    privilege_mode: riscv.PrivilegeMode,
    irq_type: Type,
    cause: Cause,
    pc: usize,
    sp: usize,
};

// decode mcause and return an IRQ structure
fn dispatch(context: *riscv.ThreadContext) IRQ {
    const mcause = riscv.readMcause();
    const mepc = riscv.readMepc();
    const sp = context[2]; // x2 is sp

    const is_interrupt = (mcause >> 63) != 0;
    const cause_type: Type = if (is_interrupt) .interrupt else .exception;

    const cause: Cause = @enumFromInt(mcause);

    const severity: Severity = switch (cause_type) {
        .interrupt => .non_fatal,
        .exception => switch (cause) {
            .user_environment_call, .supervisor_environment_call, .machine_environment_call => .non_fatal,
            else => .fatal,
        },
    };

    return IRQ{
        .severity = severity,
        .privilege_mode = riscv.getPreviousPrivilege(),
        .irq_type = cause_type,
        .cause = cause,
        .pc = mepc,
        .sp = sp,
    };
}

// our centralized high-level entry point for handling xints
pub export fn xint_handler(context: *riscv.ThreadContext) void {
    if (builtin.is_test) return;

    const irq = dispatch(context);

    switch (irq.irq_type) {
        .exception => handle_exception(irq, context),
        .interrupt => handle_interrupt(irq, context),
    }
}

fn handle_exception(irq: IRQ, context: *riscv.ThreadContext) void {
    switch (irq.cause) {
        .supervisor_environment_call => {
            // HS-mode ecall is a hypercall from the guest supervisor
            const pcpu = pcore.this();
            if (pcpu.active_vcore) |vc_raw| {
                const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
                hypercall.handle(vc, context);
            }
            riscv.writeMepc(irq.pc + 4);
        },
        .guest_instruction_page_fault, .guest_load_page_fault, .guest_store_page_fault => {
            const pcpu = pcore.this();
            if (pcpu.active_vcore) |vc_raw| {
                const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
                const gpa = riscv.readHtval(); // Guest physical address that faulted
                const g = vc.getGuest();
                g.space.handleFault(vc, gpa, @intFromEnum(irq.cause)) catch |err| {
                    debug.printf("Fault: GPA 0x{x} resolution failed: {s}\n", .{gpa, @errorName(err)});
                    fatal_exception(irq);
                };
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
    // clear/acknowledge the interrupt condition
    // TODO: implement acknowledge()
    debug.printf("Unhandled interrupt: 0x{x}\n", .{@intFromEnum(irq.cause)});
}

fn fatal_exception(irq: IRQ) void {
    debug.printf("\n*** FATAL EXCEPTION ***\n", .{});
    debug.printf("Cause: {s} (0x{x})\n", .{ @tagName(irq.cause), @intFromEnum(irq.cause) });
    debug.printf("Privilege: {s}\n", .{@tagName(irq.privilege_mode)});
    debug.printf("PC: 0x{x}, SP: 0x{x}\n", .{ irq.pc, irq.sp });

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
            // Should not happen if privilege_mode was not machine
            debug.printf("No active vcore found for guest crash. Halting.\n", .{});
            while (true) {}
        }
    }
}
