// Diosix hypervisor entry point and main initialization loop.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const xint = @import("hardware/native/cpu/riscv64/xint.zig");
const debug = @import("core/debug.zig");
const riscv = @import("hardware/native/cpu/riscv64/mod.zig");
const dt = @import("core/dt.zig");
const physmem = @import("core/physmem.zig");
const scheduler = @import("core/scheduler.zig");
const guest = @import("core/guest.zig");
const vcore = @import("core/vcore.zig");
const pcore = @import("core/pcore.zig");
const boot = @import("core/boot.zig");
const config = @import("config");
const gdb_stub = @import("core/gdb/stub.zig");

// Hardware probing & emulation modules.
pub const discovery = @import("hardware/native/discovery.zig");
pub const fdt = @import("hardware/native/fdt.zig");
pub const emulation = @import("emulation");

extern fn hw_pmp_init() void;

// Gate in entry.s (.data) released by boot CPU (ID 0) once setup completes.
extern var boot_prep_done: u32;
extern var dyn_boot_lock: u32;

var test_boot_prep_done: u32 = 0;
var test_dyn_boot_lock: u32 = 0;

comptime {
    if (builtin.is_test) {
        @export(
            &test_boot_prep_done,
            .{ .name = "boot_prep_done", .linkage = .strong },
        );
        @export(
            &test_dyn_boot_lock,
            .{ .name = "dyn_boot_lock", .linkage = .strong },
        );
    }
}

pub var global_root_vm: ?*guest.Guest = null;

/// Thread-safe entry point for the hypervisor.
/// cpu_core_id: Sequential internal CPU ID (0..N-1) assigned in entry.s.
/// fdt_paddr: Physical address of the host FDT/DTB blob (valid on CPU 0).
pub export fn main(cpu_core_id: usize, fdt_paddr: usize) void {
    const hw_hartid = riscv.readMhartid();
    const is_boot_cpu = (cpu_core_id == 0);

    if (is_boot_cpu) {
        _ = discovery.probe(fdt_paddr);
    }

    // Basic hardware/architectural setup.
    hw_pmp_init();

    var cpu_ctx: *riscv.CpuContext = undefined;
    if (cpu_core_id < pcore.TABLE_ROWS) {
        // Cores 0..31: use contiguous static pre-allocated slab context.
        cpu_ctx = riscv.getCPUContext();
        @memset(
            @as([*]u8, @ptrCast(cpu_ctx))[0..@sizeOf(riscv.CpuContext)],
            0,
        );
        cpu_ctx.last_timer_val = riscv.TIMER_INFINITY;
        cpu_ctx.cpu_core_id = cpu_core_id;
        cpu_ctx.hardware_hart_id = hw_hartid;
        cpu_ctx.in_m_mode = true;
        pcore.registerStaticCore(cpu_core_id, hw_hartid, cpu_ctx);

        // Initialize the heap allocator for this core's slab.
        const heap_base = riscv.getCPUHeapBase();
        const heap_size = riscv.getCPUHeapSize();
        cpu_ctx.allocator.init(heap_base, heap_size) catch return;
    } else {
        // Cores 32+: physical memory and dynamic heap are ready from CPU 0.
        cpu_ctx = pcore.registerDynamicCore(cpu_core_id, hw_hartid) catch |e| {
            @atomicStore(u32, &dyn_boot_lock, 0, .release);
            debug.printf(
                "Physical CPU ID {} failed dynamic allocation: {s}\n",
                .{ cpu_core_id, @errorName(e) },
            );
            return;
        };
        riscv.setTp(@intFromPtr(cpu_ctx));
        @atomicStore(u32, &dyn_boot_lock, 0, .release);
    }

    const allocator = cpu_ctx.allocator.allocator();

    // Initialize interrupts and the scheduler for this CPU.
    xint.init();
    scheduler.initCpu();

    if (is_boot_cpu) {
        const dtb = @as([*]u8, @ptrFromInt(fdt_paddr));
        pcore.host_stopping.store(false, .release);
        boot.bootCpuInit(allocator, dtb) catch |err| {
            debug.printf(
                "Boot CPU core {} failed to initialize, reason: {s}\n",
                .{ cpu_core_id, @errorName(err) },
            );
            return;
        };

        // Enable dynamic slab/heap allocation for cores >= 32 and release all.
        pcore.setDynamicHeapReady(allocator);
        debug.printf(
            "Physical boot CPU ID {} (hardware hart {}) finished " ++
                "initialization, releasing other cores\n",
            .{ cpu_core_id, hw_hartid },
        );
        @atomicStore(u32, &boot_prep_done, 1, .release);
    }

    xint.initCpuFeatures();

    debug.printf(
        "Physical CPU ID {} (hardware hart ID {}) ready for work\n",
        .{ cpu_core_id, hw_hartid },
    );
    while (true) {
        if (pcore.host_stopping.load(.acquire)) {
            if (riscv.CLINT.msip(pcore.this().hardware_hart_id)) |ptr| {
                ptr.* = 0;
            }
            riscv.writeMie(0);
            @atomicStore(bool, &pcore.this().is_parked, true, .release);
            while (true) {
                riscv.pause();
            }
        }

        if (pcore.this().active_vcore == null) {
            scheduler.schedule();
        }

        if (pcore.this().active_vcore) |vc_raw| {
            const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));

            const now = riscv.readTime();
            var timeslice_target: u64 = now +% riscv.TIMESLICE_TICKS;
            if (vc.timer_scheduled and
                vc.timer_target > now and
                vc.timer_target < timeslice_target)
            {
                timeslice_target = vc.timer_target;
            }
            if (vc.exec_path == .native) {
                if (!config.legacy_cpu and riscv.riscv_supports_sstc) {
                    const gs = vc.getNativeGuestState();
                    if (gs.vstimecmp != 0 and
                        gs.vstimecmp != riscv.TIMER_INFINITY and
                        gs.vstimecmp < timeslice_target)
                    {
                        timeslice_target = gs.vstimecmp;
                    }
                }
            }
            riscv.setTimer(timeslice_target);

            switch (vc.exec_path) {
                .native => {
                    if (vc.guest.space.mode == .h_paging) {
                        const hgatp_val = if (vc.guest.space.paging) |*p|
                            p.hgatp(vc.guest.vmid)
                        else
                            0;
                        if (vc.getNativeMachine().hgatp != hgatp_val) {
                            vc.getNativeMachine().hgatp = hgatp_val;
                        }
                    }

                    if (riscv.CLINT.msip(pcore.this().hardware_hart_id)) |ptr| {
                        ptr.* = 0;
                    }
                    pcore.this().in_m_mode = false;
                    pcore.hw_run_vcore(
                        vc.getNativeContext(),
                        vc.getNativeMachine(),
                        vc.getNativeGuestState(),
                    );
                },
                .emulated => {
                    pcore.this().in_m_mode = true;
                    pcore.this().in_emulation_runner = true;
                    @import("core/emulation.zig").emulatedRunnerSMode(vc);
                },
            }
        } else {
            riscv.setTimer(riscv.TIMER_INFINITY);
            gdb_stub.stub.pollSerialInput();
            riscv.pause(); // WFI — sleep only when no active vcore.
            if (riscv.CLINT.msip(pcore.this().hardware_hart_id)) |ptr| {
                ptr.* = 0;
            }
        }
    }
}

