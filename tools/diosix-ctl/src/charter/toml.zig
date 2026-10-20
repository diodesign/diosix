// Diosix Constitutional Charter TOML Parser & SHA-256 Sealing.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const charter_mod = @import("../charter.zig");
const common = @import("../common.zig");

const ParsedCharter = charter_mod.ParsedCharter;
const WorkloadUnit = charter_mod.WorkloadUnit;
const MAX_CHARTER_UNITS = charter_mod.MAX_CHARTER_UNITS;
const MAX_UNIT_ID_LEN = charter_mod.MAX_UNIT_ID_LEN;
const SHA256_DIGEST_LEN = charter_mod.SHA256_DIGEST_LEN;
const SHA256_HEX_LEN = charter_mod.SHA256_HEX_LEN;

const setFixedBuf = common.setFixedBuf;
const unquote = common.unquoteToml;

fn clampU16(v: u64) u16 {
    return @intCast(@min(v, std.math.maxInt(u16)));
}

fn clampU32(v: u64) u32 {
    return @intCast(@min(v, std.math.maxInt(u32)));
}

fn parseClampedU16(s: []const u8, fallback: u16) u16 {
    const v = std.fmt.parseInt(u64, s, 10) catch return fallback;
    return clampU16(v);
}

fn parseClampedU32(s: []const u8, fallback: u32) u32 {
    const v = std.fmt.parseInt(u64, s, 10) catch return fallback;
    return clampU32(v);
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
            const n = std.fmt.parseInt(u64, v, 10) catch return null;
            return clampU32(n);
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
        const g = std.fmt.parseInt(u64, trimmed, 10) catch return 256;
        const mb = std.math.mul(u64, g, 1024) catch std.math.maxInt(u32);
        return clampU32(mb);
    }
    if (std.mem.endsWith(u8, s, "MiB") or
        std.mem.endsWith(u8, s, "MB") or
        std.mem.endsWith(u8, s, "M"))
    {
        const num_end = std.mem.indexOfAny(u8, s, "Mm") orelse s.len;
        const trimmed = std.mem.trim(u8, s[0..num_end], " \t");
        return parseClampedU32(trimmed, 256);
    }
    return parseClampedU32(s, 256);
}

/// Compute the 256-bit SHA-256 digest and lowercase hex string of a Charter.
pub fn computeCharterSha256(
    content: []const u8,
    out_bytes: *[SHA256_DIGEST_LEN]u8,
    out_hex: *[SHA256_HEX_LEN]u8,
) void {
    std.crypto.hash.sha2.Sha256.hash(content, out_bytes, .{});
    _ = common.bytesToHex(out_bytes, out_hex);
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
        .min_instances => u.min_instances = parseClampedU16(val, 1),
        .target_instances => u.target_instances = parseClampedU16(val, 1),
        .max_instances => u.max_instances = parseClampedU16(val, 4),
        .instances => {
            if (parseInlineIntField(val, "min")) |v| {
                u.min_instances = clampU16(v);
            }
            if (parseInlineIntField(val, "target")) |v| {
                u.target_instances = clampU16(v);
            }
            if (parseInlineIntField(val, "max")) |v| {
                u.max_instances = clampU16(v);
            }
        },
        .vcpus => u.vcpus = parseClampedU16(val, 1),
        .ram => u.ram_mb = parseSizeMb(val),
        .quota => {
            if (parseInlineIntField(val, "vcpus")) |v| {
                u.vcpus = clampU16(v);
            }
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
                    .version => charter.version = parseClampedU32(val, 1),
                    .quorum_required => {
                        charter.quorum_required = parseClampedU16(val, 2);
                    },
                    .quorum_total => {
                        charter.quorum_total = parseClampedU16(val, 3);
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
                        charter.standby_replicas = parseClampedU16(val, 1);
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
                        charter.min_stewards = parseClampedU16(val, 3);
                    },
                    .max_simultaneous_unit_termination_pct => {
                        const pct = std.fmt.parseInt(u64, val, 10) catch 33;
                        charter.max_simultaneous_unit_termination_pct =
                            @intCast(@min(pct, 100));
                    },
                    .require_quorum_for_volume_deletion => {
                        charter.require_quorum_for_volume_deletion =
                            std.mem.eql(u8, val, "true");
                    },
                    .volume_deletion_timelock_sec => {
                        charter.volume_deletion_timelock_sec =
                            parseClampedU32(val, 86400);
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

test "charter/toml: clamps overflowing inline integers without panicking" {
    std.testing.refAllDecls(@This());
    const sample =
        \\[charter]
        \\id = "clamp-test"
        \\version = 9999999999999
        \\quorum = { required = 2, total = 3 }
        \\[[units]]
        \\id = "u1"
        \\instances = { min = 999999, target = 999999, max = 999999 }
        \\quota = { vcpus = 999999 }
    ;
    const parsed = try parseCharterToml(sample);
    try std.testing.expectEqual(std.math.maxInt(u32), parsed.version);
    const u = parsed.findUnit("u1").?;
    try std.testing.expectEqual(std.math.maxInt(u16), u.min_instances);
    try std.testing.expectEqual(std.math.maxInt(u16), u.target_instances);
    try std.testing.expectEqual(std.math.maxInt(u16), u.max_instances);
    try std.testing.expectEqual(std.math.maxInt(u16), u.vcpus);
}
