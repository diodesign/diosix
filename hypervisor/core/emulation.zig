// Native freestanding dynamic recompiler integration for Diosix hypervisor.
//
// Manages virtual core emulation loops, hardware device MMIO dispatch,
// and execution preemption using the native Zig dynamic recompiler.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const atomic = @import("atomic.zig");
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
const config = @import("config");

pub inline fn readSModeTime() u64 {
    return riscv.readTime();
}

/// Result of handling an exception from the dynamic recompiler.
pub const ExceptionAction = enum { emulated, delivered, unhandled, wfi };

/// 8 MiB code buffer size per emulated vcore.
const JIT_CODE_BUFFER_SIZE: usize = 8 * 1024 * 1024;
pub const MAX_EMULATED_VCORES: usize =
    if (@import("builtin").is_test)
        4
    else if (@hasDecl(config, "max_emulated_vcores"))
        @max(1, @as(usize, config.max_emulated_vcores))
    else
        16;
pub const INSTRUCTION_BATCH_SIZE: usize =
    if (@hasDecl(config, "instruction_batch_size"))
        @max(1, @as(usize, config.instruction_batch_size))
    else
        2_000_000;
const INITIAL_GUEST_INSN_TIME: u64 = 10_000_000;
const DELEGATE_ALL_MASK: u32 = 0xffff;
const DEFAULT_MISA_RV32: u32 =
    riscv.IsaExtension.MXL_32 | @as(u32, @truncate(riscv.IsaExtension.gc));
const SAFETY_WAKE_TICKS: u64 = 10_000;
const DEFAULT_INSN_BUDGET: usize = INSTRUCTION_BATCH_SIZE;

comptime {
    std.debug.assert(MAX_EMULATED_VCORES > 0 and INSTRUCTION_BATCH_SIZE > 0);
}

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
var emulated_slots_lock = atomic.SpinLock.init();

pub var global_insn_count = std.atomic.Value(u64).init(0);
pub var global_wfi_count = std.atomic.Value(u64).init(0);
pub var global_ecall_count = std.atomic.Value(u64).init(0);
pub var global_yield_count = std.atomic.Value(u64).init(0);
pub var last_telemetry_time = std.atomic.Value(u64).init(0);

pub fn getVirtualSModeTime(vc: *vcore.VirtualCore) u64 {
    return @max(vc.virtual_time, riscv.readTime());
}

fn uartOutputCallback(char: u8) void {
    debug.putchar(char);
}

