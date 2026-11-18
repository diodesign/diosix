// VirtIO-GPU 2D Control & Cursor Command Handlers
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const proto = @import("protocol.zig");
const vgpu_mod = @import("../vgpu.zig");

const VirtioGpu = vgpu_mod.VirtioGpu;
const VirtioGpuRespDisplayInfo = proto.VirtioGpuRespDisplayInfo;
const VirtioGpuResourceCreate2D = proto.VirtioGpuResourceCreate2D;
const VirtioGpuResourceUnref = proto.VirtioGpuResourceUnref;
const VirtioGpuSetScanout = proto.VirtioGpuSetScanout;
const VirtioGpuResourceFlush = proto.VirtioGpuResourceFlush;
const VirtioGpuTransferToHost2D = proto.VirtioGpuTransferToHost2D;
const VirtioGpuResourceAttachBacking = proto.VirtioGpuResourceAttachBacking;
const VirtioGpuResourceDetachBacking = proto.VirtioGpuResourceDetachBacking;
const VirtioGpuMemEntry = proto.VirtioGpuMemEntry;
const VirtioGpuUpdateCursor = proto.VirtioGpuUpdateCursor;

const MAX_SCANOUTS = proto.MAX_SCANOUTS;
const MAX_SYSTEM_RESOURCES = proto.MAX_SYSTEM_RESOURCES;
const MAX_RESOURCE_DIMENSION = proto.MAX_RESOURCE_DIMENSION;
const BYTES_PER_PIXEL_RGBA = proto.BYTES_PER_PIXEL_RGBA;
const MAX_BACKING_ENTRIES = proto.MAX_BACKING_ENTRIES;

fn isValidFormat(format: u32) bool {
    return switch (format) {
        proto.VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM,
        proto.VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM,
        proto.VIRTIO_GPU_FORMAT_A8R8G8B8_UNORM,
        proto.VIRTIO_GPU_FORMAT_X8R8G8B8_UNORM,
        proto.VIRTIO_GPU_FORMAT_R8G8B8A8_UNORM,
        proto.VIRTIO_GPU_FORMAT_X8B8G8R8_UNORM,
        proto.VIRTIO_GPU_FORMAT_A8B8G8R8_UNORM,
        proto.VIRTIO_GPU_FORMAT_R8G8B8X8_UNORM,
        => true,
        else => false,
    };
}

fn rectFitsResource(
    r: proto.VirtioGpuRect,
    res: *const proto.VirtioGpuResource,
) bool {
    const end_x = std.math.add(u32, r.x, r.width) catch return false;
    const end_y = std.math.add(u32, r.y, r.height) catch return false;
    return end_x <= res.width and end_y <= res.height;
}

pub fn handleGetDisplayInfoLocked(
    self: *const VirtioGpu,
    resp: *VirtioGpuRespDisplayInfo,
) void {
    @memset(std.mem.asBytes(resp), 0);
    resp.hdr.type = proto.VIRTIO_GPU_RESP_OK_DISPLAY_INFO;
    resp.pmodes[0].enabled = 1;
    resp.pmodes[0].r.x = 0;
    resp.pmodes[0].r.y = 0;
    resp.pmodes[0].r.width = self.display_width;
    resp.pmodes[0].r.height = self.display_height;
}

pub fn handleResourceCreate2DLocked(
    self: *VirtioGpu,
    req: *const VirtioGpuResourceCreate2D,
) u32 {
    if (req.resource_id == 0 or req.resource_id >= MAX_SYSTEM_RESOURCES) {
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
    }
    if (self.getResourceUnlocked(req.resource_id) != null) {
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
    }
    if (!isValidFormat(req.format)) {
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
    }
    if (req.width == 0 or req.height == 0 or
        req.width > MAX_RESOURCE_DIMENSION or
        req.height > MAX_RESOURCE_DIMENSION)
    {
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
    }
    const pixels = std.math.mul(u32, req.width, req.height) catch
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
    _ = std.math.mul(u32, pixels, BYTES_PER_PIXEL_RGBA) catch
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
    const res = self.allocateResourceUnlocked(req.resource_id) orelse
        return proto.VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY;
    res.clearBacking(self.allocator);
    const next_gen = res.backing_gen;
    res.* = .{
        .id = req.resource_id,
        .format = req.format,
        .width = req.width,
        .height = req.height,
        .backing_gen = next_gen,
        .is_active = true,
        .next = res.next,
    };
    return proto.VIRTIO_GPU_RESP_OK_NODATA;
}

