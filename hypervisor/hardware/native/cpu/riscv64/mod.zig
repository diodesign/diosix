// RISC-V non-hardware-specific routines.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const alloc = @import("../../../../core/alloc.zig");
const dsa = @import("../../../../core/dsa.zig");
const debug = @import("../../../../core/debug.zig");
const interface = @import("interface").riscv;
const config = @import("config");

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
pub const CSR = interface.CSR;
pub const Instr = interface.Instr;
pub var clint_base: ?usize = null;
pub var uart_base: ?usize = null;
pub var test_device_base: ?usize = null;
pub var plic_base: ?usize = null;

pub const CLINT = struct {
    // Standard CLINT register offsets
    pub const MTIMECMP_BASE = 0x4000;
    pub const MTIME_OFFSET = 0xbff8;

    pub fn msip(hart: usize) ?*volatile u32 {
        const base = clint_base orelse return null;
        return @ptrFromInt(base + 4 * hart);
    }
};

pub const SiFiveTest = struct {
    // SiFive test device finisher command codes
    pub const FINISHER_PASS = 0x5555;
    pub const FINISHER_RESET = 0x7777;
};

const is_test = builtin.is_test;

pub const MAX_PHYS_CORES = 256;

// Timer configuration constants
pub const TIMER_INFINITY: u64 = 0xffffffffffffffff;
pub const TIMESLICE_TICKS: u64 = 100_000; // 10ms at standard 10MHz RISC-V clock
pub const WATCHDOG_TICKS: u64 = 100_000_000; // 10s at standard 10MHz RISC-V clock
pub var cpu_to_hart_map = std.mem.zeroes([MAX_PHYS_CORES]usize);
pub var cpu_contexts = std.mem.zeroes([MAX_PHYS_CORES]?*CpuContext);

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
var test_mie: usize = 0;
var test_mip: usize = 0;
var test_misa: usize = (1 << 53) | IsaExtension.h | IsaExtension.gc; // RV64 is bit 63 in MXL, but for simple 64-bit mask we use (1 << 63)
var test_hstatus: usize = 0;
var test_hgatp: usize = 0;
pub var test_time: u64 = 0;
var test_menvcfg: usize = 0;
var test_henvcfg: usize = 0;

pub export var riscv_supports_sstc: bool = false;
pub export var riscv_supports_smstateen: bool = false;

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
    test_cpu_ctx.hardware_hart_id = 0;
    test_cpu_ctx.active_vcore = null;
    test_cpu_ctx.trap_count = 0;
    test_cpu_ctx.last_trap_pc = 0;
    test_cpu_ctx.last_trap_val = 0;
    test_cpu_ctx.trap_loop_count = 0;
    test_cpu_ctx.run_queue_count = 0;
    test_cpu_ctx.run_queue.init();

    test_mstatus = 0;
    test_mcause = 0;
    test_mepc = 0;
    test_mtval = 0;
    test_mie = 0;
    test_mip = 0;
    test_misa = MISA_MXL_64 | IsaExtension.h | IsaExtension.gc;
    test_hstatus = 0;
    test_hgatp = 0;
    test_time = 0;
    @memset(&test_heap, 0);
}

// Each thread context is the contents of its 32 general purpose CPU registers.
pub const ThreadContext = [32]usize;

// The per-CPU context for the physical core running this thread.
pub const CpuContext = struct {
    cpu_core_id: usize,
    hardware_hart_id: usize,
    allocator: alloc.HeapAllocator,

    // The currently running virtual core on this physical core.
    // This is typed as ?*anyopaque to avoid circular dependency with vcore.zig.
    active_vcore: ?*anyopaque,

    // Per-CPU lock-free (contention-free) run queue.
    run_queue: dsa.RedBlackTree(u64, dsa.compareU64),
    run_queue_count: usize,

    // Blocked queue for vcores waiting for interrupts (WFI).
    // Uses *anyopaque to avoid circular dependencies with vcore.zig.
    blocked_queue: dsa.LinkedList(*anyopaque),

    trap_count: usize,

    // Aegis: Trap loop detection fields
    last_trap_pc: usize,
    last_trap_val: usize,
    trap_loop_count: usize,

    probing_active: bool,
    probe_failed: bool,

    // True when this hart is executing in M-mode. Set on boot and trap entry,
    // cleared before mret to S-mode. Used by IRQ-safe spinlocks to decide
    // whether mstatus CSR access is safe (only valid from M-mode).
    in_m_mode: bool,

    // The vcore that went WFI-blocked on this physical core.
    // Only THIS core monitors its timer to avoid thundering herd.
    blocked_vcore: ?*anyopaque,

    // The last timer value written to CLINT mtimecmp for this physical CPU.
    // Used to avoid redundant MMIO writes that trigger BQL contention in QEMU.
    last_timer_val: u64,

    // Set when the G-stage page table is modified (demand paging).
    // Cleared after hfence.gvma. Prevents unnecessary TLB flushes
    // on ecall/timer returns that don't change page tables.
    gstage_dirty: bool,
};

