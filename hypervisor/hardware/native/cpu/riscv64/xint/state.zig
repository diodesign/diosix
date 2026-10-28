// Virtual core hardware state synchronization and physical core idle loop.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("../mod.zig");
const interrupt = @import("interrupt.zig");
const pcore = @import("../../../../../core/pcore.zig");
const vcore = @import("../../../../../core/vcore.zig");
const scheduler = @import("../../../../../core/scheduler.zig");
const config = @import("config");

pub fn parkStoppingCore(pcpu: *riscv.CpuContext) noreturn {
    if (riscv.CLINT.msip(pcpu.hardware_hart_id)) |ptr| {
        ptr.* = 0;
    }
    riscv.writeMie(0);
    @atomicStore(bool, &pcpu.is_parked, true, .release);
    while (true) {
        riscv.pause();
    }
}

/// Save the interrupted guest virtual core's architectural state from physical
/// hardware CSRs into `vc`.
pub fn saveGuestStateFromHardware(
    vc: *vcore.VirtualCore,
    context: *riscv.ThreadContext,
    pc: usize,
) void {
    @memcpy(vc.getNativeContext(), context);
    vc.getNativeMachine().mepc = pc;
    vc.getNativeMachine().mstatus = riscv.readMstatus();

    if (vc.exec_path == .native) {
        saveFpAndVectorState(vc);
        if (riscv.hasHExtension()) {
            vc.getNativeMachine().hstatus = riscv.readHstatus();
            vc.getNativeMachine().hvip = riscv.readHvip();
            riscv.saveVsState(vc.getNativeGuestState());
        } else {
            riscv.saveSState(vc.getNativeGuestState());
        }
    }
}

pub fn saveFpAndVectorState(vc: *vcore.VirtualCore) void {
    if (vc.exec_path != .native) return;

    const misa = riscv.readMisa();
    const mstatus_enable = riscv.MSTATUS.FS_DIRTY | riscv.MSTATUS.VS_DIRTY;
    riscv.writeMstatus(riscv.readMstatus() | mstatus_enable);

    if (comptime @import("builtin").is_test) {
        if ((misa & riscv.IsaExtension.d) != 0) {
            vc.exec_path.native.fp_state = riscv.mock.mock_hw_fp_state;
        }
        if ((misa & riscv.IsaExtension.v) != 0) {
            vc.exec_path.native.vec_state = riscv.mock.mock_hw_vec_state;
        }
        return;
    }

    if ((misa & riscv.IsaExtension.d) != 0) {
        const fp = &vc.exec_path.native.fp_state;
        asm volatile (
            \\.option push
            \\.option arch, +f, +d
            \\fsd f0, 0(a0); fsd f1, 8(a0)
            \\fsd f2, 16(a0); fsd f3, 24(a0)
            \\fsd f4, 32(a0); fsd f5, 40(a0)
            \\fsd f6, 48(a0); fsd f7, 56(a0)
            \\fsd f8, 64(a0); fsd f9, 72(a0)
            \\fsd f10, 80(a0); fsd f11, 88(a0)
            \\fsd f12, 96(a0); fsd f13, 104(a0)
            \\fsd f14, 112(a0); fsd f15, 120(a0)
            \\fsd f16, 128(a0); fsd f17, 136(a0)
            \\fsd f18, 144(a0); fsd f19, 152(a0)
            \\fsd f20, 160(a0); fsd f21, 168(a0)
            \\fsd f22, 176(a0); fsd f23, 184(a0)
            \\fsd f24, 192(a0); fsd f25, 200(a0)
            \\fsd f26, 208(a0); fsd f27, 216(a0)
            \\fsd f28, 224(a0); fsd f29, 232(a0)
            \\fsd f30, 240(a0); fsd f31, 248(a0)
            \\frcsr t0
            \\sd t0, 256(a0)
            \\.option pop
            :
            : [fp] "{a0}" (fp),
            : .{ .x5 = true, .memory = true });
    }

    if ((misa & riscv.IsaExtension.v) != 0) {
        const vec = &vc.exec_path.native.vec_state;
        asm volatile (
            \\.option push
            \\.option arch, +v
            \\csrr t0, vl
            \\sd t0, 1024(a0)
            \\csrr t0, vtype
            \\sd t0, 1032(a0)
            \\csrr t0, vcsr
            \\sd t0, 1040(a0)
            \\csrr t0, vstart
            \\sd t0, 1048(a0)
            \\csrr t1, vlenb
            \\slli t1, t1, 3
            \\mv t0, a0
            \\vs8r.v v0, (t0)
            \\add t0, t0, t1
            \\vs8r.v v8, (t0)
            \\add t0, t0, t1
            \\vs8r.v v16, (t0)
            \\add t0, t0, t1
            \\vs8r.v v24, (t0)
            \\.option pop
            :
            : [vec] "{a0}" (vec),
            : .{ .x5 = true, .x6 = true, .memory = true });
    }
}

