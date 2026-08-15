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
const sbi32 = @import("../hardware/emulation/arch/riscv32/sbi.zig");

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

pub fn getVirtualSModeTime(vc: *vcore.VirtualCore) u64 {
    const host_time = riscv.readTime();
    return @max(vc.virtual_time, host_time);
}

fn uartOutputCallback(char: u8) void {
    debug.putchar(char);
}

/// Initialize native dynamic recompiler instance for virtual core
pub fn init(vc: *vcore.VirtualCore) !void {
    const em = switch (vc.exec_path) {
        .emulated => |*e| e,
        else => return error.InvalidExecPath,
    };
    if (em.vcpu != null and em.engine != null) return;
    debug.printf("DEBUG emulation.init: vc=0x{x} target_arch={s}\n", .{ @intFromPtr(vc), @tagName(vc.guest.target_arch) });

    const allocator = pcore.this().allocator.allocator();
    const vcpu_ptr = allocator.create(VCpu) catch |err| {
        debug.printf("ERROR init: failed to allocate VCpu: {s}\n", .{@errorName(err)});
        return err;
    };
    const softtlb_ptr = allocator.create(emulation_native.SoftTlb) catch |err| {
        debug.printf("ERROR init: failed to allocate SoftTlb: {s}\n", .{@errorName(err)});
        return err;
    };
    const bus_ptr = allocator.create(emulation_native.Bus) catch |err| {
        debug.printf("ERROR init: failed to allocate Bus: {s}\n", .{@errorName(err)});
        return err;
    };
    const uart_ptr = allocator.create(emulation_native.VirtualUart) catch |err| {
        debug.printf("ERROR init: failed to allocate VirtualUart: {s}\n", .{@errorName(err)});
        return err;
    };
    const timer_ptr = allocator.create(emulation_native.VirtualTimer) catch |err| {
        debug.printf("ERROR init: failed to allocate VirtualTimer: {s}\n", .{@errorName(err)});
        return err;
    };
    const pic_ptr = allocator.create(emulation_native.VirtualPlic) catch |err| {
        debug.printf("ERROR init: failed to allocate VirtualPlic: {s}\n", .{@errorName(err)});
        return err;
    };
    const engine_ptr = allocator.create(Engine) catch |err| {
        debug.printf("ERROR init: failed to allocate Engine: {s}\n", .{@errorName(err)});
        return err;
    };

    const gpa_base = vc.guest.space.base_gpa;
    const hpa_base = vc.guest.space.base_hpa;
    const ram_size = vc.guest.space.range_size;
    debug.printf("DEBUG emulation.init: vc=0x{x} id={} gpa_base=0x{x} hpa_base=0x{x} ram_size=0x{x}\n", .{ @intFromPtr(vc), vc.id, gpa_base, hpa_base, ram_size });

    if (vc.id == 0) {
        const now = riscv.readTime();
        vcore.time_offset = now;
        VCpu.time_offset = now;
        VCpu.max_guest_time.store(0, .monotonic);
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
        vcpu_ptr.misa = (1 << 30) | (1 << 8) | (1 << 12) | (1 << 0) | (1 << 5) | (1 << 3) | (1 << 2);
        vcpu_ptr.running = true;
    } else {
        vcpu_ptr.id = vc.id;
        vcpu_ptr.privilege_mode = 1;
        vcpu_ptr.priv_mode = 1;
        vcpu_ptr.medeleg = 0xFFFF;
        vcpu_ptr.mideleg = 0xFFFF;
        vcpu_ptr.running = false;
    }

    softtlb_ptr.initOnPtr(gpa_base, hpa_base, ram_size);

    @memset(@as([*]u8, @ptrCast(uart_ptr))[0..@sizeOf(emulation_native.VirtualUart)], 0);
    uart_ptr.guest_id = vc.guest_id;
    uart_ptr.out_fn = uartOutputCallback;

    @memset(@as([*]u8, @ptrCast(timer_ptr))[0..@sizeOf(emulation_native.VirtualTimer)], 0);
    @memset(@as([*]u8, @ptrCast(pic_ptr))[0..@sizeOf(emulation_native.VirtualPlic)], 0);

    bus_ptr.uart = uart_ptr;
    bus_ptr.timer = timer_ptr;
    bus_ptr.pic = pic_ptr;

    const vcore_idx = vc.id % MAX_EMULATED_VCORES;
    engine_ptr.initOnPtr(&jit_buffer_pools[vcore_idx], vcpu_ptr, softtlb_ptr, bus_ptr);

    if (em.target_arch == .riscv32 and vc.id == 0) {
        rv32_arch.initRegisters(vcpu_ptr, em.entry, em.dtb, 0);
    }

    em.vcpu = vcpu_ptr;
    em.engine = engine_ptr;
}