pub fn handleResourceUnrefLocked(
    self: *VirtioGpu,
    req: *const VirtioGpuResourceUnref,
) u32 {
    const res = self.getResourceUnlocked(req.resource_id) orelse
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
    res.clearBacking(self.allocator);
    res.is_active = false;
    res.scanout_id = null;
    if (self.active_scanout_res_id == req.resource_id) {
        self.active_scanout_res_id = 0;
        self.scanout_rect = .{};
        const seq = self.frame_seq.fetchAdd(1, .acq_rel) + 1;
        self.damage_ring.pushRect(seq, .{
            .x = 0,
            .y = 0,
            .width = self.display_width,
            .height = self.display_height,
        });
    }
    if (self.cursor_resource_id == req.resource_id) {
        const old_l = @as(i64, self.cursor_x) - @as(i64, self.cursor_hot_x);
        const old_t = @as(i64, self.cursor_y) - @as(i64, self.cursor_hot_y);
        self.cursor_resource_id = 0;
        _ = self.cursor_seq.fetchAdd(1, .acq_rel);
        const seq = self.frame_seq.fetchAdd(1, .acq_rel) + 1;
        self.damage_ring.pushCursorMotion(seq, old_l, old_t, old_l, old_t);
    }
    return proto.VIRTIO_GPU_RESP_OK_NODATA;
}

pub fn handleSetScanoutLocked(
    self: *VirtioGpu,
    req: *const VirtioGpuSetScanout,
) u32 {
    if (req.scanout_id >= MAX_SCANOUTS) {
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_SCANOUT_ID;
    }
    if (req.resource_id == 0) {
        if (req.scanout_id == 0) {
            self.active_scanout_res_id = 0;
            self.scanout_rect = .{};
            const seq = self.frame_seq.fetchAdd(1, .acq_rel) + 1;
            self.damage_ring.pushRect(seq, .{
                .x = 0,
                .y = 0,
                .width = self.display_width,
                .height = self.display_height,
            });
        }
        return proto.VIRTIO_GPU_RESP_OK_NODATA;
    }
    const res = self.getResourceUnlocked(req.resource_id) orelse
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
    if (!rectFitsResource(req.r, res)) {
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
    }
    res.scanout_id = req.scanout_id;
    if (req.scanout_id == 0) {
        self.active_scanout_res_id = req.resource_id;
        self.scanout_rect = if (req.r.width > 0 and req.r.height > 0)
            req.r
        else
            .{ .x = 0, .y = 0, .width = res.width, .height = res.height };
        const seq = self.frame_seq.fetchAdd(1, .acq_rel) + 1;
        self.damage_ring.pushRect(seq, .{
            .x = 0,
            .y = 0,
            .width = self.display_width,
            .height = self.display_height,
        });
    }
    return proto.VIRTIO_GPU_RESP_OK_NODATA;
}

pub fn handleResourceFlushLocked(
    self: *VirtioGpu,
    req: *const VirtioGpuResourceFlush,
) u32 {
    const res = self.getResourceUnlocked(req.resource_id) orelse
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
    if (!rectFitsResource(req.r, res)) {
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
    }
    self.flushes_count += 1;
    self.last_flushed_resource = req.resource_id;
    const seq = self.frame_seq.fetchAdd(1, .acq_rel) + 1;
    if (req.resource_id == self.active_scanout_res_id) {
        const dmg = if (req.r.width > 0 and req.r.height > 0)
            req.r
        else if (res.last_transfer_rect.width > 0 and
            res.last_transfer_rect.height > 0)
            res.last_transfer_rect
        else
            proto.VirtioGpuRect{
                .x = 0,
                .y = 0,
                .width = res.width,
                .height = res.height,
            };
        self.damage_ring.pushRect(seq, dmg);
    }
    return proto.VIRTIO_GPU_RESP_OK_NODATA;
}

pub fn handleTransferToHost2DLocked(
    self: *VirtioGpu,
    req: *const VirtioGpuTransferToHost2D,
) u32 {
    const res = self.getResourceUnlocked(req.resource_id) orelse
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
    if (!rectFitsResource(req.r, res)) {
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
    }
    res.last_transfer_rect = req.r;
    return proto.VIRTIO_GPU_RESP_OK_NODATA;
}

