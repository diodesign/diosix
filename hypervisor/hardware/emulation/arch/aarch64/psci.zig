// ARM Power State Coordination Interface (PSCI) Emulation for Diosix
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const vcore = @import("../../../../core/vcore.zig");

pub const PSCI_SUCCESS: i32 = 0;

pub fn handlePSCI(
    vc: *vcore.VirtualCore,
    sub_idx: usize,
    func_id: u32,
    arg0: u64,
    arg1: u64,
    arg2: u64,
) i32 {
    _ = vc;
    _ = sub_idx;
    _ = func_id;
    _ = arg0;
    _ = arg1;
    _ = arg2;
    return PSCI_SUCCESS;
}

test "PSCI handler returns success" {
    const testing = std.testing;
    testing.refAllDecls(@This());

    var vc: vcore.VirtualCore = undefined;
    const res = handlePSCI(&vc, 0, 0x84000000, 0, 0, 0);
    try testing.expectEqual(PSCI_SUCCESS, res);
}
