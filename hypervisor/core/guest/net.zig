// M-mode Hierarchical L2 Ethernet Switch Routing for Guest VMs.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const scheduler = @import("../scheduler.zig");
const guest_mod = @import("../guest.zig");
const sbi_core = @import("../sbi.zig");
const pcore = @import("../pcore.zig");

const ETH_HEADER_LEN: usize = 14;
const ETH_SRC_MAC_OFFSET: usize = 6;
const LOCAL_ADMIN_MAC_PREFIX: u8 = 0x02;
const BYTE_MASK: usize = 0xff;

pub const NetPort = enum { downstream_switch, upstream_nic };

fn wakeNetVcores(target: *guest_mod.Guest) void {
    var it = target.vcores.start;
    while (it) |node| : (it = node.next) {
        if (node.contents.tryWake()) {
            scheduler.queue(node.contents);
            pcore.wakeIdleCores();
        }
    }
}

pub fn deliverToChildUpstream(
    target: *guest_mod.Guest,
    frame: []const u8,
) void {
    const riscv = @import("../../hardware/native/cpu/riscv64/mod.zig");
    if (target.net_dev.isRxReady() and target.net_dev.deliverRxFrame(frame)) {
        target.pic.setPending(5);
        var it = target.vcores.start;
        while (it) |node| : (it = node.next) {
            const vc = node.contents;
            if (vc.exec_path == .native) {
                vc.getNativeMachine().hvip |= riscv.HVIP.VSEIP;
            }
        }
        wakeNetVcores(target);
        return;
    }
    sbi_core.deliverToQueue(target, &target.net_rx, frame);
}

pub fn deliverToParentDownstream(
    parent: *guest_mod.Guest,
    frame: []const u8,
) void {
    sbi_core.deliverToQueue(parent, &parent.net_rx, frame);
}

pub fn routeEthernetFrameOnPort(
    g: *guest_mod.Guest,
    pkt_buf: []u8,
    dest_cid: usize,
    port: NetPort,
) bool {
    if (g.isNetIsolated()) return false;
    if (port == .upstream_nic and g.hasParent() and
        pkt_buf.len >= ETH_HEADER_LEN)
    {
        pkt_buf[ETH_SRC_MAC_OFFSET] = LOCAL_ADMIN_MAC_PREFIX;
        pkt_buf[ETH_SRC_MAC_OFFSET + 1] = 0;
        pkt_buf[ETH_SRC_MAC_OFFSET + 2] = 0;
        pkt_buf[ETH_SRC_MAC_OFFSET + 3] = 0;
        pkt_buf[ETH_SRC_MAC_OFFSET + 4] =
            @intCast((g.local_cid >> 8) & BYTE_MASK);
        pkt_buf[ETH_SRC_MAC_OFFSET + 5] = @intCast(g.local_cid & BYTE_MASK);
    }
    const self_upstream = g.getNetUpstreamCid();
    const allow_up = (port == .upstream_nic) or !g.net_dev.isRxReady();
    if (dest_cid == 0) {
        if (port == .downstream_switch) {
            const s = g.tree_lock.lock();
            var it = g.children.start;
            while (it) |node| : (it = node.next) {
                const ch = node.contents;
                if (!ch.isNetIsolated() and ch.getNetUpstreamCid() == 0) {
                    deliverToChildUpstream(ch, pkt_buf);
                }
            }
            g.tree_lock.unlock(s);
        }
        if (allow_up) if (g.parent) |p| {
            if (self_upstream == 0 and !p.isNetIsolated()) {
                deliverToParentDownstream(p, pkt_buf);
            }
            const ps = p.tree_lock.lock();
            var pit = p.children.start;
            while (pit) |node| : (pit = node.next) {
                const sib = node.contents;
                if (sib != g and !sib.isNetIsolated() and
                    (sib.local_cid == self_upstream or
                        sib.getNetUpstreamCid() == g.local_cid))
                {
                    deliverToChildUpstream(sib, pkt_buf);
                }
            }
            p.tree_lock.unlock(ps);
        };
        return true;
    } else if (dest_cid == guest_mod.CID_SELF and g.hasParent() and allow_up) {
        if (self_upstream != 0) return false;
        if (g.parent) |p| {
            if (!p.isNetIsolated()) deliverToParentDownstream(p, pkt_buf);
        }
        return true;
    } else if (dest_cid >= guest_mod.CID_FIRST_CHILD) {
        if (port == .downstream_switch) {
            if (g.getGuestByCid(dest_cid)) |target| {
                const ok = !target.isNetIsolated() and
                    target.getNetUpstreamCid() == 0;
                if (!ok) return false;
                deliverToChildUpstream(target, pkt_buf);
                return true;
            }
        }
        if (allow_up) if (g.parent) |p| {
            if (p.getGuestByCid(dest_cid)) |target| {
                const allowed = target != g and !target.isNetIsolated() and
                    (dest_cid == self_upstream or
                        target.getNetUpstreamCid() == g.local_cid);
                if (!allowed) return false;
                deliverToChildUpstream(target, pkt_buf);
                return true;
            }
        };
    }
    return true;
}

pub fn routeEthernetFrame(
    g: *guest_mod.Guest,
    pkt_buf: []u8,
    dest_cid: usize,
) bool {
    return routeEthernetFrameOnPort(g, pkt_buf, dest_cid, .downstream_switch);
}

pub fn onVirtioNetTx(ctx: *anyopaque, frame: []const u8) void {
    const g: *guest_mod.Guest = @ptrCast(@alignCast(ctx));
    if (frame.len == 0 or frame.len > guest_mod.MAX_PACKET_LEN) return;
    var scratch: [guest_mod.MAX_PACKET_LEN]u8 = undefined;
    @memcpy(scratch[0..frame.len], frame);
    var dst_cid: usize = 0;
    if (frame.len >= ETH_HEADER_LEN and (frame[0] & 1) == 0 and
        frame[0] == LOCAL_ADMIN_MAC_PREFIX and
        frame[1] == 0 and frame[2] == 0 and frame[3] == 0)
    {
        dst_cid = (@as(usize, frame[4]) << 8) | frame[5];
    }
    _ = routeEthernetFrameOnPort(
        g,
        scratch[0..frame.len],
        dst_cid,
        .upstream_nic,
    );
}

test "guest/net: hierarchical L2 routing declarations" {
    std.testing.refAllDecls(@This());
}
