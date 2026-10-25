// RISC-V architecture state, CPU context, feature auditing, and power helpers.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const alloc = @import("../../../../core/alloc.zig");
const atomic = @import("../../../../core/atomic.zig");
const dsa = @import("../../../../core/dsa.zig");
const debug = @import("../../../../core/debug.zig");
const interface = @import("interface").riscv;
const config = @import("config");

pub const csr = @import("csr.zig");
pub const guest_csr = @import("csr/guest.zig");
pub const mock = @import("mock.zig");
pub const initMockHardware = mock.initMockHardware;

pub const Register = interface.Register;
pub const PrivilegeMode = interface.PrivilegeMode;
pub const IsaExtension = interface.IsaExtension;
pub const Cause = interface.Cause;
pub const MSTATUS = interface.MSTATUS;
pub const SSTATUS = interface.SSTATUS;
pub const HSTATUS = interface.HSTATUS;
pub const HVIP = interface.HVIP;
pub const MIE = interface.MIE;
pub const MIP = interface.MIP;
pub const MCOUNTEREN = interface.MCOUNTEREN;
pub const ENVCFG = interface.ENVCFG;
pub const STATEEN = interface.STATEEN;
pub const toCause = interface.toCause;
pub const CSR = interface.CSR;
pub const Instr = interface.Instr;
pub const HEDELEG_DELEGATED = interface.HEDELEG_DELEGATED;
pub const HIDELEG_DELEGATED = interface.HIDELEG_DELEGATED;
pub const MEDELEG_DELEGATED = interface.MEDELEG_DELEGATED;
pub const MIDELEG_DELEGATED = interface.MIDELEG_DELEGATED;

// Re-export M-mode and H-extension CSR functions from csr.zig.
pub const readMcause = csr.readMcause;
pub const fence = csr.fence;
pub const flushIcache = csr.flushIcache;
pub const readMepc = csr.readMepc;
pub const writeMepc = csr.writeMepc;
pub const readMvendorid = csr.readMvendorid;
pub const readMarchid = csr.readMarchid;
pub const readMimpid = csr.readMimpid;
pub const readMtval = csr.readMtval;
pub const readMstatus = csr.readMstatus;
pub const writeMstatus = csr.writeMstatus;
pub const readMhartid = csr.readMhartid;
pub const readMie = csr.readMie;
pub const writeMie = csr.writeMie;
pub const readMip = csr.readMip;
pub const writeMip = csr.writeMip;
pub const readMisa = csr.readMisa;
pub const hasHExtension = csr.hasHExtension;
pub const getPreviousPrivilege = csr.getPreviousPrivilege;
pub const writeMcounteren = csr.writeMcounteren;
pub const readMenvcfg = csr.readMenvcfg;
pub const writeMenvcfg = csr.writeMenvcfg;
pub const readMedeleg = csr.readMedeleg;
pub const writeMedeleg = csr.writeMedeleg;
pub const readMideleg = csr.readMideleg;
pub const writeMideleg = csr.writeMideleg;
pub const readMtval2 = csr.readMtval2;
pub const readMtinst = csr.readMtinst;
pub const readMstateen0 = csr.readMstateen0;
pub const writeMstateen0 = csr.writeMstateen0;
pub const readHstatus = csr.readHstatus;
pub const writeHstatus = csr.writeHstatus;
pub const writeHcounteren = csr.writeHcounteren;
pub const readHenvcfg = csr.readHenvcfg;
pub const writeHenvcfg = csr.writeHenvcfg;
pub const readHgatp = csr.readHgatp;
pub const writeHgatp = csr.writeHgatp;
pub const hfenceGvma = csr.hfenceGvma;
pub const readHedeleg = csr.readHedeleg;
pub const writeHedeleg = csr.writeHedeleg;
pub const readHideleg = csr.readHideleg;
pub const writeHideleg = csr.writeHideleg;
pub const readHvip = csr.readHvip;
pub const writeHvip = csr.writeHvip;
pub const readHtval = csr.readHtval;
pub const readHtinst = csr.readHtinst;
pub const writeHstateen0 = csr.writeHstateen0;
pub const hlv_w = csr.hlv_w;
pub const hlv_wu = csr.hlv_wu;
pub const hlv_hu = csr.hlv_hu;
pub const hlv_bu = csr.hlv_bu;
pub const hlv_d = csr.hlv_d;

