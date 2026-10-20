// Diosix Constitutional Charter Types & SHA-256 Sealing.
//
// Implements workload-agnostic Charter types (`charter.toml`), SHA-256 Charter
// sealing, and re-exports Steward invariant verification and Whisper Mesh
// consensus primitives from `whisper.zig`.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const interface = @import("interface").sbi;
const whisper = @import("whisper.zig");
const common = @import("common.zig");
const sysconfig = @import("sysconfig.zig");
const toml = @import("charter/toml.zig");

pub const ProposalAction = whisper.ProposalAction;
pub const ProposalCheckResult = whisper.ProposalCheckResult;
pub const verifyProposalAgainstInvariants =
    whisper.verifyProposalAgainstInvariants;
pub const WhisperMessageType = whisper.WhisperMessageType;
pub const WhisperFrame = whisper.WhisperFrame;
pub const formatWhisperFrame = whisper.formatWhisperFrame;
pub const parseWhisperFrame = whisper.parseWhisperFrame;

pub const computeCharterSha256 = toml.computeCharterSha256;
pub const parseCharterToml = toml.parseCharterToml;

pub const DEFAULT_CHARTER_PATH = sysconfig.DEFAULT_CHARTER_CONFIG_PATH;
pub const DEFAULT_CONSTITUTION_PATH = sysconfig.DEFAULT_CONSTITUTION_DOC_PATH;
pub const ACTIVE_CHARTER_STATE_PATH = sysconfig.ACTIVE_CHARTER_STATE_PATH;
pub const CHARTER_AUDIT_LOG_PATH = sysconfig.CHARTER_AUDIT_LOG_PATH;
pub const WHISPER_SPOOL_PATH = sysconfig.WHISPER_SPOOL_PATH;

pub const MAX_CHARTER_UNITS: usize = 16;
pub const MAX_UNIT_ID_LEN: usize = 64;
pub const MAX_ARTIFACT_LEN: usize = 128;
pub const MAX_PUBKEY_LEN: usize = 256;

/// SHA-256 always yields a 32-byte digest, i.e. 64 lowercase hex characters.
pub const SHA256_DIGEST_LEN: usize = std.crypto.hash.sha2.Sha256.digest_length;
pub const SHA256_HEX_LEN: usize = SHA256_DIGEST_LEN * 2;

const setFixedBuf = common.setFixedBuf;

pub const WorkloadUnit = struct {
    id_buf: [MAX_UNIT_ID_LEN]u8 = @splat(0),
    id_len: usize = 0,
    artifact_buf: [MAX_ARTIFACT_LEN]u8 = @splat(0),
    artifact_len: usize = 0,
    min_instances: u16 = 1,
    target_instances: u16 = 1,
    max_instances: u16 = 4,
    vcpus: u16 = 1,
    ram_mb: u32 = 256,
    confidential_memory: bool = false,
    allow_wan_egress: bool = true,
    forbid_volume_export: bool = false,

    pub fn id(self: *const WorkloadUnit) []const u8 {
        return self.id_buf[0..self.id_len];
    }

    pub fn artifact(self: *const WorkloadUnit) []const u8 {
        return self.artifact_buf[0..self.artifact_len];
    }
};

