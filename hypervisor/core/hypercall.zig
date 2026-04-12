// Diosix Hypercall Interface
// Handles environment calls (ecall) from guest supervisor mode.

const std = @import("std");
const riscv = @import("riscv.zig");
const vcore = @import("vcore.zig");
const guest = @import("guest.zig");
const debug = @import("debug.zig");
const scheduler = @import("scheduler.zig");


pub const HypercallID = enum(usize) {
    vm_fork = 0x100,
    vm_exit = 0x101,
    vm_yield = 0x102,
    vm_drop_trust = 0x103,
    vm_quota_reduce = 0x104,
};

pub fn handle(vc: *vcore.VirtualCore, context: *riscv.ThreadContext) void {
    const id_raw = context[17]; // a7 is x17
    const id: HypercallID = @enumFromInt(id_raw);

    switch (id) {
        .vm_fork => {
            debug.printf("Hypercall: VM Fork requested by guest {}\n", .{vc.guest_id});
            const g = vc.getGuest();
            const child = g.fork() catch |err| {
                debug.printf("Hypercall: Fork failed: {s}\n", .{@errorName(err)});
                context[10] = 0xFFFFFFFFFFFFFFFF; // Return error in a0
                return;
            };
            
            // In the parent, return the child ID
            context[10] = child.id;
            
            // Register all child vcores with the scheduler
            var it_vcore = child.vcores.start;
            while (it_vcore) |node| {
                const child_vc = node.contents;
                scheduler.queue(child_vc);
                it_vcore = node.next;
            }

        },
        .vm_exit => {
            debug.printf("Hypercall: VM Exit requested by guest {}\n", .{vc.guest_id});
            const g = vc.getGuest();
            g.terminate();
            // This vcore will never return. The scheduler will pick a new one.
        },
        .vm_yield => {
            // Force a reschedule
            scheduler.yield(vc);
        },
        .vm_drop_trust => {
            debug.printf("Hypercall: VM Drop Trust requested by guest {}\n", .{vc.guest_id});
            const g = vc.getGuest();
            g.dropTrust();
        },
        .vm_quota_reduce => {
            debug.printf("Hypercall: VM Quota Reduce requested by guest {}\n", .{vc.guest_id});
            const g = vc.getGuest();
            const new_quotas = guest.QuotaSet{
                .max_ram_pages = context[10], // a0
                .max_vcpus = context[11],     // a1
                .max_priority = @truncate(context[12]), // a2
                .max_child_depth = context[13], // a3
                .max_descendants = context[14], // a4
            };
            g.reduceQuota(new_quotas);
        },
    }
}