// Re-export VS-mode and S-mode CSR functions from guest_csr.zig.
pub const readVsenvcfg = guest_csr.readVsenvcfg;
pub const writeVsenvcfg = guest_csr.writeVsenvcfg;
pub const readVsstatus = guest_csr.readVsstatus;
pub const writeVsstatus = guest_csr.writeVsstatus;
pub const readVsie = guest_csr.readVsie;
pub const writeVsie = guest_csr.writeVsie;
pub const readVstvec = guest_csr.readVstvec;
pub const writeVstvec = guest_csr.writeVstvec;
pub const readVsscratch = guest_csr.readVsscratch;
pub const writeVsscratch = guest_csr.writeVsscratch;
pub const readVsepc = guest_csr.readVsepc;
pub const writeVsepc = guest_csr.writeVsepc;
pub const readVscause = guest_csr.readVscause;
pub const writeVscause = guest_csr.writeVscause;
pub const readVstval = guest_csr.readVstval;
pub const writeVstval = guest_csr.writeVstval;
pub const readVsatp = guest_csr.readVsatp;
pub const writeVsatp = guest_csr.writeVsatp;
pub const readVstimecmp = guest_csr.readVstimecmp;
pub const writeVstimecmp = guest_csr.writeVstimecmp;
pub const readSstatus = guest_csr.readSstatus;
pub const writeSstatus = guest_csr.writeSstatus;
pub const readSie = guest_csr.readSie;
pub const writeSie = guest_csr.writeSie;
pub const readStvec = guest_csr.readStvec;
pub const writeStvec = guest_csr.writeStvec;
pub const readSscratch = guest_csr.readSscratch;
pub const writeSscratch = guest_csr.writeSscratch;
pub const readSepc = guest_csr.readSepc;
pub const writeSepc = guest_csr.writeSepc;
pub const readScause = guest_csr.readScause;
pub const writeScause = guest_csr.writeScause;
pub const readStval = guest_csr.readStval;
pub const writeStval = guest_csr.writeStval;
pub const readSatp = guest_csr.readSatp;
pub const writeSatp = guest_csr.writeSatp;
pub const readStimecmp = guest_csr.readStimecmp;
pub const writeStimecmp = guest_csr.writeStimecmp;
pub const readSenvcfg = guest_csr.readSenvcfg;
pub const writeSenvcfg = guest_csr.writeSenvcfg;
pub const sfenceVma = guest_csr.sfenceVma;
pub const saveVsState = guest_csr.saveVsState;
pub const restoreVsState = guest_csr.restoreVsState;
pub const saveSState = guest_csr.saveSState;
pub const restoreSState = guest_csr.restoreSState;

pub var clint_base: ?usize = null;
pub var uart_base: ?usize = null;
pub var test_device_base: ?usize = null;
pub var plic_base: ?usize = null;

pub const CLINT = @import("../../drivers/clint.zig");

pub const SiFiveTest = struct {
    pub const DEFAULT_BASE: usize = 0x100000;
    pub const FINISHER_PASS = 0x5555;
    pub const FINISHER_RESET = 0x7777;
};

const is_test = builtin.is_test;

pub const STATIC_PHYS_CORES: usize = 32;
pub const MAX_PHYS_CORES: usize = STATIC_PHYS_CORES;
pub const CPU_SLAB_SHIFT = 22;
pub const CPU_SLAB_SIZE = 1 << CPU_SLAB_SHIFT;

// Timer configuration constants (10 MHz standard RISC-V timer clock).
pub const TIMER_INFINITY: u64 = 0xffffffffffffffff;
pub const TIMESLICE_TICKS: u64 = 100_000; // 10 ms
pub const EXT_IRQ_POLL_TICKS: u64 = 1_000; // 100 us
pub const WATCHDOG_TICKS: u64 = 100_000_000; // 10 s

// hgatp probe constants for SV39x4 (mode=8, vmid=1, dummy PPN=0x82edc).
const HGATP_PROBE_MODE_SV39X4: u64 = 8 << 60;
const HGATP_PROBE_VMID: u64 = 1 << 44;
const HGATP_PROBE_PPN: u64 = 0x82edc;
const HGATP_PROBE_VAL: u64 =
    HGATP_PROBE_MODE_SV39X4 | HGATP_PROBE_VMID | HGATP_PROBE_PPN;

pub var test_time: u64 = 0;

pub export var riscv_supports_sstc: bool = false;
pub export var riscv_supports_smstateen: bool = false;

extern fn hw_private_variables() *CpuContext;
extern fn hw_heap_base() usize;
extern fn hw_heap_size() usize;
extern fn hw_pause() void;

pub const ThreadContext = [32]u64;

pub const CpuContext = struct {
    cpu_core_id: usize,
    hardware_hart_id: usize,
    allocator: alloc.HeapAllocator,
    active_vcore: ?*anyopaque,
    run_queue: dsa.LinkedList(*anyopaque),
    run_queue_count: usize,
    blocked_queue: dsa.LinkedList(*anyopaque),
    blocked_lock: atomic.SpinLock = atomic.SpinLock.init(),
    trap_count: usize,
    last_trap_pc: usize,
    last_trap_val: usize,
    trap_loop_count: usize,
    probing_active: bool,
    probe_failed: bool,
    in_m_mode: bool,
    in_emulation_runner: bool = false,
    blocked_vcore: ?*anyopaque,
    last_timer_val: u64,
    gstage_dirty: bool,
    is_parked: bool = false,
};

