// diosix hypervisor initialization
//
// Copyright (c) 2024 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const xint = @import("xint.zig");
const debug = @import("debug.zig");

pub export fn main(cpu_core_id: usize, _: usize) noreturn {
    xint.init();
    debug.printf("hypervisor: CPU core ID {} initialized\n", .{cpu_core_id});

    while (true) {}
}
