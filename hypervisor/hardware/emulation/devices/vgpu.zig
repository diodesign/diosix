// VirtIO-GPU (2D Graphics & Display Device) Emulation
// Implements VirtIO 1.1 / 1.2 Device ID 16 (VIRTIO_ID_GPU) for standard
// DRM/KMS desktop display.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const bus = @import("bus.zig");
pub const proto = @import("vgpu/protocol.zig");
pub const commands = @import("vgpu/commands.zig");

pub const VIRTIO_ID_GPU = proto.VIRTIO_ID_GPU;
pub const VIRTIO_VENDOR_ID = proto.VIRTIO_VENDOR_ID;
pub const VIRTIO_MAGIC = proto.VIRTIO_MAGIC;
pub const VIRTIO_VERSION = proto.VIRTIO_VERSION;
pub const QUEUE_SIZE_MAX = proto.QUEUE_SIZE_MAX;
pub const NUM_QUEUES = proto.NUM_QUEUES;

pub const DEFAULT_DISPLAY_WIDTH = proto.DEFAULT_DISPLAY_WIDTH;
pub const DEFAULT_DISPLAY_HEIGHT = proto.DEFAULT_DISPLAY_HEIGHT;
pub const MAX_RESOURCE_DIMENSION = proto.MAX_RESOURCE_DIMENSION;
pub const BYTES_PER_PIXEL_RGBA = proto.BYTES_PER_PIXEL_RGBA;

pub const MAX_SCANOUTS = proto.MAX_SCANOUTS;
pub const STATIC_RESOURCES = proto.STATIC_RESOURCES;
pub const DYNAMIC_HASH_BUCKETS = proto.DYNAMIC_HASH_BUCKETS;
pub const DYNAMIC_POOL_CAPACITY: usize = 128;
pub const MAX_SYSTEM_RESOURCES = proto.MAX_SYSTEM_RESOURCES;
pub const MAX_RESOURCES = proto.MAX_RESOURCES;

pub const VirtioGpuCtrlHdr = proto.VirtioGpuCtrlHdr;
pub const VirtioGpuRect = proto.VirtioGpuRect;
pub const VirtioGpuDisplayOne = proto.VirtioGpuDisplayOne;
pub const VirtioGpuRespDisplayInfo = proto.VirtioGpuRespDisplayInfo;
pub const VirtioGpuResourceCreate2D = proto.VirtioGpuResourceCreate2D;
pub const VirtioGpuResourceUnref = proto.VirtioGpuResourceUnref;
pub const VirtioGpuSetScanout = proto.VirtioGpuSetScanout;
pub const VirtioGpuResourceFlush = proto.VirtioGpuResourceFlush;
pub const VirtioGpuTransferToHost2D = proto.VirtioGpuTransferToHost2D;
pub const VirtioGpuMemEntry = proto.VirtioGpuMemEntry;
pub const VirtioGpuResourceAttachBacking = proto.VirtioGpuResourceAttachBacking;
pub const VirtioGpuResource = proto.VirtioGpuResource;

pub const VirtqDesc = bus.VirtqDesc;
pub const VIRTQ_DESC_F_NEXT = bus.VIRTQ_DESC_F_NEXT;
pub const VIRTQ_DESC_F_WRITE = bus.VIRTQ_DESC_F_WRITE;
pub const VirtqUsedElem = bus.VirtqUsedElem;
pub const VirtQueue = bus.VirtQueueConfig(QUEUE_SIZE_MAX);

