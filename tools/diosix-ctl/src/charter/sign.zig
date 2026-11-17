// Diosix Charter Keygen, Ed25519 Signing, and Signature Verification CLI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../api.zig");
const charter = @import("../charter.zig");
const common = @import("../common.zig");
const passkey = @import("../passkey.zig");
const sysconfig = @import("../sysconfig.zig");
const amend = @import("amend.zig");
const crypto = @import("crypto.zig");

const KeygenOption = enum {
    @"--priv",
    @"-p",
    @"--pub",
    @"--json",
    @"-j",
};

const SignOption = enum {
    @"--file",
    @"-f",
    @"--key",
    @"-k",
    @"--rotate-from",
    @"--out",
    @"-o",
    @"--json",
    @"-j",
};

const VerifyOption = enum {
    @"--file",
    @"-f",
    @"--against",
    @"--pubkey",
    @"--json",
    @"-j",
};

pub fn cmdCharterKeygen(
    args: []const [*:0]const u8,
    arg_start: usize,
    json_mode: bool,
) void {
    var priv_path: []const u8 = sysconfig.PRINCIPAL_PRIVKEY_PATH;
    var pub_path: []const u8 = sysconfig.PRINCIPAL_PUBKEY_PATH;
    var json_f = json_mode;
    var i: usize = arg_start;
    while (i < args.len) : (i += 1) {
        const s = std.mem.span(args[i]);
        const opt = std.meta.stringToEnum(KeygenOption, s) orelse continue;
        switch (opt) {
            .@"--priv", .@"-p" => if (i + 1 < args.len) {
                i += 1;
                priv_path = std.mem.span(args[i]);
            },
            .@"--pub" => if (i + 1 < args.len) {
                i += 1;
                pub_path = std.mem.span(args[i]);
            },
            .@"--json", .@"-j" => json_f = true,
        }
    }
    const pk = crypto.generatePrincipalKeypair(priv_path, pub_path) catch |e| {
        common.printApiError("Generate Principal Ed25519 keypair", e);
        return;
    };
    var pk_hex: [crypto.PUBKEY_HEX_LEN]u8 = undefined;
    _ = common.bytesToHex(&pk, &pk_hex);
    if (json_f) {
        common.printFmt(
            "{{\"status\":\"generated\",\"priv\":\"{s}\"," ++
                "\"pub\":\"{s}\",\"pubkey_hex\":\"{s}\"}}\n",
            .{ priv_path, pub_path, &pk_hex },
        );
    } else {
        common.printFmt(
            "✓ Generated Principal Ed25519 keypair:\n" ++
                "  Private seed : {s} (mode 0600)\n" ++
                "  Public key   : {s} ({s})\n",
            .{ priv_path, pub_path, &pk_hex },
        );
    }
}

pub fn cmdCharterSign(
    args: []const [*:0]const u8,
    arg_start: usize,
    default_file: []const u8,
    json_mode: bool,
) void {
    const alloc = std.heap.page_allocator;
    var file_path = default_file;
    var key_path: []const u8 = sysconfig.PRINCIPAL_PRIVKEY_PATH;
    var rotate_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var json_f = json_mode;
    var i: usize = arg_start;
    while (i < args.len) : (i += 1) {
        const s = std.mem.span(args[i]);
        const opt = std.meta.stringToEnum(SignOption, s) orelse continue;
        switch (opt) {
            .@"--file", .@"-f" => if (i + 1 < args.len) {
                i += 1;
                file_path = std.mem.span(args[i]);
            },
            .@"--key", .@"-k" => if (i + 1 < args.len) {
                i += 1;
                key_path = std.mem.span(args[i]);
            },
            .@"--rotate-from" => if (i + 1 < args.len) {
                i += 1;
                rotate_path = std.mem.span(args[i]);
            },
            .@"--out", .@"-o" => if (i + 1 < args.len) {
                i += 1;
                out_path = std.mem.span(args[i]);
            },
            .@"--json", .@"-j" => json_f = true,
        }
    }

    const content = common.readBinaryFile(
        file_path,
        common.MAX_MANIFEST_SIZE,
    ) catch |e| {
        common.printApiError("Read Charter TOML", e);
        return;
    };
    defer common.unmapBinaryFile(content);

    const key_raw = common.readBinaryFile(key_path, 4096) catch |e| {
        common.printApiError("Read Principal private seed", e);
        return;
    };
    defer common.unmapBinaryFile(key_raw);

    const old_raw = if (rotate_path) |rp|
        common.readBinaryFile(rp, 4096) catch |e| {
            common.printApiError("Read previous Principal seed", e);
            return;
        }
    else
        null;
    defer if (old_raw) |oraw| common.unmapBinaryFile(oraw);

    const signed = crypto.signCharterContent(
        alloc,
        content,
        key_raw,
        old_raw,
    ) catch |e| {
        common.printApiError("Sign Charter TOML", e);
        return;
    };
    defer alloc.free(signed);

    const dest = out_path orelse file_path;
    common.writeFile(dest, signed) catch |e| {
        common.printApiError("Write signed Charter TOML", e);
        return;
    };
    const parsed = charter.parseCharterToml(signed) catch return;
    if (json_f) {
        common.printFmt(
            "{{\"status\":\"signed\",\"file\":\"{s}\"," ++
                "\"version\":{d},\"sha256\":\"{s}\"}}\n",
            .{ dest, parsed.version, &parsed.sha256_hex },
        );
    } else {
        common.printFmt(
            "✓ Signed Charter '{s}' v{d} -> {s} (SHA-256: {s}).\n",
            .{ parsed.id(), parsed.version, dest, &parsed.sha256_hex },
        );
    }
}

