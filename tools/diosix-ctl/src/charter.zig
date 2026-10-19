// Diosix Constitutional Charter Parser & SHA-256 Sealing.
//
// Implements workload-agnostic Charter parsing (`charter.toml`), SHA-256
// Charter sealing, and re-exports Steward invariant verification and Whisper
// Mesh consensus primitives from `whisper.zig`.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const interface = @import("interface").sbi;
const whisper = @import("whisper.zig");

pub const ProposalAction = whisper.ProposalAction;
pub const ProposalCheckResult = whisper.ProposalCheckResult;
pub const verifyProposalAgainstInvariants =
    whisper.verifyProposalAgainstInvariants;
pub const WhisperMessageType = whisper.WhisperMessageType;
pub const WhisperFrame = whisper.WhisperFrame;
pub const formatWhisperFrame = whisper.formatWhisperFrame;
pub const parseWhisperFrame = whisper.parseWhisperFrame;

pub const DEFAULT_CHARTER_PATH = "/etc/diosix/charter.toml";
pub const DEFAULT_CONSTITUTION_PATH = "/etc/diosix/constitution.md";
pub const ACTIVE_CHARTER_STATE_PATH = "/var/lib/diosix/charter_state.toml";
pub const CHARTER_AUDIT_LOG_PATH = "/var/lib/diosix/charter_audit.log";
pub const WHISPER_SPOOL_PATH = "/run/diosix/whisper.ring";

pub const MAX_CHARTER_UNITS: usize = 16;
pub const MAX_UNIT_ID_LEN: usize = 64;
pub const MAX_ARTIFACT_LEN: usize = 128;
pub const MAX_PUBKEY_LEN: usize = 256;

fn setFixedBuf(buf: []u8, len_out: *usize, val: []const u8) void {
    const copy_len = @min(val.len, buf.len);
    @memcpy(buf[0..copy_len], val[0..copy_len]);
    len_out.* = copy_len;
}

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
    sha256_bytes: [32]u8 = @splat(0),
    sha256_hex: [64]u8 = @splat('0'),

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

fn unquote(val: []const u8) []const u8 {
    var s = std.mem.trim(u8, val, " \t\r\n");
    if (std.mem.indexOfScalar(u8, s, '#')) |comment_idx| {
        if (s.len == 0 or s[0] != '"') {
            s = std.mem.trim(u8, s[0..comment_idx], " \t\r\n");
        } else if (std.mem.indexOfScalarPos(u8, s, 1, '"')) |close_q| {
            if (comment_idx > close_q) {
                s = std.mem.trim(u8, s[0..comment_idx], " \t\r\n");
            }
        }
    }
    if (s.len >= 2 and
        ((s[0] == '"' and s[s.len - 1] == '"') or
            (s[0] == '\'' and s[s.len - 1] == '\'')))
    {
        return s[1 .. s.len - 1];
    }
    return s;
}

fn parseInlineIntField(
    inline_table: []const u8,
    field_name: []const u8,
) ?u32 {
    const inner = std.mem.trim(u8, inline_table, " \t\r\n{}");
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const k = std.mem.trim(u8, pair[0..eq], " \t");
        const v = unquote(pair[eq + 1 ..]);
        if (std.mem.eql(u8, k, field_name)) {
            return std.fmt.parseInt(u32, v, 10) catch null;
        }
    }
    return null;
}

fn parseSizeMb(raw: []const u8) u32 {
    const s = unquote(raw);
    if (std.mem.endsWith(u8, s, "GiB") or
        std.mem.endsWith(u8, s, "GB") or
        std.mem.endsWith(u8, s, "G"))
    {
        const num_end = std.mem.indexOfAny(u8, s, "Gg") orelse s.len;
        const trimmed = std.mem.trim(u8, s[0..num_end], " \t");
        const g = std.fmt.parseInt(u32, trimmed, 10) catch return 256;
        return std.math.mul(u32, g, 1024) catch 256;
    }
    if (std.mem.endsWith(u8, s, "MiB") or
        std.mem.endsWith(u8, s, "MB") or
        std.mem.endsWith(u8, s, "M"))
    {
        const num_end = std.mem.indexOfAny(u8, s, "Mm") orelse s.len;
        const trimmed = std.mem.trim(u8, s[0..num_end], " \t");
        return std.fmt.parseInt(u32, trimmed, 10) catch 256;
    }
    return std.fmt.parseInt(u32, s, 10) catch 256;
}

