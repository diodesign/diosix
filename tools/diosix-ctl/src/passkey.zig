// Diosix Zero-Password Passkey Authentication & Enrollment Engine.
//
// Implements FIDO2/WebAuthn (`sk-ssh-ed25519@openssh.com`,
// `sk-ecdsa-sha2-nistp256@openssh.com`), TPM 2.0 device-bound platform
// passkey, QR enrollment URI generation, OpenSSH wire-format public key
// decoding, and real Ed25519 cryptographic challenge-response verification.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const sysconfig = @import("sysconfig.zig");

pub const AUTHORIZED_PASSKEYS_PATH = sysconfig.AUTHORIZED_PASSKEYS_PATH;
pub const DEV_AUTHORIZED_KEYS_PATH = sysconfig.DEV_AUTHORIZED_KEYS_PATH;
pub const ROOT_AUTHORIZED_KEYS_PATH = sysconfig.ROOT_AUTHORIZED_KEYS_PATH;
pub const CHALLENGE_STATE_PATH = sysconfig.CHALLENGE_STATE_PATH;

pub const MAX_PASSKEYS: usize = 32;
pub const CHALLENGE_BYTES: usize = 32;
pub const CHALLENGE_HEX_LEN: usize = CHALLENGE_BYTES * 2;
pub const ED25519_PUBKEY_LEN: usize = 32;
pub const ED25519_SIG_LEN: usize = 64;
pub const ED25519_SIG_HEX_LEN: usize = ED25519_SIG_LEN * 2;

/// Hex characters in the short passkey fingerprint: the first 8 bytes of the
/// SHA-256 digest of the wire blob.
pub const FINGERPRINT_HEX_LEN: usize = 16;

/// OpenSSH wire blob for an Ed25519 key: u32 length + "ssh-ed25519" (11
/// bytes) + u32 length + 32-byte public key.
pub const ED25519_WIRE_BLOB_LEN: usize = 4 + 11 + 4 + ED25519_PUBKEY_LEN;

/// Base64 length of `ED25519_WIRE_BLOB_LEN` bytes: ceil(51 / 3) * 4.
pub const ED25519_WIRE_B64_LEN: usize = 68;

/// Largest decoded wire blob accepted from an authorized_passkeys line. The
/// biggest supported type (sk-ecdsa-sha2-nistp256@openssh.com) is about 200
/// bytes, so this leaves ample headroom while bounding stack use.
const MAX_WIRE_BLOB_LEN: usize = 512;

const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const PasskeyKind = enum {
    fido2_ed25519,
    fido2_ecdsa,
    tpm2_platform,
    ssh_ed25519,
    ssh_ecdsa,

    pub fn label(self: PasskeyKind) []const u8 {
        return switch (self) {
            .fido2_ed25519 => "fido2-ed25519",
            .fido2_ecdsa => "fido2-ecdsa",
            .tpm2_platform => "tpm2-platform",
            .ssh_ed25519 => "ssh-ed25519",
            .ssh_ecdsa => "ssh-ecdsa",
        };
    }
};

pub const PasskeyEntry = struct {
    kind: PasskeyKind,
    key_type: []const u8,
    base64_blob: []const u8,
    comment: []const u8,
    ed25519_pubkey: ?[ED25519_PUBKEY_LEN]u8,
    fingerprint_hex: [FINGERPRINT_HEX_LEN]u8,
};

