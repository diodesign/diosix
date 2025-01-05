// diosix hypervisor initialization and main loop
//
// Copyright (c) 2024, 2025 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const xint = @import("xint.zig");
const debug = @import("debug.zig");
const riscv = @import("riscv.zig");
const alloc = @import("alloc.zig");
const atomic = @import("atomic.zig");
const metadata = @import("metadata");
const dt = @import("dt.zig");

const BootCpuID: usize = 0; // CPU ID 0 does all the heavy lifting to begin with
var boot_complete_flag = false; // true when all cores can begin running viCPU threads

// global hypervisor state and resources - system_ctx_lock must be acquired before accessing post-boot
const SystemContext = struct {
    device_tree: ?*dt.DeviceTree,
};
var system_ctx_lock = atomic.NamedSpinLock.init("Global system context lock");
var system_ctx: ?*SystemContext = null;

// this is the thread-safe Zig entry point for the hypervisor
// cpu_core_id = unique ID assigned by the hypervisor to this CPU core
// dtb = pointer to system's device tree in memory
// returns to an infinite loop
pub export fn main(cpu_core_id: usize, dtb: [*]u8) void {
    // initialize this CPU core's private context
    // note that this creates a per-CPU heap allocator, ensuring each core has its own thread-safe memory pool.
    const cpu_ctx = riscv.getCPUContext();
    cpu_ctx.cpu_core_id = cpu_core_id;

    // initialize the heap, and store its metadata in the private context space
    // note: always pass the allocator as a pointer so that the metadata is always updated by callers
    cpu_ctx.allocator = alloc.Allocator.init(riscv.getCPUHeapBase(), riscv.getCPUHeapSize());

    // set up per-CPU core handling of exceptions and interrupts (xints)
    xint.init();

    // use one core for system-wide intialization
    switch (cpu_core_id) {
        BootCpuID => {
            debug.printf("{s}Version {s}-{s} ({s}) {s} {s}\n\n", .{ metadata.banner, metadata.project_version, metadata.git_branch, metadata.git_revision, metadata.build_date, metadata.cpu_arch });

            // allocate the system's context
            system_ctx = cpu_ctx.allocator.create(*SystemContext, @sizeOf(SystemContext)) catch |err| {
                debug.printf("Fatal! Failed to allocate system context, reason: {}\n", .{err});
                return;
            };

            // parse the system's device tree, but only keep the device tree, not the pre-parse blob
            const pre_parse_dtb = dt.DeviceTreeBlob.init(&cpu_ctx.allocator, dtb) catch |err| {
                debug.printf("Fatal! Failed to pre-parse device tree, reason: {}\n", .{err});
                return;
            };
            defer pre_parse_dtb.deinit() catch |err| {
                debug.printf("Oops! Failed to de-initialize DTB, reason: {}\n", .{err});
            };

            const device_tree = pre_parse_dtb.parse() catch |err| {
                debug.printf("Fatal! Failed to parse device tree, reason: {}\n", .{err});
                return;
            };

            // allow other cores to access the device tree
            if (system_ctx) |ctx| ctx.device_tree = device_tree;

            atomic.setBool(&boot_complete_flag, true); // unlock other cores
        },

        // make other CPU cores wait for the boot core to do its thing
        else => while (atomic.readBool(&boot_complete_flag) == false) {},
    }

    debug.printf("CPU core ID {} waiting for work...\n", .{cpu_core_id});
}
