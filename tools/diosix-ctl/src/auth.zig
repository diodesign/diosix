// Diosix Zero-Password Passkey Authentication CLI (dsx auth).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("api.zig");
const passkey = @import("passkey.zig");
const common = @import("common.zig");
const sysconfig = @import("sysconfig.zig");
const enroll = @import("auth/enroll.zig");

pub const AuthEnrollOption = enroll.AuthEnrollOption;
pub const cmdAuthEnroll = enroll.cmdAuthEnroll;

const printStr = common.printStr;
const printFmt = common.printFmt;
const sanitizeJsonStr = common.sanitizeJsonStr;
const trimWhitespace = common.trimWhitespace;
const readBinaryFile = common.readBinaryFile;
const unmapBinaryFile = common.unmapBinaryFile;
const writeFile = common.writeFile;
const fileExistsPath = common.fileExistsPath;
const detectSeatProfile = common.detectSeatProfile;
const detectBootMode = common.detectBootMode;
const generateEntropyBytes = common.generateEntropyBytes;

const AuthSubcommand = enum {
    status,
    list,
    ls,
    challenge,
    enroll,
    verify,
};

const AuthVerifyOption = enum {
    @"--challenge",
    @"-c",
    @"--json",
    @"-j",
};

/// Upper bound on the authorized_passkeys file we are willing to read.
const MAX_AUTHORIZED_PASSKEYS_BYTES: usize = 64 * 1024;

/// Upper bound on the challenge state file: "diosix-challenge:" plus the
/// 64-character hex nonce is far smaller than this.
const MAX_CHALLENGE_STATE_BYTES: usize = 512;

/// Renders the enrolled passkeys as the `dsx auth list --json` document.
/// The caller frees the result with `allocator`.
fn passkeyListJson(
    allocator: std.mem.Allocator,
    entries: []const passkey.PasskeyEntry,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"passkeys\":[");
    for (entries, 0..) |entry, idx| {
        const sep: []const u8 = if (idx > 0) "," else "";
        // Sanitizing only removes characters, so the comment length bounds it.
        const comment = try allocator.alloc(u8, entry.comment.len);
        defer allocator.free(comment);
        try out.print(
            allocator,
            "{s}{{\"index\":{d},\"kind\":\"{s}\"," ++
                "\"key_type\":\"{s}\",\"fingerprint\":\"{s}\"," ++
                "\"comment\":\"{s}\"}}",
            .{
                sep,
                idx + 1,
                entry.kind.label(),
                entry.key_type,
                &entry.fingerprint_hex,
                sanitizeJsonStr(comment, entry.comment),
            },
        );
    }
    try out.appendSlice(allocator, "]}\n");
    return out.toOwnedSlice(allocator);
}

