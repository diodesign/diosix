// Physical CPU core management
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("riscv.zig");
const vcore = @import("vcore.zig");
const alloc = @import("alloc.zig");

// the per-CPU context for the physical core running this thread
// this must match the structure returning by the low-level hw_private_variables()
pub const CpuContext = struct {
    cpu_core_id: usize,
    allocator: alloc.HeapAllocator,

    // The currently running virtual core on this physical core
    active_vcore: ?*vcore.VirtualCore,
};

// Return the CPU context for the physical core running this code
pub fn this() *CpuContext {
    return riscv.getCPUContext();
}

// Perform a context switch to the given virtual core
// This sets up the physical core to run the guest on the next exception return
pub fn contextSwitch(to_vcore: *vcore.VirtualCore) void {
    const cpu = this();

    // If we're already running a vcore, its state was saved into its
    // ThreadContext when we entered the machine mode (in assembly).
    // We just need to swap the active pointer and prepare for re-entry.
    cpu.active_vcore = to_vcore;

    // Prepare RISC-V CSRs for guest entry
    riscv.writeMepc(to_vcore.mepc);

    // Set up MSTATUS:
    // - set MPP to Supervisor (1)
    // - set MPIE to whatever we want (usually enabled)
    var mstatus = riscv.readMstatus();
    mstatus &= ~(@as(usize, 0b11) << 11); // Clear MPP
    mstatus |= (@as(usize, 1) << 11); // Set MPP to 1 (Supervisor)
    riscv.writeMstatus(mstatus);

    if (riscv.hasHExtension()) {
        riscv.writeHstatus(to_vcore.hstatus);
        riscv.writeHgatp(to_vcore.hgatp);
        riscv.writeHedeleg(to_vcore.hedeleg);
        riscv.writeHideleg(to_vcore.hideleg);
    }
}
