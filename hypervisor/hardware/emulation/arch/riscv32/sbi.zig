// RISC-V Supervisor Binary Interface (SBI) implementation.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("../../../native/cpu/riscv64/mod.zig");
const vcore = @import("../../../../core/vcore.zig");
const guest = @import("../../../../core/guest.zig");
const debug = @import("../../../../core/debug.zig");
const scheduler = @import("../../../../core/scheduler.zig");
const pcore = @import("../../../../core/pcore.zig");
const interface = @import("interface").sbi;
const arch = @import("interface").riscv;
const config = @import("config");
const rv32 = @import("mod.zig");
const glue = @import("../../../../core/emulation.zig");
const em_mod = @import("emulation");
const vcpu_mod = em_mod.vcpu;

// SBI Error Codes.
pub const SBI_SUCCESS = interface.SUCCESS;
pub const SBI_ERR_FAILED = interface.ERR_FAILED;
pub const SBI_ERR_NOT_SUPPORTED = interface.ERR_NOT_SUPPORTED;
pub const SBI_ERR_INVALID_PARAM = interface.ERR_INVALID_PARAM;
pub const SBI_ERR_DENIED = interface.ERR_DENIED;
pub const SBI_ERR_INVALID_ADDRESS = interface.ERR_INVALID_ADDRESS;
pub const SBI_ERR_ALREADY_AVAILABLE = interface.ERR_ALREADY_AVAILABLE;