/// Compute the 256-bit SHA-256 digest and lowercase hex string of a Charter.
pub fn computeCharterSha256(
    content: []const u8,
    out_bytes: *[32]u8,
    out_hex: *[64]u8,
) void {
    std.crypto.hash.sha2.Sha256.hash(content, out_bytes, .{});
    const hex_chars = "0123456789abcdef";
    for (out_bytes.*, 0..) |b, i| {
        out_hex[i * 2] = hex_chars[b >> 4];
        out_hex[i * 2 + 1] = hex_chars[b & 0x0f];
    }
}

/// Merge any unit spec fields populated on `src` before `.id` was encountered
/// into `dst` (which may already hold `[invariants.isolation.<id>]` flags).
fn mergeUnitFields(dst: *WorkloadUnit, src: *const WorkloadUnit) void {
    if (src.artifact_len > 0) {
        setFixedBuf(&dst.artifact_buf, &dst.artifact_len, src.artifact());
    }
    if (src.min_instances != 1) dst.min_instances = src.min_instances;
    if (src.target_instances != 1) dst.target_instances = src.target_instances;
    if (src.max_instances != 4) dst.max_instances = src.max_instances;
    if (src.vcpus != 1) dst.vcpus = src.vcpus;
    if (src.ram_mb != 256) dst.ram_mb = src.ram_mb;
}

fn applyUnitKey(
    charter: *ParsedCharter,
    active_unit_idx: *?usize,
    key: []const u8,
    val: []const u8,
) void {
    const UnitKey = enum {
        id,
        artifact,
        min_instances,
        target_instances,
        max_instances,
        instances,
        vcpus,
        ram,
        quota,
    };
    const idx = active_unit_idx.* orelse return;
    var u = &charter.units[idx];
    const k = std.meta.stringToEnum(UnitKey, key) orelse return;
    switch (k) {
        .id => {
            for (0..idx) |prev_i| {
                if (std.mem.eql(u8, charter.units[prev_i].id(), val)) {
                    mergeUnitFields(&charter.units[prev_i], u);
                    active_unit_idx.* = prev_i;
                    charter.unit_count = idx;
                    return;
                }
            }
            setFixedBuf(&u.id_buf, &u.id_len, val);
        },
        .artifact => setFixedBuf(&u.artifact_buf, &u.artifact_len, val),
        .min_instances => {
            u.min_instances = std.fmt.parseInt(u16, val, 10) catch 1;
        },
        .target_instances => {
            u.target_instances = std.fmt.parseInt(u16, val, 10) catch 1;
        },
        .max_instances => {
            u.max_instances = std.fmt.parseInt(u16, val, 10) catch 4;
        },
        .instances => {
            if (parseInlineIntField(val, "min")) |v| {
                u.min_instances = @intCast(v);
            }
            if (parseInlineIntField(val, "target")) |v| {
                u.target_instances = @intCast(v);
            }
            if (parseInlineIntField(val, "max")) |v| {
                u.max_instances = @intCast(v);
            }
        },
        .vcpus => u.vcpus = std.fmt.parseInt(u16, val, 10) catch 1,
        .ram => u.ram_mb = parseSizeMb(val),
        .quota => {
            if (parseInlineIntField(val, "vcpus")) |v| u.vcpus = @intCast(v);
        },
    }
}

