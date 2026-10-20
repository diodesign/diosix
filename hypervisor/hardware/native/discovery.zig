// Dynamic Hardware Probing and Discovery Layer.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fdt = @import("fdt.zig");
const uart = @import("drivers/uart.zig");
const clint = @import("drivers/clint.zig");
const plic = @import("drivers/plic.zig");
const riscv = @import("cpu/riscv64/mod.zig");

pub const HostHardware = struct {
    ram_base: u64,
    ram_size: u64,
    uart_base: ?usize,
    clint_base: ?usize,
    plic_base: ?usize,
};

pub const DEFAULT_RAM_BASE: u64 = fdt.DEFAULT_RAM_BASE;
pub const DEFAULT_RAM_SIZE: u64 = fdt.DEFAULT_RAM_SIZE;
pub const DEFAULT_UART_BASE: usize = fdt.DEFAULT_UART_BASE;
pub const DEFAULT_CLINT_BASE: usize = fdt.DEFAULT_CLINT_BASE;
pub const DEFAULT_PLIC_BASE: usize = fdt.DEFAULT_PLIC_BASE;

pub const DEFAULT_HOST_HARDWARE = HostHardware{
    .ram_base = DEFAULT_RAM_BASE,
    .ram_size = DEFAULT_RAM_SIZE,
    .uart_base = DEFAULT_UART_BASE,
    .clint_base = DEFAULT_CLINT_BASE,
    .plic_base = DEFAULT_PLIC_BASE,
};

pub fn probe(fdt_paddr: usize) HostHardware {
    const hw = blk: {
        if (fdt_paddr == 0) {
            break :blk DEFAULT_HOST_HARDWARE;
        }

        const dtb_ptr = @as([*]const u8, @ptrFromInt(fdt_paddr));
        const info = fdt.parseHardwareInfo(dtb_ptr) catch {
            break :blk DEFAULT_HOST_HARDWARE;
        };

        break :blk HostHardware{
            .ram_base = info.ram_base,
            .ram_size = info.ram_size,
            .uart_base = info.uart_base,
            .clint_base = info.clint_base,
            .plic_base = info.plic_base,
        };
    };

    if (hw.uart_base) |u| uart.init(u);
    if (hw.clint_base) |c| clint.init(c);
    if (hw.plic_base) |p| plic.init(p);

    riscv.uart_base = hw.uart_base;
    riscv.clint_base = hw.clint_base;
    riscv.plic_base = hw.plic_base;
    return hw;
}

test "discovery probe fallback on null FDT address" {
    std.testing.refAllDecls(@This());
    _ = fdt;
    _ = uart;
    _ = clint;
    _ = plic;
    defer {
        riscv.uart_base = null;
        riscv.clint_base = null;
        riscv.plic_base = null;
        uart.base_address = null;
        clint.base_address = null;
        plic.base_address = null;
    }
    const hw = probe(0);
    try std.testing.expectEqual(DEFAULT_RAM_BASE, hw.ram_base);
    try std.testing.expectEqual(DEFAULT_RAM_SIZE, hw.ram_size);
    try std.testing.expectEqual(@as(?usize, DEFAULT_UART_BASE), hw.uart_base);
    try std.testing.expectEqual(@as(?usize, DEFAULT_CLINT_BASE), hw.clint_base);
    try std.testing.expectEqual(@as(?usize, DEFAULT_PLIC_BASE), hw.plic_base);
    try std.testing.expectEqual(
        @as(?usize, DEFAULT_UART_BASE),
        uart.base_address,
    );
    try std.testing.expectEqual(
        @as(?usize, DEFAULT_CLINT_BASE),
        clint.base_address,
    );
    try std.testing.expectEqual(
        @as(?usize, DEFAULT_PLIC_BASE),
        plic.base_address,
    );
}
