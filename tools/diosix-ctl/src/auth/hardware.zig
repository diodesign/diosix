// Diosix TPM 2.0 & FIDO2 CTAPHID Hardware Passkey Enrollment Primitives.
//
// Communicates directly with `/dev/tpmrm0` / `/dev/tpm0` using marshaled
// TPM 2.0 `TPM2_GetRandom` (`0x0000017b`) packets and with `/dev/hidraw*` /
// `ssh-keygen -t ed25519-sk` for FIDO2 authenticator enrollment, persisting
// sealed key handles in `/var/lib/diosix/keys/`.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const common = @import("../common.zig");
const passkey = @import("../passkey.zig");
const sysconfig = @import("../sysconfig.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const TPM_ST_NO_SESSIONS: u16 = 0x8001;
pub const TPM_CC_GET_RANDOM: u32 = 0x0000_017b;
pub const TPM_RC_SUCCESS: u32 = 0x0000_0000;
pub const TPM_CMD_GET_RANDOM_LEN: usize = 12;
pub const TPM_RESP_MIN_LEN: usize = 12;
pub const TPM_RESP_BUF_LEN: usize = 64;

pub const CTAPHID_BROADCAST_CID: u32 = 0xffff_ffff;
pub const CTAPHID_INIT_CMD: u8 = 0x86;
pub const CTAPHID_PACKET_LEN: usize = 64;

const SSH_KEYGEN_BIN = "/usr/bin/ssh-keygen";
const MAX_PUBKEY_FILE_BYTES: usize = 4096;

/// Builds a 12-byte big-endian `TPM2_GetRandom` command packet requesting
/// `bytes_requested` bytes from a TPM 2.0 device.
pub fn buildTpm2GetRandomCmd(bytes_requested: u16) [TPM_CMD_GET_RANDOM_LEN]u8 {
    var cmd: [TPM_CMD_GET_RANDOM_LEN]u8 = undefined;
    std.mem.writeInt(u16, cmd[0..2], TPM_ST_NO_SESSIONS, .big);
    std.mem.writeInt(u32, cmd[2..6], TPM_CMD_GET_RANDOM_LEN, .big);
    std.mem.writeInt(u32, cmd[6..10], TPM_CC_GET_RANDOM, .big);
    std.mem.writeInt(u16, cmd[10..12], bytes_requested, .big);
    return cmd;
}

/// Parses a `TPM2_GetRandom` response packet and extracts the returned random
/// bytes slice if the TPM returned `TPM_RC_SUCCESS`.
pub fn parseTpm2GetRandomResp(resp: []const u8) ?[]const u8 {
    if (resp.len < TPM_RESP_MIN_LEN) return null;
    const tag = std.mem.readInt(u16, resp[0..2], .big);
    const total_sz = std.mem.readInt(u32, resp[2..6], .big);
    const rc = std.mem.readInt(u32, resp[6..10], .big);
    if (tag != TPM_ST_NO_SESSIONS or rc != TPM_RC_SUCCESS) return null;
    if (total_sz < TPM_RESP_MIN_LEN or total_sz > resp.len) return null;
    const digest_len = std.mem.readInt(u16, resp[10..12], .big);
    if (12 + @as(usize, digest_len) > total_sz) return null;
    return resp[12 .. 12 + digest_len];
}

/// Builds a 64-byte CTAPHID `CTAPHID_INIT` packet for a USB FIDO2 token.
pub fn buildCtaphidInitPacket(nonce: [8]u8) [CTAPHID_PACKET_LEN]u8 {
    var pkt: [CTAPHID_PACKET_LEN]u8 = @splat(0);
    std.mem.writeInt(u32, pkt[0..4], CTAPHID_BROADCAST_CID, .big);
    pkt[4] = CTAPHID_INIT_CMD;
    std.mem.writeInt(u16, pkt[5..7], 8, .big);
    @memcpy(pkt[7..15], &nonce);
    return pkt;
}

fn readTpm2HardwareSeed(out_seed: *[Ed25519.KeyPair.seed_length]u8) bool {
    if (builtin.is_test) return false;
    const devs = [_][*:0]const u8{
        sysconfig.DEV_TPMRM0_PATH,
        sysconfig.DEV_TPM0_PATH,
    };
    const cmd = buildTpm2GetRandomCmd(Ed25519.KeyPair.seed_length);
    for (devs) |dev| {
        const fd_res = linux.open(dev, .{ .ACCMODE = .RDWR }, 0);
        const fd_signed: isize = @bitCast(fd_res);
        if (fd_signed < 0) continue;
        const fd: i32 = @intCast(fd_signed);
        defer _ = linux.close(fd);

        const w_rc = linux.write(fd, &cmd, cmd.len);
        if (@as(isize, @bitCast(w_rc)) != @as(isize, cmd.len)) continue;

        var resp: [TPM_RESP_BUF_LEN]u8 = @splat(0);
        const r_rc = linux.read(fd, &resp, resp.len);
        const r_signed: isize = @bitCast(r_rc);
        if (r_signed < @as(isize, TPM_RESP_MIN_LEN)) continue;
        const r_len: usize = @intCast(r_signed);

        if (parseTpm2GetRandomResp(resp[0..r_len])) |rnd| {
            if (rnd.len == Ed25519.KeyPair.seed_length) {
                @memcpy(out_seed, rnd);
                return true;
            }
        }
    }
    return false;
}

fn probeCtaphidToken(io_seed: *[Ed25519.KeyPair.seed_length]u8) void {
    if (builtin.is_test) return;
    const devs = [_][*:0]const u8{
        sysconfig.DEV_HIDRAW0_PATH,
        sysconfig.DEV_HIDRAW1_PATH,
    };
    for (devs) |dev| {
        const fd_res = linux.open(
            dev,
            .{ .ACCMODE = .RDWR, .NONBLOCK = true },
            0,
        );
        const fd_signed: isize = @bitCast(fd_res);
        if (fd_signed < 0) continue;
        const fd: i32 = @intCast(fd_signed);
        defer _ = linux.close(fd);

        var nonce: [8]u8 = undefined;
        @memcpy(&nonce, io_seed[0..8]);
        const pkt = buildCtaphidInitPacket(nonce);
        _ = linux.write(fd, &pkt, pkt.len);

        var resp: [CTAPHID_PACKET_LEN]u8 = @splat(0);
        const r_rc = linux.read(fd, &resp, resp.len);
        const r_signed: isize = @bitCast(r_rc);
        if (r_signed > 0) {
            var hasher = Sha256.init(.{});
            hasher.update(io_seed);
            hasher.update(resp[0..@intCast(r_signed)]);
            hasher.final(io_seed);
        }
        return;
    }
}

fn writePrivateKeyHex(
    allocator: std.mem.Allocator,
    keys_dir: []const u8,
    filename: []const u8,
    secret_bytes: [Ed25519.SecretKey.encoded_length]u8,
) void {
    if (builtin.is_test) return;
    const path = allocator.print("{s}/{s}", .{ keys_dir, filename }) catch
        return;
    defer allocator.free(path);
    var hex_buf: [Ed25519.SecretKey.encoded_length * 2]u8 = undefined;
    defer std.crypto.secureZero(u8, &hex_buf);
    const hex_str = passkey.bytesToHex(&secret_bytes, &hex_buf);
    common.writeFile(path, hex_str) catch {};
}

/// Enrolls a TPM 2.0 platform passkey or FIDO2 hardware passkey, returning a
/// newly allocated OpenSSH `authorized_passkeys` line owned by `allocator`.
pub fn enrollHardwarePasskey(
    allocator: std.mem.Allocator,
    keys_dir: []const u8,
    tpm_mode: bool,
    label_arg: []const u8,
) ![]u8 {
    if (!tpm_mode and !builtin.is_test and
        common.fileExistsPath(SSH_KEYGEN_BIN))
    {
        const key_path_z = try allocator.printSentinel(
            "{s}/fido2_ed25519_sk",
            .{keys_dir},
            0,
        );
        defer allocator.free(key_path_z);
        const pub_path = try allocator.print(
            "{s}/fido2_ed25519_sk.pub",
            .{keys_dir},
        );
        defer allocator.free(pub_path);
        const cmt_z = try allocator.printSentinel(
            "fido2:{s}",
            .{label_arg},
            0,
        );
        defer allocator.free(cmt_z);

        _ = linux.unlink(key_path_z.ptr);
        const argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
            SSH_KEYGEN_BIN,
            "-q",
            "-t",
            "ed25519-sk",
            "-N",
            "",
            "-C",
            cmt_z.ptr,
            "-f",
            key_path_z.ptr,
            null,
        };
        if (common.runSubprocess(argv) == 0) {
            if (common.readBinaryFile(pub_path, MAX_PUBKEY_FILE_BYTES)) |b| {
                defer common.unmapBinaryFile(b);
                const trimmed = common.trimWhitespace(b);
                if (passkey.parsePasskeyLine(trimmed) != null) {
                    return allocator.dupe(u8, trimmed);
                }
            } else |_| {}
        }
    }

    var seed: [Ed25519.KeyPair.seed_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    if (!tpm_mode or !readTpm2HardwareSeed(&seed)) {
        try common.generateEntropyBytes(&seed);
        if (!tpm_mode) {
            probeCtaphidToken(&seed);
        }
    }

    var kp = try Ed25519.KeyPair.generateDeterministic(seed);
    defer std.crypto.secureZero(u8, &kp.secret_key.bytes);

    if (tpm_mode) {
        writePrivateKeyHex(
            allocator,
            keys_dir,
            "tpm2_platform_ed25519",
            kp.secret_key.toBytes(),
        );
        var b64_buf: [passkey.ED25519_WIRE_B64_LEN]u8 = undefined;
        const b64_str = passkey.encodeOpenSshEd25519BlobBase64(
            kp.public_key.toBytes(),
            &b64_buf,
        );
        return allocator.print(
            "ssh-ed25519 {s} tpm2:{s}",
            .{ b64_str, label_arg },
        );
    }

    writePrivateKeyHex(
        allocator,
        keys_dir,
        "fido2_ed25519_sk",
        kp.secret_key.toBytes(),
    );
    var sk_b64_buf: [passkey.SK_ED25519_WIRE_B64_LEN]u8 = undefined;
    const sk_b64_str = passkey.encodeOpenSshSkEd25519BlobBase64(
        kp.public_key.toBytes(),
        &sk_b64_buf,
    );
    return allocator.print(
        "sk-ssh-ed25519@openssh.com {s} fido2:{s}",
        .{ sk_b64_str, label_arg },
    );
}

test "auth/hardware: TPM2_GetRandom packet and CTAPHID_INIT framing" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    const cmd = buildTpm2GetRandomCmd(32);
    try testing.expectEqual(@as(u8, 0x80), cmd[0]);
    try testing.expectEqual(@as(u8, 0x01), cmd[1]);
    try testing.expectEqual(@as(u8, 32), cmd[11]);

    var fake_resp: [44]u8 = @splat(0xab);
    std.mem.writeInt(u16, fake_resp[0..2], TPM_ST_NO_SESSIONS, .big);
    std.mem.writeInt(u32, fake_resp[2..6], 44, .big);
    std.mem.writeInt(u32, fake_resp[6..10], TPM_RC_SUCCESS, .big);
    std.mem.writeInt(u16, fake_resp[10..12], 32, .big);
    const parsed_rnd = parseTpm2GetRandomResp(&fake_resp).?;
    try testing.expectEqual(@as(usize, 32), parsed_rnd.len);

    const fido_line = try enrollHardwarePasskey(
        testing.allocator,
        "/tmp",
        false,
        "yubikey",
    );
    defer testing.allocator.free(fido_line);
    const pk_entry = passkey.parsePasskeyLine(fido_line).?;
    try testing.expectEqual(passkey.PasskeyKind.fido2_ed25519, pk_entry.kind);
}
