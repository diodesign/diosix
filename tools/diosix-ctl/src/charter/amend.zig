// Charter Amendment & Anti-Ransomware Transition Invariant Verifier.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const charter_mod = @import("../charter.zig");
const crypto = @import("crypto.zig");

const ParsedCharter = charter_mod.ParsedCharter;

pub const AmendmentCheckResult = struct {
    allowed: bool,
    reason: []const u8,
};

fn okResult(reason: []const u8) AmendmentCheckResult {
    return .{ .allowed = true, .reason = reason };
}

fn denyResult(reason: []const u8) AmendmentCheckResult {
    return .{ .allowed = false, .reason = reason };
}

/// Deterministically verify that `proposed` is an authorized, invariant-safe
/// successor to `current`, vetoing ransomware attacks even if validly signed
/// by a compromised Principal key.
pub fn verifyCharterAmendment(
    current: *const ParsedCharter,
    proposed: *const ParsedCharter,
) AmendmentCheckResult {
    if (!std.mem.eql(u8, current.id(), proposed.id())) {
        return denyResult("Charter ID mismatch across amendment");
    }
    if (proposed.version <= current.version) {
        return denyResult("Amendment rejects version rollback or replay");
    }

    if (current.decodePrincipalPubkey()) |curr_pk| {
        if (!crypto.verifyCharterSignature(proposed, curr_pk)) {
            return denyResult(
                "Invalid Ed25519 Principal signature over amendment",
            );
        }
    } else if (proposed.hasPrincipalPubkey()) {
        if (!crypto.verifyCharterSignature(proposed, null)) {
            return denyResult("Invalid self-signed Principal signature");
        }
    }

    if (proposed.wipe_volumes) {
        return denyResult(
            "Ransomware guard: wipe_volumes prohibited in Mission update",
        );
    }
    if (current.forbid_unratified_encryption and proposed.encrypt_volumes) {
        return denyResult(
            "Ransomware guard: encrypt_volumes violates Charter invariants",
        );
    }

    if (current.require_quorum_for_volume_deletion and
        !proposed.require_quorum_for_volume_deletion)
    {
        return denyResult(
            "Cannot weaken [invariants] require_quorum_for_volume_deletion",
        );
    }
    if (current.volume_deletion_timelock_sec > 0 and
        proposed.volume_deletion_timelock_sec == 0)
    {
        return denyResult(
            "Cannot disable [invariants] volume_deletion_timelock_sec",
        );
    }
    if (current.forbid_zero_replicas and !proposed.forbid_zero_replicas) {
        return denyResult("Cannot disable [invariants] forbid_zero_replicas");
    }
    if (current.forbid_unratified_encryption and
        !proposed.forbid_unratified_encryption)
    {
        return denyResult(
            "Cannot disable [invariants] forbid_unratified_encryption",
        );
    }

    for (current.units[0..current.unit_count]) |*u| {
        const pu_opt = proposed.findUnit(u.id());
        if (u.min_instances > 0) {
            if (pu_opt == null or pu_opt.?.min_instances == 0) {
                if (current.forbid_zero_replicas) {
                    return denyResult(
                        "Availability guard: cannot drop unit replicas to zero",
                    );
                }
            }
            if (pu_opt) |pu| {
                if (pu.min_instances < u.min_instances) {
                    const lost: u64 = u.min_instances - pu.min_instances;
                    const drop_pct = (lost * 100) / @as(u64, u.min_instances);
                    if (drop_pct >
                        current.max_simultaneous_unit_termination_pct)
                    {
                        return denyResult(
                            "Violates max_simultaneous_unit_termination_pct",
                        );
                    }
                }
            }
        }
        if (u.forbid_volume_export) {
            if (pu_opt == null or !pu_opt.?.forbid_volume_export) {
                return denyResult(
                    "Violates [invariants.isolation] forbid_volume_export",
                );
            }
        }
    }

    return okResult("Signature and all Constitutional invariants satisfied");
}

test "charter/amend: vetoes ransomware replica drop+encrypt, allows scale" {
    std.testing.refAllDecls(@This());
    const t = std.testing;
    const common = @import("../common.zig");
    const seed: [crypto.PRIV_SEED_BYTES]u8 = @splat(0x44);
    var seed_hex: [crypto.PRIV_SEED_HEX_LEN]u8 = undefined;
    _ = common.bytesToHex(&seed, &seed_hex);

    const v1_raw =
        \\[charter]
        \\id = "dist-db"
        \\version = 1
        \\[invariants]
        \\max_simultaneous_unit_termination_pct = 34
        \\forbid_zero_replicas = true
        \\forbid_unratified_encryption = true
        \\[invariants.isolation."db"]
        \\forbid_volume_export = true
        \\[[units]]
        \\id = "db"
        \\instances = { min = 3, target = 3, max = 6 }
    ;
    const v1_s = try crypto.signCharterContent(
        t.allocator,
        v1_raw,
        &seed_hex,
        null,
    );
    defer t.allocator.free(v1_s);
    const v1 = try charter_mod.parseCharterToml(v1_s);

    // 1. Compromised owner ransomware attack (3 -> 0 + encrypt_volumes = true).
    const ransom_raw =
        \\[charter]
        \\id = "dist-db"
        \\version = 2
        \\[spec]
        \\encrypt_volumes = true
        \\[invariants]
        \\max_simultaneous_unit_termination_pct = 34
        \\forbid_zero_replicas = true
        \\forbid_unratified_encryption = true
        \\[invariants.isolation."db"]
        \\forbid_volume_export = true
        \\[[units]]
        \\id = "db"
        \\instances = { min = 0, target = 0, max = 6 }
    ;
    const ransom_s = try crypto.signCharterContent(
        t.allocator,
        ransom_raw,
        &seed_hex,
        null,
    );
    defer t.allocator.free(ransom_s);
    const ransom = try charter_mod.parseCharterToml(ransom_s);
    try t.expect(!verifyCharterAmendment(&v1, &ransom).allowed);

    // 2. Excess step-down (3 -> 1 = 66% > 34%).
    const step_bad_raw =
        \\[charter]
        \\id = "dist-db"
        \\version = 2
        \\[invariants]
        \\max_simultaneous_unit_termination_pct = 34
        \\forbid_zero_replicas = true
        \\forbid_unratified_encryption = true
        \\[invariants.isolation."db"]
        \\forbid_volume_export = true
        \\[[units]]
        \\id = "db"
        \\instances = { min = 1, target = 1, max = 6 }
    ;
    const sb_s = try crypto.signCharterContent(
        t.allocator,
        step_bad_raw,
        &seed_hex,
        null,
    );
    defer t.allocator.free(sb_s);
    const sb = try charter_mod.parseCharterToml(sb_s);
    try t.expect(!verifyCharterAmendment(&v1, &sb).allowed);

    // 3. Safe scale-up (3 -> 4) passes both signature and invariant checks.
    const good_raw =
        \\[charter]
        \\id = "dist-db"
        \\version = 2
        \\[invariants]
        \\max_simultaneous_unit_termination_pct = 34
        \\forbid_zero_replicas = true
        \\forbid_unratified_encryption = true
        \\[invariants.isolation."db"]
        \\forbid_volume_export = true
        \\[[units]]
        \\id = "db"
        \\instances = { min = 4, target = 4, max = 6 }
    ;
    const good_s = try crypto.signCharterContent(
        t.allocator,
        good_raw,
        &seed_hex,
        null,
    );
    defer t.allocator.free(good_s);
    const good = try charter_mod.parseCharterToml(good_s);
    try t.expect(verifyCharterAmendment(&v1, &good).allowed);
}
