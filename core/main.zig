// diosix hypervisor initialization
//
// Copyright (c) 2024 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

export fn main() void {
    const uart: *volatile u8 = @ptrFromInt(0x10000000);
    const hello: []const u8 = "Hello world!!\n\n";

    for (hello) |c| {
        uart.* = c;
    }

    while (true) {}
}
