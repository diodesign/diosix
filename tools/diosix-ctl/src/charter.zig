// Diosix Constitutional Charter Types, Signing & SHA-256 Sealing.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const interface = @import("interface").sbi;
const passkey = @import("passkey.zig");
const whisper = @import("whisper.zig");
const common = @import("common.zig");
const sysconfig = @import("sysconfig.zig");
const toml = @import("charter/toml.zig");
const crypto = @import("charter/crypto.zig");
const amend = @import("charter/amend.zig");
const ops = @import("charter/ops.zig");
const sign = @import("charter/sign.zig");

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
pub const generatePrincipalKeypair = crypto.generatePrincipalKeypair;
pub const signCharterContent = crypto.signCharterContent;
pub const verifyCharterSignature = crypto.verifyCharterSignature;
pub const AmendmentCheckResult = amend.AmendmentCheckResult;
pub const verifyCharterAmendment = amend.verifyCharterAmendment;

pub const DEFAULT_CHARTER_PATH = sysconfig.DEFAULT_CHARTER_CONFIG_PATH;
pub const DEFAULT_CONSTITUTION_PATH = sysconfig.DEFAULT_CONSTITUTION_DOC_PATH;
pub const ACTIVE_CHARTER_STATE_PATH = sysconfig.ACTIVE_CHARTER_STATE_PATH;
pub const CHARTER_AUDIT_LOG_PATH = sysconfig.CHARTER_AUDIT_LOG_PATH;
pub const WHISPER_SPOOL_PATH = sysconfig.WHISPER_SPOOL_PATH;

pub const MAX_CHARTER_UNITS: usize = 16;
pub const MAX_UNIT_ID_LEN: usize = 64;
pub const MAX_ARTIFACT_LEN: usize = 128;
pub const MAX_PUBKEY_LEN: usize = 256;
pub const MAX_GOAL_LEN: usize = 128;
pub const MAX_SIG_HEX_LEN: usize = 128;

/// SHA-256 always yields a 32-byte digest, i.e. 64 lowercase hex characters.
pub const SHA256_DIGEST_LEN: usize = std.crypto.hash.sha2.Sha256.digest_length;
pub const SHA256_HEX_LEN: usize = SHA256_DIGEST_LEN * 2;

const setFixedBuf = common.setFixedBuf;

pub const SpecMode = enum {
    swarm,
    service,
    desktop,
};

pub const WorkloadUnit = struct {
    id_buf: [MAX_UNIT_ID_LEN]u8 = @splat(0),
    id_len: usize = 0,
    artifact_buf: [MAX_ARTIFACT_LEN]u8 = @splat(0),
    artifact_len: usize = 0,
    packages_buf: [MAX_ARTIFACT_LEN]u8 = @splat(0),
    packages_len: usize = 0,
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

    pub fn packages(self: *const WorkloadUnit) []const u8 {
        if (self.packages_len == 0) return "none";
        return self.packages_buf[0..self.packages_len];
    }
};

