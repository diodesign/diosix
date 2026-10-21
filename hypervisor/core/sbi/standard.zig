// Standard RISC-V SBI v2.0 extension handlers (IPI, RFENCE, HSM, DBCN).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("../../hardware/native/cpu/riscv64/mod.zig");
const vcore = @import("../vcore.zig");
const debug = @import("../debug.zig");
const scheduler = @import("../scheduler.zig");
const pcore = @import("../pcore.zig");
const glue = @import("../emulation.zig");
const sbi_core = @import("../sbi.zig");
const interface = @import("interface").sbi;
const arch = @import("interface").riscv;

pub fn handleLegacySendIpi(
    vc: *vcore.VirtualCore,
    context: *riscv.ThreadContext,
) void {
    const mask_ptr = context[@backingInt(arch.Register.a0)];
    var hart_mask: usize = 0;
    if (mask_ptr == 0) {
        hart_mask = std.math.maxInt(usize);
    } else if (vc.exec_path == .emulated) {
        if (vc.exec_path.emulated.engine) |eng| {
            const res = eng.tlb.readU32(@truncate(mask_ptr), eng.bus);
            if (res.trap == null) hart_mask = res.val;
        }
    } else if (riscv.hasHExtension()) {
        const pcpu = pcore.this();
        pcpu.probing_active = true;
        pcpu.probe_failed = false;
        defer pcpu.probing_active = false;
        var val: usize = 0;
        for (0..@sizeOf(usize)) |i| {
            const b = riscv.hlv_bu(mask_ptr +% i);
            if (pcpu.probe_failed) {
                val = 0;
                break;
            }
            val |= @as(usize, b) << @intCast(i * 8);
        }
        hart_mask = val;
    } else {
        const g_space = &vc.getGuest().space;
        hart_mask = g_space.readGuestStruct(usize, mask_ptr) catch 0;
    }
    const g = vc.getGuest();
    for (0..@bitSizeOf(usize)) |vid| {
        if ((hart_mask & (@as(usize, 1) << @intCast(vid))) != 0) {
            if (g.findVcore(vid)) |target_vc| {
                if (target_vc.exec_path == .emulated) {
                    if (target_vc.exec_path.emulated.vcpu) |v| {
                        v.setMipBit(sbi_core.MIP_SSIP_BIT);
                    }
                }
                _ = @atomicRmw(
                    bool,
                    &target_vc.pending_ipi,
                    .Xchg,
                    true,
                    .acq_rel,
                );
                if (target_vc.tryWake()) {
                    target_vc.blocked_on_cpu = null;
                    scheduler.queue(target_vc);
                }
                if (target_vc.running_on_cpu) |target_cpu| {
                    pcore.sendIpiToCpu(target_cpu);
                } else {
                    sbi_core.broadcastPhysicalIPI();
                }
            }
        }
    }
    sbi_core.setResult(vc, context, sbi_core.SBI_SUCCESS, 0);
}

fn sendIpiToTargetVcore(target_vc: *vcore.VirtualCore, broadcast: bool) void {
    if (target_vc.state == .stopped) return;
    if (target_vc.exec_path == .emulated) {
        if (target_vc.exec_path.emulated.vcpu) |v| {
            v.setMipBit(sbi_core.MIP_SSIP_BIT);
        }
    }
    _ = @atomicRmw(bool, &target_vc.pending_ipi, .Xchg, true, .acq_rel);
    var ipi_sent = false;
    if (target_vc.tryWake()) {
        scheduler.queue(target_vc);
        ipi_sent = true;
    }
    if (target_vc.running_on_cpu) |target_cpu| {
        if (target_cpu != pcore.this().cpu_core_id) {
            pcore.sendIpiToCpu(target_cpu);
            ipi_sent = true;
        } else if (!broadcast) {
            if (riscv.hasHExtension()) {
                riscv.writeHvip(riscv.readHvip() | riscv.HVIP.VSSIP);
            }
            ipi_sent = true;
        }
    }
    if (!ipi_sent) sbi_core.broadcastPhysicalIPI();
}