pub fn cmdAuth(client: *api.DiosixClient, args: []const [*:0]const u8) !void {
    const exe_name = common.getExeName();
    const sys_cfg = common.loadRuntimeSystemConfig();
    const allocator = std.heap.page_allocator;
    _ = client;
    if (args.len == 0) {
        printFmt(
            \\Usage:
            \\  {s} auth status [--json]            Display passkey posture
            \\  {s} auth list [--json]              List enrolled passkeys
            \\  {s} auth enroll [options] [--json]  Enroll passkey or token
            \\      [--key <pubkey>|--file <path>|--tpm|--fido2|--qr]
            \\      [--label <name>]
            \\  {s} auth challenge [--json]         Generate 256-bit nonce
            \\  {s} auth verify <sig-hex> [options] Verify Ed25519 signature
            \\      [--challenge <str>] [--json]
            \\
        , .{ exe_name, exe_name, exe_name, exe_name, exe_name });
        return;
    }

    const subcmd = std.mem.span(args[0]);
    var json_mode = false;
    for (args[1..]) |arg| {
        if (common.isJsonFlag(std.mem.span(arg))) {
            json_mode = true;
        }
    }

    _ = linux.mkdir(sysconfig.VAR_LIB_DIOSIX_DIR, 0o755);
    var keys_dir_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    if (common.toPathZ(sys_cfg.keysDir(), &keys_dir_z_buf)) |kdz| {
        _ = linux.mkdir(kdz.ptr, 0o700);
    } else {
        printStr("Error: Keys directory path too long.\n");
        return;
    }
    _ = linux.mkdir(sysconfig.RUN_DIOSIX_DIR, 0o755);
    _ = linux.mkdir(sysconfig.ROOT_SSH_DIR, 0o700);

    const auth_pk_path = try allocator.print(
        "{s}/authorized_passkeys",
        .{sys_cfg.keysDir()},
    );
    defer allocator.free(auth_pk_path);

    var pk_mapped: ?[]u8 = null;
    defer if (pk_mapped) |m| unmapBinaryFile(m);
    var entries: [passkey.MAX_PASSKEYS]passkey.PasskeyEntry = undefined;
    var entry_count: usize = 0;
    if (readBinaryFile(auth_pk_path, MAX_AUTHORIZED_PASSKEYS_BYTES)) |content| {
        pk_mapped = content;
        entry_count = passkey.parseAuthorizedPasskeys(content, &entries);
    } else |_| {}

    const seat_profile = detectSeatProfile();
    const boot_mode = detectBootMode();
    const has_fido2 =
        fileExistsPath(sysconfig.DEV_HIDRAW0_PATH) or
        fileExistsPath(sysconfig.DEV_HIDRAW1_PATH);
    const has_tpm2 =
        fileExistsPath(sysconfig.DEV_TPMRM0_PATH) or
        fileExistsPath(sysconfig.DEV_TPM0_PATH);

    const cmd = std.meta.stringToEnum(AuthSubcommand, subcmd) orelse {
        printFmt(
            "Error: Unknown auth subcommand '{s}'. Use '{s} auth' for usage.\n",
            .{ subcmd, exe_name },
        );
        return;
    };

    switch (cmd) {
        .status => {
            if (json_mode) {
                printFmt(
                    "{{\"password_login\":\"disabled\"," ++
                        "\"boot_mode\":\"{s}\",\"seat_profile\":\"{s}\"," ++
                        "\"fido2_token\":{s},\"tpm2_available\":{s}," ++
                        "\"enrolled_passkeys\":{d}}}\n",
                    .{
                        boot_mode,
                        seat_profile,
                        if (has_fido2) "true" else "false",
                        if (has_tpm2) "true" else "false",
                        entry_count,
                    },
                );
            } else {
                const fido_str = if (has_fido2)
                    "detected (/dev/hidraw0)"
                else
                    "not connected";
                const tpm_str = if (has_tpm2)
                    "available (/dev/tpmrm0)"
                else
                    "not detected";
                printFmt(
                    \\Password login   : disabled (passkey-only)
                    \\Boot mode        : {s}
                    \\Seat profile     : {s}
                    \\FIDO2 USB token  : {s}
                    \\Platform TPM 2.0 : {s}
                    \\Enrolled keys    : {d} passkey(s)
                    \\
                , .{
                    boot_mode, seat_profile, fido_str, tpm_str, entry_count,
                });
            }
        },
        .list, .ls => {
            if (json_mode) {
                const json = try passkeyListJson(
                    allocator,
                    entries[0..entry_count],
                );
                defer allocator.free(json);
                printStr(json);
                return;
            }

            printStr(
                "ID   Kind            Key type                           " ++
                    "Fingerprint       Comment\n",
            );
            printStr(
                "-------------------------------------------------------" ++
                    "----------------------------------------\n",
            );
            if (entry_count == 0) {
                printStr(
                    "(No passkeys enrolled in " ++
                        "/var/lib/diosix/keys/authorized_passkeys)\n",
                );
                return;
            }
            for (entries[0..entry_count], 0..) |entry, idx| {
                const cmt = if (entry.comment.len > 0) entry.comment else "-";
                printFmt(
                    "{d:<4} {s:<15} {s:<34} {s:<17} {s}\n",
                    .{
                        idx + 1,
                        entry.kind.label(),
                        entry.key_type,
                        &entry.fingerprint_hex,
                        cmt,
                    },
                );
            }
        },
        .challenge => {
            var nonce_bytes: [passkey.CHALLENGE_BYTES]u8 = undefined;
            try generateEntropyBytes(&nonce_bytes);
            defer std.crypto.secureZero(u8, &nonce_bytes);
            var nonce_hex_buf: [passkey.CHALLENGE_HEX_LEN]u8 = undefined;
            const nonce_hex = passkey.bytesToHex(&nonce_bytes, &nonce_hex_buf);

            const chal_str = try allocator.print(
                "diosix-challenge:{s}",
                .{nonce_hex},
            );
            defer allocator.free(chal_str);
            try writeFile(passkey.CHALLENGE_STATE_PATH, chal_str);

            if (json_mode) {
                printFmt(
                    "{{\"challenge\":\"{s}\",\"nonce\":\"{s}\"}}\n",
                    .{ chal_str, nonce_hex },
                );
            } else {
                printFmt("Challenge : {s}\n", .{chal_str});
            }
        },
        .enroll => try cmdAuthEnroll(args, seat_profile, json_mode),
        .verify => {
            if (args.len < 2) {
                printStr(
                    "Usage: dsx auth verify <signature-hex> " ++
                        "[--challenge <challenge-str>] [--json]\n",
                );
                return;
            }
            const sig_hex = std.mem.span(args[1]);
            var challenge_override: ?[]const u8 = null;
            var idx: usize = 2;
            while (idx < args.len) : (idx += 1) {
                const span = std.mem.span(args[idx]);
                if (std.meta.stringToEnum(AuthVerifyOption, span)) |opt| {
                    switch (opt) {
                        .@"--challenge", .@"-c" => if (idx + 1 < args.len) {
                            idx += 1;
                            challenge_override = std.mem.span(args[idx]);
                        },
                        .@"--json", .@"-j" => json_mode = true,
                    }
                }
            }

            var chal_mapped: ?[]u8 = null;
            defer if (chal_mapped) |m| unmapBinaryFile(m);
            const active_challenge: []const u8 = if (challenge_override) |co|
                co
            else blk: {
                if (readBinaryFile(
                    passkey.CHALLENGE_STATE_PATH,
                    MAX_CHALLENGE_STATE_BYTES,
                )) |cb| {
                    chal_mapped = cb;
                    break :blk trimWhitespace(cb);
                } else |_| {
                    printStr(
                        "Error: No active challenge found. Run " ++
                            "'dsx auth challenge' or pass '--challenge'.\n",
                    );
                    return;
                }
            };

            if (challenge_override == null) {
                _ = linux.unlink(passkey.CHALLENGE_STATE_PATH);
            }

            if (passkey.verifyChallengeSignature(
                entries[0..entry_count],
                active_challenge,
                sig_hex,
            )) |match_idx| {
                const matched = entries[match_idx];
                if (json_mode) {
                    printFmt(
                        "{{\"verified\":true,\"fingerprint\":\"{s}\"," ++
                            "\"kind\":\"{s}\"}}\n",
                        .{ &matched.fingerprint_hex, matched.kind.label() },
                    );
                } else {
                    printFmt(
                        "✓ Passkey signature verified ({s}, " ++
                            "fingerprint {s})\n",
                        .{ matched.kind.label(), &matched.fingerprint_hex },
                    );
                }
            } else {
                const fail_msg = if (json_mode)
                    "{\"verified\":false}\n"
                else
                    "Error: Passkey signature verification failed.\n";
                printStr(fail_msg);
            }
        },
    }
}

