// Principal Ed25519 Keypair Generation, Charter Signing, and Verification.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const interface = @import("interface").sbi;
const charter_mod = @import("../charter.zig");
const common = @import("../common.zig");
const net_http = @import("../net/http.zig");
const passkey = @import("../passkey.zig");
const sysconfig = @import("../sysconfig.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const ParsedCharter = charter_mod.ParsedCharter;

pub const PRIV_SEED_BYTES: usize = Ed25519.KeyPair.seed_length;
pub const PRIV_SEED_HEX_LEN: usize = PRIV_SEED_BYTES * 2;
pub const PUBKEY_HEX_LEN: usize = interface.MISSION_PUBKEY_LEN * 2;

pub fn decodeSeedHex(seed_hex: []const u8) ![PRIV_SEED_BYTES]u8 {
    const trimmed = common.trimWhitespace(seed_hex);
    if (trimmed.len != PRIV_SEED_HEX_LEN) return error.InvalidSeedLength;
    var seed: [PRIV_SEED_BYTES]u8 = undefined;
    const dec = passkey.hexToBytes(trimmed, &seed) orelse
        return error.InvalidHexSeed;
    if (dec.len != PRIV_SEED_BYTES) return error.InvalidSeedLength;
    return seed;
}

pub fn readRandomSeedBytes(out_seed: *[PRIV_SEED_BYTES]u8) !void {
    const rc: isize = @bitCast(
        linux.open(sysconfig.DEV_URANDOM_PATH, .{ .ACCMODE = .RDONLY }, 0),
    );
    if (rc < 0) return error.EntropyUnavailable;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var filled: usize = 0;
    while (filled < PRIV_SEED_BYTES) {
        const rr: isize = @bitCast(
            linux.read(fd, out_seed[filled..].ptr, PRIV_SEED_BYTES - filled),
        );
        if (rr <= 0) return error.EntropyUnavailable;
        filled += @intCast(rr);
    }
}

/// Generate a fresh Ed25519 Principal keypair, saving the 32-byte hex seed
/// to `priv_path` (0600) and the 32-byte hex public key to `pub_path` (0644).
pub fn generatePrincipalKeypair(
    priv_path: []const u8,
    pub_path: []const u8,
) ![interface.MISSION_PUBKEY_LEN]u8 {
    var seed: [PRIV_SEED_BYTES]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    try readRandomSeedBytes(&seed);

    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const pk_bytes = kp.public_key.toBytes();

    var priv_hex: [PRIV_SEED_HEX_LEN + 1]u8 = undefined;
    defer std.crypto.secureZero(u8, &priv_hex);
    _ = common.bytesToHex(&seed, priv_hex[0..PRIV_SEED_HEX_LEN]);
    priv_hex[PRIV_SEED_HEX_LEN] = '\n';

    var pub_hex: [PUBKEY_HEX_LEN + 1]u8 = undefined;
    _ = common.bytesToHex(&pk_bytes, pub_hex[0..PUBKEY_HEX_LEN]);
    pub_hex[PUBKEY_HEX_LEN] = '\n';

    net_http.ensureParentDir(priv_path);
    net_http.ensureParentDir(pub_path);
    try common.writePrivateFile(priv_path, &priv_hex);
    try common.writeFile(pub_path, &pub_hex);
    return pk_bytes;
}

fn buildUnsignedWithPubkey(
    allocator: std.mem.Allocator,
    content: []const u8,
    pk_hex: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var in_charter = false;
    var found_charter = false;
    var wrote_pk = false;
    var pos: usize = 0;

    while (pos < content.len) {
        const nl = std.mem.indexOfScalarPos(u8, content, pos, '\n');
        const next_pos = if (nl) |idx| idx + 1 else content.len;
        const raw_slice = content[pos..next_pos];
        const line = std.mem.trim(u8, raw_slice, " \t\r\n");

        if (line.len > 1 and line[0] == '[' and line[line.len - 1] == ']') {
            const is_hdr = !std.mem.startsWith(u8, line, "[[");
            const hdr = if (is_hdr)
                std.mem.trim(u8, line[1 .. line.len - 1], " \t")
            else
                "";
            if (is_hdr and std.mem.eql(u8, hdr, "charter")) {
                found_charter = true;
                in_charter = true;
                try out.appendSlice(allocator, "[charter]\n");
                pos = next_pos;
                continue;
            } else if (in_charter) {
                if (!wrote_pk) {
                    const pkl = try allocator.print(
                        "principal_pubkey = \"{s}\"\n",
                        .{pk_hex},
                    );
                    defer allocator.free(pkl);
                    try out.appendSlice(allocator, pkl);
                    wrote_pk = true;
                }
                in_charter = false;
            }
        } else if (in_charter and line.len > 0 and line[0] != '#') {
            if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                const key = std.mem.trim(u8, line[0..eq], " \t");
                if (std.mem.eql(u8, key, "signature")) {
                    pos = next_pos;
                    continue;
                }
                if (std.mem.eql(u8, key, "principal_pubkey")) {
                    const pkl = try allocator.print(
                        "principal_pubkey = \"{s}\"\n",
                        .{pk_hex},
                    );
                    defer allocator.free(pkl);
                    try out.appendSlice(allocator, pkl);
                    wrote_pk = true;
                    pos = next_pos;
                    continue;
                }
            }
        }
        try out.appendSlice(allocator, raw_slice);
        pos = next_pos;
    }

    if (!found_charter) {
        var hdr_out: std.ArrayList(u8) = .empty;
        errdefer hdr_out.deinit(allocator);
        const h = try allocator.print(
            "[charter]\nprincipal_pubkey = \"{s}\"\n",
            .{pk_hex},
        );
        defer allocator.free(h);
        try hdr_out.appendSlice(allocator, h);
        try hdr_out.appendSlice(allocator, out.items);
        out.deinit(allocator);
        return hdr_out.toOwnedSlice(allocator);
    }

    if (in_charter and !wrote_pk) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
            try out.append(allocator, '\n');
        }
        const pkl = try allocator.print(
            "principal_pubkey = \"{s}\"\n",
            .{pk_hex},
        );
        defer allocator.free(pkl);
        try out.appendSlice(allocator, pkl);
    }
    return out.toOwnedSlice(allocator);
}

