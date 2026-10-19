// Diosix Hypervisor Guest Management CLI — Governance Dispatch Module.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const auth_cmd = @import("auth.zig");
const charter_cmd = @import("charter/cmd.zig");
const manifest_cmd = @import("manifest/cmd.zig");

pub const cmdAuth = auth_cmd.cmdAuth;
pub const parseProposalAction = charter_cmd.parseProposalAction;
pub const cmdCharter = charter_cmd.cmdCharter;
pub const cmdManifest = manifest_cmd.cmdManifest;
pub const cmdResolve = manifest_cmd.cmdResolve;

test "governance: re-exports auth, charter, and manifest CLI handlers" {
    std.testing.refAllDecls(@This());
    _ = auth_cmd;
    _ = charter_cmd;
    _ = manifest_cmd;
}
