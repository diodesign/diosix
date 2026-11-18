// Conserved Physical Quota-Stake Tally & Ed25519 Mission Verification.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const guest = @import("../../guest.zig");
const interface = @import("interface").sbi;

const Ed25519 = std.crypto.sign.Ed25519;
const Guest = guest.Guest;

pub const MAX_MISSION_TREE_DEPTH: usize = 16;
const MAX_MISSION_TREE_NODES: usize = 256;

pub const MissionState = struct {
    sealed: bool = false,
    has_pubkey: bool = false,
    charter_hash: [interface.CHARTER_HASH_LEN]u8 = @splat(0),
    principal_pubkey: [interface.MISSION_PUBKEY_LEN]u8 = @splat(0),
    version: u32 = 1,
    min_total_replicas: u32 = 0,
    flags: u32 = 0,
    stake_quorum_pct: u8 = 67,
    max_stepdown_pct: u8 = 33,
    pending_hash: [interface.CHARTER_HASH_LEN]u8 = @splat(0),
    proposal_cutoff_guest_id: usize = 0,
};

pub const TallyResult = struct {
    eligible_stake_pages: u64 = 0,
    approved_stake_pages: u64 = 0,
    rejected_stake_pages: u64 = 0,
    voter_count: u32 = 0,
};

const StackNode = struct {
    g: *Guest,
    depth: usize,
};

pub fn isZeroBytes(bytes: []const u8) bool {
    for (bytes) |b| {
        if (b != 0) return false;
    }
    return true;
}

pub fn findTreeRoot(g: *Guest) *Guest {
    var cur: *Guest = g;
    var hops: usize = 0;
    while (hops < MAX_MISSION_TREE_DEPTH) : (hops += 1) {
        cur = cur.parent orelse break;
    }
    return cur;
}

/// Retained physical RAM stake equals committed RAM minus committed RAM
/// explicitly delegated to stake-holding direct children, conserving weight
/// while letting parents own stake on behalf of plain workload children.
pub fn computeRetainedStakePages(g: *Guest) u64 {
    if (!g.hasParent() or !g.has_voting_stake) return 0;
    const owned = @atomicLoad(
        usize,
        &g.quotas.committed_ram_pages,
        .monotonic,
    );
    const lock_s = g.tree_lock.lock();
    defer g.tree_lock.unlock(lock_s);
    var stake_delegated: usize = 0;
    var it = g.children.start;
    while (it) |node| : (it = node.next) {
        const ch = node.contents;
        const st = @atomicLoad(guest.GuestState, &ch.state, .acquire);
        if (st == .valid and ch.has_voting_stake) {
            stake_delegated +|= @atomicLoad(
                usize,
                &ch.quotas.committed_ram_pages,
                .monotonic,
            );
        }
    }
    return @intCast(owned -| stake_delegated);
}

pub fn tallyTreeMissionVotes(
    root: *Guest,
    target_hash: [interface.CHARTER_HASH_LEN]u8,
    cutoff_id: usize,
) TallyResult {
    var result: TallyResult = .{};
    var stack: [MAX_MISSION_TREE_NODES]StackNode = undefined;
    var sp: usize = 1;
    stack[0] = .{ .g = root, .depth = 0 };
    const want_hash = !isZeroBytes(&target_hash);

    while (sp > 0) {
        sp -= 1;
        const cur = stack[sp];
        const node = cur.g;
        const st = @atomicLoad(guest.GuestState, &node.state, .acquire);
        if (st != .valid) continue;

        if (node != root and node.has_voting_stake and
            (cutoff_id == 0 or node.id <= cutoff_id))
        {
            const stake = computeRetainedStakePages(node);
            result.eligible_stake_pages +|= stake;
            if (want_hash and std.mem.eql(
                u8,
                &node.mission_vote_hash,
                &target_hash,
            )) {
                const dec = node.mission_vote_decision;
                const approve_val =
                    @backingInt(interface.MissionVoteDecision.approve);
                if (dec == approve_val) {
                    result.approved_stake_pages +|= stake;
                    result.voter_count +|= 1;
                } else if (dec == @backingInt(
                    interface.MissionVoteDecision.reject,
                )) {
                    result.rejected_stake_pages +|= stake;
                    result.voter_count +|= 1;
                }
            }
        }

        if (cur.depth >= MAX_MISSION_TREE_DEPTH) continue;
        const lock_s = node.tree_lock.lock();
        defer node.tree_lock.unlock(lock_s);
        var it = node.children.start;
        while (it) |c_node| : (it = c_node.next) {
            if (sp >= MAX_MISSION_TREE_NODES) break;
            stack[sp] = .{ .g = c_node.contents, .depth = cur.depth + 1 };
            sp += 1;
        }
    }
    return result;
}

