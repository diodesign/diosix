// Asynchronous physical interrupt handling and virtual injection on RISC-V.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const main = @import("../../../../../main.zig");
const debug = @import("../../../../../core/debug.zig");
const riscv = @import("../mod.zig");
const xint = @import("../xint.zig");
const pcore = @import("../../../../../core/pcore.zig");
const vcore = @import("../../../../../core/vcore.zig");
const scheduler = @import("../../../../../core/scheduler.zig");
const config = @import("config");

const EXT_IRQ_MIP_MASK: usize = riscv.MIP.SEIP | riscv.MIP.MEIP;

/// Check if a physical PLIC external interrupt has been claimed and deasserted,
/// clearing `VSEIP` and re-enabling physical external interrupts if so.
pub fn clearClaimedExternalIrq(pcpu: *riscv.CpuContext) bool {
    const mip_val = riscv.readMip();
    if ((mip_val & EXT_IRQ_MIP_MASK) != 0) return false;

    if (pcpu.active_vcore) |opaque_vc| {
        const vc: *vcore.VirtualCore = @ptrCast(@alignCast(opaque_vc));
        vc.getNativeMachine().hvip &= ~@as(usize, riscv.HVIP.VSEIP);
        if (riscv.hasHExtension()) {
            riscv.writeHvip(vc.getNativeMachine().hvip);
        }
    }
    if (main.global_root_vm) |g| {
        if (g.findVcore(pcpu.hardware_hart_id)) |vc| {
            vc.getNativeMachine().hvip &= ~@as(usize, riscv.HVIP.VSEIP);
        }
    }
    riscv.writeMie(riscv.MIE.ALL_PHYSICAL);
    return true;
}

/// Handle an asynchronous interrupt trapped to M-mode.
pub fn handleInterrupt(irq: xint.IRQ, context: *riscv.ThreadContext) void {
    _ = context;
    const pcpu = pcore.this();

    switch (irq.cause) {
        .machine_timer, .supervisor_timer => handleTimerInterrupt(pcpu),
        .machine_swi => handleSoftwareInterrupt(pcpu),
        .machine_interrupt, .supervisor_interrupt => {
            handleExternalInterrupt(pcpu);
        },
        else => {
            debug.printf(
                "Unhandled interrupt: 0x{x}\n",
                .{@backingInt(irq.cause)},
            );
        },
    }
}

fn handleTimerInterrupt(pcpu: *riscv.CpuContext) void {
    riscv.setTimer(riscv.TIMER_INFINITY);
    var next_timer: u64 = riscv.TIMER_INFINITY;

    if (!clearClaimedExternalIrq(pcpu)) {
        // Physical external interrupt is still pending on this hart.
        if (pcpu.active_vcore) |opaque_vc| {
            const vc: *vcore.VirtualCore = @ptrCast(@alignCast(opaque_vc));
            vc.getNativeMachine().hvip |= riscv.HVIP.VSEIP;
            if (riscv.hasHExtension()) {
                riscv.writeHvip(riscv.readHvip() | riscv.HVIP.VSEIP);
            }
        } else if (main.global_root_vm) |g| {
            if (g.findVcore(pcpu.hardware_hart_id)) |vc| {
                vc.getNativeMachine().hvip |= riscv.HVIP.VSEIP;
                if (vc.tryWake()) {
                    vc.blocked_on_cpu = null;
                    scheduler.queue(vc);
                }
            }
        }
        const ext_poll = riscv.readTime() + riscv.EXT_IRQ_POLL_TICKS;
        if (ext_poll < next_timer) next_timer = ext_poll;
    }

    // 1. Deliver to the active vCore if applicable.
    if (pcpu.active_vcore) |opaque_vc| {
        const vc: *vcore.VirtualCore = @ptrCast(@alignCast(opaque_vc));
        updateActiveVCoreTimer(vc, &next_timer);
    }

    // 2. Deliver to any blocked vCores whose timers expired.
    wakeExpiredBlockedVCores(pcpu, &next_timer);

    riscv.setTimer(next_timer);

    // Signal preemption to emulated vCPU or reschedule on timeslice expiry.
    if (pcpu.active_vcore) |opaque_vc| {
        const active_vc: *vcore.VirtualCore = @ptrCast(@alignCast(opaque_vc));
        if (active_vc.exec_path == .emulated) {
            active_vc.exec_path.emulated.preempt_pending = true;
        }
        const elapsed = riscv.readTime() -% active_vc.last_dispatched_time;
        if (elapsed >= riscv.TIMESLICE_TICKS) {
            scheduler.schedule();
        }
    } else {
        scheduler.schedule();
    }
}

