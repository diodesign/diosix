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

    // Verbose SBI tracing for early boot diagnostics (disabled for production)
    if (false) {
        debug.printf("SBI: [ENTER] ext=0x{x} func={} a0=0x{x} a1=0x{x} a2=0x{x} from vcore {}\n", .{ extension, function, a0, a1, a2, vc.id });
    }

    switch (extension) {
        interface.EXT.BASE => handleBase(vc, context, function),
        interface.EXT.TIME => handleTimer(vc, context, a0),
        interface.EXT.LEGACY_SET_TIMER => handleTimer(vc, context, a0),
        interface.EXT.SRST => handleSystemReset(vc, context, function, a0, a1),
        interface.EXT.HSM => handleHSM(vc, context, function, a0, a1, a2),
        interface.EXT.DBCN => handleDebugConsole(vc, context, function, a0, a1),
        interface.EXT.LEGACY_CONSOLE_PUTCHAR => {
            const c: u8 = @truncate(a0);
            debug.putcharFromGuest(vc.guest_id, c);
            setResult(vc, context, SBI_SUCCESS, 0);
        },
        interface.EXT.LEGACY_CONSOLE_GETCHAR => {
            const char_val = @as(isize, debug.getchar(vc.guest_id));
            context[@intFromEnum(arch.Register.a0)] = @bitCast(char_val);
            vc.context[@intFromEnum(arch.Register.a0)] = @bitCast(char_val);
            // Do NOT modify a1 or other registers.
        },
        interface.EXT.LEGACY_CLEAR_IPI => {
            vc.machine.hvip &= ~@as(usize, riscv.HVIP.VSSIP);
            // Clear the CLINT MSIP register for the current physical CPU core
            const msip_ptr = @as(*volatile u32, @ptrFromInt(0x02000000 + 4 * riscv.getCPUContext().cpu_core_id));
            msip_ptr.* = 0;
            setResult(vc, context, SBI_SUCCESS, 0);
        },
        interface.EXT.LEGACY_SEND_IPI => {
            const g = vc.getGuest();
            var mask: usize = 0xffffffffffffffff;
            if (a0 != 0) {
                mask = @as(usize, riscv.hlv_d(a0));
            }
            var it_vcore = g.vcores.start;
            while (it_vcore) |node| {
                const target_vc = node.contents;
                if (target_vc.id != vc.id) {
                    if ((mask & (@as(usize, 1) << @intCast(target_vc.id))) != 0) {
                        target_vc.machine.hvip |= riscv.HVIP.VSSIP;
                        // Trigger physical IPI to wake up target physical core from WFI
                        const msip_ptr = @as(*volatile u32, @ptrFromInt(0x02000000 + 4 * target_vc.id));
                        msip_ptr.* = 1;
                    }
                }
                it_vcore = node.next;
            }
            setResult(vc, context, SBI_SUCCESS, 0);
        },
        interface.EXT.LEGACY_REMOTE_FENCE_I,
        interface.EXT.LEGACY_REMOTE_SFENCE_VMA,
        interface.EXT.LEGACY_REMOTE_SFENCE_VMA_ASID => {
            // For a single virtual CPU, there are no remote harts, so remote fences are a complete no-op.
            setResult(vc, context, SBI_SUCCESS, 0);
        },
        interface.EXT.LEGACY_SHUTDOWN => {
            debug.printf("SBI: Guest {} requested legacy shutdown\n", .{vc.guest_id});
            terminateOrRestart(vc.getGuest());
        },
        interface.EXT.DIOSIX => handleDiosix(vc, context, function),
        else => {
            debug.printf("SBI: Unknown extension 0x{x} func {} from guest {}\n", .{ extension, function, vc.id });
            setResult(vc, context, SBI_ERR_NOT_SUPPORTED, 0);
        },
    }

    // Trace result for diagnostics (disabled for production)
    if (false) {
        const res_err = context[@intFromEnum(riscv.Register.a0)];
        const res_val = context[@intFromEnum(riscv.Register.a1)];
        debug.printf("SBI: [EXIT]  ext=0x{x} err=0x{x} val=0x{x}\n", .{ extension, res_err, res_val });
    }

    // Move guest to the next instruction after ECALL
    vc.machine.mepc += 4;
}

