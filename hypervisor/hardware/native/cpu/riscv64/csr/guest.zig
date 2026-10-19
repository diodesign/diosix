// RISC-V Virtual Supervisor (VS-mode) and Physical Supervisor (S-mode) CSRs.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const riscv = @import("../mod.zig");

const is_test = builtin.is_test;

// ---- VS-mode (Guest Supervisor) CSRs ----
// Note: The RISC-V H-extension does not define a separate 0x20a CSR; guest
// supervisor environment configuration is held in senvcfg (0x10a).

pub inline fn readVsenvcfg() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], 0x10a"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeVsenvcfg(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw 0x10a, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readVsstatus() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], vsstatus"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeVsstatus(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw vsstatus, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readVsie() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], vsie"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeVsie(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw vsie, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readVsip() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], vsip"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeVsip(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw vsip, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readVstvec() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], vstvec"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeVstvec(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw vstvec, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readVsscratch() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], vsscratch"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeVsscratch(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw vsscratch, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readVsepc() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], vsepc"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeVsepc(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw vsepc, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readVscause() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], vscause"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeVscause(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw vscause, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readVstval() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], vstval"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeVstval(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw vstval, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readVsatp() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], vsatp"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeVsatp(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw vsatp, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readVstimecmp() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], 0x24d"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeVstimecmp(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw 0x24d, %[val]"
        :
        : [val] "r" (val),
    );
}

// ---- Physical S-mode (Supervisor) CSRs for non-H fallback ----

pub inline fn readSstatus() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], sstatus"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeSstatus(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw sstatus, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readSie() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], sie"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeSie(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw sie, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readStvec() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], stvec"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeStvec(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw stvec, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readSscratch() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], sscratch"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeSscratch(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw sscratch, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readSepc() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], sepc"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeSepc(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw sepc, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readScause() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], scause"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeScause(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw scause, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readStval() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], stval"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeStval(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw stval, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readSatp() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], satp"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeSatp(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw satp, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readStimecmp() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], 0x14d"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeStimecmp(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw 0x14d, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readSenvcfg() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], 0x10a"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeSenvcfg(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw 0x10a, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn sfenceVma() void {
    if (is_test) return;
    asm volatile ("sfence.vma");
}

// ---- Bulk GuestState Hardware Save / Restore Helpers ----

pub fn saveVsState(gs: *riscv.GuestState) void {
    gs.vsstatus = readVsstatus();
    gs.vsie = readVsie();
    gs.vstvec = readVstvec();
    gs.vsscratch = readVsscratch();
    gs.vsepc = readVsepc();
    gs.vscause = readVscause();
    gs.vstval = readVstval();
    gs.vsatp = readVsatp();
    if (!config.legacy_cpu) {
        if (riscv.riscv_supports_sstc) gs.vstimecmp = readVstimecmp();
        if (riscv.riscv_supports_smstateen) gs.vsenvcfg = readVsenvcfg();
    }
}

pub fn restoreVsState(gs: *const riscv.GuestState) void {
    writeVsstatus(gs.vsstatus);
    writeVsie(gs.vsie);
    writeVstvec(gs.vstvec);
    writeVsscratch(gs.vsscratch);
    writeVsepc(gs.vsepc);
    writeVscause(gs.vscause);
    writeVstval(gs.vstval);
    writeVsatp(gs.vsatp);
    if (!config.legacy_cpu) {
        var henvcfg_val: usize = riscv.ENVCFG.CACHE_OPS_ALL;
        if (riscv.riscv_supports_sstc) henvcfg_val |= riscv.ENVCFG.STCE;
        riscv.writeHenvcfg(henvcfg_val);
        if (riscv.riscv_supports_sstc) writeVstimecmp(gs.vstimecmp);
        if (riscv.riscv_supports_smstateen) writeVsenvcfg(gs.vsenvcfg);
    }
}

pub fn saveSState(gs: *riscv.GuestState) void {
    gs.vsstatus = readSstatus();
    gs.vsie = readSie();
    gs.vstvec = readStvec();
    gs.vsscratch = readSscratch();
    gs.vsepc = readSepc();
    gs.vscause = readScause();
    gs.vstval = readStval();
    gs.vsatp = readSatp();
    if (!config.legacy_cpu) {
        if (riscv.riscv_supports_sstc) gs.vstimecmp = readStimecmp();
        if (riscv.riscv_supports_smstateen) gs.vsenvcfg = readSenvcfg();
    }
}

pub fn restoreSState(gs: *const riscv.GuestState) void {
    writeSstatus(gs.vsstatus);
    writeSie(gs.vsie);
    writeStvec(gs.vstvec);
    writeSscratch(gs.vsscratch);
    writeSepc(gs.vsepc);
    writeScause(gs.vscause);
    writeStval(gs.vstval);
    writeSatp(gs.vsatp);
    if (!config.legacy_cpu) {
        if (riscv.riscv_supports_sstc) writeStimecmp(gs.vstimecmp);
        if (riscv.riscv_supports_smstateen) writeSenvcfg(gs.vsenvcfg);
    }
}

test "guest CSR save/restore helpers in test mode" {
    var gs: riscv.GuestState = std.mem.zeroes(riscv.GuestState);
    saveVsState(&gs);
    restoreVsState(&gs);
    saveSState(&gs);
    restoreSState(&gs);
    try std.testing.expectEqual(@as(usize, 0), gs.vsstatus);
}
