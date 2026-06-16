// High-level exception and interrupt (xint) handling on RISC-V.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const main = @import("main.zig");
const builtin = @import("builtin");
const debug = @import("debug.zig");
const riscv = @import("riscv.zig");
const pcore = @import("pcore.zig");
const vcore = @import("vcore.zig");
const sbi = @import("sbi.zig");
const vm_space = @import("vm.zig");
const scheduler = @import("scheduler.zig");
const config = @import("config");

fn raw_print_char(c: u8) void {
    debug.hw_putchar(c);
}

fn raw_print_hex(val: usize) void {
    const chars = "0123456789abcdef";
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        raw_print_char(chars[(val >> @intCast(i * 4)) & 0xf]);
    }
}

extern fn hw_xint_init() void;

// Initialize hardware-dependent xint handling.
pub fn init() void {
    hw_xint_init();


    // Enable physical timer, software, and external interrupts (including supervisor mode in M-mode)
    riscv.writeMie(0xa8a);

    // Enable M-mode delegation of cycle, time, and instret counters (bits 0, 1, 2 = 7)
    // to lower privilege modes (HS, VS, VU, U).
    riscv.writeMcounteren(7);

    // Enable physical Vector (VS) and Floating-point (FS) extensions (set to 3 = Dirty)
    var mstatus = riscv.readMstatus();
    mstatus |= (3 << riscv.MSTATUS.VS_SHIFT) | (3 << riscv.MSTATUS.FS_SHIFT);
    riscv.writeMstatus(mstatus);
}

// Configure environment and state enables on the calling CPU core once
// the global probed features flags are initialized and stable.
// This must be called by every CPU core.
pub fn initCpuFeatures() void {
    if (riscv.hasHExtension() and !config.legacy_cpu and riscv.riscv_supports_smstateen) {
        // Enable STCE (bit 63) to allow supervisor/guest timer compare registers (stimecmp/vstimecmp)
        // and Cache Block Operations: CBZE (bit 7), CBCFE (bit 6), and CBIE (bits 4-5) = 240 (0xF0).
        // This grants lower privilege modes (including the guest VM) permission to execute them natively in hardware.
        const envcfg_val = (@as(usize, 1) << 63) | 240;
        riscv.writeMenvcfg(envcfg_val);
        riscv.writeHenvcfg(envcfg_val);

        // Enable state-enables for AIA (bit 59), IMSIC (bit 58), and CSRIND (bit 60),
        // as well as ENVCFG (bit 62) to delegate native hardware register access to lower privilege levels (HS/VS/U).
        // For mstateen0 (0x30c), we also enable bit 63 (SE0) to control/enable lower-level stateen.
        const mstateen_val = (@as(usize, 1) << 63) | (@as(usize, 1) << 62) | (@as(usize, 1) << 60) | (@as(usize, 1) << 59) | (@as(usize, 1) << 58);
        const hstateen_val = (@as(usize, 1) << 62) | (@as(usize, 1) << 60) | (@as(usize, 1) << 59) | (@as(usize, 1) << 58);
        riscv.writeMstateen0(mstateen_val);
        riscv.writeHstateen0(hstateen_val);
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
    const is_ecall = (irq.cause == .virtual_supervisor_environment_call or irq.cause == .supervisor_environment_call or irq.cause == .user_environment_call);
    if (!is_ecall and !is_interrupt and cpu.last_trap_pc == irq.pc and cpu.last_trap_val == irq.val) {
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
    if (pcpu.active_vcore) |vc_raw| {
        const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
        if (vc.exec_path == .emulated) {
            @import("emulation.zig").stop(vc);
        }
    }

    const irq = dispatch(context);

    total_trap_count += 1;

    // If we're coming from a guest, save its context
    if (irq.privilege_mode != .machine) {
        if (pcpu.active_vcore) |vc_raw| {
            const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
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
                    if (riscv.riscv_supports_sstc) gs.vstimecmp = riscv.readStimecmp();
                    if (riscv.riscv_supports_smstateen) gs.vsenvcfg = riscv.readSenvcfg();
                }
            }
        }
    }

    switch (irq.irq_type) {
        .exception => handle_exception(irq, context),
        .interrupt => handle_interrupt(irq, context),
    }

    // If the trap came from a guest (not machine mode), handle rescheduling and idle loops
    if (irq.privilege_mode != .machine) {
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
            riscv.pause(); // Execute WFI (Wait For Interrupt)
            scheduler.schedule();
        }
    }

    // Refresh context if we're running a vcore
    if (pcpu.active_vcore) |vc_raw| {
        const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));

        if (vc.exec_path == .native) {
            // Inject pending virtual timer interrupt if scheduled and target has passed.
            if (vc.timer_scheduled and riscv.readTime() >= vc.timer_target) {
                vc.getNativeMachine().hvip |= riscv.HVIP.VSTIP;
                vc.timer_scheduled = false;
            }

            @memcpy(context, vc.getNativeContext());
            pcore.contextSwitch(vc);
            syncGuestStateToHardware(vc);
        } else if (vc.exec_path == .emulated) {
            // For emulated vcores, we must write the struct mepc to the
            // hardware CSR so mret goes to the right place.
            riscv.writeMepc(vc.getNativeMachine().mepc);
        }
    }


    // Clear in_m_mode before mret returns to a lower privilege mode.
    // If we're returning to M-mode (idle hart WFI loop), keep it true.
    if (irq.privilege_mode != .machine) {
        pcpu.in_m_mode = false;
    }
}

