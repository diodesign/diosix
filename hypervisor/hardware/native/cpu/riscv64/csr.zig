// RISC-V Machine-mode (M-mode) and Hypervisor-extension (H-mode) CSR helpers.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const interface = @import("interface").riscv;

const is_test = builtin.is_test;

pub const PrivilegeMode = interface.PrivilegeMode;
pub const IsaExtension = interface.IsaExtension;
pub const MSTATUS = interface.MSTATUS;

// RISC-V 64-bit MXL bit for MISA.
pub const MISA_MXL_64: usize = 1 << 63;

// Mock CSR state for host unit tests.
pub var test_mstatus: usize = 0;
pub var test_mcause: usize = 0;
pub var test_mepc: usize = 0;
pub var test_mtval: usize = 0;
pub var test_mie: usize = 0;
pub var test_mip: usize = 0;
pub var test_misa: usize = MISA_MXL_64 | IsaExtension.h | IsaExtension.gc;
pub var test_hstatus: usize = 0;
pub var test_hgatp: usize = 0;
pub var test_menvcfg: usize = 0;
pub var test_henvcfg: usize = 0;

pub fn resetMockCsrs() void {
    if (!is_test) return;
    test_mstatus = 0;
    test_mcause = 0;
    test_mepc = 0;
    test_mtval = 0;
    test_mie = 0;
    test_mip = 0;
    test_misa = MISA_MXL_64 | IsaExtension.h | IsaExtension.gc;
    test_hstatus = 0;
    test_hgatp = 0;
    test_menvcfg = 0;
    test_henvcfg = 0;
}

// ---- M-mode CSRs ----