fn updateActiveVCoreTimer(vc: *vcore.VirtualCore, next_timer: *u64) void {
    const now = riscv.readTime();
    if (vc.timer_scheduled) {
        if (now >= vc.timer_target) {
            if (vc.exec_path == .native and !riscv.riscv_supports_sstc) {
                vc.getNativeMachine().hvip |= riscv.HVIP.VSTIP;
            }
            vc.timer_scheduled = false;
        } else if (vc.timer_target < next_timer.*) {
            next_timer.* = vc.timer_target;
        }
    }

    if (vc.exec_path == .native) {
        const gs = vc.getNativeGuestState();
        if (!riscv.riscv_supports_sstc and
            gs.vstimecmp != 0 and
            gs.vstimecmp != riscv.TIMER_INFINITY)
        {
            if (now >= gs.vstimecmp) {
                vc.getNativeMachine().hvip |= riscv.HVIP.VSTIP;
            } else if (gs.vstimecmp < next_timer.*) {
                next_timer.* = gs.vstimecmp;
            }
        }
    }
}

const SSTC_WFI_POLL_TICKS: u64 = 5_000;

fn wakeExpiredBlockedVCores(pcpu: *riscv.CpuContext, next_timer: *u64) void {
    const b_timer_prev = pcpu.blocked_lock.lock();
    defer pcpu.blocked_lock.unlock(b_timer_prev);

    var it = pcpu.blocked_queue.start;
    while (it) |node| {
        const next_it = node.next;
        const vc: *vcore.VirtualCore = @ptrCast(@alignCast(node.contents));

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

        const now = riscv.readTime();
        var wake = false;
        if (vc.timer_scheduled) {
            if (now >= vc.timer_target) {
                if (vc.exec_path == .native and
                    (config.legacy_cpu or !riscv.riscv_supports_sstc))
                {
                    vc.getNativeMachine().hvip |= riscv.HVIP.VSTIP;
                } else if (vc.exec_path == .emulated) {
                    if (vc.exec_path.emulated.vcpu) |v| {
                        v.mip |= riscv.MIP.STIP;
                    }
                }
                vc.timer_scheduled = false;
                wake = true;
            } else if (vc.timer_target < next_timer.*) {
                next_timer.* = vc.timer_target;
            }
        }

        if (!wake and vc.exec_path == .native) {
            const gs = vc.getNativeGuestState();
            if (gs.vstimecmp != 0 and
                gs.vstimecmp != riscv.TIMER_INFINITY)
            {
                if (now >= gs.vstimecmp) {
                    if (config.legacy_cpu or !riscv.riscv_supports_sstc) {
                        vc.getNativeMachine().hvip |= riscv.HVIP.VSTIP;
                    }
                    wake = true;
                } else if (gs.vstimecmp < next_timer.*) {
                    next_timer.* = gs.vstimecmp;
                }
            }
            if (!wake and
                (now -% vc.last_queued_time >= riscv.TIMESLICE_TICKS))
            {
                wake = true;
            } else if (!wake and
                !config.legacy_cpu and
                riscv.riscv_supports_sstc)
            {
                const poll_target = now + SSTC_WFI_POLL_TICKS;
                if (poll_target < next_timer.*) next_timer.* = poll_target;
            }
        } else if (!wake and vc.exec_path == .emulated) {
            if (now -% vc.last_queued_time >= riscv.TIMESLICE_TICKS) {
                wake = true;
            }
        }

        if (wake) {
            pcpu.blocked_queue.remove(node);
            vc.blocked_on_cpu = null;
            @atomicStore(bool, &vc.wfi_blocked, false, .release);
            vc.state = .ready;
            scheduler.queue(vc);
        }

        it = next_it;
    }
}

