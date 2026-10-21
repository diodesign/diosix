// High-level exception and interrupt (xint) handling on RISC-V.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const debug = @import("../../../../core/debug.zig");
const riscv = @import("mod.zig");
const pcore = @import("../../../../core/pcore.zig");
const vcore = @import("../../../../core/vcore.zig");
const scheduler = @import("../../../../core/scheduler.zig");
const config = @import("config");

pub const csr_emu = @import("xint/csr.zig");
pub const exception = @import("xint/exception.zig");
pub const interrupt = @import("xint/interrupt.zig");
pub const state = @import("xint/state.zig");

pub const parkStoppingCore = state.parkStoppingCore;
pub const saveGuestStateFromHardware = state.saveGuestStateFromHardware;
pub const runIdleLoop = state.runIdleLoop;
pub const checkIdleVCoreWake = state.checkIdleVCoreWake;
pub const syncGuestStateToHardware = state.syncGuestStateToHardware;

extern fn hw_xint_init() void;

/// Initialize hardware-dependent xint handling on the calling CPU core.
pub fn init() void {
    hw_xint_init();

    // Keep physical interrupts in M-mode so the hypervisor can handle core
    // wakeups and virtual interrupt injection.
    riscv.writeMideleg(0);
    riscv.writeMie(riscv.MIE.ALL_PHYSICAL);
    riscv.writeMcounteren(riscv.MCOUNTEREN.DEFAULT_COUNTERS);

    // Enable physical Vector (VS) and Floating-point (FS) extensions (Dirty)
    // and set TW so VS-mode WFI traps to M-mode.
    var mstatus = riscv.readMstatus();
    mstatus |= riscv.MSTATUS.VS_DIRTY | riscv.MSTATUS.FS_DIRTY;
    mstatus |= riscv.MSTATUS.TW;
    riscv.writeMstatus(mstatus);
}

/// Configure environment and state enables on the calling CPU core once
/// global probed feature flags are initialized and stable.
pub fn initCpuFeatures() void {
    if (config.legacy_cpu) return;

    var envcfg_val: usize = riscv.ENVCFG.CACHE_OPS_ALL;
    if (riscv.riscv_supports_sstc) {
        envcfg_val |= riscv.ENVCFG.STCE;
    }

    if (riscv.riscv_supports_smstateen) {
        const stateen_base = riscv.STATEEN.BASE_FEATURES;
        riscv.writeMstateen0(stateen_base | riscv.STATEEN.SE0);
        if (riscv.hasHExtension()) {
            riscv.writeHstateen0(stateen_base);
        }
    }

    if (envcfg_val != 0) {
        riscv.writeMenvcfg(envcfg_val);
        if (riscv.hasHExtension()) {
            riscv.writeHenvcfg(envcfg_val);
        }
    }

    if (!config.legacy_cpu and riscv.riscv_supports_sstc) {
        riscv.writeStimecmp(riscv.TIMER_INFINITY);
    }

    // Delegate virtual supervisor interrupts (VSSIP, VSTIP, VSEIP) to VS-mode
    // while keeping physical interrupts in M-mode.
    const current_mideleg = riscv.readMideleg();
    const virt_sip_mask =
        riscv.HVIP.VSSIP | riscv.HVIP.VSTIP | riscv.HVIP.VSEIP;
    const phys_sip_mask = riscv.MIP.SSIP | riscv.MIP.STIP | riscv.MIP.SEIP;
    riscv.writeMideleg((current_mideleg & ~phys_sip_mask) | virt_sip_mask);
}

pub const Type = enum {
    exception,
    interrupt,
};

pub const Severity = enum {
    fatal,
    non_fatal,
};

pub const Cause = riscv.Cause;

pub const IRQ = struct {
    severity: Severity,
    privilege_mode: riscv.PrivilegeMode,
    irq_type: Type,
    cause: Cause,
    pc: usize,
    sp: usize,
    val: usize,
};

const MAX_TRAP_LOGS = 100;
const TRAP_LOOP_WARN_THRESHOLD: usize = 2;
const TRAP_LOOP_HARD_LIMIT: usize = 64;

pub var total_trap_count: usize = 0;