fn insertSignatureLine(
    allocator: std.mem.Allocator,
    unsigned_toml: []const u8,
    sig_hex: []const u8,
) ![]u8 {
    const marker = "[charter]\n";
    const idx = std.mem.indexOf(u8, unsigned_toml, marker) orelse
        return error.MissingCharterSection;
    const split = idx + marker.len;
    return allocator.print(
        "{s}signature = \"{s}\"\n{s}",
        .{ unsigned_toml[0..split], sig_hex, unsigned_toml[split..] },
    );
}

/// Sign a `charter.toml` document with `priv_seed_hex` (or rotate keys by
/// signing the new `principal_pubkey` with `old_priv_seed_hex_opt`).
pub fn signCharterContent(
    allocator: std.mem.Allocator,
    content: []const u8,
    priv_seed_hex: []const u8,
    old_priv_seed_hex_opt: ?[]const u8,
) ![]u8 {
    var new_seed = try decodeSeedHex(priv_seed_hex);
    defer std.crypto.secureZero(u8, &new_seed);
    const new_kp = try Ed25519.KeyPair.generateDeterministic(new_seed);
    const new_pk = new_kp.public_key.toBytes();

    var signing_kp = new_kp;
    if (old_priv_seed_hex_opt) |old_hex| {
        var old_seed = try decodeSeedHex(old_hex);
        defer std.crypto.secureZero(u8, &old_seed);
        signing_kp = try Ed25519.KeyPair.generateDeterministic(old_seed);
    }

    var pk_hex: [PUBKEY_HEX_LEN]u8 = undefined;
    _ = common.bytesToHex(&new_pk, &pk_hex);

    const unsigned = try buildUnsignedWithPubkey(allocator, content, &pk_hex);
    defer allocator.free(unsigned);

    const parsed = try charter_mod.parseCharterToml(unsigned);
    const margs = try parsed.toMissionArgs(false);
    const msg = interface.buildMissionSignMessage(&margs);
    const sig = try signing_kp.sign(&msg, null);
    var sig_hex: [interface.MISSION_SIG_LEN * 2]u8 = undefined;
    _ = common.bytesToHex(&sig.toBytes(), &sig_hex);

    return insertSignatureLine(allocator, unsigned, &sig_hex);
}

/// Cryptographically verify a parsed Charter's Ed25519 signature.
pub fn verifyCharterSignature(
    parsed: *const ParsedCharter,
    expected_pubkey_override: ?[interface.MISSION_PUBKEY_LEN]u8,
) bool {
    const sig_bytes = parsed.decodeSignature() orelse return false;
    const own_pk = parsed.decodePrincipalPubkey() orelse return false;
    const verify_pk = expected_pubkey_override orelse own_pk;
    const pk = Ed25519.PublicKey.fromBytes(verify_pk) catch return false;
    const margs = parsed.toMissionArgs(false) catch return false;
    const msg = interface.buildMissionSignMessage(&margs);
    const sig = Ed25519.Signature.fromBytes(sig_bytes);
    sig.verify(&msg, pk) catch return false;
    return true;
}

test "charter/crypto: sign, verify, tamper rejection, and key rotation" {
    std.testing.refAllDecls(@This());
    const t = std.testing;
    const seed1: [PRIV_SEED_BYTES]u8 = @splat(0x31);
    const seed2: [PRIV_SEED_BYTES]u8 = @splat(0x52);
    var s1_hex: [PRIV_SEED_HEX_LEN]u8 = undefined;
    var s2_hex: [PRIV_SEED_HEX_LEN]u8 = undefined;
    _ = common.bytesToHex(&seed1, &s1_hex);
    _ = common.bytesToHex(&seed2, &s2_hex);
    const kp1 = try Ed25519.KeyPair.generateDeterministic(seed1);

    const raw =
        \\[charter]
        \\id = "mesh-signed"
        \\version = 1
        \\principal_pubkey = ""
        \\[[units]]
        \\id = "db"
        \\instances = { min = 3, target = 3, max = 5 }
    ;
    const signed1 = try signCharterContent(t.allocator, raw, &s1_hex, null);
    defer t.allocator.free(signed1);
    const p1 = try charter_mod.parseCharterToml(signed1);
    try t.expect(verifyCharterSignature(&p1, null));
    try t.expect(verifyCharterSignature(&p1, kp1.public_key.toBytes()));

    // Rotating to seed2 signed by seed1 verifies against old key kp1.
    const rotated = try signCharterContent(
        t.allocator,
        raw,
        &s2_hex,
        &s1_hex,
    );
    defer t.allocator.free(rotated);
    const p_rot = try charter_mod.parseCharterToml(rotated);
    try t.expect(verifyCharterSignature(&p_rot, kp1.public_key.toBytes()));
    try t.expect(!verifyCharterSignature(&p_rot, null));

    // Tampering goal/version invalidates signature.
    const tampered = try std.mem.replaceOwned(
        u8,
        t.allocator,
        signed1,
        "min = 3",
        "min = 0",
    );
    defer t.allocator.free(tampered);
    const p_bad = try charter_mod.parseCharterToml(tampered);
    try t.expect(!verifyCharterSignature(&p_bad, null));
}
