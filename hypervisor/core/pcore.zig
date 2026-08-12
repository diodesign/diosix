// Physical CPU core management
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("../hardware/native/cpu/riscv64/mod.zig");
const vcore = @import("vcore.zig");
const alloc = @import("alloc.zig");

// Return the CPU context for the physical core running this code
pub fn this() *riscv.CpuContext {
    return riscv.getCPUContext();
}

pub extern fn hw_run_vcore(
    context: *riscv.ThreadContext,
    machine: *const riscv.MachineState,
    guest_state: *const riscv.GuestState,
) noreturn;

// Perform a context switch to the given virtual core
// This sets up the physical core to run the guest on the next exception return
pub fn contextSwitch(to_vcore: *vcore.VirtualCore) void {
    const cpu = this();
    if (@intFromPtr(to_vcore) & 7 != 0) @import("debug.zig").printf("!!! contextSwitch given misaligned to_vcore 0x{x}\n", .{@intFromPtr(to_vcore)});
    cpu.active_vcore = to_vcore;
    to_vcore.running_on_cpu = cpu.cpu_core_id;

    const pmp = @import("../hardware/native/cpu/riscv64/pmp.zig");
    switch (to_vcore.exec_path) {
        .native => {
            to_vcore.guest.space.apply(to_vcore.guest.vmid);
        },
        .emulated => |*e| {
            // Store physical CPU core context pointer in emulated runner's tp register
            if (!e.emu_running) {
                e.context[@intFromEnum(riscv.Register.tp)] = @intFromPtr(cpu);
            }

            pmp.PMPConfig.clearAllPmp();
            pmp.PMPConfig.writePmpAddr(0, ~@as(usize, 0));
            pmp.PMPConfig.writePmpCfg(0, 0x1f); // NAPOT, RWX
        },
    }
}
