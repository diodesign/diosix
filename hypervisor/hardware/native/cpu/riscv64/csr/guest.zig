// RISC-V Virtual Supervisor (VS-mode) and Physical Supervisor (S-mode) CSRs.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const riscv = @import("../mod.zig");

const is_test = builtin.is_test;

pub var mock_vsstatus: u64 = 0;
pub var mock_sstatus: u64 = 0;

// ---- VS-mode (Guest Supervisor) CSRs ----
// Note: The RISC-V H-extension does not define a separate 0x20a CSR; guest
// supervisor environment configuration is held in senvcfg (0x10a).

pub inline fn readVsenvcfg() u64 {
    return readSenvcfg();
}

pub inline fn writeVsenvcfg(val: u64) void {
    writeSenvcfg(val);
}

pub inline fn readVsstatus() u64 {
    if (is_test) return mock_vsstatus;
    return asm volatile ("csrr %[ret], vsstatus"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn writeVsstatus(val: u64) void {
    if (is_test) {
        mock_vsstatus = val;
        return;
    }
    asm volatile ("csrw vsstatus, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readVsie() u64 {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], vsie"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn writeVsie(val: u64) void {
    if (is_test) return;
    asm volatile ("csrw vsie, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readVstvec() u64 {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], vstvec"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn writeVstvec(val: u64) void {
    if (is_test) return;
    asm volatile ("csrw vstvec, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readVsscratch() u64 {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], vsscratch"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn writeVsscratch(val: u64) void {
    if (is_test) return;
    asm volatile ("csrw vsscratch, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readVsepc() u64 {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], vsepc"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn writeVsepc(val: u64) void {
    if (is_test) return;
    asm volatile ("csrw vsepc, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readVscause() u64 {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], vscause"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn writeVscause(val: u64) void {
    if (is_test) return;
    asm volatile ("csrw vscause, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readVstval() u64 {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], vstval"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn writeVstval(val: u64) void {
    if (is_test) return;
    asm volatile ("csrw vstval, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readVsatp() u64 {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], vsatp"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn writeVsatp(val: u64) void {
    if (is_test) return;
    asm volatile ("csrw vsatp, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readVstimecmp() u64 {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], 0x24d"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn writeVstimecmp(val: u64) void {
    if (is_test) return;
    asm volatile ("csrw 0x24d, %[val]"
        :
        : [val] "r" (val),
    );
}

// ---- Physical S-mode (Supervisor) CSRs for non-H fallback ----

pub inline fn readSstatus() u64 {
    if (is_test) return mock_sstatus;
    return asm volatile ("csrr %[ret], sstatus"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn writeSstatus(val: u64) void {
    if (is_test) {
        mock_sstatus = val;
        return;
    }
    asm volatile ("csrw sstatus, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readSie() u64 {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], sie"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn writeSie(val: u64) void {
    if (is_test) return;
    asm volatile ("csrw sie, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readStvec() u64 {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], stvec"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn writeStvec(val: u64) void {
    if (is_test) return;
    asm volatile ("csrw stvec, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readSscratch() u64 {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], sscratch"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn writeSscratch(val: u64) void {
    if (is_test) return;
    asm volatile ("csrw sscratch, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readSepc() u64 {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], sepc"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn writeSepc(val: u64) void {
    if (is_test) return;
    asm volatile ("csrw sepc, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readScause() u64 {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], scause"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn writeScause(val: u64) void {
    if (is_test) return;
    asm volatile ("csrw scause, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readStval() u64 {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], stval"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn writeStval(val: u64) void {
    if (is_test) return;
    asm volatile ("csrw stval, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readSatp() u64 {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], satp"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn writeSatp(val: u64) void {
    if (is_test) return;
    asm volatile ("csrw satp, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readStimecmp() u64 {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], 0x14d"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn writeStimecmp(val: u64) void {
    if (is_test) return;
    asm volatile ("csrw 0x14d, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readSenvcfg() u64 {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], 0x10a"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn writeSenvcfg(val: u64) void {
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
    std.testing.refAllDecls(@This());
    mock_vsstatus = 0;
    mock_sstatus = 0;
    defer {
        mock_vsstatus = 0;
        mock_sstatus = 0;
    }

    var gs: riscv.GuestState = std.mem.zeroes(riscv.GuestState);
    gs.vsstatus = 0xdead_beef;
    restoreVsState(&gs);
    try std.testing.expectEqual(@as(u64, 0xdead_beef), mock_vsstatus);

    var saved_vs: riscv.GuestState = std.mem.zeroes(riscv.GuestState);
    saveVsState(&saved_vs);
    try std.testing.expectEqual(@as(u64, 0xdead_beef), saved_vs.vsstatus);

    gs.vsstatus = 0xcafe_babe;
    restoreSState(&gs);
    try std.testing.expectEqual(@as(u64, 0xcafe_babe), mock_sstatus);

    var saved_s: riscv.GuestState = std.mem.zeroes(riscv.GuestState);
    saveSState(&saved_s);
    try std.testing.expectEqual(@as(u64, 0xcafe_babe), saved_s.vsstatus);
}
