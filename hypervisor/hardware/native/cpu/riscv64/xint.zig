// High-level exception and interrupt (xint) handling on RISC-V.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const main = @import("../../../../main.zig");
const builtin = @import("builtin");
const debug = @import("../../../../core/debug.zig");
const riscv = @import("mod.zig");
const pcore = @import("../../../../core/pcore.zig");
const vcore = @import("../../../../core/vcore.zig");
const sbi = @import("../../../../core/sbi.zig");
const vm_space = @import("../../../../core/vm.zig");
const scheduler = @import("../../../../core/scheduler.zig");
const emu_vcpu = @import("emulation").vcpu;
const config = @import("config");

fn rawPrintChar(c: u8) void {
    debug.hw_putchar(c);
}

fn rawPrintHex(val: usize) void {
    const chars = "0123456789abcdef";
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        rawPrintChar(chars[(val >> @intCast(i * 4)) & 0xf]);
    }
}

extern fn hw_xint_init() void;

// Initialize hardware-dependent xint handling.
pub fn init() void {
    hw_xint_init();


    // Do not delegate physical interrupts to S-mode, as the hypervisor needs to handle them in M-mode.
    // Especially stimecmp (Sstc) timer interrupts must trap to M-mode.
    riscv.writeMideleg(0);
    // Enable physical timer, software, and external interrupts (both machine and supervisor mode)
    riscv.writeMie(riscv.MIE.ALL_PHYSICAL);

    // Enable M-mode delegation of cycle, time, and instret counters
    // to lower privilege modes (HS, VS, VU, U).
    riscv.writeMcounteren(riscv.MCOUNTEREN.DEFAULT_COUNTERS);

    // Enable physical Vector (VS) and Floating-point (FS) extensions (set to 3 = Dirty)
    var mstatus = riscv.readMstatus();
    mstatus |= (3 << riscv.MSTATUS.VS_SHIFT) | (3 << riscv.MSTATUS.FS_SHIFT);
    riscv.writeMstatus(mstatus);
}