pub fn restoreFpAndVectorState(vc: *const vcore.VirtualCore) void {
    if (vc.exec_path != .native) return;

    const misa = riscv.readMisa();
    const mstatus_enable = riscv.MSTATUS.FS_DIRTY | riscv.MSTATUS.VS_DIRTY;
    riscv.writeMstatus(riscv.readMstatus() | mstatus_enable);

    if (comptime @import("builtin").is_test) {
        if ((misa & riscv.IsaExtension.d) != 0) {
            riscv.mock.mock_hw_fp_state = vc.exec_path.native.fp_state;
        }
        if ((misa & riscv.IsaExtension.v) != 0) {
            riscv.mock.mock_hw_vec_state = vc.exec_path.native.vec_state;
        }
        return;
    }

    if ((misa & riscv.IsaExtension.d) != 0) {
        const fp = &vc.exec_path.native.fp_state;
        asm volatile (
            \\.option push
            \\.option arch, +f, +d
            \\fld f0, 0(a0); fld f1, 8(a0)
            \\fld f2, 16(a0); fld f3, 24(a0)
            \\fld f4, 32(a0); fld f5, 40(a0)
            \\fld f6, 48(a0); fld f7, 56(a0)
            \\fld f8, 64(a0); fld f9, 72(a0)
            \\fld f10, 80(a0); fld f11, 88(a0)
            \\fld f12, 96(a0); fld f13, 104(a0)
            \\fld f14, 112(a0); fld f15, 120(a0)
            \\fld f16, 128(a0); fld f17, 136(a0)
            \\fld f18, 144(a0); fld f19, 152(a0)
            \\fld f20, 160(a0); fld f21, 168(a0)
            \\fld f22, 176(a0); fld f23, 184(a0)
            \\fld f24, 192(a0); fld f25, 200(a0)
            \\fld f26, 208(a0); fld f27, 216(a0)
            \\fld f28, 224(a0); fld f29, 232(a0)
            \\fld f30, 240(a0); fld f31, 248(a0)
            \\ld t0, 256(a0)
            \\fscsr t0
            \\.option pop
            :
            : [fp] "{a0}" (fp),
            : .{ .x5 = true, .memory = true });
    }

    if ((misa & riscv.IsaExtension.v) != 0) {
        const vec = &vc.exec_path.native.vec_state;
        asm volatile (
            \\.option push
            \\.option arch, +v
            \\csrr t1, vlenb
            \\slli t1, t1, 3
            \\mv t0, a0
            \\vl8r.v v0, (t0)
            \\add t0, t0, t1
            \\vl8r.v v8, (t0)
            \\add t0, t0, t1
            \\vl8r.v v16, (t0)
            \\add t0, t0, t1
            \\vl8r.v v24, (t0)
            \\ld t0, 1024(a0)
            \\ld t1, 1032(a0)
            \\vsetvl zero, t0, t1
            \\ld t0, 1040(a0)
            \\csrw vcsr, t0
            \\ld t0, 1048(a0)
            \\csrw vstart, t0
            \\.option pop
            :
            : [vec] "{a0}" (vec),
            : .{ .x5 = true, .x6 = true, .memory = true });
    }
}

