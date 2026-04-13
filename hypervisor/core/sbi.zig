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
    const a2 = context[@intFromEnum(arch.Register.a2)];

    // const a3 = context[@intFromEnum(arch.Register.a3)];
    // const a4 = context[@intFromEnum(arch.Register.a4)];
    // const a5 = context[@intFromEnum(arch.Register.a5)];

    // Verbose SBI tracing for early boot diagnostics
    debug.printf("SBI: [ENTER] ext=0x{x} func={} a0=0x{x} a1=0x{x} a2=0x{x} from vcore {}\n", .{ extension, function, a0, a1, a2, vc.id });

    switch (extension) {
        interface.EXT.BASE => handleBase(vc, context, function),
        interface.EXT.TIME, interface.EXT.LEGACY_SET_TIMER => handleTimer(vc, context, function, a0),
        interface.EXT.SRST => handleSystemReset(vc, context, function, a0, a1),
        interface.EXT.HSM => handleHSM(vc, context, function, a0, a1, a2),
        interface.EXT.DBCN => handleDebugConsole(vc, context, function, a0, a1),
        interface.EXT.LEGACY_CONSOLE_PUTCHAR => {
            const c: u8 = @truncate(a0);
            debug.putcharFromGuest(vc.guest_id, c);
            setResult(context, SBI_SUCCESS, 0);
        },
        interface.EXT.LEGACY_CONSOLE_GETCHAR => {
            setResult(context, @bitCast(@as(isize, debug.getchar(vc.guest_id))), 0);
        },
        interface.EXT.LEGACY_SHUTDOWN => {
            debug.printf("SBI: Guest {} requested shutdown\n", .{vc.guest_id});
            vc.getGuest().terminate();
        },
        interface.EXT.DIOSIX => handleDiosix(vc, context, function),
        else => {
            debug.printf("SBI: Unknown extension 0x{x} func {} from guest {}\n", .{ extension, function, vc.id });
            setResult(context, SBI_ERR_NOT_SUPPORTED, 0);
        },
    }

    // Trace result for diagnostics
    const res_err = context[@intFromEnum(riscv.Register.a0)];
    const res_val = context[@intFromEnum(riscv.Register.a1)];
    debug.printf("SBI: [EXIT]  ext=0x{x} err=0x{x} val=0x{x}\n", .{ extension, res_err, res_val });

    // Move guest to the next instruction after ECALL
    vc.machine.mepc += 4;
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
                interface.EXT.TIME,
                interface.EXT.SRST,
                interface.EXT.DBCN,
                interface.EXT.DIOSIX,
                interface.EXT.LEGACY_CONSOLE_PUTCHAR,
                interface.EXT.LEGACY_SHUTDOWN,
                => 1,
                else => 0,
            };
            setResult(context, SBI_SUCCESS, supported);
        },
        interface.BASE.GET_MVENDORID => setResult(context, SBI_SUCCESS, riscv.readMvendorid()),
        interface.BASE.GET_MARCHID => setResult(context, SBI_SUCCESS, riscv.readMarchid()),
        interface.BASE.GET_MIMPID => setResult(context, SBI_SUCCESS, riscv.readMimpid()),
        else => setResult(context, SBI_ERR_NOT_SUPPORTED, 0),
    }
}

fn handleTimer(vc: *vcore.VirtualCore, context: *riscv.ThreadContext, function: usize, stime: u64) void {
    _ = function;
    debug.printf("SBI: Timer set to 0x{x} for guest {}\n", .{ stime, vc.guest_id });
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

fn handleHSM(vc: *vcore.VirtualCore, context: *riscv.ThreadContext, function: usize, a0: usize, a1: usize, a2: usize) void {
    const g = vc.getGuest();
    switch (function) {
        0 => { // HART_START
            const target_hart = a0;
            const start_addr = a1;
            const opaque_param = a2;

            if (g.findVcore(target_hart)) |target_vc| {
                if (target_vc.state != .stopped) {
                    setResult(context, interface.ERR_ALREADY_AVAILABLE, 0);
                    return;
                }
                target_vc.machine.mepc = start_addr;
                target_vc.context[@intFromEnum(arch.Register.a0)] = target_hart;
                target_vc.context[@intFromEnum(arch.Register.a1)] = opaque_param;
                target_vc.state = .ready;

                // Ensure it's in the scheduler
                scheduler.queue(target_vc);

                setResult(context, SBI_SUCCESS, 0);
                debug.printf("SBI: HSM Started vcore {} at 0x{x} for guest {}\n", .{ target_hart, start_addr, g.id });
            } else {
                setResult(context, interface.ERR_INVALID_PARAM, 0);
            }
        },
        1 => { // HART_STOP (currently stubbed)
            vc.state = .stopped;
            setResult(context, SBI_SUCCESS, 0);
        },
        2 => { // HART_GET_STATUS
            const target_hart = a0;
            if (g.findVcore(target_hart)) |target_vc| {
                const status: usize = switch (target_vc.state) {
                    .running => 0, // STARTED
                    .ready => 0, // Also consider STARTED or START_PENDING
                    .stopped => 1, // STOPPED
                };
                setResult(context, SBI_SUCCESS, status);
            } else {
                setResult(context, interface.ERR_INVALID_PARAM, 0);
            }
        },
        else => setResult(context, SBI_ERR_NOT_SUPPORTED, 0),
    }
}

fn handleDebugConsole(vc: *vcore.VirtualCore, context: *riscv.ThreadContext, function: usize, a0: usize, a1: usize) void {
    const g = vc.getGuest();
    switch (function) {
        interface.DBCN.CONSOLE_WRITE => {
            const num_bytes = a0;
            const gpa = a1; // base_addr_lo
            var written: usize = 0;
            while (written < num_bytes) : (written += 1) {
                const hpa = g.space.translateGPA(gpa + written) catch {
                    setResult(context, SBI_ERR_INVALID_ADDRESS, written);
                    return;
                };
                const c = @as(*u8, @ptrFromInt(hpa)).*;
                debug.putcharFromGuest(vc.guest_id, c);
                // Trace character output for diagnostics (uncomment for verbose character logging)
                // debug.printf("{c}", .{c});
            }
            setResult(context, SBI_SUCCESS, written);
        },
        interface.DBCN.CONSOLE_READ => {
            const num_bytes = a0;
            const gpa = a1; // base_addr_lo
            var read: usize = 0;
            while (read < num_bytes) : (read += 1) {
                const c = debug.getchar(vc.guest_id);
                if (c < 0) break;
                const hpa = g.space.translateGPA(gpa + read) catch {
                    setResult(context, SBI_ERR_INVALID_ADDRESS, read);
                    return;
                };
                @as(*u8, @ptrFromInt(hpa)).* = @truncate(@as(u16, @bitCast(c)));
            }
            setResult(context, SBI_SUCCESS, read);
        },
        interface.DBCN.CONSOLE_WRITE_BYTE => {
            debug.putcharFromGuest(vc.guest_id, @truncate(a0));
            setResult(context, SBI_SUCCESS, 0);
        },
        else => setResult(context, SBI_ERR_NOT_SUPPORTED, 0),
    }
}

fn setResult(context: *riscv.ThreadContext, err: isize, val: usize) void {
    context[@intFromEnum(arch.Register.a0)] = @bitCast(err); // A0 = error code.
    context[@intFromEnum(arch.Register.a1)] = val; // A1 = value.
}