fn trimAscii(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

const WireKeyType = enum {
    @"sk-ssh-ed25519@openssh.com",
    @"sk-ecdsa-sha2-nistp256@openssh.com",
    @"ssh-ed25519",
    @"ecdsa-sha2-nistp256",
};

/// Classifies an OpenSSH / FIDO2 key type identifier and comment into
/// `PasskeyKind`.
pub fn classifyKeyType(key_type: []const u8, comment: []const u8) ?PasskeyKind {
    const parsed = std.meta.stringToEnum(WireKeyType, key_type) orelse
        return null;
    const is_tpm = std.mem.indexOf(u8, comment, "tpm2:") != null or
        std.mem.indexOf(u8, comment, "platform-tpm") != null;
    return switch (parsed) {
        .@"sk-ssh-ed25519@openssh.com" => .fido2_ed25519,
        .@"sk-ecdsa-sha2-nistp256@openssh.com" => .fido2_ecdsa,
        .@"ssh-ed25519" => if (is_tpm) .tpm2_platform else .ssh_ed25519,
        .@"ecdsa-sha2-nistp256" => if (is_tpm) .tpm2_platform else .ssh_ecdsa,
    };
}

/// Extracts the raw 32-byte Ed25519 public key from a decoded OpenSSH
/// wire-format key blob for both `ssh-ed25519` and
/// `sk-ssh-ed25519@openssh.com`.
pub fn extractEd25519PubkeyFromWireBlob(
    wire_blob: []const u8,
) ?[ED25519_PUBKEY_LEN]u8 {
    if (wire_blob.len < 4) return null;
    const type_len_u32 = std.mem.readInt(u32, wire_blob[0..4], .big);
    if (type_len_u32 > 128) return null;
    const type_len: usize = @intCast(type_len_u32);
    if (4 + type_len + 4 > wire_blob.len) return null;
    const key_type = wire_blob[4 .. 4 + type_len];
    const parsed = std.meta.stringToEnum(WireKeyType, key_type) orelse
        return null;
    switch (parsed) {
        .@"ssh-ed25519", .@"sk-ssh-ed25519@openssh.com" => {},
        else => return null,
    }

    const pk_len_off = 4 + type_len;
    const pk_len = std.mem.readInt(u32, wire_blob[pk_len_off..][0..4], .big);
    if (pk_len != ED25519_PUBKEY_LEN) return null;
    const pk_off = pk_len_off + 4;
    if (pk_off + ED25519_PUBKEY_LEN > wire_blob.len) return null;

    var out: [ED25519_PUBKEY_LEN]u8 = undefined;
    @memcpy(&out, wire_blob[pk_off .. pk_off + ED25519_PUBKEY_LEN]);
    return out;
}

/// Encodes a raw 32-byte Ed25519 public key into a standard OpenSSH
/// wire-format blob (`string "ssh-ed25519" || string <32-byte-pubkey>`,
/// 51 bytes total) and Base64-encodes it.
pub fn encodeOpenSshEd25519BlobBase64(
    pubkey: [ED25519_PUBKEY_LEN]u8,
    out_b64: *[ED25519_WIRE_B64_LEN]u8,
) []const u8 {
    var wire: [ED25519_WIRE_BLOB_LEN]u8 = undefined;
    std.mem.writeInt(u32, wire[0..4], 11, .big);
    @memcpy(wire[4..15], "ssh-ed25519");
    std.mem.writeInt(u32, wire[15..19], 32, .big);
    @memcpy(wire[19..51], &pubkey);
    return std.base64.standard.Encoder.encode(out_b64, &wire);
}

/// Parses and validates a single OpenSSH / FIDO2 authorized_passkeys line.
pub fn parsePasskeyLine(raw_line: []const u8) ?PasskeyEntry {
    const line = trimAscii(raw_line);
    if (line.len == 0 or line[0] == '#') return null;

    // Reject control characters or shell injection characters.
    for (line) |ch| {
        if (ch < 0x20 or ch >= 0x7f) return null;
        switch (ch) {
            ';', '|', '&', '`', '$', '<', '>', '\\', '"' => return null,
            else => {},
        }
    }

    var it = std.mem.tokenizeAny(u8, line, " \t");
    const key_type = it.next() orelse return null;
    const b64_blob = it.next() orelse return null;
    const rest_start =
        (@intFromPtr(b64_blob.ptr) - @intFromPtr(line.ptr)) + b64_blob.len;
    const comment = if (rest_start < line.len)
        trimAscii(line[rest_start..])
    else
        "";

    const kind = classifyKeyType(key_type, comment) orelse return null;

    var decoded_buf: [MAX_WIRE_BLOB_LEN]u8 = undefined;
    const decoded_len =
        std.base64.standard.Decoder.calcSizeForSlice(b64_blob) catch
            return null;
    if (decoded_len < 16 or decoded_len > decoded_buf.len) return null;
    std.base64.standard.Decoder.decode(
        decoded_buf[0..decoded_len],
        b64_blob,
    ) catch return null;
    const wire_blob = decoded_buf[0..decoded_len];

    // Verify wire header matches key_type.
    if (wire_blob.len < 4) return null;
    const wire_type_len_u32 = std.mem.readInt(u32, wire_blob[0..4], .big);
    if (wire_type_len_u32 > 128) return null;
    const wire_type_len: usize = @intCast(wire_type_len_u32);
    if (4 + wire_type_len > wire_blob.len) return null;
    const wire_type = wire_blob[4 .. 4 + wire_type_len];
    if (!std.mem.eql(u8, wire_type, key_type)) return null;

    // Compute short 16-char SHA-256 fingerprint of the wire blob.
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(wire_blob, &digest, .{});
    var fp_hex: [FINGERPRINT_HEX_LEN]u8 = undefined;
    _ = bytesToHex(digest[0 .. FINGERPRINT_HEX_LEN / 2], &fp_hex);

    return PasskeyEntry{
        .kind = kind,
        .key_type = key_type,
        .base64_blob = b64_blob,
        .comment = comment,
        .ed25519_pubkey = extractEd25519PubkeyFromWireBlob(wire_blob),
        .fingerprint_hex = fp_hex,
    };
}

/// Parses an entire `authorized_passkeys` buffer into `out_entries`.
pub fn parseAuthorizedPasskeys(
    content: []const u8,
    out_entries: []PasskeyEntry,
) usize {
    var count: usize = 0;
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |raw_line| {
        if (count >= out_entries.len) break;
        if (parsePasskeyLine(raw_line)) |entry| {
            out_entries[count] = entry;
            count += 1;
        }
    }
    return count;
}

/// Encodes a byte slice as lowercase hexadecimal.
pub const bytesToHex = @import("common.zig").bytesToHex;

/// Decodes a hexadecimal string into `out_bytes`.
pub fn hexToBytes(hex: []const u8, out_bytes: []u8) ?[]const u8 {
    if (hex.len % 2 != 0 or hex.len / 2 > out_bytes.len) return null;
    var i: usize = 0;
    while (i < hex.len) : (i += 2) {
        const hi = std.fmt.charToDigit(hex[i], 16) catch return null;
        const lo = std.fmt.charToDigit(hex[i + 1], 16) catch return null;
        out_bytes[i / 2] = (hi << 4) | lo;
    }
    return out_bytes[0 .. hex.len / 2];
}

/// Verifies a 64-byte (128-hex-char) Ed25519 signature over `challenge_msg`
/// against any enrolled Ed25519 / FIDO2-Ed25519 / TPM2-Ed25519 passkey in
/// `entries`. Returns the index of the matching passkey entry on success, or
/// `null` if verification fails.
pub fn verifyChallengeSignature(
    entries: []const PasskeyEntry,
    challenge_msg: []const u8,
    signature_hex: []const u8,
) ?usize {
    var sig_bytes: [ED25519_SIG_LEN]u8 = undefined;
    const decoded_sig = hexToBytes(signature_hex, &sig_bytes) orelse
        return null;
    if (decoded_sig.len != ED25519_SIG_LEN) return null;

    const sig = Ed25519.Signature.fromBytes(sig_bytes);

    for (entries, 0..) |entry, idx| {
        if (entry.ed25519_pubkey) |pk_bytes| {
            // A malformed enrolled key can never match; skip it.
            const pk = Ed25519.PublicKey.fromBytes(pk_bytes) catch continue;
            if (sig.verify(challenge_msg, pk)) |_| {
                return idx;
            } else |_| {}
        }
    }
    return null;
}

/// Generates a deterministic WebAuthn / FIDO2 hybrid QR enrollment URI for
/// smartphone/tablet pairing. The caller frees the result with `allocator`.
pub fn formatEnrollmentQrUri(
    allocator: std.mem.Allocator,
    challenge_hex: []const u8,
    seat_profile: []const u8,
) ![]u8 {
    return allocator.print(
        "diosix://passkey-enroll?rp=diosix.local&seat={s}&challenge={s}",
        .{ seat_profile, challenge_hex },
    );
}

// -----------------------------------------------------------------------------
// Unit Tests
// -----------------------------------------------------------------------------
const testing = std.testing;

test "formatEnrollmentQrUri never truncates long seat profiles" {
    const seat: [400]u8 = @splat('s');
    const uri = try formatEnrollmentQrUri(testing.allocator, "abcd", &seat);
    defer testing.allocator.free(uri);
    const expected = try testing.allocator.print(
        "diosix://passkey-enroll?rp=diosix.local&seat={s}&challenge=abcd",
        .{&seat},
    );
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, uri);
}