fn handleSoftwareInterrupt(pcpu: *riscv.CpuContext) void {
    if (riscv.CLINT.msip(pcpu.hardware_hart_id)) |ptr| {
        ptr.* = 0;
    }
    if (riscv.hasHExtension()) {
        riscv.hfenceGvma();
    }
    pcpu.gstage_dirty = true;

    const b_swi_prev = pcpu.blocked_lock.lock();
    var it = pcpu.blocked_queue.start;
    while (it) |node| {
        const next_it = node.next;
        const vc: *vcore.VirtualCore = @ptrCast(@alignCast(node.contents));

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

        if (@atomicLoad(bool, &vc.pending_ipi, .acquire)) {
            pcpu.blocked_queue.remove(node);
            vc.blocked_on_cpu = null;
            @atomicStore(bool, &vc.wfi_blocked, false, .release);
            vc.state = .ready;
            scheduler.queue(vc);
        }
        it = next_it;
    }
    pcpu.blocked_lock.unlock(b_swi_prev);

    if (pcpu.active_vcore) |opaque_vc| {
        const active_vc: *vcore.VirtualCore = @ptrCast(@alignCast(opaque_vc));
        if (active_vc.exec_path == .emulated) {
            active_vc.exec_path.emulated.preempt_pending = true;
        } else {
            if (@atomicRmw(
                bool,
                &active_vc.pending_ipi,
                .Xchg,
                false,
                .acq_rel,
            )) {
                active_vc.getNativeMachine().hvip |= riscv.HVIP.VSSIP;
            }
            if (riscv.hasHExtension()) {
                riscv.writeHvip(active_vc.getNativeMachine().hvip);
            } else {
                const ssip_bit: usize =
                    if ((active_vc.getNativeMachine().hvip &
                        riscv.HVIP.VSSIP) != 0)
                        riscv.MIP.SSIP
                    else
                        0;
                riscv.writeMip(riscv.readMip() | ssip_bit);
            }
        }
    }

    scheduler.schedule();
}

fn handleExternalInterrupt(pcpu: *riscv.CpuContext) void {
    var target_vcore: ?*vcore.VirtualCore = null;
    if (pcpu.active_vcore) |opaque_vc| {
        target_vcore = @ptrCast(@alignCast(opaque_vc));
    } else if (main.global_root_vm) |g| {
        target_vcore = g.findVcore(pcpu.hardware_hart_id);
    }

    if (target_vcore) |tvc| {
        tvc.getNativeMachine().hvip |= riscv.HVIP.VSEIP;
        if (tvc.tryWake()) {
            tvc.blocked_on_cpu = null;
            scheduler.queue(tvc);
        }

        if (pcpu.active_vcore) |opaque_vc| {
            const active_vc: *vcore.VirtualCore =
                @ptrCast(@alignCast(opaque_vc));
            if (active_vc == tvc) {
                if (riscv.hasHExtension()) {
                    riscv.writeHvip(riscv.readHvip() | riscv.HVIP.VSEIP);
                }
            } else if (active_vc.exec_path == .emulated) {
                active_vc.exec_path.emulated.preempt_pending = true;
            }
        }

        if (tvc.running_on_cpu) |cpu| {
            if (cpu != pcpu.cpu_core_id) {
                pcore.sendIpiToCpu(cpu);
            }
        }
    }

    // Mask MEIE and SEIE in M-mode until the guest claims the PLIC interrupt.
    const ext_mask = ~@as(usize, riscv.MIE.MEIE | riscv.MIE.SEIE);
    riscv.writeMie(riscv.readMie() & ext_mask);
    riscv.setTimer(riscv.readTime() + riscv.EXT_IRQ_POLL_TICKS);

    if (pcpu.active_vcore == null) {
        scheduler.schedule();
    }
}

