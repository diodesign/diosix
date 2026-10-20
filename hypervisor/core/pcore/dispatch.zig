// Physical CPU core IPI signaling, parking, and virtual core context switch.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const riscv = @import("../../hardware/native/cpu/riscv64/mod.zig");
const pmp = @import("../../hardware/native/cpu/riscv64/pmp.zig");
const vcore = @import("../vcore.zig");
const physmem = @import("../physmem.zig");
const pcore = @import("../pcore.zig");

pub fn sendIpiToCpu(cpu_id: usize) void {
    if (builtin.is_test) return;
    if (pcore.fromId(cpu_id)) |ctx| {
        const hw_hart = ctx.hardware_hart_id;
        if (hw_hart != pcore.this().hardware_hart_id) {
            if (riscv.CLINT.msip(hw_hart)) |ptr| {
                ptr.* = 1;
                return;
            }
        } else return;
    }
    broadcastIpi();
}

pub fn broadcastIpi() void {
    if (builtin.is_test) return;
    const my_hart = pcore.this().hardware_hart_id;

    for (&pcore.core_table) |*row| {
        if (row.static_ptr) |ctx| {
            if (ctx.hardware_hart_id != my_hart) {
                if (riscv.CLINT.msip(ctx.hardware_hart_id)) |ptr| ptr.* = 1;
            }
        }
    }

    const flags = pcore.table_lock.lock();
    defer pcore.table_lock.unlock(flags);

    for (&pcore.core_table) |*row| {
        var cur = row.dynamic_head;
        while (cur) |node| : (cur = node.next) {
            if (node.hart_id != my_hart) {
                if (riscv.CLINT.msip(node.hart_id)) |ptr| ptr.* = 1;
            }
        }
    }
}

pub fn parkOtherCores() void {
    pcore.host_stopping.store(true, .release);
    broadcastIpi();
    if (pcore.countOnline() <= 1) return;

    const my_ctx = pcore.this();
    const max_spins: usize = if (builtin.is_test) 1_000 else 100_000_000;
    var spins: usize = 0;
    while (spins < max_spins) : (spins += 1) {
        var all_parked = true;

        for (&pcore.core_table) |*row| {
            if (row.static_ptr) |ctx| {
                if (ctx != my_ctx and
                    !@atomicLoad(bool, &ctx.is_parked, .acquire))
                {
                    all_parked = false;
                    break;
                }
            }
        }

        if (all_parked) {
            const flags = pcore.table_lock.lock();
            for (&pcore.core_table) |*row| {
                var cur = row.dynamic_head;
                while (cur) |node| : (cur = node.next) {
                    if (&node.context != my_ctx and
                        !@atomicLoad(bool, &node.context.is_parked, .acquire))
                    {
                        all_parked = false;
                        break;
                    }
                }
                if (!all_parked) break;
            }
            pcore.table_lock.unlock(flags);
        }

        if (all_parked) return;
        if (spins % 10_000 == 0) broadcastIpi();
        riscv.pause();
    }
}

pub fn contextSwitch(to_vcore: *vcore.VirtualCore) void {
    const cpu = pcore.this();
    if (cpu.active_vcore) |active| {
        if (@intFromPtr(active) == @intFromPtr(to_vcore) and
            to_vcore.running_on_cpu == cpu.cpu_core_id)
        {
            return;
        }
    }
    if ((@intFromPtr(to_vcore) & (@alignOf(vcore.VirtualCore) - 1)) != 0) {
        @import("../debug.zig").printf(
            "!!! contextSwitch given misaligned to_vcore 0x{x}\n",
            .{@intFromPtr(to_vcore)},
        );
    }
    cpu.active_vcore = to_vcore;
    to_vcore.running_on_cpu = cpu.cpu_core_id;
    to_vcore.state = .running;
    to_vcore.last_dispatched_time =
        if (builtin.is_test) 0 else riscv.readTime();

    pmp.PMPConfig.clearAllPmp();
    const hv_reg = physmem.getHvRegion();
    if (hv_reg.size > 0 and to_vcore.exec_path == .native) {
        pmp.PMPConfig.writePmpAddr(0, hv_reg.base >> pmp.PMP_ADDR_SHIFT);
        pmp.PMPConfig.writePmpAddr(1, hv_reg.end() >> pmp.PMP_ADDR_SHIFT);
        pmp.PMPConfig.writePmpCfg(1, pmp.PMPAccess.tor | pmp.PMPAccess.none);
    }
    pmp.PMPConfig.writePmpAddr(2, std.math.maxInt(usize));
    pmp.PMPConfig.writePmpCfg(2, pmp.PMPAccess.napot | pmp.PMPAccess.rwx);

    to_vcore.guest.space.apply(to_vcore.guest.vmid);
    if (to_vcore.exec_path == .emulated and
        !to_vcore.exec_path.emulated.emu_running)
    {
        to_vcore.context[@backingInt(riscv.Register.tp)] = @intFromPtr(cpu);
        to_vcore.context[@backingInt(riscv.Register.a0)] =
            @intFromPtr(to_vcore);
    }
}

test "Physical CPU dispatch and IPI helpers" {
    std.testing.refAllDecls(@This());
}
