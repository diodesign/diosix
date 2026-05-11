// RISC-V non-hardware-specific routines.
//
// Copyright (c) 2024, 2025, 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const alloc = @import("alloc.zig");
const dsa = @import("dsa.zig");
const debug = @import("debug.zig");
const interface = @import("interface").riscv;

pub const Register = interface.Register;
pub const PrivilegeMode = interface.PrivilegeMode;
pub const IsaExtension = interface.IsaExtension;
pub const Cause = interface.Cause;
pub const MSTATUS = interface.MSTATUS;
pub const SSTATUS = interface.SSTATUS;
pub const HSTATUS = struct {
    pub const GVA: usize = 1 << 6;
    pub const SPV: usize = 1 << 7;
    pub const SPVP: usize = 1 << 8;
    pub const HU: usize = 1 << 9;
    pub const VGEIN_MASK: usize = 0x3f << 12;
    pub const VGEIN_SHIFT: usize = 12;
    pub const VTVM: usize = 1 << 20;
    pub const VTW: usize = 1 << 21;
    pub const VTSR: usize = 1 << 22;
};
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
pub var test_time: u64 = 0;

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

// Provide mock symbols for hardware functions when testing
fn hw_putchar_mock(_: u8) callconv(.c) void {}
fn hw_pause_mock() callconv(.c) void {}
fn hw_pmp_init_mock() callconv(.c) void {}
fn hw_reboot_mock() callconv(.c) void {}
fn hw_shutdown_mock() callconv(.c) void {}
fn hw_set_timer_mock(_: u64) callconv(.c) void {}
fn hw_xint_init_mock() callconv(.c) void {}
fn hw_run_vcore_mock(_: *ThreadContext, _: *const MachineState, _: *const GuestState) callconv(.c) noreturn {
    while (true) {}
}

