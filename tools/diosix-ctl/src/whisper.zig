// Steward Invariant Verifier & Whisper Mesh Consensus Framing.
//
// Implements deterministic constitutional invariant verification and Whisper
// BFT consensus framing for the Steward Collective.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const charter_mod = @import("charter.zig");
const charter_whisper = @import("charter/whisper.zig");
const ParsedCharter = charter_mod.ParsedCharter;

pub const WhisperMessageType = charter_whisper.WhisperMessageType;
pub const WhisperFrame = charter_whisper.WhisperFrame;
pub const formatWhisperFrame = charter_whisper.formatWhisperFrame;
pub const parseWhisperFrame = charter_whisper.parseWhisperFrame;
pub const cmdCharterWhisper = charter_whisper.cmdCharterWhisper;

pub const ProposalAction = enum {
    amend_charter,
    terminate_steward,
    reset_steward,
    root_failover,
    terminate_units,
    delete_volume,
    export_volume,
    enable_wan_egress,
};

pub const ProposalCheckResult = struct {
    allowed: bool,
    requires_quorum: bool,
    reason: []const u8,
};

/// Deterministically evaluate a proposed operational or governance action
/// against the sealed Constitutional Charter's `[invariants]`.
pub fn verifyProposalAgainstInvariants(
    charter: *const ParsedCharter,
    action: ProposalAction,
    target_unit_id: []const u8,
    affected_count: u32,
    total_active_count: u32,
    has_quorum: bool,
) ProposalCheckResult {
    switch (action) {
        .amend_charter, .reset_steward, .root_failover => {
            if (!has_quorum) {
                return .{
                    .allowed = false,
                    .requires_quorum = true,
                    .reason = "Action requires M-of-N Steward quorum " ++
                        "ratification",
                };
            }
            return .{
                .allowed = true,
                .requires_quorum = true,
                .reason = "Ratified by M-of-N Steward quorum",
            };
        },
        .terminate_steward => {
            if (total_active_count <= charter.min_stewards) {
                return .{
                    .allowed = false,
                    .requires_quorum = true,
                    .reason = "Violates [invariants] min_stewards floor",
                };
            }
            if (!has_quorum) {
                return .{
                    .allowed = false,
                    .requires_quorum = true,
                    .reason = "Terminating a Steward VM requires M-of-N " ++
                        "Steward quorum",
                };
            }
            return .{
                .allowed = true,
                .requires_quorum = true,
                .reason = "Steward termination satisfies min_stewards " ++
                    "and quorum",
            };
        },
        .terminate_units => {
            if (total_active_count > 0) {
                const pct = (@as(u64, affected_count) * 100) /
                    @as(u64, total_active_count);
                if (pct > charter.max_simultaneous_unit_termination_pct) {
                    return .{
                        .allowed = false,
                        .requires_quorum = true,
                        .reason = "Violates [invariants] " ++
                            "max_simultaneous_unit_termination_pct ceiling",
                    };
                }
            }
            return .{
                .allowed = true,
                .requires_quorum = false,
                .reason = "Unit termination within " ++
                    "max_simultaneous_unit_termination_pct bound",
            };
        },
        .delete_volume => {
            if (charter.require_quorum_for_volume_deletion and !has_quorum) {
                return .{
                    .allowed = false,
                    .requires_quorum = true,
                    .reason = "Violates [invariants] " ++
                        "require_quorum_for_volume_deletion",
                };
            }
            return .{
                .allowed = true,
                .requires_quorum = charter.require_quorum_for_volume_deletion,
                .reason = "Volume deletion permitted under Charter policy",
            };
        },
        .export_volume => {
            if (charter.findUnit(target_unit_id)) |u| {
                if (u.forbid_volume_export) {
                    return .{
                        .allowed = false,
                        .requires_quorum = true,
                        .reason = "Violates [invariants.isolation] " ++
                            "forbid_volume_export = true",
                    };
                }
            }
            return .{
                .allowed = true,
                .requires_quorum = false,
                .reason = "Volume export permitted for unit",
            };
        },
        .enable_wan_egress => {
            if (charter.findUnit(target_unit_id)) |u| {
                if (!u.allow_wan_egress) {
                    return .{
                        .allowed = false,
                        .requires_quorum = true,
                        .reason = "Violates [invariants.isolation] " ++
                            "allow_wan_egress = false",
                    };
                }
            }
            return .{
                .allowed = true,
                .requires_quorum = false,
                .reason = "WAN egress permitted for unit",
            };
        },
    }
}

test "verifyProposalAgainstInvariants enforces Constitutional invariants" {
    std.testing.refAllDecls(@This());
    _ = charter_whisper;
    const testing = std.testing;

    const sample =
        \\[charter]
        \\id = "test-charter"
        \\quorum_required = 2
        \\quorum_total = 3
        \\
        \\[invariants]
        \\min_stewards = 3
        \\max_simultaneous_unit_termination_pct = 33
        \\require_quorum_for_volume_deletion = true
        \\
        \\[invariants.isolation."unit-alpha"]
        \\confidential_memory = true
        \\allow_wan_egress = false
        \\forbid_volume_export = true
    ;
    const charter = try charter_mod.parseCharterToml(sample);

    // 1. Reject terminating > 33% of active units at once (2 of 4 = 50%).
    const r1 = verifyProposalAgainstInvariants(
        &charter,
        .terminate_units,
        "unit-alpha",
        2,
        4,
        true,
    );
    try testing.expect(!r1.allowed);

    // 2. Allow terminating <= 33% of active units (1 of 4 = 25%).
    const r2 = verifyProposalAgainstInvariants(
        &charter,
        .terminate_units,
        "unit-alpha",
        1,
        4,
        false,
    );
    try testing.expect(r2.allowed);

    // 3. Reject terminating a Steward when active count == min_stewards (3).
    const r3 = verifyProposalAgainstInvariants(
        &charter,
        .terminate_steward,
        "",
        1,
        3,
        true,
    );
    try testing.expect(!r3.allowed);

    // 4. Reject volume export when forbid_volume_export == true.
    const r4 = verifyProposalAgainstInvariants(
        &charter,
        .export_volume,
        "unit-alpha",
        1,
        1,
        true,
    );
    try testing.expect(!r4.allowed);

    // 5. Reject WAN egress when allow_wan_egress == false.
    const r5 = verifyProposalAgainstInvariants(
        &charter,
        .enable_wan_egress,
        "unit-alpha",
        1,
        1,
        true,
    );
    try testing.expect(!r5.allowed);

    // 6. Reject volume deletion without M-of-N Steward quorum.
    const r6 = verifyProposalAgainstInvariants(
        &charter,
        .delete_volume,
        "unit-alpha",
        1,
        1,
        false,
    );
    try testing.expect(!r6.allowed);
    const r7 = verifyProposalAgainstInvariants(
        &charter,
        .delete_volume,
        "unit-alpha",
        1,
        1,
        true,
    );
    try testing.expect(r7.allowed);
}
