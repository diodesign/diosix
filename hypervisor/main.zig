// Diosix hypervisor entry point and main initialization loop.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const xint = @import("hardware/native/cpu/riscv64/xint.zig");
const debug = @import("core/debug.zig");
const riscv = @import("hardware/native/cpu/riscv64/mod.zig");
const alloc = @import("core/alloc.zig");
const atomic = @import("core/atomic.zig");
const dt = @import("core/dt.zig");
const physmem = @import("core/physmem.zig");
const scheduler = @import("core/scheduler.zig");
const guest = @import("core/guest.zig");
const vcore = @import("core/vcore.zig");
const loader = @import("core/loader.zig");
const pcore = @import("core/pcore.zig");
const sv39x4 = @import("hardware/native/cpu/riscv64/sv39x4.zig");
const elf_spec = @import("interface").elf;
const boot = @import("core/boot.zig");
const config = @import("config");
const gdb_stub = @import("core/gdb/stub.zig");

// Hardware Probing & Emulation Modules
pub const discovery = @import("hardware/native/discovery.zig");
pub const fdt = @import("hardware/native/fdt.zig");
pub const emulation = @import("emulation");

extern fn hw_pmp_init() void;

// Root VM linker symbols.
extern const __rootvm_start: u8;
extern const __rootvm_end: u8;

// CPU ID 0 does all the heavy lifting to begin with.
const BootCpuID: usize = 0;

// True when all cores can begin running vCPU threads.
var boot_complete_flag = std.atomic.Value(bool).init(false);

// True when CPU 0 has finished probing global hardware features.
pub var features_probed = std.atomic.Value(bool).init(false);

pub var global_root_vm: ?*guest.Guest = null;

var global_dtb: [*]u8 = undefined;

/// Thread-safe entry point for the hypervisor.
/// hartid: Physical CPU hart ID passed by OpenSBI/bootloader in a0
/// fdt_paddr: Physical address of host FDT/DTB blob passed in a1
pub export fn main(cpu_core_id: usize, fdt_paddr: usize) void {
    const hw_hartid = riscv.readMhartid();
    const dtb = @as([*]u8, @ptrFromInt(fdt_paddr));

    if (cpu_core_id == BootCpuID) {
        global_dtb = dtb;
        _ = discovery.probe(fdt_paddr);
    }

    // Basic hardware/architectural setup. No locks or complex structures yet.
    hw_pmp_init();

    var cpu_ctx = riscv.getCPUContext();
    @memset(@as([*]u8, @ptrCast(cpu_ctx))[0..@sizeOf(riscv.CpuContext)], 0);

    cpu_ctx.last_timer_val = riscv.TIMER_INFINITY;

    cpu_ctx.cpu_core_id = cpu_core_id;
    if (cpu_core_id < riscv.MAX_PHYS_CORES) {
        riscv.cpu_contexts[cpu_core_id] = cpu_ctx;
    }
    cpu_ctx.in_m_mode = true; // Boot code runs in M-mode

    cpu_ctx.hardware_hart_id = hw_hartid;
    if (cpu_core_id < riscv.cpu_to_hart_map.len) {
        riscv.cpu_to_hart_map[cpu_core_id] = hw_hartid;
    }

    // Initialize the heap allocator for this core.
    cpu_ctx.allocator.init(riscv.getCPUHeapBase(), riscv.getCPUHeapSize()) catch return;
    const allocator = cpu_ctx.allocator.allocator();

    // Initialize interrupts and the scheduler.
    xint.init();
    scheduler.initCpu();

    switch (cpu_core_id) {
        BootCpuID => {
            boot.bootCpuInit(allocator, global_dtb) catch |err| {
                debug.printf("Boot CPU core {} failed to initialize, reason: {s}\n", .{ cpu_core_id, @errorName(err) });
                return;
            };

            features_probed.store(true, .release);
            debug.printf("Physical boot CPU ID {} (hardware hart {}) finished initialization, releasing other cores\n", .{ cpu_core_id, hw_hartid });
            boot_complete_flag.store(true, .release);
        },

        else => {
            while (!features_probed.load(.acquire)) {
                asm volatile ("nop");
            }
            while (!boot_complete_flag.load(.acquire)) {
                asm volatile ("nop");
            }
        },
    }

    xint.initCpuFeatures();

    debug.printf("Physical CPU ID {} (hardware hart ID {}) ready for work\n", .{ cpu_core_id, hw_hartid });
    while (true) {
        if (pcore.this().active_vcore == null) {
            scheduler.schedule();
        }

        if (pcore.this().active_vcore) |vc_raw| {
            const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));

            var timeslice_target: u64 = riscv.readTime() +% riscv.TIMESLICE_TICKS;
            const now = riscv.readTime();
            if (vc.timer_scheduled and vc.timer_target > now and vc.timer_target < timeslice_target) {
                timeslice_target = vc.timer_target;
            }
            if (vc.exec_path == .native) {
                if (!config.legacy_cpu and riscv.riscv_supports_sstc) {
                    const gs = vc.getNativeGuestState();
                    if (gs.vstimecmp != 0 and gs.vstimecmp != riscv.TIMER_INFINITY and gs.vstimecmp < timeslice_target) {
                        timeslice_target = gs.vstimecmp;
                    }
                }
            }
            riscv.setTimer(timeslice_target);

            switch (vc.exec_path) {
                .native => {
                    if (vc.guest.space.mode == .h_paging) {
                        const hgatp_val = vc.guest.space.paging.?.hgatp(vc.guest.vmid);
                        if (vc.getNativeMachine().hgatp != hgatp_val) {
                            vc.getNativeMachine().hgatp = hgatp_val;
                        }
                    }

                    if (riscv.CLINT.msip(pcore.this().hardware_hart_id)) |ptr| {
                        ptr.* = 0;
                    }
                    pcore.this().in_m_mode = false;
                    pcore.hw_run_vcore(vc.getNativeContext(), vc.getNativeMachine(), vc.getNativeGuestState());
                },
                .emulated => {
                    vc.exec_path.emulated.context[@intFromEnum(riscv.Register.a0)] = @intFromPtr(vc);
                    vc.exec_path.emulated.context[@intFromEnum(riscv.Register.tp)] = @intFromPtr(pcore.this());
                    pcore.this().in_m_mode = true;
                    pcore.hw_run_vcore(vc.getNativeContext(), vc.getNativeMachine(), vc.getNativeGuestState());
                },
            }
        } else {
            riscv.setTimer(riscv.TIMER_INFINITY);
            gdb_stub.stub.pollSerialInput();
            riscv.pause(); // WFI — sleep only when no active vcore
        }
    }
}

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    debug.releaseLocksForCrash();
    debug.printf("\n\nPanic! {s} at 0x{x}\n", .{ message, return_address orelse 0 });
    while (true) {}
}