pub fn verifyMissionEd25519(
    args: *const interface.MissionArgs,
    verify_pk_bytes: [interface.MISSION_PUBKEY_LEN]u8,
) bool {
    if (isZeroBytes(&verify_pk_bytes) or isZeroBytes(&args.principal_pubkey)) {
        return false;
    }
    const pk = Ed25519.PublicKey.fromBytes(verify_pk_bytes) catch return false;
    const sig = Ed25519.Signature.fromBytes(args.signature);
    const msg = interface.buildMissionSignMessage(args);
    sig.verify(&msg, pk) catch return false;
    return true;
}

pub fn passesRansomwareGuard(
    st: *const MissionState,
    in_args: *const interface.MissionArgs,
) bool {
    if ((st.flags & interface.MissionFlags.PROTECT_REPLICAS) != 0) {
        if (st.min_total_replicas > 0 and in_args.min_total_replicas == 0) {
            return false;
        }
        if (in_args.min_total_replicas < st.min_total_replicas) {
            const lost: u64 =
                st.min_total_replicas - in_args.min_total_replicas;
            const limit: u64 = @as(u64, st.min_total_replicas) *
                @as(u64, st.max_stepdown_pct);
            if (lost * 100 > limit) return false;
        }
    }
    if ((st.flags & interface.MissionFlags.FORBID_UNRATIFIED_ENCRYPT) != 0) {
        const destr = interface.MissionFlags.DESTRUCTIVE_ENCRYPT |
            interface.MissionFlags.DESTRUCTIVE_WIPE;
        if ((in_args.flags & destr) != 0 and
            in_args.min_total_replicas < st.min_total_replicas)
        {
            return false;
        }
    }
    return true;
}

test "mission/tally: zero-byte and ransomware stepdown guards" {
    std.testing.refAllDecls(@This());
    try std.testing.expect(isZeroBytes(&[_]u8{ 0, 0, 0 }));
    try std.testing.expect(!isZeroBytes(&[_]u8{ 0, 1, 0 }));

    const st = MissionState{
        .sealed = true,
        .min_total_replicas = 3,
        .flags = interface.MissionFlags.PROTECT_REPLICAS |
            interface.MissionFlags.FORBID_UNRATIFIED_ENCRYPT,
        .max_stepdown_pct = 34,
    };
    var ok_step = interface.MissionArgs{ .min_total_replicas = 2 };
    try std.testing.expect(passesRansomwareGuard(&st, &ok_step));

    var zero_drop = interface.MissionArgs{ .min_total_replicas = 0 };
    try std.testing.expect(!passesRansomwareGuard(&st, &zero_drop));

    var bad_step = interface.MissionArgs{ .min_total_replicas = 1 };
    try std.testing.expect(!passesRansomwareGuard(&st, &bad_step));

    var enc_drop = interface.MissionArgs{
        .min_total_replicas = 2,
        .flags = interface.MissionFlags.DESTRUCTIVE_ENCRYPT,
    };
    try std.testing.expect(!passesRansomwareGuard(&st, &enc_drop));

    // Verify workload children (no DELEGATE_STAKE) & 0-committed Sybils.
    const testing = std.testing;
    const alloc = testing.allocator;
    const physmem = @import("../../physmem.zig");
    const scheduler = @import("../../scheduler.zig");
    scheduler.init();
    scheduler.initCpu();
    guest.quota_mod.resetGuestManagerForTest();
    var phys = try physmem.initForTest(alloc, 128);
    defer phys.deinit();

    const rt = try guest.createGuest(
        alloc,
        true,
        true,
        null,
        0,
        0,
        0,
        .riscv64,
    );
    defer rt.deinit();
    const steward = try guest.createGuest(
        alloc,
        false,
        false,
        rt,
        0,
        0,
        0,
        .riscv64,
    );
    defer steward.deinit();
    steward.has_voting_stake = true;
    steward.quotas.committed_ram_pages = 100;

    const web_leaf = try guest.createGuest(
        alloc,
        false,
        false,
        steward,
        0,
        0,
        0,
        .riscv64,
    );
    defer web_leaf.deinit();
    web_leaf.has_voting_stake = false;
    web_leaf.quotas.committed_ram_pages = 64;

    const sybil_zero = try guest.createGuest(
        alloc,
        false,
        false,
        steward,
        0,
        0,
        0,
        .riscv64,
    );
    defer sybil_zero.deinit();
    sybil_zero.has_voting_stake = true;
    sybil_zero.quotas.committed_ram_pages = 0;

    try testing.expectEqual(@as(u64, 0), computeRetainedStakePages(rt));
    try testing.expectEqual(@as(u64, 0), computeRetainedStakePages(web_leaf));
    try testing.expectEqual(@as(u64, 0), computeRetainedStakePages(sybil_zero));
    try testing.expectEqual(@as(u64, 100), computeRetainedStakePages(steward));
}
