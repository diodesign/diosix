// Shared SBI Constitutional Charter and Mission Governance ABI definitions.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const CHARTER_HASH_LEN: usize = 32;
pub const MISSION_PUBKEY_LEN: usize = 32;
pub const MISSION_SIG_LEN: usize = 64;
pub const MISSION_SIGN_DOMAIN = "diosix-mission-v1:";
pub const MISSION_SIGN_MSG_LEN: usize = MISSION_SIGN_DOMAIN.len +
    CHARTER_HASH_LEN + MISSION_PUBKEY_LEN + 4 + 4 + 1 + 1;

pub const CharterArgs = extern struct {
    charter_hash: [CHARTER_HASH_LEN]u8 = @splat(0),
    quorum_required: u16 = 2,
    quorum_total: u16 = 3,
    standby_replicas: u16 = 1,
    is_sealed: u8 = 0,
    _reserved: u8 = 0,
    ratified_mask: u64 = 0,
    approved_target_cid: u64 = 0,
    failover_epoch: u64 = 0,
};

pub const MissionFlags = struct {
    pub const PROTECT_REPLICAS: u32 = 1 << 0;
    pub const FORBID_UNRATIFIED_ENCRYPT: u32 = 1 << 1;
    pub const DESTRUCTIVE_ENCRYPT: u32 = 1 << 2;
    pub const DESTRUCTIVE_WIPE: u32 = 1 << 3;
};

pub const MissionArgs = extern struct {
    charter_hash: [CHARTER_HASH_LEN]u8 = @splat(0),
    principal_pubkey: [MISSION_PUBKEY_LEN]u8 = @splat(0),
    signature: [MISSION_SIG_LEN]u8 = @splat(0),
    version: u32 = 1,
    min_total_replicas: u32 = 0,
    flags: u32 = 0,
    stake_quorum_pct: u8 = 67,
    max_stepdown_pct: u8 = 33,
    is_sealed: u8 = 0,
    has_pubkey: u8 = 0,
    eligible_stake_pages: u64 = 0,
    approved_stake_pages: u64 = 0,
    rejected_stake_pages: u64 = 0,
    voter_count: u32 = 0,
    _reserved: u32 = 0,
};

pub const MissionVoteDecision = enum(u8) {
    none = 0,
    approve = 1,
    reject = 2,
};

pub const MissionVoteArgs = extern struct {
    proposal_hash: [CHARTER_HASH_LEN]u8 = @splat(0),
    decision: u8 = @backingInt(MissionVoteDecision.approve),
    _reserved: [7]u8 = @splat(0),
    caller_stake_pages: u64 = 0,
    eligible_stake_pages: u64 = 0,
    approved_stake_pages: u64 = 0,
    rejected_stake_pages: u64 = 0,
};

/// Build the canonical 92-byte preimage signed by the Principal Ed25519 key.
pub fn buildMissionSignMessage(
    args: *const MissionArgs,
) [MISSION_SIGN_MSG_LEN]u8 {
    var msg: [MISSION_SIGN_MSG_LEN]u8 = @splat(0);
    @memcpy(msg[0..MISSION_SIGN_DOMAIN.len], MISSION_SIGN_DOMAIN);
    const h_off = MISSION_SIGN_DOMAIN.len;
    @memcpy(msg[h_off .. h_off + CHARTER_HASH_LEN], &args.charter_hash);
    const pk_off = h_off + CHARTER_HASH_LEN;
    @memcpy(
        msg[pk_off .. pk_off + MISSION_PUBKEY_LEN],
        &args.principal_pubkey,
    );
    const v_off = pk_off + MISSION_PUBKEY_LEN;
    std.mem.writeInt(u32, msg[v_off..][0..4], args.version, .little);
    std.mem.writeInt(
        u32,
        msg[v_off + 4 ..][0..4],
        args.min_total_replicas,
        .little,
    );
    msg[v_off + 8] = args.stake_quorum_pct;
    msg[v_off + 9] = @truncate(args.flags);
    return msg;
}

comptime {
    std.debug.assert(MISSION_SIGN_MSG_LEN == 92);
    std.debug.assert(@sizeOf(CharterArgs) == 64);
    std.debug.assert(@sizeOf(MissionArgs) == 176);
    std.debug.assert(@sizeOf(MissionVoteArgs) == 72);
}

test "sbi/governance: ABI sizes and canonical signing preimage" {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(CharterArgs));
    try std.testing.expectEqual(@as(usize, 176), @sizeOf(MissionArgs));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(MissionVoteArgs));
    var args = MissionArgs{
        .version = 7,
        .min_total_replicas = 3,
        .stake_quorum_pct = 67,
        .flags = MissionFlags.PROTECT_REPLICAS |
            MissionFlags.DESTRUCTIVE_ENCRYPT,
    };
    @memset(&args.charter_hash, 0xaa);
    @memset(&args.principal_pubkey, 0xbb);
    const msg = buildMissionSignMessage(&args);
    try std.testing.expectEqualStrings(MISSION_SIGN_DOMAIN, msg[0..18]);
    try std.testing.expectEqual(@as(u8, 7), msg[82]);
    try std.testing.expectEqual(@as(u8, 3), msg[86]);
    try std.testing.expectEqual(@as(u8, 67), msg[90]);
    try std.testing.expectEqual(@as(u8, 0x05), msg[91]);
}