// Configure environment and state enables on the calling CPU core once
// the global probed features flags are initialized and stable.
// This must be called by every CPU core.
pub fn initCpuFeatures() void {
    if (config.legacy_cpu) return;

    var envcfg_val: usize = 0;
    
    if (riscv.riscv_supports_sstc) {
        // Enable STCE to allow supervisor/guest timer compare registers (stimecmp/vstimecmp)
        envcfg_val |= riscv.ENVCFG.STCE;
    }
    
    if (riscv.riscv_supports_smstateen) {
        // Enable Cache Block Operations: CBZE (bit 7), CBCFE (bit 6), and CBIE (bits 4-5) = 240 (0xF0).
        envcfg_val |= riscv.ENVCFG.CACHE_OPS_ALL;
        
        // Enable state-enables for AIA, IMSIC, CSRIND, and ENVCFG to delegate native register access
        const stateen_base = riscv.STATEEN.BASE_FEATURES;
        
        // For mstateen0 (0x30c), we also enable bit 63 (SE0) to control/enable lower-level stateen.
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

    // Initialize the physical supervisor timer (stimecmp) to infinity so it doesn't 
    // immediately fire a physical STIP trap storm. The hypervisor will program this
    // dynamically when it needs to wake up from WFI.
    if (!config.legacy_cpu and riscv.riscv_supports_sstc) {
        riscv.writeStimecmp(std.math.maxInt(u64));
    }

    // For PMP fallback guests (native without H-extension), we must delegate supervisor
    // interrupts directly to S-mode since the guest runs natively in S-mode.
    if (!riscv.hasHExtension()) {
        const current_mideleg = riscv.readMideleg();
        const sip_mask = (1 << 1) | (1 << 5) | (1 << 9); // SSIP, STIP, SEIP
        riscv.writeMideleg(current_mideleg | sip_mask);
    }
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
const TRAP_LOOP_HARD_LIMIT: usize = 64;

pub var total_trap_count: usize = 0;

// Diagnostic trap counters per-cause (temporary for debugging multi-core stall)
var diag_ecall_count: usize = 0;
var diag_timer_count: usize = 0;
var diag_swi_count: usize = 0;
var diag_gpf_count: usize = 0;
var diag_wfi_count: usize = 0;
var diag_other_count: usize = 0;
var diag_last_report: usize = 0;

// Decode mcause and return an IRQ structure.
fn dispatch(context: *riscv.ThreadContext) IRQ {
    const mcause = riscv.readMcause();
    const mepc = riscv.readMepc();
    const sp = context[@intFromEnum(riscv.Register.sp)];

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

    // Explicitly handle unknown/unexpected traps with more verbosity
    if (irq.cause == .unknown) {
        debug.printf("!!! UNKNOWN TRAP on Core {}: mcause=0x{x} mtval=0x{x} mepc=0x{x} mstatus=0x{x}\n", .{
            pcore.this().cpu_core_id,
            mcause,
            mtval,
            riscv.readMepc(),
            riscv.readMstatus(),
        });
    }

    const cpu = pcore.this();
    const is_ecall = (irq.cause == .virtual_supervisor_environment_call or irq.cause == .supervisor_environment_call or irq.cause == .user_environment_call or irq.cause == .machine_environment_call);
    if (irq.privilege_mode == .machine and !is_ecall and !is_interrupt and cpu.last_trap_pc == irq.pc and cpu.last_trap_val == irq.val) {
        cpu.trap_loop_count += 1;
        if (cpu.trap_loop_count > TRAP_LOOP_HARD_LIMIT) {
            debug.printf("!!! TRAP LOOP EXCEEDED HARD LIMIT on Core {}: pc=0x{x} cause={s} count={} — terminating guest\n", .{ cpu.cpu_core_id, irq.pc, @tagName(irq.cause), cpu.trap_loop_count });
            // Terminate the offending guest to reclaim the core.
            const term_cpu = pcore.this();
            if (term_cpu.active_vcore) |vc_raw| {
                const vc_term: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
                vc_term.getGuest().terminate();
                term_cpu.active_vcore = null;
            }
            cpu.trap_loop_count = 0;
        } else if (cpu.trap_loop_count > 2) {
            if (cpu.active_vcore) |vc_raw_diag| {
                const vc_diag: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw_diag));
                switch (vc_diag.exec_path) {
                    .native => |n| {
                        debug.printf("!!! LOOP DETECTED on Core {}: pc=0x{x} cause={s} count={} vstvec=0x{x} vsepc=0x{x} mepc=0x{x}\n", .{ cpu.cpu_core_id, irq.pc, @tagName(irq.cause), cpu.trap_loop_count, n.guest_state.vstvec, n.guest_state.vsepc, n.machine.mepc });
                    },
                    .emulated => {
                        debug.printf("!!! LOOP DETECTED on emulated Core {}: pc=0x{x} cause={s} count={}\n", .{ cpu.cpu_core_id, irq.pc, @tagName(irq.cause), cpu.trap_loop_count });
                    },
                }
            } else {
                debug.printf("!!! LOOP DETECTED on Core {}: pc=0x{x} cause={s} count={}\n", .{ cpu.cpu_core_id, irq.pc, @tagName(irq.cause), cpu.trap_loop_count });
            }
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

// Our centralized high-level entry point for handling xints.
pub export fn xint_handler(context: *riscv.ThreadContext) void {
    if (builtin.is_test) return;


    const pcpu = pcore.this();
    pcpu.in_m_mode = true; // Trap entry is always in M-mode
    const irq = dispatch(context);
    if (pcpu.active_vcore) |vc_raw| {
        if (@intFromPtr(vc_raw) & 7 != 0) {
            @import("../../../../core/debug.zig").printf("!!! xint_handler misaligned pcpu 0x{x} vc_raw 0x{x}\n", .{@intFromPtr(pcpu), @intFromPtr(vc_raw)});
        }
        const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
        if (vc.exec_path == .emulated) {
            // Emulated core trap
        }
    }



    // If we're coming from a guest or emulator, save its context
    var is_guest = irq.privilege_mode != .machine;
    if (pcpu.active_vcore) |vc_raw| {
        const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
        if (vc.exec_path == .emulated) is_guest = true;
    }

    if (is_guest) {
        if (pcpu.active_vcore) |vc_raw| {
            const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
            if (vc.exec_path == .native) {
                @memcpy(vc.getNativeContext(), context);
                vc.getNativeMachine().mepc = irq.pc;
                vc.getNativeMachine().mstatus = riscv.readMstatus();
                if (riscv.hasHExtension()) {
                    vc.getNativeMachine().hvip = riscv.readHvip();
                    const gs = vc.getNativeGuestState();
                    gs.vsstatus = riscv.readVsstatus();
                    gs.vsie = riscv.readVsie();
                    gs.vstvec = riscv.readVstvec();
                    gs.vsscratch = riscv.readVsscratch();
                    gs.vsepc = riscv.readVsepc();
                    gs.vscause = riscv.readVscause();
                    gs.vstval = riscv.readVstval();
                    gs.vsatp = riscv.readVsatp();
                    if (!config.legacy_cpu) {
                        if (riscv.riscv_supports_sstc) gs.vstimecmp = riscv.readVstimecmp();
                        if (riscv.riscv_supports_smstateen) gs.vsenvcfg = riscv.readVsenvcfg();
                    }
                } else {
                    const gs = vc.getNativeGuestState();
                    gs.vsstatus = riscv.readSstatus();
                    gs.vsie = riscv.readSie();
                    gs.vstvec = riscv.readStvec();
                    gs.vsscratch = riscv.readSscratch();
                    gs.vsepc = riscv.readSepc();
                    gs.vscause = riscv.readScause();
                    gs.vstval = riscv.readStval();
                    gs.vsatp = riscv.readSatp();
                    if (!config.legacy_cpu) {
                        if (riscv.riscv_supports_sstc) gs.vstimecmp = riscv.readVstimecmp();
                        if (riscv.riscv_supports_smstateen) gs.vsenvcfg = riscv.readSenvcfg();
                    }
                }
            } else if (vc.exec_path == .emulated) {
                @memcpy(vc.getNativeContext(), context);
                vc.getNativeMachine().mepc = irq.pc;
                vc.getNativeMachine().mstatus = riscv.readMstatus();
            }
        }
    }

    switch (irq.irq_type) {
        .exception => handle_exception(irq, context),
        .interrupt => handle_interrupt(irq, context),
    }

    // If the trap came from a guest (not machine mode), handle rescheduling
    if (is_guest) {
        // If the active vcore was stopped (e.g., guest VM exited/terminated), reschedule immediately.
        if (pcpu.active_vcore) |vc_raw| {
            const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
            if (vc.state == .stopped) {
                scheduler.schedule();
            }
        }

        // If there is no active vcore to run, enter a low-power scheduling loop in machine mode
        // until a virtual core becomes ready (e.g. via timer or hardware interrupt).
        while (pcpu.active_vcore == null) {
            const now_time = riscv.readTime();
            const timeslice_limit = now_time +% riscv.TIMESLICE_TICKS;
            var min_timer: u64 = if (pcpu.blocked_queue.start != null) timeslice_limit else ~@as(u64, 0);
            var it = pcpu.blocked_queue.start;
            
            while (it) |node| {
                const next_it = node.next;
                const vc: *vcore.VirtualCore = @ptrCast(@alignCast(node.contents));
                
                // If it was woken up by another vCore on the same CPU, remove it from the blocked queue
                if (!@atomicLoad(bool, &vc.wfi_blocked, .acquire)) {
                    pcpu.blocked_queue.remove(node);
                    it = next_it;
                    continue;
                }

                var wake = false;
                
                // Check pending IPIs
                if (@atomicLoad(bool, &vc.pending_ipi, .acquire)) {
                    wake = true;
                } else if (vc.exec_path == .native) {
                    // Check unhandled hardware virtual interrupts (VSSIP, VSTIP, VSEIP)
                    const virt_mask = riscv.HVIP.VSSIP | riscv.HVIP.VSTIP | riscv.HVIP.VSEIP;
                    if ((vc.getNativeMachine().hvip & virt_mask) != 0) wake = true;
                }
                
                // Check Native Timer (Sstc hardware or software emulated)
                if (!wake and vc.exec_path == .native) {
                    const vstc = vc.getNativeGuestState().vstimecmp;
                    if (vstc != 0 and vstc != riscv.TIMER_INFINITY) {
                        if (now_time >= vstc) {
                            vc.getNativeMachine().hvip |= riscv.HVIP.VSTIP;
                            wake = true;
                        } else if (vstc < min_timer) {
                            min_timer = vstc;
                        }
                    }
                    if (!wake and (now_time -% vc.last_queued_time >= riscv.TIMESLICE_TICKS)) {
                        // Spurious WFI wakeup after timeslice to prevent spinlock deadlocks
                        wake = true;
                    }
                }

                // Check Emulated Guest Timer
                if (!wake and vc.exec_path == .emulated) {
                    if (vc.timer_scheduled) {
                        if (now_time >= vc.timer_target) {
                            wake = true;
                            vc.timer_scheduled = false;
                            if (vc.exec_path.emulated.vcpu) |v| {
                                v.mip |= (1 << 5); // STIP
                            }
                        } else if (vc.timer_target < min_timer) {
                            min_timer = vc.timer_target;
                        }
                    }
                    if (!wake and (now_time -% vc.last_queued_time >= riscv.TIMESLICE_TICKS)) {
                        // Spurious WFI wakeup after timeslice to prevent spinlock deadlocks
                        wake = true;
                    }
                }
                
                if (wake) {
                    pcpu.blocked_queue.remove(node);
                    if (vc.tryWake()) {
                        vc.blocked_on_cpu = null;
                        scheduler.queue(vc);
                    }
                }
                
                it = next_it;
            }
            
            // Check if a hardware MSIP IPI is pending on this physical core via in-register mip CSR
            const msip_pending = (riscv.readMip() & (1 << 3)) != 0;
            
            // Try to schedule any newly woken vcores
            scheduler.schedule();
            if (pcpu.active_vcore != null) {
                break;
            }
            
            // Sleep the physical CPU only if no IPI is pending
            if (!msip_pending) {
                riscv.setTimer(min_timer);
                riscv.pause(); // Execute WFI
            }
        }
    }

    // Refresh context if we're returning to a vcore from a lower privilege mode.
    // If we trapped from M-mode (e.g. nested trap during memory probing or IPIs),
    // we must NOT overwrite the hardware stack frame with the guest's state,
    // as we need to return directly back to the interrupted M-mode code.
    const restore_context = (irq.privilege_mode != .machine) and (pcpu.active_vcore != null);

    if (restore_context) {
        if (pcpu.active_vcore) |vc_raw| {
            const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));

            if (vc.exec_path == .native) {
                @memcpy(context, vc.getNativeContext());
                pcore.contextSwitch(vc);
                syncGuestStateToHardware(vc);
            } else if (vc.exec_path == .emulated) {
                @memcpy(context, vc.getNativeContext());
                pcore.contextSwitch(vc);
                riscv.writeMstatus(vc.getNativeMachine().mstatus);
                riscv.writeMepc(vc.getNativeMachine().mepc);
            }
        }
    }


    // Clear in_m_mode before mret returns to a lower privilege mode.
    // If we're returning to M-mode (idle hart WFI loop), keep it true.
    if (restore_context) {
        pcpu.in_m_mode = false;
    }
}

// Synchronize the virtual core's architecture state to the physical hardware CSRs.
// This is required before returning to guest mode (mret) if the state has changed.
fn syncGuestStateToHardware(vc: *vcore.VirtualCore) void {
    const ms = vc.getNativeMachine();
    const gs = vc.getNativeGuestState();

    if (@atomicRmw(bool, &vc.pending_ipi, .Xchg, false, .acq_rel)) {
        ms.hvip |= riscv.HVIP.VSSIP;
    }

    riscv.writeMepc(ms.mepc);
    riscv.writeMstatus(ms.mstatus);

    if (riscv.hasHExtension()) {
        if (vc.guest.space.mode == .h_paging) {
            ms.hgatp = vc.guest.space.paging.?.hgatp(vc.guest.vmid);
        }
        riscv.writeHstatus(ms.hstatus);
        riscv.writeHgatp(ms.hgatp);

        // If the guest has programmed a timer via vstimecmp (Sstc), ensure we clear any stale
        // software-injected VSTIP bit in hvip so the hardware can manage the interrupt natively.
        // On legacy CPUs lacking Sstc, emulate the timer interrupt in software by setting VSTIP.
        var hvip_val = ms.hvip;

        if (!config.legacy_cpu and riscv.riscv_supports_sstc) {
            hvip_val &= ~@as(usize, riscv.HVIP.VSTIP);
        } else if (gs.vstimecmp != 0 and gs.vstimecmp != riscv.TIMER_INFINITY) {
            if (riscv.readTime() >= gs.vstimecmp) {
                hvip_val |= riscv.HVIP.VSTIP;
            } else {
                hvip_val &= ~@as(usize, riscv.HVIP.VSTIP);
            }
        }

        // Dynamically assert or clear VSEIP in hvip based on the physical mip MEIP/SEIP bits
        const mip_val = riscv.readMip();
        if ((mip_val & ((1 << 9) | (1 << 11))) != 0) {
            hvip_val |= riscv.HVIP.VSEIP;
        } else {
            hvip_val &= ~@as(usize, riscv.HVIP.VSEIP);
        }

        riscv.writeHvip(hvip_val);
        
        // Ensure that the physical timer is programmed correctly for this core
        // because the vcore might have migrated from another physical core, or
        // the timer might have been cleared by another vcore's timer expiring.
        var next_timer: u64 = ~@as(u64, 0);

        if (vc.exec_path == .emulated) {
            if (vc.timer_scheduled) {
                if (riscv.readTime() >= vc.timer_target) {
                    vc.timer_scheduled = false; // Emulation loop will handle MIP_STIP
                } else {
                    next_timer = vc.timer_target;
                }
            }
        } else {
            const vstc = vc.getNativeGuestState().vstimecmp;
            if (vstc != 0 and vstc != 0xffffffffffffffff) {
                if (riscv.readTime() >= vstc) {
                    if (config.legacy_cpu or !riscv.riscv_supports_sstc) {
                        hvip_val |= riscv.HVIP.VSTIP;
                        riscv.writeHvip(hvip_val);
                    }
                } else {
                    next_timer = vstc;
                }
            }
        }
        
        // Include blocked vcores on this physical core
        var it = pcore.this().blocked_queue.start;
        while (it) |node| {
            const blocked_vc: *vcore.VirtualCore = @ptrCast(@alignCast(node.contents));
            if (blocked_vc.exec_path == .emulated) {
                if (blocked_vc.timer_scheduled and blocked_vc.timer_target < next_timer) {
                    next_timer = blocked_vc.timer_target;
                }
            } else {
                const b_gs = blocked_vc.getNativeGuestState();
                if (b_gs.vstimecmp != 0 and b_gs.vstimecmp != 0xffffffffffffffff and b_gs.vstimecmp < next_timer) {
                    next_timer = b_gs.vstimecmp;
                }
            }
            it = node.next;
        }
        
        // Clamp the next_timer to enforce a preemptive timeslice (10ms at 10MHz = 100,000 ticks)
        // This ensures that native guests don't monopolize the physical CPU and starve
        // other vcores (e.g. during SMP bringup when spinning in WFI/Zawrs loops).
        const timeslice_target = riscv.readTime() +% riscv.TIMESLICE_TICKS;
        if (next_timer == riscv.TIMER_INFINITY or next_timer > timeslice_target) {
            next_timer = timeslice_target;
        }

        if (next_timer != riscv.TIMER_INFINITY) {
            riscv.setTimer(next_timer);
        } else {
            riscv.setTimer(riscv.TIMER_INFINITY);
        }

        riscv.writeHedeleg(ms.hedeleg);
        riscv.writeHideleg(ms.hideleg);

        // Hierarchical trust-based counter delegation
        // Grant direct native access to cycle, time, and instret (bits 0, 1, 2 = 7)
        // to trusted guests (such as the Root VM) to run at full hardware speed with zero trap overhead.
        // Untrusted/less-privileged guests are forced to trap (hcounteren = 0) so their time access
        // can be emulated safely in software without exposing security timing weaknesses.
        if (vc.getGuest().is_trusted) {
            riscv.writeHcounteren(7);
        } else {
            riscv.writeHcounteren(0);
        }

        // Sync VS-mode (Guest Supervisor) CSRs
        riscv.writeVsstatus(gs.vsstatus);
        riscv.writeVsie(gs.vsie);
        riscv.writeVstvec(gs.vstvec);
        riscv.writeVsscratch(gs.vsscratch);
        riscv.writeVsepc(gs.vsepc);
        riscv.writeVscause(gs.vscause);
        riscv.writeVstval(gs.vstval);
        riscv.writeVsatp(gs.vsatp);

        if (!config.legacy_cpu) {
            if (riscv.riscv_supports_smstateen) {
                riscv.writeVsenvcfg(gs.vsenvcfg);
                riscv.writeHenvcfg((1 << 63) | 240);
            }
            if (riscv.riscv_supports_sstc) riscv.writeVstimecmp(gs.vstimecmp);
        }

        // Only flush G-stage TLB if the page table was modified since the last flush.
        // Demand paging (resolveFault) sets gstage_dirty when mapping new pages.
        // Skipping this for ecall/timer returns avoids ~800 unnecessary TLB flushes/second,
        // each of which would invalidate the entire guest address space.
        riscv.hfenceGvma();
    } else {
        // Clear or set STIP (bit 5) and SSIP (bit 1) in physical mip based on whether VSTIP/VSSIP in machine.hvip is set.
        var mip_val = riscv.readMip();
        if ((ms.hvip & riscv.HVIP.VSTIP) != 0) {
            mip_val |= (1 << 5); // STIP
        } else {
            mip_val &= ~@as(usize, 1 << 5);
        }

        if ((ms.hvip & riscv.HVIP.VSSIP) != 0) {
            mip_val |= (1 << 1); // SSIP
        } else {
            mip_val &= ~@as(usize, 1 << 1);
        }

        // If guest has programmed a timer via stimecmp, inject if target passed
        if (gs.vstimecmp != 0 and gs.vstimecmp != 0xffffffffffffffff) {
            if (riscv.readTime() >= gs.vstimecmp) {
                mip_val |= (1 << 5);
            } else {
                mip_val &= ~@as(usize, 1 << 5);
            }
        }

        riscv.writeMip(mip_val);

        // Sync S-mode (Guest Supervisor) CSRs directly
        riscv.writeSstatus(gs.vsstatus);
        riscv.writeSie(gs.vsie);
        riscv.writeStvec(gs.vstvec);
        riscv.writeSscratch(gs.vsscratch);
        riscv.writeSepc(gs.vsepc);
        riscv.writeScause(gs.vscause);
        riscv.writeStval(gs.vstval);
        riscv.writeSatp(gs.vsatp);

        if (!config.legacy_cpu) {
            if (riscv.riscv_supports_sstc) riscv.writeStimecmp(gs.vstimecmp);
            if (riscv.riscv_supports_smstateen) riscv.writeSenvcfg(gs.vsenvcfg);
        }

        // Flash S-mode TLB entries
        riscv.sfenceVma();
    }
}

// Safely fetch an instruction from guest memory, accounting for potential
// unaligned addresses if the guest PC ends in a 2-byte boundary.
fn fetchGuestInstruction(pc: usize) usize {
    const pcpu = pcore.this();
    pcpu.probing_active = true;
    pcpu.probe_failed = false;
    defer pcpu.probing_active = false;

    var instr: usize = 0;

    if ((pc & 0x2) != 0) {
        // Misaligned PC: fetch as 16-bit parcels to avoid alignment faults
        const lower = riscv.hlv_hu(pc);
        if (pcpu.probe_failed) return 0;
        instr = lower;

        // Check if it's a 32-bit instruction (lowest 2 bits are 11)
        if ((lower & 0b11) == 0b11) {
            const upper = riscv.hlv_hu(pc + 2);
            if (pcpu.probe_failed) return 0;
            instr |= (@as(usize, upper) << 16);
        }
    } else {
        // Aligned PC: safe to fetch 32-bit word directly.
        // 4-byte aligned addresses never cross page boundaries.
        instr = riscv.hlv_wu(pc);
        if (pcpu.probe_failed) return 0;
    }

    return instr;
}

fn handle_exception(irq: IRQ, context: *riscv.ThreadContext) void {
    if (irq.privilege_mode == .machine) {
        if (irq.irq_type == .exception) {
            if (irq.cause == .machine_environment_call) {
                // Let the M-mode emulator ecall fall through to standard handling
            } else {
                const pcpu = pcore.this();
                if (pcpu.probing_active) {
                    pcpu.probe_failed = true;
                    // Advance PC past the 4-byte instruction that triggered the illegal instruction exception
                    riscv.writeMepc(irq.pc + 4);
                    return;
                }
                fatal_exception(irq, context);
                return;
            }
        }
        // If it's an interrupt, let it fall through and be handled normally!
    }


    switch (irq.cause) {
        .illegal_instruction, .virtual_instruction => {
            const pcpu = pcore.this();
            if (pcpu.active_vcore) |vc_raw| {
                const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));

                // Ratified Spec Compliance: illegal instruction exceptions write the faulting instruction
                // directly into the mtval register (irq.val). If it is non-zero, we use it directly
                // to avoid expensive instruction-space translations and memory loads (hlv_wu).
                // If mtval is 0 (e.g., instruction crosses a page boundary, or implementation
                // doesn't provide it), use hlv_wu wrapped in the probe mechanism for safety.
                // The probe catches faults (e.g., unmapped PC from corrupted jump) without
                // crashing the hypervisor — the nested trap handler sets probe_failed=true
                // and skips past the faulting instruction.
                const instr: usize = blk: {
                    if (irq.val != 0) break :blk irq.val;
                    if (riscv.hasHExtension()) {
                        break :blk fetchGuestInstruction(irq.pc);
                    }
                    break :blk @as(usize, 0);
                };

                // Check if it's an access to siselect (0x150 or 0x015), sireg (0x151 or 0x016), vsiselect (0x250 or 0x215), vsireg (0x251 or 0x216),
                // siselecth (0xdb0), siregh (0xdb4), vsiselecth (0xeb0), vsiregh (0xeb4),
                // or senvcfg (0x10A), vsenvcfg (0x20A)
                const opcode = instr & riscv.Instr.OPCODE_MASK;
                const csr = (instr >> 20) & riscv.Instr.CSR_MASK;

                const is_emulated_csr = switch (csr) {
                    riscv.CSR.SEED, riscv.CSR.SIREG_LEGACY, riscv.CSR.VSISELECT_LEGACY, riscv.CSR.VSIREG_LEGACY, riscv.CSR.SISELECT, riscv.CSR.SIREG, riscv.CSR.VSISELECT, riscv.CSR.VSIREG, riscv.CSR.SISELECTH, riscv.CSR.SIREGH, riscv.CSR.VSISELECTH, riscv.CSR.VSIREGH, riscv.CSR.SENVCFG, riscv.CSR.VSENVCFG, riscv.CSR.STIMECMP => true,
                    else => false,
                };

                if (opcode == riscv.Instr.OPCODE_SYSTEM and is_emulated_csr) {
                    const rd = (instr >> 7) & riscv.Instr.RD_MASK;
                    const rs1 = (instr >> 15) & riscv.Instr.RS1_MASK;
                    const funct3 = (instr >> 12) & riscv.Instr.FUNCT3_MASK;

                    // Determine previous value to return in rd
                    var old_val: usize = 0;
                    if (csr == riscv.CSR.SEED) {
                        // RISC-V Entropy Source Extension (Zkr): Return ES16 status (0x80000000)
                        // combined with 16 bits of pseudo-random entropy from hardware time.
                        const time_now = riscv.readTime();
                        const entropy = (time_now ^ (time_now >> 16)) & 0xffff;
                        old_val = 0x80000000 | entropy;
                        debug.printf("Zkr seed read: time=0x{x} entropy=0x{x} old_val=0x{x}\n", .{ time_now, entropy, old_val });
                    } else if (csr == riscv.CSR.VSISELECT_LEGACY or csr == riscv.CSR.SISELECT or csr == riscv.CSR.VSISELECT or csr == riscv.CSR.SISELECTH or csr == riscv.CSR.VSISELECTH) {
                        old_val = vc.getNativeSiselect().*;
                    } else if (csr == riscv.CSR.SENVCFG or csr == riscv.CSR.VSENVCFG) {
                        old_val = vc.getNativeGuestState().vsenvcfg;
                    } else if (csr == riscv.CSR.STIMECMP) {
                        old_val = vc.getNativeGuestState().vstimecmp;
                    } else {
                        // sireg/siregh always returns 0 for our emulation
                        old_val = 0;
                    }

                    // Write new value based on instruction type
                    if (funct3 == riscv.Instr.FUNCT3_CSRRW) {
                        const new_val = if (rs1 == 0) 0 else context[rs1];
                        if (csr == riscv.CSR.VSISELECT_LEGACY or csr == riscv.CSR.SISELECT or csr == riscv.CSR.VSISELECT or csr == riscv.CSR.SISELECTH or csr == riscv.CSR.VSISELECTH) {
                            vc.getNativeSiselect().* = new_val;
                        } else if (csr == riscv.CSR.SENVCFG or csr == riscv.CSR.VSENVCFG) {
                            vc.getNativeGuestState().vsenvcfg = new_val;
                        } else if (csr == riscv.CSR.STIMECMP) {
                            vc.getNativeGuestState().vstimecmp = new_val;
                            vc.getNativeMachine().hvip &= ~@as(usize, riscv.HVIP.VSTIP);
                        }
                    } else if (funct3 == riscv.Instr.FUNCT3_CSRRS) {
                        if (rs1 != 0) {
                            const val_to_set = context[rs1];
                            if (csr == riscv.CSR.VSISELECT_LEGACY or csr == riscv.CSR.SISELECT or csr == riscv.CSR.VSISELECT or csr == riscv.CSR.SISELECTH or csr == riscv.CSR.VSISELECTH) {
                                vc.getNativeSiselect().* |= val_to_set;
                            } else if (csr == riscv.CSR.SENVCFG or csr == riscv.CSR.VSENVCFG) {
                                vc.getNativeGuestState().vsenvcfg |= val_to_set;
                            } else if (csr == riscv.CSR.STIMECMP) {
                                vc.getNativeGuestState().vstimecmp |= val_to_set;
                                vc.getNativeMachine().hvip &= ~@as(usize, riscv.HVIP.VSTIP);
                            }
                        }
                    } else if (funct3 == riscv.Instr.FUNCT3_CSRRC) {
                        if (rs1 != 0) {
                            const val_to_clear = context[rs1];
                            if (csr == riscv.CSR.VSISELECT_LEGACY or csr == riscv.CSR.SISELECT or csr == riscv.CSR.VSISELECT or csr == riscv.CSR.SISELECTH or csr == riscv.CSR.VSISELECTH) {
                                vc.getNativeSiselect().* &= ~val_to_clear;
                            } else if (csr == riscv.CSR.SENVCFG or csr == riscv.CSR.VSENVCFG) {
                                vc.getNativeGuestState().vsenvcfg &= ~val_to_clear;
                            } else if (csr == riscv.CSR.STIMECMP) {
                                vc.getNativeGuestState().vstimecmp &= ~val_to_clear;
                                vc.getNativeMachine().hvip &= ~@as(usize, riscv.HVIP.VSTIP);
                            }
                        }
                    } else if (funct3 == riscv.Instr.FUNCT3_CSRRWI) {
                        if (csr == riscv.CSR.VSISELECT_LEGACY or csr == riscv.CSR.SISELECT or csr == riscv.CSR.VSISELECT or csr == riscv.CSR.SISELECTH or csr == riscv.CSR.VSISELECTH) {
                            vc.getNativeSiselect().* = rs1;
                        } else if (csr == riscv.CSR.SENVCFG or csr == riscv.CSR.VSENVCFG) {
                            vc.getNativeGuestState().vsenvcfg = rs1;
                        } else if (csr == riscv.CSR.STIMECMP) {
                            vc.getNativeGuestState().vstimecmp = rs1;
                            vc.getNativeMachine().hvip &= ~@as(usize, riscv.HVIP.VSTIP);
                        }
                    } else if (funct3 == riscv.Instr.FUNCT3_CSRRSI) {
                        if (csr == riscv.CSR.VSISELECT_LEGACY or csr == riscv.CSR.SISELECT or csr == riscv.CSR.VSISELECT or csr == riscv.CSR.SISELECTH or csr == riscv.CSR.VSISELECTH) {
                            vc.getNativeSiselect().* |= rs1;
                        } else if (csr == riscv.CSR.SENVCFG or csr == riscv.CSR.VSENVCFG) {
                            vc.getNativeGuestState().vsenvcfg |= rs1;
                        } else if (csr == riscv.CSR.STIMECMP) {
                            vc.getNativeGuestState().vstimecmp |= rs1;
                            vc.getNativeMachine().hvip &= ~@as(usize, riscv.HVIP.VSTIP);
                        }
                    } else if (funct3 == riscv.Instr.FUNCT3_CSRRCI) {
                        if (csr == riscv.CSR.VSISELECT_LEGACY or csr == riscv.CSR.SISELECT or csr == riscv.CSR.VSISELECT or csr == riscv.CSR.SISELECTH or csr == riscv.CSR.VSISELECTH) {
                            vc.getNativeSiselect().* &= ~rs1;
                        } else if (csr == riscv.CSR.SENVCFG or csr == riscv.CSR.VSENVCFG) {
                            vc.getNativeGuestState().vsenvcfg &= ~rs1;
                        } else if (csr == riscv.CSR.STIMECMP) {
                            vc.getNativeGuestState().vstimecmp &= ~rs1;
                            vc.getNativeMachine().hvip &= ~@as(usize, riscv.HVIP.VSTIP);
                        }
                    }

                    if (rd != 0) {
                        context[rd] = old_val;
                        vc.getNativeContext()[rd] = old_val;
                    }

                    vc.getNativeMachine().mepc += 4;
                    // Write mepc to hardware CSR: the asm stub doesn't touch mepc,
                    // and this early-return path skips syncGuestStateToHardware.
                    // Without this, mret returns to the faulting instruction.
                    riscv.writeMepc(vc.getNativeMachine().mepc);
                    pcore.this().trap_loop_count = 0; // Reset loop detector

                    // For stimecmp emulation: write the new vstimecmp directly to hardware
                    // and clear VSTIP, since the CSR emulation path returns without calling
                    // syncGuestStateToHardware (which normally writes vstimecmp).
                    if (csr == riscv.CSR.STIMECMP) {
                        const vstc = vc.getNativeGuestState().vstimecmp;
                        if (riscv.riscv_supports_sstc) {
                            riscv.writeVstimecmp(vstc);
                            var hvip = riscv.readHvip();
                            hvip &= ~@as(usize, riscv.HVIP.VSTIP);
                            riscv.writeHvip(hvip);
                        }
                        if (vstc != 0 and vstc != ~@as(u64, 0)) {
                            riscv.setTimer(vstc);
                        }
                    }

                    return;
                }

                // Emulate rdtime / csrr rd, time
                const rdtime_inst: u32 = (riscv.CSR.TIME << 20) | (riscv.Instr.FUNCT3_CSRRS << 12) | riscv.Instr.OPCODE_SYSTEM;
                const rdtime_mask: u32 = ~@as(u32, riscv.Instr.RD_MASK << 7);

                if ((instr & rdtime_mask) == rdtime_inst) {
                    const time_now = riscv.readTime();
                    const rd = (instr >> 7) & riscv.Instr.RD_MASK;

                    // Fix register corruption: write to both the stack copy (context) and the stored vc.context.
                    context[rd] = @as(usize, time_now);
                    vc.getNativeContext()[rd] = @as(usize, time_now);
                    vc.getNativeMachine().mepc += 4;
                    pcore.this().trap_loop_count = 0; // Reset loop detector

                    return;
                }

                // Emulate FENCE.I - instruction fence
                // This is safe to emulate as NOP since QEMU maintains I-cache coherency.
                if (instr == riscv.Instr.FENCE_I) {
                    vc.getNativeMachine().mepc += 4;
                    pcore.this().trap_loop_count = 0;
                    return;
                }

                // Emulate WFI - Wait For Interrupt
                // In VS-mode, WFI traps as virtual instruction when hstatus.VTW=1.
                if (instr == riscv.Instr.WFI) {
                    pcore.this().trap_loop_count = 0;

                    // If virtual interrupts are already pending (e.g. VSTIP from timer, VSSIP from IPI), do not block.
                    const gs = vc.getNativeGuestState();
                    const timer_expired = (gs.vstimecmp != 0 and gs.vstimecmp != riscv.TIMER_INFINITY and riscv.readTime() >= gs.vstimecmp);
                    const virt_mask = riscv.HVIP.VSSIP | riscv.HVIP.VSTIP | riscv.HVIP.VSEIP;
                    const has_pending_ipi = @atomicLoad(bool, &vc.pending_ipi, .acquire);
                    const pending_virt = ((vc.getNativeMachine().hvip | (if (has_pending_ipi) @as(usize, riscv.HVIP.VSSIP) else 0)) & virt_mask) != 0;

                    if (pending_virt or timer_expired) {
                        // Spurious wakeup / pending interrupt exists — advance mepc past WFI and resume immediately.
                        vc.getNativeMachine().mepc += 4;
                        if (@atomicRmw(bool, &vc.pending_ipi, .Xchg, false, .acq_rel)) {
                            vc.getNativeMachine().hvip |= riscv.HVIP.VSSIP;
                        }
                        if (riscv.hasHExtension()) {
                            riscv.writeHvip(vc.getNativeMachine().hvip);
                        }
                        riscv.writeMepc(vc.getNativeMachine().mepc);
                        return;
                    }

                    // No pending interrupts — block the vcore.
                    // Record this vcore as blocked on THIS physical core.
                    // Only this core will monitor the vcore's timer (avoids thundering herd).
                    vc.blocked_node.contents = vc;
                    pcore.this().blocked_queue.pushStart(&vc.blocked_node);
                    vc.blocked_on_cpu = pcore.this().cpu_core_id;
                    @atomicStore(bool, &vc.wfi_blocked, true, .release);
                    scheduler.schedule();
                    // Fall through to the idle loop below the switch statement
                } else {
                    // All non-WFI instruction emulation: these return immediately
                    // since they don't block the vcore.

                    // Emulate Zawrs: WRS.NTO (0x00d00073) and WRS.STO (0x01d00073)
                    // Wait on Reservation Set — the guest is spinning on a lock (lr/sc loop).
                    // With hstatus.VTW=1, this traps to M-mode after a timeout.
                    // We advance mepc by 4 for a spurious wakeup (permitted by spec).
                    // The guest re-evaluates the lock via its branch-back to lr.
                    // Normal timeslice preemption ensures the lock-holder gets CPU time.

                    if (instr == 0x00d00073 or instr == 0x01d00073 or instr == 0x0100000f) {
                        vc.getNativeMachine().mepc += 4;
                        riscv.writeMepc(vc.getNativeMachine().mepc);
                        pcore.this().trap_loop_count = 0;
                        return;
                    }

                    // Emulate FENCE (opcode matches: OPCODE_MISC_MEM, funct3 = FUNCT3_FENCE)
                    // Various FENCE encodings that might trap from VS-mode
                    if ((instr & riscv.Instr.OPCODE_MASK) == riscv.Instr.OPCODE_MISC_MEM and ((instr >> 12) & riscv.Instr.FUNCT3_MASK) == riscv.Instr.FUNCT3_FENCE) {
                        vc.getNativeMachine().mepc += 4;
                        riscv.writeMepc(vc.getNativeMachine().mepc);
                        pcore.this().trap_loop_count = 0;
                        return;
                    }

                    // Unrecognized instruction — check if it's an M-mode CSR read from
                    // the dynarec JIT (which may emit native CSR instructions that fault
                    // because the S-mode runner can't access M-mode CSRs).
                    if ((instr & riscv.Instr.OPCODE_MASK) == riscv.Instr.OPCODE_SYSTEM) {
                        const funct3 = (instr >> 12) & riscv.Instr.FUNCT3_MASK;
                        if (funct3 >= 1 and funct3 <= 3) { // CSRRW, CSRRS, CSRRC
                            const mmode_csr = instr >> 20;
                            const mmode_rd = (instr >> 7) & riscv.Instr.RD_MASK;

                            // Emulate reads of M-mode CSRs.
                            const val: usize = switch (mmode_csr) {
                                0xF14 => vc.id, // mhartid
                                0xF11 => 0, // mvendorid
                                0xF12 => 0, // marchid
                                0xF13 => 0, // mimpid
                                0x301 => 0, // misa: return 0 to indicate not available
                                else => {
                                    // Truly unrecognized — fall through to reflection
                                    if (pcore.this().trap_loop_count < 2) {
                                        debug.printf("Unhandled illegal instruction 0x{x} at PC=0x{x} — reflecting to guest\n", .{ instr, irq.pc });
                                    }
                                    var csr_reflect_irq = irq;
                                    csr_reflect_irq.val = instr;
                                    reflectExceptionToGuest(vc, csr_reflect_irq) catch |err| {
                                        debug.printf("Reflection failed: {s}\n", .{@errorName(err)});
                                        fatal_exception(irq, context);
                                    };
                                    return;
                                },
                            };

                            // For CSRRS/CSRRC with rs1=0, it's a pure read.
                            // For CSRRW, the write is a no-op for read-only M-mode CSRs.

                            if (mmode_rd != 0) {
                                context[mmode_rd] = val;
                                vc.getNativeContext()[mmode_rd] = val;
                            }
                            vc.getNativeMachine().mepc += 4;
                            pcore.this().trap_loop_count = 0;
                            return;
                        }
                    }

                    {
                        if (pcore.this().trap_loop_count < 2) {
                            debug.printf("Unhandled illegal instruction 0x{x} at PC=0x{x} — reflecting to guest\n", .{ instr, irq.pc });
                        }
                        // Override irq.val with the decoded instruction so vstval is
                        // always correct, even if mtval was 0 for virtual_instruction traps.
                        var reflect_irq = irq;
                        reflect_irq.val = instr;
                        reflectExceptionToGuest(vc, reflect_irq) catch |err| {
                            debug.printf("Reflection failed: {s}\n", .{@errorName(err)});
                            fatal_exception(irq, context);
                        };
                    }
                }
            } else {
                fatal_exception(irq, context);
            }
        },
        .machine_environment_call, .supervisor_environment_call, .virtual_supervisor_environment_call => {
            // HS-mode or VS-mode ecall is an SBI call from the guest supervisor.
            // M-mode ecall is the M-mode emulator runner yielding.
            const pcpu = pcore.this();
            if (pcpu.active_vcore) |vc_raw| {
                const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
                if (vc.exec_path == .emulated) {
                    // This is the emulator runner exiting.
                    // Advance PC past ECALL so it doesn't execute again when rescheduled.
                    vc.getNativeMachine().mepc += 4;
                    // Yield the physical core to schedule other vcores
                    scheduler.schedule();
                } else {
                    if (irq.cause == .machine_environment_call) {
                        @panic("Unhandled M-mode ecall from native guest");
                    }
                    sbi.handle(vc, 0, context);
                }
            }
        },
        .guest_instruction_page_fault, .guest_load_page_fault, .guest_store_page_fault, .unknown => {
            // Only handle as fault if it's an exception, not an interrupt.
            if (irq.irq_type == .exception) {
                const pcpu = pcore.this();
                if (pcpu.active_vcore) |vc_raw| {
                    const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
                    var gpa: usize = 0;
                    if (riscv.hasHExtension()) {
                        // Try to get Guest Physical Address from mtval2 or htval
                        const mtval2 = riscv.readMtval2();
                        const htval_val = riscv.readHtval();
                        gpa = mtval2;
                        if (gpa == 0) gpa = htval_val;

                        // As per RISC-V Privileged / Hypervisor specification, mtval2 and htval
                        // hold the guest physical address shifted right by 2 bits.
                        if (gpa != 0) {
                            gpa = gpa << 2;
                        }
                    } else {
                        // In non-H mode, standard page faults write the faulting GVA directly to mtval (irq.val)
                        gpa = irq.val;
                    }

                    if (gpa == 0 or !riscv.hasHExtension()) {
                        // First-stage (VS-stage) page fault! Reflect to guest as standard page fault.
                        var reflected_irq = irq;
                        reflected_irq.cause = switch (irq.cause) {
                            .guest_instruction_page_fault => .instruction_page_fault,
                            .guest_load_page_fault => .load_page_fault,
                            .guest_store_page_fault => .store_page_fault,
                            else => irq.cause,
                        };
                        reflectExceptionToGuest(vc, reflected_irq) catch |err| {
                            debug.printf("Reflection failed: {s}\n", .{@errorName(err)});
                            fatal_exception(irq, context);
                        };
                        return;
                    }

                    const g = vc.getGuest();
                    g.space.handleFault(vc, gpa, @intFromEnum(irq.cause)) catch |err| {
                        debug.printf("Fault: GPA 0x{x} resolution failed: {s}\n", .{ gpa, @errorName(err) });
                        fatal_exception(irq, context);
                    };
                    // Mark G-stage page table as dirty so syncGuestStateToHardware
                    // will flush the TLB before returning to the guest.
                    pcore.this().gstage_dirty = true;
                }
            }
        },
        else => {
            if (irq.irq_type == .exception) {
                const pcpu = pcore.this();
                if (pcpu.active_vcore) |vc_raw| {
                    const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
                    reflectExceptionToGuest(vc, irq) catch |err| {
                        debug.printf("Reflection failed: {s}\n", .{@errorName(err)});
                        fatal_exception(irq, context);
                    };
                } else {
                    fatal_exception(irq, context);
                }
            }
        },
    }
}

