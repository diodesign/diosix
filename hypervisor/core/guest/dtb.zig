// Guest Flattened Device Tree (DTB) builders for RISC-V and AArch64 Root VMs.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const dt = @import("../dt.zig");
const guest = @import("../guest.zig");
const debug = @import("../debug.zig");

const BASE_RISCV_BOOTARGS =
    "console=hvc0 earlycon=sbi rootfstype=ramfs cma=32M no4lvl maxcpus={} " ++
    "lpj=50000 rcupdate.rcu_cpu_stall_suppress=1 rcutree.kthread_prio=1 " ++
    "unaligned_scalar_speed=fast video=1280x800 vt.global_cursor_default=0{s}";

/// Modifies the parsed host device tree in place for a RISC-V Root VM and
/// serializes it to a binary DTB blob. Populates `guest_hart_ids` with the
/// discovered `reg` properties of enabled CPU nodes.
pub fn buildRiscvGuestDtb(
    cpu_allocator: std.mem.Allocator,
    device_tree: *dt.DeviceTree,
    guest_arch: guest.TargetArch,
    root_vm_gpa_base: usize,
    rootvm_ram_size: usize,
    cpu_count: usize,
    host_bootargs: []const u8,
    guest_hart_ids: []usize,
) ![]u8 {
    // Delete any existing /memory@* nodes from the host DTB.
    while (true) {
        var mem_it = device_tree.iter("/", 1);
        var found_mem: ?[]const u8 = null;
        while (mem_it.next()) |path| {
            if (std.mem.startsWith(u8, path, "/memory@")) {
                found_mem = path;
                break;
            }
        }
        if (found_mem) |path| {
            device_tree.deleteNode(path);
        } else break;
    }

    const guest_memory_node = try std.fmt.allocPrint(
        cpu_allocator,
        "/memory@{x}",
        .{root_vm_gpa_base},
    );
    defer cpu_allocator.free(guest_memory_node);

    try device_tree.editProperty(
        guest_memory_node,
        "reg",
        try dt.DeviceTreeProperty.fromMultiU64(
            cpu_allocator,
            &.{ root_vm_gpa_base, rootvm_ram_size },
        ),
    );
    try device_tree.editProperty(
        guest_memory_node,
        "device_type",
        try dt.DeviceTreeProperty.fromText(cpu_allocator, "memory"),
    );

    const guest_cpus: usize = if (guest_arch != .riscv64) 1 else cpu_count;
    const mitigations = if (guest_arch != .riscv64)
        " mitigations=off clocksource=riscv_clocksource"
    else
        "";
    const bootargs = if (host_bootargs.len > 0)
        try std.fmt.allocPrint(
            cpu_allocator,
            BASE_RISCV_BOOTARGS ++ " {s}",
            .{ guest_cpus, mitigations, host_bootargs },
        )
    else
        try std.fmt.allocPrint(
            cpu_allocator,
            BASE_RISCV_BOOTARGS,
            .{ guest_cpus, mitigations },
        );
    defer cpu_allocator.free(bootargs);

    device_tree.editProperty(
        "/chosen",
        "bootargs",
        try dt.DeviceTreeProperty.fromText(cpu_allocator, bootargs),
    ) catch |err| {
        debug.printf(
            "Warning: Failed to inject bootargs into guest DTB: {s}\n",
            .{@errorName(err)},
        );
    };

    // Clear host-specific reserved memory nodes and entries.
    device_tree.reserved_count = 0;
    while (true) {
        var res_it = device_tree.iter("/reserved-memory", 10);
        if (res_it.next()) |path| {
            device_tree.deleteNode(path);
        } else break;
    }

    // Remove AIA interrupt controller nodes (aplic and imsic) so the guest
    // kernel falls back to PLIC.
    while (true) {
        var aia_it = device_tree.iter("/", 10);
        var found_aia: ?[]const u8 = null;
        while (aia_it.next()) |path| {
            if (std.mem.indexOf(u8, path, "aplic") != null or
                std.mem.indexOf(u8, path, "imsic") != null)
            {
                found_aia = path;
                break;
            }
        }
        if (found_aia) |path| {
            device_tree.deleteNode(path);
        } else break;
    }

    // Set /cpus timebase-frequency to 10 MHz (0x00989680).
    try device_tree.editProperty(
        "/cpus",
        "timebase-frequency",
        try dt.DeviceTreeProperty.fromBytes(
            cpu_allocator,
            &[_]u8{ 0x00, 0x98, 0x96, 0x80 },
        ),
    );

    var cpu_it = device_tree.iter("/cpus/cpu@", 10);
    var enabled_cpu_index: usize = 0;
    while (cpu_it.next()) |path| {
        var slash_count: usize = 0;
        for (path) |c| {
            if (c == '/') slash_count += 1;
        }
        if (slash_count != 2) continue;

        if (guest_arch == .riscv32) {
            try device_tree.editProperty(
                path,
                "riscv,isa",
                try dt.DeviceTreeProperty.fromText(
                    cpu_allocator,
                    "rv32imafdc",
                ),
            );
            try device_tree.editProperty(
                path,
                "riscv,isa-base",
                try dt.DeviceTreeProperty.fromText(cpu_allocator, "rv32i"),
            );
            try device_tree.editProperty(
                path,
                "mmu-type",
                try dt.DeviceTreeProperty.fromText(
                    cpu_allocator,
                    "riscv,sv32",
                ),
            );
            var minimal_exts = std.ArrayList(u8).empty;
            defer minimal_exts.deinit(cpu_allocator);
            for ([_][]const u8{
                "i",
                "m",
                "a",
                "f",
                "d",
                "c",
                "zicsr",
                "zifencei",
            }) |ext| {
                try minimal_exts.appendSlice(cpu_allocator, ext);
                try minimal_exts.append(cpu_allocator, 0);
            }
            try device_tree.editProperty(
                path,
                "riscv,isa-extensions",
                try dt.DeviceTreeProperty.fromBytes(
                    cpu_allocator,
                    minimal_exts.items,
                ),
            );
        }

        if (enabled_cpu_index < cpu_count) {
            try device_tree.editProperty(
                path,
                "status",
                try dt.DeviceTreeProperty.fromText(cpu_allocator, "okay"),
            );
            var reg_val: usize = enabled_cpu_index;
            if (device_tree.getProperty(path, "reg")) |reg_prop| {
                if (reg_prop.data) |reg_data| {
                    if (reg_data.len == 8) {
                        reg_val = std.mem.readInt(u64, reg_data[0..8], .big);
                    } else if (reg_data.len == 4) {
                        reg_val = std.mem.readInt(u32, reg_data[0..4], .big);
                    }
                }
            } else |_| {}

            if (enabled_cpu_index < guest_hart_ids.len) {
                guest_hart_ids[enabled_cpu_index] = reg_val;
            }
            enabled_cpu_index += 1;
        } else {
            try device_tree.editProperty(
                path,
                "status",
                try dt.DeviceTreeProperty.fromText(cpu_allocator, "disabled"),
            );
        }
    }

    // Delete extra CPU nodes beyond cpu_count and all their descendants.
    while (true) {
        var del_it = device_tree.iter("/cpus/cpu@", 10);
        var del_index: usize = 0;
        var found_to_delete: ?[]const u8 = null;
        var delete_prefix: ?[]const u8 = null;
        while (del_it.next()) |path| {
            if (delete_prefix) |prefix| {
                if (std.mem.startsWith(u8, path, prefix)) {
                    found_to_delete = path;
                    break;
                }
                found_to_delete = null;
                delete_prefix = null;
            }

            var slash_cnt: usize = 0;
            for (path) |c| {
                if (c == '/') slash_cnt += 1;
            }
            if (slash_cnt == 2) {
                if (del_index >= cpu_count) {
                    delete_prefix = path;
                    found_to_delete = path;
                } else {
                    del_index += 1;
                }
            }
        }
        if (found_to_delete) |path| {
            device_tree.deleteNode(path);
        } else break;
    }

    return device_tree.toBlob();
}