pub fn handleIPI(
    vc: *vcore.VirtualCore,
    context: *riscv.ThreadContext,
    hart_mask: usize,
    hart_mask_base: usize,
) void {
    const g = vc.getGuest();
    const base: usize = if (vc.exec_path == .emulated)
        (hart_mask_base & sbi_core.RV32_WORD_MASK)
    else
        hart_mask_base;
    if (base == sbi_core.RV32_WORD_MASK or
        hart_mask_base == std.math.maxInt(usize))
    {
        var it = g.vcores.start;
        while (it) |node| : (it = node.next) {
            if (node.contents.id == vc.id) continue;
            sendIpiToTargetVcore(node.contents, true);
        }
    } else {
        const mask: usize = if (vc.exec_path == .emulated)
            (hart_mask & sbi_core.RV32_WORD_MASK)
        else
            hart_mask;
        for (0..@bitSizeOf(usize)) |bit_pos| {
            if ((mask & (@as(usize, 1) << @intCast(bit_pos))) != 0) {
                const hid = std.math.add(usize, base, bit_pos) catch continue;
                if (g.findVcore(hid)) |target_vc| {
                    sendIpiToTargetVcore(target_vc, false);
                }
            }
        }
    }
    sbi_core.setResult(vc, context, sbi_core.SBI_SUCCESS, 0);
}

fn flushEmulatedVcoreTlb(
    self_vc: *vcore.VirtualCore,
    target_vc: *vcore.VirtualCore,
) void {
    if (target_vc == self_vc) {
        if (target_vc.exec_path.emulated.engine) |eng| eng.tlb.flush();
    } else if (target_vc.exec_path == .emulated) {
        if (target_vc.exec_path.emulated.vcpu) |v| v.setNeedsTlbFlush();
        if (target_vc.running_on_cpu) |target_cpu| {
            if (target_cpu != pcore.this().cpu_core_id) {
                pcore.sendIpiToCpu(target_cpu);
            }
        }
    }
}

pub fn handleRFENCE(
    vc: *vcore.VirtualCore,
    context: *riscv.ThreadContext,
    _: usize,
    hart_mask: usize,
    hart_mask_base: usize,
) void {
    const g = vc.getGuest();
    if (vc.exec_path == .emulated) {
        if (hart_mask_base == std.math.maxInt(usize) or
            (hart_mask_base & sbi_core.RV32_WORD_MASK) ==
                sbi_core.RV32_WORD_MASK)
        {
            var it = g.vcores.start;
            while (it) |node| : (it = node.next) {
                flushEmulatedVcoreTlb(vc, node.contents);
            }
        } else {
            const mask: usize = hart_mask & sbi_core.RV32_WORD_MASK;
            const base_val: usize = hart_mask_base & sbi_core.RV32_WORD_MASK;
            for (0..@bitSizeOf(usize)) |bit_pos| {
                if ((mask & (@as(usize, 1) << @intCast(bit_pos))) != 0) {
                    const hid = std.math.add(usize, base_val, bit_pos) catch
                        continue;
                    if (g.findVcore(hid)) |tvc| flushEmulatedVcoreTlb(vc, tvc);
                }
            }
        }
    } else {
        if (riscv.hasHExtension()) riscv.hfenceGvma() else riscv.sfenceVma();
        riscv.getCPUContext().gstage_dirty = false;
        if (hart_mask_base == std.math.maxInt(usize)) {
            sbi_core.broadcastPhysicalIPI();
        } else {
            for (0..@bitSizeOf(usize)) |bit_pos| {
                if ((hart_mask & (@as(usize, 1) << @intCast(bit_pos))) != 0) {
                    const hid = std.math.add(
                        usize,
                        hart_mask_base,
                        bit_pos,
                    ) catch continue;
                    if (g.findVcore(hid)) |tvc| {
                        if (tvc.running_on_cpu) |target_cpu| {
                            pcore.sendIpiToCpu(target_cpu);
                        } else {
                            sbi_core.broadcastPhysicalIPI();
                        }
                    }
                }
            }
        }
    }
    sbi_core.setResult(vc, context, sbi_core.SBI_SUCCESS, 0);
}

