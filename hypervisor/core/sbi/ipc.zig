// Diosix SBI inter-guest memory mapping, manifest, and network handlers.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const riscv = @import("../../hardware/native/cpu/riscv64/mod.zig");
const sv39x4 = @import("../../hardware/native/cpu/riscv64/sv39x4.zig");
const vcore = @import("../vcore.zig");
const guest = @import("../guest.zig");
const physmem = @import("../physmem.zig");
const sbi_core = @import("../sbi.zig");
const charter = @import("charter.zig");
const interface = @import("interface").sbi;

inline fn reply(
    vc: *vcore.VirtualCore,
    ctx: *riscv.ThreadContext,
    err: isize,
    val: usize,
) void {
    sbi_core.setResult(vc, ctx, err, val);
}

fn isChildConfidentialLocked(child: *const guest.Guest) bool {
    const sealed = charter.isCharterSealed();
    return (child.is_steward and sealed) or
        (child.is_confidential and (sealed or child.hasAnyVcoreStarted()));
}

pub fn handleGetManifest(
    vc: *vcore.VirtualCore,
    context: *riscv.ThreadContext,
    g: *guest.Guest,
    a0: usize,
) void {
    var margs = g.space.readGuestStruct(interface.ManifestArgs, a0) catch {
        return reply(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
    };
    const target = g.getGuestByCid(@intCast(margs.target_cid)) orelse {
        return reply(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
    };
    if (target != g and
        (target.parent != g or isChildConfidentialLocked(target)))
    {
        return reply(vc, context, sbi_core.SBI_ERR_DENIED, 0);
    }
    const max_len: usize = @intCast(margs.max_len);
    const data_ptr: usize = @intCast(margs.data_ptr);
    const actual_len = target.getManifestLength();
    const alloc_len: usize = @min(max_len, actual_len);
    if (max_len > 0 and data_ptr != 0) {
        _ = std.math.add(usize, data_ptr, max_len) catch {
            return reply(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        };
    }
    if (alloc_len > 0 and data_ptr != 0) {
        const kbuf = target.allocator.alloc(u8, alloc_len) catch {
            return reply(vc, context, sbi_core.SBI_ERR_FAILED, 0);
        };
        defer target.allocator.free(kbuf);

        var copy_len: usize = 0;
        if (target.readManifest(kbuf)) |read_len| {
            copy_len = @min(alloc_len, read_len);
            g.space.copyToGuest(data_ptr, kbuf[0..copy_len]) catch {
                return reply(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
            };
            margs.actual_len = read_len;
        } else {
            margs.actual_len = 0;
        }
        g.space.writeGuestStruct(interface.ManifestArgs, a0, margs) catch {
            return reply(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        };
        reply(vc, context, sbi_core.SBI_SUCCESS, copy_len);
    } else {
        margs.actual_len = actual_len;
        g.space.writeGuestStruct(interface.ManifestArgs, a0, margs) catch {
            return reply(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        };
        reply(vc, context, sbi_core.SBI_SUCCESS, 0);
    }
}

pub fn handleSetManifest(
    vc: *vcore.VirtualCore,
    context: *riscv.ThreadContext,
    g: *guest.Guest,
    a0: usize,
) void {
    const margs = g.space.readGuestStruct(interface.ManifestArgs, a0) catch {
        return reply(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
    };
    const target = g.getGuestByCid(@intCast(margs.target_cid)) orelse {
        return reply(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
    };
    const can_set = if (target == g)
        (g.is_trusted or g.is_root)
    else
        (target.parent == g and !isChildConfidentialLocked(target));
    if (!can_set) {
        return reply(vc, context, sbi_core.SBI_ERR_DENIED, 0);
    }
    const max_len: usize = @intCast(margs.max_len);
    const data_ptr: usize = @intCast(margs.data_ptr);
    if (max_len == 0 or max_len > sbi_core.MAX_MANIFEST_SIZE_BYTES) {
        return reply(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
    }
    _ = std.math.add(usize, data_ptr, max_len) catch {
        return reply(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
    };
    const buf = target.allocator.alloc(u8, max_len) catch {
        return reply(vc, context, sbi_core.SBI_ERR_FAILED, 0);
    };
    defer target.allocator.free(buf);

    g.space.copyFromGuest(buf, data_ptr) catch {
        return reply(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
    };
    target.setManifest(buf) catch {
        return reply(vc, context, sbi_core.SBI_ERR_FAILED, 0);
    };
    reply(vc, context, sbi_core.SBI_SUCCESS, 0);
}

fn overlapsOwnRam(
    g: *const guest.Guest,
    gpa_start: usize,
    gpa_end: usize,
) bool {
    if (g.space.range_size == 0) return false;
    const own_start = g.space.base_gpa;
    const raw_end = own_start +| g.space.range_size;
    const own_end: usize = if (g.space.base_hpa != 0)
        raw_end
    else
        @min(raw_end, sbi_core.DIOSIX_CHILD_MEM_BASE);
    return gpa_start < own_end and gpa_end > own_start;
}

pub fn handleMapChildMem(
    vc: *vcore.VirtualCore,
    context: *riscv.ThreadContext,
    g: *guest.Guest,
    a0: usize,
) void {
    const margs = g.space.readGuestStruct(
        interface.MapChildMemArgs,
        a0,
    ) catch {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    const child = g.getGuestByCid(@intCast(margs.child_id)) orelse {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    };
    if (margs.child_id < guest.CID_FIRST_CHILD or
        child.parent != g or
        isChildConfidentialLocked(child))
    {
        return reply(vc, context, sbi_core.SBI_ERR_DENIED, 0);
    }
    const sz: usize = @intCast(margs.size);
    const c_gpa: usize = @intCast(margs.child_gpa);
    const p_gpa: usize = @intCast(margs.parent_gpa);
    if (sz == 0 or sz > sbi_core.MAX_FOREIGN_MAP_SIZE_BYTES or
        (sz % physmem.PageSize) != 0 or
        (c_gpa % physmem.PageSize) != 0 or
        (p_gpa % physmem.PageSize) != 0)
    {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }
    const c_end = std.math.add(usize, c_gpa, sz) catch {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    };
    const p_end = std.math.add(usize, p_gpa, sz) catch {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    };
    if (c_end > sv39x4.MAX_GPA or p_end > sv39x4.MAX_GPA or
        overlapsOwnRam(g, p_gpa, p_end))
    {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }
    const ap_end = sbi_core.DIOSIX_CHILD_MEM_BASE +
        sbi_core.DIOSIX_CHILD_MEM_MAX_SIZE;
    if (p_gpa < sbi_core.DIOSIX_CHILD_MEM_BASE or p_end > ap_end) {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }

    const parent_rwx = sv39x4.PTEFlags.leaf_rw_user;
    const child_rwx = sv39x4.PTEFlags.leaf_rwx_user;

    var offset: usize = 0;
    while (offset < sz) : (offset += physmem.PageSize) {
        const cur_c = c_gpa + offset;
        const cur_p = p_gpa + offset;
        const child_hpa = child.space.translateGPA(cur_c) catch blk: {
            if (!child.checkRamQuota(1)) {
                if (offset > 0) g.space.unmap(p_gpa, offset);
                sbi_core.setResult(vc, context, sbi_core.SBI_ERR_FAILED, 0);
                return;
            }
            const new_page = physmem.allocPage() catch {
                if (offset > 0) g.space.unmap(p_gpa, offset);
                sbi_core.setResult(vc, context, sbi_core.SBI_ERR_FAILED, 0);
                return;
            };
            @memset(@as([*]u8, @ptrFromInt(new_page))[0..physmem.PageSize], 0);
            child.space.map(
                cur_c,
                new_page,
                physmem.PageSize,
                child_rwx,
            ) catch {
                physmem.freePage(new_page);
                if (offset > 0) g.space.unmap(p_gpa, offset);
                sbi_core.setResult(vc, context, sbi_core.SBI_ERR_FAILED, 0);
                return;
            };
            child.consumeQuota(1, 0);
            physmem.decrementPageRef(new_page);
            break :blk new_page;
        };
        if (physmem.isHypervisorMemory(child_hpa, physmem.PageSize)) {
            if (offset > 0) g.space.unmap(p_gpa, offset);
            sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
            return;
        }
        g.space.map(cur_p, child_hpa, physmem.PageSize, parent_rwx) catch {
            if (offset > 0) g.space.unmap(p_gpa, offset);
            sbi_core.setResult(vc, context, sbi_core.SBI_ERR_FAILED, 0);
            return;
        };
    }
    riscv.hfenceGvma();
    sbi_core.setResult(vc, context, sbi_core.SBI_SUCCESS, sz);
}

pub fn handleUnmapChildMem(
    vc: *vcore.VirtualCore,
    context: *riscv.ThreadContext,
    g: *guest.Guest,
    a0: usize,
) void {
    const uargs = g.space.readGuestStruct(
        interface.UnmapChildMemArgs,
        a0,
    ) catch {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    const sz: usize = @intCast(uargs.size);
    const p_gpa: usize = @intCast(uargs.parent_gpa);
    if (sz == 0 or sz > sbi_core.MAX_FOREIGN_MAP_SIZE_BYTES or
        (sz % physmem.PageSize) != 0 or
        (p_gpa % physmem.PageSize) != 0)
    {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }
    const p_end = std.math.add(usize, p_gpa, sz) catch {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    };
    const ap_end = sbi_core.DIOSIX_CHILD_MEM_BASE +
        sbi_core.DIOSIX_CHILD_MEM_MAX_SIZE;
    if (p_end > sv39x4.MAX_GPA or overlapsOwnRam(g, p_gpa, p_end) or
        p_gpa < sbi_core.DIOSIX_CHILD_MEM_BASE or p_end > ap_end)
    {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }
    g.space.unmap(p_gpa, sz);
    riscv.hfenceGvma();
    sbi_core.setResult(vc, context, sbi_core.SBI_SUCCESS, 0);
}

pub fn handleSetNetPolicy(
    vc: *vcore.VirtualCore,
    context: *riscv.ThreadContext,
    g: *guest.Guest,
    target_cid: usize,
    flags: usize,
    upstream_cid: usize,
) void {
    if (target_cid < guest.CID_FIRST_CHILD) {
        return reply(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
    }
    const child = g.getGuestByCid(target_cid) orelse {
        return reply(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
    };
    if (child.parent != g and !g.is_root) {
        return reply(vc, context, sbi_core.SBI_ERR_DENIED, 0);
    }
    const norm_upstream: usize = if (upstream_cid == guest.CID_SELF)
        0
    else
        upstream_cid;
    if (norm_upstream != 0 and
        (norm_upstream == target_cid or g.getGuestByCid(norm_upstream) == null))
    {
        return reply(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
    }
    child.setNetIsolated((flags & interface.NetPolicyFlags.ISOLATED) != 0);
    child.setNetUpstreamCid(norm_upstream);
    reply(vc, context, sbi_core.SBI_SUCCESS, 0);
}

const ETH_HEADER_LEN: usize = 14;
const ETH_SRC_MAC_OFFSET: usize = 6;
const LOCAL_ADMIN_MAC_PREFIX: u8 = 0x02;
const BYTE_MASK: usize = 0xff;

pub fn handleNetSend(
    vc: *vcore.VirtualCore,
    context: *riscv.ThreadContext,
    g: *guest.Guest,
    a0: usize,
    a1: usize,
    dest_cid: usize,
) void {
    if (g.isNetIsolated()) {
        return reply(vc, context, sbi_core.SBI_ERR_DENIED, 0);
    }
    if (a1 == 0 or a1 > guest.MAX_PACKET_LEN) {
        return reply(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
    }
    const pkt_len = a1;
    _ = std.math.add(usize, a0, pkt_len) catch {
        return reply(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
    };
    const pkt_buf = g.allocator.alloc(u8, pkt_len) catch {
        return reply(vc, context, sbi_core.SBI_ERR_FAILED, 0);
    };
    defer g.allocator.free(pkt_buf);

    g.space.copyFromGuest(pkt_buf, a0) catch {
        return reply(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
    };
    if (!g.is_root and pkt_buf.len >= ETH_HEADER_LEN) {
        pkt_buf[ETH_SRC_MAC_OFFSET] = LOCAL_ADMIN_MAC_PREFIX;
        pkt_buf[ETH_SRC_MAC_OFFSET + 1] = 0;
        pkt_buf[ETH_SRC_MAC_OFFSET + 2] = 0;
        pkt_buf[ETH_SRC_MAC_OFFSET + 3] = 0;
        pkt_buf[ETH_SRC_MAC_OFFSET + 4] =
            @intCast((g.local_cid >> 8) & BYTE_MASK);
        pkt_buf[ETH_SRC_MAC_OFFSET + 5] = @intCast(g.local_cid & BYTE_MASK);
    }
    const self_upstream = g.getNetUpstreamCid();
    if (dest_cid == 0) {
        {
            const s = g.tree_lock.lock();
            var it = g.children.start;
            while (it) |node| : (it = node.next) {
                const ch = node.contents;
                if (!ch.isNetIsolated() and ch.getNetUpstreamCid() == 0) {
                    sbi_core.deliverToQueue(ch, &ch.net_rx, pkt_buf);
                }
            }
            g.tree_lock.unlock(s);
        }
        if (g.parent) |p| {
            if (self_upstream == 0 and !p.isNetIsolated()) {
                sbi_core.deliverToQueue(p, &p.net_rx, pkt_buf);
            }
            const ps = p.tree_lock.lock();
            var pit = p.children.start;
            while (pit) |node| : (pit = node.next) {
                const sib = node.contents;
                if (sib != g and !sib.isNetIsolated() and
                    (sib.local_cid == self_upstream or
                        sib.getNetUpstreamCid() == g.local_cid))
                {
                    sbi_core.deliverToQueue(sib, &sib.net_rx, pkt_buf);
                }
            }
            p.tree_lock.unlock(ps);
        }
    } else if (dest_cid == guest.CID_SELF and !g.is_root) {
        if (self_upstream != 0) {
            return reply(vc, context, sbi_core.SBI_ERR_DENIED, 0);
        }
        if (g.parent) |p| {
            if (!p.isNetIsolated()) {
                sbi_core.deliverToQueue(p, &p.net_rx, pkt_buf);
            }
        }
    } else if (dest_cid >= guest.CID_FIRST_CHILD) {
        if (g.getGuestByCid(dest_cid)) |target| {
            if (target.isNetIsolated() or target.getNetUpstreamCid() != 0) {
                return reply(vc, context, sbi_core.SBI_ERR_DENIED, 0);
            }
            sbi_core.deliverToQueue(target, &target.net_rx, pkt_buf);
        } else if (g.parent) |p| {
            if (p.getGuestByCid(dest_cid)) |target| {
                const allowed = target != g and !target.isNetIsolated() and
                    (dest_cid == self_upstream or
                        target.getNetUpstreamCid() == g.local_cid);
                if (!allowed) {
                    return reply(vc, context, sbi_core.SBI_ERR_DENIED, 0);
                }
                sbi_core.deliverToQueue(target, &target.net_rx, pkt_buf);
            }
        }
    }
    reply(vc, context, sbi_core.SBI_SUCCESS, 0);
}

test "SBI IPC manifest and network handlers" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    const alloc = testing.allocator;
    const arch = @import("interface").riscv;
    var phys_test = try physmem.initForTest(alloc, 128);
    defer phys_test.deinit();

    const g = try guest.createGuest(alloc, true, true, null, 0, 0, 0, .riscv64);
    defer g.deinit();
    const page = try physmem.allocPage();
    try g.space.map(
        0x80000000,
        page,
        physmem.PageSize,
        sv39x4.PTEFlags.leaf_rw_user,
    );
    physmem.decrementPageRef(page);

    var vc = vcore.VirtualCore.init(0, g, 0x80000000, 0, .normal);
    var ctx: riscv.ThreadContext = @splat(0);

    const payload = "manifest-test";
    try g.space.copyToGuest(0x80000200, payload);
    const set_args = interface.ManifestArgs{
        .target_cid = guest.CID_SELF,
        .data_ptr = 0x80000200,
        .max_len = payload.len,
        .actual_len = 0,
    };
    try g.space.writeGuestStruct(interface.ManifestArgs, 0x80000000, set_args);
    handleSetManifest(&vc, &ctx, g, 0x80000000);
    try testing.expectEqual(@as(usize, 0), ctx[@backingInt(arch.Register.a0)]);

    const get_args = interface.ManifestArgs{
        .target_cid = guest.CID_SELF,
        .data_ptr = 0x80000400,
        .max_len = 4096,
        .actual_len = 0,
    };
    try g.space.writeGuestStruct(interface.ManifestArgs, 0x80000000, get_args);
    handleGetManifest(&vc, &ctx, g, 0x80000000);
    try testing.expectEqual(@as(usize, 0), ctx[@backingInt(arch.Register.a0)]);
    try testing.expectEqual(payload.len, ctx[@backingInt(arch.Register.a1)]);

    const c_router = try g.createChild(false, .riscv64, 1);
    defer c_router.deinit();
    const c_app = try g.createChild(false, .riscv64, 1);
    defer c_app.deinit();
    const c_peer = try g.createChild(false, .riscv64, 1);
    defer c_peer.deinit();
    const p_app = try physmem.allocPage();
    try c_app.space.map(
        0x80000000,
        p_app,
        physmem.PageSize,
        sv39x4.PTEFlags.leaf_rw_user,
    );
    physmem.decrementPageRef(p_app);
    try c_app.space.copyToGuest(0x80000000, "frame");
    var vc_app = vcore.VirtualCore.init(0, c_app, 0x80000000, 0, .normal);

    // Direct sibling-to-sibling frame injection is denied by default.
    handleNetSend(&vc_app, &ctx, c_app, 0x80000000, 5, c_peer.local_cid);
    const denied: usize = @bitCast(sbi_core.SBI_ERR_DENIED);
    try testing.expectEqual(denied, ctx[@backingInt(arch.Register.a0)]);
    try testing.expectEqual(@as(usize, 0), c_peer.net_rx.getCount());

    // Designate c_router as upstream gateway for c_app; traffic to c_router
    // is permitted while traffic to unrelated c_peer remains denied.
    handleSetNetPolicy(&vc, &ctx, g, c_app.local_cid, 0, c_router.local_cid);
    try testing.expectEqual(@as(usize, 0), ctx[@backingInt(arch.Register.a0)]);
    handleNetSend(&vc_app, &ctx, c_app, 0x80000000, 5, guest.CID_SELF);
    try testing.expectEqual(denied, ctx[@backingInt(arch.Register.a0)]);
    handleNetSend(&vc_app, &ctx, c_app, 0x80000000, 5, c_router.local_cid);
    try testing.expectEqual(@as(usize, 0), ctx[@backingInt(arch.Register.a0)]);
    try testing.expectEqual(@as(usize, 1), c_router.net_rx.getCount());

    // Isolate c_app completely; all outbound frames are denied.
    const iso_flag = interface.NetPolicyFlags.ISOLATED;
    handleSetNetPolicy(&vc, &ctx, g, c_app.local_cid, iso_flag, 0);
    handleNetSend(&vc_app, &ctx, c_app, 0x80000000, 5, guest.CID_SELF);
    try testing.expectEqual(denied, ctx[@backingInt(arch.Register.a0)]);
}