/// Program the physical hardware timer and external interrupt mask before
/// returning to a guest virtual core.
pub fn programHardwareTimerAndMie(
    vc: *vcore.VirtualCore,
    hvip_val: *usize,
) void {
    var ext_irq_pending = false;
    if (main.global_root_vm) |root_g| {
        if (root_g.findVcore(pcore.this().hardware_hart_id)) |target_vc| {
            if ((target_vc.getNativeMachine().hvip & riscv.HVIP.VSEIP) != 0) {
                ext_irq_pending = true;
            }
        }
    }
    if (!ext_irq_pending and (hvip_val.* & riscv.HVIP.VSEIP) == 0) {
        riscv.writeMie(riscv.MIE.ALL_PHYSICAL);
    } else {
        const mask = ~@as(usize, riscv.MIE.MEIE | riscv.MIE.SEIE);
        riscv.writeMie(riscv.MIE.ALL_PHYSICAL & mask);
    }

    var next_timer: u64 = riscv.TIMER_INFINITY;
    const now = riscv.readTime();
    const vstc = vc.getNativeGuestState().vstimecmp;
    if (vstc != 0 and vstc != riscv.TIMER_INFINITY) {
        if (now >= vstc) {
            if (config.legacy_cpu or !riscv.riscv_supports_sstc) {
                hvip_val.* |= riscv.HVIP.VSTIP;
                riscv.writeHvip(hvip_val.*);
            }
        } else if (config.legacy_cpu or !riscv.riscv_supports_sstc) {
            if (vstc < next_timer) next_timer = vstc;
        }
    }

    const b_scan_prev = pcore.this().blocked_lock.lock();
    var it = pcore.this().blocked_queue.start;
    while (it) |node| {
        const b_vc: *vcore.VirtualCore =
            @ptrCast(@alignCast(node.contents));
        if (b_vc.timer_scheduled and b_vc.timer_target < next_timer) {
            next_timer = b_vc.timer_target;
        }
        if (b_vc.exec_path == .native) {
            const b_gs = b_vc.getNativeGuestState();
            if (b_gs.vstimecmp != 0 and
                b_gs.vstimecmp != riscv.TIMER_INFINITY)
            {
                if (now >= b_gs.vstimecmp) {
                    if (config.legacy_cpu or !riscv.riscv_supports_sstc) {
                        b_vc.getNativeMachine().hvip |= riscv.HVIP.VSTIP;
                    }
                } else if (b_gs.vstimecmp < next_timer) {
                    next_timer = b_gs.vstimecmp;
                }
            }
        }
        it = node.next;
    }
    pcore.this().blocked_lock.unlock(b_scan_prev);

    if (ext_irq_pending or (hvip_val.* & riscv.HVIP.VSEIP) != 0) {
        const ext_poll_target = riscv.readTime() + riscv.EXT_IRQ_POLL_TICKS;
        if (ext_poll_target < next_timer) next_timer = ext_poll_target;
    }

    const timeslice_target = riscv.readTime() +% riscv.TIMESLICE_TICKS;
    if (next_timer == riscv.TIMER_INFINITY or next_timer > timeslice_target) {
        next_timer = timeslice_target;
    }
    riscv.setTimer(next_timer);
}

test "interrupt: clearClaimedExternalIrq re-enables MIE" {
    std.testing.refAllDecls(@This());
    riscv.initMockHardware();
    riscv.writeMip(0);
    riscv.writeMie(0);
    const cleared = clearClaimedExternalIrq(pcore.this());
    try std.testing.expect(cleared);
    try std.testing.expectEqual(riscv.MIE.ALL_PHYSICAL, riscv.readMie());
}
