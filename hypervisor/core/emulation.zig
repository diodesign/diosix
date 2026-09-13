// Native Freestanding Dynamic Recompiler Integration for Diosix Hypervisor
//
// Manages virtual core emulation loops, hardware device MMIO dispatch,
// and execution preemption using the native Zig dynamic recompiler.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const vcore = @import("vcore.zig");
const guest = @import("guest.zig");
const riscv = @import("../hardware/native/cpu/riscv64/mod.zig");
const debug = @import("debug.zig");
const pcore = @import("pcore.zig");
const gdb_stub = @import("gdb/stub.zig");
const emulation_native = @import("emulation");
pub const VCpu = emulation_native.VCpu;
pub const SoftTlb = emulation_native.SoftTlb;
pub const Engine = emulation_native.Engine;
const rv32_arch = @import("../hardware/emulation/arch/riscv32/mod.zig");
const sbi = @import("sbi.zig");

pub const TpGuard = struct {
    saved_tp: usize = 0,
    swapped: bool = false,

    pub fn init() TpGuard {
        if (comptime @import("builtin").is_test) return .{};
        var current: usize = undefined;
        asm volatile (
            \\mv %[current], tp
            : [current] "=r" (current),
        );
        if (riscv.isHostTp(current)) {
            return .{ .saved_tp = current, .swapped = false };
        } else {
            const host_tp = riscv.readSscratch();
            asm volatile (
                \\mv tp, %[host_tp]
                :
                : [host_tp] "r" (host_tp),
            );
            return .{ .saved_tp = current, .swapped = true };
        }
    }

    pub fn deinit(self: TpGuard) void {
        if (comptime @import("builtin").is_test) return;
        if (self.swapped) {
            asm volatile (
                \\mv tp, %[saved]
                :
                : [saved] "r" (self.saved_tp),
            );
        }
    }
};

pub inline fn readSModeTime() u64 {
    return riscv.readTime();
}

/// Result of handling an exception from the dynamic recompiler
pub const ExceptionAction = enum {
    emulated,
    delivered,
    unhandled,
    wfi,
};

/// 8MB code buffer size per emulated vcore
const JIT_CODE_BUFFER_SIZE: usize = 8 * 1024 * 1024;
const MAX_EMULATED_VCORES: usize = 4;

var jit_buffer_pools: [MAX_EMULATED_VCORES][JIT_CODE_BUFFER_SIZE]u8 = undefined;
var vcpu_pools: [MAX_EMULATED_VCORES]VCpu = undefined;
var softtlb_pools: [MAX_EMULATED_VCORES]emulation_native.SoftTlb = undefined;
var bus_pools: [MAX_EMULATED_VCORES]emulation_native.Bus = undefined;
var engine_pools: [MAX_EMULATED_VCORES]Engine = undefined;

pub const EmulatedSlot = struct {
    guest_id: usize = 0,
    vcore_id: usize = 0,
    in_use: bool = false,
};

var emulated_slots: [MAX_EMULATED_VCORES]EmulatedSlot = @splat(.{});
var emulated_slots_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub var global_insn_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var global_wfi_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var global_ecall_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var global_yield_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var last_telemetry_time: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub fn getVirtualSModeTime(vc: *vcore.VirtualCore) u64 {
    const host_time = riscv.readTime();
    return @max(vc.virtual_time, host_time);
}

fn uartOutputCallback(char: u8) void {
    debug.putchar(char);
}