fn handle_interrupt(irq: IRQ, context: *riscv.ThreadContext) void {
    _ = context;
    const pcpu = pcore.this();

    switch (irq.cause) {
        .machine_timer, .supervisor_timer => {
            riscv.setTimer(0xffffffffffffffff);
            var next_timer: u64 = ~@as(u64, 0);
            
            // 1. Deliver to the active vCore if applicable
            if (pcpu.active_vcore) |opaque_vc| {
                const vc: *vcore.VirtualCore = @ptrCast(@alignCast(opaque_vc));

                if (vc.timer_scheduled) {
                    if (riscv.readTime() >= vc.timer_target) {
                        if (vc.exec_path == .native) {
                            if (!riscv.riscv_supports_sstc) {
                                vc.getNativeMachine().hvip |= riscv.HVIP.VSTIP;
                            }
                        }
                        vc.timer_scheduled = false;
                    } else {
                        if (vc.timer_target < next_timer) next_timer = vc.timer_target;
                    }
                }

                if (vc.exec_path == .native) {
                    const gs = vc.getNativeGuestState();
                    if (!riscv.riscv_supports_sstc and gs.vstimecmp != 0 and gs.vstimecmp != riscv.TIMER_INFINITY) {
                        if (riscv.readTime() >= gs.vstimecmp) {
                            vc.getNativeMachine().hvip |= riscv.HVIP.VSTIP;
                        } else {
                            if (gs.vstimecmp < next_timer) next_timer = gs.vstimecmp;
                        }
                    }
                }
            }

            // 2. Deliver to any blocked vcores whose timers expired, and calculate next_timer
            var it = pcpu.blocked_queue.start;
            while (it) |node| {
                const next_it = node.next;
                const vc: *vcore.VirtualCore = @ptrCast(@alignCast(node.contents));
                
                if (!@atomicLoad(bool, &vc.wfi_blocked, .acquire)) {
                    pcpu.blocked_queue.remove(node);
                    it = next_it;
                    continue;
                }

                var wake = false;
                if (vc.timer_scheduled) {
                    if (riscv.readTime() >= vc.timer_target) {
                        if (vc.exec_path == .native) {
                            if (!riscv.riscv_supports_sstc) {
                                vc.getNativeMachine().hvip |= riscv.HVIP.VSTIP;
                            }
                        }
                        vc.timer_scheduled = false;
                        wake = true;
                    } else {
                        if (vc.timer_target < next_timer) next_timer = vc.timer_target;
                    }
                }

                if (!wake and vc.exec_path == .native) {
                    if (!config.legacy_cpu and riscv.riscv_supports_sstc) {
                        const gs = vc.getNativeGuestState();
                        if (gs.vstimecmp != 0 and gs.vstimecmp != riscv.TIMER_INFINITY) {
                            if (riscv.readTime() >= gs.vstimecmp) {
                                wake = true;
                            } else if (gs.vstimecmp < next_timer) {
                                next_timer = gs.vstimecmp;
                            }
                        }
                        if (!wake and (riscv.readTime() -% vc.last_queued_time >= riscv.TIMESLICE_TICKS)) {
                            wake = true;
                        } else if (!wake) {
                            const poll_target = riscv.readTime() + 5000;
                            if (poll_target < next_timer) next_timer = poll_target;
                        }
                    }
                } else if (!wake and vc.exec_path == .emulated) {
                    if (vc.timer_scheduled) {
                        if (riscv.readTime() >= vc.timer_target) {
                            wake = true;
                            if (vc.exec_path.emulated.vcpu) |v| {
                                v.mip |= (1 << 5); // STIP
                            }
                        } else if (vc.timer_target < next_timer) {
                            next_timer = vc.timer_target;
                        }
                    }
                    if (!wake and (riscv.readTime() -% vc.last_queued_time >= riscv.TIMESLICE_TICKS)) {
                        wake = true;
                    }
                }

                if (wake) {
                    pcpu.blocked_queue.remove(node);
                    if (vc.tryWake()) {
                        vc.blocked_on_cpu = null;
                        scheduler.queue(vc);
                    }
                }

                it = next_it;
            }
            
            riscv.setTimer(next_timer);

            // Asynchronous preemption: if dynarec is running on this core, signal preemption.
            if (pcpu.active_vcore) |opaque_vc| {
                const active_vc: *vcore.VirtualCore = @ptrCast(@alignCast(opaque_vc));
                if (active_vc.exec_path == .emulated) {
                    active_vc.exec_path.emulated.preempt_pending = true;
                }
            }

            // Preemptive multitasking: yield the physical CPU when timeslice expires
            scheduler.schedule();
        },
        .machine_swi => {
            // Clear the CLINT MSIP register for the current physical CPU core
            if (riscv.CLINT.msip(pcpu.hardware_hart_id)) |ptr| {
                ptr.* = 0;
            }
            // Wake any WFI-blocked vcores on this physical core that have pending software interrupts
            var it = pcpu.blocked_queue.start;
            while (it) |node| {
                const next_it = node.next;
                const vc: *vcore.VirtualCore = @ptrCast(@alignCast(node.contents));
                
                // If it was woken up by another CPU, clean it up
                if (!@atomicLoad(bool, &vc.wfi_blocked, .acquire)) {
                    pcpu.blocked_queue.remove(node);
                    it = next_it;
                    continue;
                }

                var wake = false;
                if (@atomicLoad(bool, &vc.pending_ipi, .acquire)) {
                    wake = true;
                }

                if (wake) {
                    pcpu.blocked_queue.remove(node);
                    if (vc.tryWake()) {
                        vc.blocked_on_cpu = null;
                        scheduler.queue(vc);
                    }
                }
                it = next_it;
            }

            // Asynchronous preemption: if dynarec is running on this core, signal preemption.
            if (pcpu.active_vcore) |opaque_vc| {
                const active_vc: *vcore.VirtualCore = @ptrCast(@alignCast(opaque_vc));
                if (active_vc.exec_path == .emulated) {
                    active_vc.exec_path.emulated.preempt_pending = true;
                } else {
                    if (@atomicRmw(bool, &active_vc.pending_ipi, .Xchg, false, .acq_rel)) {
                        active_vc.getNativeMachine().hvip |= riscv.HVIP.VSSIP;
                        if (riscv.hasHExtension()) {
                            riscv.writeHvip(riscv.readHvip() | riscv.HVIP.VSSIP);
                        } else {
                            riscv.writeMip(riscv.readMip() | (1 << 1));
                        }
                    }
                }
            }

            // Schedule any ready vcore picked up via IPI only if this physical CPU is currently idle
            if (pcpu.active_vcore == null) {
                scheduler.schedule();
            }
        },
        .machine_interrupt, .supervisor_interrupt => {
            // Machine/Supervisor external interrupt from the PLIC.
            // Route it to the guest vcores globally.
            if (main.global_root_vm) |g| {
                var it_vcore = g.vcores.start;
                while (it_vcore) |node| {
                    const vc = node.contents;
                    if (vc.blocked_on_cpu) |home_cpu| {
                        if (vc.tryWake()) {
                            if (home_cpu != pcpu.cpu_core_id and home_cpu < riscv.cpu_to_hart_map.len) {
                                if (riscv.CLINT.msip(riscv.cpu_to_hart_map[home_cpu])) |ptr| {
                                    ptr.* = 1;
                                }
                            } else {
                                scheduler.queue(vc);
                            }
                        }
                    }
                    it_vcore = node.next;
                }
            }

            // Asynchronous preemption: if dynarec is running on this core, signal preemption.
            if (pcpu.active_vcore) |opaque_vc| {
                const active_vc: *vcore.VirtualCore = @ptrCast(@alignCast(opaque_vc));
                if (active_vc.exec_path == .emulated) {
                    active_vc.exec_path.emulated.preempt_pending = true;
                }
            }
        },
        else => {
            debug.printf("Unhandled interrupt: 0x{x}\n", .{@intFromEnum(irq.cause)});
        },
    }
}