test "parsePasskeyLine validates FIDO2 sk-ssh-ed25519 and ssh-ed25519 keys" {
    testing.refAllDecls(@This());
    const seed: [Ed25519.KeyPair.seed_length]u8 = @splat(0x42);
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    var b64_buf: [ED25519_WIRE_B64_LEN]u8 = undefined;
    const b64_str = encodeOpenSshEd25519BlobBase64(
        kp.public_key.toBytes(),
        &b64_buf,
    );

    const line = try testing.allocator.print(
        "ssh-ed25519 {s} tpm2:platform-passkey",
        .{b64_str},
    );
    defer testing.allocator.free(line);

    const parsed = parsePasskeyLine(line).?;
    try testing.expectEqual(PasskeyKind.tpm2_platform, parsed.kind);
    try testing.expectEqualStrings("ssh-ed25519", parsed.key_type);
    try testing.expectEqualStrings("tpm2:platform-passkey", parsed.comment);
    try testing.expectEqualSlices(
        u8,
        &kp.public_key.toBytes(),
        &parsed.ed25519_pubkey.?,
    );

    // Also test FIDO2 sk-ssh-ed25519@openssh.com wire format:
    // string "sk-ssh-ed25519@openssh.com" (26 bytes) ||
    // string <32-byte pubkey> || string "ssh:" (4 bytes).
    var sk_wire: [4 + 26 + 4 + 32 + 4 + 4]u8 = undefined;
    std.mem.writeInt(u32, sk_wire[0..4], 26, .big);
    @memcpy(sk_wire[4..30], "sk-ssh-ed25519@openssh.com");
    std.mem.writeInt(u32, sk_wire[30..34], 32, .big);
    @memcpy(sk_wire[34..66], &kp.public_key.toBytes());
    std.mem.writeInt(u32, sk_wire[66..70], 4, .big);
    @memcpy(sk_wire[70..74], "ssh:");
    const Base64 = std.base64.standard.Encoder;
    var sk_b64_buf: [Base64.calcSize(sk_wire.len)]u8 = undefined;
    const sk_b64 = Base64.encode(&sk_b64_buf, &sk_wire);
    const sk_line = try testing.allocator.print(
        "sk-ssh-ed25519@openssh.com {s} yubikey-5-nfc",
        .{sk_b64},
    );
    defer testing.allocator.free(sk_line);
    const sk_parsed = parsePasskeyLine(sk_line).?;
    try testing.expectEqual(PasskeyKind.fido2_ed25519, sk_parsed.kind);
    try testing.expectEqualSlices(
        u8,
        &kp.public_key.toBytes(),
        &sk_parsed.ed25519_pubkey.?,
    );

    // Reject malformed or shell-injected lines and overflow wire headers.
    try testing.expect(
        parsePasskeyLine("ssh-ed25519 AAAAB3NzaC1yc2E= bad;rm -rf /") == null,
    );
    try testing.expect(parsePasskeyLine("unknown-type AAAA comment") == null);
    try testing.expect(
        parsePasskeyLine(
            "ssh-ed25519 /////wAAAAAAAAAAAAAAAAAAAA== overflow",
        ) == null,
    );
}

