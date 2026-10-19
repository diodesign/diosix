// Diosix shared interface library.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const riscv = @import("riscv.zig");
pub const sbi = @import("sbi.zig");
pub const elf = @import("elf.zig");

test {
    _ = riscv;
    _ = sbi;
    _ = elf;
    std.testing.refAllDecls(@This());
}