// Reflect an exception back to the guest supervisor
fn reflectExceptionToGuest(vc: *vcore.VirtualCore, irq: IRQ) !void {
    if (vc.exec_path == .emulated) {
        debug.printf("FATAL: reflectExceptionToGuest called for S-mode emulator runner! irq cause={}\n", .{irq.cause});
        fatal_exception(irq, null);
    }
    const ms = vc.getNativeMachine();
    const gs = vc.getNativeGuestState();

    // Save fault context in S-mode/VS-mode registers
    gs.vsepc = irq.pc;
    // Virtual instruction exceptions (cause 22) must be reflected to the guest
    // as illegal instruction (cause 2). The guest doesn't know about cause 22 —
    // it's a hypervisor-level exception. The RISC-V spec requires this mapping.
    gs.vscause = if (irq.cause == .virtual_instruction) 2 else @intFromEnum(irq.cause);
    gs.vstval = irq.val;

    // Modify SSTATUS/VSSTATUS:
    // - Set SPP to previous privilege (0 for User, 1 for Supervisor)
    // - Set SPIE to current SIE
    // - Clear SIE
    const spp: usize = if (irq.privilege_mode == .supervisor) 1 else 0;
    const sie_active = (gs.vsstatus & riscv.SSTATUS.SIE) != 0;
    gs.vsstatus &= ~@as(usize, riscv.SSTATUS.SIE); // Clear SIE
    gs.vsstatus &= ~@as(usize, riscv.SSTATUS.SPIE); // Clear SPIE
    gs.vsstatus &= ~(@as(usize, 1) << riscv.SSTATUS.SPP_SHIFT); // Clear SPP
    gs.vsstatus |= (spp << riscv.SSTATUS.SPP_SHIFT);
    if (sie_active) {
        gs.vsstatus |= riscv.SSTATUS.SPIE;
    }

    // Ensure we enter Supervisor mode (MPP=1)
    ms.mstatus &= ~@as(usize, riscv.MSTATUS.MPP_MASK);
    ms.mstatus |= (@as(usize, 1) << riscv.MSTATUS.MPP_SHIFT);

    if (riscv.hasHExtension()) {
        ms.mstatus |= riscv.MSTATUS.MPV;
    }

    const base = gs.vstvec & ~@as(usize, 0b11);
    if (base == 0) {
        debug.printf("FATAL: Reflecting exception to NULL vstvec — terminating guest.\n", .{});
        vc.getGuest().terminate();
        return error.InvalidAddress;
    }

    // Synchronous exceptions always jump to the base address, even in vectored mode
    ms.mepc = base;


    if (riscv.hasHExtension()) {
        // Update hstatus.SPVP to reflect the privilege mode we're coming from
        ms.hstatus &= ~riscv.HSTATUS.SPVP;
        if (irq.privilege_mode == .supervisor) {
            ms.hstatus |= riscv.HSTATUS.SPVP;
        }
    }
}