pub fn handle(vc: *vcore.VirtualCore, sub_idx: usize, context: *riscv.ThreadContext) void {
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
            const stime = if (vc.exec_path == .emulated) (a0 & 0xffffffff) | ((@as(u64, a1) & 0xffffffff) << 32) else a0;
            handleTimer(vc, sub_idx, context, stime);
        },
        interface.EXT.LEGACY_SET_TIMER => {
            const stime = if (vc.exec_path == .emulated) (a0 & 0xffffffff) | ((@as(u64, a1) & 0xffffffff) << 32) else a0;
            handleTimer(vc, sub_idx, context, stime);
        },
        interface.EXT.SRST => handleSystemReset(vc, context, function, a0, a1),
        interface.EXT.HSM => handleHSM(vc, sub_idx, context, function, a0, a1, a2),
        interface.EXT.DBCN => handleDebugConsole(vc, context, function, a0, a1, a2),
        interface.EXT.IPI => handleIPI(vc, context, a0, a1),
        interface.EXT.RFENCE => handleRFENCE(vc, context, function, a0, a1),
        interface.EXT.LEGACY_CONSOLE_PUTCHAR => {
            const c: u8 = @truncate(a0);
            debug.putcharFromGuest(vc.guest_id, c);
            // Legacy SBI v0.1 sbi_console_putchar does not return values in a0/a1.
        },
        interface.EXT.LEGACY_CONSOLE_GETCHAR => {
            const char_val = @as(isize, debug.getchar(vc.guest_id));
            context[@intFromEnum(arch.Register.a0)] = @bitCast(char_val);
            if (vc.exec_path == .native) {
                vc.getNativeContext()[@intFromEnum(arch.Register.a0)] = @bitCast(char_val);
            } else if (vc.exec_path == .emulated) {
                if (vc.exec_path.emulated.vcpu) |v| {
                    v.setGpr(10, @truncate(@as(usize, @bitCast(char_val))));
                }
            }
            // Do NOT modify a1 or other registers.
        },
        interface.EXT.LEGACY_CLEAR_IPI => {
            if (vc.exec_path == .emulated) {
                if (vc.exec_path.emulated.vcpu) |v| {
                    v.clearMipBit(1); // clear SSIP
                }
                _ = @atomicRmw(bool, &vc.exec_path.emulated.sub_vcores[sub_idx].pending_ipi, .Xchg, false, .acq_rel);
            } else {
                vc.getNativeMachine().hvip &= ~@as(usize, riscv.HVIP.VSSIP);
                riscv.writeHvip(vc.getNativeMachine().hvip);
                // Clear the CLINT MSIP register for the current physical CPU core
                if (riscv.CLINT.msip(riscv.getCPUContext().hardware_hart_id)) |ptr| {
                    ptr.* = 0;
                }
                _ = @atomicRmw(bool, &vc.pending_ipi, .Xchg, false, .acq_rel);
            }
            setResult(vc, context, SBI_SUCCESS, 0);
        },
        interface.EXT.LEGACY_SEND_IPI => {
            // SBI v0.1: hart_mask is ALWAYS a virtual address pointing to the bit-vector, even on RV64
            const mask_ptr = context[@intFromEnum(arch.Register.a0)];
            var hart_mask: usize = 0;
            if (vc.exec_path == .emulated) {
                if (mask_ptr != 0) {
                    if (vc.exec_path.emulated.engine) |eng| {
                        const res = eng.tlb.readU32(@truncate(mask_ptr), eng.bus);
                        hart_mask = res.val;
                    }
                } else {
                    hart_mask = ~@as(usize, 0); // NULL pointer means ALL harts in SBI v0.1
                }
            } else {
                if (mask_ptr != 0) {
                    hart_mask = @as(usize, @bitCast(riscv.hlv_d(mask_ptr)));
                } else {
                    hart_mask = ~@as(usize, 0);
                }
            }
            const g = vc.getGuest();
            for (0..guest.Guest.max_vcores) |vid| {
                if ((hart_mask & (@as(usize, 1) << @intCast(vid))) != 0) {
                    if (g.vcore_lookup[vid]) |target_vc| {
                        if (target_vc.exec_path == .emulated) {
                            if (target_vc.exec_path.emulated.vcpu) |v| {
                                v.setMipBit(1); // Set SSIP
                            }
                        }
                        _ = @atomicRmw(bool, &target_vc.pending_ipi, .Xchg, true, .acq_rel);
                        if (target_vc.tryWake()) {
                            target_vc.blocked_on_cpu = null;
                            scheduler.queue(target_vc);
                        }
                        const target_hw_hart = if (target_vc.id < riscv.cpu_to_hart_map.len) riscv.cpu_to_hart_map[target_vc.id] else target_vc.id;
                        if (riscv.CLINT.msip(target_hw_hart)) |ptr| {
                            ptr.* = 1;
                        } else {
                            broadcastPhysicalIPI();
                        }
                    }
                }
            }
            setResult(vc, context, SBI_SUCCESS, 0);
        },
        interface.EXT.LEGACY_REMOTE_FENCE_I, interface.EXT.LEGACY_REMOTE_SFENCE_VMA, interface.EXT.LEGACY_REMOTE_SFENCE_VMA_ASID => {
            if (vc.exec_path == .emulated) {
                if (vc.exec_path.emulated.engine) |eng| {
                    eng.tlb.flush();
                }
            } else {
                if (riscv.hasHExtension()) {
                    riscv.hfenceGvma();
                } else {
                    riscv.sfenceVma();
                }
                riscv.getCPUContext().gstage_dirty = false;
            }
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
        riscv.writeMepc(vc.getNativeMachine().mepc);
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
    const base: usize = if (vc.exec_path == .emulated) (hart_mask_base & 0xffffffff) else hart_mask_base;
    if (base == 0xffffffff or hart_mask_base == 0xffffffffffffffff) {
        // Broadcast to all valid vcores in the guest (except self)
        for (0..guest.Guest.max_vcores) |vid| {
            if (g.vcore_lookup[vid]) |target_vc| {
                if (target_vc.id == vc.id) continue;
                if (target_vc.exec_path == .emulated) {
                    if (target_vc.exec_path.emulated.vcpu) |v| {
                        v.setMipBit(1); // Set SSIP
                    }
                } else {
                    target_vc.getNativeMachine().hvip |= riscv.HVIP.VSSIP;
                }
                _ = @atomicRmw(bool, &target_vc.pending_ipi, .Xchg, true, .acq_rel);
                if (target_vc.tryWake()) {
                    scheduler.queue(target_vc);
                }
                const target_hw_hart = if (target_vc.id < riscv.cpu_to_hart_map.len) riscv.cpu_to_hart_map[target_vc.id] else target_vc.id;
                if (riscv.CLINT.msip(target_hw_hart)) |ptr| {
                    ptr.* = 1;
                } else {
                    broadcastPhysicalIPI();
                }
            }
        }
    } else {
        // Targeted send
        const mask: usize = if (vc.exec_path == .emulated) (hart_mask & 0xffffffff) else hart_mask;
        const base_val: usize = if (vc.exec_path == .emulated) (hart_mask_base & 0xffffffff) else hart_mask_base;
        for (0..@bitSizeOf(usize)) |bit_pos| {
            if ((mask & (@as(usize, 1) << @intCast(bit_pos))) != 0) {
                const hart_id = base_val + bit_pos;
                if (hart_id < guest.Guest.max_vcores) {
                    if (g.vcore_lookup[hart_id]) |target_vc| {
                        if (target_vc.exec_path == .emulated) {
                            if (target_vc.exec_path.emulated.vcpu) |v| {
                                v.setMipBit(1); // Set SSIP
                            }
                        } else {
                            target_vc.getNativeMachine().hvip |= riscv.HVIP.VSSIP;
                        }
                        _ = @atomicRmw(bool, &target_vc.pending_ipi, .Xchg, true, .acq_rel);
                        var ipi_sent = false;

                        if (target_vc.tryWake()) {
                            scheduler.queue(target_vc);
                            ipi_sent = true;
                        }

                        if (target_vc.running_on_cpu) |target_cpu| {
                            if (target_cpu != pcore.this().cpu_core_id and target_cpu < riscv.cpu_to_hart_map.len) {
                                if (riscv.CLINT.msip(riscv.cpu_to_hart_map[target_cpu])) |ptr| {
                                    ptr.* = 1;
                                    ipi_sent = true;
                                }
                            } else if (target_cpu == pcore.this().cpu_core_id) {
                                if (riscv.hasHExtension()) {
                                    riscv.writeHvip(riscv.readHvip() | riscv.HVIP.VSSIP);
                                }
                                ipi_sent = true;
                            }
                        }

                        // GUARANTEE DELIVERY: If no targeted physical IPI was dispatched (e.g. transient state),
                        // send IPI directly to the target hardware hart or broadcast to prevent sleeping deadlocks.
                        if (!ipi_sent) {
                            const target_hw_hart = if (target_vc.id < riscv.cpu_to_hart_map.len) riscv.cpu_to_hart_map[target_vc.id] else target_vc.id;
                            if (riscv.CLINT.msip(target_hw_hart)) |ptr| {
                                ptr.* = 1;
                            } else {
                                broadcastPhysicalIPI();
                            }
                        }
                    }
                }
            }
        }
    }
    setResult(vc, context, SBI_SUCCESS, 0);
}

