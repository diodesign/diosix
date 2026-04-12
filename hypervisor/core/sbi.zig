// RISC-V Supervisor Binary Interface (SBI) implementation.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("riscv.zig");
const vcore = @import("vcore.zig");
const guest = @import("guest.zig");
const debug = @import("debug.zig");
const scheduler = @import("scheduler.zig");
const interface = @import("interface").sbi;
const arch = @import("interface").riscv;

// SBI Error Codes.
pub const SBI_SUCCESS = interface.SUCCESS;
pub const SBI_ERR_FAILED = interface.ERR_FAILED;
pub const SBI_ERR_NOT_SUPPORTED = interface.ERR_NOT_SUPPORTED;
pub const SBI_ERR_INVALID_PARAM = interface.ERR_INVALID_PARAM;
pub const SBI_ERR_DENIED = interface.ERR_DENIED;
pub const SBI_ERR_INVALID_ADDRESS = interface.ERR_INVALID_ADDRESS;
pub const SBI_ERR_ALREADY_AVAILABLE = interface.ERR_ALREADY_AVAILABLE;

pub fn handle(vc: *vcore.VirtualCore, context: *riscv.ThreadContext) void {
    const extension = context[@intFromEnum(arch.Register.a7)];
    const function = context[@intFromEnum(arch.Register.a6)];
    const a0 = context[@intFromEnum(arch.Register.a0)];
    const a1 = context[@intFromEnum(arch.Register.a1)];

    switch (extension) {
        interface.EXT.BASE => handleBase(vc, context, function),
        interface.EXT.TIMER, interface.EXT.LEGACY_SET_TIMER => handleTimer(vc, context, function, a0),
        interface.EXT.SRST => handleSystemReset(vc, context, function, a0, a1),
        interface.EXT.LEGACY_CONSOLE_PUTCHAR => {
            debug.putchar(@truncate(a0));
            setResult(context, SBI_SUCCESS, 0);
        },
        interface.EXT.LEGACY_SHUTDOWN => {
            debug.printf("SBI: Guest {} requested shutdown\n", .{vc.guest_id});
            vc.getGuest().terminate();
        },
        interface.EXT.DIOSIX => handleDiosix(vc, context, function),
        else => {
            debug.printf("SBI: Unknown extension 0x{x} func {} from guest {}\n", .{ extension, function, vc.guest_id });
            setResult(context, SBI_ERR_NOT_SUPPORTED, 0);
        },
    }
}

fn handleBase(vc: *vcore.VirtualCore, context: *riscv.ThreadContext, function: usize) void {
    _ = vc;
    switch (function) {
        interface.BASE.GET_SPEC_VERSION => setResult(context, SBI_SUCCESS, interface.SPEC_VERSION),
        interface.BASE.GET_IMPL_ID => setResult(context, SBI_SUCCESS, interface.IMPL_ID),
        interface.BASE.GET_IMPL_VERSION => setResult(context, SBI_SUCCESS, interface.IMPL_VERSION),
        interface.BASE.PROBE_EXTENSION => {
            const ext = context[@intFromEnum(arch.Register.a0)];
            const supported: usize = switch (ext) {
                interface.EXT.BASE,
                interface.EXT.TIMER,
                interface.EXT.SRST,
                interface.EXT.DIOSIX,
                interface.EXT.LEGACY_CONSOLE_PUTCHAR,
                interface.EXT.LEGACY_SHUTDOWN,
                => 1,
                else => 0,
            };
            setResult(context, SBI_SUCCESS, supported);
        },
        else => setResult(context, SBI_ERR_NOT_SUPPORTED, 0),
    }
}

fn handleTimer(vc: *vcore.VirtualCore, context: *riscv.ThreadContext, function: usize, stime: u64) void {
    _ = vc;
    _ = function;
    // Set timer for guest.
    riscv.setTimer(stime);
    setResult(context, SBI_SUCCESS, 0);
}

fn handleSystemReset(vc: *vcore.VirtualCore, _: *riscv.ThreadContext, function: usize, reset_type: usize, reset_reason: usize) void {
    _ = function;
    _ = reset_reason;
    debug.printf("SBI: System Reset (type {}) requested by guest {}\n", .{ reset_type, vc.guest_id });
    vc.getGuest().terminate();
}

fn handleDiosix(vc: *vcore.VirtualCore, context: *riscv.ThreadContext, function: usize) void {
    switch (function) {
        interface.DIOSIX.EXIT => {
            debug.printf("SBI: Diosix Exit requested by guest {}\n", .{vc.guest_id});
            vc.getGuest().terminate();
        },
        interface.DIOSIX.YIELD => {
            scheduler.yield(vc);
        },
        interface.DIOSIX.FORK => {
            const g = vc.getGuest();
            const child = g.fork() catch |err| {
                debug.printf("SBI: Diosix Fork failed: {s}\n", .{@errorName(err)});
                setResult(context, SBI_ERR_FAILED, 0);
                return;
            };
            
            // Register all child vcores with the scheduler.
            var it_vcore = child.vcores.start;
            while (it_vcore) |node| {
                scheduler.queue(node.contents);
                it_vcore = node.next;
            }
            setResult(context, SBI_SUCCESS, child.id);
        },
        interface.DIOSIX.DROP_TRUST => {
            vc.getGuest().dropTrust();
            setResult(context, SBI_SUCCESS, 0);
        },
        else => setResult(context, SBI_ERR_NOT_SUPPORTED, 0),
    }
}

fn setResult(context: *riscv.ThreadContext, err: isize, val: usize) void {
    context[@intFromEnum(arch.Register.a0)] = @bitCast(err); // A0 = error code.
    context[@intFromEnum(arch.Register.a1)] = val;           // A1 = value.
}