pub inline fn readMcause() usize {
    if (is_test) return test_mcause;
    return asm volatile ("csrr %[ret], mcause"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn fence() void {
    if (is_test) return;
    asm volatile ("fence rw, rw");
}

pub inline fn flushIcache() void {
    if (is_test) return;
    asm volatile ("fence.i");
}

pub inline fn readRA() usize {
    if (is_test) return 0;
    return asm volatile ("mv %[ret], ra"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn readMepc() usize {
    if (is_test) return test_mepc;
    return asm volatile ("csrr %[ret], mepc"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeMepc(val: usize) void {
    if (is_test) {
        test_mepc = val;
        return;
    }
    asm volatile ("csrw mepc, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readMvendorid() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], mvendorid"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn readMarchid() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], marchid"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn readMimpid() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], mimpid"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn readMtval() usize {
    if (is_test) return test_mtval;
    return asm volatile ("csrr %[ret], mtval"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn readMstatus() usize {
    if (is_test) return test_mstatus;
    return asm volatile ("csrr %[ret], mstatus"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeMstatus(val: usize) void {
    if (is_test) {
        test_mstatus = val;
        return;
    }
    asm volatile ("csrw mstatus, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readMhartid() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], mhartid"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn readMie() usize {
    if (is_test) return test_mie;
    return asm volatile ("csrr %[ret], mie"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeMie(val: usize) void {
    if (is_test) {
        test_mie = val;
        return;
    }
    asm volatile ("csrw mie, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readMip() usize {
    if (is_test) return test_mip;
    return asm volatile ("csrr %[ret], mip"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeMip(val: usize) void {
    if (is_test) {
        test_mip = val;
        return;
    }
    asm volatile ("csrw mip, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readMisa() usize {
    if (is_test) return test_misa;
    return asm volatile ("csrr %[ret], misa"
        : [ret] "=r" (-> usize),
    );
}

pub fn hasHExtension() bool {
    const misa = readMisa();
    if (misa == 0) return false;
    return (misa & IsaExtension.h) != 0;
}

pub fn getPreviousPrivilege() PrivilegeMode {
    const mstatus = readMstatus();
    const raw_mpp = (mstatus & MSTATUS.MPP_MASK) >> MSTATUS.MPP_SHIFT;
    return @fromBackingInt(@intCast(raw_mpp));
}

pub inline fn writeMcounteren(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw mcounteren, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readMenvcfg() usize {
    if (is_test) return test_menvcfg;
    return asm volatile ("csrr %[ret], menvcfg"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeMenvcfg(val: usize) void {
    if (is_test) {
        test_menvcfg = val;
        return;
    }
    asm volatile ("csrw menvcfg, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readMedeleg() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], medeleg"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeMedeleg(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw medeleg, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readMideleg() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], mideleg"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeMideleg(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw mideleg, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readMtval2() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], 0x34b"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn readMtinst() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], 0x34a"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn readMstateen0() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], 0x30c"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeMstateen0(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw 0x30c, %[val]"
        :
        : [val] "r" (val),
    );
}

// ---- H-extension CSRs & Hypervisor Virtual-Machine Load Instructions ----

pub inline fn readHstatus() usize {
    if (is_test) return test_hstatus;
    return asm volatile ("csrr %[ret], hstatus"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeHstatus(val: usize) void {
    if (is_test) {
        test_hstatus = val;
        return;
    }
    asm volatile ("csrw hstatus, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn writeHcounteren(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw hcounteren, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readHenvcfg() usize {
    if (is_test) return test_henvcfg;
    return asm volatile ("csrr %[ret], henvcfg"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeHenvcfg(val: usize) void {
    if (is_test) {
        test_henvcfg = val;
        return;
    }
    asm volatile ("csrw henvcfg, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readHgatp() usize {
    if (is_test) return test_hgatp;
    return asm volatile ("csrr %[ret], hgatp"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeHgatp(val: usize) void {
    if (is_test) {
        test_hgatp = val;
        return;
    }
    asm volatile ("csrw hgatp, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn hfenceGvma() void {
    if (is_test) return;
    asm volatile ("hfence.gvma");
}

pub inline fn readHedeleg() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], hedeleg"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeHedeleg(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw hedeleg, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readHideleg() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], hideleg"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeHideleg(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw hideleg, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readHvip() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], hvip"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeHvip(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw hvip, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readHtval() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], htval"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn readHtinst() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], htinst"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeHstateen0(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw 0x60c, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn hlv_w(ptr: usize) u32 {
    if (comptime is_test) return 0;
    var val: u32 = 0;
    asm volatile (
        \\ .attribute arch, "rv64gc_zicsr_h"
        \\ hlv.w %[val], (%[ptr])
        : [val] "=r" (val),
        : [ptr] "r" (ptr),
    );
    return val;
}

pub inline fn hlv_wu(ptr: usize) u32 {
    if (comptime is_test) return 0;
    var val: u32 = 0;
    asm volatile (
        \\ .attribute arch, "rv64gc_zicsr_h"
        \\ hlv.wu %[val], (%[ptr])
        : [val] "=r" (val),
        : [ptr] "r" (ptr),
    );
    return val;
}

pub inline fn hlv_hu(ptr: usize) u16 {
    if (comptime is_test) return 0;
    var val: u16 = 0;
    asm volatile (
        \\ .attribute arch, "rv64gc_zicsr_h"
        \\ hlv.hu %[val], (%[ptr])
        : [val] "=r" (val),
        : [ptr] "r" (ptr),
    );
    return val;
}

pub inline fn hlv_bu(ptr: usize) u8 {
    if (comptime is_test) return 0;
    var val: u8 = 0;
    asm volatile (
        \\ .attribute arch, "rv64gc_zicsr_h"
        \\ hlv.bu %[val], (%[ptr])
        : [val] "=r" (val),
        : [ptr] "r" (ptr),
    );
    return val;
}

pub inline fn hlv_d(ptr: usize) u64 {
    if (comptime is_test) return 0;
    var val: u64 = 0;
    asm volatile (
        \\ .attribute arch, "rv64gc_zicsr_h"
        \\ hlv.d %[val], (%[ptr])
        : [val] "=r" (val),
        : [ptr] "r" (ptr),
    );
    return val;
}

test "M-mode and H-extension mock CSR read/write and privilege decoding" {
    const testing = std.testing;
    resetMockCsrs();
    defer resetMockCsrs();

    try testing.expect(hasHExtension());
    writeMstatus(@as(usize, 1) << MSTATUS.MPP_SHIFT);
    try testing.expectEqual(PrivilegeMode.supervisor, getPreviousPrivilege());

    writeMepc(0x80200000);
    try testing.expectEqual(@as(usize, 0x80200000), readMepc());

    writeHgatp(0x8000_0000_0008_2edc);
    try testing.expectEqual(@as(usize, 0x8000_0000_0008_2edc), readHgatp());
}
