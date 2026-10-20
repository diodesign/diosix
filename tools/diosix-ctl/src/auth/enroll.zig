// Diosix Zero-Password Passkey Enrollment CLI Handler (dsx auth enroll).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const passkey = @import("../passkey.zig");
const common = @import("../common.zig");

const printStr = common.printStr;
const sanitizeJsonStr = common.sanitizeJsonStr;
const trimWhitespace = common.trimWhitespace;
const readBinaryFile = common.readBinaryFile;
const unmapBinaryFile = common.unmapBinaryFile;
const appendFileLine = common.appendFileLine;
const generateEntropyBytes = common.generateEntropyBytes;

const Ed25519 = std.crypto.sign.Ed25519;

/// Largest public key file accepted by `--file`: one OpenSSH key line, far
/// below a page.
const MAX_PUBKEY_FILE_BYTES: usize = 4096;

pub const AuthEnrollOption = enum {
    @"--key",
    @"-k",
    @"--file",
    @"-f",
    @"--label",
    @"-l",
    @"--tpm",
    @"--fido2",
    @"--qr",
    @"--json",
    @"-j",
};

pub fn cmdAuthEnroll(
    args: []const [*:0]const u8,
    seat_profile: []const u8,
    initial_json: bool,
) !void {
    const sys_cfg = common.loadRuntimeSystemConfig();
    var key_arg: ?[]const u8 = null;
    var file_arg: ?[]const u8 = null;
    var label_arg: []const u8 = "operator@diosix";
    var tpm_mode = false;
    var fido2_mode = false;
    var qr_mode = false;
    var json_mode = initial_json;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const span = std.mem.span(args[i]);
        if (std.meta.stringToEnum(AuthEnrollOption, span)) |opt| {
            switch (opt) {
                .@"--key", .@"-k" => {
                    if (i + 1 >= args.len) {
                        printStr(
                            "Error: Option '--key' requires a public key.\n",
                        );
                        return;
                    }
                    i += 1;
                    key_arg = std.mem.span(args[i]);
                },
                .@"--file", .@"-f" => {
                    if (i + 1 >= args.len) {
                        printStr(
                            "Error: Option '--file' requires a file path.\n",
                        );
                        return;
                    }
                    i += 1;
                    file_arg = std.mem.span(args[i]);
                },
                .@"--label", .@"-l" => {
                    if (i + 1 >= args.len) {
                        printStr(
                            "Error: Option '--label' requires a label.\n",
                        );
                        return;
                    }
                    i += 1;
                    label_arg = std.mem.span(args[i]);
                },
                .@"--tpm" => tpm_mode = true,
                .@"--fido2" => fido2_mode = true,
                .@"--qr" => qr_mode = true,
                .@"--json", .@"-j" => json_mode = true,
            }
        }
    }

    const allocator = std.heap.page_allocator;

    if (qr_mode) {
        var nonce_bytes: [passkey.CHALLENGE_BYTES]u8 = undefined;
        try generateEntropyBytes(&nonce_bytes);
        defer std.crypto.secureZero(u8, &nonce_bytes);
        var nonce_hex_buf: [passkey.CHALLENGE_HEX_LEN]u8 = undefined;
        const nonce_hex = passkey.bytesToHex(&nonce_bytes, &nonce_hex_buf);
        const uri = try passkey.formatEnrollmentQrUri(
            allocator,
            nonce_hex,
            seat_profile,
        );
        defer allocator.free(uri);

        if (json_mode) {
            common.printFmt(
                "{{\"status\":\"qr_ready\",\"uri\":\"{s}\"," ++
                    "\"seat\":\"{s}\",\"challenge\":\"{s}\"}}\n",
                .{ uri, seat_profile, nonce_hex },
            );
        } else {
            common.printFmt("WebAuthn passkey QR URI : {s}\n", .{uri});
        }
        return;
    }

    var synth_line: ?[]u8 = null;
    defer if (synth_line) |l| allocator.free(l);
    var file_mapped: ?[]u8 = null;
    defer if (file_mapped) |m| unmapBinaryFile(m);

    var line_to_enroll: ?[]const u8 = key_arg;
    if (line_to_enroll == null and file_arg != null) {
        if (readBinaryFile(file_arg.?, MAX_PUBKEY_FILE_BYTES)) |fbytes| {
            file_mapped = fbytes;
            line_to_enroll = trimWhitespace(fbytes);
        } else |_| {
            printStr("Error: Could not read public key file.\n");
            return;
        }
    } else if (line_to_enroll == null and (tpm_mode or fido2_mode)) {
        var seed: [Ed25519.KeyPair.seed_length]u8 = undefined;
        try generateEntropyBytes(&seed);
        defer std.crypto.secureZero(u8, &seed);
        var kp = Ed25519.KeyPair.generateDeterministic(seed) catch {
            printStr("Error: Could not generate passkey key pair.\n");
            return;
        };
        defer std.crypto.secureZero(u8, &kp.secret_key.bytes);
        var b64_buf: [passkey.ED25519_WIRE_B64_LEN]u8 = undefined;
        const b64_str = passkey.encodeOpenSshEd25519BlobBase64(
            kp.public_key.toBytes(),
            &b64_buf,
        );
        const prefix_comment = if (tpm_mode) "tpm2:" else "fido2:";
        synth_line = try allocator.print(
            "ssh-ed25519 {s} {s}{s}",
            .{ b64_str, prefix_comment, label_arg },
        );
        line_to_enroll = synth_line;
    }

    if (line_to_enroll == null) {
        printStr(
            "Error: Specify '--key <pubkey>', '--file <path>', " ++
                "'--tpm', '--fido2', or '--qr'.\n",
        );
        return;
    }

    const validated = passkey.parsePasskeyLine(line_to_enroll.?) orelse {
        printStr(
            "Error: Invalid OpenSSH or FIDO2 passkey public key format.\n",
        );
        return;
    };

    const auth_pk_z = try allocator.printSentinel(
        "{s}/authorized_passkeys",
        .{sys_cfg.keysDir()},
        0,
    );
    defer allocator.free(auth_pk_z);

    try appendFileLine(auth_pk_z.ptr, line_to_enroll.?);
    try appendFileLine(passkey.ROOT_AUTHORIZED_KEYS_PATH, line_to_enroll.?);

    if (json_mode) {
        // Sanitizing only removes characters, so the comment length bounds it.
        const comment_buf = try allocator.alloc(u8, validated.comment.len);
        defer allocator.free(comment_buf);
        common.printFmt(
            "{{\"status\":\"enrolled\",\"kind\":\"{s}\"," ++
                "\"fingerprint\":\"{s}\",\"comment\":\"{s}\"}}\n",
            .{
                validated.kind.label(),
                &validated.fingerprint_hex,
                sanitizeJsonStr(comment_buf, validated.comment),
            },
        );
    } else {
        common.printFmt(
            "✓ Enrolled passkey ({s}, fingerprint {s})\n",
            .{ validated.kind.label(), &validated.fingerprint_hex },
        );
    }
}

test "auth/enroll: option enum parses enrollment flags" {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(
        AuthEnrollOption.@"--tpm",
        std.meta.stringToEnum(AuthEnrollOption, "--tpm").?,
    );
}