/// Stop execution of emulated vcore
pub fn stop(vc: *vcore.VirtualCore) void {
    const em = switch (vc.exec_path) {
        .emulated => |*e| e,
        else => return,
    };
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
            const em = switch (vc.exec_path) {
                .emulated => |*e| e,
                else => null,
            };
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
            var it = pcpu.blocked_queue.start;
            while (it) |node| {
                const next_it = node.next;
                const vc: *vcore.VirtualCore = @ptrCast(@alignCast(node.contents));
                if (!@atomicLoad(bool, &vc.wfi_blocked, .acquire)) {
                    // Woken by remote CPU / IPI
                    pcpu.blocked_queue.remove(node);
                    it = next_it;
                    continue;
                }
                var wake = false;
                if (@atomicRmw(bool, &vc.pending_ipi, .Xchg, false, .acq_rel)) {
                    wake = true;
                    if (vc.exec_path == .emulated and vc.exec_path.emulated.vcpu != null) {
                        vc.exec_path.emulated.vcpu.?.mip |= (1 << 1); // SSIP
                    }
                } else {
                    var target: u64 = std.math.maxInt(u64);
                    if (vc.timer_scheduled) {
                        target = vc.timer_target;
                    }
                    if (vc.exec_path == .emulated and vc.exec_path.emulated.vcpu != null) {
                        const v = vc.exec_path.emulated.vcpu.?;
                        const vtimecmp = v.vstimecmp;
                        const mtimecmp = if (vc.id < 4 and vc.exec_path.emulated.engine != null) vc.exec_path.emulated.engine.?.bus.timer.mtimecmp[vc.id] else ~@as(u64, 0);
                        const guest_target = @min(vtimecmp, mtimecmp);
                        if (guest_target != ~@as(u64, 0)) {
                            const host_target = guest_target +% vcore.time_offset;
                            if (host_target < target) target = host_target;
                        }
                    }
                    if (target != std.math.maxInt(u64)) {
                        if (now >= target) {
                            wake = true;
                            vc.timer_scheduled = false;
                            if (vc.exec_path == .emulated and vc.exec_path.emulated.vcpu != null) {
                                vc.exec_path.emulated.vcpu.?.mip |= (1 << 5); // STIP
                            }
                        } else if (target < min_target) {
                            min_target = target;
                        }
                    }
                }
                if (wake) {
                    pcpu.blocked_queue.remove(node);
                    if (vc.tryWake()) {
                        vc.blocked_on_cpu = null;
                        if (current_vc == null) {
                            pcore.contextSwitch(vc);
                            current_vc = vc;
                        } else {
                            scheduler.queue(vc);
                        }
                    }
                }
                it = next_it;
            }

            if (current_vc == null) {
                const safety_target = if (min_target != std.math.maxInt(u64)) min_target else (now + 10_000);
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

    const em = switch (vc.exec_path) {
        .emulated => |*e| e,
        else => return,
    };
    const vcpu_ptr = em.vcpu.?;
    const engine_ptr = em.engine.?;
    em.preempt_pending = false;

    vc.virtual_time = riscv.readTime();
    gdb_stub.stub.active_vc = vc;

    if (@atomicRmw(bool, &vc.pending_ipi, .Xchg, false, .acq_rel)) {
        vcpu_ptr.mip |= (1 << 1); // SSIP
    }

    const budget: usize = 2_000_000;
    const exit_reason = engine_ptr.run(vcpu_ptr, budget);

    em.exit_count += 1;
    if (em.exit_count <= 20 or em.exit_count % 100 == 0 or vc.id == 0) {
        debug.printf("EMU PROGRESS: vc={} pc=0x{x} irq_pc=0x{x} satp=0x{x} priv={} exit={s} exits={}\n", .{ vc.id, vcpu_ptr.pc, engine_ptr.last_irq_pc, vcpu_ptr.satp, vcpu_ptr.privilege_mode, @tagName(exit_reason), em.exit_count });
    }

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
            vc.blocked_node.contents = vc;
            pcore.this().blocked_queue.pushStart(&vc.blocked_node);
            vc.blocked_on_cpu = pcore.this().cpu_core_id;
            @atomicStore(bool, &vc.wfi_blocked, true, .release);
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

            sbi32.handle(vc, 0, &context);

            inline for (0..32) |i| {
                vcpu_ptr.regs[i] = context[i];
            }
        },
    }
}
