// RISC-V Hypervisor-extension (H-mode) CSRs and Virtual-Machine Load Helpers.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const csr = @import("../csr.zig");

const is_test = builtin.is_test;

pub inline fn readHstatus() usize {
    if (is_test) return csr.test_hstatus;
    return asm volatile ("csrr %[ret], hstatus"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeHstatus(val: usize) void {
    if (is_test) {
        csr.test_hstatus = val;
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
    if (is_test) return csr.test_henvcfg;
    return asm volatile ("csrr %[ret], henvcfg"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeHenvcfg(val: usize) void {
    if (is_test) {
        csr.test_henvcfg = val;
        return;
    }
    asm volatile ("csrw henvcfg, %[val]"
        :
        : [val] "r" (val),
    );
}

pub inline fn readHgatp() usize {
    if (is_test) return csr.test_hgatp;
    return asm volatile ("csrr %[ret], hgatp"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn writeHgatp(val: usize) void {
    if (is_test) {
        csr.test_hgatp = val;
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

test "H-extension CSR helpers and virtual load stubs" {
    std.testing.refAllDecls(@This());
    csr.resetMockCsrs();
    defer csr.resetMockCsrs();

    writeHstatus(0x180);
    try std.testing.expectEqual(@as(usize, 0x180), readHstatus());
    try std.testing.expectEqual(@as(u32, 0), hlv_wu(0));
}
