// M-mode Constitutional Charter and Autonomic Steward consensus handlers.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("../../hardware/native/cpu/riscv64/mod.zig");
const sv39x4 = @import("../../hardware/native/cpu/riscv64/sv39x4.zig");
const vcore = @import("../vcore.zig");
const guest = @import("../guest.zig");
const debug = @import("../debug.zig");
const scheduler = @import("../scheduler.zig");
const physmem = @import("../physmem.zig");
const atomic = @import("../atomic.zig");
const sbi_core = @import("../sbi.zig");
const interface = @import("interface").sbi;
const arch = @import("interface").riscv;

pub const MAX_STEWARD_QUORUM_TOTAL: u16 = 62;
pub const MAX_STEWARD_CID_EXCL: usize =
    guest.CID_FIRST_CHILD + MAX_STEWARD_QUORUM_TOTAL;

pub const CharterState = struct {
    sealed: bool = false,
    charter_hash: [interface.CHARTER_HASH_LEN]u8 =
        std.mem.zeroes([interface.CHARTER_HASH_LEN]u8),
    quorum_required: u16 = 2,
    quorum_total: u16 = 3,
    standby_replicas: u16 = 1,
    ratified_mask: u64 = 0,
    vote_target_cids: [MAX_STEWARD_CID_EXCL]u64 = @splat(0),
    approved_target_cid: u64 = 0,
    failover_epoch: u64 = 0,
};

var charter_manager = atomic.LockPayload(CharterState).init(
    "M-mode Constitutional Charter state",
    .{},
);

const VCore = vcore.VirtualCore;
const Ctx = riscv.ThreadContext;
const Guest = guest.Guest;

inline fn reply(vc: *VCore, ctx: *Ctx, err: isize, val: usize) void {
    sbi_core.setResult(vc, ctx, err, val);
}

pub fn resetCharterForTest() void {
    const guard = charter_manager.acquire();
    defer guard.release();
    guard.get().* = .{};
}

pub fn isCharterSealed() bool {
    const guard = charter_manager.acquire();
    defer guard.release();
    return guard.get().sealed;
}

pub fn incrementFailoverEpoch() usize {
    const guard = charter_manager.acquire();
    defer guard.release();
    const st = guard.get();
    st.failover_epoch += 1;
    return @intCast(st.failover_epoch);
}

fn countVotesForTarget(st: *const CharterState, target_cid: u64) usize {
    var count: usize = 0;
    for (guest.CID_FIRST_CHILD..MAX_STEWARD_CID_EXCL) |cid| {
        const bit = @as(u64, 1) << @intCast(cid);
        if ((st.ratified_mask & bit) != 0 and
            st.vote_target_cids[cid] == target_cid)
        {
            count += 1;
        }
    }
    return count;
}

pub fn checkAndConsumeQuorum(target_cid: usize) bool {
    const guard = charter_manager.acquire();
    defer guard.release();
    const st = guard.get();
    if (!st.sealed) return true;

    const votes = countVotesForTarget(st, @intCast(target_cid));
    if (votes >= st.quorum_required) {
        st.ratified_mask = 0;
        st.vote_target_cids = @splat(0);
        st.approved_target_cid = 0;
        return true;
    }
    return false;
}

