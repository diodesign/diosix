// M-mode Cryptographic Mission Governance & Conserved Quota-Stake Consensus.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("../../hardware/native/cpu/riscv64/mod.zig");
const sv39x4 = @import("../../hardware/native/cpu/riscv64/sv39x4.zig");
const vcore = @import("../vcore.zig");
const guest = @import("../guest.zig");
const scheduler = @import("../scheduler.zig");
const physmem = @import("../physmem.zig");
const atomic = @import("../atomic.zig");
const sbi_core = @import("../sbi.zig");
const charter = @import("charter.zig");
const tally_mod = @import("mission/tally.zig");
const interface = @import("interface").sbi;
const arch = @import("interface").riscv;

const Ed25519 = std.crypto.sign.Ed25519;
const MissionState = tally_mod.MissionState;
const isZeroBytes = tally_mod.isZeroBytes;
const findTreeRoot = tally_mod.findTreeRoot;
const computeRetainedStakePages = tally_mod.computeRetainedStakePages;
const tallyTreeMissionVotes = tally_mod.tallyTreeMissionVotes;
const verifyMissionEd25519 = tally_mod.verifyMissionEd25519;
const passesRansomwareGuard = tally_mod.passesRansomwareGuard;

var mission_manager = atomic.LockPayload(MissionState).init(
    "M-mode Mission Governance state",
    .{},
);

const VCore = vcore.VirtualCore;
const Ctx = riscv.ThreadContext;
const Guest = guest.Guest;

inline fn reply(vc: *VCore, ctx: *Ctx, err: isize, val: usize) void {
    sbi_core.setResult(vc, ctx, err, val);
}

pub fn resetMissionForTest() void {
    const guard = mission_manager.acquire();
    defer guard.release();
    guard.get().* = .{};
}