fn handleTimer(vc: *vcore.VirtualCore, sub_idx: usize, context: *riscv.ThreadContext, stime: u64) void {
    if (vc.exec_path == .emulated) {
        vc.timer_target = stime;
        vc.timer_scheduled = (stime != 0 and stime != ~@as(u64, 0));
        const sub = &vc.exec_path.emulated.sub_vcores[sub_idx];
        sub.timer_target = stime;
        sub.timer_scheduled = vc.timer_scheduled;

        if (vc.exec_path.emulated.vcpu) |v| {
            v.vstimecmp = stime;
            v.clearMipBit(5); // Clear MIP_STIP until Engine evaluates deadline
        }
        if (vc.timer_scheduled) {
            riscv.setTimer(stime +% vcore.time_offset);
        }
    } else {
        vc.getNativeGuestState().vstimecmp = stime;
        if (!config.legacy_cpu and riscv.riscv_supports_sstc) {
            riscv.writeVstimecmp(stime);
            vc.getNativeMachine().hvip &= ~@as(usize, riscv.HVIP.VSTIP);
            riscv.writeHvip(vc.getNativeMachine().hvip);
        }
        if (stime != 0 and stime != ~@as(u64, 0)) {
            riscv.setTimer(stime);
        }
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

fn handleRFENCE(vc: *vcore.VirtualCore, context: *riscv.ThreadContext, function: usize, a0: usize, a1: usize) void {
    _ = function;
    const g = vc.getGuest();
    const hart_mask = a0;
    const hart_mask_base = a1;

    if (vc.exec_path == .emulated) {
        if (hart_mask_base == std.math.maxInt(usize) or (hart_mask_base & 0xffffffff) == 0xffffffff) {
            for (0..guest.Guest.max_vcores) |vid| {
                if (g.vcore_lookup[vid]) |target_vc| {
                    if (target_vc == vc) {
                        if (target_vc.exec_path.emulated.engine) |eng| {
                            eng.tlb.flush();
                        }
                    } else if (target_vc.exec_path == .emulated) {
                        if (target_vc.exec_path.emulated.vcpu) |v| {
                            v.setNeedsTlbFlush();
                        }
                        const target_hw_hart = if (target_vc.id < riscv.cpu_to_hart_map.len) riscv.cpu_to_hart_map[target_vc.id] else target_vc.id;
                        if (riscv.CLINT.msip(target_hw_hart)) |ptr| {
                            ptr.* = 1;
                        }
                    }
                }
            }
        } else {
            const mask: usize = hart_mask & 0xffffffff;
            const base_val: usize = hart_mask_base & 0xffffffff;
            for (0..@bitSizeOf(usize)) |bit_pos| {
                if ((mask & (@as(usize, 1) << @intCast(bit_pos))) != 0) {
                    const hart_id = base_val + bit_pos;
                    if (hart_id < guest.Guest.max_vcores) {
                        if (g.vcore_lookup[hart_id]) |target_vc| {
                            if (target_vc == vc) {
                                if (target_vc.exec_path.emulated.engine) |eng| {
                                    eng.tlb.flush();
                                }
                            } else if (target_vc.exec_path == .emulated) {
                                if (target_vc.exec_path.emulated.vcpu) |v| {
                                    v.setNeedsTlbFlush();
                                }
                                const target_hw_hart = if (target_vc.id < riscv.cpu_to_hart_map.len) riscv.cpu_to_hart_map[target_vc.id] else target_vc.id;
                                if (riscv.CLINT.msip(target_hw_hart)) |ptr| {
                                    ptr.* = 1;
                                }
                            }
                        }
                    }
                }
            }
        }
    } else {
        if (riscv.hasHExtension()) {
            riscv.hfenceGvma();
        } else {
            riscv.sfenceVma();
        }
        riscv.getCPUContext().gstage_dirty = false;
    }
    setResult(vc, context, SBI_SUCCESS, 0);
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

fn handleHSM(vc: *vcore.VirtualCore, sub_idx: usize, context: *riscv.ThreadContext, function: usize, a0: usize, a1: usize, a2: usize) void {
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

                if (target_vc.exec_path == .emulated) {
                    target_vc.exec_path.emulated.entry = start_addr;
                    if (target_vc.exec_path.emulated.vcpu == null) {
                        glue.init(target_vc) catch |err| {
                            debug.printf("ERROR sbi HART_START: glue.init failed: {s}\n", .{@errorName(err)});
                            setResult(vc, context, interface.ERR_FAILED, 0);
                            return;
                        };
                    }
                    if (target_vc.exec_path.emulated.vcpu) |target_vcpu| {
                        target_vcpu.pc = @truncate(start_addr);
                        target_vcpu.setReg(10, target_hart);
                        target_vcpu.setReg(11, opaque_param);
                        target_vcpu.privilege_mode = 1;
                        target_vcpu.priv_mode = 1;
                        target_vcpu.satp = 0;
                        target_vcpu.medeleg = 0xFFFF;
                        target_vcpu.mideleg = 0xFFFF;
                        target_vcpu.mstatus = (1 << 8) | (1 << 5); // SPP=1, SPIE=1, SIE=0
                        target_vcpu.vstimecmp = ~@as(u64, 0);
                        target_vcpu.clearMipBit(5);
                        target_vcpu.clearMipBit(1);
                        target_vcpu.running = true;
                    }
                    target_vc.state = .ready;
                    scheduler.queue(target_vc);
                    const target_hw_hart = if (target_vc.id < riscv.cpu_to_hart_map.len) riscv.cpu_to_hart_map[target_vc.id] else target_vc.id;
                    if (riscv.CLINT.msip(target_hw_hart)) |ptr| {
                        ptr.* = 1;
                    }
                    broadcastPhysicalIPI();
                    setResult(vc, context, interface.SUCCESS, 0);
                } else {
                    target_vc.getNativeContext()[@intFromEnum(arch.Register.a0)] = target_hart;
                    target_vc.getNativeContext()[@intFromEnum(arch.Register.a1)] = opaque_param;
                    target_vc.getNativeMachine().mepc = start_addr;
                    target_vc.getNativeMachine().mstatus = (1 << 11) | riscv.MSTATUS.MPIE | riscv.MSTATUS.MPV | (3 << riscv.MSTATUS.VS_SHIFT) | (3 << riscv.MSTATUS.FS_SHIFT);
                    target_vc.getNativeMachine().hstatus = riscv.HSTATUS.SPV | riscv.HSTATUS.SPVP;
                    target_vc.getNativeMachine().hedeleg = 0xb1fb;
                    target_vc.getNativeMachine().hideleg = 0x1666;
                    target_vc.getNativeMachine().hvip = 0;
                    if (target_vc.guest.space.mode == .h_paging) {
                        target_vc.getNativeMachine().hgatp = target_vc.guest.space.paging.?.hgatp(target_vc.guest.vmid);
                    }
                    target_vc.getNativeGuestState().vsstatus = riscv.SSTATUS.SPIE | (3 << riscv.MSTATUS.VS_SHIFT) | (3 << riscv.MSTATUS.FS_SHIFT);
                    target_vc.getNativeGuestState().vsatp = 0;
                    target_vc.getNativeGuestState().vstimecmp = 0xffffffffffffffff;
                    target_vc.getNativeGuestState().vsenvcfg = (1 << 63) | 240;
                    target_vc.getNativeGuestState().vstvec = 0;
                    target_vc.getNativeGuestState().vsie = 0;
                    target_vc.getNativeGuestState().vsscratch = 0;
                    target_vc.getNativeGuestState().vsepc = 0;
                    target_vc.getNativeGuestState().vscause = 0;
                    target_vc.getNativeGuestState().vstval = 0;
                    @atomicStore(bool, &target_vc.pending_ipi, false, .release);
                    target_vc.state = .ready;
                    scheduler.queue(target_vc);
                    const target_hw_hart = if (target_vc.id < riscv.cpu_to_hart_map.len) riscv.cpu_to_hart_map[target_vc.id] else target_vc.id;
                    if (riscv.CLINT.msip(target_hw_hart)) |ptr| {
                        ptr.* = 1;
                    } else {
                        broadcastPhysicalIPI();
                    }
                    setResult(vc, context, interface.SUCCESS, 0);
                }
            } else {
                setResult(vc, context, interface.ERR_INVALID_PARAM, 0);
            }
        },
        interface.HSM.HART_STOP => {
            if (vc.exec_path == .emulated) {
                vc.exec_path.emulated.sub_vcores[sub_idx].state = .stopped;
                // No setResult needed as HART_STOP never returns
            } else {
                vc.state = .stopped;
                setResult(vc, context, SBI_SUCCESS, 0);
            }
        },
        interface.HSM.HART_GET_STATUS => {
            const target_hart = a0;
            if (vc.exec_path == .emulated) {
                if (target_hart < vc.exec_path.emulated.sub_vcore_count) {
                    const status: usize = switch (vc.exec_path.emulated.sub_vcores[target_hart].state) {
                        .running, .ready, .blocked => interface.HSM.STATUS_STARTED,
                        .stopped => interface.HSM.STATUS_STOPPED,
                    };
                    setResult(vc, context, SBI_SUCCESS, status);
                } else {
                    setResult(vc, context, interface.ERR_INVALID_PARAM, 0);
                }
            } else {
                if (g.findVcore(target_hart)) |target_vc| {
                    const status: usize = switch (target_vc.state) {
                        .running, .ready, .blocked => interface.HSM.STATUS_STARTED,
                        .stopped => interface.HSM.STATUS_STOPPED,
                    };
                    setResult(vc, context, SBI_SUCCESS, status);
                } else {
                    setResult(vc, context, interface.ERR_INVALID_PARAM, 0);
                }
            }
        },
        else => setResult(vc, context, SBI_ERR_NOT_SUPPORTED, 0),
    }
}