pub fn handleHSM(
    vc: *vcore.VirtualCore,
    _: usize,
    context: *riscv.ThreadContext,
    function: usize,
    a0: usize,
    a1: usize,
    a2: usize,
) void {
    const g = vc.getGuest();
    switch (function) {
        interface.HSM.HART_START => {
            if ((a1 & 1) != 0) {
                sbi_core.setResult(
                    vc,
                    context,
                    interface.ERR_INVALID_ADDRESS,
                    0,
                );
                return;
            }
            const target_vc = g.findVcore(a0) orelse {
                sbi_core.setResult(vc, context, interface.ERR_INVALID_PARAM, 0);
                return;
            };
            if (target_vc.state != .stopped) {
                sbi_core.setResult(
                    vc,
                    context,
                    interface.ERR_ALREADY_AVAILABLE,
                    0,
                );
                return;
            }
            if (target_vc.exec_path == .emulated) {
                target_vc.exec_path.emulated.entry = a1;
                if (target_vc.exec_path.emulated.vcpu == null) {
                    glue.init(target_vc) catch {
                        sbi_core.setResult(
                            vc,
                            context,
                            interface.ERR_FAILED,
                            0,
                        );
                        return;
                    };
                }
                if (target_vc.exec_path.emulated.vcpu) |tv| {
                    tv.pc = @truncate(a1);
                    tv.setReg(@backingInt(arch.Register.a0), a0);
                    tv.setReg(@backingInt(arch.Register.a1), a2);
                    tv.privilege_mode = arch.PRIV_SUPERVISOR;
                    tv.satp = 0;
                    tv.medeleg = 0xffff;
                    tv.mideleg = 0xffff;
                    tv.mstatus = (1 << riscv.SSTATUS.SPP_SHIFT) |
                        riscv.SSTATUS.SPIE;
                    tv.vstimecmp = riscv.TIMER_INFINITY;
                    tv.clearMipBit(sbi_core.MIP_STIP_BIT);
                    tv.clearMipBit(sbi_core.MIP_SSIP_BIT);
                    tv.running = true;
                }
            } else {
                target_vc.configureNativeState(a1, a2);
            }
            target_vc.state = .ready;
            scheduler.queue(target_vc);
            sbi_core.broadcastPhysicalIPI();
            sbi_core.setResult(vc, context, interface.SUCCESS, 0);
        },
        interface.HSM.HART_STOP, interface.HSM.HART_SUSPEND => {
            if (vc.exec_path == .native) {
                vc.getNativeMachine().mepc +=
                    sbi_core.ECALL_INSTRUCTION_SIZE_BYTES;
            }
            vc.state = if (function == interface.HSM.HART_STOP)
                .stopped
            else
                .blocked;
            sbi_core.setResult(vc, context, interface.SUCCESS, 0);
            scheduler.yield(vc);
        },
        interface.HSM.HART_GET_STATUS => {
            if (g.findVcore(a0)) |target_vc| {
                const status: usize = switch (target_vc.state) {
                    .ready, .running, .blocked => interface.HSM.STATUS_STARTED,
                    .stopped => interface.HSM.STATUS_STOPPED,
                };
                sbi_core.setResult(vc, context, interface.SUCCESS, status);
            } else {
                sbi_core.setResult(vc, context, interface.ERR_INVALID_PARAM, 0);
            }
        },
        else => sbi_core.setResult(vc, context, interface.ERR_NOT_SUPPORTED, 0),
    }
}

