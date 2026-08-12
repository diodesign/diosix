// ARM Power State Coordination Interface (PSCI) Emulation for Diosix
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const vcore = @import("../../../../core/vcore.zig");

pub fn handlePSCI(vc: *vcore.VirtualCore, sub_idx: usize, func_id: u32, arg0: u64, arg1: u64, arg2: u64) i32 {
    _ = vc;
    _ = sub_idx;
    _ = func_id;
    _ = arg0;
    _ = arg1;
    _ = arg2;
    return 0; // PSCI SUCCESS
}
