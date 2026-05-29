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
const vm_space = @import("vm_space.zig");
const scheduler = @import("scheduler.zig");

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

    // Enable physical timer, software, and external interrupts
    riscv.writeMie(0x888);

    // Enable M-mode delegation of cycle, time, and instret counters (bits 0, 1, 2 = 7)
    // to lower privilege modes (HS, VS, VU, U).
    riscv.writeMcounteren(7);

    // Enable physical Vector (VS) and Floating-point (FS) extensions (set to 3 = Dirty)
    var mstatus = riscv.readMstatus();
    mstatus |= (3 << riscv.MSTATUS.VS_SHIFT) | (3 << riscv.MSTATUS.FS_SHIFT);
    riscv.writeMstatus(mstatus);

    if (riscv.hasHExtension()) {
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
                debug.printf("!!! LOOP DETECTED on Core {}: pc=0x{x} cause={s} count={} vstvec=0x{x} vsepc=0x{x} mepc=0x{x}\n", .{ cpu.cpu_core_id, irq.pc, @tagName(irq.cause), cpu.trap_loop_count, vc_diag.guest_state.vstvec, vc_diag.guest_state.vsepc, vc_diag.machine.mepc });
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
    const irq = dispatch(context);
    
    if (false) {
        if (pcpu.active_vcore) |vc_raw| {
            const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
            debug.printf("[HV] xint_handler: core={} active_vcore=0x{x} guest={} vcore={}\n", .{ pcpu.cpu_core_id, @intFromPtr(pcpu.active_vcore), vc.guest_id, vc.id });
        } else {
            debug.printf("[HV] xint_handler: core={} active_vcore=NULL\n", .{ pcpu.cpu_core_id });
        }
    }
    // Trap detail logging
    if (false) {
        if (irq.privilege_mode != .machine) {
            const is_ecall = (irq.cause == .virtual_supervisor_environment_call or irq.cause == .supervisor_environment_call or irq.cause == .user_environment_call);
            if (!is_ecall) {
                debug.printf("Trapped: core={} mode={s} pc=0x{x} cause={s} (0x{x}) val=0x{x}\n", .{ pcpu.cpu_core_id, @tagName(irq.privilege_mode), irq.pc, @tagName(irq.cause), @intFromEnum(irq.cause), irq.val });

                // Log translation state for debugging isolation failures
                const hgatp = riscv.readHgatp();
                const hstatus = riscv.readHstatus();
                const vsatp = riscv.readVsatp();
                const htval = riscv.readHtval();
                const mstatus = riscv.readMstatus();
                const hvip = if (riscv.hasHExtension()) riscv.readHvip() else 0;
                const mideleg = if (riscv.hasHExtension()) riscv.readMideleg() else 0;
                const medeleg = if (riscv.hasHExtension()) riscv.readMedeleg() else 0;

                debug.printf("[HV] State: hgatp=0x{x} hstatus=0x{x} vsatp=0x{x} mstatus=0x{x} htval=0x{x} hvip=0x{x}\n", .{ hgatp, hstatus, vsatp, mstatus, htval, hvip });
                debug.printf("[HV] Virtualization: MPV={} GVA={} SPV={} SPVP={} mideleg=0x{x} medeleg=0x{x}\n", .{ (mstatus & riscv.MSTATUS.MPV) != 0, (hstatus & riscv.HSTATUS.GVA) != 0, (hstatus & riscv.HSTATUS.SPV) != 0, (hstatus & riscv.HSTATUS.SPVP) != 0, mideleg, medeleg });

                if (riscv.hasHExtension()) {
                    const vstvec = riscv.readVstvec();
                    const vscause = riscv.readVscause();
                    const vsie = riscv.readVsie();
                    debug.printf("[HV] Guest: vstvec=0x{x} vscause=0x{x} vsie=0x{x}\n", .{ vstvec, vscause, vsie });
                }

                pcpu.trap_count += 1;
            }
        }
    }

    // If we're coming from a guest, save its context
    if (irq.privilege_mode != .machine) {
        if (pcpu.active_vcore) |vc_raw| {
            const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
            @memcpy(&vc.context, context);
            vc.machine.mepc = irq.pc;
            vc.machine.mstatus = riscv.readMstatus();
            if (riscv.hasHExtension()) {
                vc.machine.hvip = riscv.readHvip();
                const gs = &vc.guest_state;
                gs.vsstatus = riscv.readVsstatus();
                gs.vsie = riscv.readVsie();
                gs.vstvec = riscv.readVstvec();
                gs.vsscratch = riscv.readVsscratch();
                gs.vsepc = riscv.readVsepc();
                gs.vscause = riscv.readVscause();
                gs.vstval = riscv.readVstval();
                gs.vsatp = riscv.readVsatp();
                gs.vstimecmp = riscv.readVstimecmp();
                gs.vsenvcfg = riscv.readVsenvcfg();
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
        @memcpy(context, &vc.context);
        pcore.contextSwitch(vc);
        syncGuestStateToHardware(vc);
    }
}

// Synchronize the virtual core's architecture state to the physical hardware CSRs.
// This is required before returning to guest mode (mret) if the state has changed.
fn syncGuestStateToHardware(vc: *vcore.VirtualCore) void {
    const ms = &vc.machine;
    const gs = &vc.guest_state;

    if (false) {
        debug.printf("[HV] syncGuestStateToHardware: mepc=0x{x}\n", .{ms.mepc});
    }
    riscv.writeMepc(ms.mepc);
    riscv.writeMstatus(ms.mstatus);

    // Aegis: Confirm exactly where we are jumping to on return (Disabled for high-speed VM boot)
    // debug.printf("[HV] -> Return to PC=0x{x} mode={s}\n", .{ ms.mepc, if ((ms.mstatus & riscv.MSTATUS.MPV) != 0) "virtual" else "host" });

    if (riscv.hasHExtension()) {
        if (vc.guest.space.mode == .h_paging) {
            vc.machine.hgatp = vc.guest.space.paging.?.hgatp(vc.guest.vmid);
        }
        riscv.writeHstatus(ms.hstatus);
        riscv.writeHgatp(ms.hgatp);

        // If the guest has programmed a timer via vstimecmp (Sstc), ensure we clear any stale
        // software-injected VSTIP bit in hvip so the hardware can manage the interrupt natively.
        var hvip_val = ms.hvip;
        if (gs.vstimecmp != 0) {
            hvip_val &= ~@as(usize, riscv.HVIP.VSTIP);
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
        riscv.writeVstimecmp(gs.vstimecmp);
        riscv.writeVsenvcfg(gs.vsenvcfg);

        // Flush any G-stage TLB entries to ensure any page table updates are immediately active.
        riscv.hfenceGvma();
    }
}

fn handle_exception(irq: IRQ, context: *riscv.ThreadContext) void {
    if (irq.privilege_mode == .machine) {
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
                    instr = riscv.hlv_wu(irq.pc);
                }

                // Check if it's an access to siselect (0x150 or 0x015), sireg (0x151 or 0x016), vsiselect (0x250 or 0x215), vsireg (0x251 or 0x216),
                // siselecth (0xdb0), siregh (0xdb4), vsiselecth (0xeb0), vsiregh (0xeb4),
                // or senvcfg (0x10A), vsenvcfg (0x20A)
                const opcode = instr & 0x7f;
                const csr = (instr >> 20) & 0xfff;
                const is_seed_csr = (csr == 0x015);
                const is_aia_csr = (csr == 0x016 or csr == 0x215 or csr == 0x216 or
                                    csr == 0x150 or csr == 0x151 or csr == 0x250 or csr == 0x251 or
                                    csr == 0xdb0 or csr == 0xdb4 or csr == 0xeb0 or csr == 0xeb4);
                const is_envcfg_csr = (csr == 0x10a or csr == 0x20a);
                if (opcode == 0x73 and (is_aia_csr or is_envcfg_csr or is_seed_csr)) {
                    const rd = (instr >> 7) & 0x1f;
                    const rs1 = (instr >> 15) & 0x1f;
                    const funct3 = (instr >> 12) & 0x7;

                    // Determine previous value to return in rd
                    var old_val: usize = 0;
                    if (csr == 0x015) {
                        // RISC-V Entropy Source Extension (Zkr): Return ES16 status (0x80000000)
                        // combined with 16 bits of pseudo-random entropy from hardware time.
                        const time_now = riscv.readTime();
                        const entropy = (time_now ^ (time_now >> 16)) & 0xffff;
                        old_val = 0x80000000 | entropy;
                        debug.printf("[HV] Zkr seed read: time=0x{x} entropy=0x{x} old_val=0x{x}\n", .{ time_now, entropy, old_val });
                    } else if (csr == 0x215 or csr == 0x150 or csr == 0x250 or csr == 0xdb0 or csr == 0xeb0) {
                        old_val = vc.siselect;
                    } else if (csr == 0x10a or csr == 0x20a) {
                        old_val = vc.guest_state.vsenvcfg;
                    } else {
                        // sireg/siregh always returns 0 for our emulation
                        old_val = 0;
                    }

                    // Write new value based on instruction type
                    if (funct3 == 1) { // CSRRW
                        const new_val = if (rs1 == 0) 0 else context[rs1];
                        if (csr == 0x215 or csr == 0x150 or csr == 0x250 or csr == 0xdb0 or csr == 0xeb0) {
                            vc.siselect = new_val;
                        } else if (csr == 0x10a or csr == 0x20a) {
                            vc.guest_state.vsenvcfg = new_val;
                        }
                    } else if (funct3 == 2) { // CSRRS
                        if (rs1 != 0) {
                            const val_to_set = context[rs1];
                            if (csr == 0x215 or csr == 0x150 or csr == 0x250 or csr == 0xdb0 or csr == 0xeb0) {
                                vc.siselect |= val_to_set;
                            } else if (csr == 0x10a or csr == 0x20a) {
                                vc.guest_state.vsenvcfg |= val_to_set;
                            }
                        }
                    } else if (funct3 == 3) { // CSRRC
                        if (rs1 != 0) {
                            const val_to_clear = context[rs1];
                            if (csr == 0x215 or csr == 0x150 or csr == 0x250 or csr == 0xdb0 or csr == 0xeb0) {
                                vc.siselect &= ~val_to_clear;
                            } else if (csr == 0x10a or csr == 0x20a) {
                                vc.guest_state.vsenvcfg &= ~val_to_clear;
                            }
                        }
                    } else if (funct3 == 5) { // CSRRWI
                        if (csr == 0x215 or csr == 0x150 or csr == 0x250 or csr == 0xdb0 or csr == 0xeb0) {
                            vc.siselect = rs1;
                        } else if (csr == 0x10a or csr == 0x20a) {
                            vc.guest_state.vsenvcfg = rs1;
                        }
                    } else if (funct3 == 6) { // CSRRSI
                        if (csr == 0x215 or csr == 0x150 or csr == 0x250 or csr == 0xdb0 or csr == 0xeb0) {
                            vc.siselect |= rs1;
                        } else if (csr == 0x10a or csr == 0x20a) {
                            vc.guest_state.vsenvcfg |= rs1;
                        }
                    } else if (funct3 == 7) { // CSRRCI
                        if (csr == 0x215 or csr == 0x150 or csr == 0x250 or csr == 0xdb0 or csr == 0xeb0) {
                            vc.siselect &= ~rs1;
                        } else if (csr == 0x10a or csr == 0x20a) {
                            vc.guest_state.vsenvcfg &= ~rs1;
                        }
                    }

                    if (rd != 0) {
                        context[rd] = old_val;
                        vc.context[rd] = old_val;
                    }

                    vc.machine.mepc += 4;
                    pcore.this().trap_loop_count = 0; // Reset loop detector
                    if (false) {
                        if (csr == 0x10a or csr == 0x20a) {
                            debug.printf("[HV] Core {} VCore {}: Emulated CSR 0x{x} access at PC=0x{x} vsenvcfg=0x{x}\n", .{ pcpu.cpu_core_id, vc.id, csr, irq.pc, vc.guest_state.vsenvcfg });
                        } else {
                            debug.printf("[HV] Core {} VCore {}: Emulated CSR 0x{x} access at PC=0x{x} siselect=0x{x}\n", .{ pcpu.cpu_core_id, vc.id, csr, irq.pc, vc.siselect });
                        }
                    }
                    return;
                }

                // Emulate rdtime / csrr rd, time
                const rdtime_inst: u32 = (0xc01 << 20) | (2 << 12) | (0x1c << 2) | 3;
                const rdtime_mask: u32 = ~@as(u32, 0x1f << 7);

                if ((instr & rdtime_mask) == rdtime_inst) {
                    const time_now = riscv.readTime();
                    const rd = (instr >> 7) & 0x1f;

                    // Fix register corruption: write to both the stack copy (context) and the stored vc.context.
                    context[rd] = @as(usize, time_now);
                    vc.context[rd] = @as(usize, time_now);
                    vc.machine.mepc += 4;
                    pcore.this().trap_loop_count = 0; // Reset loop detector

                    if (false) {
                        debug.printf("Emulated rdtime: time=0x{x} rd={} pc=0x{x}\n", .{ time_now, rd, irq.pc });
                    }
                    return;
                }

                // Emulate FENCE.I (opcode 0x0000100f) - instruction fence
                // This is safe to emulate as NOP since QEMU maintains I-cache coherency.
                if (instr == 0x0000100f) {
                    vc.machine.mepc += 4;
                    pcore.this().trap_loop_count = 0;
                    return;
                }

                // Emulate WFI (opcode 0x10500073) - wait for interrupt
                // In VS-mode, WFI may trap as illegal. We yield to the scheduler.
                if (instr == 0x10500073) {
                    vc.machine.mepc += 4;
                    pcore.this().trap_loop_count = 0;
                    scheduler.schedule();
                    return;
                }

                // Emulate FENCE (opcode matches: low 7 bits = 0x0f, funct3 = 0)
                // Various FENCE encodings that might trap from VS-mode
                if ((instr & 0x7f) == 0x0f and ((instr >> 12) & 0x7) == 0) {
                    vc.machine.mepc += 4;
                    pcore.this().trap_loop_count = 0;
                    return;
                }

                // Unrecognized instruction — log it once then reflect to guest
                {
                    if (pcore.this().trap_loop_count < 2) {
                        debug.printf("[HV] Unhandled illegal instruction 0x{x} at PC=0x{x} — reflecting to guest\n", .{ instr, irq.pc });
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
                sbi.handle(vc, context);
            }
        },
        .guest_instruction_page_fault, .guest_load_page_fault, .guest_store_page_fault, .unknown => {
            // Some implementations might use 21 (unknown) for other guest faults.
            // Only handle as fault if it's within the known guest fault range or matches unknown.
            if (@intFromEnum(irq.cause) == 21 or irq.irq_type == .exception) {
                const pcpu = pcore.this();
                if (pcpu.active_vcore) |vc_raw| {
                    const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
                    // Try to get Guest Physical Address from mtval2 or htval
                    const mtval2 = riscv.readMtval2();
                    const htval_val = riscv.readHtval();
                    var gpa = mtval2;
                    if (gpa == 0) gpa = htval_val;

                    if (false) {
                        debug.printf("[HV] Guest Fault: cause={s} (0x{x}) pc=0x{x} val=0x{x} gpa=0x{x}\n", .{ @tagName(irq.cause), @intFromEnum(irq.cause), irq.pc, irq.val, gpa });
                    }

                    // As per RISC-V Privileged / Hypervisor specification, mtval2 and htval
                    // hold the guest physical address shifted right by 2 bits.
                    if (gpa != 0) {
                        gpa = gpa << 2;
                    }

                    if (gpa == 0) {
                        // First-stage (VS-stage) page fault! Reflect to guest as standard page fault.
                        var reflected_irq = irq;
                        reflected_irq.cause = switch (irq.cause) {
                            .guest_instruction_page_fault => .instruction_page_fault,
                            .guest_load_page_fault => .load_page_fault,
                            .guest_store_page_fault => .store_page_fault,
                            else => irq.cause,
                        };
                        if (false) {
                            debug.printf("Guest VS-stage Page Fault: core={} pc=0x{x} cause={s} (0x{x}) val=0x{x} - reflecting\n", .{ pcpu.cpu_core_id, irq.pc, @tagName(reflected_irq.cause), @intFromEnum(reflected_irq.cause), irq.val });
                        }
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
                    if (false) {
                        debug.printf("Guest Exception: core={} pc=0x{x} cause={s} (0x{x}) val=0x{x} - reflecting\n", .{ pcpu.cpu_core_id, irq.pc, @tagName(irq.cause), @intFromEnum(irq.cause), irq.val });
                    }
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
            if (pcpu.active_vcore) |vc_raw| {
                const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
                // Only inject virtual timer interrupt if the guest explicitly scheduled a legacy timer via SBI,
                // and the guest is not using Sstc (vstimecmp).
                // If the guest is using vstimecmp, the hardware handles VSTIP natively and writing VSTIP to hvip
                // will permanently assert it, causing an infinite loop of guest interrupts.
                if (vc.timer_scheduled) {
                    if (false) {
                        debug.printf("IRQ: Injecting virtual timer interrupt (VSTIP) for guest {}\n", .{vc.guest_id});
                    }
                    vc.machine.hvip |= riscv.HVIP.VSTIP;
                    vc.timer_scheduled = false; // Reset scheduling state until next event
                }
            }
            // Clear hardware timer condition by setting it far into the future
            // until the guest (or hypervisor) sets a new one.
            riscv.setTimer(0xffffffffffffffff);
        },
        .machine_swi => {
            // Clear the CLINT MSIP register for the current physical CPU core
            const msip_ptr = @as(*volatile u32, @ptrFromInt(0x02000000 + 4 * pcpu.cpu_core_id));
            msip_ptr.* = 0;
        },
        .machine_interrupt => {
            // Machine external interrupt (MEIP) from the PLIC.
            // For now, log and inject VSEIP into the guest.
            debug.printf("MEI: Machine external interrupt on core {}\n", .{pcpu.cpu_core_id});
            if (pcpu.active_vcore) |vc_raw| {
                const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));
                vc.machine.hvip |= riscv.HVIP.VSEIP;
            }
        },
        else => {
            debug.printf("Unhandled interrupt: 0x{x}\n", .{@intFromEnum(irq.cause)});
        },
    }
}

// Reflect an exception back to the guest supervisor
fn reflectExceptionToGuest(vc: *vcore.VirtualCore, irq: IRQ) !void {
    if (!riscv.hasHExtension()) return error.NoHExtension;

    const ms = &vc.machine;
    const gs = &vc.guest_state;

    // 1. Save fault context in VS-mode registers
    gs.vsepc = irq.pc;
    gs.vscause = @intFromEnum(irq.cause);
    gs.vstval = irq.val;

    // 2. Modify SSTATUS/VSSTATUS:
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

    // 2b. Ensure we enter VS-mode (Supervisor + Virtualization)
    ms.mstatus &= ~@as(usize, riscv.MSTATUS.MPP_MASK);
    ms.mstatus |= (@as(usize, 1) << riscv.MSTATUS.MPP_SHIFT);
    ms.mstatus |= riscv.MSTATUS.MPV;

    // Handle both direct and vectored modes
    const base = gs.vstvec & ~@as(usize, 0b11);
    const mode = gs.vstvec & 0b11;

    if (base == 0) {
        debug.printf("FATAL: Reflecting exception to NULL vstvec — terminating guest.\n", .{});
        vc.getGuest().terminate();
        return error.NoHExtension; // Abort reflection.
    }

    if (mode == 0) {
        ms.mepc = base;
    } else {
        // Vectored mode: base + 4 * cause
        ms.mepc = base + 4 * (@intFromEnum(irq.cause) & 0x7FFFFFFFFFFFFFFF);
    }
    if (false) {
        debug.printf("[HV] Reflecting: trap PC=0x{x} -> guest handler=0x{x} mode={s}\n", .{ irq.pc, ms.mepc, if (mode == 0) "direct" else "vectored" });
    }

    // 4. Update hstatus.SPVP to reflect the privilege mode we're coming from
    ms.hstatus &= ~riscv.HSTATUS.SPVP;
    if (irq.privilege_mode == .supervisor) {
        ms.hstatus |= riscv.HSTATUS.SPVP;
    }
}

var fatal_exception_active = std.atomic.Value(bool).init(false);

fn fatal_exception(irq: IRQ) void {
    if (fatal_exception_active.swap(true, .seq_cst)) {
        // Recursive fatal exception! Direct raw UART write and halt immediately.
        debug.hw_putchar('\n');
        debug.hw_putchar('!');
        debug.hw_putchar('R');
        debug.hw_putchar('E');
        debug.hw_putchar('C');
        debug.hw_putchar('!');
        debug.hw_putchar('\n');
        while (true) {}
    }

    debug.releaseLocksForCrash();
    debug.printf("\n*** FATAL EXCEPTION ***\n", .{});
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