comptime {
    if (is_test) {
        @export(&hw_putchar_mock, .{ .name = "hw_putchar", .linkage = .strong });
        @export(&hw_pause_mock, .{ .name = "hw_pause", .linkage = .strong });
        @export(&hw_pmp_init_mock, .{ .name = "hw_pmp_init", .linkage = .strong });
        @export(&hw_reboot_mock, .{ .name = "hw_reboot", .linkage = .strong });
        @export(&hw_shutdown_mock, .{ .name = "hw_shutdown", .linkage = .strong });
        @export(&hw_set_timer_mock, .{ .name = "hw_set_timer", .linkage = .strong });
        @export(&hw_private_variables_mock, .{ .name = "hw_private_variables", .linkage = .strong });
        @export(&hw_heap_base_mock, .{ .name = "hw_heap_base", .linkage = .strong });
        @export(&hw_heap_size_mock, .{ .name = "hw_heap_size", .linkage = .strong });
        @export(&hw_xint_init_mock, .{ .name = "hw_xint_init", .linkage = .strong });
        @export(&hw_run_vcore_mock, .{ .name = "hw_run_vcore", .linkage = .strong });
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

pub fn initMockHardware() void {
    if (!is_test) return;
    test_cpu_ctx.cpu_core_id = 0;
    test_cpu_ctx.active_vcore = null;
    test_cpu_ctx.trap_count = 0;
    test_cpu_ctx.last_trap_pc = 0;
    test_cpu_ctx.trap_loop_count = 0;
    test_cpu_ctx.run_queue_count = 0;
    test_cpu_ctx.run_queue.init();

    test_mstatus = 0;
    test_mcause = 0;
    test_mepc = 0;
    test_mtval = 0;
    test_misa = MISA_MXL_64 | IsaExtension.h | IsaExtension.gc;
    test_hstatus = 0;
    test_hgatp = 0;
    test_time = 0;
    @memset(&test_heap,0);
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
    
    // Aegis: Trap loop detection fields
    last_trap_pc: usize,
    trap_loop_count: usize,
};

// Machine and Hypervisor specific architecture state
pub const MachineState = struct {
    mepc: usize,
    mstatus: usize,
    hstatus: usize,
    hgatp: usize,
    hvip: usize,
    hedeleg: usize,
    hideleg: usize,
};

// VS-mode (Guest Supervisor) architecture state
pub const GuestState = struct {
    vsstatus: usize,
    vsie: usize,
    vstvec: usize,
    vsscratch: usize,
    vsepc: usize,
    vscause: usize,
    vstval: usize,
    vsatp: usize,
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

pub inline fn hlv_w(ptr: usize) u32 {
    var val: u32 = 0;
    asm volatile (
        \\ .attribute arch, "rv64gc_zicsr_h"
        \\ hlv.w %[val], (%[ptr])
        : [val] "=r" (val)
        : [ptr] "r" (ptr)
    );
    return val;
}

pub inline fn hlv_wu(ptr: usize) u32 {
    var val: u32 = 0;
    asm volatile (
        \\ .attribute arch, "rv64gc_zicsr_h"
        \\ hlv.wu %[val], (%[ptr])
        : [val] "=r" (val)
        : [ptr] "r" (ptr)
    );
    return val;
}

pub inline fn hlv_hu(ptr: usize) u16 {
    var val: u16 = 0;
    asm volatile (
        \\ .attribute arch, "rv64gc_zicsr_h"
        \\ hlv.hu %[val], (%[ptr])
        : [val] "=r" (val)
        : [ptr] "r" (ptr)
    );
    return val;
}

pub inline fn hlv_bu(ptr: usize) u8 {
    var val: u8 = 0;
    asm volatile (
        \\ .attribute arch, "rv64gc_zicsr_h"
        \\ hlv.bu %[val], (%[ptr])
        : [val] "=r" (val)
        : [ptr] "r" (ptr)
    );
    return val;
}

pub inline fn hlv_d(ptr: usize) u64 {
    var val: u64 = 0;
    asm volatile (
        \\ .attribute arch, "rv64gc_zicsr_h"
        \\ hlv.d %[val], (%[ptr])
        : [val] "=r" (val)
        : [ptr] "r" (ptr)
    );
    return val;
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

pub inline fn readMtval2() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], 0x344"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn readMtinst() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], 0x34a"
        : [ret] "=r" (-> usize),
    );
}

pub fn verifyHExtension() !void {
    if (is_test) return;
    
    // Test 1: hgatp persistence
    const val_hgatp: u64 = (8 << 60) | (1 << 44) | 0x82edc;
    writeHgatp(val_hgatp);
    const read_hgatp = readHgatp();
    if (read_hgatp != val_hgatp) {
        debug.printf("[HV] CRITICAL: hgatp write failure. Wrote 0x{x}, read back 0x{x}\n", .{val_hgatp, read_hgatp});
        return error.HardwareIncompatible;
    }

    // Test 2: mstatus.MPV persistence
    const initial_mstatus = readMstatus();
    writeMstatus(initial_mstatus | MSTATUS.MPV);
    const mstatus_with_v = readMstatus();
    writeMstatus(initial_mstatus); // Restore
    if ((mstatus_with_v & MSTATUS.MPV) == 0) {
        debug.printf("[HV] CRITICAL: mstatus.MPV write failure. H-extension disabled or broken?\n", .{});
        return error.HardwareIncompatible;
    }
    
    debug.printf("[HV] H-extension architectural audit PASSED\n", .{});
}


pub fn setTimer(stime: u64) void {
    if (is_test) return;
    hw_set_timer(stime);
}

// Read the time CSR (or its memory-mapped equivalent via mtime).
// In M-mode on RISC-V, `time` may not be directly accessible; fall back to CLINT mtime.
pub inline fn readTime() u64 {
    if (is_test) return test_time;
    return asm volatile ("csrr %[ret], time"
        : [ret] "=r" (-> u64),
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

// ---- VS-mode (Guest Supervisor) CSRs ----

pub inline fn readVsstatus() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], vsstatus" : [ret] "=r" (-> usize));
}

pub inline fn writeVsstatus(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw vsstatus, %[val]" : : [val] "r" (val));
}

pub inline fn readVsie() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], vsie" : [ret] "=r" (-> usize));
}

pub inline fn writeVsie(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw vsie, %[val]" : : [val] "r" (val));
}

pub inline fn readVstvec() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], vstvec" : [ret] "=r" (-> usize));
}

pub inline fn writeVstvec(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw vstvec, %[val]" : : [val] "r" (val));
}

pub inline fn readVsscratch() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], vsscratch" : [ret] "=r" (-> usize));
}

pub inline fn writeVsscratch(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw vsscratch, %[val]" : : [val] "r" (val));
}

pub inline fn readVsepc() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], vsepc" : [ret] "=r" (-> usize));
}

pub inline fn writeVsepc(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw vsepc, %[val]" : : [val] "r" (val));
}

pub inline fn readVscause() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], vscause" : [ret] "=r" (-> usize));
}

pub inline fn writeVscause(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw vscause, %[val]" : : [val] "r" (val));
}

pub inline fn readVstval() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], vstval" : [ret] "=r" (-> usize));
}

pub inline fn writeVstval(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw vstval, %[val]" : : [val] "r" (val));
}

pub inline fn readVsatp() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], vsatp" : [ret] "=r" (-> usize));
}

pub inline fn writeVsatp(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw vsatp, %[val]" : : [val] "r" (val));
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
