// Diosix SBI Tier 1 Stage-2 Zero-Copy Child Desktop Scanout Mapping Handler
//
// Maps a direct non-confidential child's VirtIO-GPU framebuffer pages read-only
// into the caller's Stage-2 aperture at SCANOUT_MAP_GPA_BASE via a 2-slot LRU
// cache, returns accumulated dirty rectangles and cursor overlays, and tears
// down child scanout mappings before child memory is freed.
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
const desktop = @import("desktop.zig");
const ipc = @import("ipc.zig");
const emulation = @import("emulation");
const interface = @import("interface").sbi;

const damage_mod = emulation.VirtioGpu.damage_mod;
pub const slots = @import("scanout_map/slots.zig");
pub const unmapSlotLocked = slots.unmapSlotLocked;
pub const unmapOnGuestTeardown = slots.unmapOnGuestTeardown;
const findOrMapZeroCopyLocked = slots.findOrMapZeroCopyLocked;

fn reply(
    vc: *vcore.VirtualCore,
    context: *riscv.ThreadContext,
    err: isize,
    val: usize,
) void {
    sbi_core.setResult(vc, context, err, val);
}

fn streamCursorToCallerLocked(
    caller: *guest.Guest,
    gpu: *emulation.VirtioGpu,
    cursor_pixels_ptr: u64,
    cursor_h: u32,
) bool {
    var row_buf: [damage_mod.CURSOR_PIXELS / 64]u32 = undefined;
    const row_bytes = row_buf.len * @sizeOf(u32);
    for (0..64) |ry| {
        if (ry < cursor_h) {
            if (!damage_mod.extractCursorRowArgb64(gpu, ry, &row_buf)) {
                @memset(&row_buf, 0);
            }
        } else {
            @memset(&row_buf, 0);
        }
        const dst_gpa = std.math.add(
            usize,
            @as(usize, @intCast(cursor_pixels_ptr)),
            ry * row_bytes,
        ) catch return false;
        caller.space.copyToGuest(dst_gpa, std.mem.asBytes(&row_buf)) catch {
            return false;
        };
    }
    return true;
}

