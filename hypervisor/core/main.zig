// diosix hypervisor initialization and main loop
//
// Copyright (c) 2024 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const xint = @import("xint.zig");
const debug = @import("debug.zig");
const riscv = @import("riscv.zig");
const alloc = @import("alloc.zig");
const atomic = @import("atomic.zig");
const metadata = @import("metadata");
const dt = @import("dt.zig");

const BootCpuID: usize = 0; // CPU ID 0 does all the heavy lifting to begin with
var boot_finished_flag = false;

// this is the thread-safe Zig entry point for the hypervisor
pub export fn main(cpu_core_id: usize, dtb: [*]u8) void {
    // initialize this CPU core's private context
    // note that this creates a per-CPU heap allocator, ensuring each core has its own thread-safe memory pool.
    const cpu_ctx = riscv.get_cpu_context();
    cpu_ctx.cpu_core_id = cpu_core_id;

    // initialize the heap and store its metadata in the private context space
    // note: always pass the allocator as a pointer so that the metadata is always updated by callers
    cpu_ctx.allocator = alloc.Allocator.init(riscv.get_cpu_heap_base(), riscv.get_cpu_heap_size());

    // set up per-CPU core handling of exceptions and interrupts (xints)
    xint.init();

    // use one core for system-wide intialization
    switch (cpu_core_id) {
        BootCpuID => {
            debug.printf("{s}Version {s}-{s} ({s}) {s} {s}\n\n", .{ metadata.banner, metadata.project_version, metadata.git_branch, metadata.git_revision, metadata.build_date, metadata.cpu_arch });

            const parsed = dt.DeviceTreeBlob.init(&cpu_ctx.allocator, dtb) catch |err| {
                debug.printf("Faield to parse device tree, reason: {!}\nHalting...\n", .{err});
                return;
            };
            defer parsed.deinit(&cpu_ctx.allocator) catch |err| {
                debug.printf("Failed to de-initialize DTB during failed initialization, reason: {!}\n", .{err});
            };

            atomic.set_bool(&boot_finished_flag, true); // unlock other cores
        },

        // make other CPU cores wait for the boot core to do its thing
        else => while (atomic.read_bool(&boot_finished_flag) == false) {},
    }

    debug.printf("CPU core ID {} waiting for work...\n", .{cpu_core_id});
}
