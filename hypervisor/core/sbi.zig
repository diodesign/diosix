// RISC-V Supervisor Binary Interface (SBI) implementation.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("../hardware/native/cpu/riscv64/mod.zig");
const vcore = @import("vcore.zig");
const guest = @import("guest.zig");
const debug = @import("debug.zig");
const scheduler = @import("scheduler.zig");
const pcore = @import("pcore.zig");
const physmem = @import("physmem.zig");
const sv39x4 = @import("../hardware/native/cpu/riscv64/sv39x4.zig");
const interface = @import("interface").sbi;

const arch = @import("interface").riscv;
const config = @import("config");
const glue = @import("emulation.zig");
const loader = @import("loader.zig");
const em_mod = @import("emulation");
const vcpu_mod = em_mod.vcpu;
const builtin = @import("builtin");

extern const project_version: [*:0]const u8;
extern const git_revision: [*:0]const u8;

pub const RV32_WORD_MASK: u64 = 0xFFFF_FFFF;
pub const RV32_HIGH_SHIFT: u6 = 32;
pub const ECALL_INSTRUCTION_SIZE_BYTES: usize = 4;
pub const MIP_SSIP_BIT: u6 = 1;
pub const MIP_STIP_BIT: u6 = 5;
pub const DBCN_CHUNK_BUFFER_SIZE: usize = 256;
pub const DBCN_MAX_WRITE_BYTES: usize = 4096;

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
            const stime = if (vc.exec_path == .emulated) (a0 & RV32_WORD_MASK) | ((@as(u64, a1) & RV32_WORD_MASK) << RV32_HIGH_SHIFT) else a0;
            handleTimer(vc, sub_idx, context, stime);
        },
        interface.EXT.LEGACY_SET_TIMER => {
            const stime = if (vc.exec_path == .emulated) (a0 & RV32_WORD_MASK) | ((@as(u64, a1) & RV32_WORD_MASK) << RV32_HIGH_SHIFT) else a0;
            handleTimer(vc, sub_idx, context, stime);
        },
        interface.EXT.SRST => handleSystemReset(vc, context, function, a0, a1),
        interface.EXT.HSM => handleHSM(vc, sub_idx, context, function, a0, a1, a2),
        interface.EXT.DBCN => handleDebugConsole(vc, context, function, a0, a1, a2),
        interface.EXT.IPI => handleIPI(vc, context, a0, a1),
        interface.EXT.RFENCE => handleRFENCE(vc, context, function, a0, a1),
        interface.EXT.LEGACY_CONSOLE_PUTCHAR => {
            if (vc.guest_id == 1) {
                const c: u8 = @truncate(a0);
                debug.putchar(c);
            }
            // Legacy SBI v0.1 sbi_console_putchar does not return values in a0/a1.
        },
        interface.EXT.LEGACY_CONSOLE_GETCHAR => {
            const char_val: isize = if (vc.guest_id == 1) @as(isize, debug.getchar()) else -1;
            context[@intFromEnum(arch.Register.a0)] = @bitCast(char_val);
            if (vc.exec_path == .native) {
                vc.getNativeContext()[@intFromEnum(arch.Register.a0)] = @bitCast(char_val);
            } else if (vc.exec_path == .emulated) {
                if (vc.exec_path.emulated.vcpu) |v| {
                    v.setGpr(@intFromEnum(arch.Register.a0), @truncate(@as(usize, @bitCast(char_val))));
                }
            }
            // Do NOT modify a1 or other registers.
        },
        interface.EXT.LEGACY_CLEAR_IPI => {
            if (vc.exec_path == .emulated) {
                if (vc.exec_path.emulated.vcpu) |v| {
                    v.clearMipBit(MIP_SSIP_BIT); // clear SSIP
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
                    hart_mask = std.math.maxInt(usize); // NULL pointer means ALL harts in SBI v0.1
                }
            } else {
                if (mask_ptr != 0) {
                    hart_mask = @as(usize, @bitCast(riscv.hlv_d(mask_ptr)));
                } else {
                    hart_mask = std.math.maxInt(usize);
                }
            }
            const g = vc.getGuest();
            for (0..guest.max_vcores) |vid| {
                if ((hart_mask & (@as(usize, 1) << @intCast(vid))) != 0) {
                    if (g.vcore_lookup[vid]) |target_vc| {
                        if (target_vc.exec_path == .emulated) {
                            if (target_vc.exec_path.emulated.vcpu) |v| {
                                v.setMipBit(MIP_SSIP_BIT); // Set SSIP
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
            terminateOrRestart(vc.getGuest(), 0);
        },

        interface.EXT.DIOSIX => handleDiosix(vc, context, function, a0, a1, a2),
        else => {
            debug.printf("SBI: Unknown extension 0x{x} func {} from guest {}\n", .{ extension, function, vc.id });
            setResult(vc, context, SBI_ERR_NOT_SUPPORTED, 0);
        },
    }

    // Move guest to the next instruction after ECALL
    if (vc.exec_path == .native) {
        vc.getNativeMachine().mepc += ECALL_INSTRUCTION_SIZE_BYTES;
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
    const base: usize = if (vc.exec_path == .emulated) (hart_mask_base & RV32_WORD_MASK) else hart_mask_base;
    if (base == RV32_WORD_MASK or hart_mask_base == std.math.maxInt(usize)) {
        // Broadcast to all valid vcores in the guest (except self)
        for (0..guest.max_vcores) |vid| {
            if (g.vcore_lookup[vid]) |target_vc| {
                if (target_vc.id == vc.id) continue;
                if (target_vc.exec_path == .emulated) {
                    if (target_vc.exec_path.emulated.vcpu) |v| {
                        v.setMipBit(MIP_SSIP_BIT); // Set SSIP
                    }
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
        const mask: usize = if (vc.exec_path == .emulated) (hart_mask & RV32_WORD_MASK) else hart_mask;
        const base_val: usize = if (vc.exec_path == .emulated) (hart_mask_base & RV32_WORD_MASK) else hart_mask_base;
        for (0..@bitSizeOf(usize)) |bit_pos| {
            if ((mask & (@as(usize, 1) << @intCast(bit_pos))) != 0) {
                const hart_id = base_val + bit_pos;
                if (hart_id < guest.max_vcores) {
                    if (g.vcore_lookup[hart_id]) |target_vc| {
                        if (target_vc.exec_path == .emulated) {
                            if (target_vc.exec_path.emulated.vcpu) |v| {
                                v.setMipBit(MIP_SSIP_BIT); // Set SSIP
                            }
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
        vc.timer_scheduled = (stime != 0 and stime != std.math.maxInt(u64));
        const sub = &vc.exec_path.emulated.sub_vcores[sub_idx];
        sub.timer_target = stime;
        sub.timer_scheduled = vc.timer_scheduled;

        if (vc.exec_path.emulated.vcpu) |v| {
            v.vstimecmp = stime;
            v.clearMipBit(MIP_STIP_BIT); // Clear MIP_STIP until Engine evaluates deadline
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
        if (stime != 0 and stime != std.math.maxInt(u64)) {
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
        if (hart_mask_base == std.math.maxInt(usize) or (hart_mask_base & RV32_WORD_MASK) == RV32_WORD_MASK) {
            for (0..guest.max_vcores) |vid| {
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
            const mask: usize = hart_mask & RV32_WORD_MASK;
            const base_val: usize = hart_mask_base & RV32_WORD_MASK;
            for (0..@bitSizeOf(usize)) |bit_pos| {
                if ((mask & (@as(usize, 1) << @intCast(bit_pos))) != 0) {
                    const hart_id = base_val + bit_pos;
                    if (hart_id < guest.max_vcores) {
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

        // Broadcast IPI to remote harts in the mask so they also flush their TLBs
        if (hart_mask_base == std.math.maxInt(usize)) {
            broadcastPhysicalIPI();
        } else {
            for (0..@bitSizeOf(usize)) |bit_pos| {
                if ((hart_mask & (@as(usize, 1) << @intCast(bit_pos))) != 0) {
                    const hart_id = hart_mask_base + bit_pos;
                    if (hart_id < riscv.cpu_to_hart_map.len) {
                        if (riscv.CLINT.msip(riscv.cpu_to_hart_map[hart_id])) |ptr| {
                            ptr.* = 1;
                        }
                    }
                }
            }
        }
    }
    setResult(vc, context, SBI_SUCCESS, 0);
}

fn deliverPacket(target: *guest.Guest, pkt_data: []const u8) void {
    if (target.net_rx.push(pkt_data)) {
        var it = target.vcores.start;
        while (it) |node| {
            const target_vc = node.contents;
            if (target_vc.tryWake()) {
                scheduler.queue(target_vc);
            }
            it = node.next;
        }
        broadcastPhysicalIPI();
    }
}

fn handleDiosix(vc: *vcore.VirtualCore, context: *riscv.ThreadContext, function: usize, a0: usize, a1: usize, a2: usize) void {
    const g = vc.getGuest();
    switch (function) {
        interface.DIOSIX.TERMINATE => {
            const target_cid = a0;
            const exit_code = a1;
            if (target_cid == guest.CID_SELF or (target_cid == guest.CID_PARENT and g.is_root)) {
                debug.printf("SBI: Diosix Terminate (self) requested by guest (CID {}) with exit code {}\n", .{ g.local_cid, exit_code });
                terminateOrRestart(g, exit_code);
            } else if (target_cid == guest.CID_PARENT) {
                // Non-root VM cannot terminate its parent
                setResult(vc, context, SBI_ERR_DENIED, 0);
            } else if (target_cid >= guest.CID_FIRST_CHILD) {
                if (g.getGuestByCid(target_cid)) |child| {
                    debug.printf("SBI: Guest terminating child (CID {}) with exit code {}\n", .{ target_cid, exit_code });
                    child.terminateWithCode(exit_code);
                    setResult(vc, context, SBI_SUCCESS, 0);
                } else {
                    setResult(vc, context, SBI_ERR_INVALID_PARAM, 0);
                }
            } else {
                setResult(vc, context, SBI_ERR_INVALID_PARAM, 0);
            }
        },

        interface.DIOSIX.YIELD => {
            scheduler.yield(vc);
        },
        interface.DIOSIX.DROP_TRUST => {
            g.dropTrust();
            setResult(vc, context, SBI_SUCCESS, 0);
        },
        interface.DIOSIX.GET_INFO => {
            const target_cid = if (a0 < 4096) a0 else 1;
            const info_gpa = if (a0 < 4096) a1 else a0;
            const info_len = if (a0 < 4096) a2 else a1;

            if (info_len != 0 and info_len < @sizeOf(interface.GuestInfo)) {
                setResult(vc, context, SBI_ERR_INVALID_PARAM, 0);
                return;
            }

            if (target_cid == 0) {
                setResult(vc, context, SBI_ERR_DENIED, 0);
                return;
            }

            const target_guest: ?*guest.Guest = if (target_cid == 1)
                g
            else
                g.getGuestByCid(target_cid);

            if (target_guest == null) {
                setResult(vc, context, SBI_ERR_INVALID_PARAM, 0);
                return;
            }
            const tg = target_guest.?;

            if (g.space.translateGPA(info_gpa) catch null) |hpa| {
                const info_ptr: *interface.GuestInfo = @ptrFromInt(hpa);
                const effective_ram_pages: usize = blk: {
                    if (tg.is_root) {
                        break :blk if (tg.space.range_size > 0) tg.space.range_size / physmem.PageSize else (512 * 1024 * 1024 / physmem.PageSize);
                    } else {
                        if (tg.space.range_size > 0) {
                            break :blk tg.space.range_size / physmem.PageSize;
                        } else if (tg.quotas.used_ram_pages > 0 and tg.quotas.used_ram_pages != std.math.maxInt(usize)) {
                            break :blk tg.quotas.used_ram_pages;
                        } else if (tg.quotas.max_ram_pages > 0 and tg.quotas.max_ram_pages != std.math.maxInt(usize)) {
                            break :blk tg.quotas.max_ram_pages;
                        } else {
                            break :blk (256 * 1024 * 1024 / physmem.PageSize);
                        }
                    }
                };

                info_ptr.* = .{
                    .guest_id = if (tg == g) 1 else target_cid,
                    .parent_id = if (tg == g) (if (g.parent != null) guest.CID_PARENT else 0) else 1,
                    .is_trusted = if (tg.is_trusted) 1 else 0,
                    .is_root = if (tg.is_root) 1 else 0,
                    .target_arch = @intFromEnum(tg.target_arch),
                    .assigned_cid = if (tg.is_root) 1 else @truncate(tg.local_cid),
                    .vcpus = tg.vcores.count(),
                    .self_ram_pages = effective_ram_pages,
                    .used_vcpus = if (tg.quotas.used_vcpus > 0) tg.quotas.used_vcpus else tg.vcores.count(),
                    .max_vcpus = if (tg.quotas.max_vcpus == std.math.maxInt(usize)) tg.vcores.count() else tg.quotas.max_vcpus,
                    .used_ram_pages = if (tg.quotas.used_ram_pages > 0 and tg.quotas.used_ram_pages != std.math.maxInt(usize)) tg.quotas.used_ram_pages else effective_ram_pages,
                    .max_ram_pages = if (tg.quotas.max_ram_pages == std.math.maxInt(usize)) effective_ram_pages else tg.quotas.max_ram_pages,
                    .child_count = tg.children.count(),
                };

                setResult(vc, context, SBI_SUCCESS, 0);
            } else {
                setResult(vc, context, SBI_ERR_INVALID_ADDRESS, 0);
            }
        },

        interface.DIOSIX.RUN => {
            if (g.space.translateGPA(a0) catch null) |args_hpa| {
                const args: *const interface.RunArgs = @ptrFromInt(args_hpa);
                // Look up child by CID (>= CID_FIRST_CHILD) or create a fresh child on the fly (child_id == 0)
                const child_to_run: ?*guest.Guest = if (args.child_id >= guest.CID_FIRST_CHILD)
                    g.getGuestByCid(args.child_id)
                else if (args.child_id == 0)
                    g.createChild((args.flags & interface.RunFlags.TRUSTED) != 0, .riscv64, 1) catch null
                else
                    null;

                if (child_to_run) |child| {
                    // Set trust level: default is untrusted unless RunFlags.TRUSTED is explicitly passed
                    if ((args.flags & interface.RunFlags.TRUSTED) != 0) {
                        if (!g.is_trusted) {
                            setResult(vc, context, SBI_ERR_DENIED, 0);
                            return;
                        }
                        child.is_trusted = true;
                        child.space.is_trusted = true;
                    } else {
                        child.dropTrust();
                    }

                    // 1. Stop all virtual cores of the child VM and wait for physical cores to relinquish them
                    child.stop();

                    // 2. Invalidate TLB and G-stage translation cache
                    if (riscv.hasHExtension()) {
                        riscv.hfenceGvma();
                    } else {
                        riscv.sfenceVma();
                    }

                    if (args.elf_size == 0) {
                        setResult(vc, context, SBI_SUCCESS, child.local_cid);
                        return;
                    }

                    if (g.space.translateGPA(args.elf_ptr) catch null) |elf_hpa| {
                        const elf_data = @as([*]const u8, @ptrFromInt(elf_hpa))[0..args.elf_size];

                        // 3. Detect and update target architecture if necessary
                        if (loader.Loader.detectArch(elf_data) catch null) |detected_arch| {
                            child.target_arch = detected_arch;
                        }

                        // 4. Load the ELF binary segments into child GPA space
                        const entry_point = loader.Loader.load(child, elf_data) catch |err| {
                            debug.printf("SBI: Run loader failed: {s}\n", .{@errorName(err)});
                            setResult(vc, context, SBI_ERR_FAILED, 0);
                            return;
                        };

                        // 5. Reset all child virtual cores (Hart 0 = .ready, Hart 1..N = .stopped)
                        child.resetForRun(entry_point, args.dtb_ptr);

                        // 6. Enqueue only the primary bootstrap core (Hart 0) into scheduler
                        if (child.vcores.start) |vc_node| {
                            scheduler.queue(vc_node.contents);
                        }

                        setResult(vc, context, SBI_SUCCESS, child.local_cid);
                    } else {
                        setResult(vc, context, SBI_ERR_INVALID_ADDRESS, 0);
                    }
                } else {
                    setResult(vc, context, SBI_ERR_INVALID_PARAM, 0);
                }
            } else {
                setResult(vc, context, SBI_ERR_INVALID_ADDRESS, 0);
            }
        },
        interface.DIOSIX.POLL_EVENT => {
            const event_gpa = a0;
            const event_len = a1;
            if (event_len < @sizeOf(interface.Event)) {
                setResult(vc, context, SBI_ERR_INVALID_PARAM, 0);
                return;
            }
            if (g.events.pop()) |ev| {
                if (g.space.translateGPA(event_gpa) catch null) |hpa| {
                    const ev_ptr: *interface.Event = @ptrFromInt(hpa);
                    ev_ptr.* = ev;
                    setResult(vc, context, SBI_SUCCESS, 1);
                } else {
                    setResult(vc, context, SBI_ERR_INVALID_ADDRESS, 0);
                }
            } else {
                setResult(vc, context, SBI_SUCCESS, 0);
            }
        },
        interface.DIOSIX.SET_QUOTA => {
            if (g.space.translateGPA(a0) catch null) |hpa| {
                const qargs: *const interface.QuotaArgs = @ptrFromInt(hpa);
                g.setQuota(qargs.*) catch |err| {
                    switch (err) {
                        error.AccessDenied => setResult(vc, context, SBI_ERR_DENIED, 0),
                        error.InvalidParam => setResult(vc, context, SBI_ERR_INVALID_PARAM, 0),
                    }
                    return;
                };
                setResult(vc, context, SBI_SUCCESS, 0);
            } else {
                setResult(vc, context, SBI_ERR_INVALID_ADDRESS, 0);
            }
        },
        interface.DIOSIX.GET_HV_INFO => {
            const buf_gpa = a0;
            const buf_len = a1;
            if (buf_len < @sizeOf(interface.HypervisorInfo)) {
                setResult(vc, context, SBI_ERR_INVALID_PARAM, 0);
                return;
            }
            if (g.space.translateGPA(buf_gpa) catch null) |hpa| {
                const info_ptr: *interface.HypervisorInfo = @ptrFromInt(hpa);
                var info = interface.HypervisorInfo{};

                const v_str = std.mem.span(project_version);
                if (std.mem.indexOfScalar(u8, v_str, '.')) |dot| {
                    info.version_major = std.fmt.parseInt(u16, v_str[0..dot], 10) catch 26;
                    info.version_minor = std.fmt.parseInt(u16, v_str[dot + 1 ..], 10) catch 1;
                }

                const rev_str = std.mem.span(git_revision);
                const copy_len = @min(rev_str.len, 15);
                @memcpy(info.build_commit[0..copy_len], rev_str[0..copy_len]);

                info.features = interface.HypervisorFeature.DYNAREC | interface.HypervisorFeature.VIRTIO_VSOCK;

                if (!builtin.is_test and riscv.hasHExtension()) {
                    info.features |= interface.HypervisorFeature.HARDWARE_VIRT |
                        interface.HypervisorFeature.STAGE2_PAGING;
                }

                info.host_physical_cores = riscv.getOnlineCpuCount();
                info.host_timer_freq_hz = interface.HOST_TIMER_FREQ_HZ;
                info.host_total_ram_kb = @intCast(physmem.getTotalRamBytes() / 1024);
                info.host_free_ram_kb = @intCast(physmem.getFreeRamBytes() / 1024);

                info_ptr.* = info;
                setResult(vc, context, SBI_SUCCESS, 0);
            } else {
                setResult(vc, context, SBI_ERR_INVALID_ADDRESS, 0);
            }
        },
        interface.DIOSIX.GET_MANIFEST => {
            if (g.space.translateGPA(a0) catch null) |hpa| {
                const margs: *interface.ManifestArgs = @ptrFromInt(hpa);
                const target_guest = g.getGuestByCid(margs.target_cid);
                if (target_guest) |target| {
                    if (target.manifest) |m_data| {
                        const copy_len = @min(margs.max_len, m_data.len);
                        if (copy_len > 0) {
                            if (g.space.translateGPA(margs.data_ptr) catch null) |data_hpa| {
                                const dst_slice: [*]u8 = @ptrFromInt(data_hpa);
                                @memcpy(dst_slice[0..copy_len], m_data[0..copy_len]);
                                margs.actual_len = m_data.len;
                                setResult(vc, context, SBI_SUCCESS, copy_len);
                            } else {
                                setResult(vc, context, SBI_ERR_INVALID_ADDRESS, 0);
                            }
                        } else {
                            margs.actual_len = m_data.len;
                            setResult(vc, context, SBI_SUCCESS, 0);
                        }
                    } else {
                        margs.actual_len = 0;
                        setResult(vc, context, SBI_SUCCESS, 0);
                    }
                } else {
                    setResult(vc, context, SBI_ERR_INVALID_PARAM, 0);
                }
            } else {
                setResult(vc, context, SBI_ERR_INVALID_ADDRESS, 0);
            }
        },
        interface.DIOSIX.SET_MANIFEST => {
            if (g.space.translateGPA(a0) catch null) |hpa| {
                const margs: *const interface.ManifestArgs = @ptrFromInt(hpa);
                const target_guest = g.getGuestByCid(margs.target_cid);
                if (target_guest) |target| {
                    if (!g.is_trusted and !g.is_root and target.parent != g) {
                        setResult(vc, context, SBI_ERR_DENIED, 0);
                        return;
                    }
                    if (g.space.translateGPA(margs.data_ptr) catch null) |data_hpa| {
                        const src_slice: [*]const u8 = @ptrFromInt(data_hpa);
                        target.setManifest(src_slice[0..margs.max_len]) catch |err| {
                            debug.printf("SBI: Set manifest failed: {s}\n", .{@errorName(err)});
                            setResult(vc, context, SBI_ERR_FAILED, 0);
                            return;
                        };
                        setResult(vc, context, SBI_SUCCESS, 0);
                    } else {
                        setResult(vc, context, SBI_ERR_INVALID_ADDRESS, 0);
                    }
                } else {
                    setResult(vc, context, SBI_ERR_INVALID_PARAM, 0);
                }
            } else {
                setResult(vc, context, SBI_ERR_INVALID_ADDRESS, 0);
            }
        },
        interface.DIOSIX.MAP_CHILD_MEM => {
            if (g.space.translateGPA(a0) catch null) |hpa| {
                const margs: *const interface.MapChildMemArgs = @ptrFromInt(hpa);
                const target_guest = g.getGuestByCid(margs.child_id);
                if (target_guest) |child| {
                    // Security Shield: Caller must be direct parent or ancestor of child
                    if (child == g or (child.parent != g and !g.is_root)) {
                        setResult(vc, context, SBI_ERR_DENIED, 0);
                        return;
                    }
                    if (margs.size == 0 or (margs.size % physmem.PageSize) != 0) {
                        setResult(vc, context, SBI_ERR_INVALID_PARAM, 0);
                        return;
                    }
                    // Limit foreign mapping size to 512MB per call for safety
                    if (margs.size > 512 * 1024 * 1024) {
                        setResult(vc, context, SBI_ERR_INVALID_PARAM, 0);
                        return;
                    }

                    const parent_rwx = sv39x4.PTEFlags.read | sv39x4.PTEFlags.write | sv39x4.PTEFlags.valid | sv39x4.PTEFlags.accessed | sv39x4.PTEFlags.dirty | sv39x4.PTEFlags.user;
                    var offset: usize = 0;
                    while (offset < margs.size) : (offset += physmem.PageSize) {
                        const cur_child_gpa = margs.child_gpa + offset;
                        const cur_parent_gpa = margs.parent_gpa + offset;

                        // Ensure child page exists (allocate on demand if needed)
                        const child_hpa = child.space.translateGPA(cur_child_gpa) catch blk: {
                            const new_page = physmem.allocPage() catch {
                                setResult(vc, context, SBI_ERR_FAILED, 0);
                                return;
                            };
                            @memset(@as([*]u8, @ptrFromInt(new_page))[0..physmem.PageSize], 0);
                            const child_pte_flags = sv39x4.PTEFlags.read | sv39x4.PTEFlags.write | sv39x4.PTEFlags.execute | sv39x4.PTEFlags.valid | sv39x4.PTEFlags.accessed | sv39x4.PTEFlags.dirty | sv39x4.PTEFlags.user;
                            child.space.map(cur_child_gpa, new_page, physmem.PageSize, child_pte_flags) catch {
                                setResult(vc, context, SBI_ERR_FAILED, 0);
                                return;
                            };
                            break :blk new_page;
                        };

                        // Map child_hpa into parent's Stage-2 page table
                        g.space.map(cur_parent_gpa, child_hpa, physmem.PageSize, parent_rwx) catch {
                            setResult(vc, context, SBI_ERR_FAILED, 0);
                            return;
                        };
                    }

                    riscv.hfenceGvma();
                    setResult(vc, context, SBI_SUCCESS, margs.size);
                } else {
                    setResult(vc, context, SBI_ERR_INVALID_PARAM, 0);
                }
            } else {
                setResult(vc, context, SBI_ERR_INVALID_ADDRESS, 0);
            }
        },
        interface.DIOSIX.UNMAP_CHILD_MEM => {
            if (g.space.translateGPA(a0) catch null) |hpa| {
                const uargs: *const interface.UnmapChildMemArgs = @ptrFromInt(hpa);
                if (uargs.size == 0 or (uargs.size % physmem.PageSize) != 0) {
                    setResult(vc, context, SBI_ERR_INVALID_PARAM, 0);
                    return;
                }
                g.space.unmap(uargs.parent_gpa, uargs.size);
                riscv.hfenceGvma();
                setResult(vc, context, SBI_SUCCESS, 0);
            } else {
                setResult(vc, context, SBI_ERR_INVALID_ADDRESS, 0);
            }
        },
        interface.DIOSIX.START => {
            if (g.space.translateGPA(a0) catch null) |hpa| {
                const sargs: *const interface.StartArgs = @ptrFromInt(hpa);
                const target_guest = g.getGuestByCid(sargs.child_id);
                if (target_guest) |child| {
                    if (!g.is_trusted and !g.is_root and child.parent != g) {
                        setResult(vc, context, SBI_ERR_DENIED, 0);
                        return;
                    }
                    child.resetForRun(sargs.entry_point, sargs.dtb_ptr);
                    if (child.vcores.start) |vc_node| {
                        scheduler.queue(vc_node.contents);
                        broadcastPhysicalIPI();
                    }
                    setResult(vc, context, SBI_SUCCESS, child.local_cid);
                } else {
                    setResult(vc, context, SBI_ERR_INVALID_PARAM, 0);
                }
            } else {
                setResult(vc, context, SBI_ERR_INVALID_ADDRESS, 0);
            }
        },
        interface.DIOSIX.NET_SEND => {
            if (g.space.translateGPA(a0) catch null) |hpa| {
                const pkt_len = @min(a1, guest.MAX_PACKET_LEN);
                if (pkt_len == 0) {
                    setResult(vc, context, SBI_ERR_INVALID_PARAM, 0);
                    return;
                }
                const pkt_data = @as([*]const u8, @ptrFromInt(hpa))[0..pkt_len];
                const dest_cid = a2;

                if (dest_cid == 0) {
                    // Broadcast packet: send to all peers
                    var it = g.children.start;
                    while (it) |node| {
                        deliverPacket(node.contents, pkt_data);
                        it = node.next;
                    }
                    if (g.parent) |p| {
                        deliverPacket(p, pkt_data);
                    }
                } else if (dest_cid == guest.CID_PARENT or (dest_cid == 1 and !g.is_root)) {
                    if (g.parent) |p| {
                        deliverPacket(p, pkt_data);
                    }
                } else if (dest_cid >= guest.CID_FIRST_CHILD) {
                    if (g.getGuestByCid(dest_cid)) |target| {
                        deliverPacket(target, pkt_data);
                    } else if (g.parent) |p| {
                        if (p.getGuestByCid(dest_cid)) |target| {
                            deliverPacket(target, pkt_data);
                        }
                    }
                }
                setResult(vc, context, SBI_SUCCESS, 0);
            } else {
                setResult(vc, context, SBI_ERR_INVALID_ADDRESS, 0);
            }
        },
        interface.DIOSIX.NET_RECV => {
            if (g.space.translateGPA(a0) catch null) |hpa| {
                const max_len = @min(a1, guest.MAX_PACKET_LEN);
                const out_buf = @as([*]u8, @ptrFromInt(hpa))[0..max_len];
                if (g.net_rx.pop(out_buf)) |copied| {
                    setResult(vc, context, SBI_SUCCESS, copied);
                } else {
                    setResult(vc, context, SBI_SUCCESS, 0);
                }
            } else {
                setResult(vc, context, SBI_ERR_INVALID_ADDRESS, 0);
            }
        },
        interface.DIOSIX.NET_POLL => {
            setResult(vc, context, SBI_SUCCESS, g.net_rx.count);
        },
        else => setResult(vc, context, SBI_ERR_NOT_SUPPORTED, 0),
    }
}

fn handleHSM(vc: *vcore.VirtualCore, sub_idx: usize, context: *riscv.ThreadContext, function: usize, a0: usize, a1: usize, a2: usize) void {
    _ = sub_idx;
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
                        target_vcpu.setReg(@intFromEnum(arch.Register.a0), target_hart);
                        target_vcpu.setReg(@intFromEnum(arch.Register.a1), opaque_param);
                        target_vcpu.privilege_mode = 1;
                        target_vcpu.priv_mode = 1;
                        target_vcpu.satp = 0;
                        target_vcpu.medeleg = 0xFFFF;
                        target_vcpu.mideleg = 0xFFFF;
                        target_vcpu.mstatus = (1 << riscv.SSTATUS.SPP_SHIFT) | riscv.SSTATUS.SPIE; // SPP=1, SPIE=1, SIE=0
                        target_vcpu.vstimecmp = std.math.maxInt(u64);
                        target_vcpu.clearMipBit(MIP_STIP_BIT);
                        target_vcpu.clearMipBit(MIP_SSIP_BIT);
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
                    target_vc.getNativeMachine().mstatus = (1 << riscv.MSTATUS.MPP_SHIFT) | riscv.MSTATUS.MPIE | riscv.MSTATUS.MPV | (3 << riscv.MSTATUS.FS_SHIFT);
                    target_vc.getNativeMachine().hstatus = riscv.HSTATUS.SPV | riscv.HSTATUS.SPVP;
                    target_vc.getNativeMachine().hedeleg = 0xb1fb;
                    target_vc.getNativeMachine().hideleg = 0x1666;
                    target_vc.getNativeMachine().hvip = 0;
                    if (target_vc.guest.space.mode == .h_paging) {
                        target_vc.getNativeMachine().hgatp = target_vc.guest.space.paging.?.hgatp(target_vc.guest.vmid);
                    }
                    target_vc.getNativeGuestState().vsstatus = riscv.SSTATUS.SPIE | (3 << riscv.MSTATUS.FS_SHIFT);
                    target_vc.getNativeGuestState().vsatp = 0;
                    target_vc.getNativeGuestState().vstimecmp = std.math.maxInt(u64);
                    target_vc.getNativeGuestState().vsenvcfg = riscv.ENVCFG.STCE | riscv.ENVCFG.CACHE_OPS_ALL;
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
            vc.state = .stopped;
            setResult(vc, context, interface.SUCCESS, 0);
            scheduler.yield(vc);
        },
        interface.HSM.HART_GET_STATUS => {
            const target_hart = a0;
            if (g.findVcore(target_hart)) |target_vc| {
                const status: usize = switch (target_vc.state) {
                    .ready, .running, .blocked => interface.HSM.STATUS_STARTED,
                    .stopped => interface.HSM.STATUS_STOPPED,
                };
                setResult(vc, context, interface.SUCCESS, status);
            } else {
                setResult(vc, context, interface.ERR_INVALID_PARAM, 0);
            }
        },
        interface.HSM.HART_SUSPEND => {
            vc.state = .blocked;
            setResult(vc, context, interface.SUCCESS, 0);
            scheduler.yield(vc);
        },
        else => setResult(vc, context, interface.ERR_NOT_SUPPORTED, 0),
    }
}

fn handleDebugConsole(vc: *vcore.VirtualCore, context: *riscv.ThreadContext, function: usize, a0: usize, a1: usize, a2: usize) void {
    // Only Root VM (guest_id == 1) has direct access to the physical host serial console.
    // Child guest VMs communicate out-of-band via virtual networking (diosix0 / SSH).
    if (vc.guest_id != 1) {
        switch (function) {
            interface.DBCN.CONSOLE_WRITE => setResult(vc, context, SBI_SUCCESS, a0),
            interface.DBCN.CONSOLE_READ => setResult(vc, context, SBI_SUCCESS, 0),
            interface.DBCN.CONSOLE_WRITE_BYTE => setResult(vc, context, SBI_SUCCESS, 0),
            else => setResult(vc, context, SBI_ERR_NOT_SUPPORTED, 0),
        }
        return;
    }

    const g = vc.getGuest();
    switch (function) {
        interface.DBCN.CONSOLE_WRITE => {
            // Cap bytes-per-call to prevent a guest from monopolizing the
            // hypervisor in this loop. The guest can make multiple calls.
            const num_bytes = if (a0 > DBCN_MAX_WRITE_BYTES) DBCN_MAX_WRITE_BYTES else a0;
            const gpa: usize = (a1 & RV32_WORD_MASK) | ((@as(usize, @intCast(a2)) & RV32_WORD_MASK) << RV32_HIGH_SHIFT);

            var written: usize = 0;
            var buf: [DBCN_CHUNK_BUFFER_SIZE]u8 = undefined;
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
                    debug.write(buf[0..buf_idx]);
                    buf_idx = 0;
                }
            }
            if (buf_idx > 0) {
                debug.write(buf[0..buf_idx]);
            }
            setResult(vc, context, SBI_SUCCESS, written);
        },
        interface.DBCN.CONSOLE_READ => {
            const num_bytes = a0;
            const gpa: usize = (a1 & RV32_WORD_MASK) | ((@as(usize, @intCast(a2)) & RV32_WORD_MASK) << RV32_HIGH_SHIFT);
            var read: usize = 0;
            while (read < num_bytes) : (read += 1) {
                const c = debug.getchar();
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
            debug.putchar(@truncate(a0));
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
            v.setGpr(@intFromEnum(arch.Register.a0), @truncate(@as(usize, @bitCast(err))));
            v.setGpr(@intFromEnum(arch.Register.a1), @truncate(val));
        }
    }
}

/// Terminate a guest. If the guest is the Root VM, the architecture requires
/// that the host is powered off (exit_code == 0) or rebooted (exit_code == 1).
fn terminateOrRestart(g: *guest.Guest, exit_code: usize) void {
    g.terminate();
    if (g.is_root) {
        if (exit_code == 0) {
            debug.printf("Root VM terminated with exit code 0. Powering off host.\n", .{});
            riscv.shutdown();
        } else {
            debug.printf("Root VM terminated with exit code {}. Rebooting host.\n", .{exit_code});
            riscv.reboot();
        }
    }
}

/// Send a physical IPI to all other physical cores to wake them from WFI.
/// This is necessary when a WFI-blocked vcore is woken and queued: since
/// running_on_cpu is null for blocked vcores, we can't target a specific
/// physical core. Broadcasting ensures an idle core picks up the vcore.
fn broadcastPhysicalIPI() void {
    const my_hart = riscv.getCPUContext().hardware_hart_id;
    for (riscv.cpu_to_hart_map) |hw_hart| {
        if (hw_hart == my_hart) continue; // Don't IPI ourselves
        if (riscv.CLINT.msip(hw_hart)) |ptr| {
            ptr.* = 1;
        }
    }
}

test "SBI Base extension dispatch" {
    const testing = std.testing;

    var phys_test = try physmem.initForTest(testing.allocator, 128);
    defer phys_test.deinit();

    const g = try guest.createGuest(testing.allocator, true, true, null, 0, 0, 0, .riscv64);
    defer g.deinit();

    var vc = vcore.VirtualCore.init(0, g, 0x80000000, 0, .normal);
    var ctx: riscv.ThreadContext = std.mem.zeroes(riscv.ThreadContext);

    // 1. Test GET_SPEC_VERSION (Base Ext 0x10, FID 0)
    ctx[@intFromEnum(arch.Register.a7)] = interface.EXT.BASE;
    ctx[@intFromEnum(arch.Register.a6)] = interface.BASE.GET_SPEC_VERSION;
    handle(&vc, 0, &ctx);
    try testing.expectEqual(@as(usize, 0), ctx[@intFromEnum(arch.Register.a0)]); // SUCCESS
    try testing.expectEqual(@as(usize, interface.SPEC_VERSION), ctx[@intFromEnum(arch.Register.a1)]);

    // 2. Test GET_IMPL_ID (Base Ext 0x10, FID 1)
    ctx[@intFromEnum(arch.Register.a7)] = interface.EXT.BASE;
    ctx[@intFromEnum(arch.Register.a6)] = interface.BASE.GET_IMPL_ID;
    handle(&vc, 0, &ctx);
    try testing.expectEqual(@as(usize, 0), ctx[@intFromEnum(arch.Register.a0)]); // SUCCESS
    try testing.expectEqual(@as(usize, interface.IMPL_ID), ctx[@intFromEnum(arch.Register.a1)]);

    // 3. Test PROBE_EXTENSION for Diosix Extension (0x0A000005)
    ctx[@intFromEnum(arch.Register.a7)] = interface.EXT.BASE;
    ctx[@intFromEnum(arch.Register.a6)] = interface.BASE.PROBE_EXTENSION;
    ctx[@intFromEnum(arch.Register.a0)] = interface.EXT.DIOSIX;
    handle(&vc, 0, &ctx);
    try testing.expectEqual(@as(usize, 0), ctx[@intFromEnum(arch.Register.a0)]); // SUCCESS
    try testing.expectEqual(@as(usize, 1), ctx[@intFromEnum(arch.Register.a1)]); // Available

    // 4. Test Unsupported extension ID
    ctx[@intFromEnum(arch.Register.a7)] = 0x99999999;
    ctx[@intFromEnum(arch.Register.a6)] = 0;
    handle(&vc, 0, &ctx);
    try testing.expectEqual(@as(usize, @bitCast(SBI_ERR_NOT_SUPPORTED)), ctx[@intFromEnum(arch.Register.a0)]);
}

test "SBI Diosix hypervisor extension get info and drop trust" {
    const testing = std.testing;

    var phys_test = try physmem.initForTest(testing.allocator, 128);
    defer phys_test.deinit();

    const g = try guest.createGuest(testing.allocator, true, true, null, 0, 0, 0, .riscv64);
    defer g.deinit();

    var vc = vcore.VirtualCore.init(0, g, 0x80000000, 0, .normal);
    var ctx: riscv.ThreadContext = std.mem.zeroes(riscv.ThreadContext);

    // Verify initial guest trust state
    try testing.expect(g.is_trusted);

    // 1. Test DROP_TRUST (FID 3)
    ctx[@intFromEnum(arch.Register.a7)] = interface.EXT.DIOSIX;
    ctx[@intFromEnum(arch.Register.a6)] = interface.DIOSIX.DROP_TRUST;
    handle(&vc, 0, &ctx);
    try testing.expectEqual(@as(usize, 0), ctx[@intFromEnum(arch.Register.a0)]); // SUCCESS
    try testing.expect(!g.is_trusted); // Trust successfully dropped

    // 2. Test Calling DROP_TRUST again when already untrusted -> still SUCCESS and remains untrusted
    handle(&vc, 0, &ctx);
    try testing.expectEqual(@as(usize, 0), ctx[@intFromEnum(arch.Register.a0)]);
    try testing.expect(!g.is_trusted);
}