/// Parse a `charter.toml` configuration into a validated `ParsedCharter`.
pub fn parseCharterToml(content: []const u8) !ParsedCharter {
    var charter = ParsedCharter{};
    computeCharterSha256(content, &charter.sha256_bytes, &charter.sha256_hex);

    const Section = enum { none, charter, invariants, isolation_unit, unit };
    var section: Section = .none;
    var iso_unit_buf: [MAX_UNIT_ID_LEN]u8 = @splat(0);
    var iso_unit_len: usize = 0;
    var active_unit_idx: ?usize = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.eql(u8, line, "[[units]]")) {
            section = .unit;
            if (charter.unit_count < MAX_CHARTER_UNITS) {
                active_unit_idx = charter.unit_count;
                charter.units[charter.unit_count] = .{};
                charter.unit_count += 1;
            } else {
                active_unit_idx = null;
            }
            continue;
        }

        const HeaderSection = enum { charter, invariants };
        if (line[0] == '[' and line[line.len - 1] == ']') {
            const header = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            if (std.meta.stringToEnum(HeaderSection, header)) |hdr| {
                section = switch (hdr) {
                    .charter => .charter,
                    .invariants => .invariants,
                };
            } else if (std.mem.startsWith(
                u8,
                header,
                "invariants.isolation.",
            )) {
                section = .isolation_unit;
                const uname = unquote(header["invariants.isolation.".len..]);
                setFixedBuf(&iso_unit_buf, &iso_unit_len, uname);
                _ = charter.findOrCreateUnit(iso_unit_buf[0..iso_unit_len]);
            } else {
                section = .none;
            }
            continue;
        }

        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_idx], " \t");
        const val = unquote(std.mem.trim(u8, line[eq_idx + 1 ..], " \t"));

        switch (section) {
            .charter, .none => {
                const CharterKey = enum {
                    id,
                    version,
                    quorum_required,
                    quorum_total,
                    quorum,
                    standby_replicas,
                    root_failover,
                    principal_pubkey,
                };
                if (std.meta.stringToEnum(CharterKey, key)) |k| switch (k) {
                    .id => setFixedBuf(&charter.id_buf, &charter.id_len, val),
                    .version => {
                        charter.version =
                            std.fmt.parseInt(u32, val, 10) catch 1;
                    },
                    .quorum_required => {
                        charter.quorum_required =
                            std.fmt.parseInt(u16, val, 10) catch 2;
                    },
                    .quorum_total => {
                        charter.quorum_total =
                            std.fmt.parseInt(u16, val, 10) catch 3;
                    },
                    .quorum => {
                        if (parseInlineIntField(val, "required")) |req| {
                            charter.quorum_required = @intCast(@min(req, 62));
                        }
                        if (parseInlineIntField(val, "total")) |tot| {
                            charter.quorum_total = @intCast(@min(tot, 62));
                        }
                    },
                    .standby_replicas => {
                        charter.standby_replicas =
                            std.fmt.parseInt(u16, val, 10) catch 1;
                    },
                    .root_failover => {
                        if (parseInlineIntField(val, "standby_replicas")) |r| {
                            charter.standby_replicas = @intCast(@min(r, 8));
                        }
                    },
                    .principal_pubkey => setFixedBuf(
                        &charter.principal_pubkey_buf,
                        &charter.principal_pubkey_len,
                        val,
                    ),
                };
            },
            .invariants => {
                const InvariantKey = enum {
                    min_stewards,
                    max_simultaneous_unit_termination_pct,
                    require_quorum_for_volume_deletion,
                    volume_deletion_timelock_sec,
                };
                if (std.meta.stringToEnum(InvariantKey, key)) |k| switch (k) {
                    .min_stewards => {
                        charter.min_stewards =
                            std.fmt.parseInt(u16, val, 10) catch 3;
                    },
                    .max_simultaneous_unit_termination_pct => {
                        const pct = std.fmt.parseInt(u8, val, 10) catch 33;
                        charter.max_simultaneous_unit_termination_pct =
                            @min(pct, 100);
                    },
                    .require_quorum_for_volume_deletion => {
                        charter.require_quorum_for_volume_deletion =
                            std.mem.eql(u8, val, "true");
                    },
                    .volume_deletion_timelock_sec => {
                        charter.volume_deletion_timelock_sec =
                            std.fmt.parseInt(u32, val, 10) catch 86400;
                    },
                };
            },
            .isolation_unit => {
                const IsolationKey = enum {
                    confidential_memory,
                    allow_wan_egress,
                    forbid_volume_export,
                };
                const iso_name = iso_unit_buf[0..iso_unit_len];
                if (charter.findOrCreateUnit(iso_name)) |u| {
                    const is_t = std.mem.eql(u8, val, "true");
                    if (std.meta.stringToEnum(IsolationKey, key)) |k| {
                        switch (k) {
                            .confidential_memory => {
                                u.confidential_memory = is_t;
                            },
                            .allow_wan_egress => u.allow_wan_egress = is_t,
                            .forbid_volume_export => {
                                u.forbid_volume_export = is_t;
                            },
                        }
                    }
                }
            },
            .unit => applyUnitKey(&charter, &active_unit_idx, key, val),
        }
    }

    if (charter.quorum_required == 0 or
        charter.quorum_required > charter.quorum_total or
        charter.quorum_total > 62)
    {
        return error.InvalidQuorumConfig;
    }

    return charter;
}

test "parseCharterToml parses Charter and merges out-of-order unit keys" {
    std.testing.refAllDecls(@This());
    _ = whisper;
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
