// Physical CPU core management
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("riscv.zig");
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
    cpu.active_vcore = to_vcore;
    to_vcore.running_on_cpu = cpu.cpu_core_id;

    // Apply guest memory space (paging or PMP)
    to_vcore.guest.space.apply(to_vcore.guest.vmid);
}
