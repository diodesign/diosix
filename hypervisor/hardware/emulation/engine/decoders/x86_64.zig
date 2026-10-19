// x86_64 Decoder Stub for Diosix Dynamic Recompiler.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const Instruction = union(enum) {
    unknown: u32,
};

pub const DecodedInsn = struct {
    insn: Instruction,
    len: u8,
};

pub fn decode(raw_code: u32) DecodedInsn {
    return .{ .insn = .{ .unknown = raw_code }, .len = 1 };
}

test "x86_64 stub decoder" {
    const dec = decode(0x90);
    try std.testing.expectEqual(@as(u8, 1), dec.len);
    try std.testing.expectEqual(@as(u32, 0x90), dec.insn.unknown);
    std.testing.refAllDecls(@This());
}