pub fn runIdleLoop(pcpu: *riscv.CpuContext) void {
    while (pcpu.active_vcore == null) {
        if (pcore.host_stopping.load(.acquire)) {
            parkStoppingCore(pcpu);
        }

        const mip_now = riscv.readMip();
        if ((mip_now & riscv.MIP.MSIP) != 0) {
            if (riscv.CLINT.msip(pcpu.hardware_hart_id)) |ptr| {
                ptr.* = 0;
            }
            if (riscv.hasHExtension()) {
                riscv.hfenceGvma();
            }
            pcpu.gstage_dirty = true;
        }
        const ext_pending =
            (mip_now & (riscv.MIP.SEIP | riscv.MIP.MEIP)) != 0;
        if (ext_pending) {
            _ = interrupt.deliverRootExternalIrq(pcpu);
        }

        const now_time = riscv.readTime();
        const timeslice_limit = now_time +% riscv.TIMESLICE_TICKS;
        const b_prev = pcpu.blocked_lock.lock();
        var min_timer: u64 = if (pcpu.blocked_queue.start != null)
            timeslice_limit
        else
            riscv.TIMER_INFINITY;
        var it = pcpu.blocked_queue.start;

        while (it) |node| {
            const next_it = node.next;
            const vc: *vcore.VirtualCore =
                @ptrCast(@alignCast(node.contents));

            if (!@atomicLoad(bool, &vc.wfi_blocked, .acquire) or
                vc.state == .stopped or
                vc.getGuest().state != .valid)
            {
                pcpu.blocked_queue.remove(node);
                vc.blocked_on_cpu = null;
                if (vc.getGuest().state != .valid) vc.state = .stopped;
                it = next_it;
                continue;
            }

            if (checkIdleVCoreWake(vc, now_time, &min_timer)) {
                pcpu.blocked_queue.remove(node);
                vc.blocked_on_cpu = null;
                @atomicStore(bool, &vc.wfi_blocked, false, .release);
                vc.state = .ready;
                scheduler.queue(vc);
            }

            it = next_it;
        }
        pcpu.blocked_lock.unlock(b_prev);

        scheduler.schedule();
        if (pcpu.active_vcore != null) break;

        if ((riscv.readMip() & riscv.MIP.MSIP) == 0) {
            if (ext_pending) {
                const ext_mask = ~@as(usize, riscv.MIE.MEIE | riscv.MIE.SEIE);
                riscv.writeMie(riscv.MIE.ALL_PHYSICAL & ext_mask);
                const ext_poll = now_time + riscv.EXT_IRQ_POLL_TICKS;
                if (ext_poll < min_timer) min_timer = ext_poll;
            } else {
                riscv.writeMie(riscv.MIE.ALL_PHYSICAL);
            }
            riscv.setTimer(min_timer);
            riscv.pause();
        }
    }
}

pub fn checkIdleVCoreWake(
    vc: *vcore.VirtualCore,
    now_time: u64,
    min_timer: *u64,
) bool {
    if (@atomicLoad(bool, &vc.pending_ipi, .acquire)) return true;

    if (vc.exec_path == .native) {
        if (vc.guest.is_root) {
            const blocked_mip = riscv.readMip();
            if ((blocked_mip & (riscv.MIP.SEIP | riscv.MIP.MEIP)) != 0) {
                vc.getNativeMachine().hvip |= riscv.HVIP.VSEIP;
                return true;
            }
        }
        const gs = vc.getNativeGuestState();
        const timer_armed = interrupt.isGuestTimerArmed(gs);
        const virt_mask: usize = riscv.HVIP.VSSIP | riscv.HVIP.VSEIP |
            (if (timer_armed) riscv.HVIP.VSTIP else 0);
        if ((vc.getNativeMachine().hvip & virt_mask) != 0) return true;

        if (vc.timer_scheduled) {
            if (now_time >= vc.timer_target) {
                vc.timer_scheduled = false;
                if (config.legacy_cpu or !riscv.riscv_supports_sstc) {
                    vc.getNativeMachine().hvip |= riscv.HVIP.VSTIP;
                }
                return true;
            } else if (vc.timer_target < min_timer.*) {
                min_timer.* = vc.timer_target;
            }
        }
        if (timer_armed) {
            if (now_time >= gs.vstimecmp) {
                if (config.legacy_cpu or !riscv.riscv_supports_sstc) {
                    vc.getNativeMachine().hvip |= riscv.HVIP.VSTIP;
                }
                return true;
            } else if (gs.vstimecmp < min_timer.*) {
                min_timer.* = gs.vstimecmp;
            }
        }
        return false;
    }

    if (vc.exec_path == .emulated) {
        if (vc.timer_scheduled) {
            if (now_time >= vc.timer_target) {
                vc.timer_scheduled = false;
                if (vc.exec_path.emulated.vcpu) |v| {
                    v.mip |= riscv.MIP.STIP;
                }
                return true;
            } else if (vc.timer_target < min_timer.*) {
                min_timer.* = vc.timer_target;
            }
        }
        return false;
    }

    return false;
}