pub const MachineState = extern struct {
    mepc: u64,
    mstatus: u64,
    hstatus: u64,
    hgatp: u64,
    hvip: u64,
    hedeleg: u64,
    hideleg: u64,
};

pub const GuestState = extern struct {
    vsstatus: u64,
    vsie: u64,
    vstvec: u64,
    vsscratch: u64,
    vsepc: u64,
    vscause: u64,
    vstval: u64,
    vsatp: u64,
    vstimecmp: u64,
    vsenvcfg: u64,
};

pub const NUM_FP_REGS: usize = 32;
pub const NUM_VEC_REGS: usize = 32;
pub const MAX_VLEN_BYTES: usize = 32;
pub const VTYPE_VILL_BIT: u64 = @as(u64, 1) << 63;

pub const FpState = extern struct {
    fregs: [NUM_FP_REGS]u64 = @splat(0),
    fcsr: u64 = 0,
};

pub const VectorState = extern struct {
    vregs: [NUM_VEC_REGS * MAX_VLEN_BYTES]u8 align(16) = @splat(0),
    vl: u64 = 0,
    vtype: u64 = VTYPE_VILL_BIT,
    vcsr: u64 = 0,
    vstart: u64 = 0,
};

comptime {
    const assert = std.debug.assert;
    assert(@sizeOf(ThreadContext) == 32 * @sizeOf(u64));
    assert(@sizeOf(CpuContext) <= 4096);
    assert(@offsetOf(MachineState, "mepc") == 0);
    assert(@offsetOf(MachineState, "mstatus") == 8);
    assert(@offsetOf(MachineState, "hstatus") == 16);
    assert(@offsetOf(MachineState, "hgatp") == 24);
    assert(@offsetOf(MachineState, "hvip") == 32);
    assert(@offsetOf(MachineState, "hedeleg") == 40);
    assert(@offsetOf(MachineState, "hideleg") == 48);
    assert(@offsetOf(GuestState, "vsstatus") == 0);
    assert(@offsetOf(GuestState, "vsie") == 8);
    assert(@offsetOf(GuestState, "vstvec") == 16);
    assert(@offsetOf(GuestState, "vsscratch") == 24);
    assert(@offsetOf(GuestState, "vsepc") == 32);
    assert(@offsetOf(GuestState, "vscause") == 40);
    assert(@offsetOf(GuestState, "vstval") == 48);
    assert(@offsetOf(FpState, "fregs") == 0);
    assert(@offsetOf(FpState, "fcsr") == 256);
    assert(@offsetOf(VectorState, "vregs") == 0);
    assert(@offsetOf(VectorState, "vl") == 1024);
    assert(@offsetOf(VectorState, "vtype") == 1032);
    assert(@offsetOf(VectorState, "vcsr") == 1040);
    assert(@offsetOf(VectorState, "vstart") == 1048);
    assert(@offsetOf(GuestState, "vsatp") == 56);
    assert(@offsetOf(GuestState, "vstimecmp") == 64);
    assert(@offsetOf(GuestState, "vsenvcfg") == 72);
}

pub inline fn getCPUContext() *CpuContext {
    if (is_test) return &mock.test_cpu_ctx;
    return hw_private_variables();
}

pub inline fn getCPUHeapBase() usize {
    if (is_test) return @intFromPtr(&mock.test_heap);
    return hw_heap_base();
}

pub inline fn getCPUHeapSize() usize {
    if (is_test) return mock.test_heap.len;
    return hw_heap_size();
}

pub fn initCPUHeapAllocator() !void {
    const cpu_context = getCPUContext();
    const heap_base = getCPUHeapBase();
    const heap_size = getCPUHeapSize();
    debug.printf(
        "CPU Heap Init: base = 0x{x}, size = 0x{x} ({} MB)\n",
        .{ heap_base, heap_size, heap_size / 1024 / 1024 },
    );
    try cpu_context.allocator.init(heap_base, heap_size);
}

pub fn getCPUHeapAllocator() alloc.Allocator {
    return getCPUContext().allocator.allocator();
}

