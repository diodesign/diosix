// Shared SBI Device Passthrough (MMIO, DMA-Trust, & IRQ Delegation) ABI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const MAX_CHILD_MMIO_SIZE_BYTES: u64 = 256 * 1024 * 1024;
pub const MAX_DELEGATED_IRQS: usize = 64;

pub const MmioPassFlags = struct {
    pub const READ_ONLY: u64 = 1 << 0;
    pub const DMA_TRUSTED: u64 = 1 << 1;
    pub const QUERY_RAM: u64 = 1 << 2;
    pub const VALID_MASK: u64 = READ_ONLY | DMA_TRUSTED | QUERY_RAM;
};

pub const MapChildMmioArgs = extern struct {
    child_id: u64,
    host_pa: u64 = 0,
    child_gpa: u64 = 0,
    size: u64 = 0,
    flags: u64 = 0,
};

pub const IrqPassFlags = struct {
    pub const RELEASE: u64 = 1 << 0;
    pub const VALID_MASK: u64 = RELEASE;
};

pub const DelegateChildIrqArgs = extern struct {
    child_id: u64,
    phys_irq: u32,
    virt_irq: u32 = 0,
    flags: u64 = 0,
};

comptime {
    std.debug.assert(@sizeOf(MapChildMmioArgs) == 40);
    std.debug.assert(@sizeOf(DelegateChildIrqArgs) == 24);
}

test "SBI passthrough ABI layout and flag constants" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(MapChildMmioArgs));
    try std.testing.expectEqual(
        @as(usize, 24),
        @sizeOf(DelegateChildIrqArgs),
    );
    try std.testing.expectEqual(@as(u64, 1 << 0), MmioPassFlags.READ_ONLY);
    try std.testing.expectEqual(@as(u64, 1 << 1), MmioPassFlags.DMA_TRUSTED);
    try std.testing.expectEqual(@as(u64, 1 << 2), MmioPassFlags.QUERY_RAM);
    try std.testing.expectEqual(@as(u64, 1 << 0), IrqPassFlags.RELEASE);
}