/// Initialize native dynamic recompiler instance for virtual core
pub fn init(vc: *vcore.VirtualCore) !void {
    if (vc.exec_path != .emulated) return error.InvalidExecPath;
    const em = &vc.exec_path.emulated;
    if (em.vcpu != null and em.engine != null) return;

    while (emulated_slots_lock.swap(true, .acquire)) {
        std.atomic.spinLoopHint();
    }
    defer emulated_slots_lock.store(false, .release);

    var assigned_slot: ?usize = null;
    for (0..MAX_EMULATED_VCORES) |i| {
        if (emulated_slots[i].in_use and
            emulated_slots[i].guest_id == vc.guest_id and
            emulated_slots[i].vcore_id == vc.id)
        {
            assigned_slot = i;
            break;
        }
    }

    if (assigned_slot == null) {
        for (0..MAX_EMULATED_VCORES) |i| {
            if (!emulated_slots[i].in_use) {
                emulated_slots[i] = .{
                    .guest_id = vc.guest_id,
                    .vcore_id = vc.id,
                    .in_use = true,
                };
                assigned_slot = i;
                break;
            }
        }
    }

    const vcore_idx = assigned_slot orelse return error.OutOfEmulatedVcoreSlots;
    const vcpu_ptr = &vcpu_pools[vcore_idx];
    const softtlb_ptr = &softtlb_pools[vcore_idx];
    const bus_ptr = &bus_pools[vcore_idx];
    const engine_ptr = &engine_pools[vcore_idx];

    const gpa_base = vc.guest.space.base_gpa;
    const hpa_base = vc.guest.space.base_hpa;
    const ram_size = vc.guest.space.range_size;

    if (vc.id == 0) {
        vcore.time_offset = 0;
        VCpu.time_offset.store(0, .release);
        VCpu.max_guest_time.store(0, .monotonic);
        VCpu.guest_insn_time.store(10_000_000, .monotonic);
        @memset(@as([*]u8, @ptrCast(vcpu_ptr))[0..@sizeOf(VCpu)], 0);
        vcpu_ptr.pc = @truncate(em.entry);
        vcpu_ptr.id = vc.id;
        vcpu_ptr.setReg(10, @truncate(vc.id));
        vcpu_ptr.setReg(11, @truncate(em.dtb));
        vcpu_ptr.privilege_mode = 1; // Supervisor mode for Linux kernel
        vcpu_ptr.priv_mode = 1;
        vcpu_ptr.medeleg = 0xFFFF;
        vcpu_ptr.mideleg = 0xFFFF;
        vcpu_ptr.stvec = 0;
        vcpu_ptr.mtvec = 0;
        vcpu_ptr.vstimecmp = ~@as(u64, 0);
        vcpu_ptr.misa = (1 << 30) | (1 << 8) | (1 << 12) | (1 << 0) | (1 << 5) | (1 << 3) | (1 << 2);
        vcpu_ptr.running = true;

        if (vc.guest.uart.out_fn == null) {
            vc.guest.uart.out_fn = uartOutputCallback;
        }
        vc.guest.uart.guest_id = vc.guest_id;
    } else {
        @memset(@as([*]u8, @ptrCast(vcpu_ptr))[0..@sizeOf(VCpu)], 0);
        vcpu_ptr.id = vc.id;
        vcpu_ptr.privilege_mode = 1;
        vcpu_ptr.priv_mode = 1;
        vcpu_ptr.medeleg = 0xFFFF;
        vcpu_ptr.mideleg = 0xFFFF;
        vcpu_ptr.vstimecmp = ~@as(u64, 0);
        vcpu_ptr.misa = (1 << 30) | (1 << 8) | (1 << 12) | (1 << 0) | (1 << 5) | (1 << 3) | (1 << 2);
        vcpu_ptr.running = false;
    }

    softtlb_ptr.initOnPtr(gpa_base, hpa_base, ram_size);

    bus_ptr.uart = &vc.guest.uart;
    bus_ptr.timer = &vc.guest.timer;
    bus_ptr.pic = &vc.guest.pic;
    bus_ptr.vsock = &vc.guest.vsock;
    engine_ptr.initOnPtr(&jit_buffer_pools[vcore_idx], vcpu_ptr, softtlb_ptr, bus_ptr);

    if (em.target_arch == .riscv32 and vc.id == 0) {
        rv32_arch.initRegisters(vcpu_ptr, em.entry, em.dtb, 0);
    }

    em.vcpu = vcpu_ptr;
    em.engine = engine_ptr;
    em.slot_idx = vcore_idx;
}