pub fn auditCpuFeatures() !void {
    if (is_test) return;
    debug.printf("CPU features audit:\n", .{});

    const pcpu = getCPUContext();
    if (!config.legacy_cpu) {
        // Probe Smstateen (0x30c) and Sstc (0x14d).
        pcpu.probing_active = true;
        pcpu.probe_failed = false;
        _ = readMstateen0();
        riscv_supports_smstateen = !pcpu.probe_failed;

        pcpu.probing_active = true;
        pcpu.probe_failed = false;
        const old_menvcfg = readMenvcfg();
        writeMenvcfg(old_menvcfg | ENVCFG.STCE);
        const old_stimecmp = readStimecmp();
        writeStimecmp(TIMER_INFINITY);
        const mip_clear = readMip();
        writeStimecmp(0);
        const mip_set = readMip();
        writeStimecmp(old_stimecmp);
        writeMenvcfg(old_menvcfg);

        const stip_cleared = (mip_clear & MIP.STIP) == 0;
        const stip_asserted = (mip_set & MIP.STIP) != 0;
        riscv_supports_sstc =
            !pcpu.probe_failed and stip_cleared and stip_asserted;
        if (riscv_supports_sstc) {
            writeMenvcfg(old_menvcfg | ENVCFG.STCE);
            writeStimecmp(TIMER_INFINITY);
        }
        pcpu.probing_active = false;
    }

    const has_h = hasHExtension();
    const h_str = if (has_h) "detected" else "absent";
    const sm_str = if (riscv_supports_smstateen) "detected" else "absent";
    const sstc_str = if (riscv_supports_sstc) "detected" else "absent";
    debug.printf(" - Hardware virtualization (H) {s}\n", .{h_str});
    debug.printf(" - Enhanced isolation (Smstateen) {s}\n", .{sm_str});
    debug.printf(" - Efficient timer interrupts (Sstc) {s}\n", .{sstc_str});

    if (has_h) {
        const initial_hgatp = readHgatp();
        writeHgatp(HGATP_PROBE_VAL);
        const read_hgatp = readHgatp();
        writeHgatp(initial_hgatp);
        hfenceGvma();
        if (read_hgatp != HGATP_PROBE_VAL) {
            debug.printf(
                "CRITICAL: hgatp write failure (wrote 0x{x}, read 0x{x})\n",
                .{ HGATP_PROBE_VAL, read_hgatp },
            );
            return error.HardwareIncompatible;
        }
        const initial_mstatus = readMstatus();
        writeMstatus(initial_mstatus | MSTATUS.MPV);
        const mstatus_with_v = readMstatus();
        writeMstatus(initial_mstatus);
        if ((mstatus_with_v & MSTATUS.MPV) == 0) {
            debug.printf("CRITICAL: mstatus.MPV write failure\n", .{});
            return error.HardwareIncompatible;
        }
    }
}

pub fn setTimer(stime: u64) void {
    if (is_test) return;
    const pcpu = getCPUContext();
    pcpu.last_timer_val = stime;

    const drivers = @import("../../../../core/drivers.zig");
    if (drivers.timer) |drv| {
        drv.setTimer(stime);
    } else {
        CLINT.setTimer(readMhartid(), stime);
    }
}

pub inline fn readTime() u64 {
    if (is_test) return test_time;
    return asm volatile ("rdtime %[ret]"
        : [ret] "=r" (-> u64),
    );
}

pub inline fn setTp(val: usize) void {
    if (is_test) return;
    asm volatile ("mv tp, %[val]"
        :
        : [val] "r" (val),
    );
}

pub fn getOnlineCpuCount() u32 {
    if (is_test) return 1;
    const count = @import("../../../../core/pcore.zig").countOnline();
    return if (count > 0) @as(u32, @intCast(count)) else 1;
}

fn finishPowerState(finisher_code: u32, is_reset: bool) noreturn {
    const pcore = @import("../../../../core/pcore.zig");
    pcore.parkOtherCores();
    const drivers = @import("../../../../core/drivers.zig");
    if (drivers.reset) |drv| {
        if (is_reset) drv.reset() else drv.shutdown();
    }
    const base = test_device_base orelse SiFiveTest.DEFAULT_BASE;
    const ptr = @as(*volatile u32, @ptrFromInt(base));
    ptr.* = finisher_code;
    while (true) {}
}

pub fn reboot() void {
    if (is_test) return;
    finishPowerState(SiFiveTest.FINISHER_RESET, true);
}

pub fn shutdown() void {
    if (is_test) return;
    finishPowerState(SiFiveTest.FINISHER_PASS, false);
}

pub fn pause() void {
    if (is_test) return;
    hw_pause();
}

test "riscv mock hardware initialization and heap allocator" {
    std.testing.refAllDecls(@This());
    _ = csr;
    _ = guest_csr;
    _ = mock;
    _ = @import("pmp.zig");
    _ = @import("sv39x4.zig");
    _ = @import("xint.zig");
    initMockHardware();
    try initCPUHeapAllocator();
    const a = getCPUHeapAllocator();
    const buf = try a.alloc(u8, 64);
    defer a.free(buf);
    try std.testing.expectEqual(@as(usize, 64), buf.len);
}