/// Synchronize the virtual core's architectural state to physical hardware CSRs
/// before returning to guest mode via `mret`.
pub fn syncGuestStateToHardware(vc: *vcore.VirtualCore) void {
    const ms = vc.getNativeMachine();
    const gs = vc.getNativeGuestState();

    if (@atomicRmw(bool, &vc.pending_ipi, .Xchg, false, .acq_rel)) {
        ms.hvip |= riscv.HVIP.VSSIP;
    }

    ms.mstatus |= riscv.MSTATUS.VS_DIRTY |
        riscv.MSTATUS.FS_DIRTY |
        riscv.MSTATUS.TW;
    riscv.writeMepc(ms.mepc);
    riscv.writeMstatus(ms.mstatus);
    restoreFpAndVectorState(vc);

    if (riscv.hasHExtension()) {
        if (vc.guest.space.mode == .h_paging) {
            ms.hgatp = if (vc.guest.space.paging) |*p|
                p.hgatp(vc.guest.vmid)
            else
                0;
        }
        const old_hgatp = riscv.readHgatp();
        riscv.writeHstatus(ms.hstatus);
        riscv.writeHgatp(ms.hgatp);

        var hvip_val: usize = ms.hvip;
        if (!config.legacy_cpu and riscv.riscv_supports_sstc) {
            hvip_val &= ~@as(usize, riscv.HVIP.VSTIP);
        } else if (gs.vstimecmp != 0 and
            gs.vstimecmp != riscv.TIMER_INFINITY)
        {
            if (riscv.readTime() >= gs.vstimecmp) {
                hvip_val |= riscv.HVIP.VSTIP;
            } else {
                hvip_val &= ~@as(usize, riscv.HVIP.VSTIP);
            }
        }

        ms.hvip = hvip_val;
        riscv.writeHvip(hvip_val);

        interrupt.programHardwareTimerAndMie(vc, &hvip_val);

        riscv.writeHedeleg(ms.hedeleg);
        riscv.writeHideleg(ms.hideleg);
        riscv.writeHcounteren(riscv.MCOUNTEREN.DEFAULT_COUNTERS);
        riscv.restoreVsState(gs);
        const pcpu = pcore.this();
        if (ms.hgatp != old_hgatp or pcpu.gstage_dirty) {
            riscv.hfenceGvma();
            pcpu.gstage_dirty = false;
        }
    } else {
        var mip_val = riscv.readMip();
        if ((ms.hvip & riscv.HVIP.VSTIP) != 0) {
            mip_val |= riscv.MIP.STIP;
        } else {
            mip_val &= ~@as(usize, riscv.MIP.STIP);
        }

        if ((ms.hvip & riscv.HVIP.VSSIP) != 0) {
            mip_val |= riscv.MIP.SSIP;
        } else {
            mip_val &= ~@as(usize, riscv.MIP.SSIP);
        }

        if (gs.vstimecmp != 0 and gs.vstimecmp != riscv.TIMER_INFINITY) {
            if (riscv.readTime() >= gs.vstimecmp) {
                mip_val |= riscv.MIP.STIP;
            } else {
                mip_val &= ~@as(usize, riscv.MIP.STIP);
            }
        }

        riscv.writeMip(mip_val);
        riscv.restoreSState(gs);
        riscv.sfenceVma();
    }
}