/// Release emulated vcore slot and reset engine/TLB resources
pub fn deinit(vc: *vcore.VirtualCore) void {
    if (vc.exec_path != .emulated) return;
    const em = &vc.exec_path.emulated;

    while (emulated_slots_lock.swap(true, .acquire)) {
        std.atomic.spinLoopHint();
    }
    defer emulated_slots_lock.store(false, .release);

    for (0..MAX_EMULATED_VCORES) |i| {
        if (emulated_slots[i].in_use and
            emulated_slots[i].guest_id == vc.guest_id and
            emulated_slots[i].vcore_id == vc.id)
        {
            if (em.engine) |eng| {
                eng.tlb.flush();
            }
            emulated_slots[i] = .{
                .guest_id = 0,
                .vcore_id = 0,
                .in_use = false,
            };
            break;
        }
    }

    em.vcpu = null;
    em.engine = null;
    em.slot_idx = null;
}

/// Stop execution of emulated vcore
pub fn stop(vc: *vcore.VirtualCore) void {
    if (vc.exec_path != .emulated) return;
    const em = &vc.exec_path.emulated;
    em.preempt_pending = true;
}

pub fn emulatedRunnerSMode(initial_vc: *vcore.VirtualCore) callconv(.c) void {
    const scheduler = @import("scheduler.zig");
    var current_vc: ?*vcore.VirtualCore = initial_vc;
    while (true) {
        if (current_vc) |vc| {
            if (vc.state == .blocked) {
                vc.running_on_cpu = null;
                pcore.this().active_vcore = null;
                current_vc = scheduler.pickNext();
                if (current_vc) |next_vc| {
                    pcore.contextSwitch(next_vc);
                }
                continue;
            }

            run(vc);

            // Only yield if vcore is blocked (WFI) or preempted (timeslice expired)
            const em = if (vc.exec_path == .emulated) &vc.exec_path.emulated else null;
            const should_yield = (vc.state == .blocked) or (em != null and em.?.preempt_pending);
            if (should_yield) {
                if (em) |e| e.preempt_pending = false;
                scheduler.yield(vc);
                if (pcore.this().active_vcore) |act| {
                    current_vc = @ptrCast(@alignCast(act));
                } else {
                    current_vc = scheduler.pickNext();
                    if (current_vc) |next_vc| {
                        pcore.contextSwitch(next_vc);
                    }
                }
            }
        } else {
            // No ready vcore for this physical CPU, inspect blocked queue and pause
            const pcpu = pcore.this();
            const now = riscv.readTime();
            var min_target: u64 = std.math.maxInt(u64);
            const b_emu_prev = pcpu.blocked_lock.lock();
            var it = pcpu.blocked_queue.start;
            while (it) |node| {
                const next_it = node.next;
                const vc: *vcore.VirtualCore = @ptrCast(@alignCast(node.contents));
                if (!@atomicLoad(bool, &vc.wfi_blocked, .acquire)) {
                    // Woken by remote CPU / IPI
                    pcpu.blocked_queue.remove(node);
                    vc.blocked_on_cpu = null;
                    it = next_it;
                    continue;
                }
                var wake = false;
                if (@atomicRmw(bool, &vc.pending_ipi, .Xchg, false, .acq_rel)) {
                    wake = true;
                    if (vc.exec_path == .emulated and vc.exec_path.emulated.vcpu != null) {
                        vc.exec_path.emulated.vcpu.?.setMipBit(1); // SSIP
                    }
                } else {
                    if (vc.exec_path == .emulated and vc.exec_path.emulated.vcpu != null) {
                        const v = vc.exec_path.emulated.vcpu.?;
                        const vtimecmp = v.vstimecmp;
                        const mtimecmp = if (vc.exec_path.emulated.engine) |eng| eng.bus.timer.getMtimecmp(vc.id) else ~@as(u64, 0);
                        const guest_target = @min(vtimecmp, mtimecmp);
                        if (guest_target != ~@as(u64, 0)) {
                            const cur_guest_time = VCpu.readGuestTime();
                            if (cur_guest_time >= guest_target) {
                                wake = true;
                                v.setMipBit(5); // STIP
                            } else if (guest_target < min_target) {
                                min_target = guest_target;
                            }
                        }
                    } else {
                        var target: u64 = std.math.maxInt(u64);
                        if (vc.timer_scheduled) {
                            target = vc.timer_target;
                        }
                        if (target != std.math.maxInt(u64)) {
                            if (now >= target) {
                                wake = true;
                                vc.timer_scheduled = false;
                            } else if (target < min_target) {
                                min_target = target;
                            }
                        }
                    }
                }
                if (wake) {
                    pcpu.blocked_queue.remove(node);
                    vc.blocked_on_cpu = null;
                    @atomicStore(bool, &vc.wfi_blocked, false, .release);
                    vc.state = .ready;
                    if (current_vc == null) {
                        pcore.contextSwitch(vc);
                        current_vc = vc;
                    } else {
                        scheduler.queue(vc);
                    }
                }
                it = next_it;
            }
            pcpu.blocked_lock.unlock(b_emu_prev);

            if (current_vc == null) {
                const safety_target = now + 10_000;
                riscv.setTimer(safety_target);
                riscv.pause();
                if (riscv.CLINT.msip(pcpu.hardware_hart_id)) |ptr| {
                    ptr.* = 0;
                }
                if (pcore.this().active_vcore) |act| {
                    const act_vc: *vcore.VirtualCore = @ptrCast(@alignCast(act));
                    if (!@atomicLoad(bool, &act_vc.wfi_blocked, .acquire) and act_vc.state != .blocked) {
                        current_vc = act_vc;
                    }
                }
                if (current_vc == null) {
                    current_vc = scheduler.pickNext();
                    if (current_vc) |next_vc| {
                        pcore.contextSwitch(next_vc);
                    }
                }
            }
        }
    }
}

