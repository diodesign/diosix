// RISC-V Supervisor Binary Interface (SBI) implementation.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("../riscv64/riscv.zig");
const vcore = @import("../../vcore.zig");
const guest = @import("../../guest.zig");
const debug = @import("../../debug.zig");
const scheduler = @import("../../scheduler.zig");
const pcore = @import("../../pcore.zig");
const interface = @import("interface").sbi;
const arch = @import("interface").riscv;
const config = @import("config");
const rv32 = @import("riscv32.zig");
const glue = @import("../../unicorn.zig");

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

    switch (extension) {
        interface.EXT.BASE => handleBase(vc, context, function),
        interface.EXT.TIME => {
            // RV32 SBI: 64-bit stime split across a0 (low) and a1 (high).
            // RV64 SBI: a0 holds the full 64-bit value; a1 is unused.
            const stime = if (vc.exec_path == .emulated) a0 | (@as(u64, a1) << 32) else a0;
            handleTimer(vc, context, stime);
        },
        interface.EXT.LEGACY_SET_TIMER => {
            const stime = if (vc.exec_path == .emulated) a0 | (@as(u64, a1) << 32) else a0;
            handleTimer(vc, context, stime);
        },
        interface.EXT.SRST => handleSystemReset(vc, context, function, a0, a1),
        interface.EXT.HSM => handleHSM(vc, context, function, a0, a1, a2),
        interface.EXT.DBCN => handleDebugConsole(vc, context, function, a0, a1),
        interface.EXT.IPI => handleIPI(vc, context, a0, a1),
        interface.EXT.RFENCE => {
            // Execute local TLB flushes. The guest is requesting remote fences
            // across virtual harts. For correctness, we flush locally and rely on
            // the fact that when a vcore is scheduled onto a different physical core,
            // the context switch in hw_run_vcore already performs hfence.gvma.
            riscv.hfenceGvma();
            riscv.getCPUContext().gstage_dirty = false; // TLB already flushed
            setResult(vc, context, SBI_SUCCESS, 0);
        },
        interface.EXT.LEGACY_CONSOLE_PUTCHAR => {
            const c: u8 = @truncate(a0);
            debug.putcharFromGuest(vc.guest_id, c);
            setResult(vc, context, SBI_SUCCESS, 0);
        },
        interface.EXT.LEGACY_CONSOLE_GETCHAR => {
            const char_val = @as(isize, debug.getchar(vc.guest_id));
            context[@intFromEnum(arch.Register.a0)] = @bitCast(char_val);
            vc.getNativeContext()[@intFromEnum(arch.Register.a0)] = @bitCast(char_val);
            // Do NOT modify a1 or other registers.
        },
        interface.EXT.LEGACY_CLEAR_IPI => {
            if (vc.exec_path == .emulated) {
                var mip: u64 = 0;
                _ = glue.uc_reg_read(vc.exec_path.emulated.uc, rv32.UC_REG_MIP, &mip);
                mip &= ~(@as(u64, 1) << 1); // clear SSIP

                // Temporarily elevate to M-mode so the write to MIP succeeds
                var current_priv: u32 = 0;
                _ = glue.uc_reg_read(vc.exec_path.emulated.uc, rv32.UC_REG_PRIV, &current_priv);
                var m_priv: u32 = 3; // PRV_M
                _ = glue.uc_reg_write(vc.exec_path.emulated.uc, rv32.UC_REG_PRIV, &m_priv);

                _ = glue.uc_reg_write(vc.exec_path.emulated.uc, rv32.UC_REG_MIP, &mip);

                // Restore previous privilege mode
                _ = glue.uc_reg_write(vc.exec_path.emulated.uc, rv32.UC_REG_PRIV, &current_priv);
            } else {
                vc.getNativeMachine().hvip &= ~@as(usize, riscv.HVIP.VSSIP);
                // Clear the CLINT MSIP register for the current physical CPU core
                if (riscv.CLINT.msip(riscv.getCPUContext().hardware_hart_id)) |ptr| {
                    ptr.* = 0;
                }
            }
            _ = @atomicRmw(bool, &vc.pending_ipi, .Xchg, false, .acq_rel);
            setResult(vc, context, SBI_SUCCESS, 0);
        },
        interface.EXT.LEGACY_SEND_IPI => {
            // SBI v0.1: hart_mask is ALWAYS a virtual address pointing to the bit-vector, even on RV64
            const mask_ptr = context[@intFromEnum(arch.Register.a0)];
            var hart_mask: usize = 0;
            if (mask_ptr != 0) {
                // Diosix is 64-bit, we can just read 64 bits from the guest's virtual address
                hart_mask = @as(usize, @bitCast(riscv.hlv_d(mask_ptr)));
            } else {
                // If mask_ptr is NULL, it usually means broadcast (or all 1s).
                // But typically SBI 0.1 callers pass a valid pointer.
                hart_mask = 0;
            }
            const g = vc.getGuest();
            for (0..guest.Guest.max_vcores) |vid| {
                if ((hart_mask & (@as(usize, 1) << @intCast(vid))) != 0) {
                    if (g.vcore_lookup[vid]) |target_vc| {
                        _ = @atomicRmw(bool, &target_vc.pending_ipi, .Xchg, true, .acq_rel);
                        if (target_vc.blocked_on_cpu) |home_cpu| {
                            if (home_cpu == pcore.this().cpu_core_id) {
                                if (target_vc.tryWake()) {
                                    pcore.this().blocked_queue.remove(&target_vc.blocked_node);
                                    target_vc.blocked_on_cpu = null;
                                    scheduler.queue(target_vc);
                                }
                            } else {
                                if (home_cpu < riscv.cpu_to_hart_map.len) {
                                    if (riscv.CLINT.msip(riscv.cpu_to_hart_map[home_cpu])) |ptr| {
                                        ptr.* = 1;
                                    }
                                }
                            }
                        } else {
                            if (target_vc.running_on_cpu) |target_cpu| {
                                if (target_cpu != pcore.this().cpu_core_id and target_cpu < riscv.cpu_to_hart_map.len) {
                                    if (riscv.CLINT.msip(riscv.cpu_to_hart_map[target_cpu])) |ptr| {
                                        ptr.* = 1;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            setResult(vc, context, SBI_SUCCESS, 0);
        },
        interface.EXT.LEGACY_REMOTE_FENCE_I, interface.EXT.LEGACY_REMOTE_SFENCE_VMA, interface.EXT.LEGACY_REMOTE_SFENCE_VMA_ASID => {
            riscv.hfenceGvma();
            riscv.getCPUContext().gstage_dirty = false;
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

    // Move guest to the next instruction after ECALL
    if (vc.exec_path == .native) {
        vc.getNativeMachine().mepc += 4;
    }
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
                interface.EXT.IPI,
                interface.EXT.RFENCE,
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

fn handleIPI(vc: *vcore.VirtualCore, context: *riscv.ThreadContext, hart_mask: usize, hart_mask_base: usize) void {
    const g = vc.getGuest();

    if (hart_mask_base == 0xffffffffffffffff) {
        // Broadcast to all valid vcores in the guest
        for (0..guest.Guest.max_vcores) |vid| {
            if (g.vcore_lookup[vid]) |target_vc| {
                    _ = @atomicRmw(bool, &target_vc.pending_ipi, .Xchg, true, .acq_rel);
                if (target_vc.blocked_on_cpu) |home_cpu| {
                    if (home_cpu == pcore.this().cpu_core_id) {
                        if (target_vc.tryWake()) {
                            pcore.this().blocked_queue.remove(&target_vc.blocked_node);
                            target_vc.blocked_on_cpu = null;
                            scheduler.queue(target_vc);
                        }
                    } else {
                        if (home_cpu < riscv.cpu_to_hart_map.len) {
                            if (riscv.CLINT.msip(riscv.cpu_to_hart_map[home_cpu])) |ptr| {
                                ptr.* = 1;
                            }
                        }
                    }
                } else {
                    if (target_vc.running_on_cpu) |target_cpu| {
                        if (target_cpu != pcore.this().cpu_core_id and target_cpu < riscv.cpu_to_hart_map.len) {
                            if (riscv.CLINT.msip(riscv.cpu_to_hart_map[target_cpu])) |ptr| {
                                ptr.* = 1;
                            }
                        }
                    }
                }
            }
        }
    } else {
        // Targeted send
        for (0..@bitSizeOf(usize)) |bit_pos| {
            if ((hart_mask & (@as(usize, 1) << @intCast(bit_pos))) != 0) {
                const hart_id = hart_mask_base + bit_pos;
                if (hart_id < guest.Guest.max_vcores) {
                    if (g.vcore_lookup[hart_id]) |target_vc| {
                            _ = @atomicRmw(bool, &target_vc.pending_ipi, .Xchg, true, .acq_rel);
                        if (target_vc.blocked_on_cpu) |home_cpu| {
                            if (home_cpu == pcore.this().cpu_core_id) {
                                if (target_vc.tryWake()) {
                                    pcore.this().blocked_queue.remove(&target_vc.blocked_node);
                                    target_vc.blocked_on_cpu = null;
                                    scheduler.queue(target_vc);
                                }
                            } else {
                                if (home_cpu < riscv.cpu_to_hart_map.len) {
                                    if (riscv.CLINT.msip(riscv.cpu_to_hart_map[home_cpu])) |ptr| {
                                        ptr.* = 1;
                                    }
                                }
                            }
                        } else {
                            if (target_vc.running_on_cpu) |target_cpu| {
                                if (target_cpu != pcore.this().cpu_core_id and target_cpu < riscv.cpu_to_hart_map.len) {
                                    if (riscv.CLINT.msip(riscv.cpu_to_hart_map[target_cpu])) |ptr| {
                                        ptr.* = 1;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    setResult(vc, context, SBI_SUCCESS, 0);
}

fn handleTimer(vc: *vcore.VirtualCore, context: *riscv.ThreadContext, stime: u64) void {
    if (vc.exec_path == .native) {
        if (!config.legacy_cpu and riscv.riscv_supports_sstc) {
            // When Sstc is enabled (STCE=1), VSTIP is read-only in hvip and managed
            // natively by hardware comparing time >= vstimecmp. Manually injecting
            // VSTIP via hvip writes will silently fail.
            // Map the SBI SET_TIMER call directly to the hardware vstimecmp mechanism.
            vc.getNativeGuestState().vstimecmp = stime;
            // Clear any lingering manual scheduled timer.
            vc.timer_scheduled = false;
        } else {
            vc.timer_scheduled = true;
            vc.timer_target = stime;
            vc.getNativeMachine().hvip &= ~@as(usize, riscv.HVIP.VSTIP);
        }

        // Calculate the next physical timer event across the current vcore AND all blocked vcores
        var next_timer: u64 = ~@as(u64, 0);
        
        // Include the current vcore's timer
        if (!config.legacy_cpu and riscv.riscv_supports_sstc) {
            const vstc = vc.getNativeGuestState().vstimecmp;
            if (vstc != 0 and vstc != 0xffffffffffffffff) {
                next_timer = vstc;
            }
        } else if (vc.timer_scheduled) {
            next_timer = vc.timer_target;
        }

        var it = pcore.this().blocked_queue.start;
        while (it) |node| {
            const blocked_vc: *vcore.VirtualCore = @ptrCast(@alignCast(node.contents));
            if (blocked_vc.timer_scheduled and blocked_vc.timer_target < next_timer) {
                next_timer = blocked_vc.timer_target;
            }
            if (blocked_vc.exec_path == .native and !config.legacy_cpu and riscv.riscv_supports_sstc) {
                const gs = blocked_vc.getNativeGuestState();
                if (gs.vstimecmp != 0 and gs.vstimecmp != 0xffffffffffffffff and gs.vstimecmp < next_timer) {
                    next_timer = gs.vstimecmp;
                }
            }
            it = node.next;
        }

        if (next_timer != ~@as(u64, 0)) {
            riscv.setTimer(next_timer);
        } else {
            riscv.setTimer(0xffffffffffffffff);
        }
    } else {
        vc.timer_scheduled = true;
        vc.timer_target = stime;
    }

    setResult(vc, context, SBI_SUCCESS, 0);
}

fn handleSystemReset(vc: *vcore.VirtualCore, _: *riscv.ThreadContext, function: usize, reset_type: usize, reset_reason: usize) void {
    _ = function;
    _ = reset_reason;
    const g = vc.getGuest();
    debug.printf("SBI: System Reset (type {}) requested by guest {}\n", .{ reset_type, g.id });

    if (g.is_root) {
        if (reset_type == interface.SRST.TYPE_SHUTDOWN) {
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
        interface.HSM.HART_START => {
            const target_hart = a0;
            const start_addr = a1;
            const opaque_param = a2;

            if (g.findVcore(target_hart)) |target_vc| {
                if (target_vc.state != .stopped) {
                    setResult(vc, context, interface.ERR_ALREADY_AVAILABLE, 0);
                    return;
                }

                if (target_vc.exec_path == .native) {
                    target_vc.getNativeMachine().mepc = start_addr;
                    target_vc.getNativeContext()[@intFromEnum(arch.Register.a0)] = target_hart;
                    target_vc.getNativeContext()[@intFromEnum(riscv.Register.a1)] = opaque_param;
                } else {
                    target_vc.exec_path.emulated.entry = start_addr;
                    target_vc.exec_path.emulated.dtb = opaque_param;
                    if (target_vc.exec_path.emulated.uc) |uc| {
                        var pc: u64 = start_addr;
                        _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_PC), &pc);
                        var a0_val: u64 = target_hart;
                        _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X10), &a0_val);
                        var a1_val: u64 = opaque_param;
                        _ = glue.uc_reg_write(uc, @intFromEnum(glue.uc_riscv_reg.UC_RISCV_REG_X11), &a1_val);
                    }
                }
                target_vc.state = .ready;
                target_vc.wfi_blocked = false;

                // Ensure it's in the scheduler
                scheduler.queue(target_vc);

                // Trigger physical IPI to wake any idle physical core to pick up this vcore
                broadcastPhysicalIPI();


                setResult(vc, context, SBI_SUCCESS, 0);
            } else {
                debug.printf("HART_START: hart={} NOT FOUND\n", .{target_hart});
                setResult(vc, context, interface.ERR_INVALID_PARAM, 0);
            }
        },
        interface.HSM.HART_STOP => {
            vc.state = .stopped;
            setResult(vc, context, SBI_SUCCESS, 0);
        },
        interface.HSM.HART_GET_STATUS => {
            const target_hart = a0;
            if (g.findVcore(target_hart)) |target_vc| {
                const status: usize = switch (target_vc.state) {
                    .running => interface.HSM.STATUS_STARTED,
                    .ready => interface.HSM.STATUS_STARTED,
                    .stopped => interface.HSM.STATUS_STOPPED,
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
            // Cap bytes-per-call to prevent a guest from monopolizing the
            // hypervisor in this loop. The guest can make multiple calls.
            const DBCN_MAX_WRITE: usize = 4096;
            const num_bytes = if (a0 > DBCN_MAX_WRITE) DBCN_MAX_WRITE else a0;
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
    if (vc.exec_path == .native) {
        vc.getNativeContext()[@intFromEnum(arch.Register.a0)] = @bitCast(err);
        vc.getNativeContext()[@intFromEnum(arch.Register.a1)] = val;
    }
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

/// Send a physical IPI to all other physical cores to wake them from WFI.
/// This is necessary when a WFI-blocked vcore is woken and queued: since
/// running_on_cpu is null for blocked vcores, we can't target a specific
/// physical core. Broadcasting ensures an idle core picks up the vcore.
fn broadcastPhysicalIPI() void {
    const my_hart = riscv.getCPUContext().hardware_hart_id;
    for (0..riscv.MAX_PHYS_CORES) |cpu_id| {
        const hw_hart = riscv.cpu_to_hart_map[cpu_id];
        if (hw_hart == 0 and cpu_id != 0) break; // End of initialized entries
        if (hw_hart == my_hart) continue; // Don't IPI ourselves
        if (riscv.CLINT.msip(hw_hart)) |ptr| {
            ptr.* = 1;
        }
    }
}
