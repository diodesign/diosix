// Diosix Zero-Password Passkey Authentication CLI (dsx auth).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const api = @import("api.zig");
const passkey = @import("passkey.zig");
const common = @import("common.zig");
const enroll = @import("auth/enroll.zig");

pub const AuthEnrollOption = enroll.AuthEnrollOption;
pub const cmdAuthEnroll = enroll.cmdAuthEnroll;

const printStr = common.printStr;
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

pub fn cmdAuth(client: *api.DiosixClient, args: []const [*:0]const u8) !void {
    const exe_name = common.getExeName();
    const sys_cfg = common.loadRuntimeSystemConfig();
    _ = client;
    if (args.len == 0) {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
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
        , .{ exe_name, exe_name, exe_name, exe_name, exe_name }) catch return;
        printStr(msg);
        return;
    }

    const subcmd = std.mem.span(args[0]);
    var json_mode = false;
    for (args[1..]) |arg| {
        if (common.isJsonFlag(std.mem.span(arg))) {
            json_mode = true;
        }
    }

    _ = linux.mkdir("/var/lib/diosix", 0o755);
    var keys_dir_z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    if (common.toPathZ(sys_cfg.keysDir(), &keys_dir_z_buf)) |kdz| {
        _ = linux.mkdir(kdz.ptr, 0o700);
    }
    _ = linux.mkdir("/run/diosix", 0o755);
    _ = linux.mkdir("/root/.ssh", 0o700);

    var auth_pk_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const auth_pk_path = std.fmt.bufPrint(
        &auth_pk_buf,
        "{s}/authorized_passkeys",
        .{sys_cfg.keysDir()},
    ) catch passkey.AUTHORIZED_PASSKEYS_PATH;

    var pk_mapped: ?[]u8 = null;
    defer if (pk_mapped) |m| unmapBinaryFile(m);
    var entries: [passkey.MAX_PASSKEYS]passkey.PasskeyEntry = undefined;
    var entry_count: usize = 0;
    if (readBinaryFile(auth_pk_path, 65536)) |content| {
        pk_mapped = content;
        entry_count = passkey.parseAuthorizedPasskeys(content, &entries);
    } else |_| {}

    const seat_profile = detectSeatProfile();
    const boot_mode = detectBootMode();
    const has_fido2 =
        fileExistsPath("/dev/hidraw0") or fileExistsPath("/dev/hidraw1");
    const has_tpm2 =
        fileExistsPath("/dev/tpmrm0") or fileExistsPath("/dev/tpm0");

    const cmd = std.meta.stringToEnum(AuthSubcommand, subcmd) orelse {
        var err_buf: [128]u8 = undefined;
        const err_msg = std.fmt.bufPrint(
            &err_buf,
            "Error: Unknown auth subcommand '{s}'. Use '{s} auth' for usage.\n",
            .{ subcmd, exe_name },
        ) catch "Error: Unknown auth subcommand.\n";
        printStr(err_msg);
        return;
    };

    switch (cmd) {
        .status => {
            if (json_mode) {
                var jbuf: [512]u8 = undefined;
                const jfmt =
                    "{{\"password_login\":\"disabled\"," ++
                    "\"boot_mode\":\"{s}\",\"seat_profile\":\"{s}\"," ++
                    "\"fido2_token\":{s},\"tpm2_available\":{s}," ++
                    "\"enrolled_passkeys\":{d}}}\n";
                const jout = std.fmt.bufPrint(&jbuf, jfmt, .{
                    boot_mode,
                    seat_profile,
                    if (has_fido2) "true" else "false",
                    if (has_tpm2) "true" else "false",
                    entry_count,
                }) catch return;
                printStr(jout);
            } else {
                var buf: [512]u8 = undefined;
                const fido_str = if (has_fido2)
                    "detected (/dev/hidraw0)"
                else
                    "not connected";
                const tpm_str = if (has_tpm2)
                    "available (/dev/tpmrm0)"
                else
                    "not detected";
                const out = std.fmt.bufPrint(&buf,
                    \\Password login   : disabled (passkey-only)
                    \\Boot mode        : {s}
                    \\Seat profile     : {s}
                    \\FIDO2 USB token  : {s}
                    \\Platform TPM 2.0 : {s}
                    \\Enrolled keys    : {d} passkey(s)
                    \\
                , .{
                    boot_mode, seat_profile, fido_str, tpm_str, entry_count,
                }) catch return;
                printStr(out);
            }
        },
        .list, .ls => {
            if (json_mode) {
                var jbuf: [4096]u8 = undefined;
                var pos: usize = 0;
                const prefix = "{\"passkeys\":[";
                @memcpy(jbuf[0..prefix.len], prefix);
                pos += prefix.len;
                for (entries[0..entry_count], 0..) |entry, idx| {
                    const sep: []const u8 = if (idx > 0) "," else "";
                    var c_buf: [128]u8 = undefined;
                    const ifmt =
                        "{s}{{\"index\":{d},\"kind\":\"{s}\"," ++
                        "\"key_type\":\"{s}\",\"fingerprint\":\"{s}\"," ++
                        "\"comment\":\"{s}\"}}";
                    const item = std.fmt.bufPrint(jbuf[pos..], ifmt, .{
                        sep,
                        idx + 1,
                        entry.kind.label(),
                        entry.key_type,
                        &entry.fingerprint_hex,
                        sanitizeJsonStr(&c_buf, entry.comment),
                    }) catch break;
                    pos += item.len;
                }
                const suffix = "]}\n";
                if (pos + suffix.len <= jbuf.len) {
                    @memcpy(jbuf[pos .. pos + suffix.len], suffix);
                    pos += suffix.len;
                }
                printStr(jbuf[0..pos]);
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
                var line_buf: [256]u8 = undefined;
                const lfmt = "{d:<4} {s:<15} {s:<34} {s:<17} {s}\n";
                const cmt = if (entry.comment.len > 0) entry.comment else "-";
                const line = std.fmt.bufPrint(&line_buf, lfmt, .{
                    idx + 1,
                    entry.kind.label(),
                    entry.key_type,
                    &entry.fingerprint_hex,
                    cmt,
                }) catch continue;
                printStr(line);
            }
        },
        .challenge => {
            var nonce_bytes: [passkey.CHALLENGE_BYTES]u8 = undefined;
            try generateEntropyBytes(&nonce_bytes);
            defer std.crypto.secureZero(u8, &nonce_bytes);
            var nonce_hex_buf: [passkey.CHALLENGE_HEX_LEN]u8 = undefined;
            const nonce_hex = passkey.bytesToHex(&nonce_bytes, &nonce_hex_buf);

            var chal_buf: [128]u8 = undefined;
            const cfmt = "diosix-challenge:{s}";
            const chal_str = std.fmt.bufPrint(
                &chal_buf,
                cfmt,
                .{nonce_hex},
            ) catch return;
            try writeFile(passkey.CHALLENGE_STATE_PATH, chal_str);

            var out_buf: [256]u8 = undefined;
            const out = if (json_mode)
                std.fmt.bufPrint(
                    &out_buf,
                    "{{\"challenge\":\"{s}\",\"nonce\":\"{s}\"}}\n",
                    .{ chal_str, nonce_hex },
                ) catch return
            else
                std.fmt.bufPrint(
                    &out_buf,
                    "Challenge : {s}\n",
                    .{chal_str},
                ) catch return;
            printStr(out);
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
                if (readBinaryFile(passkey.CHALLENGE_STATE_PATH, 512)) |cb| {
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
                var out_buf: [256]u8 = undefined;
                const out = if (json_mode)
                    std.fmt.bufPrint(
                        &out_buf,
                        "{{\"verified\":true,\"fingerprint\":\"{s}\"," ++
                            "\"kind\":\"{s}\"}}\n",
                        .{ &matched.fingerprint_hex, matched.kind.label() },
                    ) catch return
                else
                    std.fmt.bufPrint(
                        &out_buf,
                        "✓ Passkey signature verified ({s}, " ++
                            "fingerprint {s})\n",
                        .{ matched.kind.label(), &matched.fingerprint_hex },
                    ) catch return;
                printStr(out);
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