pub fn panic(
    message: []const u8,
    _: ?*std.builtin.StackTrace,
    return_address: ?usize,
) noreturn {
    debug.releaseLocksForCrash();
    debug.printf(
        "\n\nPanic! {s} at 0x{x}\n",
        .{ message, return_address orelse 0 },
    );
    while (true) {}
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("interface");
    _ = @import("emulation");
    _ = @import("core/alloc.zig");
    _ = @import("core/atomic.zig");
    _ = @import("core/dsa.zig");
    _ = @import("core/drivers.zig");
    _ = @import("core/guest/dtb.zig");
    _ = @import("core/loader.zig");
    _ = @import("core/vm.zig");
    _ = @import("core/sbi.zig");
    _ = @import("core/emulation.zig");
    _ = @import("core/gdb/mod.zig");
    _ = @import("core/gdb/rsp.zig");
    _ = debug;
    _ = boot;
    _ = dt;
    _ = guest;
    _ = vcore;
    _ = scheduler;
    _ = pcore;
    _ = physmem;
    _ = gdb_stub;
    _ = xint;
    _ = riscv;
    _ = discovery;
    _ = fdt;
    _ = @import("hardware/native/drivers/uart.zig");
    _ = @import("hardware/native/drivers/clint.zig");
    _ = @import("hardware/native/drivers/plic.zig");
    _ = @import("hardware/emulation/arch/riscv32/mod.zig");
    _ = @import("hardware/emulation/arch/aarch64/mod.zig");
    _ = @import("hardware/emulation/arch/aarch64/psci.zig");
    _ = @import("hardware/emulation/arch/x86_64/mod.zig");
}