fn handleDebugConsole(vc: *vcore.VirtualCore, context: *riscv.ThreadContext, function: usize, a0: usize, a1: usize, a2: usize) void {
    const g = vc.getGuest();
    switch (function) {
        interface.DBCN.CONSOLE_WRITE => {
            // Cap bytes-per-call to prevent a guest from monopolizing the
            // hypervisor in this loop. The guest can make multiple calls.
            const DBCN_MAX_WRITE: usize = 4096;
            const num_bytes = if (a0 > DBCN_MAX_WRITE) DBCN_MAX_WRITE else a0;
            const gpa: usize = (a1 & 0xffffffff) | ((@as(usize, @intCast(a2)) & 0xffffffff) << 32);

            var written: usize = 0;
            var buf: [256]u8 = undefined;
            var buf_idx: usize = 0;

            while (written < num_bytes) {
                const target_addr = gpa + written;
                var char: u8 = 0;
                if (g.space.translateGPA(target_addr)) |hpa| {
                    char = @as(*u8, @ptrFromInt(hpa)).*;
                } else |_| {
                    setResult(vc, context, SBI_ERR_INVALID_ADDRESS, written);
                    return;
                }
                buf[buf_idx] = char;
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
            const gpa: usize = (a1 & 0xffffffff) | ((@as(usize, @intCast(a2)) & 0xffffffff) << 32);
            var read: usize = 0;
            while (read < num_bytes) : (read += 1) {
                const c = debug.getchar(vc.guest_id);
                if (c < 0) break;
                const target_addr = gpa + read;
                if (g.space.translateGPA(target_addr)) |hpa| {
                    @as(*u8, @ptrFromInt(hpa)).* = @truncate(@as(u16, @bitCast(c)));
                } else |_| {
                    setResult(vc, context, SBI_ERR_INVALID_ADDRESS, read);
                    return;
                }
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
    } else if (vc.exec_path == .emulated) {
        if (vc.exec_path.emulated.vcpu) |v| {
            v.setGpr(10, @truncate(@as(usize, @bitCast(err))));
            v.setGpr(11, @truncate(val));
        }
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
    for (0..riscv.MAX_PHYS_CORES) |hw_hart| {
        if (hw_hart == my_hart) continue; // Don't IPI ourselves
        if (riscv.CLINT.msip(hw_hart)) |ptr| {
            ptr.* = 1;
        }
    }
}