test "auth_cmd: subcommand and option enums parse cleanly" {
    std.testing.refAllDecls(@This());
    _ = enroll;
    try std.testing.expectEqual(
        AuthSubcommand.enroll,
        std.meta.stringToEnum(AuthSubcommand, "enroll").?,
    );
    try std.testing.expectEqual(
        AuthEnrollOption.@"--tpm",
        std.meta.stringToEnum(AuthEnrollOption, "--tpm").?,
    );
}

test "auth_cmd: passkeyListJson sanitizes and never truncates" {
    const allocator = std.testing.allocator;
    const long_comment: [300]u8 = @splat('c');
    const comment = long_comment ++ "\"\\";
    const entry = passkey.PasskeyEntry{
        .kind = .ssh_ed25519,
        .key_type = "ssh-ed25519",
        .base64_blob = "",
        .comment = comment,
        .ed25519_pubkey = null,
        .fingerprint_hex = "0123456789abcdef".*,
    };
    const entries = [_]passkey.PasskeyEntry{ entry, entry };
    const json = try passkeyListJson(allocator, &entries);
    defer allocator.free(json);
    const expected = try allocator.print(
        "{{\"passkeys\":[" ++
            "{{\"index\":1,\"kind\":\"ssh-ed25519\"," ++
            "\"key_type\":\"ssh-ed25519\"," ++
            "\"fingerprint\":\"0123456789abcdef\"," ++
            "\"comment\":\"{s}\"}}," ++
            "{{\"index\":2,\"kind\":\"ssh-ed25519\"," ++
            "\"key_type\":\"ssh-ed25519\"," ++
            "\"fingerprint\":\"0123456789abcdef\"," ++
            "\"comment\":\"{s}\"}}]}}\n",
        .{ &long_comment, &long_comment },
    );
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, json);
}
