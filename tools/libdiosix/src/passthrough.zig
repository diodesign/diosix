// Diosix Passthrough (MMIO, DMA RAM Query, & IRQ Delegation) IOCTL Helpers.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("lib.zig");

pub const ChildRamRange = struct {
    gpa_base: u64,
    hpa_base: u64,
    size: usize,
};

pub fn mapChildMmio(
    client: *api.DiosixClient,
    target_cid: usize,
    host_pa: u64,
    child_gpa: u64,
    size: usize,
    flags: u64,
) !void {
    const fd = try client.getFd();
    var args = api.MapChildMmioArgs{
        .child_id = target_cid,
        .host_pa = host_pa,
        .child_gpa = child_gpa,
        .size = size,
        .flags = flags,
    };
    _ = try api.checkIoctlRc(
        linux.ioctl(fd, api.IOCTL_MAP_CHILD_MMIO, @intFromPtr(&args)),
    );
}

pub fn queryChildRam(
    client: *api.DiosixClient,
    target_cid: usize,
) !ChildRamRange {
    const fd = try client.getFd();
    var args = api.MapChildMmioArgs{
        .child_id = target_cid,
        .flags = api.MmioPassFlags.QUERY_RAM,
    };
    _ = try api.checkIoctlRc(
        linux.ioctl(fd, api.IOCTL_MAP_CHILD_MMIO, @intFromPtr(&args)),
    );
    return .{
        .gpa_base = args.child_gpa,
        .hpa_base = args.host_pa,
        .size = @intCast(args.size),
    };
}

pub fn delegateChildIrq(
    client: *api.DiosixClient,
    target_cid: usize,
    phys_irq: u32,
    virt_irq: u32,
    flags: u64,
) !u32 {
    const fd = try client.getFd();
    var args = api.DelegateChildIrqArgs{
        .child_id = target_cid,
        .phys_irq = phys_irq,
        .virt_irq = virt_irq,
        .flags = flags,
    };
    _ = try api.checkIoctlRc(
        linux.ioctl(fd, api.IOCTL_DELEGATE_CHILD_IRQ, @intFromPtr(&args)),
    );
    return args.virt_irq;
}

test "api/passthrough: ioctl constants and ABI struct sizes" {
    try std.testing.expectEqual(@as(u32, 0x1021), api.IOCTL_MAP_CHILD_MMIO);
    try std.testing.expectEqual(
        @as(u32, 0x1022),
        api.IOCTL_DELEGATE_CHILD_IRQ,
    );
    try std.testing.expectEqual(@as(u64, 1 << 7), api.RunFlags.DMA_TRUSTED);
    try std.testing.expectEqual(
        @as(usize, 40),
        @sizeOf(api.MapChildMmioArgs),
    );
    try std.testing.expectEqual(
        @as(usize, 24),
        @sizeOf(api.DelegateChildIrqArgs),
    );
}