pub const ParsedCharter = struct {
    id_buf: [MAX_UNIT_ID_LEN]u8 = @splat(0),
    id_len: usize = 0,
    version: u32 = 1,
    quorum_required: u16 = 2,
    quorum_total: u16 = 3,
    standby_replicas: u16 = 1,
    principal_pubkey_buf: [MAX_PUBKEY_LEN]u8 = @splat(0),
    principal_pubkey_len: usize = 0,

    // Constitutional invariants.
    min_stewards: u16 = 3,
    max_simultaneous_unit_termination_pct: u8 = 33,
    require_quorum_for_volume_deletion: bool = true,
    volume_deletion_timelock_sec: u32 = 86400,

    // Workload units.
    units: [MAX_CHARTER_UNITS]WorkloadUnit = @splat(.{}),
    unit_count: usize = 0,

    // Computed 256-bit SHA-256 digest of the canonical Charter text.
    sha256_bytes: [SHA256_DIGEST_LEN]u8 = @splat(0),
    sha256_hex: [SHA256_HEX_LEN]u8 = @splat('0'),

    pub fn id(self: *const ParsedCharter) []const u8 {
        if (self.id_len == 0) return "autonomous-mesh-01";
        return self.id_buf[0..self.id_len];
    }

    pub fn principalPubkey(self: *const ParsedCharter) []const u8 {
        return self.principal_pubkey_buf[0..self.principal_pubkey_len];
    }

    pub fn findUnit(
        self: *const ParsedCharter,
        unit_id: []const u8,
    ) ?*const WorkloadUnit {
        for (self.units[0..self.unit_count]) |*u| {
            if (std.mem.eql(u8, u.id(), unit_id)) return u;
        }
        return null;
    }

    pub fn findOrCreateUnit(
        self: *ParsedCharter,
        unit_id: []const u8,
    ) ?*WorkloadUnit {
        for (self.units[0..self.unit_count]) |*u| {
            if (std.mem.eql(u8, u.id(), unit_id)) return u;
        }
        if (self.unit_count >= MAX_CHARTER_UNITS) return null;
        var u = &self.units[self.unit_count];
        u.* = .{};
        setFixedBuf(&u.id_buf, &u.id_len, unit_id);
        self.unit_count += 1;
        return u;
    }

    pub fn toSbiArgs(
        self: *const ParsedCharter,
        is_sealed: bool,
    ) interface.CharterArgs {
        return .{
            .charter_hash = self.sha256_bytes,
            .quorum_required = self.quorum_required,
            .quorum_total = self.quorum_total,
            .standby_replicas = self.standby_replicas,
            .is_sealed = if (is_sealed) 1 else 0,
            .ratified_mask = 0,
            .approved_target_cid = 0,
            .failover_epoch = 0,
        };
    }
};

test "parseCharterToml parses Charter and merges out-of-order unit keys" {
    std.testing.refAllDecls(@This());
    _ = whisper;
    _ = toml;
    _ = @import("charter/cmd.zig");
    _ = @import("charter/status.zig");
    _ = @import("charter/whisper.zig");
    const testing = std.testing;
    const sample =
        \\[charter]
        \\id = "autonomous-mesh-01"
        \\version = 2
        \\quorum = { required = 2, total = 3 }
        \\root_failover = { standby_replicas = 1 }
        \\principal_pubkey = "sk-ssh-ed25519@openssh.com AAAAGnNr"
        \\[invariants]
        \\min_stewards = 3
        \\max_simultaneous_unit_termination_pct = 33
        \\require_quorum_for_volume_deletion = true
        \\volume_deletion_timelock_sec = 86400
        \\[invariants.isolation."unit-alpha"]
        \\confidential_memory = true
        \\allow_wan_egress = false
        \\forbid_volume_export = true
        \\[[units]]
        \\artifact = "workload-a.img"
        \\ram = "1GiB"
        \\id = "unit-alpha"
        \\instances = { min = 2, target = 2, max = 4 }
    ;
    const parsed = try parseCharterToml(sample);
    try testing.expectEqualStrings("autonomous-mesh-01", parsed.id());
    try testing.expectEqual(@as(u32, 2), parsed.version);
    try testing.expectEqual(@as(u16, 2), parsed.quorum_required);
    try testing.expectEqual(@as(u16, 3), parsed.quorum_total);
    try testing.expectEqual(@as(u16, 1), parsed.standby_replicas);
    try testing.expectEqual(@as(u16, 3), parsed.min_stewards);
    const max_pct = parsed.max_simultaneous_unit_termination_pct;
    try testing.expectEqual(@as(u8, 33), max_pct);
    try testing.expect(parsed.require_quorum_for_volume_deletion);
    try testing.expectEqual(@as(usize, 1), parsed.unit_count);
    const u = parsed.findUnit("unit-alpha").?;
    try testing.expectEqualStrings("workload-a.img", u.artifact());
    try testing.expectEqual(@as(u16, 2), u.min_instances);
    try testing.expectEqual(@as(u16, 2), u.target_instances);
    try testing.expectEqual(@as(u16, 4), u.max_instances);
    try testing.expectEqual(@as(u32, 1024), u.ram_mb);
    try testing.expect(u.confidential_memory);
    try testing.expect(!u.allow_wan_egress);
    try testing.expect(u.forbid_volume_export);
}