/// Decode `mcause` and return an `IRQ` structure.
fn dispatch(context: *riscv.ThreadContext) IRQ {
    const mcause = riscv.readMcause();
    const mepc = riscv.readMepc();
    const sp = context[@backingInt(riscv.Register.sp)];

    const is_interrupt = (mcause & Cause.INTERRUPT_BIT) != 0;
    const cause_type: Type = if (is_interrupt) .interrupt else .exception;
    const mtval = riscv.readMtval();
    const cause = riscv.toCause(mcause);

    const irq = IRQ{
        .severity = if (cause_type == .interrupt) .non_fatal else .fatal,
        .privilege_mode = riscv.getPreviousPrivilege(),
        .irq_type = cause_type,
        .cause = cause,
        .pc = mepc,
        .sp = sp,
        .val = mtval,
    };

    if (irq.cause == .unknown) {
        debug.printf(
            "!!! UNKNOWN TRAP on Core {}: mcause=0x{x} mtval=0x{x} " ++
                "mepc=0x{x} mstatus=0x{x}\n",
            .{
                pcore.this().cpu_core_id,
                mcause,
                mtval,
                mepc,
                riscv.readMstatus(),
            },
        );
    }

    const cpu = pcore.this();
    var active_stopped = false;
    if (cpu.active_vcore) |vc_raw| {
        const vc_chk: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
        if (vc_chk.state == .stopped or vc_chk.getGuest().state != .valid) {
            vc_chk.state = .stopped;
            active_stopped = true;
        }
    }

    const is_ecall = switch (irq.cause) {
        .virtual_supervisor_environment_call,
        .supervisor_environment_call,
        .user_environment_call,
        .machine_environment_call,
        => true,
        else => false,
    };

    if (irq.privilege_mode != .machine and
        !active_stopped and
        !is_ecall and
        !is_interrupt and
        cpu.last_trap_pc == irq.pc and
        cpu.last_trap_val == irq.val)
    {
        cpu.trap_loop_count += 1;
        if (cpu.trap_loop_count > TRAP_LOOP_HARD_LIMIT) {
            debug.printf(
                "!!! TRAP LOOP EXCEEDED HARD LIMIT on Core {}: pc=0x{x} " ++
                    "cause={s} count={} — terminating guest\n",
                .{
                    cpu.cpu_core_id,
                    irq.pc,
                    @tagName(irq.cause),
                    cpu.trap_loop_count,
                },
            );
            if (cpu.active_vcore) |vc_raw| {
                const vc_term: *vcore.VirtualCore =
                    @ptrCast(@alignCast(vc_raw));
                vc_term.getGuest().terminate();
                vc_term.state = .stopped;
            }
            cpu.trap_loop_count = 0;
        } else if (cpu.trap_loop_count > TRAP_LOOP_WARN_THRESHOLD) {
            debug.printf(
                "!!! LOOP DETECTED on Core {}: pc=0x{x} cause={s} count={}\n",
                .{
                    cpu.cpu_core_id,
                    irq.pc,
                    @tagName(irq.cause),
                    cpu.trap_loop_count,
                },
            );
        }
    } else {
        cpu.last_trap_pc = irq.pc;
        cpu.last_trap_val = irq.val;
        if (!is_ecall and !is_interrupt) {
            cpu.trap_loop_count = 0;
        }
    }

    if (cpu.trap_count < MAX_TRAP_LOGS) {
        cpu.trap_count += 1;
    }

    return irq;
}

/// Centralized high-level entry point for handling exceptions and interrupts.
pub export fn xint_handler(context: *riscv.ThreadContext) void {
    if (builtin.is_test) return;

    const pcpu = pcore.this();
    pcpu.in_m_mode = true;

    if (pcore.host_stopping.load(.acquire)) {
        parkStoppingCore(pcpu);
    }

    const irq = dispatch(context);

    const is_guest = irq.privilege_mode != .machine;
    if (is_guest) {
        if (pcpu.active_vcore) |vc_raw| {
            const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
            saveGuestStateFromHardware(vc, context, irq.pc);
        }
    }

    _ = interrupt.clearClaimedExternalIrq(pcpu);

    var skip_guest_exception = false;
    if (is_guest) {
        if (pcpu.active_vcore) |vc_raw| {
            const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
            if (vc.state == .stopped or vc.getGuest().state != .valid) {
                vc.state = .stopped;
                skip_guest_exception = true;
            }
        }
    }

    switch (irq.irq_type) {
        .exception => {
            if (!skip_guest_exception) {
                exception.handleException(irq, context);
            }
        },
        .interrupt => interrupt.handleInterrupt(irq, context),
    }

    if (!is_guest and pcpu.probe_failed) {
        return;
    }

    if (is_guest) {
        if (pcpu.active_vcore) |vc_raw| {
            const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
            if (vc.state == .stopped or vc.getGuest().state != .valid) {
                vc.state = .stopped;
                scheduler.schedule();
            }
        }
    }

    if (pcpu.active_vcore == null) {
        runIdleLoop(pcpu);
    }

    if (pcpu.active_vcore) |vc_raw| {
        const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
        @memcpy(context, vc.getNativeContext());
        pcore.contextSwitch(vc);

        if (vc.exec_path == .native) {
            syncGuestStateToHardware(vc);
        } else if (vc.exec_path == .emulated) {
            vc.getNativeMachine().mstatus |=
                riscv.MSTATUS.VS_DIRTY |
                riscv.MSTATUS.FS_DIRTY |
                riscv.MSTATUS.TW;
            riscv.writeMstatus(vc.getNativeMachine().mstatus);
            riscv.writeMepc(vc.getNativeMachine().mepc);
        }
        pcpu.in_m_mode = false;
    }
}

test {
    std.testing.refAllDecls(@This());
    _ = csr_emu;
    _ = exception;
    _ = interrupt;
    _ = state;
}