pub fn handleDebugConsole(
    vc: *vcore.VirtualCore,
    context: *riscv.ThreadContext,
    function: usize,
    a0: usize,
    a1: usize,
    a2: usize,
) void {
    if (!vc.guest.is_root) {
        switch (function) {
            interface.DBCN.CONSOLE_WRITE => {
                sbi_core.setResult(vc, context, sbi_core.SBI_SUCCESS, a0);
            },
            interface.DBCN.CONSOLE_READ,
            interface.DBCN.CONSOLE_WRITE_BYTE,
            => sbi_core.setResult(vc, context, sbi_core.SBI_SUCCESS, 0),
            else => sbi_core.setResult(
                vc,
                context,
                sbi_core.SBI_ERR_NOT_SUPPORTED,
                0,
            ),
        }
        return;
    }
    const g = vc.getGuest();
    const gpa: usize = if (vc.exec_path == .emulated or
        (a2 != 0 and a2 != std.math.maxInt(usize)))
        @truncate((a1 & sbi_core.RV32_WORD_MASK) |
            ((@as(u64, a2) & sbi_core.RV32_WORD_MASK) <<
                sbi_core.RV32_HIGH_SHIFT))
    else
        a1;

    switch (function) {
        interface.DBCN.CONSOLE_WRITE => {
            const num_bytes: usize = @min(a0, sbi_core.DBCN_MAX_WRITE_BYTES);
            _ = std.math.add(usize, gpa, num_bytes) catch {
                sbi_core.setResult(
                    vc,
                    context,
                    sbi_core.SBI_ERR_INVALID_ADDRESS,
                    0,
                );
                return;
            };
            var written: usize = 0;
            var buf: [sbi_core.DBCN_CHUNK_BUFFER_SIZE]u8 = undefined;
            while (written < num_bytes) {
                const chunk: usize = @min(num_bytes - written, buf.len);
                g.space.copyFromGuest(buf[0..chunk], gpa + written) catch {
                    sbi_core.setResult(
                        vc,
                        context,
                        sbi_core.SBI_ERR_INVALID_ADDRESS,
                        written,
                    );
                    return;
                };
                debug.write(buf[0..chunk]);
                written += chunk;
            }
            sbi_core.setResult(vc, context, sbi_core.SBI_SUCCESS, written);
        },
        interface.DBCN.CONSOLE_READ => {
            const num_bytes: usize = @min(a0, sbi_core.DBCN_MAX_WRITE_BYTES);
            _ = std.math.add(usize, gpa, num_bytes) catch {
                sbi_core.setResult(
                    vc,
                    context,
                    sbi_core.SBI_ERR_INVALID_ADDRESS,
                    0,
                );
                return;
            };
            var read: usize = 0;
            while (read < num_bytes) : (read += 1) {
                const c = debug.getchar();
                if (c < 0) break;
                const char_byte: [1]u8 = .{@truncate(@as(u16, @bitCast(c)))};
                g.space.copyToGuest(gpa + read, &char_byte) catch {
                    sbi_core.setResult(
                        vc,
                        context,
                        sbi_core.SBI_ERR_INVALID_ADDRESS,
                        read,
                    );
                    return;
                };
            }
            sbi_core.setResult(vc, context, sbi_core.SBI_SUCCESS, read);
        },
        interface.DBCN.CONSOLE_WRITE_BYTE => {
            debug.putchar(@truncate(a0));
            sbi_core.setResult(vc, context, sbi_core.SBI_SUCCESS, 0);
        },
        else => sbi_core.setResult(
            vc,
            context,
            sbi_core.SBI_ERR_NOT_SUPPORTED,
            0,
        ),
    }
}

test "SBI Standard HSM status query" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    const alloc = testing.allocator;
    const guest = @import("../guest.zig");
    const physmem = @import("../physmem.zig");
    var phys_test = try physmem.initForTest(alloc, 128);
    defer phys_test.deinit();

    const g = try guest.createGuest(alloc, true, true, null, 0, 0, 0, .riscv64);
    defer g.deinit();
    const vc = try g.addVcore(0, 0x80000000, 0, .normal, null);
    var ctx: riscv.ThreadContext = @splat(0);

    handleHSM(vc, 0, &ctx, interface.HSM.HART_GET_STATUS, 0, 0, 0);
    try testing.expectEqual(@as(usize, 0), ctx[@backingInt(arch.Register.a0)]);
    try testing.expectEqual(
        interface.HSM.STATUS_STOPPED,
        ctx[@backingInt(arch.Register.a1)],
    );

    vc.state = .ready;
    handleHSM(vc, 0, &ctx, interface.HSM.HART_GET_STATUS, 0, 0, 0);
    try testing.expectEqual(
        interface.HSM.STATUS_STARTED,
        ctx[@backingInt(arch.Register.a1)],
    );
}