/// Initialize native dynamic recompiler instance for virtual core.
pub fn init(vc: *vcore.VirtualCore) !void {
    if (vc.exec_path != .emulated) return error.InvalidExecPath;
    const em = &vc.exec_path.emulated;
    if (em.vcpu != null and em.engine != null) return;

    const lock_state = emulated_slots_lock.lock();
    defer emulated_slots_lock.unlock(lock_state);

    var assigned_slot: ?usize = null;
    for (&emulated_slots, 0..) |slot, i| {
        if (slot.in_use and slot.guest_id == vc.guest_id and
            slot.vcore_id == vc.id)
        {
            assigned_slot = i;
            break;
        }
    }
    if (assigned_slot == null) {
        for (&emulated_slots, 0..) |*slot, i| {
            if (!slot.in_use) {
                slot.* = .{
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

    @memset(@as([*]u8, @ptrCast(vcpu_ptr))[0..@sizeOf(VCpu)], 0);
    vcpu_ptr.id = vc.id;
    vcpu_ptr.privilege_mode = riscv.PrivilegeMode.PRIV_SUPERVISOR;
    vcpu_ptr.medeleg = DELEGATE_ALL_MASK;
    vcpu_ptr.mideleg = DELEGATE_ALL_MASK;
    vcpu_ptr.vstimecmp = riscv.TIMER_INFINITY;
    vcpu_ptr.misa = DEFAULT_MISA_RV32;

    if (vc.id == 0) {
        vcore.time_offset = 0;
        VCpu.time_offset.store(0, .release);
        VCpu.max_guest_time.store(0, .monotonic);
        VCpu.guest_insn_time.store(INITIAL_GUEST_INSN_TIME, .monotonic);
        vcpu_ptr.pc = @truncate(em.entry);
        vcpu_ptr.setReg(@backingInt(riscv.Register.a0), @truncate(vc.id));
        vcpu_ptr.setReg(@backingInt(riscv.Register.a1), @truncate(em.dtb));
        vcpu_ptr.running = true;
        if (vc.guest.uart.out_fn == null) {
            vc.guest.uart.out_fn = uartOutputCallback;
        }
        vc.guest.uart.guest_id = vc.guest_id;
    } else {
        vcpu_ptr.running = false;
    }

    softtlb_ptr.initOnPtr(
        vc.guest.space.base_gpa,
        vc.guest.space.base_hpa,
        vc.guest.space.range_size,
    );
    bus_ptr.uart = &vc.guest.uart;
    bus_ptr.timer = &vc.guest.timer;
    bus_ptr.pic = &vc.guest.pic;
    bus_ptr.vsock = &vc.guest.vsock;
    engine_ptr.initOnPtr(
        &jit_buffer_pools[vcore_idx],
        vcpu_ptr,
        softtlb_ptr,
        bus_ptr,
    );
    if (em.target_arch == .riscv32 and vc.id == 0) {
        rv32_arch.initRegisters(vcpu_ptr, em.entry, em.dtb, 0);
    }
    em.vcpu = vcpu_ptr;
    em.engine = engine_ptr;
    em.slot_idx = vcore_idx;
}

/// Release emulated vcore slot and reset engine/TLB resources.
pub fn deinit(vc: *vcore.VirtualCore) void {
    if (vc.exec_path != .emulated) return;
    const em = &vc.exec_path.emulated;
    const lock_state = emulated_slots_lock.lock();
    defer emulated_slots_lock.unlock(lock_state);

    for (&emulated_slots) |*slot| {
        if (slot.in_use and slot.guest_id == vc.guest_id and
            slot.vcore_id == vc.id)
        {
            if (em.engine) |eng| eng.tlb.flush();
            slot.* = .{};
            break;
        }
    }
    em.vcpu = null;
    em.engine = null;
    em.slot_idx = null;
}

/// Stop execution of emulated vcore.
pub fn stop(vc: *vcore.VirtualCore) void {
    if (vc.exec_path != .emulated) return;
    vc.exec_path.emulated.preempt_pending = true;
}

pub fn emulatedRunnerSMode(initial_vc: *vcore.VirtualCore) callconv(.c) void {
    const scheduler = @import("scheduler.zig");
    var current_vc: ?*vcore.VirtualCore = initial_vc;
    while (true) {
        if (current_vc) |vc| {
            if (vc.exec_path != .emulated) {
                pcore.this().in_emulation_runner = false;
                pcore.contextSwitch(vc);
                return;
            }
            if (vc.state == .blocked or vc.state == .stopped) {
                vc.running_on_cpu = null;
                pcore.this().active_vcore = null;
                current_vc = scheduler.pickNext();
                if (current_vc) |next_vc| pcore.contextSwitch(next_vc);
                continue;
            }

            const force_yield = run(vc);
            const em = if (vc.exec_path == .emulated)
                &vc.exec_path.emulated
            else
                null;
            const should_yield = force_yield or (vc.state == .blocked) or
                (vc.state == .stopped) or (em != null and em.?.preempt_pending);
            if (should_yield) {
                if (em) |e| e.preempt_pending = false;
                scheduler.yield(vc);
                if (pcore.this().active_vcore) |act| {
                    current_vc = @ptrCast(@alignCast(act));
                } else {
                    current_vc = scheduler.pickNext();
                    if (current_vc) |next_vc| pcore.contextSwitch(next_vc);
                }
            }
        } else {
            const pcpu = pcore.this();
            const now = riscv.readTime();
            var min_target: u64 = riscv.TIMER_INFINITY;
            const b_emu_prev = pcpu.blocked_lock.lock();
            var it = pcpu.blocked_queue.start;
            while (it) |node| {
                const next_it = node.next;
                const vc: *vcore.VirtualCore =
                    @ptrCast(@alignCast(node.contents));
                if (!@atomicLoad(bool, &vc.wfi_blocked, .acquire)) {
                    pcpu.blocked_queue.remove(node);
                    vc.blocked_on_cpu = null;
                    it = next_it;
                    continue;
                }
                var wake = false;
                if (@atomicRmw(bool, &vc.pending_ipi, .Xchg, false, .acq_rel)) {
                    wake = true;
                    if (vc.exec_path == .emulated) {
                        if (vc.exec_path.emulated.vcpu) |v| {
                            v.setMipBit(sbi.MIP_SSIP_BIT);
                        }
                    }
                } else if (vc.exec_path == .emulated and
                    vc.exec_path.emulated.vcpu != null)
                {
                    const v = vc.exec_path.emulated.vcpu.?;
                    const vtimecmp = v.vstimecmp;
                    const mtimecmp = if (vc.exec_path.emulated.engine) |eng|
                        eng.bus.timer.getMtimecmp(vc.id)
                    else
                        riscv.TIMER_INFINITY;
                    const guest_target: u64 = @min(vtimecmp, mtimecmp);
                    if (guest_target != riscv.TIMER_INFINITY) {
                        const cur_guest_time = VCpu.readGuestTime();
                        if (cur_guest_time >= guest_target) {
                            wake = true;
                            v.setMipBit(sbi.MIP_STIP_BIT);
                        } else if (guest_target < min_target) {
                            min_target = guest_target;
                        }
                    }
                } else if (vc.timer_scheduled and
                    vc.timer_target != riscv.TIMER_INFINITY)
                {
                    if (now >= vc.timer_target) {
                        wake = true;
                        vc.timer_scheduled = false;
                    } else if (vc.timer_target < min_target) {
                        min_target = vc.timer_target;
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
                riscv.setTimer(now + SAFETY_WAKE_TICKS);
                riscv.pause();
                if (riscv.CLINT.msip(pcpu.hardware_hart_id)) |ptr| ptr.* = 0;
                if (pcore.this().active_vcore) |act| {
                    const act_vc: *vcore.VirtualCore =
                        @ptrCast(@alignCast(act));
                    if (!@atomicLoad(bool, &act_vc.wfi_blocked, .acquire) and
                        act_vc.state != .blocked)
                    {
                        current_vc = act_vc;
                    }
                }
                if (current_vc == null) {
                    current_vc = scheduler.pickNext();
                    if (current_vc) |next_vc| pcore.contextSwitch(next_vc);
                }
            }
        }
    }
}

/// Run native dynamic recompiler execution loop for virtual core.
pub fn run(vc: *vcore.VirtualCore) bool {
    init(vc) catch |e| {
        debug.printf("Native dynarec init failed: {s}\n", .{@errorName(e)});
        vc.guest.terminateWithCode(1);
        return true;
    };

    if (vc.exec_path != .emulated) return true;
    const em = &vc.exec_path.emulated;
    const vcpu_ptr = em.vcpu.?;
    const engine_ptr = em.engine.?;
    em.preempt_pending = false;

    vc.virtual_time = riscv.readTime();
    gdb_stub.stub.active_vc = vc;

    if (@atomicRmw(bool, &vc.pending_ipi, .Xchg, false, .acq_rel)) {
        vcpu_ptr.setMipBit(sbi.MIP_SSIP_BIT);
    }

    const insns_before = engine_ptr.total_insn_count;
    const exit_reason = engine_ptr.run(vcpu_ptr, DEFAULT_INSN_BUDGET);
    const insns_delta = engine_ptr.total_insn_count -% insns_before;
    _ = global_insn_count.fetchAdd(insns_delta, .monotonic);

    switch (exit_reason) {
        .wfi => _ = global_wfi_count.fetchAdd(1, .monotonic),
        .ecall => _ = global_ecall_count.fetchAdd(1, .monotonic),
        .yield, .normal => _ = global_yield_count.fetchAdd(1, .monotonic),
        else => {},
    }

    em.exit_count += 1;

    switch (exit_reason) {
        .yield, .normal => return false,
        .wfi => {
            vc.state = .blocked;
            const pcpu = pcore.this();
            const b_wfi_emu_prev = pcpu.blocked_lock.lock();
            vc.blocked_node.contents = vc;
            pcpu.blocked_queue.pushStart(&vc.blocked_node);
            vc.blocked_on_cpu = pcpu.cpu_core_id;
            @atomicStore(bool, &vc.wfi_blocked, true, .release);
            pcpu.blocked_lock.unlock(b_wfi_emu_prev);
            return true;
        },
        .page_fault, .illegal_instruction, .unhandled => {
            debug.printf(
                "FAULT EXIT: {s} pc=0x{x} fpc=0x{x} cause={} val=0x{x}\n",
                .{
                    @tagName(exit_reason),
                    vcpu_ptr.pc,
                    engine_ptr.last_fault_pc,
                    engine_ptr.last_fault_cause,
                    engine_ptr.last_fault_val,
                },
            );
            vc.guest.terminateWithCode(1);
            return true;
        },
        .ecall => {
            var context: riscv.ThreadContext = undefined;
            inline for (0..32) |i| context[i] = @truncate(vcpu_ptr.regs[i]);
            sbi.handle(vc, 0, &context);
            inline for (0..32) |i| vcpu_ptr.regs[i] = context[i];
            return vc.guest.state != .valid;
        },
    }
}

test "Emulated VCore dynamic slot allocation, isolation, and reclaim" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    const allocator = testing.allocator;

    var phys_test = try @import("physmem.zig").initForTest(allocator, 4096);
    defer phys_test.deinit();

    const g1 = try guest.createGuest(
        allocator,
        false,
        false,
        null,
        0x80000000,
        0x80000000,
        0x100000,
        .riscv32,
    );
    defer g1.deinit();

    var vcs: [4]*vcore.VirtualCore = undefined;
    for (&vcs, 0..) |*slot, idx| {
        slot.* = try g1.addVcore(idx, 0x80000000, 0x80001000, .normal, null);
        try init(slot.*);
    }
    const s0 = vcs[0].exec_path.emulated.slot_idx.?;
    const s1 = vcs[1].exec_path.emulated.slot_idx.?;
    const s2 = vcs[2].exec_path.emulated.slot_idx.?;
    const s3 = vcs[3].exec_path.emulated.slot_idx.?;
    try testing.expect(s0 != s1 and s0 != s2 and s0 != s3);
    try testing.expect(s1 != s2 and s1 != s3 and s2 != s3);
    try testing.expectEqual(&g1.uart, bus_pools[s0].uart);
    try testing.expectEqual(&g1.timer, bus_pools[s0].timer);
    try testing.expectEqual(&g1.pic, bus_pools[s0].pic);
    try testing.expectEqual(&g1.vsock, bus_pools[s0].vsock.?);

    const vc4 = try g1.addVcore(4, 0x80000000, 0x80001000, .normal, null);
    try testing.expectError(error.OutOfEmulatedVcoreSlots, init(vc4));

    deinit(vcs[1]);
    try testing.expect(vcs[1].exec_path.emulated.slot_idx == null);
    try init(vc4);
    try testing.expectEqual(s1, vc4.exec_path.emulated.slot_idx.?);

    for ([_]*vcore.VirtualCore{ vcs[0], vcs[2], vcs[3], vc4 }) |vc| deinit(vc);
}
