// VirtIO-GPU 2D Control Command Handlers
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

const MAX_SCANOUTS = proto.MAX_SCANOUTS;
const STATIC_RESOURCES = proto.STATIC_RESOURCES;
const MAX_SYSTEM_RESOURCES = proto.MAX_SYSTEM_RESOURCES;
const MAX_RESOURCE_DIMENSION = proto.MAX_RESOURCE_DIMENSION;
const BYTES_PER_PIXEL_RGBA = proto.BYTES_PER_PIXEL_RGBA;

pub fn handleGetDisplayInfo(
    self: *VirtioGpu,
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

pub fn handleResourceCreate2D(
    self: *VirtioGpu,
    req: *const VirtioGpuResourceCreate2D,
) u32 {
    if (req.resource_id == 0 or req.resource_id >= MAX_SYSTEM_RESOURCES) {
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
    }
    if (self.getResource(req.resource_id) != null) {
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
    }
    switch (req.format) {
        proto.VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM,
        proto.VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM,
        proto.VIRTIO_GPU_FORMAT_A8R8G8B8_UNORM,
        proto.VIRTIO_GPU_FORMAT_X8R8G8B8_UNORM,
        proto.VIRTIO_GPU_FORMAT_R8G8B8A8_UNORM,
        proto.VIRTIO_GPU_FORMAT_X8B8G8R8_UNORM,
        => {},
        else => return proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER,
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
    const res = self.allocateResource(req.resource_id) orelse
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
    res.* = .{
        .id = req.resource_id,
        .format = req.format,
        .width = req.width,
        .height = req.height,
        .is_active = true,
        .next = res.next,
    };
    return proto.VIRTIO_GPU_RESP_OK_NODATA;
}

pub fn handleResourceUnref(
    self: *VirtioGpu,
    req: *const VirtioGpuResourceUnref,
) u32 {
    if (req.resource_id == 0 or req.resource_id >= MAX_SYSTEM_RESOURCES) {
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
    }
    if (req.resource_id >= STATIC_RESOURCES) {
        while (self.lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer self.lock.store(false, .release);
        const res = self.getDynamicResourceLocked(req.resource_id) orelse
            return proto.VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
        res.is_active = false;
        res.scanout_id = null;
        res.backing_gpa = 0;
        res.backing_len = 0;
        return proto.VIRTIO_GPU_RESP_OK_NODATA;
    }
    const res = self.getResource(req.resource_id) orelse
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
    res.is_active = false;
    res.scanout_id = null;
    res.backing_gpa = 0;
    res.backing_len = 0;
    return proto.VIRTIO_GPU_RESP_OK_NODATA;
}

pub fn handleSetScanout(
    self: *VirtioGpu,
    req: *const VirtioGpuSetScanout,
) u32 {
    if (req.scanout_id >= MAX_SCANOUTS) {
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_SCANOUT_ID;
    }
    if (req.resource_id != 0) {
        const res = self.getResource(req.resource_id) orelse
            return proto.VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
        const end_x = std.math.add(u32, req.r.x, req.r.width) catch
            return proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
        const end_y = std.math.add(u32, req.r.y, req.r.height) catch
            return proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
        if (end_x > res.width or end_y > res.height) {
            return proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
        }
        res.scanout_id = req.scanout_id;
    }
    return proto.VIRTIO_GPU_RESP_OK_NODATA;
}

pub fn handleResourceFlush(
    self: *VirtioGpu,
    req: *const VirtioGpuResourceFlush,
) u32 {
    const res = self.getResource(req.resource_id) orelse
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
    const end_x = std.math.add(u32, req.r.x, req.r.width) catch
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
    const end_y = std.math.add(u32, req.r.y, req.r.height) catch
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
    if (end_x > res.width or end_y > res.height) {
        return proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
    }
    self.flushes_count += 1;
    self.last_flushed_resource = req.resource_id;
    return proto.VIRTIO_GPU_RESP_OK_NODATA;
}

test "VirtIO GPU command dimension bounds validation" {
    const testing = std.testing;
    testing.refAllDecls(@This());

    var gpu = VirtioGpu.init(1);
    const req = VirtioGpuResourceCreate2D{
        .hdr = .{
            .type = proto.VIRTIO_GPU_CMD_RESOURCE_CREATE_2D,
            .flags = 0,
            .fence_id = 0,
            .ctx_id = 0,
            .padding = 0,
        },
        .resource_id = 1,
        .format = proto.VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM,
        .width = MAX_RESOURCE_DIMENSION + 1,
        .height = proto.DEFAULT_DISPLAY_HEIGHT,
    };
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER,
        handleResourceCreate2D(&gpu, &req),
    );
}
