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
    if (cpu.active_vcore) |active| {
        if (@intFromPtr(active) == @intFromPtr(to_vcore) and to_vcore.running_on_cpu == cpu.cpu_core_id) {
            return;
        }
    }
    if (@intFromPtr(to_vcore) & 7 != 0) @import("debug.zig").printf("!!! contextSwitch given misaligned to_vcore 0x{x}\n", .{@intFromPtr(to_vcore)});
    cpu.active_vcore = to_vcore;
    to_vcore.running_on_cpu = cpu.cpu_core_id;
    to_vcore.state = .running;

    const pmp = @import("../hardware/native/cpu/riscv64/pmp.zig");
    pmp.PMPConfig.clearAllPmp();
    pmp.PMPConfig.writePmpAddr(0, ~@as(usize, 0));
    pmp.PMPConfig.writePmpCfg(0, 0x1f); // NAPOT, RWX

    switch (to_vcore.exec_path) {
        .native => {
            to_vcore.guest.space.apply(to_vcore.guest.vmid);
        },
        .emulated => |*e| {
            to_vcore.guest.space.apply(to_vcore.guest.vmid);
            // Store physical CPU core context pointer in emulated runner's tp register and vcore in a0
            if (!e.emu_running) {
                e.context[@intFromEnum(riscv.Register.tp)] = @intFromPtr(cpu);
                e.context[@intFromEnum(riscv.Register.a0)] = @intFromPtr(to_vcore);
            }
        },
    }
}
