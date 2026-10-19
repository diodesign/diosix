// AArch64 Decoder Stub for Diosix Dynamic Recompiler.
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
    return .{ .insn = .{ .unknown = raw_code }, .len = 4 };
}

test "AArch64 stub decoder" {
    const dec = decode(0xd503201f);
    try std.testing.expectEqual(@as(u8, 4), dec.len);
    try std.testing.expectEqual(@as(u32, 0xd503201f), dec.insn.unknown);
    std.testing.refAllDecls(@This());
}