var fatal_exception_active = std.atomic.Value(bool).init(false);
var cpu_in_fatal = std.mem.zeroes([256]bool);

fn fatal_exception(irq: IRQ, context: ?*riscv.ThreadContext) void {
    const cpu_id = pcore.this().cpu_core_id;
    if (cpu_id < cpu_in_fatal.len) {
        if (cpu_in_fatal[cpu_id]) {
            // Recursive fatal exception on the SAME core! Direct raw UART write and halt immediately.
            debug.hw_putchar('\n');
            debug.hw_putchar('!');
            debug.hw_putchar('R');
            debug.hw_putchar('E');
            debug.hw_putchar('C');
            debug.hw_putchar('!');
            debug.hw_putchar('\n');
            while (true) {}
        }
        cpu_in_fatal[cpu_id] = true;
    }

    if (fatal_exception_active.swap(true, .seq_cst)) {
        // Another core has already claimed the fatal exception printer.
        // Halt silently to avoid garbling the primary traceback.
        while (true) {}
    }

    debug.releaseLocksForCrash();
    debug.printf("\nBug! Fatal exception\n", .{});
    debug.printf("Cause: {s} (0x{x})\n", .{ @tagName(irq.cause), @intFromEnum(irq.cause) });
    debug.printf("Privilege: {s}\n", .{@tagName(irq.privilege_mode)});
    debug.printf("PC: 0x{x}, SP: 0x{x}\n", .{ irq.pc, irq.sp });
    debug.printf("HTVAL: 0x{x}, MTVAL: 0x{x}\n", .{ riscv.readHtval(), riscv.readMtval() });

    if (context) |ctx| {
        debug.printf("Registers:\n", .{});
        debug.printf(" ra: 0x{x}, gp: 0x{x}, tp: 0x{x}\n", .{ ctx[1], ctx[3], ctx[4] });
        debug.printf(" t0: 0x{x}, t1: 0x{x}, t2: 0x{x}\n", .{ ctx[5], ctx[6], ctx[7] });
        debug.printf(" s0/fp: 0x{x}, s1: 0x{x}\n", .{ ctx[8], ctx[9] });
        debug.printf(" a0: 0x{x}, a1: 0x{x}, a2: 0x{x}, a3: 0x{x}\n", .{ ctx[10], ctx[11], ctx[12], ctx[13] });
        debug.printf(" a4: 0x{x}, a5: 0x{x}, a6: 0x{x}, a7: 0x{x}\n", .{ ctx[14], ctx[15], ctx[16], ctx[17] });
        debug.printf(" s2-s11: 0x{x} 0x{x} 0x{x} 0x{x} 0x{x} 0x{x} 0x{x} 0x{x} 0x{x} 0x{x}\n", .{ ctx[18], ctx[19], ctx[20], ctx[21], ctx[22], ctx[23], ctx[24], ctx[25], ctx[26], ctx[27] });
        debug.printf(" t3-t6: 0x{x} 0x{x} 0x{x} 0x{x}\n", .{ ctx[28], ctx[29], ctx[30], ctx[31] });
    }

    if (irq.privilege_mode == .machine) {
        debug.printf("Hypervisor crashed. Halting.\n", .{});
        while (true) {}
    } else {
        debug.printf("Guest environment crashed. Terminating subtree.\n", .{});
        const pcpu = pcore.this();
        if (pcpu.active_vcore) |vc_raw| {
            const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
            const g = vc.getGuest();
            g.terminate();
            if (g.is_root) {
                debug.printf("Root VM crashed. Halting host.\n", .{});
                while (true) {}
            }
        } else {
            // Should not happen if privilege_mode was not machine.
            debug.printf("No active vcore found for guest crash. Halting.\n", .{});
            while (true) {}
        }
    }
}
