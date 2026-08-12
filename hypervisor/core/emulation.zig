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

/// 2MB code buffer size per emulated vcore
const JIT_CODE_BUFFER_SIZE: usize = 2 * 1024 * 1024;

var jit_buffer_pool: [JIT_CODE_BUFFER_SIZE]u8 = undefined;

pub fn getVirtualSModeTime(vc: *vcore.VirtualCore) u64 {
    const host_time = riscv.readTime();
    return @max(vc.virtual_time, host_time);
}

fn uartOutputCallback(char: u8) void {
    debug.putchar(char);
}

/// Initialize native dynamic recompiler instance for virtual core
pub fn init(vc: *vcore.VirtualCore) !void {
    const em = &vc.exec_path.emulated;
    if (em.vcpu != null and em.engine != null) return;

    const allocator = pcore.this().allocator.allocator();
    const vcpu_ptr = try allocator.create(VCpu);
    const softtlb_ptr = try allocator.create(emulation_native.SoftTlb);
    const bus_ptr = try allocator.create(emulation_native.Bus);
    const uart_ptr = try allocator.create(emulation_native.VirtualUart);
    const timer_ptr = try allocator.create(emulation_native.VirtualTimer);
    const pic_ptr = try allocator.create(emulation_native.VirtualPlic);

    const ram_base = vc.guest.space.base_hpa;
    const ram_size = vc.guest.space.range_size;

    vcpu_ptr.* = VCpu{};
    softtlb_ptr.* = emulation_native.SoftTlb.init(ram_base, ram_size);
    uart_ptr.* = emulation_native.VirtualUart{ .guest_id = vc.guest_id };
    timer_ptr.* = emulation_native.VirtualTimer{};
    pic_ptr.* = emulation_native.VirtualPlic{};
    bus_ptr.* = emulation_native.Bus{
        .uart = uart_ptr,
        .timer = timer_ptr,
        .pic = pic_ptr,
    };

    const engine_ptr = try allocator.create(Engine);
    engine_ptr.* = Engine.init(&jit_buffer_pool, vcpu_ptr, softtlb_ptr, bus_ptr);

    if (em.target_arch == .riscv32) {
        rv32_arch.initRegisters(vcpu_ptr, em.entry, em.dtb, 0);
    }

    em.vcpu = vcpu_ptr;
    em.engine = engine_ptr;
}

/// Stop execution of emulated vcore
pub fn stop(vc: *vcore.VirtualCore) void {
    const em = &vc.exec_path.emulated;
    em.preempt_pending = true;
}

/// Supervisor-mode runner entry point for emulated virtual cores
pub fn emulatedRunnerSMode(vc: *vcore.VirtualCore) void {
    run(vc);
}

/// Run native dynamic recompiler execution loop for virtual core
pub fn run(vc: *vcore.VirtualCore) void {
    init(vc) catch |e| {
        debug.printf("Native dynarec init failed: {s}\n", .{@errorName(e)});
        return;
    };

    const em = &vc.exec_path.emulated;
    const vcpu_ptr = em.vcpu.?;
    const engine_ptr = em.engine.?;
    em.preempt_pending = false;

    vc.virtual_time = riscv.readTime();
    gdb_stub.stub.active_vc = vc;

    const budget: u32 = 10_000;
    const exit_reason = engine_ptr.run(vcpu_ptr, budget);

    switch (exit_reason) {
        .yield, .normal => {},
        .wfi => {
            vc.wfi_blocked = true;
        },
        .ecall => {
            // Forward SBI / system calls
        },
        .page_fault, .illegal_instruction, .unhandled => {
            debug.printf("Dynarec execution trap: reason={s} PC=0x{x}\n", .{ @tagName(exit_reason), vcpu_ptr.pc });
        },
    }
}