pub const VirtioGpu = struct {
    guest_cid: usize = 0,
    status: u32 = 0,
    device_features_sel: u32 = 0,
    driver_features_sel: u32 = 0,
    driver_features: u64 = 0,
    queue_sel: u32 = 0,
    interrupt_status: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    queues: [NUM_QUEUES]VirtQueue = @splat(.{}),
    /// Column 1: Static fast-path resources 0..31 (wait-free, O(1)).
    static_resources: [STATIC_RESOURCES]VirtioGpuResource = @splat(.{}),
    /// Column 2: Dynamic hash buckets for resource IDs >= 32 (id % 32).
    dynamic_buckets: [DYNAMIC_HASH_BUCKETS]?*VirtioGpuResource = @splat(null),
    /// Embedded pool for standalone execution (up to 128 dynamic resources).
    dynamic_pool: [DYNAMIC_POOL_CAPACITY]VirtioGpuResource = @splat(.{}),
    pool_count: usize = 0,
    lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    display_width: u32 = DEFAULT_DISPLAY_WIDTH,
    display_height: u32 = DEFAULT_DISPLAY_HEIGHT,
    flushes_count: usize = 0,
    last_flushed_resource: u32 = 0,

    pub fn getDynamicResourceLocked(
        self: *VirtioGpu,
        id: u32,
    ) ?*VirtioGpuResource {
        const bucket = id % DYNAMIC_HASH_BUCKETS;
        var curr = self.dynamic_buckets[bucket];
        while (curr) |res| {
            if (res.id == id and res.is_active) return res;
            curr = res.next;
        }
        return null;
    }

    pub fn getResource(self: *VirtioGpu, id: u32) ?*VirtioGpuResource {
        if (id == 0 or id >= MAX_SYSTEM_RESOURCES) return null;
        if (id < STATIC_RESOURCES) {
            const res = &self.static_resources[id];
            return if (res.is_active) res else null;
        }
        while (self.lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer self.lock.store(false, .release);

        return self.getDynamicResourceLocked(id);
    }

    pub fn allocateResource(self: *VirtioGpu, id: u32) ?*VirtioGpuResource {
        if (id == 0 or id >= MAX_SYSTEM_RESOURCES) return null;
        if (id < STATIC_RESOURCES) {
            const res = &self.static_resources[id];
            if (res.is_active) return null;
            res.is_active = true;
            return res;
        }
        while (self.lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer self.lock.store(false, .release);

        if (self.getDynamicResourceLocked(id) != null) return null;

        const bucket = id % DYNAMIC_HASH_BUCKETS;
        var curr = self.dynamic_buckets[bucket];
        while (curr) |res| {
            if (!res.is_active) {
                res.id = id;
                res.is_active = true;
                return res;
            }
            curr = res.next;
        }
        if (self.pool_count < self.dynamic_pool.len) {
            const res = &self.dynamic_pool[self.pool_count];
            self.pool_count += 1;
            res.id = id;
            res.is_active = true;
            res.next = self.dynamic_buckets[bucket];
            self.dynamic_buckets[bucket] = res;
            return res;
        }
        return null;
    }

    pub fn init(guest_cid: usize) VirtioGpu {
        return .{ .guest_cid = guest_cid };
    }

    pub fn readReg(self: *VirtioGpu, offset: u32) u32 {
        const irq = self.interrupt_status.load(.acquire);
        return bus.readVirtioCommon(
            self,
            VIRTIO_ID_GPU,
            NUM_QUEUES,
            QUEUE_SIZE_MAX,
            irq,
            offset,
        ) orelse 0;
    }

    pub fn writeReg(self: *VirtioGpu, offset: u32, val: u32) void {
        if (bus.writeVirtioQueueAndFeatureReg(
            self,
            NUM_QUEUES,
            QUEUE_SIZE_MAX,
            offset,
            val,
        )) return;

        switch (offset) {
            bus.VIRTIO_MMIO_REG_QUEUE_NOTIFY => {
                if (val == 0) self.processControlQueue();
            },
            bus.VIRTIO_MMIO_REG_INTERRUPT_ACK => {
                _ = self.interrupt_status.fetchAnd(~val, .acq_rel);
            },
            bus.VIRTIO_MMIO_REG_STATUS => {
                self.status = val;
                if (val == 0) self.reset();
            },
            else => {},
        }
    }

    pub fn reset(self: *VirtioGpu) void {
        while (self.lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer self.lock.store(false, .release);

        self.status = 0;
        self.interrupt_status.store(0, .release);
        for (&self.queues) |*q| q.* = .{};
        for (&self.static_resources) |*r| r.* = .{};
        self.dynamic_buckets = @splat(null);
        self.dynamic_pool = @splat(.{});
        self.pool_count = 0;
    }

    pub fn processControlQueue(self: *VirtioGpu) void {
        _ = self.interrupt_status.fetchOr(1, .acq_rel);
    }

    pub const handleGetDisplayInfo = commands.handleGetDisplayInfo;
    pub const handleResourceCreate2D = commands.handleResourceCreate2D;
    pub const handleResourceUnref = commands.handleResourceUnref;
    pub const handleSetScanout = commands.handleSetScanout;
    pub const handleResourceFlush = commands.handleResourceFlush;
};

test "VirtIO GPU register probe, display info, and 2D resource management" {
    const testing = std.testing;
    testing.refAllDecls(@This());
    _ = proto;
    _ = commands;

    var gpu = VirtioGpu.init(2);

    try testing.expectEqual(VIRTIO_MAGIC, gpu.readReg(0x000));
    try testing.expectEqual(VIRTIO_VERSION, gpu.readReg(0x004));
    try testing.expectEqual(VIRTIO_ID_GPU, gpu.readReg(0x008));
    try testing.expectEqual(VIRTIO_VENDOR_ID, gpu.readReg(0x00c));

    var disp_resp: VirtioGpuRespDisplayInfo = undefined;
    gpu.handleGetDisplayInfo(&disp_resp);
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_OK_DISPLAY_INFO,
        disp_resp.hdr.type,
    );
    try testing.expectEqual(@as(u32, 1), disp_resp.pmodes[0].enabled);
    try testing.expectEqual(
        DEFAULT_DISPLAY_WIDTH,
        disp_resp.pmodes[0].r.width,
    );
    try testing.expectEqual(
        DEFAULT_DISPLAY_HEIGHT,
        disp_resp.pmodes[0].r.height,
    );

    const zero_hdr = VirtioGpuCtrlHdr{
        .type = proto.VIRTIO_GPU_CMD_RESOURCE_CREATE_2D,
        .flags = 0,
        .fence_id = 0,
        .ctx_id = 0,
        .padding = 0,
    };
    const create_req = VirtioGpuResourceCreate2D{
        .hdr = zero_hdr,
        .resource_id = 1,
        .format = proto.VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM,
        .width = DEFAULT_DISPLAY_WIDTH,
        .height = DEFAULT_DISPLAY_HEIGHT,
    };
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_OK_NODATA,
        gpu.handleResourceCreate2D(&create_req),
    );
    try testing.expect(gpu.getResource(1) != null);
    try testing.expect(gpu.getResource(1).?.is_active);

    const full_rect = VirtioGpuRect{
        .x = 0,
        .y = 0,
        .width = DEFAULT_DISPLAY_WIDTH,
        .height = DEFAULT_DISPLAY_HEIGHT,
    };
    const scanout_req = VirtioGpuSetScanout{
        .hdr = zero_hdr,
        .r = full_rect,
        .scanout_id = 0,
        .resource_id = 1,
    };
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_OK_NODATA,
        gpu.handleSetScanout(&scanout_req),
    );

    const flush_req = VirtioGpuResourceFlush{
        .hdr = zero_hdr,
        .r = full_rect,
        .resource_id = 1,
        .padding = 0,
    };
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_OK_NODATA,
        gpu.handleResourceFlush(&flush_req),
    );
    try testing.expectEqual(@as(usize, 1), gpu.flushes_count);
    try testing.expectEqual(@as(u32, 1), gpu.last_flushed_resource);

    // Dynamic resource allocation (>= 32) and bucket collision resolution.
    var dyn_req_32 = create_req;
    dyn_req_32.resource_id = 32;
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_OK_NODATA,
        gpu.handleResourceCreate2D(&dyn_req_32),
    );
    try testing.expect(gpu.getResource(32) != null);

    var dyn_req_64 = create_req;
    dyn_req_64.resource_id = 64;
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_OK_NODATA,
        gpu.handleResourceCreate2D(&dyn_req_64),
    );
    try testing.expect(gpu.getResource(64) != null);
    try testing.expect(gpu.getResource(32) != null);

    var dyn_flush_64 = flush_req;
    dyn_flush_64.resource_id = 64;
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_OK_NODATA,
        gpu.handleResourceFlush(&dyn_flush_64),
    );
    try testing.expectEqual(@as(u32, 64), gpu.last_flushed_resource);

    // Duplicate dynamic resource rejection.
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID,
        gpu.handleResourceCreate2D(&dyn_req_32),
    );

    // Dynamic unref and slot reuse.
    const unref_32 = VirtioGpuResourceUnref{
        .hdr = zero_hdr,
        .resource_id = 32,
        .padding = 0,
    };
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_OK_NODATA,
        gpu.handleResourceUnref(&unref_32),
    );
    try testing.expect(gpu.getResource(32) == null);

    // Re-create resource 32 (reuses inactive bucket node).
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_OK_NODATA,
        gpu.handleResourceCreate2D(&dyn_req_32),
    );
    try testing.expect(gpu.getResource(32) != null);

    // Test zero queue size rejection.
    gpu.writeReg(0x030, 0);
    gpu.writeReg(0x038, 0);
    try testing.expect(gpu.queues[0].num > 0);

    // Test out-of-bounds flush rectangle rejection.
    const bad_flush = VirtioGpuResourceFlush{
        .hdr = zero_hdr,
        .r = .{
            .x = 1000,
            .y = 500,
            .width = DEFAULT_DISPLAY_WIDTH,
            .height = DEFAULT_DISPLAY_HEIGHT,
        },
        .resource_id = 1,
        .padding = 0,
    };
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER,
        gpu.handleResourceFlush(&bad_flush),
    );

    // Test duplicate resource creation and invalid format/ID rejection.
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID,
        gpu.handleResourceCreate2D(&create_req),
    );

    var bad_fmt_req = create_req;
    bad_fmt_req.resource_id = 2;
    bad_fmt_req.format = 999;
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER,
        gpu.handleResourceCreate2D(&bad_fmt_req),
    );

    var zero_res_req = create_req;
    zero_res_req.resource_id = 0;
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID,
        gpu.handleResourceCreate2D(&zero_res_req),
    );

    var oob_res_req = create_req;
    oob_res_req.resource_id = MAX_SYSTEM_RESOURCES;
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID,
        gpu.handleResourceCreate2D(&oob_res_req),
    );

    gpu.writeReg(bus.VIRTIO_MMIO_REG_QUEUE_SEL, 0);
    try testing.expectEqual(
        QUEUE_SIZE_MAX,
        gpu.readReg(bus.VIRTIO_MMIO_REG_QUEUE_NUM_MAX),
    );
    gpu.writeReg(bus.VIRTIO_MMIO_REG_QUEUE_SEL, 99);
    try testing.expectEqual(
        @as(u32, 0),
        gpu.readReg(bus.VIRTIO_MMIO_REG_QUEUE_NUM_MAX),
    );
}
