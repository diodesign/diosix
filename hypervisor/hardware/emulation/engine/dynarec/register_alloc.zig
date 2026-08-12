// Static 1-to-1 Register Pinning Rules for Diosix Dynamic Recompiler
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

/// Static 1-to-1 Register Mapping Rules (RV32 Guest GPR -> RV64 Host GPR)
pub fn mapGuestGprToHost(guest_reg: u5) u5 {
    return guest_reg; // 1-to-1 direct mapping x0-x31
}
