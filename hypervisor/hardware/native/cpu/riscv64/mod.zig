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
pub const readRA = csr.readRA;
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
pub const readVsip = guest_csr.readVsip;
pub const writeVsip = guest_csr.writeVsip;
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

pub const CLINT = struct {
    pub const MTIMECMP_BASE = 0x4000;
    pub const MTIME_OFFSET = 0xbff8;

    pub fn msip(hart: usize) ?*volatile u32 {
        const base = clint_base orelse return null;
        const offset = std.math.mul(usize, 4, hart) catch return null;
        const addr = std.math.add(usize, base, offset) catch return null;
        return @ptrFromInt(addr);
    }
};

pub const SiFiveTest = struct {
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

fn initCpuToHartMap() [STATIC_PHYS_CORES]usize {
    var map: [STATIC_PHYS_CORES]usize = undefined;
    for (0..STATIC_PHYS_CORES) |i| map[i] = i;
    return map;
}
pub var cpu_to_hart_map: [STATIC_PHYS_CORES]usize = initCpuToHartMap();
pub var cpu_contexts = std.mem.zeroes([STATIC_PHYS_CORES]?*CpuContext);

pub var test_time: u64 = 0;

pub export var riscv_supports_sstc: bool = false;
pub export var riscv_supports_smstateen: bool = false;

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

pub const ThreadContext = [32]usize;

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
    mepc: usize,
    mstatus: usize,
    hstatus: usize,
    hgatp: usize,
    hvip: usize,
    hedeleg: usize,
    hideleg: usize,
};

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
    const cpu_context = getCPUContext();
    return cpu_context.allocator.allocator();
}

pub fn auditCpuFeatures() !void {
    if (is_test) return;

    debug.printf("CPU features audit:\n", .{});

    const pcpu = getCPUContext();
    if (!config.legacy_cpu) {
        // Probe Smstateen (0x30c).
        pcpu.probing_active = true;
        pcpu.probe_failed = false;
        _ = readMstateen0();
        riscv_supports_smstateen = !pcpu.probe_failed;

        // Probe Sstc (0x14d) by verifying that writing to stimecmp toggles STIP
        // (bit 5) in mip while menvcfg.STCE (bit 63) is enabled.
        pcpu.probing_active = true;
        pcpu.probe_failed = false;

        const old_menvcfg = readMenvcfg();
        const stce_bit = @as(usize, 1) << 63;
        writeMenvcfg(old_menvcfg | stce_bit);

        const old_stimecmp = readStimecmp();
        writeStimecmp(TIMER_INFINITY);
        const mip_clear = readMip();
        writeStimecmp(0);
        const mip_set = readMip();

        writeStimecmp(old_stimecmp);
        writeMenvcfg(old_menvcfg);

        const stip_bit = @as(usize, 1) << 5;
        const stip_cleared = (mip_clear & stip_bit) == 0;
        const stip_asserted = (mip_set & stip_bit) != 0;

        riscv_supports_sstc =
            !pcpu.probe_failed and stip_cleared and stip_asserted;

        if (riscv_supports_sstc) {
            writeMenvcfg(old_menvcfg | stce_bit);
            writeStimecmp(TIMER_INFINITY);
        }

        pcpu.probing_active = false;
    }

    const has_h = hasHExtension();
    debug.printf(
        " - Hardware virtualization (H) {s}\n",
        .{if (has_h) "detected" else "absent"},
    );
    debug.printf(
        " - Enhanced isolation (Smstateen) {s}\n",
        .{if (riscv_supports_smstateen) "detected" else "absent"},
    );
    debug.printf(
        " - Efficient timer interrupts (Sstc) {s}\n",
        .{if (riscv_supports_sstc) "detected" else "absent"},
    );

    if (has_h) {
        const val_hgatp: u64 = (8 << 60) | (1 << 44) | 0x82edc;
        writeHgatp(val_hgatp);
        const read_hgatp = readHgatp();
        if (read_hgatp != val_hgatp) {
            debug.printf(
                "CRITICAL: hgatp write failure (wrote 0x{x}, read 0x{x})\n",
                .{ val_hgatp, read_hgatp },
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
        const base = clint_base orelse 0x02000000;
        const addr = base + CLINT.MTIMECMP_BASE + 8 * readMhartid();
        const mtimecmp_ptr = @as(*volatile u64, @ptrFromInt(addr));
        mtimecmp_ptr.* = stime;
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

pub fn isHostTp(tp_val: usize) bool {
    if (is_test) return false;
    return @import("../../../../core/pcore.zig").isHostTp(tp_val);
}

pub fn getOnlineCpuCount() u32 {
    if (is_test) return 1;
    const count = @import("../../../../core/pcore.zig").countOnline();
    return if (count > 0) @as(u32, @intCast(count)) else 1;
}

pub const TpGuard = struct {
    saved_tp: usize = 0,
    swapped: bool = false,

    pub inline fn init() TpGuard {
        if (is_test) return .{};
        var current: usize = undefined;
        asm volatile ("mv %[current], tp"
            : [current] "=r" (current),
        );
        if (isHostTp(current)) {
            return .{ .saved_tp = current, .swapped = false };
        }
        var host_tp: usize = undefined;
        asm volatile (
            \\csrr %[host_tp], mscratch
            \\mv tp, %[host_tp]
            : [host_tp] "=r" (host_tp),
        );
        return .{ .saved_tp = current, .swapped = true };
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

pub fn reboot() void {
    if (is_test) return;
    const pcore = @import("../../../../core/pcore.zig");
    pcore.parkOtherCores();
    const drivers = @import("../../../../core/drivers.zig");
    if (drivers.reset) |drv| drv.reset();
    const base = test_device_base orelse 0x100000;
    const ptr = @as(*volatile u32, @ptrFromInt(base));
    ptr.* = SiFiveTest.FINISHER_RESET;
    while (true) {}
}

pub fn shutdown() void {
    if (is_test) return;
    const pcore = @import("../../../../core/pcore.zig");
    pcore.parkOtherCores();
    const drivers = @import("../../../../core/drivers.zig");
    if (drivers.reset) |drv| drv.shutdown();
    const base = test_device_base orelse 0x100000;
    const ptr = @as(*volatile u32, @ptrFromInt(base));
    ptr.* = SiFiveTest.FINISHER_PASS;
    while (true) {}
}

pub fn pause() void {
    if (is_test) return;
    hw_pause();
}

test "riscv mock hardware initialization and heap allocator" {
    _ = csr;
    _ = guest_csr;
    initMockHardware();
    try initCPUHeapAllocator();
    const a = getCPUHeapAllocator();
    const buf = try a.alloc(u8, 64);
    defer a.free(buf);
    try std.testing.expectEqual(@as(usize, 64), buf.len);
}
