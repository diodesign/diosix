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
pub export fn main(hartid_boot_arg: usize, fdt_paddr: usize) void {
    _ = hartid_boot_arg;
    const hw_hartid = riscv.readMhartid();
    const dtb = @as([*]u8, @ptrFromInt(fdt_paddr));

    // For static cores (< TABLE_ROWS), assign ID deterministically matching hw_hartid.
    // For dynamic cores (>= TABLE_ROWS), claim dense sequential internal core ID via atomic counter.
    const cpu_core_id = if (hw_hartid < pcore.TABLE_ROWS) hw_hartid else pcore.claimNextCpuId();

    if (cpu_core_id == BootCpuID) {
        global_dtb = dtb;
        _ = discovery.probe(fdt_paddr);
    }

    // Basic hardware/architectural setup. No locks or complex structures yet.
    hw_pmp_init();

    var cpu_ctx: *riscv.CpuContext = undefined;
    if (cpu_core_id < pcore.TABLE_ROWS) {
        // Cores 0..31: use static pre-allocated slab context
        cpu_ctx = riscv.getCPUContext();
        @memset(@as([*]u8, @ptrCast(cpu_ctx))[0..@sizeOf(riscv.CpuContext)], 0);
        cpu_ctx.last_timer_val = riscv.TIMER_INFINITY;
        cpu_ctx.cpu_core_id = cpu_core_id;
        cpu_ctx.hardware_hart_id = hw_hartid;
        cpu_ctx.in_m_mode = true; // Boot code runs in M-mode
        pcore.registerStaticCore(cpu_core_id, hw_hartid, cpu_ctx);

        // Initialize the heap allocator for this core.
        cpu_ctx.allocator.init(riscv.getCPUHeapBase(), riscv.getCPUHeapSize()) catch return;
    } else {
        // Cores 32+: wait until dynamic memory allocation is ready
        while (!pcore.isDynamicHeapReady()) {
            std.atomic.spinLoopHint();
        }
        cpu_ctx = pcore.registerDynamicCore(cpu_core_id, hw_hartid) catch |err| {
            debug.printf("Physical CPU ID {} failed dynamic allocation: {s}\n", .{ cpu_core_id, @errorName(err) });
            return;
        };
        // Update tp to point to the dynamically allocated CPU context
        riscv.setTp(@intFromPtr(cpu_ctx));
    }

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

            // Global dynamic heap is now ready for cores 32+
            pcore.setDynamicHeapReady(allocator);

            features_probed.store(true, .release);
            debug.printf("Physical boot CPU ID {} (hardware hart {}) finished initialization, releasing other cores\n", .{ cpu_core_id, hw_hartid });
            boot_complete_flag.store(true, .release);
        },

        else => {
            while (!features_probed.load(.acquire)) {
                std.atomic.spinLoopHint();
            }
            while (!boot_complete_flag.load(.acquire)) {
                std.atomic.spinLoopHint();
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
                        const hgatp_val = if (vc.guest.space.paging) |*p| p.hgatp(vc.guest.vmid) else 0;
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
                    vc.context[@intFromEnum(riscv.Register.a0)] = @intFromPtr(vc);
                    vc.context[@intFromEnum(riscv.Register.tp)] = @intFromPtr(pcore.this());
                    pcore.this().in_m_mode = true;
                    pcore.hw_run_vcore(vc.getNativeContext(), vc.getNativeMachine(), vc.getNativeGuestState());
                },
            }
        } else {
            riscv.setTimer(riscv.TIMER_INFINITY);
            gdb_stub.stub.pollSerialInput();
            riscv.pause(); // WFI — sleep only when no active vcore
            if (riscv.CLINT.msip(pcore.this().hardware_hart_id)) |ptr| {
                ptr.* = 0;
            }
        }
    }
}

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    debug.releaseLocksForCrash();
    debug.printf("\n\nPanic! {s} at 0x{x}\n", .{ message, return_address orelse 0 });
    while (true) {}
}

test {
    _ = @import("emulation");
}

