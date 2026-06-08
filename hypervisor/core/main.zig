// Diosix hypervisor initialization and main loop.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const xint = @import("xint.zig");
const debug = @import("debug.zig");
const riscv = @import("riscv.zig");
const alloc = @import("alloc.zig");
const atomic = @import("atomic.zig");
const dt = @import("dt.zig");
const physmem = @import("physmem.zig");
const scheduler = @import("scheduler.zig");
const guest = @import("guest.zig");
const vcore = @import("vcore.zig");
const loader = @import("loader.zig");
const pcore = @import("pcore.zig");
const sv39x4 = @import("sv39x4.zig");
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
var boot_complete_flag = atomic.LockPayload(bool).init("Boot complete", false);

pub var global_root_vm: ?*guest.Guest = null;

// This is the thread-safe Zig entry point for the hypervisor.
// cpu_core_id = unique ID assigned by the hypervisor to this physical CPU core.
// dtb = pointer to host system's device tree in memory.
// Returns to an infinite loop.
pub export fn main(cpu_core_id: usize, dtb: [*]u8) void {
    // Basic hardware/architectural setup. No locks or complex structures yet.
    hw_pmp_init();

    // Exception and interrupt delegation is handled by hw_xint_init() in xint.s,
    // which is called from xint.init() below. See xint.s for the authoritative
    // medeleg and mideleg values.

    const cpu_ctx = riscv.getCPUContext();
    @memset(@as([*]u8, @ptrCast(cpu_ctx))[0..@sizeOf(riscv.CpuContext)], 0);
    cpu_ctx.cpu_core_id = cpu_core_id;

    const hart_id = riscv.readMhartid();
    cpu_ctx.hardware_hart_id = hart_id;
    if (cpu_core_id < riscv.cpu_to_hart_map.len) {
        riscv.cpu_to_hart_map[cpu_core_id] = hart_id;
    }
    if (cpu_core_id < riscv.MAX_PHYS_CORES) {
        riscv.cpu_contexts[cpu_core_id] = cpu_ctx;
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
            boot.bootCpuInit(allocator, dtb) catch |err| {
                debug.printf("Boot CPU core {} failed to initialize, reason: {s}\n", .{ cpu_core_id, @errorName(err) });
                return;
            };

            debug.printf("Physical boot CPU core {} finished initialization, releasing other cores\n", .{cpu_core_id});

            const guard = boot_complete_flag.acquire();
            guard.get().* = true;
            guard.release();
        },

        else => {
            while (true) {
                const guard = boot_complete_flag.acquire();
                const completed = guard.get().*;
                guard.release();
                if (completed) break;
            }
        },
    }

    xint.initCpuFeatures();

    debug.printf("Physical CPU core ID {} ready for work\n", .{cpu_core_id});
    while (true) {
        scheduler.schedule();

        if (pcore.this().active_vcore) |ptr| {
            const vc: *vcore.VirtualCore = @ptrCast(@alignCast(ptr));

            // Ensure machine state has latest hgatp if H-extension is active.
            if (vc.guest.space.mode == .h_paging) {
                const hgatp_val = vc.guest.space.paging.?.hgatp(vc.guest.vmid);
                if (vc.machine.hgatp != hgatp_val) {
                    vc.machine.hgatp = hgatp_val;
                }
            }

            if (vc.timer_scheduled and riscv.readTime() >= vc.timer_target) {
                vc.machine.hvip |= riscv.HVIP.VSTIP;
                vc.timer_scheduled = false;
            }

            pcore.hw_run_vcore(&vc.context, &vc.machine, &vc.guest_state);
        }

        // We only get here if no vcores were available to run.
        // Program the physical timer before going to sleep if a guest vcore is waiting for a timer event.
        if (global_root_vm) |g| {
            if (g.findVcore(pcore.this().hardware_hart_id)) |vc| {
                if (vc.wfi_blocked) {
                    var next_timer: u64 = 0xffffffffffffffff;
                    if (!config.legacy_cpu and riscv.riscv_supports_sstc) {
                        if (vc.guest_state.vstimecmp != 0 and vc.guest_state.vstimecmp != 0xffffffffffffffff) {
                            next_timer = vc.guest_state.vstimecmp;
                        }
                    }
                    if (vc.timer_scheduled) {
                        if (vc.timer_target < next_timer) {
                            next_timer = vc.timer_target;
                        }
                    }
                    if (next_timer != 0xffffffffffffffff) {
                        riscv.setTimer(next_timer);
                    }
                }
            }
        }
        riscv.pause(); // wfi
    }
}

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    debug.releaseLocksForCrash();
    debug.printf("\n\nPanic! {s}\n", .{message});
    while (true) {}
}