pub fn handleAttachBackingSliceLocked(
    self: *VirtioGpu,
    req: *const VirtioGpuResourceAttachBacking,
    entries: []const VirtioGpuMemEntry,
) u32 {
    if (req.nr_entries > MAX_BACKING_ENTRIES or
        entries.len != req.nr_entries)
    {
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
    }
    const res = self.getResourceUnlocked(req.resource_id) orelse
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
    res.clearBacking(self.allocator);
    if (entries.len == 0) return proto.VIRTIO_GPU_RESP_OK_NODATA;

    var total_len: usize = 0;
    for (entries) |ent| {
        _ = std.math.add(u64, ent.addr, ent.length) catch
            return proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
        total_len = std.math.add(usize, total_len, ent.length) catch
            return proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
    }

    if (entries.len == 1) {
        res.inline_entry = entries[0];
        res.has_inline_entry = true;
    } else {
        const alloc = self.allocator orelse
            return proto.VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY;
        const owned = alloc.alloc(VirtioGpuMemEntry, entries.len) catch
            return proto.VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY;
        @memcpy(owned, entries);
        res.backing_entries = owned;
    }
    res.backing_gpa = entries[0].addr;
    res.backing_len = total_len;
    res.backing_gen +%= 1;
    return proto.VIRTIO_GPU_RESP_OK_NODATA;
}

pub fn handleDetachBackingLocked(
    self: *VirtioGpu,
    req: *const VirtioGpuResourceDetachBacking,
) u32 {
    const res = self.getResourceUnlocked(req.resource_id) orelse
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
    res.clearBacking(self.allocator);
    return proto.VIRTIO_GPU_RESP_OK_NODATA;
}

pub fn handleCursorLocked(
    self: *VirtioGpu,
    req: *const VirtioGpuUpdateCursor,
    is_move: bool,
) void {
    if (req.pos.scanout_id != 0) return;
    const old_left = @as(i64, self.cursor_x) - @as(i64, self.cursor_hot_x);
    const old_top = @as(i64, self.cursor_y) - @as(i64, self.cursor_hot_y);
    self.cursor_x = req.pos.x;
    self.cursor_y = req.pos.y;
    if (!is_move) {
        self.cursor_resource_id = req.resource_id;
        self.cursor_hot_x = req.hot_x;
        self.cursor_hot_y = req.hot_y;
        _ = self.cursor_seq.fetchAdd(1, .acq_rel);
    }
    const new_left = @as(i64, self.cursor_x) - @as(i64, self.cursor_hot_x);
    const new_top = @as(i64, self.cursor_y) - @as(i64, self.cursor_hot_y);
    const seq = self.frame_seq.fetchAdd(1, .acq_rel) + 1;
    self.damage_ring.pushCursorMotion(
        seq,
        old_left,
        old_top,
        new_left,
        new_top,
    );
}

test "VirtIO GPU command dimension and scatter-gather backing validation" {
    const testing = std.testing;
    testing.refAllDecls(@This());

    var gpu = VirtioGpu.initWithMem(1, null, testing.allocator);
    defer gpu.deinit();

    const hdr = proto.VirtioGpuCtrlHdr{
        .type = proto.VIRTIO_GPU_CMD_RESOURCE_CREATE_2D,
    };
    const bad_req = VirtioGpuResourceCreate2D{
        .hdr = hdr,
        .resource_id = 1,
        .format = proto.VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM,
        .width = MAX_RESOURCE_DIMENSION + 1,
        .height = proto.DEFAULT_DISPLAY_HEIGHT,
    };
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER,
        handleResourceCreate2DLocked(&gpu, &bad_req),
    );

    const ok_req = VirtioGpuResourceCreate2D{
        .hdr = hdr,
        .resource_id = 1,
        .format = proto.VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM,
        .width = 64,
        .height = 64,
    };
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_OK_NODATA,
        handleResourceCreate2DLocked(&gpu, &ok_req),
    );
    const sg = [_]VirtioGpuMemEntry{
        .{ .addr = 0x8000_0000, .length = 4096 },
        .{ .addr = 0x8000_2000, .length = 12_288 },
    };
    const attach = VirtioGpuResourceAttachBacking{
        .hdr = hdr,
        .resource_id = 1,
        .nr_entries = 2,
    };
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_OK_NODATA,
        handleAttachBackingSliceLocked(&gpu, &attach, &sg),
    );
    try testing.expectEqual(
        @as(usize, 16_384),
        gpu.getResourceUnlocked(1).?.backing_len,
    );
}
