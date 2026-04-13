// RISC-V non-hardware-specific routines.
//
// Copyright (c) 2024, 2025, 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const alloc = @import("alloc.zig");
const dsa = @import("dsa.zig");
const interface = @import("interface").riscv;

pub const Register = interface.Register;
pub const PrivilegeMode = interface.PrivilegeMode;
pub const IsaExtension = interface.IsaExtension;
pub const Cause = interface.Cause;
pub const MSTATUS = interface.MSTATUS;
pub const SSTATUS = interface.SSTATUS;
pub const HSTATUS = interface.HSTATUS;
pub const HVIP = interface.HVIP;
pub const toCause = interface.toCause;

const is_test = builtin.is_test;

// Mock CSR state for tests.
var mock_csrs = if (is_test) std.StaticStringMap(usize).initComptime(.{
    .{ "mstatus", 0 },
    .{ "mcause", 0 },
    .{ "mepc", 0 },
    .{ "mtval", 0 },
    .{ "misa", (1 << 30) | (1 << 7) | (1 << 18) | (1 << 20) }, // RV64 + H + S + U
}) else {};

// For dynamic CSRs in tests, use a simple array or similar if needed.
// Actually, let's just use global variables for common CSRs to simplify.
var test_mstatus: usize = 0;
var test_mcause: usize = 0;
var test_mepc: usize = 0;
var test_mtval: usize = 0;
var test_misa: usize = (1 << 53) | IsaExtension.h | IsaExtension.gc; // RV64 is bit 63 in MXL, but for simple 64-bit mask we use (1 << 63)
var test_hstatus: usize = 0;
var test_hgatp: usize = 0;

// RISC-V 64-bit MXL for MISA
const MISA_MXL_64: usize = 1 << 63;

extern fn hw_putchar(c: u8) void;
extern fn hw_getchar() i16;
extern fn hw_set_timer(stime: u64) void;
extern fn hw_private_variables() *CpuContext;
extern fn hw_heap_base() usize;
extern fn hw_heap_size() usize;
extern fn hw_reboot() void;
extern fn hw_shutdown() void;
extern fn hw_pause() void;
extern fn hw_pmp_init() void;

// Provide mock symbols for hw_putchar and hw_pause when testing
// so that debug output is silently discarded by the test harness.
fn hw_putchar_mock(_: u8) callconv(.c) void {}
fn hw_pause_mock() callconv(.c) void {}
fn hw_pmp_init_mock() callconv(.c) void {}

comptime {
    if (is_test) {
        @export(&hw_putchar_mock, .{ .name = "hw_putchar", .linkage = .strong });
        @export(&hw_pause_mock, .{ .name = "hw_pause", .linkage = .strong });
        @export(&hw_pmp_init_mock, .{ .name = "hw_pmp_init", .linkage = .strong });
    }
}

// Define mock hardware variables for tests.
var test_cpu_ctx: CpuContext = undefined;
var test_heap: [1024 * 1024]u8 align(4096) = undefined;

pub export fn hw_private_variables_mock() *CpuContext {
    return &test_cpu_ctx;
}
pub export fn hw_heap_base_mock() usize {
    return @intFromPtr(&test_heap);
}
pub export fn hw_heap_size_mock() usize {
    return test_heap.len;
}

// Each thread context is the contents of its 32 general purpose CPU registers.
pub const ThreadContext = [32]usize;

// The per-CPU context for the physical core running this thread.
pub const CpuContext = struct {
    cpu_core_id: usize,
    allocator: alloc.HeapAllocator,

    // The currently running virtual core on this physical core.
    // This is typed as ?*anyopaque to avoid circular dependency with vcore.zig.
    active_vcore: ?*anyopaque,

    // Per-CPU lock-free (contention-free) run queue.
    run_queue: dsa.RedBlackTree(u64, dsa.compareU64),
    run_queue_count: usize,

    trap_count: usize,
};

// Return a pointer to the CPU context for the core running this thread.
pub inline fn getCPUContext() *CpuContext {
    if (is_test) return &test_cpu_ctx;
    return hw_private_variables();
}

// Return the base address of the heap for the core running this thread.
pub inline fn getCPUHeapBase() usize {
    if (is_test) return @intFromPtr(&test_heap);
    return hw_heap_base();
}

// Return the size of the heap for the core running this thread.
pub inline fn getCPUHeapSize() usize {
    if (is_test) return test_heap.len;
    return hw_heap_size();
}

// Initialize the heap allocator for the CPU core running this thread.
pub fn initCPUHeapAllocator() !void {
    const cpu_context = getCPUContext();
    try cpu_context.allocator.init(getCPUHeapBase(), getCPUHeapSize());
}

// Return a standard Zig allocator for the CPU core running this thread.
pub fn getCPUHeapAllocator() alloc.Allocator {
    const cpu_context = getCPUContext();
    return cpu_context.allocator.allocator();
}

// Return the mcause CSR.
pub inline fn readMcause() usize {
    if (is_test) return test_mcause;
    return asm volatile ("csrr %[ret], mcause"
        : [ret] "=r" (-> usize),
    );
}

// Perform a memory fence for read/write on all harts.
pub inline fn fence() void {
    if (is_test) return;
    asm volatile ("fence rw, rw");
}

// Return the mepc CSR.
pub inline fn readMepc() usize {
    if (is_test) return test_mepc;
    return asm volatile ("csrr %[ret], mepc"
        : [ret] "=r" (-> usize),
    );
}

// Return the mvendorid CSR.
pub inline fn readMvendorid() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], mvendorid"
        : [ret] "=r" (-> usize),
    );
}

// Return the marchid CSR.
pub inline fn readMarchid() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], marchid"
        : [ret] "=r" (-> usize),
    );
}

// Return the mimpid CSR.
pub inline fn readMimpid() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], mimpid"
        : [ret] "=r" (-> usize),
    );
}

// Write to the mepc CSR.
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

// Return the mtval CSR.
pub inline fn readMtval() usize {
    if (is_test) return test_mtval;
    return asm volatile ("csrr %[ret], mtval"
        : [ret] "=r" (-> usize),
    );
}

// Return the mstatus CSR.
pub inline fn readMstatus() usize {
    if (is_test) return test_mstatus;
    return asm volatile ("csrr %[ret], mstatus"
        : [ret] "=r" (-> usize),
    );
}

// Write to the mstatus CSR.
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

// Return the misa CSR (0 if not supported or restricted).
pub inline fn readMisa() usize {
    if (is_test) return test_misa;
    return asm volatile ("csrr %[ret], misa"
        : [ret] "=r" (-> usize),
    );
}

// Check if the H (hypervisor) extension is supported.
pub fn hasHExtension() bool {
    const misa = readMisa();
    if (misa == 0) return false;
    return (misa & IsaExtension.h) != 0;
}

pub fn getPreviousPrivilege() PrivilegeMode {
    const mstatus = readMstatus();
    return @enumFromInt((mstatus & MSTATUS.MPP_MASK) >> MSTATUS.MPP_SHIFT);
}

// ---- H-extension CSRs ----

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

pub fn setTimer(stime: u64) void {
    if (is_test) return;
    hw_set_timer(stime);
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

// Reboot the host machine.
pub fn reboot() void {
    if (builtin.is_test) return;
    hw_reboot();
}

// Shutdown the host machine.
pub fn shutdown() void {
    if (builtin.is_test) return;
    hw_shutdown();
}

pub fn pause() void {
    if (builtin.is_test) return;
    hw_pause();
}