fn handleBase(vc: *vcore.VirtualCore, context: *riscv.ThreadContext, function: usize) void {
    switch (function) {
        interface.BASE.GET_SPEC_VERSION => setResult(vc, context, SBI_SUCCESS, interface.SPEC_VERSION),
        interface.BASE.GET_IMPL_ID => setResult(vc, context, SBI_SUCCESS, interface.IMPL_ID),
        interface.BASE.GET_IMPL_VERSION => setResult(vc, context, SBI_SUCCESS, interface.IMPL_VERSION),
        interface.BASE.PROBE_EXTENSION => {
            const ext = context[@intFromEnum(arch.Register.a0)];
            const supported: usize = switch (ext) {
                interface.EXT.BASE,
                interface.EXT.TIME,
                interface.EXT.SRST,
                interface.EXT.HSM,
                interface.EXT.DBCN,
                interface.EXT.DIOSIX,
                interface.EXT.LEGACY_CONSOLE_PUTCHAR,
                interface.EXT.LEGACY_CLEAR_IPI,
                interface.EXT.LEGACY_SEND_IPI,
                interface.EXT.LEGACY_REMOTE_FENCE_I,
                interface.EXT.LEGACY_REMOTE_SFENCE_VMA,
                interface.EXT.LEGACY_REMOTE_SFENCE_VMA_ASID,
                interface.EXT.LEGACY_SHUTDOWN,
                => 1,
                else => 0,
            };
            setResult(vc, context, SBI_SUCCESS, supported);
        },
        interface.BASE.GET_MVENDORID => setResult(vc, context, SBI_SUCCESS, riscv.readMvendorid()),
        interface.BASE.GET_MARCHID => setResult(vc, context, SBI_SUCCESS, riscv.readMarchid()),
        interface.BASE.GET_MIMPID => setResult(vc, context, SBI_SUCCESS, riscv.readMimpid()),
        else => setResult(vc, context, SBI_ERR_NOT_SUPPORTED, 0),
    }
}

fn handleTimer(vc: *vcore.VirtualCore, context: *riscv.ThreadContext, stime: u64) void {
    // Set timer for guest.
    riscv.setTimer(stime);
    
    // Track that the guest has explicitly scheduled a timer interrupt.
    vc.timer_scheduled = true;
    vc.timer_target = stime;
    
    if (riscv.hasHExtension()) {
        vc.guest_state.vstimecmp = stime;
    }
    
    // Clear the guest's virtual timer interrupt pending bit now that they've scheduled a new event.
    vc.machine.hvip &= ~@as(usize, riscv.HVIP.VSTIP);

    setResult(vc, context, SBI_SUCCESS, 0);
}

fn handleSystemReset(vc: *vcore.VirtualCore, _: *riscv.ThreadContext, function: usize, reset_type: usize, reset_reason: usize) void {
    _ = function;
    _ = reset_reason;
    const g = vc.getGuest();
    debug.printf("SBI: System Reset (type {}) requested by guest {}\n", .{ reset_type, g.id });

    if (g.is_root) {
        // SRST reset_type: 0 = shutdown, 1 = cold reboot, 2 = warm reboot
        if (reset_type == 0) {
            debug.printf("Root VM requested shutdown. Powering off host.\n", .{});
            g.terminate();
            riscv.shutdown();
        } else {
            debug.printf("Root VM requested reboot. Restarting host.\n", .{});
            g.terminate();
            riscv.reboot();
        }
    } else {
        g.terminate();
    }
}

fn handleDiosix(vc: *vcore.VirtualCore, context: *riscv.ThreadContext, function: usize) void {
    switch (function) {
        interface.DIOSIX.EXIT => {
            const g = vc.getGuest();
            debug.printf("SBI: Diosix Exit requested by guest {}\n", .{g.id});
            terminateOrRestart(g);
        },
        interface.DIOSIX.YIELD => {
            scheduler.yield(vc);
        },
        interface.DIOSIX.FORK => {
            const g = vc.getGuest();
            const child = g.fork() catch |err| {
                debug.printf("SBI: Diosix Fork failed: {s}\n", .{@errorName(err)});
                setResult(vc, context, SBI_ERR_FAILED, 0);
                return;
            };

            // Register all child vcores with the scheduler.
            var it_vcore = child.vcores.start;
            while (it_vcore) |node| {
                scheduler.queue(node.contents);
                it_vcore = node.next;
            }
            setResult(vc, context, SBI_SUCCESS, child.id);
        },
        interface.DIOSIX.DROP_TRUST => {
            vc.getGuest().dropTrust();
            setResult(vc, context, SBI_SUCCESS, 0);
        },
        else => setResult(vc, context, SBI_ERR_NOT_SUPPORTED, 0),
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
                    setResult(vc, context, interface.ERR_ALREADY_AVAILABLE, 0);
                    return;
                }
                target_vc.machine.mepc = start_addr;
                target_vc.context[@intFromEnum(arch.Register.a0)] = target_hart;
                target_vc.context[@intFromEnum(arch.Register.a1)] = opaque_param;
                target_vc.state = .ready;

                // Ensure it's in the scheduler
                scheduler.queue(target_vc);

                // Trigger physical IPI to wake up physical core target_hart from WFI
                const msip_ptr = @as(*volatile u32, @ptrFromInt(0x02000000 + 4 * target_hart));
                msip_ptr.* = 1;

                setResult(vc, context, SBI_SUCCESS, 0);
                debug.printf("SBI: HSM Started vcore {} at 0x{x} for guest {}\n", .{ target_hart, start_addr, g.id });
            } else {
                setResult(vc, context, interface.ERR_INVALID_PARAM, 0);
            }
        },
        1 => { // HART_STOP (currently stubbed)
            vc.state = .stopped;
            setResult(vc, context, SBI_SUCCESS, 0);
        },
        2 => { // HART_GET_STATUS
            const target_hart = a0;
            if (g.findVcore(target_hart)) |target_vc| {
                const status: usize = switch (target_vc.state) {
                    .running => 0, // STARTED
                    .ready => 0, // Also consider STARTED or START_PENDING
                    .stopped => 1, // STOPPED
                };
                setResult(vc, context, SBI_SUCCESS, status);
            } else {
                setResult(vc, context, interface.ERR_INVALID_PARAM, 0);
            }
        },
        else => setResult(vc, context, SBI_ERR_NOT_SUPPORTED, 0),
    }
}