// Machine and Hypervisor specific architecture state
pub const MachineState = extern struct {
    mepc: usize,
    mstatus: usize,
    hstatus: usize,
    hgatp: usize,
    hvip: usize,
    hedeleg: usize,
    hideleg: usize,
};

// VS-mode (Guest Supervisor) architecture state
pub const GuestState = extern struct {
    vsstatus: usize,
    vsie: usize,
    vstvec: usize,
    vsscratch: usize,
    vsepc: usize,
    vscause: usize,
    vstval: usize,
    vsatp: usize,
    vstimecmp: usize,
    vsenvcfg: usize,
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
    const heap_base = getCPUHeapBase();
    const heap_size = getCPUHeapSize();
    debug.printf("CPU Heap Init: base = 0x{x}, size = 0x{x} ({} MB)\n", .{ heap_base, heap_size, heap_size / 1024 / 1024 });
    try cpu_context.allocator.init(heap_base, heap_size);
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

// Return the mhartid CSR.
pub inline fn readMhartid() usize {
    if (is_test) return 0;
    return asm volatile ("csrr %[ret], mhartid"
        : [ret] "=r" (-> usize),
    );
}

// Return the mie CSR.
pub inline fn readMie() usize {
    if (is_test) return test_mie;
    return asm volatile ("csrr %[ret], mie"
        : [ret] "=r" (-> usize),
    );
}

// Return the mip CSR.
pub inline fn readMip() usize {
    if (is_test) return test_mip;
    return asm volatile ("csrr %[ret], mip"
        : [ret] "=r" (-> usize),
    );
}

// Write to the mip CSR.
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

// Write to the mie CSR.
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

pub inline fn writeHcounteren(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw hcounteren, %[val]"
        :
        : [val] "r" (val),
    );
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

pub fn auditCpuFeatures() !void {
    if (is_test) return;

    debug.printf("CPU features audit:\n", .{});

    const pcpu = getCPUContext();
    if (!config.legacy_cpu) {
        // Probe Smstateen (0x30c)
        pcpu.probing_active = true;
        pcpu.probe_failed = false;
        _ = readMstateen0();
        riscv_supports_smstateen = !pcpu.probe_failed;

        // Probe Sstc (0x14d) by verifying that writing to the supervisor comparator (stimecmp)
        // actually toggles the supervisor timer interrupt pending bit (STIP, bit 5) in mip.
        // The comparator is only active if the STCE bit (bit 63) in menvcfg is set, so we temporarily enable it.
        pcpu.probing_active = true;
        pcpu.probe_failed = false;

        const old_menvcfg = readMenvcfg();
        const stce_bit = @as(usize, 1) << 63;
        writeMenvcfg(old_menvcfg | stce_bit);

        const old_stimecmp = readStimecmp();

        writeStimecmp(0xffffffffffffffff);
        const mip_clear = readMip();

        writeStimecmp(0);
        const mip_set = readMip();

        writeStimecmp(old_stimecmp);
        writeMenvcfg(old_menvcfg);

        const stip_bit = @as(usize, 1) << 5; // STIP in mip
        const stip_cleared = (mip_clear & stip_bit) == 0;
        const stip_asserted = (mip_set & stip_bit) != 0;

        riscv_supports_sstc = !pcpu.probe_failed and stip_cleared and stip_asserted;

        // If Sstc is detected, keep menvcfg.STCE enabled so VS-mode can access
        // stimecmp (mapped to vstimecmp by hardware). Without STCE, guest
        // stimecmp accesses trap as illegal instruction.
        if (riscv_supports_sstc) {
            writeMenvcfg(old_menvcfg | stce_bit);
            // Clear the test STIP by setting stimecmp to infinity
            writeStimecmp(0xffffffffffffffff);
        }

        pcpu.probing_active = false;
    }

    const has_h = hasHExtension();

    // Print probed features in a clean, audited list
    debug.printf(" - Hardware virtualization (H) {s}\n", .{if (has_h) "detected" else "absent"});
    debug.printf(" - Enhanced isolation (Smstateen) {s}\n", .{if (riscv_supports_smstateen) "detected" else "absent"});
    debug.printf(" - Efficient timer interrupts (Sstc) {s}\n", .{if (riscv_supports_sstc) "detected" else "absent"});

    // Perform H-extension verification if detected
    if (has_h) {
        // Test 1: hgatp persistence
        const val_hgatp: u64 = (8 << 60) | (1 << 44) | 0x82edc;
        writeHgatp(val_hgatp);
        const read_hgatp = readHgatp();
        if (read_hgatp != val_hgatp) {
            debug.printf("CRITICAL: hgatp write failure. Wrote 0x{x}, read back 0x{x}\n", .{ val_hgatp, read_hgatp });
            return error.HardwareIncompatible;
        }

        // Test 2: mstatus.MPV persistence
        const initial_mstatus = readMstatus();
        writeMstatus(initial_mstatus | MSTATUS.MPV);
        const mstatus_with_v = readMstatus();
        writeMstatus(initial_mstatus); // Restore
        if ((mstatus_with_v & MSTATUS.MPV) == 0) {
            debug.printf("CRITICAL: mstatus.MPV write failure. H-extension disabled or broken?\n", .{});
            return error.HardwareIncompatible;
        }
    }
}

pub fn setTimer(stime: u64) void {
    if (is_test) return;
    const pcpu = getCPUContext();
    if (pcpu.last_timer_val == stime) return;
    pcpu.last_timer_val = stime;

    const drivers = @import("../../../../core/drivers.zig");
    if (drivers.timer) |drv| {
        drv.setTimer(stime);
    } else {
        const base = clint_base orelse 0x02000000;
        const mtimecmp_ptr = @as(*volatile u64, @ptrFromInt(base + CLINT.MTIMECMP_BASE + 8 * readMhartid()));
        mtimecmp_ptr.* = stime;
    }
}

// Read the time CSR. On RISC-V, `rdtime` reads the platform time counter
// directly via CSR, avoiding MMIO contention on the CLINT mtime register.
// MMIO reads to CLINT serialize all cores in QEMU through the BQL.
pub inline fn readTime() u64 {
    if (is_test) return test_time;
    return asm volatile ("rdtime %[ret]"
        : [ret] "=r" (-> u64),
    );
}

extern const __hypervisor_end: u8;

pub fn isHostTp(tp_val: usize) bool {
    if (is_test) return false;
    if (tp_val % 16 != 0) return false;

    const hv_end = @intFromPtr(&__hypervisor_end);
    const max_cores = MAX_PHYS_CORES;
    const cpu_slab_shift = 20; // 1MB per CPU slab
    const max_slab_end = hv_end + (max_cores << cpu_slab_shift);

    if (tp_val < hv_end or tp_val >= max_slab_end) return false;

    const ctx = @as(*CpuContext, @ptrFromInt(tp_val));
    const core_id = ctx.cpu_core_id;
    if (core_id >= cpu_contexts.len) return false;
    return cpu_contexts[core_id] == ctx;
}

pub const TpGuard = struct {
    saved_tp: usize = 0,
    swapped: bool = false,
    pub inline fn init() TpGuard {
        if (is_test) return .{};
        var current: usize = undefined;
        asm volatile (
            \\mv %[current], tp
            : [current] "=r" (current),
        );
        if (isHostTp(current)) {
            return .{ .saved_tp = current, .swapped = false };
        } else {
            var host_tp: usize = undefined;
            asm volatile (
                \\csrr %[host_tp], mscratch
                \\mv tp, %[host_tp]
                : [host_tp] "=r" (host_tp),
            );
            return .{ .saved_tp = current, .swapped = true };
        }
    }
    pub inline fn deinit(self: TpGuard) void {
        if (is_test) return;
        if (self.swapped) {
            asm volatile ("mv tp, %[saved]"
                :
                : [saved] "r" (self.saved_tp),
            );
        }
    }
};

pub inline fn readRA() usize {
    if (is_test) return 0;
    return asm volatile ("mv %[ret], ra"
        : [ret] "=r" (-> usize),
    );
}

pub inline fn flushIcache() void {
    if (is_test) return;
    asm volatile ("fence.i");
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

pub inline fn writeHstateen0(val: usize) void {
    if (is_test) return;
    asm volatile ("csrw 0x60c, %[val]"
        :
        : [val] "r" (val),
    );
}

// Reboot the host machine.
pub fn reboot() void {
    if (builtin.is_test) return;
    const drivers = @import("../../../../core/drivers.zig");
    if (drivers.reset) |drv| {
        drv.reset();
    } else if (test_device_base) |base| {
        const ptr = @as(*volatile u32, @ptrFromInt(base));
        ptr.* = SiFiveTest.FINISHER_RESET;
    }
    while (true) {}
}

// Shutdown the host machine.
pub fn shutdown() void {
    if (builtin.is_test) return;
    const drivers = @import("../../../../core/drivers.zig");
    if (drivers.reset) |drv| {
        drv.shutdown();
    } else if (test_device_base) |base| {
        const ptr = @as(*volatile u32, @ptrFromInt(base));
        ptr.* = SiFiveTest.FINISHER_PASS;
    }
    while (true) {}
}

pub fn pause() void {
    if (builtin.is_test) return;
    hw_pause();
}

// ---- Physical S-mode (Supervisor) CSR helpers & cache management for non-H fallback ----

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