/// Builds a minimal AArch64 device tree from scratch describing CPU cores,
/// RAM, PL011 UART, ARM generic timer, PSCI interface, and GICv2 interrupt
/// controller.
pub fn buildAarch64Dtb(
    allocator: std.mem.Allocator,
    ram_base: usize,
    ram_size: usize,
    cpu_count: usize,
    host_bootargs: []const u8,
) !*dt.DeviceTree {
    const arm_dt = try dt.DeviceTree.init(allocator);
    errdefer arm_dt.deinit();

    try arm_dt.editProperty(
        "/",
        "compatible",
        try dt.DeviceTreeProperty.fromText(allocator, "linux,dummy-virt"),
    );
    try arm_dt.editProperty(
        "/",
        "#address-cells",
        try dt.DeviceTreeProperty.fromU32(allocator, 2),
    );
    try arm_dt.editProperty(
        "/",
        "#size-cells",
        try dt.DeviceTreeProperty.fromU32(allocator, 2),
    );
    try arm_dt.editProperty(
        "/",
        "model",
        try dt.DeviceTreeProperty.fromText(allocator, "diosix,virt"),
    );
    try arm_dt.editProperty(
        "/",
        "interrupt-parent",
        try dt.DeviceTreeProperty.fromU32(allocator, 1),
    );

    const base_arm_args =
        "earlycon=pl011,mmio32,0x09000000 console=ttyAMA0 " ++
        "nokaslr norandmaps panic=30 mitigations=off";
    const arm_bootargs = if (host_bootargs.len > 0)
        try std.fmt.allocPrint(
            allocator,
            base_arm_args ++ " {s}",
            .{host_bootargs},
        )
    else
        try std.fmt.allocPrint(allocator, base_arm_args, .{});
    defer allocator.free(arm_bootargs);

    try arm_dt.editProperty(
        "/chosen",
        "bootargs",
        try dt.DeviceTreeProperty.fromText(allocator, arm_bootargs),
    );
    try arm_dt.editProperty(
        "/chosen",
        "stdout-path",
        try dt.DeviceTreeProperty.fromText(allocator, "/pl011@9000000"),
    );

    const mem_node = try std.fmt.allocPrint(
        allocator,
        "/memory@{x}",
        .{ram_base},
    );
    defer allocator.free(mem_node);
    try arm_dt.editProperty(
        mem_node,
        "device_type",
        try dt.DeviceTreeProperty.fromText(allocator, "memory"),
    );
    try arm_dt.editProperty(
        mem_node,
        "reg",
        try dt.DeviceTreeProperty.fromMultiU64(
            allocator,
            &.{ ram_base, ram_size },
        ),
    );

    try arm_dt.editProperty(
        "/cpus",
        "#address-cells",
        try dt.DeviceTreeProperty.fromU32(allocator, 1),
    );
    try arm_dt.editProperty(
        "/cpus",
        "#size-cells",
        try dt.DeviceTreeProperty.fromU32(allocator, 0),
    );

    for (0..cpu_count) |i| {
        const cpu_node = try std.fmt.allocPrint(
            allocator,
            "/cpus/cpu@{}",
            .{i},
        );
        defer allocator.free(cpu_node);
        try arm_dt.editProperty(
            cpu_node,
            "device_type",
            try dt.DeviceTreeProperty.fromText(allocator, "cpu"),
        );
        try arm_dt.editProperty(
            cpu_node,
            "compatible",
            try dt.DeviceTreeProperty.fromText(allocator, "arm,cortex-a53"),
        );
        try arm_dt.editProperty(
            cpu_node,
            "reg",
            try dt.DeviceTreeProperty.fromU32(allocator, @intCast(i)),
        );
        try arm_dt.editProperty(
            cpu_node,
            "enable-method",
            try dt.DeviceTreeProperty.fromText(allocator, "psci"),
        );
    }

    try arm_dt.editProperty(
        "/psci",
        "compatible",
        try dt.DeviceTreeProperty.fromText(allocator, "arm,psci-1.0"),
    );
    try arm_dt.editProperty(
        "/psci",
        "method",
        try dt.DeviceTreeProperty.fromText(allocator, "hvc"),
    );

    try arm_dt.editProperty(
        "/timer",
        "compatible",
        try dt.DeviceTreeProperty.fromText(allocator, "arm,armv8-timer"),
    );
    try arm_dt.editProperty(
        "/timer",
        "interrupts",
        try dt.DeviceTreeProperty.fromMultiU32(allocator, &.{
            1, 13, 0x304,
            1, 14, 0x304,
            1, 11, 0x304,
            1, 10, 0x304,
        }),
    );
    try arm_dt.editProperty(
        "/timer",
        "always-on",
        dt.DeviceTreeProperty.empty,
    );

    try arm_dt.editProperty(
        "/pl011@9000000",
        "compatible",
        try dt.DeviceTreeProperty.fromText(allocator, "arm,pl011"),
    );
    try arm_dt.editProperty(
        "/pl011@9000000",
        "reg",
        try dt.DeviceTreeProperty.fromMultiU64(
            allocator,
            &.{ 0x09000000, 0x1000 },
        ),
    );
    try arm_dt.editProperty(
        "/pl011@9000000",
        "interrupts",
        try dt.DeviceTreeProperty.fromMultiU32(allocator, &.{ 0, 1, 4 }),
    );

    try arm_dt.editProperty(
        "/intc@8000000",
        "compatible",
        try dt.DeviceTreeProperty.fromText(allocator, "arm,cortex-a15-gic"),
    );
    try arm_dt.editProperty(
        "/intc@8000000",
        "#interrupt-cells",
        try dt.DeviceTreeProperty.fromU32(allocator, 3),
    );
    try arm_dt.editProperty(
        "/intc@8000000",
        "interrupt-controller",
        dt.DeviceTreeProperty.empty,
    );
    try arm_dt.editProperty(
        "/intc@8000000",
        "reg",
        try dt.DeviceTreeProperty.fromMultiU64(allocator, &.{
            0x08000000, 0x10000,
            0x08010000, 0x10000,
        }),
    );
    try arm_dt.editProperty(
        "/intc@8000000",
        "phandle",
        try dt.DeviceTreeProperty.fromU32(allocator, 1),
    );
    try arm_dt.editProperty(
        "/intc@8000000",
        "#address-cells",
        try dt.DeviceTreeProperty.fromU32(allocator, 0),
    );

    return arm_dt;
}

test "buildAarch64Dtb creates expected nodes and bootargs" {
    const allocator = std.testing.allocator;
    const tree = try buildAarch64Dtb(
        allocator,
        0x80000000,
        0x10000000,
        2,
        "diosix.mode=live",
    );
    defer tree.deinit();

    const model = try tree.getProperty("/", "model");
    try std.testing.expectEqualStrings("diosix,virt", try model.asText());

    const bootargs = try tree.getProperty("/chosen", "bootargs");
    try std.testing.expect(
        std.mem.indexOf(u8, try bootargs.asText(), "diosix.mode=live") != null,
    );
    try std.testing.expect(tree.nodeExists("/cpus/cpu@0"));
    try std.testing.expect(tree.nodeExists("/cpus/cpu@1"));
}