test "verifyChallengeSignature verifies real Ed25519 UART signatures" {
    const seed: [Ed25519.KeyPair.seed_length]u8 = @splat(0x7a);
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    var b64_buf: [ED25519_WIRE_B64_LEN]u8 = undefined;
    const b64_str = encodeOpenSshEd25519BlobBase64(
        kp.public_key.toBytes(),
        &b64_buf,
    );

    const line = try testing.allocator.print(
        "ssh-ed25519 {s} operator@yubikey\n",
        .{b64_str},
    );
    defer testing.allocator.free(line);

    var entries: [4]PasskeyEntry = undefined;
    const count = parseAuthorizedPasskeys(line, &entries);
    try testing.expectEqual(@as(usize, 1), count);

    const challenge = "diosix-challenge:0123456789abcdef0123456789abcdef";
    const sig = try kp.sign(challenge, null);
    var sig_hex_buf: [ED25519_SIG_HEX_LEN]u8 = undefined;
    const sig_hex = bytesToHex(&sig.toBytes(), &sig_hex_buf);

    const matched_idx = verifyChallengeSignature(
        entries[0..count],
        challenge,
        sig_hex,
    );
    try testing.expectEqual(@as(?usize, 0), matched_idx);

    // Tampered challenge must fail verification.
    try testing.expect(
        verifyChallengeSignature(
            entries[0..count],
            "tampered-challenge",
            sig_hex,
        ) == null,
    );
}