/// Run native dynamic recompiler execution loop for virtual core
pub fn run(vc: *vcore.VirtualCore) void {
    init(vc) catch |e| {
        debug.printf("Native dynarec init failed: {s}\n", .{@errorName(e)});
        return;
    };

    if (vc.exec_path != .emulated) return;
    const em = &vc.exec_path.emulated;
    const vcpu_ptr = em.vcpu.?;
    const engine_ptr = em.engine.?;
    em.preempt_pending = false;

    vc.virtual_time = riscv.readTime();
    gdb_stub.stub.active_vc = vc;

    if (@atomicRmw(bool, &vc.pending_ipi, .Xchg, false, .acq_rel)) {
        vcpu_ptr.setMipBit(1); // SSIP
    }

    const budget: usize = 2_000_000;
    const insns_before = engine_ptr.total_insn_count;
    const exit_reason = engine_ptr.run(vcpu_ptr, budget);
    const insns_delta = engine_ptr.total_insn_count -% insns_before;
    _ = global_insn_count.fetchAdd(insns_delta, .monotonic);

    switch (exit_reason) {
        .wfi => _ = global_wfi_count.fetchAdd(1, .monotonic),
        .ecall => _ = global_ecall_count.fetchAdd(1, .monotonic),
        .yield, .normal => _ = global_yield_count.fetchAdd(1, .monotonic),
        else => {},
    }

    em.exit_count += 1;

    if (exit_reason == .unhandled or exit_reason == .illegal_instruction) {
        debug.printf("EMU UNHANDLED EXIT: pc=0x{x} last_pc=0x{x} exit={s} cause={} fault_pc=0x{x}\n", .{
            vcpu_ptr.pc,
            engine_ptr.last_pc,
            @tagName(exit_reason),
            engine_ptr.last_fault_cause,
            engine_ptr.last_fault_pc,
        });
    }

    switch (exit_reason) {
        .yield, .normal => {},
        .wfi => {
            vc.state = .blocked;
            const pcpu = pcore.this();
            const b_wfi_emu_prev = pcpu.blocked_lock.lock();
            vc.blocked_node.contents = vc;
            pcpu.blocked_queue.pushStart(&vc.blocked_node);
            vc.blocked_on_cpu = pcpu.cpu_core_id;
            @atomicStore(bool, &vc.wfi_blocked, true, .release);
            pcpu.blocked_lock.unlock(b_wfi_emu_prev);
            return;
        },
        .page_fault, .illegal_instruction, .unhandled => {
            debug.printf("FAULT EXIT: exit={s} pc=0x{x} fault_pc=0x{x} cause={} val=0x{x} satp=0x{x}\n", .{ @tagName(exit_reason), vcpu_ptr.pc, engine_ptr.last_fault_pc, engine_ptr.last_fault_cause, engine_ptr.last_fault_val, vcpu_ptr.satp });
        },
        .ecall => {
            var context: riscv.ThreadContext = undefined;
            inline for (0..32) |i| {
                context[i] = @truncate(vcpu_ptr.regs[i]);
            }

            sbi.handle(vc, 0, &context);

            inline for (0..32) |i| {
                vcpu_ptr.regs[i] = context[i];
            }
        },
    }
}

