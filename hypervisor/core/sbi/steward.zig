// M-mode Autonomic Steward whisper IPC, recovery, and failover handlers.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("../../hardware/native/cpu/riscv64/mod.zig");
const vcore = @import("../vcore.zig");
const guest = @import("../guest.zig");
const debug = @import("../debug.zig");
const scheduler = @import("../scheduler.zig");
const sbi_core = @import("../sbi.zig");
const charter = @import("charter.zig");

const VCore = vcore.VirtualCore;
const Ctx = riscv.ThreadContext;

inline fn reply(vc: *VCore, ctx: *Ctx, err: isize, val: usize) void {
    sbi_core.setResult(vc, ctx, err, val);
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
    defer {
        std.crypto.secureZero(u8, msg_buf);
        g.allocator.free(msg_buf);
    }

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
    const max_len: usize = @min(a1, guest.MAX_PACKET_LEN);
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
        if (!charter.checkAndConsumeQuorum(target_cid)) {
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
        if (!charter.checkAndConsumeQuorum(guest.CID_SELF)) {
            debug.printf("SBI: REQUEST_ROOT_FAILOVER denied\n", .{});
            reply(vc, ctx, sbi_core.SBI_ERR_DENIED, 0);
            return;
        }
        guest.Guest.promoteStandbyRoot(root_vm.?, standby) catch {
            reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
            return;
        };
        const new_epoch = charter.incrementFailoverEpoch();
        reply(vc, ctx, sbi_core.SBI_SUCCESS, new_epoch);
    } else {
        reply(vc, ctx, sbi_core.SBI_ERR_INVALID_PARAM, 0);
    }
}

test "Steward whisper and failover module declarations" {
    std.testing.refAllDecls(@This());
}