test "state: save and restore hstatus, FP, and Vector registers per vCore" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    riscv.initMockHardware();
    const physmem = @import("../../../../../core/physmem.zig");
    var phys_test = try physmem.initForTest(testing.allocator, 2048);
    defer phys_test.deinit();
    const guest_mod = @import("../../../../../core/guest.zig");
    const g = try guest_mod.createGuest(
        testing.allocator,
        false,
        false,
        null,
        0,
        0,
        0,
        .riscv64,
    );
    defer g.deinit();

    var vc0 = vcore.VirtualCore.init(0, g, 0x80000000, 0x80001000, .normal);
    var vc1 = vcore.VirtualCore.init(1, g, 0x80000000, 0x80001000, .normal);
    var ctx = std.mem.zeroes(riscv.ThreadContext);
    riscv.writeHstatus(riscv.HSTATUS.SPV | riscv.HSTATUS.SPVP);

    // Populate hardware FP and Vector state while vc0 is active, then save.
    riscv.mock.mock_hw_fp_state.fregs[0] = 0x3ff0000000000000;
    riscv.mock.mock_hw_fp_state.fregs[31] = 0x400921fb54442d18;
    riscv.mock.mock_hw_fp_state.fcsr = 0x1f;
    riscv.mock.mock_hw_vec_state.vregs[0] = 0xa5;
    riscv.mock.mock_hw_vec_state.vregs[1023] = 0x5a;
    riscv.mock.mock_hw_vec_state.vl = 64;
    riscv.mock.mock_hw_vec_state.vtype = 0xd3; // e32, m8, ta, ma (vill=0)
    riscv.mock.mock_hw_vec_state.vcsr = 0x3;
    riscv.mock.mock_hw_vec_state.vstart = 4;

    saveGuestStateFromHardware(&vc0, &ctx, 0x80002000);
    try testing.expectEqual(
        @as(u64, riscv.HSTATUS.SPV | riscv.HSTATUS.SPVP),
        vc0.getNativeMachine().hstatus,
    );

    // Context-switch to vc1: hardware FP/Vector state must reset to vc1's
    // initial state (vtype = VTYPE_VILL_BIT) and not leak vc0's registers.
    syncGuestStateToHardware(&vc1);
    try testing.expectEqual(@as(u64, 0), riscv.mock.mock_hw_fp_state.fregs[0]);
    try testing.expectEqual(
        riscv.VTYPE_VILL_BIT,
        riscv.mock.mock_hw_vec_state.vtype,
    );

    // Mutate vc1's hardware FP/Vector state and save vc1.
    riscv.mock.mock_hw_fp_state.fregs[0] = 0xdeadbeefcafebabe;
    riscv.mock.mock_hw_vec_state.vl = 16;
    riscv.mock.mock_hw_vec_state.vtype = 0xc8;
    saveGuestStateFromHardware(&vc1, &ctx, 0x80003000);

    // Context-switch back to vc0 and verify vc0's FP/Vector state is intact.
    syncGuestStateToHardware(&vc0);
    try testing.expectEqual(
        @as(u64, 0x3ff0000000000000),
        riscv.mock.mock_hw_fp_state.fregs[0],
    );
    try testing.expectEqual(
        @as(u64, 0x400921fb54442d18),
        riscv.mock.mock_hw_fp_state.fregs[31],
    );
    try testing.expectEqual(@as(u64, 0x1f), riscv.mock.mock_hw_fp_state.fcsr);
    const vregs = &riscv.mock.mock_hw_vec_state.vregs;
    try testing.expectEqual(@as(u8, 0xa5), vregs[0]);
    try testing.expectEqual(@as(u8, 0x5a), vregs[1023]);
    try testing.expectEqual(@as(u64, 64), riscv.mock.mock_hw_vec_state.vl);
    try testing.expectEqual(@as(u64, 0xd3), riscv.mock.mock_hw_vec_state.vtype);
    try testing.expectEqual(@as(u64, 0x3), riscv.mock.mock_hw_vec_state.vcsr);
    try testing.expectEqual(@as(u64, 4), riscv.mock.mock_hw_vec_state.vstart);
}
