// diosix hypervisor initialization
//
// Copyright (c) 2024 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

export fn main(cpu_core_id: usize, _: usize) noreturn {
    if (cpu_core_id == 0) {
        const uart: *volatile u8 = @ptrFromInt(0x10000000);
        const hello: []const u8 = "Hello world from CPU core 0!!\n\n";

        for (hello) |c| {
            uart.* = c;
        }
    }

    while (true) {}
}

export fn xint_handler() noreturn {
    const uart: *volatile u8 = @ptrFromInt(0x10000000);
    const hello: []const u8 = "Unexpected xint!\n\n";

    for (hello) |c| {
        uart.* = c;
    }

    while (true) {}
}