test "Emulated VCore Dynamic Slot Allocation, Multi-Guest Isolation, and Reclaim" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var phys_test = try @import("physmem.zig").initForTest(allocator, 4096);
    defer phys_test.deinit();

    const g1 = try guest.createGuest(allocator, false, false, null, 0x80000000, 0x80000000, 0x100000, .riscv32);
    defer g1.deinit();

    // Allocate 4 emulated vcores across the system (slots 0..3)
    const vc0 = try g1.addVcore(0, 0x80000000, 0x80001000, .normal, null);
    const vc1 = try g1.addVcore(1, 0x80000000, 0x80001000, .normal, null);
    const vc2 = try g1.addVcore(2, 0x80000000, 0x80001000, .normal, null);
    const vc3 = try g1.addVcore(3, 0x80000000, 0x80001000, .normal, null);

    try init(vc0);
    try init(vc1);
    try init(vc2);
    try init(vc3);

    // Verify all 4 got distinct slots
    const s0 = vc0.exec_path.emulated.slot_idx.?;
    const s1 = vc1.exec_path.emulated.slot_idx.?;
    const s2 = vc2.exec_path.emulated.slot_idx.?;
    const s3 = vc3.exec_path.emulated.slot_idx.?;
    try testing.expect(s0 != s1 and s0 != s2 and s0 != s3);
    try testing.expect(s1 != s2 and s1 != s3 and s2 != s3);

    // Verify per-guest virtual devices are bound to g1, not global statics
    try testing.expectEqual(&g1.uart, bus_pools[s0].uart);
    try testing.expectEqual(&g1.timer, bus_pools[s0].timer);
    try testing.expectEqual(&g1.pic, bus_pools[s0].pic);
    try testing.expectEqual(&g1.vsock, bus_pools[s0].vsock.?);

    // 5th vcore must fail with OutOfEmulatedVcoreSlots instead of aliasing slot 0
    const vc4 = try g1.addVcore(4, 0x80000000, 0x80001000, .normal, null);
    try testing.expectError(error.OutOfEmulatedVcoreSlots, init(vc4));

    // Release slot for vc1
    deinit(vc1);
    try testing.expect(vc1.exec_path.emulated.slot_idx == null);

    // Now vc4 can be allocated into the vacated slot!
    try init(vc4);
    try testing.expectEqual(s1, vc4.exec_path.emulated.slot_idx.?);

    // Clean up
    deinit(vc0);
    deinit(vc2);
    deinit(vc3);
    deinit(vc4);
}