fn queryMissionState(vc: *VCore, ctx: *Ctx, g: *Guest, a0: usize) void {
    var req_hash: [interface.CHARTER_HASH_LEN]u8 = @splat(0);
    if (a0 != 0) {
        const req = g.space.readGuestStruct(
            interface.MissionArgs,
            a0,
        ) catch {
            reply(vc, ctx, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
            return;
        };
        req_hash = req.charter_hash;
    }

    const root = findTreeRoot(g);
    const out_args = blk: {
        const guard = mission_manager.acquire();
        defer guard.release();
        const st = guard.get();
        const tgt_hash = if (!isZeroBytes(&req_hash))
            req_hash
        else if (!isZeroBytes(&st.pending_hash))
            st.pending_hash
        else
            st.charter_hash;
        const cutoff = if (!isZeroBytes(&st.pending_hash) and
            std.mem.eql(u8, &st.pending_hash, &tgt_hash))
            st.proposal_cutoff_guest_id
        else
            0;
        const tally = tallyTreeMissionVotes(root, tgt_hash, cutoff);
        break :blk interface.MissionArgs{
            .charter_hash = st.charter_hash,
            .principal_pubkey = st.principal_pubkey,
            .version = st.version,
            .min_total_replicas = st.min_total_replicas,
            .flags = st.flags,
            .stake_quorum_pct = st.stake_quorum_pct,
            .max_stepdown_pct = st.max_stepdown_pct,
            .is_sealed = if (st.sealed) 1 else 0,
            .has_pubkey = if (st.has_pubkey) 1 else 0,
            .eligible_stake_pages = tally.eligible_stake_pages,
            .approved_stake_pages = tally.approved_stake_pages,
            .rejected_stake_pages = tally.rejected_stake_pages,
            .voter_count = tally.voter_count,
        };
    };
    if (a0 != 0) {
        g.space.writeGuestStruct(interface.MissionArgs, a0, out_args) catch {
            reply(vc, ctx, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
            return;
        };
    }
    reply(vc, ctx, sbi_core.SBI_SUCCESS, out_args.is_sealed);
}

pub fn handleSealMission(vc: *VCore, ctx: *Ctx, a0: usize, a1: usize) void {
    const g = vc.getGuest();
    if (a1 == 0) {
        queryMissionState(vc, ctx, g, a0);
        return;
    }

    const in_args = g.space.readGuestStruct(
        interface.MissionArgs,
        a0,
    ) catch {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    if (in_args.stake_quorum_pct == 0 or
        in_args.stake_quorum_pct > 100 or
        in_args.max_stepdown_pct > 100 or
        isZeroBytes(&in_args.charter_hash))
    {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }
    if (g.hasParent() and !g.is_steward) {
        reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
        return;
    }

    const snap = blk: {
        const guard = mission_manager.acquire();
        defer guard.release();
        const st = guard.get();
        break :blk .{
            .sealed = st.sealed,
            .has_pubkey = st.has_pubkey,
            .pubkey = st.principal_pubkey,
        };
    };
    if (!snap.sealed and g.hasParent()) {
        reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
        return;
    }

    const verify_pk = if (snap.sealed and snap.has_pubkey)
        snap.pubkey
    else
        in_args.principal_pubkey;
    if (!verifyMissionEd25519(&in_args, verify_pk)) {
        reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
        return;
    }

    const root = findTreeRoot(g);
    var out_args = in_args;
    {
        const guard = mission_manager.acquire();
        defer guard.release();
        const st = guard.get();
        if (st.sealed) {
            if (st.has_pubkey and
                !std.mem.eql(u8, &st.principal_pubkey, &snap.pubkey))
            {
                reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
                return;
            }
            if (in_args.version <= st.version) {
                reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
                return;
            }
            if (!passesRansomwareGuard(st, &in_args)) {
                reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
                return;
            }
            const cutoff = if (std.mem.eql(
                u8,
                &st.pending_hash,
                &in_args.charter_hash,
            ))
                st.proposal_cutoff_guest_id
            else
                0;
            const tally = tallyTreeMissionVotes(
                root,
                in_args.charter_hash,
                cutoff,
            );
            if (st.min_total_replicas > 0 and tally.eligible_stake_pages == 0) {
                reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
                return;
            }
            if (tally.eligible_stake_pages > 0) {
                const lhs = tally.approved_stake_pages *| 100;
                const rhs = tally.eligible_stake_pages *|
                    @as(u64, st.stake_quorum_pct);
                if (lhs < rhs) {
                    reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
                    return;
                }
            }
            out_args.eligible_stake_pages = tally.eligible_stake_pages;
            out_args.approved_stake_pages = tally.approved_stake_pages;
            out_args.rejected_stake_pages = tally.rejected_stake_pages;
            out_args.voter_count = tally.voter_count;
        }
        st.sealed = true;
        st.has_pubkey = true;
        st.charter_hash = in_args.charter_hash;
        st.principal_pubkey = in_args.principal_pubkey;
        st.version = in_args.version;
        st.min_total_replicas = in_args.min_total_replicas;
        st.flags = in_args.flags;
        st.stake_quorum_pct = in_args.stake_quorum_pct;
        st.max_stepdown_pct = in_args.max_stepdown_pct;
        st.pending_hash = @splat(0);
        st.proposal_cutoff_guest_id = 0;
        out_args.is_sealed = 1;
        out_args.has_pubkey = 1;
    }

    charter.syncCharterHashFromMission(in_args.charter_hash);
    g.space.writeGuestStruct(interface.MissionArgs, a0, out_args) catch {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    reply(vc, ctx, sbi_core.SBI_SUCCESS, 1);
}

pub fn handleVoteMission(vc: *VCore, ctx: *Ctx, a0: usize) void {
    const g = vc.getGuest();
    const in_args = g.space.readGuestStruct(
        interface.MissionVoteArgs,
        a0,
    ) catch {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    const app_v = @backingInt(interface.MissionVoteDecision.approve);
    const rej_v = @backingInt(interface.MissionVoteDecision.reject);
    const dec_ok = in_args.decision == app_v or in_args.decision == rej_v;
    if (!dec_ok or isZeroBytes(&in_args.proposal_hash)) {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }

    const root = findTreeRoot(g);
    const caller_stake = if (g == root) 0 else computeRetainedStakePages(g);
    const tally = blk: {
        const guard = mission_manager.acquire();
        defer guard.release();
        const st = guard.get();
        if (!std.mem.eql(u8, &st.pending_hash, &in_args.proposal_hash)) {
            st.pending_hash = in_args.proposal_hash;
            st.proposal_cutoff_guest_id =
                guest.quota_mod.vmid_mod.peekLastGuestId();
        }
        g.mission_vote_hash = in_args.proposal_hash;
        g.mission_vote_decision = in_args.decision;
        break :blk tallyTreeMissionVotes(
            root,
            in_args.proposal_hash,
            st.proposal_cutoff_guest_id,
        );
    };

    const out_args = interface.MissionVoteArgs{
        .proposal_hash = in_args.proposal_hash,
        .decision = in_args.decision,
        .caller_stake_pages = caller_stake,
        .eligible_stake_pages = tally.eligible_stake_pages,
        .approved_stake_pages = tally.approved_stake_pages,
        .rejected_stake_pages = tally.rejected_stake_pages,
    };
    g.space.writeGuestStruct(interface.MissionVoteArgs, a0, out_args) catch {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    reply(vc, ctx, sbi_core.SBI_SUCCESS, @intCast(tally.approved_stake_pages));
}

fn spawnTestMissionGuest(
    alloc: std.mem.Allocator,
    is_trusted: bool,
    parent: ?*Guest,
) !*Guest {
    const g = try guest.createGuest(
        alloc,
        is_trusted,
        is_trusted and parent == null,
        parent,
        0,
        0,
        0,
        .riscv64,
    );
    g.quotas.delegated_ram_pages = 0;
    const rw = sv39x4.PTEFlags.leaf_rw_user;
    const page = try physmem.allocPage();
    try g.space.map(0x80000000, page, physmem.PageSize, rw);
    physmem.decrementPageRef(page);
    return g;
}

fn signTestMissionArgs(
    kp: Ed25519.KeyPair,
    args: *interface.MissionArgs,
) !void {
    args.principal_pubkey = kp.public_key.toBytes();
    const msg = interface.buildMissionSignMessage(args);
    const sig = try kp.sign(&msg, null);
    args.signature = sig.toBytes();
}

test "mission: Ed25519 sealing, conserved stake Sybil resistance, and guards" {
    _ = tally_mod;
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    resetMissionForTest();
    defer resetMissionForTest();
    charter.resetCharterForTest();
    defer charter.resetCharterForTest();
    scheduler.init();
    scheduler.initCpu();
    guest.quota_mod.resetGuestManagerForTest();

    var phys_test = try physmem.initForTest(testing.allocator, 256);
    defer phys_test.deinit();

    const seed: [Ed25519.KeyPair.seed_length]u8 = @splat(0x42);
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);

    const root = try spawnTestMissionGuest(testing.allocator, true, null);
    defer root.deinit();
    root.quotas.max_ram_pages = 512;

    const child1 = try spawnTestMissionGuest(testing.allocator, false, root);
    defer child1.deinit();
    child1.quotas.max_ram_pages = 64;
    child1.quotas.delegated_ram_pages = 32;
    const gc1a = try spawnTestMissionGuest(testing.allocator, false, child1);
    defer gc1a.deinit();
    gc1a.quotas.max_ram_pages = 16;
    const gc1b = try spawnTestMissionGuest(testing.allocator, false, child1);
    defer gc1b.deinit();
    gc1b.quotas.max_ram_pages = 16;

    const child2 = try spawnTestMissionGuest(testing.allocator, false, root);
    defer child2.deinit();
    child2.quotas.max_ram_pages = 64;
    const child3 = try spawnTestMissionGuest(testing.allocator, false, root);
    defer child3.deinit();
    child3.quotas.max_ram_pages = 64;

    var r_vc = vcore.VirtualCore.init(0, root, 0x80000000, 0, .normal);
    var c1_vc = vcore.VirtualCore.init(0, child1, 0x80000000, 0, .normal);
    var g1a_vc = vcore.VirtualCore.init(0, gc1a, 0x80000000, 0, .normal);
    var g1b_vc = vcore.VirtualCore.init(0, gc1b, 0x80000000, 0, .normal);
    var c2_vc = vcore.VirtualCore.init(0, child2, 0x80000000, 0, .normal);
    var c3_vc = vcore.VirtualCore.init(0, child3, 0x80000000, 0, .normal);
    var ctx: riscv.ThreadContext = @splat(0);

    const a0_i = @backingInt(arch.Register.a0);
    const a1_i = @backingInt(arch.Register.a1);
    const a6_i = @backingInt(arch.Register.a6);
    const a7_i = @backingInt(arch.Register.a7);
    const denied: usize = @bitCast(sbi_core.SBI_ERR_DENIED);

    // 1. Forged signature on v1 fails.
    var m1 = interface.MissionArgs{
        .version = 1,
        .min_total_replicas = 3,
        .flags = interface.MissionFlags.PROTECT_REPLICAS |
            interface.MissionFlags.FORBID_UNRATIFIED_ENCRYPT,
        .stake_quorum_pct = 67,
        .max_stepdown_pct = 33,
    };
    @memset(&m1.charter_hash, 0x11);
    try signTestMissionArgs(kp, &m1);
    m1.signature[0] ^= 0xff;
    try root.space.writeGuestStruct(interface.MissionArgs, 0x80000000, m1);
    ctx[a7_i] = interface.EXT.DIOSIX;
    ctx[a6_i] = interface.DIOSIX.SEAL_MISSION;
    ctx[a0_i] = 0x80000000;
    ctx[a1_i] = 1;
    sbi_core.handle(&r_vc, &ctx);
    try testing.expectEqual(denied, ctx[a0_i]);

    // 2. Validly signed v1 seals cleanly.
    m1.signature[0] ^= 0xff;
    try root.space.writeGuestStruct(interface.MissionArgs, 0x80000000, m1);
    ctx[a0_i] = 0x80000000;
    ctx[a1_i] = 1;
    sbi_core.handle(&r_vc, &ctx);
    try testing.expectEqual(@as(usize, 0), ctx[a0_i]);
    try testing.expect(charter.isCharterSealed());

    // 3. Compromised-Principal ransomware (3 -> 0 + DESTRUCTIVE_ENCRYPT) fails.
    var ransom = m1;
    @memset(&ransom.charter_hash, 0x99);
    ransom.version = 2;
    ransom.min_total_replicas = 0;
    ransom.flags |= interface.MissionFlags.DESTRUCTIVE_ENCRYPT;
    try signTestMissionArgs(kp, &ransom);
    var v_app = interface.MissionVoteArgs{
        .proposal_hash = ransom.charter_hash,
        .decision = @backingInt(interface.MissionVoteDecision.approve),
    };
    for ([_]*vcore.VirtualCore{ &c1_vc, &c2_vc, &c3_vc }) |vc_p| {
        const g_p = vc_p.getGuest();
        try g_p.space.writeGuestStruct(
            interface.MissionVoteArgs,
            0x80000000,
            v_app,
        );
        ctx[a6_i] = interface.DIOSIX.VOTE_MISSION;
        ctx[a0_i] = 0x80000000;
        sbi_core.handle(vc_p, &ctx);
    }
    try root.space.writeGuestStruct(interface.MissionArgs, 0x80000000, ransom);
    ctx[a6_i] = interface.DIOSIX.SEAL_MISSION;
    ctx[a0_i] = 0x80000000;
    ctx[a1_i] = 1;
    sbi_core.handle(&r_vc, &ctx);
    try testing.expectEqual(denied, ctx[a0_i]);

    // 4. Sybil-split subtree (child1 + gc1a + gc1b = 64/192 = 33%) is denied.
    var v2 = m1;
    @memset(&v2.charter_hash, 0x22);
    v2.version = 2;
    v2.min_total_replicas = 4;
    try signTestMissionArgs(kp, &v2);
    v_app.proposal_hash = v2.charter_hash;
    for ([_]*vcore.VirtualCore{ &c1_vc, &g1a_vc, &g1b_vc }) |vc_p| {
        const g_p = vc_p.getGuest();
        try g_p.space.writeGuestStruct(
            interface.MissionVoteArgs,
            0x80000000,
            v_app,
        );
        ctx[a6_i] = interface.DIOSIX.VOTE_MISSION;
        ctx[a0_i] = 0x80000000;
        sbi_core.handle(vc_p, &ctx);
    }
    try testing.expectEqual(@as(usize, 64), ctx[a1_i]);
    try root.space.writeGuestStruct(interface.MissionArgs, 0x80000000, v2);
    ctx[a6_i] = interface.DIOSIX.SEAL_MISSION;
    ctx[a0_i] = 0x80000000;
    ctx[a1_i] = 1;
    sbi_core.handle(&r_vc, &ctx);
    try testing.expectEqual(denied, ctx[a0_i]);

    // Reactive Sybil child spawned after proposal cutoff gets 0 eligible stake.
    const late = try spawnTestMissionGuest(testing.allocator, false, root);
    defer late.deinit();
    late.quotas.max_ram_pages = 1024;
    var late_vc = vcore.VirtualCore.init(0, late, 0x80000000, 0, .normal);
    try late.space.writeGuestStruct(
        interface.MissionVoteArgs,
        0x80000000,
        v_app,
    );
    ctx[a6_i] = interface.DIOSIX.VOTE_MISSION;
    ctx[a0_i] = 0x80000000;
    sbi_core.handle(&late_vc, &ctx);
    try testing.expectEqual(@as(usize, 64), ctx[a1_i]);

    // Peer children vote approve -> 192/192 = 100% >= 67%.
    for ([_]*vcore.VirtualCore{ &c2_vc, &c3_vc }) |vc_p| {
        const g_p = vc_p.getGuest();
        try g_p.space.writeGuestStruct(
            interface.MissionVoteArgs,
            0x80000000,
            v_app,
        );
        ctx[a6_i] = interface.DIOSIX.VOTE_MISSION;
        ctx[a0_i] = 0x80000000;
        sbi_core.handle(vc_p, &ctx);
    }
    try testing.expectEqual(@as(usize, 192), ctx[a1_i]);

    try root.space.writeGuestStruct(interface.MissionArgs, 0x80000000, v2);
    ctx[a6_i] = interface.DIOSIX.SEAL_MISSION;
    ctx[a0_i] = 0x80000000;
    ctx[a1_i] = 1;
    sbi_core.handle(&r_vc, &ctx);
    try testing.expectEqual(@as(usize, 0), ctx[a0_i]);
    try testing.expectEqual(@as(usize, 1), ctx[a1_i]);
}
