// Diosix hypervisor initialization and main loop.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const xint = @import("arch/riscv64/xint.zig");
const debug = @import("debug.zig");
const riscv = @import("arch/riscv64/riscv.zig");
const alloc = @import("alloc.zig");
const atomic = @import("atomic.zig");
const dt = @import("dt.zig");
const physmem = @import("physmem.zig");
const scheduler = @import("scheduler.zig");
const guest = @import("guest.zig");
const vcore = @import("vcore.zig");
const loader = @import("loader.zig");
const pcore = @import("pcore.zig");
const sv39x4 = @import("arch/riscv64/sv39x4.zig");
const elf_spec = @import("interface").elf;
const boot = @import("boot.zig");
const config = @import("config");

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

// This is the thread-safe Zig entry point for the hypervisor.
// cpu_core_id = unique ID assigned by the hypervisor to this physical CPU core.
// dtb = pointer to host system's device tree in memory (valid for boot core only)
// Returns to an infinite loop.
var global_dtb: [*]u8 = undefined;

pub export fn main(cpu_core_id: usize, dtb: [*]u8) void {
    if (cpu_core_id == BootCpuID) global_dtb = dtb;
    // Basic hardware/architectural setup. No locks or complex structures yet.
    hw_pmp_init();

    // Exception and interrupt delegation is handled by hw_xint_init() in xint.s,
    // which is called from xint.init() below. See xint.s for the authoritative
    // medeleg and mideleg values.

    var cpu_ctx = riscv.getCPUContext();
    // Zero out the CpuContext structure since QEMU might have left garbage
    @memset(@as([*]u8, @ptrCast(cpu_ctx))[0..@sizeOf(riscv.CpuContext)], 0);

    cpu_ctx.last_timer_val = riscv.TIMER_INFINITY;

    cpu_ctx.cpu_core_id = cpu_core_id;
    if (cpu_core_id < riscv.MAX_PHYS_CORES) {
        riscv.cpu_contexts[cpu_core_id] = cpu_ctx;
    }
    cpu_ctx.in_m_mode = true; // Boot code runs in M-mode

    const hart_id = riscv.readMhartid();
    cpu_ctx.hardware_hart_id = hart_id;
    if (cpu_core_id < riscv.cpu_to_hart_map.len) {
        riscv.cpu_to_hart_map[cpu_core_id] = hart_id;
    }

    // Initialize the heap allocator for this core.
    cpu_ctx.allocator.init(riscv.getCPUHeapBase(), riscv.getCPUHeapSize()) catch return;
    const allocator = cpu_ctx.allocator.allocator();

    // Initialize interrupts and the scheduler.
    xint.init();
    scheduler.initCpu();

    // Make the boot CPU core does the single-threaded initialization, holding back the other cores until it's done.
    switch (cpu_core_id) {
        BootCpuID => {
            boot.bootCpuInit(allocator, global_dtb) catch |err| {
                debug.printf("Boot CPU core {} failed to initialize, reason: {s}\n", .{ cpu_core_id, @errorName(err) });
                return;
            };

            // Signal that features have been probed (done inside bootCpuInit via auditCpuFeatures)
            features_probed.store(true, .release);

            debug.printf("Physical boot CPU core {} finished initialization, releasing other cores\n", .{cpu_core_id});

            boot_complete_flag.store(true, .release);
        },

        else => {
            // Wait for CPU 0 to finish probing features
            while (!features_probed.load(.acquire)) {
                asm volatile ("nop");
            }

            while (!boot_complete_flag.load(.acquire)) {
                asm volatile ("nop");
            }
        },
    }

    xint.initCpuFeatures();

    debug.printf("Physical CPU core ID {} ready for work\n", .{cpu_core_id});
    while (true) {
        scheduler.schedule();

        if (pcore.this().active_vcore) |vc_raw| {
            const vc: *vcore.VirtualCore = @ptrCast(@alignCast(vc_raw));

            // Program the machine timer for preemptive multitasking.
            // The vcore runs for at most TIMESLICE_TICKS before the timer
            // fires and xint_handler calls scheduler.schedule() to pick
            // the next vcore (CFS vruntime ordering). If the guest has a
            // pending timer that expires sooner, use that instead to avoid
            // delaying guest timer interrupts.
            var timeslice_target: u64 = riscv.readTime() +% riscv.TIMESLICE_TICKS;

            // If the guest has a timer that fires before the timeslice ends,
            // use the guest timer so we can deliver its interrupt promptly.
            if (vc.timer_scheduled and vc.timer_target < timeslice_target) {
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
                    // Ensure machine state has latest hgatp if H-extension is active.
                    if (vc.guest.space.mode == .h_paging) {
                        const hgatp_val = vc.guest.space.paging.?.hgatp(vc.guest.vmid);
                        if (vc.getNativeMachine().hgatp != hgatp_val) {
                            vc.getNativeMachine().hgatp = hgatp_val;
                        }
                    }

                    pcore.this().in_m_mode = false;
                    pcore.hw_run_vcore(vc.getNativeContext(), vc.getNativeMachine(), vc.getNativeGuestState());
                },
                .emulated => {
                    vc.exec_path.emulated.context[@intFromEnum(riscv.Register.a0)] = @intFromPtr(vc);
                    vc.exec_path.emulated.context[@intFromEnum(riscv.Register.tp)] = @intFromPtr(pcore.this());
                    pcore.this().in_m_mode = false;
                    pcore.hw_run_vcore(vc.getNativeContext(), vc.getNativeMachine(), vc.getNativeGuestState());
                },
            }
        }

        // We only get here if no vcores were available to run.
        // Sleep until an IPI wakes us (e.g., HART_START or IPI broadcast).
        // Timer monitoring for blocked vcores is handled by the trap handler's
        // idle loop (in xint.zig), which is entered after the first trap.
        // We must NOT busy-loop or do MMIO here — in QEMU, MMIO writes to CLINT
        // serialize all vCPUs through the BQL, causing massive slowdowns.
        riscv.setTimer(riscv.TIMER_INFINITY);
        riscv.pause(); // WFI — sleep until IPI
    }
}

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    debug.releaseLocksForCrash();
    debug.printf("\n\nPanic! {s}\n", .{message});
    while (true) {}
}
