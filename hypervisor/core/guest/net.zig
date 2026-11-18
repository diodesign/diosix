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
const ETH_TYPE_OFFSET: usize = 12;
const ETH_TYPE_ARP: u16 = 0x0806;
const ETH_TYPE_VLAN: u16 = 0x8100;
const ETH_TYPE_QINQ: u16 = 0x88a8;
const ETH_TYPE_QINQ_ALT: u16 = 0x9100;
const ARP_MIN_LEN: usize = 28;
const ARP_HLEN_OFFSET: usize = 18;
const ARP_SHA_OFFSET: usize = 22;
const LOCAL_ADMIN_MAC_PREFIX: u8 = 0x02;
const BYTE_MASK: usize = 0xff;

pub const NetPort = enum { downstream_switch, upstream_nic };

/// Returns a child-originated Ethernet frame copy with authentic source MAC
/// and ARP sender hardware address stamped to `02:00:00:00:HI:LO`.
fn sanitizeUpwardChildFrame(
    g: *guest_mod.Guest,
    raw: []const u8,
    out: *[guest_mod.MAX_PACKET_LEN]u8,
) ?[]u8 {
    if (raw.len < ETH_HEADER_LEN or raw.len > out.len) return null;
    const eth_type = (@as(u16, raw[ETH_TYPE_OFFSET]) << 8) |
        raw[ETH_TYPE_OFFSET + 1];
    if (eth_type == ETH_TYPE_VLAN or eth_type == ETH_TYPE_QINQ or
        eth_type == ETH_TYPE_QINQ_ALT)
    {
        return null;
    }
    @memcpy(out[0..raw.len], raw);
    const hi: u8 = @intCast((g.local_cid >> 8) & BYTE_MASK);
    const lo: u8 = @intCast(g.local_cid & BYTE_MASK);
    const mac = [6]u8{ LOCAL_ADMIN_MAC_PREFIX, 0, 0, 0, hi, lo };
    @memcpy(out[ETH_SRC_MAC_OFFSET .. ETH_SRC_MAC_OFFSET + 6], &mac);
    if (eth_type == ETH_TYPE_ARP) {
        if (raw.len < ARP_MIN_LEN or raw[ARP_HLEN_OFFSET] != 6) return null;
        @memcpy(out[ARP_SHA_OFFSET .. ARP_SHA_OFFSET + 6], &mac);
    }
    return out[0..raw.len];
}

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
    if (target.net_dev.isRxReady()) {
        if (target.net_dev.deliverRxFrame(frame)) {
            target.pic.setPending(5);
            var it = target.vcores.start;
            while (it) |node| : (it = node.next) {
                const vc = node.contents;
                if (vc.exec_path == .native) {
                    vc.getNativeMachine().hvip |= riscv.HVIP.VSEIP;
                }
            }
            wakeNetVcores(target);
        }
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
    const self_upstream = g.getNetUpstreamCid();
    const allow_up = (port == .upstream_nic) or !g.net_dev.isRxReady();
    var up_scratch: [guest_mod.MAX_PACKET_LEN]u8 = undefined;
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
            const up_pkt = sanitizeUpwardChildFrame(
                g,
                pkt_buf,
                &up_scratch,
            ) orelse return false;
            if (self_upstream == 0 and !p.isNetIsolated()) {
                deliverToParentDownstream(p, up_pkt);
            }
            const ps = p.tree_lock.lock();
            var pit = p.children.start;
            while (pit) |node| : (pit = node.next) {
                const sib = node.contents;
                if (sib != g and !sib.isNetIsolated() and
                    (sib.local_cid == self_upstream or
                        sib.getNetUpstreamCid() == g.local_cid))
                {
                    deliverToChildUpstream(sib, up_pkt);
                }
            }
            p.tree_lock.unlock(ps);
        };
        return true;
    } else if (dest_cid == guest_mod.CID_SELF and g.hasParent() and allow_up) {
        if (self_upstream != 0) return false;
        const up_pkt = sanitizeUpwardChildFrame(
            g,
            pkt_buf,
            &up_scratch,
        ) orelse return false;
        if (g.parent) |p| {
            if (!p.isNetIsolated()) deliverToParentDownstream(p, up_pkt);
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
                const up_pkt = sanitizeUpwardChildFrame(
                    g,
                    pkt_buf,
                    &up_scratch,
                ) orelse return false;
                deliverToChildUpstream(target, up_pkt);
                return true;
            }
        };
    }
    return false;
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

test "guest/net: stamps MAC and ARP SHA on NET_SEND and blocks 802.1Q" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    const physmem = @import("../physmem.zig");
    const quota_mod = @import("quota.zig");
    scheduler.init();
    scheduler.initCpu();
    quota_mod.resetGuestManagerForTest();
    var phys = try physmem.initForTest(testing.allocator, 256);
    defer phys.deinit();

    const parent = try guest_mod.createGuest(
        testing.allocator,
        true,
        true,
        null,
        0,
        0,
        0,
        .riscv64,
    );
    defer parent.deinit();
    const child = try parent.createChild(false, .riscv64, 1);
    defer child.deinit();

    // Spoofed ARP frame sent via SBI NET_SEND path (.downstream_switch).
    var arp: [42]u8 = @splat(0);
    @memset(arp[0..6], 0xff);
    @memcpy(arp[6..12], &[_]u8{ 0x06, 0x11, 0x22, 0x33, 0x44, 0x55 });
    arp[12] = 0x08;
    arp[13] = 0x06;
    arp[18] = 6;
    @memcpy(arp[22..28], &[_]u8{ 0x06, 0xaa, 0xbb, 0xcc, 0xdd, 0xee });
    try testing.expect(routeEthernetFrame(child, &arp, 0));

    var rx: [64]u8 = @splat(0);
    const n = parent.net_rx.pop(&rx) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 42), n);
    try testing.expectEqual(@as(u8, 0x02), rx[6]);
    try testing.expectEqual(@as(u8, @truncate(child.local_cid)), rx[11]);
    try testing.expectEqualSlices(u8, rx[6..12], rx[22..28]);

    // 802.1Q VLAN frame is rejected.
    var vlan: [32]u8 = @splat(0);
    vlan[12] = 0x81;
    vlan[13] = 0x00;
    try testing.expect(!routeEthernetFrame(child, &vlan, 0));
}