fn handleDebugConsole(vc: *vcore.VirtualCore, context: *riscv.ThreadContext, function: usize, a0: usize, a1: usize) void {
    const g = vc.getGuest();
    switch (function) {
        interface.DBCN.CONSOLE_WRITE => {
            const num_bytes = a0;
            const gpa = a1; // base_addr_lo
            var written: usize = 0;
            var buf: [256]u8 = undefined;
            var buf_idx: usize = 0;

            while (written < num_bytes) {
                const target_gpa = gpa + written;
                const hpa = g.space.translateGPA(target_gpa) catch blk: {
                    if (buf_idx > 0) {
                        debug.writeFromGuest(vc.guest_id, buf[0..buf_idx]);
                        buf_idx = 0;
                    }
                    // Try to resolve demand paging in software for the SBI buffer page
                    g.space.handleFault(vc, target_gpa, 21) catch { // 21 is guest load page fault
                        setResult(vc, context, SBI_ERR_INVALID_ADDRESS, written);
                        return;
                    };
                    break :blk g.space.translateGPA(target_gpa) catch {
                        setResult(vc, context, SBI_ERR_INVALID_ADDRESS, written);
                        return;
                    };
                };
                buf[buf_idx] = @as(*u8, @ptrFromInt(hpa)).*;
                buf_idx += 1;
                written += 1;

                if (buf_idx == buf.len) {
                    debug.writeFromGuest(vc.guest_id, buf[0..buf_idx]);
                    buf_idx = 0;
                }
            }
            if (buf_idx > 0) {
                debug.writeFromGuest(vc.guest_id, buf[0..buf_idx]);
            }
            setResult(vc, context, SBI_SUCCESS, written);
        },
        interface.DBCN.CONSOLE_READ => {
            const num_bytes = a0;
            const gpa = a1; // base_addr_lo
            var read: usize = 0;
            while (read < num_bytes) : (read += 1) {
                const c = debug.getchar(vc.guest_id);
                if (c < 0) break;
                const target_gpa = gpa + read;
                const hpa = g.space.translateGPA(target_gpa) catch blk: {
                    // Try to resolve demand paging in software for the SBI buffer page
                    g.space.handleFault(vc, target_gpa, 23) catch { // 23 is guest store page fault
                        setResult(vc, context, SBI_ERR_INVALID_ADDRESS, read);
                        return;
                    };
                    break :blk g.space.translateGPA(target_gpa) catch {
                        setResult(vc, context, SBI_ERR_INVALID_ADDRESS, read);
                        return;
                    };
                };
                @as(*u8, @ptrFromInt(hpa)).* = @truncate(@as(u16, @bitCast(c)));
            }
            setResult(vc, context, SBI_SUCCESS, read);
        },
        interface.DBCN.CONSOLE_WRITE_BYTE => {
            debug.putcharFromGuest(vc.guest_id, @truncate(a0));
            setResult(vc, context, SBI_SUCCESS, 0);
        },
        else => setResult(vc, context, SBI_ERR_NOT_SUPPORTED, 0),
    }
}

fn setResult(vc: *vcore.VirtualCore, context: *riscv.ThreadContext, err: isize, val: usize) void {
    context[@intFromEnum(arch.Register.a0)] = @bitCast(err); // A0 = error code.
    context[@intFromEnum(arch.Register.a1)] = val; // A1 = value.
    vc.context[@intFromEnum(arch.Register.a0)] = @bitCast(err);
    vc.context[@intFromEnum(arch.Register.a1)] = val;
}

/// Terminate a guest. If the guest is the Root VM, the architecture requires
/// that the host is restarted because the system is no longer manageable.
fn terminateOrRestart(g: *guest.Guest) void {
    g.terminate();
    if (g.is_root) {
        debug.printf("Root VM terminated. Rebooting host as per architecture policy.\n", .{});
        riscv.reboot();
    }
}
