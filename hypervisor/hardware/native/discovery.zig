// Dynamic Hardware Probing and Discovery Layer
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fdt = @import("fdt.zig");
const uart = @import("drivers/uart.zig");
const clint = @import("drivers/clint.zig");
const plic = @import("drivers/plic.zig");

pub const HostHardware = struct {
    ram_base: u64,
    ram_size: u64,
    uart_base: ?usize,
    clint_base: ?usize,
    plic_base: ?usize,
};

pub fn probe(fdt_paddr: usize) HostHardware {
    if (fdt_paddr == 0) {
        return HostHardware{
            .ram_base = 0x80000000,
            .ram_size = 512 * 1024 * 1024,
            .uart_base = 0x10000000,
            .clint_base = 0x02000000,
            .plic_base = 0x0c000000,
        };
    }

    const dtb_ptr = @as([*]const u8, @ptrFromInt(fdt_paddr));
    const info = fdt.parseHardwareInfo(dtb_ptr) catch {
        return HostHardware{
            .ram_base = 0x80000000,
            .ram_size = 512 * 1024 * 1024,
            .uart_base = 0x10000000,
            .clint_base = 0x02000000,
            .plic_base = 0x0c000000,
        };
    };

    if (info.uart_base) |u| uart.init(u);
    if (info.clint_base) |c| clint.init(c);
    if (info.plic_base) |p| plic.init(p);

    return HostHardware{
        .ram_base = info.ram_base,
        .ram_size = info.ram_size,
        .uart_base = info.uart_base,
        .clint_base = info.clint_base,
        .plic_base = info.plic_base,
    };
}
