// Guest Flattened Device Tree (DTB) builder for AArch64 Root VMs.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const dt = @import("../../dt.zig");
const dtb = @import("../dtb.zig");

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
        try allocator.print(
            base_arm_args ++ " {s}",
            .{host_bootargs},
        )
    else
        try allocator.dupe(u8, base_arm_args);
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

    const mem_node = try allocator.print(
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
        const cpu_node = try allocator.print(
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
    const irq_fl = dtb.AARCH64_TIMER_IRQ_FLAGS;
    try arm_dt.editProperty(
        "/timer",
        "interrupts",
        try dt.DeviceTreeProperty.fromMultiU32(allocator, &.{
            1, 13, irq_fl,
            1, 14, irq_fl,
            1, 11, irq_fl,
            1, 10, irq_fl,
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
            &.{ dtb.AARCH64_PL011_BASE, dtb.AARCH64_PL011_SIZE },
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
            dtb.AARCH64_GICD_BASE, dtb.AARCH64_GICD_SIZE,
            dtb.AARCH64_GICC_BASE, dtb.AARCH64_GICC_SIZE,
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
    std.testing.refAllDecls(@This());
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
