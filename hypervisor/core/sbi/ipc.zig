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

pub fn handleGetManifest(
    vc: *vcore.VirtualCore,
    context: *riscv.ThreadContext,
    g: *guest.Guest,
    a0: usize,
) void {
    var margs = g.space.readGuestStruct(interface.ManifestArgs, a0) catch {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    const target = g.getGuestByCid(@intCast(margs.target_cid)) orelse {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    };
    const max_len: usize = @intCast(margs.max_len);
    const data_ptr: usize = @intCast(margs.data_ptr);
    const actual_len = target.getManifestLength();
    const alloc_len: usize = @min(max_len, actual_len);
    if (max_len > 0 and data_ptr != 0) {
        _ = std.math.add(usize, data_ptr, max_len) catch {
            sbi_core.setResult(
                vc,
                context,
                sbi_core.SBI_ERR_INVALID_ADDRESS,
                0,
            );
            return;
        };
    }
    if (alloc_len > 0 and data_ptr != 0) {
        const kbuf = target.allocator.alloc(u8, alloc_len) catch {
            sbi_core.setResult(vc, context, sbi_core.SBI_ERR_FAILED, 0);
            return;
        };
        defer target.allocator.free(kbuf);

        var copy_len: usize = 0;
        if (target.readManifest(kbuf)) |read_len| {
            const cl: usize = @min(alloc_len, read_len);
            copy_len = cl;
            g.space.copyToGuest(data_ptr, kbuf[0..copy_len]) catch {
                sbi_core.setResult(
                    vc,
                    context,
                    sbi_core.SBI_ERR_INVALID_ADDRESS,
                    0,
                );
                return;
            };
            margs.actual_len = read_len;
        } else {
            margs.actual_len = 0;
        }
        g.space.writeGuestStruct(interface.ManifestArgs, a0, margs) catch {
            sbi_core.setResult(
                vc,
                context,
                sbi_core.SBI_ERR_INVALID_ADDRESS,
                0,
            );
            return;
        };
        sbi_core.setResult(vc, context, sbi_core.SBI_SUCCESS, copy_len);
    } else {
        margs.actual_len = actual_len;
        g.space.writeGuestStruct(interface.ManifestArgs, a0, margs) catch {
            sbi_core.setResult(
                vc,
                context,
                sbi_core.SBI_ERR_INVALID_ADDRESS,
                0,
            );
            return;
        };
        sbi_core.setResult(vc, context, sbi_core.SBI_SUCCESS, 0);
    }
}

pub fn handleSetManifest(
    vc: *vcore.VirtualCore,
    context: *riscv.ThreadContext,
    g: *guest.Guest,
    a0: usize,
) void {
    const margs = g.space.readGuestStruct(interface.ManifestArgs, a0) catch {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    const target = g.getGuestByCid(@intCast(margs.target_cid)) orelse {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    };
    if (!g.is_trusted and !g.is_root and target.parent != g) {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_DENIED, 0);
        return;
    }
    const max_len: usize = @intCast(margs.max_len);
    const data_ptr: usize = @intCast(margs.data_ptr);
    if (max_len == 0 or max_len > sbi_core.MAX_MANIFEST_SIZE_BYTES) {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }
    _ = std.math.add(usize, data_ptr, max_len) catch {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    const buf = target.allocator.alloc(u8, max_len) catch {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_FAILED, 0);
        return;
    };
    defer target.allocator.free(buf);

    g.space.copyFromGuest(buf, data_ptr) catch {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    target.setManifest(buf) catch {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_FAILED, 0);
        return;
    };
    sbi_core.setResult(vc, context, sbi_core.SBI_SUCCESS, 0);
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
    if (child == g or (child.parent != g and !g.is_root)) {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_DENIED, 0);
        return;
    }
    const child_started = child.hasAnyVcoreStarted();
    if ((child.is_steward and charter.isCharterSealed()) or
        (child.is_confidential and
            (charter.isCharterSealed() or child_started)))
    {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_DENIED, 0);
        return;
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
    if (!g.is_root and
        (p_gpa < sbi_core.DIOSIX_CHILD_MEM_BASE or p_end > ap_end))
    {
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
                sbi_core.setResult(vc, context, sbi_core.SBI_ERR_FAILED, 0);
                return;
            }
            const new_page = physmem.allocPage() catch {
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
                sbi_core.setResult(vc, context, sbi_core.SBI_ERR_FAILED, 0);
                return;
            };
            child.consumeQuota(1, 0);
            physmem.decrementPageRef(new_page);
            break :blk new_page;
        };
        if (physmem.isHypervisorMemory(child_hpa, physmem.PageSize)) {
            sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
            return;
        }
        g.space.map(cur_p, child_hpa, physmem.PageSize, parent_rwx) catch {
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
        (!g.is_root and
            (p_gpa < sbi_core.DIOSIX_CHILD_MEM_BASE or p_end > ap_end)))
    {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }
    g.space.unmap(p_gpa, sz);
    riscv.hfenceGvma();
    sbi_core.setResult(vc, context, sbi_core.SBI_SUCCESS, 0);
}

pub fn handleNetSend(
    vc: *vcore.VirtualCore,
    context: *riscv.ThreadContext,
    g: *guest.Guest,
    a0: usize,
    a1: usize,
    dest_cid: usize,
) void {
    if (a1 == 0 or a1 > guest.MAX_PACKET_LEN) {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
        return;
    }
    const pkt_len = a1;
    _ = std.math.add(usize, a0, pkt_len) catch {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };
    const pkt_buf = g.allocator.alloc(u8, pkt_len) catch {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_FAILED, 0);
        return;
    };
    defer g.allocator.free(pkt_buf);

    g.space.copyFromGuest(pkt_buf, a0) catch {
        sbi_core.setResult(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
        return;
    };

    if (dest_cid == 0) {
        {
            const s = g.tree_lock.lock();
            var it = g.children.start;
            while (it) |node| : (it = node.next) {
                sbi_core.deliverToQueue(
                    node.contents,
                    &node.contents.net_rx,
                    pkt_buf,
                );
            }
            g.tree_lock.unlock(s);
        }
        if (g.parent) |p| sbi_core.deliverToQueue(p, &p.net_rx, pkt_buf);
    } else if (dest_cid == guest.CID_PARENT or
        (dest_cid == guest.CID_SELF and !g.is_root))
    {
        if (g.parent) |p| sbi_core.deliverToQueue(p, &p.net_rx, pkt_buf);
    } else if (dest_cid >= guest.CID_FIRST_CHILD) {
        if (g.getGuestByCid(dest_cid)) |target| {
            sbi_core.deliverToQueue(target, &target.net_rx, pkt_buf);
        } else if (g.parent) |p| {
            if (p.getGuestByCid(dest_cid)) |target| {
                sbi_core.deliverToQueue(target, &target.net_rx, pkt_buf);
            }
        }
    }
    sbi_core.setResult(vc, context, sbi_core.SBI_SUCCESS, 0);
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
}