pub const ParsedCharter = struct {
    id_buf: [MAX_UNIT_ID_LEN]u8 = @splat(0),
    id_len: usize = 0,
    version: u32 = 1,
    quorum_required: u16 = 2,
    quorum_total: u16 = 3,
    stake_quorum_pct: u8 = 67,
    standby_replicas: u16 = 1,
    principal_pubkey_buf: [MAX_PUBKEY_LEN]u8 = @splat(0),
    principal_pubkey_len: usize = 0,
    signature_buf: [MAX_SIG_HEX_LEN]u8 = @splat(0),
    signature_len: usize = 0,

    // Declarative specification ([spec]).
    goal_buf: [MAX_GOAL_LEN]u8 = @splat(0),
    goal_len: usize = 0,
    mode: SpecMode = .swarm,
    fleet_hosts: u16 = 1,
    encrypt_volumes: bool = false,
    wipe_volumes: bool = false,

    // Constitutional invariants ([invariants]).
    min_stewards: u16 = 3,
    max_simultaneous_unit_termination_pct: u8 = 33,
    require_quorum_for_volume_deletion: bool = true,
    volume_deletion_timelock_sec: u32 = 86400,
    forbid_zero_replicas: bool = true,
    forbid_unratified_encryption: bool = true,

    // Workload units ([[units]]).
    units: [MAX_CHARTER_UNITS]WorkloadUnit = @splat(.{}),
    unit_count: usize = 0,

    // Computed 256-bit SHA-256 digest of the unsigned canonical Charter text.
    sha256_bytes: [SHA256_DIGEST_LEN]u8 = @splat(0),
    sha256_hex: [SHA256_HEX_LEN]u8 = @splat('0'),

    pub fn id(self: *const ParsedCharter) []const u8 {
        if (self.id_len == 0) return "autonomous-mesh-01";
        return self.id_buf[0..self.id_len];
    }

    pub fn goal(self: *const ParsedCharter) []const u8 {
        return self.goal_buf[0..self.goal_len];
    }

    pub fn principalPubkeyRaw(self: *const ParsedCharter) []const u8 {
        return self.principal_pubkey_buf[0..self.principal_pubkey_len];
    }

    pub fn signatureHex(self: *const ParsedCharter) []const u8 {
        return self.signature_buf[0..self.signature_len];
    }

    pub fn hasPrincipalPubkey(self: *const ParsedCharter) bool {
        return self.decodePrincipalPubkey() != null;
    }

    pub fn decodePrincipalPubkey(
        self: *const ParsedCharter,
    ) ?[interface.MISSION_PUBKEY_LEN]u8 {
        const raw = common.trimWhitespace(self.principalPubkeyRaw());
        if (raw.len == interface.MISSION_PUBKEY_LEN * 2) {
            var pk: [interface.MISSION_PUBKEY_LEN]u8 = undefined;
            if (passkey.hexToBytes(raw, &pk)) |dec| {
                if (dec.len == interface.MISSION_PUBKEY_LEN) return pk;
            }
        }
        if (raw.len > 0) {
            if (passkey.parsePasskeyLine(raw)) |entry| {
                return entry.ed25519_pubkey;
            }
        }
        return null;
    }

    pub fn decodeSignature(
        self: *const ParsedCharter,
    ) ?[interface.MISSION_SIG_LEN]u8 {
        const raw = common.trimWhitespace(self.signatureHex());
        if (raw.len != interface.MISSION_SIG_LEN * 2) return null;
        var sig: [interface.MISSION_SIG_LEN]u8 = undefined;
        const dec = passkey.hexToBytes(raw, &sig) orelse return null;
        if (dec.len != interface.MISSION_SIG_LEN) return null;
        return sig;
    }

    pub fn totalMinReplicas(self: *const ParsedCharter) u32 {
        var total: u32 = 0;
        for (self.units[0..self.unit_count]) |*u| {
            total +|= u.min_instances;
        }
        return total;
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

    pub fn toMissionArgs(
        self: *const ParsedCharter,
        is_sealed: bool,
    ) !interface.MissionArgs {
        const pk = self.decodePrincipalPubkey() orelse
            return error.MissingPrincipalPubkey;
        const sig = self.decodeSignature() orelse
            @as([interface.MISSION_SIG_LEN]u8, @splat(0));
        var flags: u32 = 0;
        if (self.forbid_zero_replicas or
            self.max_simultaneous_unit_termination_pct < 100)
        {
            flags |= interface.MissionFlags.PROTECT_REPLICAS;
        }
        if (self.forbid_unratified_encryption) {
            flags |= interface.MissionFlags.FORBID_UNRATIFIED_ENCRYPT;
        }
        if (self.encrypt_volumes) {
            flags |= interface.MissionFlags.DESTRUCTIVE_ENCRYPT;
        }
        if (self.wipe_volumes) {
            flags |= interface.MissionFlags.DESTRUCTIVE_WIPE;
        }
        return .{
            .charter_hash = self.sha256_bytes,
            .principal_pubkey = pk,
            .signature = sig,
            .version = self.version,
            .min_total_replicas = self.totalMinReplicas(),
            .flags = flags,
            .stake_quorum_pct = self.stake_quorum_pct,
            .max_stepdown_pct = self.max_simultaneous_unit_termination_pct,
            .is_sealed = if (is_sealed) 1 else 0,
            .has_pubkey = 1,
        };
    }
};

test "parseCharterToml parses Charter, spec, and unit packages" {
    std.testing.refAllDecls(@This());
    _ = whisper;
    _ = toml;
    _ = crypto;
    _ = amend;
    _ = ops;
    _ = sign;
    _ = @import("charter/cmd.zig");
    _ = @import("charter/status.zig");
    _ = @import("charter/whisper.zig");
    const testing = std.testing;
    const sample =
        \\[charter]
        \\id = "autonomous-mesh-01"
        \\version = 2
        \\stake_quorum_pct = 67
        \\quorum = { required = 2, total = 3 }
        \\root_failover = { standby_replicas = 1 }
        \\[spec]
        \\goal = "Maintain 3-way distributed DB"
        \\mode = "swarm"
        \\fleet_hosts = 2
        \\encrypt_volumes = false
        \\[invariants]
        \\min_stewards = 3
        \\max_simultaneous_unit_termination_pct = 33
        \\require_quorum_for_volume_deletion = true
        \\volume_deletion_timelock_sec = 86400
        \\forbid_zero_replicas = true
        \\forbid_unratified_encryption = true
        \\[invariants.isolation."unit-alpha"]
        \\confidential_memory = true
        \\allow_wan_egress = false
        \\forbid_volume_export = true
        \\[[units]]
        \\artifact = "diosix-node.elf"
        \\packages = "doas,curl"
        \\ram = "1GiB"
        \\id = "unit-alpha"
        \\instances = { min = 2, target = 2, max = 4 }
    ;
    const parsed = try parseCharterToml(sample);
    try testing.expectEqualStrings("autonomous-mesh-01", parsed.id());
    try testing.expectEqual(@as(u32, 2), parsed.version);
    try testing.expectEqual(@as(u8, 67), parsed.stake_quorum_pct);
    try testing.expectEqualStrings(
        "Maintain 3-way distributed DB",
        parsed.goal(),
    );
    try testing.expectEqual(SpecMode.swarm, parsed.mode);
    try testing.expectEqual(@as(u16, 2), parsed.fleet_hosts);
    try testing.expect(!parsed.encrypt_volumes);
    try testing.expect(parsed.forbid_zero_replicas);
    const u = parsed.findUnit("unit-alpha").?;
    try testing.expectEqualStrings("diosix-node.elf", u.artifact());
    try testing.expectEqualStrings("doas,curl", u.packages());
    try testing.expectEqual(@as(u16, 2), u.min_instances);
    try testing.expectEqual(@as(u32, 2), parsed.totalMinReplicas());
}