fn handleUnmapRequest(
    vc: *vcore.VirtualCore,
    context: *riscv.ThreadContext,
    caller: *guest.Guest,
    a0: usize,
    args: *interface.GpuMapScanoutArgs,
) void {
    var any_unmapped = false;
    {
        const s = caller.scanout_map_lock.lock();
        defer caller.scanout_map_lock.unlock(s);
        if (args.target_cid == 0) {
            for (0..interface.SCANOUT_SLOT_COUNT) |i| {
                if (unmapSlotLocked(caller, i)) any_unmapped = true;
            }
        } else if (caller.getGuestByCid(@intCast(args.target_cid))) |target| {
            for (0..interface.SCANOUT_SLOT_COUNT) |i| {
                if (caller.scanout_map_slots[i].child_guest_id == target.id) {
                    if (unmapSlotLocked(caller, i)) any_unmapped = true;
                }
            }
        }
        if (any_unmapped) riscv.hfenceGvma();
    }
    args.slot_offset_bytes = 0;
    args.mapped_bytes = 0;
    args.flags = 0;
    caller.space.writeGuestStruct(interface.GpuMapScanoutArgs, a0, args.*) catch
        return reply(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
    reply(vc, context, sbi_core.SBI_SUCCESS, 0);
}

/// SBI handler for DIOSIX_GPU_MAP_SCANOUT (`FID 30`).
pub fn handleGpuMapScanout(
    vc: *vcore.VirtualCore,
    context: *riscv.ThreadContext,
    caller: *guest.Guest,
    a0: usize,
) void {
    var args = caller.space.readGuestStruct(
        interface.GpuMapScanoutArgs,
        a0,
    ) catch return reply(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);

    if ((args.flags & interface.GpuScanoutFlags.UNMAP) != 0) {
        return handleUnmapRequest(vc, context, caller, a0, &args);
    }

    const target = caller.getGuestByCid(@intCast(args.target_cid)) orelse
        return reply(vc, context, sbi_core.SBI_ERR_INVALID_PARAM, 0);
    if (!desktop.canAccessGuestDesktop(caller, target)) {
        return reply(vc, context, sbi_core.SBI_ERR_DENIED, 0);
    }

    if ((args.flags & interface.GpuScanoutFlags.SET_DISPLAY_SIZE) != 0 and
        args.width > 0 and args.height > 0)
    {
        if (target.gpu.setDisplaySize(args.width, args.height)) {
            desktop.notifyTargetVcoresIrq(target);
        }
    }

    const ap_base = interface.SCANOUT_MAP_GPA_BASE;
    const ap_end = ap_base + interface.SCANOUT_APERTURE_BYTES;
    const can_aperture = caller.space.mode == .h_paging and
        !ipc.overlapsOwnRam(caller, ap_base, ap_end);

    const prev_frame_seq = args.frame_seq;
    const prev_cursor_seq = args.cursor_seq;
    const was_cursor_vis = (args.flags &
        interface.GpuScanoutFlags.CURSOR_VISIBLE) != 0;

    {
        const s = caller.scanout_map_lock.lock();
        defer caller.scanout_map_lock.unlock(s);

        target.gpu.acquireLock();
        defer target.gpu.releaseLock();

        const cur_frame_seq = target.gpu.frame_seq.load(.acquire);
        const cur_cursor_seq = target.gpu.cursor_seq.load(.acquire);
        args.frame_seq = cur_frame_seq;
        args.cursor_seq = cur_cursor_seq;
        args.slot_offset_bytes = 0;
        args.mapped_bytes = 0;
        args.width = 0;
        args.height = 0;
        args.stride_pixels = 0;
        args.format = 0;
        args.dirty_x = 0;
        args.dirty_y = 0;
        args.dirty_w = 0;
        args.dirty_h = 0;
        args.flags = 0;

        const res = if (target.gpu.active_scanout_res_id != 0)
            target.gpu.getResourceUnlocked(target.gpu.active_scanout_res_id)
        else
            null;
        if (res) |r| {
            const w = if (target.gpu.scanout_rect.width > 0)
                target.gpu.scanout_rect.width
            else
                r.width;
            const h = if (target.gpu.scanout_rect.height > 0)
                target.gpu.scanout_rect.height
            else
                r.height;
            if (w > 0 and h > 0 and r.entriesSlice().len > 0) {
                args.flags |= interface.GpuScanoutFlags.ACTIVE;
                if (cur_frame_seq != prev_frame_seq) {
                    args.flags |= interface.GpuScanoutFlags.UPDATED;
                }
                args.width = w;
                args.height = h;
                args.stride_pixels = r.width;
                args.format = r.format;

                const dirty = target.gpu.damage_ring.computeDirtyRectSince(
                    prev_frame_seq,
                    cur_frame_seq,
                    w,
                    h,
                );
                args.dirty_x = dirty.x;
                args.dirty_y = dirty.y;
                args.dirty_w = dirty.width;
                args.dirty_h = dirty.height;

                const pages_opt = damage_mod.isZeroCopyCompatible(
                    &target.gpu,
                    r,
                    interface.MAX_GPU_SCANOUT_PAGES,
                );
                if (can_aperture and pages_opt != null) {
                    const page_count = pages_opt.?;
                    if (findOrMapZeroCopyLocked(
                        caller,
                        target,
                        r,
                        page_count,
                    )) |slot_idx| {
                        const F = interface.GpuScanoutFlags;
                        const off_u64 =
                            slot_idx * interface.SCANOUT_SLOT_BYTES;
                        args.slot_offset_bytes = @intCast(off_u64);
                        args.mapped_bytes = @intCast(
                            @as(usize, page_count) * physmem.PageSize,
                        );
                        args.flags |= F.MAPPED_ZERO_COPY;
                    }
                }
            }
        }

        const cmeta = damage_mod.getCursorMetaLocked(&target.gpu);
        args.cursor_x = @bitCast(target.gpu.cursor_x);
        args.cursor_y = @bitCast(target.gpu.cursor_y);
        args.cursor_hot_x = target.gpu.cursor_hot_x;
        args.cursor_hot_y = target.gpu.cursor_hot_y;
        args.cursor_w = cmeta.width;
        args.cursor_h = cmeta.height;
        if (cmeta.visible) {
            args.flags |= interface.GpuScanoutFlags.CURSOR_VISIBLE;
            const need_cursor = (cur_cursor_seq != prev_cursor_seq) or
                !was_cursor_vis;
            if (args.cursor_pixels_ptr != 0 and need_cursor) {
                if (streamCursorToCallerLocked(
                    caller,
                    &target.gpu,
                    args.cursor_pixels_ptr,
                    cmeta.height,
                )) {
                    args.flags |=
                        interface.GpuScanoutFlags.CURSOR_SHAPE_UPDATED;
                }
            }
        }
    }

    caller.space.writeGuestStruct(interface.GpuMapScanoutArgs, a0, args) catch
        return reply(vc, context, sbi_core.SBI_ERR_INVALID_ADDRESS, 0);
    reply(vc, context, sbi_core.SBI_SUCCESS, 0);
}

test "SBI zero-copy scanout, LRU slots, confidential deny & teardown" {
    _ = slots;
    std.testing.refAllDecls(@This());
    const t = std.testing;
    const arch = @import("interface").riscv;
    const F = interface.GpuScanoutFlags;
    const Args = interface.GpuMapScanoutArgs;
    const vgpu = emulation.VirtioGpu;
    const vproto = vgpu.proto_mod;
    const vcmds = vgpu.commands_mod;
    const rw = sv39x4.PTEFlags.leaf_rw_user;
    const a0_reg = @backingInt(arch.Register.a0);

    @import("../scheduler.zig").init();
    @import("../scheduler.zig").initCpu();
    var phys = try physmem.initForTest(t.allocator, 256);
    defer phys.deinit();

    const p = try guest.createGuest(
        t.allocator,
        true,
        true,
        null,
        0,
        0,
        0,
        .riscv64,
    );
    defer p.deinit();
    for ([_]usize{ 0x8000_0000, 0x8000_1000 }) |gpa| {
        const pg = try physmem.allocPage();
        try p.space.map(gpa, pg, physmem.PageSize, rw);
        physmem.decrementPageRef(pg);
    }

    const c = try p.createChild(false, .riscv64, 1);
    const c_pg = try physmem.allocPage();
    try c.space.map(0x8000_0000, c_pg, physmem.PageSize, rw);
    physmem.decrementPageRef(c_pg);
    try c.space.copyToGuest(0x8000_0000, &[_]u8{ 0x11, 0x22, 0x33, 0xff });

    for ([_]u32{ 1, 2 }) |rid| {
        _ = vcmds.handleResourceCreate2DLocked(&c.gpu, &.{
            .hdr = .{},
            .resource_id = rid,
            .format = vproto.VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM,
            .width = 1,
            .height = 1,
        });
        const ent = [_]vproto.VirtioGpuMemEntry{
            .{ .addr = 0x8000_0000, .length = 4096 },
        };
        _ = vcmds.handleAttachBackingSliceLocked(
            &c.gpu,
            &.{ .hdr = .{}, .resource_id = rid, .nr_entries = 1 },
            &ent,
        );
    }
    _ = vcmds.handleSetScanoutLocked(&c.gpu, &.{
        .hdr = .{},
        .r = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .scanout_id = 0,
        .resource_id = 1,
    });
    _ = vcmds.handleResourceFlushLocked(&c.gpu, &.{
        .hdr = .{},
        .r = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .resource_id = 1,
        .padding = 0,
    });
    var p_vc = vcore.VirtualCore.init(0, p, 0x8000_0000, 0, .normal);
    var ctx: riscv.ThreadContext = @splat(0);

    try p.space.writeGuestStruct(Args, 0x8000_0000, .{
        .target_cid = c.local_cid,
        .cursor_pixels_ptr = 0x8000_1000,
    });
    handleGpuMapScanout(&p_vc, &ctx, p, 0x8000_0000);
    try t.expectEqual(@as(usize, 0), ctx[a0_reg]);
    const res1 = try p.space.readGuestStruct(Args, 0x8000_0000);
    try t.expect((res1.flags & F.MAPPED_ZERO_COPY) != 0);
    try t.expectEqual(@as(u32, 0), res1.slot_offset_bytes);
    try t.expectEqual(@as(u32, 2), physmem.getPageRef(c_pg));
    const pte = (try p.space.paging.?.walk(
        interface.SCANOUT_MAP_GPA_BASE,
        false,
    )).*;
    const wxd = sv39x4.PTEFlags.write |
        sv39x4.PTEFlags.execute |
        sv39x4.PTEFlags.dirty;
    try t.expectEqual(@as(u64, 0), pte & wxd);

    // Resource 2 maps slot 1; child teardown drops refcount back to 0.
    _ = vcmds.handleSetScanoutLocked(&c.gpu, &.{
        .hdr = .{},
        .r = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .scanout_id = 0,
        .resource_id = 2,
    });
    try p.space.writeGuestStruct(Args, 0x8000_0000, .{
        .target_cid = c.local_cid,
        .frame_seq = res1.frame_seq,
    });
    handleGpuMapScanout(&p_vc, &ctx, p, 0x8000_0000);
    const res2 = try p.space.readGuestStruct(Args, 0x8000_0000);
    const s1_off: u32 = @intCast(interface.SCANOUT_SLOT_BYTES);
    try t.expectEqual(s1_off, res2.slot_offset_bytes);
    try t.expectEqual(@as(u32, 3), physmem.getPageRef(c_pg));

    c.is_confidential = true;
    handleGpuMapScanout(&p_vc, &ctx, p, 0x8000_0000);
    try t.expectEqual(
        @as(usize, @bitCast(sbi_core.SBI_ERR_DENIED)),
        ctx[a0_reg],
    );
    c.is_confidential = false;

    c.deinit();
    try t.expectEqual(@as(u32, 0), physmem.getPageRef(c_pg));
}