pub fn handleSealCharter(vc: *VCore, ctx: *Ctx, a0: usize, a1: usize) void {
    const g = vc.getGuest();
    if (a1 == 0) {
        const out_args = blk: {
            const guard = charter_manager.acquire();
            defer guard.release();
            const st = guard.get();
            break :blk interface.CharterArgs{
                .charter_hash = st.charter_hash,
                .quorum_required = st.quorum_required,
                .quorum_total = st.quorum_total,
                .standby_replicas = st.standby_replicas,
                .is_sealed = if (st.sealed) 1 else 0,
                .ratified_mask = st.ratified_mask,
                .approved_target_cid = st.approved_target_cid,
                .failover_epoch = st.failover_epoch,
            };
        };
        if (a0 != 0) {
            const CArgs = interface.CharterArgs;
            g.space.writeGuestStruct(CArgs, a0, out_args) catch {
                reply(vc, ctx, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
                return;
            };
        }
        reply(vc, ctx, sbi_core.SBI_SUCCESS, out_args.is_sealed);
        return;
    }

    const in_args = g.space.readGuestStruct(interface.CharterArgs, a0) catch {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    if (in_args.quorum_required == 0 or
        in_args.quorum_required > in_args.quorum_total or
        in_args.quorum_total > MAX_STEWARD_QUORUM_TOTAL)
    {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }

    {
        const guard = charter_manager.acquire();
        defer guard.release();
        const st = guard.get();
        if (!st.sealed) {
            if (!g.is_root) {
                reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
                return;
            }
        } else {
            const votes = countVotesForTarget(st, guest.CID_SELF);
            if (votes < st.quorum_required) {
                reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
                return;
            }
        }
        st.sealed = true;
        st.charter_hash = in_args.charter_hash;
        st.quorum_required = in_args.quorum_required;
        st.quorum_total = in_args.quorum_total;
        st.standby_replicas = in_args.standby_replicas;
        st.ratified_mask = 0;
        st.vote_target_cids = @splat(0);
        st.approved_target_cid = 0;
    }
    reply(vc, ctx, sbi_core.SBI_SUCCESS, 1);
}

pub fn handleRatifyCharter(vc: *VCore, ctx: *Ctx, a0: usize) void {
    const g = vc.getGuest();
    if (!g.is_steward or
        g.local_cid < guest.CID_FIRST_CHILD or
        g.local_cid >= MAX_STEWARD_CID_EXCL)
    {
        reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
        return;
    }
    const target_cid: u64 = @intCast(a0);
    const vote_count: usize = blk: {
        const guard = charter_manager.acquire();
        defer guard.release();
        const st = guard.get();
        st.vote_target_cids[g.local_cid] = target_cid;
        st.ratified_mask |= (@as(u64, 1) << @intCast(g.local_cid));
        st.approved_target_cid = target_cid;
        break :blk countVotesForTarget(st, target_cid);
    };
    reply(vc, ctx, sbi_core.SBI_SUCCESS, vote_count);
}

pub fn handleWhisperSend(
    vc: *VCore,
    ctx: *Ctx,
    a0: usize,
    a1: usize,
    a2: usize,
) void {
    const g = vc.getGuest();
    if (!g.is_steward and !g.is_root) {
        reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
        return;
    }
    if (a1 == 0 or a1 > guest.MAX_PACKET_LEN) {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }
    const msg_len = a1;
    _ = std.math.add(usize, a0, msg_len) catch {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    const msg_buf = g.allocator.alloc(u8, msg_len) catch {
        reply(vc, ctx, sbi_core.SBI_ERR_FAILED, 0);
        return;
    };
    defer g.allocator.free(msg_buf);

    g.space.copyFromGuest(msg_buf, a0) catch {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    const dest_cid = a2;
    const root_parent: ?*guest.Guest = if (g.is_root) g else g.parent;

    if (root_parent) |rp| {
        if (dest_cid == 0) {
            const s = rp.tree_lock.lock();
            var it = rp.children.start;
            while (it) |node| : (it = node.next) {
                const peer = node.contents;
                if (peer != g and peer.is_steward) {
                    sbi_core.deliverToQueue(peer, &peer.whisper_rx, msg_buf);
                }
            }
            rp.tree_lock.unlock(s);
        } else if (dest_cid == guest.CID_SELF or
            dest_cid == guest.CID_PARENT)
        {
            if (rp != g) {
                sbi_core.deliverToQueue(rp, &rp.whisper_rx, msg_buf);
            }
        } else if (dest_cid >= guest.CID_FIRST_CHILD) {
            if (rp.getGuestByCid(dest_cid)) |target| {
                if (target.is_steward or target.is_root) {
                    const q = &target.whisper_rx;
                    sbi_core.deliverToQueue(target, q, msg_buf);
                } else {
                    reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
                    return;
                }
            } else {
                reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
                return;
            }
        }
        reply(vc, ctx, sbi_core.SBI_SUCCESS, msg_len);
    } else {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
    }
}

pub fn handleWhisperRecv(vc: *VCore, ctx: *Ctx, a0: usize, a1: usize) void {
    const g = vc.getGuest();
    if (!g.is_steward and !g.is_root) {
        reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
        return;
    }
    const max_len = @min(a1, guest.MAX_PACKET_LEN);
    if (g.whisper_rx.popToGuest(&g.space, a0, max_len)) |copy_len| {
        reply(vc, ctx, sbi_core.SBI_SUCCESS, copy_len);
    } else |_| {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
    }
}

pub fn handleResetSteward(vc: *VCore, ctx: *Ctx, a0: usize, a1: usize) void {
    const g = vc.getGuest();
    const target_cid = a0;
    const override_entry = a1;
    if ((override_entry & 1) != 0) {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }
    const root_parent: ?*guest.Guest =
        if (g.is_root) g else if (g.is_steward) g.parent else null;
    if (root_parent == null) {
        reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
        return;
    }
    if (root_parent.?.getGuestByCid(target_cid)) |target| {
        if (!target.is_steward) {
            reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
            return;
        }
        if (!checkAndConsumeQuorum(target_cid)) {
            debug.printf("SBI: RESET_STEWARD CID {} denied\n", .{target_cid});
            reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
            return;
        }
        target.resetSteward(override_entry);
        if (target.vcores.start) |vc_node| {
            scheduler.queue(vc_node.contents);
            sbi_core.broadcastPhysicalIPI();
        }
        reply(vc, ctx, sbi_core.SBI_SUCCESS, target.steward_reset_count);
    } else {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
    }
}

pub fn handleRequestRootFailover(vc: *VCore, ctx: *Ctx, a0: usize) void {
    const g = vc.getGuest();
    const requested_standby_cid = a0;
    const root_vm: ?*guest.Guest =
        if (g.is_root) g else if (g.is_steward) g.parent else null;
    if (root_vm == null or !root_vm.?.is_root) {
        reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
        return;
    }
    const standby_opt: ?*guest.Guest =
        if (requested_standby_cid >= guest.CID_FIRST_CHILD)
            root_vm.?.getGuestByCid(requested_standby_cid)
        else
            root_vm.?.findStandbyRoot();

    if (standby_opt) |standby| {
        if (!standby.is_standby_root) {
            reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
            return;
        }
        if (!checkAndConsumeQuorum(guest.CID_SELF)) {
            debug.printf("SBI: REQUEST_ROOT_FAILOVER denied\n", .{});
            reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
            return;
        }
        guest.Guest.promoteStandbyRoot(root_vm.?, standby) catch {
            reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
            return;
        };
        const new_epoch = incrementFailoverEpoch();
        reply(vc, ctx, sbi_core.SBI_SUCCESS, new_epoch);
    } else {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
    }
}

fn spawnTestGuest(
    alloc: std.mem.Allocator,
    is_root: bool,
    parent: ?*guest.Guest,
) !*guest.Guest {
    return guest.createGuest(
        alloc,
        is_root,
        is_root,
        parent,
        0,
        0,
        0,
        .riscv64,
    );
}

fn spawnTestSteward(alloc: std.mem.Allocator, root: *Guest) !*Guest {
    const rwx = sv39x4.PTEFlags.read | sv39x4.PTEFlags.write |
        sv39x4.PTEFlags.valid | sv39x4.PTEFlags.accessed |
        sv39x4.PTEFlags.dirty | sv39x4.PTEFlags.user;
    const st = try spawnTestGuest(alloc, false, root);
    st.is_steward = true;
    const page = try physmem.allocPage();
    try st.space.map(0x80000000, page, physmem.PageSize, rwx);
    physmem.decrementPageRef(page);
    return st;
}

test "SBI Diosix Phase 5: Charter sealing, Steward quorum guard, and failover" {
    const testing = std.testing;
    resetCharterForTest();
    defer resetCharterForTest();
    scheduler.init();
    scheduler.initCpu();

    var phys_test = try physmem.initForTest(testing.allocator, 256);
    defer phys_test.deinit();

    const rwx = sv39x4.PTEFlags.read | sv39x4.PTEFlags.write |
        sv39x4.PTEFlags.valid | sv39x4.PTEFlags.accessed |
        sv39x4.PTEFlags.dirty | sv39x4.PTEFlags.user;
    const root_vm = try spawnTestGuest(testing.allocator, true, null);
    defer root_vm.deinit();
    const root_page = try physmem.allocPage();
    try root_vm.space.map(0x80000000, root_page, physmem.PageSize, rwx);
    physmem.decrementPageRef(root_page);

    const standby_root = try spawnTestGuest(testing.allocator, false, root_vm);
    standby_root.is_standby_root = true;

    const steward1 = try spawnTestSteward(testing.allocator, root_vm);
    steward1.quotas.max_ram_pages = 1024;
    steward1.quotas.max_vcpus = 2;
    _ = try steward1.addVcore(0, 0x80200000, 0x80100000, .normal, null);
    steward1.resetForRun(0x80200000, 0x80100000);
    const steward2 = try spawnTestSteward(testing.allocator, root_vm);
    const steward3 = try spawnTestSteward(testing.allocator, root_vm);
    const leaf_vm = try spawnTestGuest(testing.allocator, false, steward1);
    leaf_vm.is_confidential = true;

    var root_vc = vcore.VirtualCore.init(0, root_vm, 0x80000000, 0, .normal);
    var s1_vc = vcore.VirtualCore.init(0, steward1, 0x80000000, 0, .normal);
    var s2_vc = vcore.VirtualCore.init(0, steward2, 0x80000000, 0, .normal);
    var s3_vc = vcore.VirtualCore.init(0, steward3, 0x80000000, 0, .normal);
    var ctx: riscv.ThreadContext = std.mem.zeroes(riscv.ThreadContext);

    var cargs = interface.CharterArgs{
        .quorum_required = 2,
        .quorum_total = 3,
        .standby_replicas = 1,
    };
    @memset(&cargs.charter_hash, 0xab);
    const CArgs = interface.CharterArgs;
    try root_vm.space.writeGuestStruct(CArgs, 0x80000000, cargs);

    ctx[@backingInt(arch.Register.a7)] = interface.EXT.DIOSIX;
    ctx[@backingInt(arch.Register.a6)] = interface.DIOSIX.SEAL_CHARTER;
    ctx[@backingInt(arch.Register.a0)] = 0x80000000;
    ctx[@backingInt(arch.Register.a1)] = 1;
    sbi_core.handle(&root_vc, 0, &ctx);
    try testing.expectEqual(@as(usize, 0), ctx[@backingInt(arch.Register.a0)]);
    try testing.expect(isCharterSealed());

    ctx[@backingInt(arch.Register.a6)] = interface.DIOSIX.TERMINATE;
    ctx[@backingInt(arch.Register.a0)] = steward1.local_cid;
    ctx[@backingInt(arch.Register.a1)] = 1;
    sbi_core.handle(&root_vc, 0, &ctx);
    const denied: usize = @bitCast(sbi_core.SBI_ERR_DENIED);
    try testing.expectEqual(denied, ctx[@backingInt(arch.Register.a0)]);

    const whisper_msg = "whisper:quorum-heartbeat-ok";
    try steward1.space.copyToGuest(0x80000000, whisper_msg);
    ctx[@backingInt(arch.Register.a6)] = interface.DIOSIX.WHISPER_SEND;
    ctx[@backingInt(arch.Register.a0)] = 0x80000000;
    ctx[@backingInt(arch.Register.a1)] = whisper_msg.len;
    ctx[@backingInt(arch.Register.a2)] = 0;
    sbi_core.handle(&s1_vc, 0, &ctx);
    try testing.expectEqual(@as(usize, 0), ctx[@backingInt(arch.Register.a0)]);

    ctx[@backingInt(arch.Register.a6)] = interface.DIOSIX.WHISPER_RECV;
    ctx[@backingInt(arch.Register.a0)] = 0x80000200;
    ctx[@backingInt(arch.Register.a1)] = 64;
    sbi_core.handle(&s2_vc, 0, &ctx);
    const a1_idx = @backingInt(arch.Register.a1);
    try testing.expectEqual(whisper_msg.len, ctx[a1_idx]);

    // 2-of-3 Steward ratification unlocks RESET_STEWARD even if Steward 3
    // attempts to vote for a conflicting target_cid!
    ctx[@backingInt(arch.Register.a6)] = interface.DIOSIX.RATIFY_CHARTER;
    ctx[@backingInt(arch.Register.a0)] = steward1.local_cid;
    sbi_core.handle(&s1_vc, 0, &ctx);
    ctx[@backingInt(arch.Register.a0)] = 99;
    sbi_core.handle(&s3_vc, 0, &ctx);
    ctx[@backingInt(arch.Register.a0)] = steward1.local_cid;
    sbi_core.handle(&s2_vc, 0, &ctx);
    try testing.expectEqual(@as(usize, 2), ctx[a1_idx]);

    ctx[@backingInt(arch.Register.a6)] = interface.DIOSIX.RESET_STEWARD;
    ctx[@backingInt(arch.Register.a0)] = steward1.local_cid;
    ctx[@backingInt(arch.Register.a1)] = 0;
    sbi_core.handle(&s2_vc, 0, &ctx);
    try testing.expectEqual(@as(usize, 0), ctx[@backingInt(arch.Register.a0)]);
    try testing.expectEqual(@as(usize, 1), steward1.steward_reset_count);
    try testing.expectEqual(guest.GuestState.valid, leaf_vm.state);

    ctx[@backingInt(arch.Register.a6)] = interface.DIOSIX.RATIFY_CHARTER;
    ctx[@backingInt(arch.Register.a0)] = guest.CID_SELF;
    sbi_core.handle(&s1_vc, 0, &ctx);
    ctx[@backingInt(arch.Register.a0)] = guest.CID_SELF;
    sbi_core.handle(&s2_vc, 0, &ctx);

    ctx[@backingInt(arch.Register.a6)] = interface.DIOSIX.REQUEST_ROOT_FAILOVER;
    ctx[@backingInt(arch.Register.a0)] = 0;
    sbi_core.handle(&s1_vc, 0, &ctx);
    try testing.expectEqual(@as(usize, 0), ctx[@backingInt(arch.Register.a0)]);
    try testing.expect(standby_root.is_root);
    try testing.expectEqual(standby_root, steward1.parent.?);

    standby_root.terminate();
    standby_root.deinit();
    steward1.deinit();
    steward2.deinit();
    steward3.deinit();
    leaf_vm.deinit();
}