pub fn cmdCharterVerify(
    args: []const [*:0]const u8,
    arg_start: usize,
    default_file: []const u8,
    json_mode: bool,
) void {
    var file_path = default_file;
    var against_path: ?[]const u8 = null;
    var pub_override: ?[api.MISSION_PUBKEY_LEN]u8 = null;
    var json_f = json_mode;
    var i: usize = arg_start;
    while (i < args.len) : (i += 1) {
        const s = std.mem.span(args[i]);
        const opt = std.meta.stringToEnum(VerifyOption, s) orelse continue;
        switch (opt) {
            .@"--file", .@"-f" => if (i + 1 < args.len) {
                i += 1;
                file_path = std.mem.span(args[i]);
            },
            .@"--against" => if (i + 1 < args.len) {
                i += 1;
                against_path = std.mem.span(args[i]);
            },
            .@"--pubkey" => if (i + 1 < args.len) {
                i += 1;
                var pk: [api.MISSION_PUBKEY_LEN]u8 = undefined;
                if (passkey.hexToBytes(std.mem.span(args[i]), &pk)) |d| {
                    if (d.len == api.MISSION_PUBKEY_LEN) pub_override = pk;
                }
            },
            .@"--json", .@"-j" => json_f = true,
        }
    }
    const content = common.readBinaryFile(
        file_path,
        common.MAX_MANIFEST_SIZE,
    ) catch |e| {
        common.printApiError("Read Charter TOML", e);
        return;
    };
    defer common.unmapBinaryFile(content);
    const parsed = charter.parseCharterToml(content) catch {
        common.printStr("Error: Invalid Charter TOML.\n");
        return;
    };
    const sig_ok = crypto.verifyCharterSignature(&parsed, pub_override);
    var res = amend.AmendmentCheckResult{
        .allowed = sig_ok,
        .reason = if (sig_ok)
            "Valid Ed25519 signature"
        else
            "Invalid signature",
    };
    if (against_path) |ap| {
        const cur_raw = common.readBinaryFile(
            ap,
            common.MAX_MANIFEST_SIZE,
        ) catch |e| {
            common.printApiError("Read baseline Charter TOML", e);
            return;
        };
        defer common.unmapBinaryFile(cur_raw);
        const cur = charter.parseCharterToml(cur_raw) catch {
            common.printStr("Error: Invalid baseline Charter TOML.\n");
            return;
        };
        res = amend.verifyCharterAmendment(&cur, &parsed);
    }
    if (json_f) {
        const s_val = if (res.allowed) "true" else "false";
        common.printFmt(
            "{{\"signature_valid\":{},\"allowed\":{s}," ++
                "\"version\":{d},\"sha256\":\"{s}\",\"reason\":\"{s}\"}}\n",
            .{
                sig_ok,
                s_val,
                parsed.version,
                &parsed.sha256_hex,
                res.reason,
            },
        );
    } else {
        const mark = if (res.allowed) "✓" else "✗";
        common.printFmt("{s} Verify v{d}: {s}\n", .{
            mark,
            parsed.version,
            res.reason,
        });
    }
}

test "charter/sign: option enums parse CLI flags" {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(
        SignOption.@"--rotate-from",
        std.meta.stringToEnum(SignOption, "--rotate-from").?,
    );
    try std.testing.expectEqual(
        VerifyOption.@"--against",
        std.meta.stringToEnum(VerifyOption, "--against").?,
    );
}