// Synchronize the virtual core's architecture state to the physical hardware CSRs.
// This is required before returning to guest mode (mret) if the state has changed.
fn syncGuestStateToHardware(vc: *vcore.VirtualCore) void {
    const ms = vc.getNativeMachine();
    const gs = vc.getNativeGuestState();

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
        if (config.legacy_cpu or !riscv.riscv_supports_sstc) {
            if (gs.vstimecmp != 0 and gs.vstimecmp != 0xffffffffffffffff) {
                if (riscv.readTime() >= gs.vstimecmp) {
                    hvip_val |= riscv.HVIP.VSTIP;
                } else {
                    hvip_val &= ~@as(usize, riscv.HVIP.VSTIP);
                }
            }
        } else {
            if (gs.vstimecmp != 0 and gs.vstimecmp != 0xffffffffffffffff) {
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
            if (riscv.riscv_supports_sstc) riscv.writeVstimecmp(gs.vstimecmp);
            if (riscv.riscv_supports_smstateen) riscv.writeVsenvcfg(gs.vsenvcfg);
        }

        // Flush any G-stage TLB entries to ensure any page table updates are immediately active.
        riscv.hfenceGvma();
    } else {
        // Clear or set STIP (bit 5) in physical mip based on whether VSTIP in machine.hvip is set.
        var mip_val = riscv.readMip();
        if ((ms.hvip & riscv.HVIP.VSTIP) != 0) {
            mip_val |= (1 << 5); // STIP
        } else {
            mip_val &= ~@as(usize, 1 << 5);
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

fn handle_exception(irq: IRQ, context: *riscv.ThreadContext) void {
    if (irq.privilege_mode == .machine) {
        const pcpu = pcore.this();
        if (pcpu.probing_active) {
            pcpu.probe_failed = true;
            // Advance PC past the 4-byte instruction that triggered the illegal instruction exception
            riscv.writeMepc(irq.pc + 4);
            return;
        }
        fatal_exception(irq);
        return;
    }
    switch (irq.cause) {
        .illegal_instruction, .virtual_instruction => {
            const pcpu = pcore.this();
            if (pcpu.active_vcore) |vc_raw| {
                const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));

                // Ratified Spec Compliance: illegal instruction exceptions write the faulting instruction
                // directly into the mtval register (irq.val). If it is non-zero, we use it directly
                // to avoid expensive instruction-space translations and memory loads (hlv_wu).
                var instr = irq.val;
                if (instr == 0) {
                    if (riscv.hasHExtension()) {
                        instr = riscv.hlv_wu(irq.pc);
                    } else {
                        instr = 0;
                    }
                }

                // Check if it's an access to siselect (0x150 or 0x015), sireg (0x151 or 0x016), vsiselect (0x250 or 0x215), vsireg (0x251 or 0x216),
                // siselecth (0xdb0), siregh (0xdb4), vsiselecth (0xeb0), vsiregh (0xeb4),
                // or senvcfg (0x10A), vsenvcfg (0x20A)
                const opcode = instr & riscv.Instr.OPCODE_MASK;
                const csr = (instr >> 20) & riscv.Instr.CSR_MASK;

                const is_emulated_csr = switch (csr) {
                    riscv.CSR.SEED, riscv.CSR.SIREG_LEGACY, riscv.CSR.VSISELECT_LEGACY, riscv.CSR.VSIREG_LEGACY, riscv.CSR.SISELECT, riscv.CSR.SIREG, riscv.CSR.VSISELECT, riscv.CSR.VSIREG, riscv.CSR.SISELECTH, riscv.CSR.SIREGH, riscv.CSR.VSISELECTH, riscv.CSR.VSIREGH, riscv.CSR.SENVCFG, riscv.CSR.VSENVCFG => true,
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
                        }
                    } else if (funct3 == riscv.Instr.FUNCT3_CSRRS) {
                        if (rs1 != 0) {
                            const val_to_set = context[rs1];
                            if (csr == riscv.CSR.VSISELECT_LEGACY or csr == riscv.CSR.SISELECT or csr == riscv.CSR.VSISELECT or csr == riscv.CSR.SISELECTH or csr == riscv.CSR.VSISELECTH) {
                                vc.getNativeSiselect().* |= val_to_set;
                            } else if (csr == riscv.CSR.SENVCFG or csr == riscv.CSR.VSENVCFG) {
                                vc.getNativeGuestState().vsenvcfg |= val_to_set;
                            }
                        }
                    } else if (funct3 == riscv.Instr.FUNCT3_CSRRC) {
                        if (rs1 != 0) {
                            const val_to_clear = context[rs1];
                            if (csr == riscv.CSR.VSISELECT_LEGACY or csr == riscv.CSR.SISELECT or csr == riscv.CSR.VSISELECT or csr == riscv.CSR.SISELECTH or csr == riscv.CSR.VSISELECTH) {
                                vc.getNativeSiselect().* &= ~val_to_clear;
                            } else if (csr == riscv.CSR.SENVCFG or csr == riscv.CSR.VSENVCFG) {
                                vc.getNativeGuestState().vsenvcfg &= ~val_to_clear;
                            }
                        }
                    } else if (funct3 == riscv.Instr.FUNCT3_CSRRWI) {
                        if (csr == riscv.CSR.VSISELECT_LEGACY or csr == riscv.CSR.SISELECT or csr == riscv.CSR.VSISELECT or csr == riscv.CSR.SISELECTH or csr == riscv.CSR.VSISELECTH) {
                            vc.getNativeSiselect().* = rs1;
                        } else if (csr == riscv.CSR.SENVCFG or csr == riscv.CSR.VSENVCFG) {
                            vc.getNativeGuestState().vsenvcfg = rs1;
                        }
                    } else if (funct3 == riscv.Instr.FUNCT3_CSRRSI) {
                        if (csr == riscv.CSR.VSISELECT_LEGACY or csr == riscv.CSR.SISELECT or csr == riscv.CSR.VSISELECT or csr == riscv.CSR.SISELECTH or csr == riscv.CSR.VSISELECTH) {
                            vc.getNativeSiselect().* |= rs1;
                        } else if (csr == riscv.CSR.SENVCFG or csr == riscv.CSR.VSENVCFG) {
                            vc.getNativeGuestState().vsenvcfg |= rs1;
                        }
                    } else if (funct3 == riscv.Instr.FUNCT3_CSRRCI) {
                        if (csr == riscv.CSR.VSISELECT_LEGACY or csr == riscv.CSR.SISELECT or csr == riscv.CSR.VSISELECT or csr == riscv.CSR.SISELECTH or csr == riscv.CSR.VSISELECTH) {
                            vc.getNativeSiselect().* &= ~rs1;
                        } else if (csr == riscv.CSR.SENVCFG or csr == riscv.CSR.VSENVCFG) {
                            vc.getNativeGuestState().vsenvcfg &= ~rs1;
                        }
                    }

                    if (rd != 0) {
                        context[rd] = old_val;
                        vc.getNativeContext()[rd] = old_val;
                    }

                    vc.getNativeMachine().mepc += 4;
                    pcore.this().trap_loop_count = 0; // Reset loop detector

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
                // In VS-mode, WFI may trap as illegal. We yield to the scheduler.
                if (instr == riscv.Instr.WFI) {
                    vc.getNativeMachine().mepc += 4;
                    pcore.this().trap_loop_count = 0;
                    vc.wfi_blocked = true;
                    scheduler.schedule();
                    return;
                }

                // Emulate FENCE (opcode matches: OPCODE_MISC_MEM, funct3 = FUNCT3_FENCE)
                // Various FENCE encodings that might trap from VS-mode
                if ((instr & riscv.Instr.OPCODE_MASK) == riscv.Instr.OPCODE_MISC_MEM and ((instr >> 12) & riscv.Instr.FUNCT3_MASK) == riscv.Instr.FUNCT3_FENCE) {
                    vc.getNativeMachine().mepc += 4;
                    pcore.this().trap_loop_count = 0;
                    return;
                }

                // Unrecognized instruction — check if it's an M-mode CSR read from
                // the Unicorn JIT (which may emit native CSR instructions that fault
                // because the S-mode runner can't access M-mode CSRs).
                if ((instr & riscv.Instr.OPCODE_MASK) == riscv.Instr.OPCODE_SYSTEM) {
                    const funct3 = (instr >> 12) & riscv.Instr.FUNCT3_MASK;
                    if (funct3 >= 1 and funct3 <= 3) { // CSRRW, CSRRS, CSRRC
                        const mmode_csr = instr >> 20;
                        const mmode_rd = (instr >> 7) & riscv.Instr.RD_MASK;

                        // Emulate reads of M-mode CSRs.
                        const val: usize = switch (mmode_csr) {
                            0xF14 => riscv.readMhartid(), // mhartid
                            0xF11 => 0, // mvendorid
                            0xF12 => 0, // marchid
                            0xF13 => 0, // mimpid
                            0x301 => 0, // misa: return 0 to indicate not available
                            else => {
                                // Truly unrecognized — fall through to reflection
                                if (pcore.this().trap_loop_count < 2) {
                                    debug.printf("Unhandled illegal instruction 0x{x} at PC=0x{x} — reflecting to guest\n", .{ instr, irq.pc });
                                }
                                reflectExceptionToGuest(vc, irq) catch |err| {
                                    debug.printf("Reflection failed: {s}\n", .{@errorName(err)});
                                    fatal_exception(irq);
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
                    reflectExceptionToGuest(vc, irq) catch |err| {
                        debug.printf("Reflection failed: {s}\n", .{@errorName(err)});
                        fatal_exception(irq);
                    };
                }
            } else {
                fatal_exception(irq);
            }
        },
        .supervisor_environment_call, .virtual_supervisor_environment_call => {
            // HS-mode or VS-mode ecall is an SBI call from the guest supervisor.
            const pcpu = pcore.this();
            if (pcpu.active_vcore) |vc_raw| {
                const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
                if (vc.exec_path == .emulated) {
                    // This is the S-mode emulator runner exiting.
                    // Advance PC past ECALL so it doesn't execute again when rescheduled.
                    vc.getNativeMachine().mepc += 4;
                    // Yield the physical core to schedule other vcores
                    scheduler.schedule();
                } else {
                    sbi.handle(vc, context);
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
                            fatal_exception(irq);
                        };
                        return;
                    }

                    const g = vc.getGuest();
                    g.space.handleFault(vc, gpa, @intFromEnum(irq.cause)) catch |err| {
                        debug.printf("Fault: GPA 0x{x} resolution failed: {s}\n", .{ gpa, @errorName(err) });
                        fatal_exception(irq);
                    };
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
                        fatal_exception(irq);
                    };
                } else {
                    fatal_exception(irq);
                }
            }
        },
    }
}

fn handle_interrupt(irq: IRQ, context: *riscv.ThreadContext) void {
    _ = context;
    const pcpu = pcore.this();

    switch (irq.cause) {
        .machine_timer => {
            // Reprogram mtimecmp to clear the level-triggered interrupt.
            const TIMESLICE_TICKS: u64 = 500_000; // 50ms at 10MHz
            riscv.setTimer(riscv.readTime() +% TIMESLICE_TICKS);

            if (pcpu.active_vcore) |vc_raw| {
                const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));

                // Deliver guest timer interrupt if the guest's timer has expired.
                if (vc.timer_scheduled and riscv.readTime() >= vc.timer_target) {
                    if (vc.exec_path == .native) {
                        vc.getNativeMachine().hvip |= riscv.HVIP.VSTIP;
                    }
                    vc.timer_scheduled = false;
                }

                // Preemptive multitasking: the timeslice timer has fired.
                // Force a scheduling decision so other vcores get CPU time.
                scheduler.schedule();
            } else {
                // Core was sleeping. Check if the vcore mapped to this hart has its timer expired.
                if (main.global_root_vm) |g| {
                    if (g.findVcore(pcpu.hardware_hart_id)) |vc| {
                        const sbi_timer_expired = vc.timer_scheduled and riscv.readTime() >= vc.timer_target;
                        const sstc_timer_expired = if (vc.exec_path == .native) (!config.legacy_cpu and riscv.riscv_supports_sstc and vc.getNativeGuestState().vstimecmp != 0 and vc.getNativeGuestState().vstimecmp != 0xffffffffffffffff and riscv.readTime() >= vc.getNativeGuestState().vstimecmp) else false;
                        const timer_expired = sbi_timer_expired or sstc_timer_expired;

                        if (timer_expired) {
                            if (sbi_timer_expired or config.legacy_cpu or !riscv.riscv_supports_sstc) {
                                if (vc.exec_path == .native) {
                                    vc.getNativeMachine().hvip |= riscv.HVIP.VSTIP;
                                }
                                vc.timer_scheduled = false;
                            }
                            if (vc.wfi_blocked) {
                                vc.wfi_blocked = false;
                                vc.state = .ready;
                                scheduler.queue(vc);
                            }
                        }
                    }
                }
            }
            // Clear hardware timer condition by setting it far into the future
            // until the main loop programs a new timeslice or guest timer.
            riscv.setTimer(0xffffffffffffffff);
        },
        .machine_swi => {
            // Clear the CLINT MSIP register for the current physical CPU core
            if (riscv.CLINT.msip(pcpu.hardware_hart_id)) |ptr| {
                ptr.* = 0;
            }
            if (main.global_root_vm) |g| {
                if (g.findVcore(pcpu.hardware_hart_id)) |vc| {
                    if (vc.wfi_blocked) {
                        vc.wfi_blocked = false;
                        vc.state = .ready;
                        scheduler.queue(vc);
                    }
                }
            }
        },
        .machine_interrupt, .supervisor_interrupt => {
            // Machine/Supervisor external interrupt from the PLIC.
            // Route it to the guest vcores globally.
            if (main.global_root_vm) |g| {
                var it_vcore = g.vcores.start;
                while (it_vcore) |node| {
                    const vc = node.contents;
                    if (vc.exec_path == .native) {
                        vc.getNativeMachine().hvip |= riscv.HVIP.VSEIP;
                    }
                    if (vc.wfi_blocked) {
                        vc.wfi_blocked = false;
                        vc.state = .ready;
                        scheduler.queue(vc);
                    }

                    // If the vcore is active on another physical core, send an IPI to wake it up
                    if (vc.running_on_cpu) |target_cpu| {
                        if (target_cpu != pcpu.cpu_core_id) {
                            if (riscv.CLINT.msip(vc.id)) |ptr| {
                                ptr.* = 1;
                            }
                        }
                    }
                    it_vcore = node.next;
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
        fatal_exception(irq);
    }
    const ms = vc.getNativeMachine();
    const gs = vc.getNativeGuestState();

    // Save fault context in S-mode/VS-mode registers
    gs.vsepc = irq.pc;
    gs.vscause = @intFromEnum(irq.cause);
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

fn fatal_exception(irq: IRQ) void {
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
