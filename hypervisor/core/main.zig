// diosix hypervisor initialization and main loop
//
// Copyright (c) 2024, 2025, 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
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

// this is the core initialization logic for the boot CPU.
// it is separated from main() to allow for easier testing.
fn bootCpuInit(cpu_allocator: std.mem.Allocator, dtb: [*]u8) !void {
    debug.printf("{s}Version {s} {s}/{s} {s} {s}@{s} (Zig {s} {s})\n\n", .{ metadata.banner, metadata.project_version, metadata.git_branch, metadata.git_revision, metadata.build_date, metadata.build_user, metadata.build_hostname, metadata.zig_version, metadata.cpu_arch });

    system_ctx = try cpu_allocator.create(SystemContext);

    const pre_parse_dtb = try dt.DeviceTreeBlob.init(cpu_allocator, dtb);
    defer pre_parse_dtb.deinit();

    // keep parsed tree in boot CPU core's heap
    const device_tree = try pre_parse_dtb.parse();

    if (system_ctx) |ctx| ctx.device_tree = device_tree;
}

// this is the thread-safe Zig entry point for the hypervisor
// cpu_core_id = unique ID assigned by the hypervisor to this physical CPU core
// dtb = pointer to system's device tree in memory
// returns to an infinite loop
pub export fn main(cpu_core_id: usize, dtb: [*]u8) void {
    if (builtin.is_test) return;
    const cpu_ctx = riscv.getCPUContext();
    cpu_ctx.cpu_core_id = cpu_core_id;

    cpu_ctx.allocator.init(riscv.getCPUHeapBase(), riscv.getCPUHeapSize()) catch {
        debug.printf("CPU core ID {} failed to initialize its heap allocator\n", .{cpu_core_id});
        return;
    };
    const allocator = cpu_ctx.allocator.allocator();

    xint.init();

    switch (cpu_core_id) {
        BootCpuID => {
            bootCpuInit(allocator, dtb) catch |err| {
                debug.printf("Boot CPU failed to initialize, reason: {s}\n", .{@errorName(err)});
                // In a real scenario, we might halt or panic here.
                // For now, we just stop this core.
                return;
            };

            atomic.writeBool(&boot_complete_flag, true);
        },

        else => while (atomic.readBool(&boot_complete_flag) == false) {},
    }

    debug.printf("CPU core ID {} waiting for work...\n", .{cpu_core_id});
}

test "boot CPU initialization" {
    const testing = std.testing;

    // Create a mock device tree blob. The contents don't have to be valid
    // for this test, just the header structure for parsing.
    // fdt_header { magic, totalsize, off_dt_struct, ... }
    var fake_dtb_data = [_]u8{
        0xd0, 0x0d, 0xfe, 0xed, // magic
        0x00, 0x00, 0x00, 0x40, // totalsize = 64
        0x00, 0x00, 0x00, 0x28, // off_dt_struct
        0x00, 0x00, 0x00, 0x38, // off_dt_strings
        0x00, 0x00, 0x00, 0x00, // off_mem_rsvmap
        0x00, 0x00, 0x00, 0x11, // version
        0x00, 0x00, 0x00, 0x10, // last_comp_version
        0x00, 0x00, 0x00, 0x00, // boot_cpuid_phys
        0x00, 0x00, 0x00, 0x00, // size_dt_strings
        0x00, 0x00, 0x00, 0x00, // size_dt_struct
    };
    const fake_dtb_ptr: [*]u8 = &fake_dtb_data;

    // Use the standard testing allocator to act as the heap
    const allocator = testing.allocator;

    // Run the boot init function
    try bootCpuInit(allocator, fake_dtb_ptr);

    // Check that the global system context was created and the device tree was assigned
    try testing.expect(system_ctx != null);
    if (system_ctx) |ctx| {
        try testing.expect(ctx.device_tree != null);
        // Clean up the memory allocated during the test
        allocator.destroy(ctx.device_tree.?);
        allocator.destroy(ctx);
    }

    // Reset global state for other tests
    system_ctx = null;
}
