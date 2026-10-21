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
        if (riscv.hasHExtension()) {
            vc.getNativeMachine().hstatus = riscv.readHstatus();
            vc.getNativeMachine().hvip = riscv.readHvip();
            riscv.saveVsState(vc.getNativeGuestState());
        } else {
            riscv.saveSState(vc.getNativeGuestState());
        }
    }
}

pub fn runIdleLoop(pcpu: *riscv.CpuContext) void {
    while (pcpu.active_vcore == null) {
        if (pcore.host_stopping.load(.acquire)) {
            parkStoppingCore(pcpu);
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

        const msip_pending = (riscv.readMip() & riscv.MIP.MSIP) != 0;
        scheduler.schedule();
        if (pcpu.active_vcore != null) break;

        if (!msip_pending) {
            riscv.writeMie(riscv.MIE.ALL_PHYSICAL);
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
        const blocked_mip = riscv.readMip();
        if ((blocked_mip & (riscv.MIP.SEIP | riscv.MIP.MEIP)) != 0) {
            vc.getNativeMachine().hvip |= riscv.HVIP.VSEIP;
            return true;
        }
        const virt_mask =
            riscv.HVIP.VSSIP | riscv.HVIP.VSTIP | riscv.HVIP.VSEIP;
        if ((vc.getNativeMachine().hvip & virt_mask) != 0) return true;

        const vstc = vc.getNativeGuestState().vstimecmp;
        if (vstc != 0 and vstc != riscv.TIMER_INFINITY) {
            if (now_time >= vstc) {
                vc.getNativeMachine().hvip |= riscv.HVIP.VSTIP;
                return true;
            } else if (vstc < min_timer.*) {
                min_timer.* = vstc;
            }
        }
        return (now_time -% vc.last_queued_time) >= riscv.TIMESLICE_TICKS;
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
        return (now_time -% vc.last_queued_time) >= riscv.TIMESLICE_TICKS;
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

    if (riscv.hasHExtension()) {
        if (vc.guest.space.mode == .h_paging) {
            ms.hgatp = if (vc.guest.space.paging) |*p|
                p.hgatp(vc.guest.vmid)
            else
                0;
        }
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
        riscv.hfenceGvma();
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

test "state: saveGuestStateFromHardware captures hstatus" {
    std.testing.refAllDecls(@This());
    riscv.initMockHardware();
    const physmem = @import("../../../../../core/physmem.zig");
    var phys_test = try physmem.initForTest(std.testing.allocator, 2048);
    defer phys_test.deinit();
    const guest_mod = @import("../../../../../core/guest.zig");
    const g = try guest_mod.createGuest(
        std.testing.allocator,
        false,
        false,
        null,
        0,
        0,
        0,
        .riscv64,
    );
    defer g.deinit();

    var vc = vcore.VirtualCore.init(0, g, 0x80000000, 0x80001000, .normal);
    var ctx = std.mem.zeroes(riscv.ThreadContext);
    riscv.writeHstatus(riscv.HSTATUS.SPV | riscv.HSTATUS.SPVP);

    saveGuestStateFromHardware(&vc, &ctx, 0x80002000);
    try std.testing.expectEqual(
        @as(u64, riscv.HSTATUS.SPV | riscv.HSTATUS.SPVP),
        vc.getNativeMachine().hstatus,
    );
}
