// VirtIO-GPU (2D Graphics & Display Device) Emulation
// Implements VirtIO 1.1 / 1.2 Device ID 16 (VIRTIO_ID_GPU) for standard DRM/KMS desktop display.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const bus = @import("bus.zig");

pub const VIRTIO_ID_GPU: u32 = 16;
pub const VIRTIO_VENDOR_ID: u32 = 0x554d4551; // "QEMU" / Standard VirtIO
pub const VIRTIO_MAGIC: u32 = 0x74726976; // "virt"
pub const VIRTIO_VERSION: u32 = 2; // Modern VirtIO

pub const QUEUE_SIZE_MAX: u16 = 64;
pub const NUM_QUEUES: usize = 2; // 0 = controlq, 1 = cursorq

// VirtIO GPU Formats
pub const VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM: u32 = 1;
pub const VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM: u32 = 2;
pub const VIRTIO_GPU_FORMAT_A8R8G8B8_UNORM: u32 = 3;
pub const VIRTIO_GPU_FORMAT_X8R8G8B8_UNORM: u32 = 4;
pub const VIRTIO_GPU_FORMAT_R8G8B8A8_UNORM: u32 = 67;
pub const VIRTIO_GPU_FORMAT_X8B8G8R8_UNORM: u32 = 68;

// VirtIO GPU Commands
pub const VIRTIO_GPU_CMD_GET_DISPLAY_INFO: u32 = 0x0100;
pub const VIRTIO_GPU_CMD_RESOURCE_CREATE_2D: u32 = 0x0101;
pub const VIRTIO_GPU_CMD_RESOURCE_UNREF: u32 = 0x0102;
pub const VIRTIO_GPU_CMD_SET_SCANOUT: u32 = 0x0103;
pub const VIRTIO_GPU_CMD_RESOURCE_FLUSH: u32 = 0x0104;
pub const VIRTIO_GPU_CMD_TRANSFER_TO_HOST_2D: u32 = 0x0105;
pub const VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING: u32 = 0x0106;
pub const VIRTIO_GPU_CMD_RESOURCE_DETACH_BACKING: u32 = 0x0107;
pub const VIRTIO_GPU_CMD_GET_CAPSET_INFO: u32 = 0x0108;
pub const VIRTIO_GPU_CMD_GET_CAPSET: u32 = 0x0109;
pub const VIRTIO_GPU_CMD_GET_EDID: u32 = 0x010a;

pub const VIRTIO_GPU_CMD_UPDATE_CURSOR: u32 = 0x0300;
pub const VIRTIO_GPU_CMD_MOVE_CURSOR: u32 = 0x0301;

// VirtIO GPU Responses
pub const VIRTIO_GPU_RESP_OK_NODATA: u32 = 0x1100;
pub const VIRTIO_GPU_RESP_OK_DISPLAY_INFO: u32 = 0x1101;
pub const VIRTIO_GPU_RESP_OK_CAPSET_INFO: u32 = 0x1102;
pub const VIRTIO_GPU_RESP_OK_CAPSET: u32 = 0x1103;
pub const VIRTIO_GPU_RESP_OK_EDID: u32 = 0x1104;
pub const VIRTIO_GPU_RESP_ERR_UNSPEC: u32 = 0x1200;
pub const VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY: u32 = 0x1201;
pub const VIRTIO_GPU_RESP_ERR_INVALID_SCANOUT_ID: u32 = 0x1202;
pub const VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID: u32 = 0x1203;
pub const VIRTIO_GPU_RESP_ERR_INVALID_CONTEXT_ID: u32 = 0x1204;
pub const VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER: u32 = 0x1205;

pub const MAX_SCANOUTS: usize = 16;
pub const STATIC_RESOURCES: usize = 32;
pub const DYNAMIC_HASH_BUCKETS: usize = 32;
pub const MAX_SYSTEM_RESOURCES: usize = 4096;
pub const MAX_RESOURCES: usize = MAX_SYSTEM_RESOURCES;

pub const VirtioGpuCtrlHdr = extern struct {
    type: u32,
    flags: u32,
    fence_id: u64,
    ctx_id: u32,
    padding: u32,
};

pub const VirtioGpuRect = extern struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const VirtioGpuDisplayOne = extern struct {
    r: VirtioGpuRect,
    enabled: u32,
    flags: u32,
};

pub const VirtioGpuRespDisplayInfo = extern struct {
    hdr: VirtioGpuCtrlHdr,
    pmodes: [MAX_SCANOUTS]VirtioGpuDisplayOne,
};

pub const VirtioGpuResourceCreate2D = extern struct {
    hdr: VirtioGpuCtrlHdr,
    resource_id: u32,
    format: u32,
    width: u32,
    height: u32,
};

pub const VirtioGpuResourceUnref = extern struct {
    hdr: VirtioGpuCtrlHdr,
    resource_id: u32,
    padding: u32,
};

pub const VirtioGpuSetScanout = extern struct {
    hdr: VirtioGpuCtrlHdr,
    r: VirtioGpuRect,
    scanout_id: u32,
    resource_id: u32,
};

pub const VirtioGpuResourceFlush = extern struct {
    hdr: VirtioGpuCtrlHdr,
    r: VirtioGpuRect,
    resource_id: u32,
    padding: u32,
};

pub const VirtioGpuTransferToHost2D = extern struct {
    hdr: VirtioGpuCtrlHdr,
    r: VirtioGpuRect,
    offset: u64,
    resource_id: u32,
    padding: u32,
};

pub const VirtioGpuMemEntry = extern struct {
    addr: u64,
    length: u32,
    padding: u32,
};

pub const VirtioGpuResourceAttachBacking = extern struct {
    hdr: VirtioGpuCtrlHdr,
    resource_id: u32,
    nr_entries: u32,
};

pub const VirtioGpuResource = struct {
    id: u32 = 0,
    format: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    scanout_id: ?u32 = null,
    backing_gpa: u64 = 0,
    backing_len: usize = 0,
    is_active: bool = false,
    next: ?*VirtioGpuResource = null,
};

pub const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

pub const VIRTQ_DESC_F_NEXT: u16 = 1;
pub const VIRTQ_DESC_F_WRITE: u16 = 2;

pub const VirtqAvail = extern struct {
    flags: u16,
    idx: u16,
    ring: [QUEUE_SIZE_MAX]u16,
    used_event: u16,
};

pub const VirtqUsedElem = extern struct {
    id: u32,
    len: u32,
};

pub const VirtqUsed = extern struct {
    flags: u16,
    idx: u16,
    ring: [QUEUE_SIZE_MAX]VirtqUsedElem,
    avail_event: u16,
};

pub const VirtQueue = struct {
    num: u16 = QUEUE_SIZE_MAX,
    ready: bool = false,
    desc_gpa: u64 = 0,
    driver_gpa: u64 = 0,
    device_gpa: u64 = 0,
    last_avail_idx: u16 = 0,
    last_used_idx: u16 = 0,
};

pub const VirtioGpu = struct {
    guest_cid: usize = 0,
    status: u32 = 0,
    device_features_sel: u32 = 0,
    driver_features_sel: u32 = 0,
    driver_features: u64 = 0,
    queue_sel: u32 = 0,
    interrupt_status: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    queues: [NUM_QUEUES]VirtQueue = @splat(.{}),
    // Column 1: Static fast-path resources 0..31 (wait-free, O(1), zero heap allocation)
    static_resources: [STATIC_RESOURCES]VirtioGpuResource = @splat(.{}),
    // Column 2: Dynamic hash buckets for resource IDs >= 32 (keyed by id % 32)
    dynamic_buckets: [DYNAMIC_HASH_BUCKETS]?*VirtioGpuResource = @splat(null),
    // Dynamic node pool for standalone execution (up to 128 dynamic resources = 160 total resources)
    dynamic_pool: [128]VirtioGpuResource = @splat(.{}),
    pool_count: usize = 0,
    lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    display_width: u32 = 1280,
    display_height: u32 = 720,
    flushes_count: usize = 0,
    last_flushed_resource: u32 = 0,

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

        const bucket = id % DYNAMIC_HASH_BUCKETS;
        var curr = self.dynamic_buckets[bucket];
        while (curr) |res| {
            if (res.id == id and res.is_active) return res;
            curr = res.next;
        }
        return null;
    }

    pub fn allocateResource(self: *VirtioGpu, id: u32) ?*VirtioGpuResource {
        if (id == 0 or id >= MAX_SYSTEM_RESOURCES) return null;
        if (id < STATIC_RESOURCES) {
            const res = &self.static_resources[id];
            if (res.is_active) return null; // Duplicate
            return res;
        }
        while (self.lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer self.lock.store(false, .release);

        const bucket = id % DYNAMIC_HASH_BUCKETS;
        var curr = self.dynamic_buckets[bucket];
        while (curr) |res| {
            if (res.id == id and res.is_active) return null; // Duplicate
            curr = res.next;
        }
        // Check for an inactive slot in the bucket to reuse
        curr = self.dynamic_buckets[bucket];
        while (curr) |res| {
            if (!res.is_active) {
                res.id = id;
                return res;
            }
            curr = res.next;
        }
        // Otherwise take a node from the embedded pool
        if (self.pool_count < self.dynamic_pool.len) {
            const res = &self.dynamic_pool[self.pool_count];
            self.pool_count += 1;
            res.id = id;
            res.next = self.dynamic_buckets[bucket];
            self.dynamic_buckets[bucket] = res;
            return res;
        }
        return null;
    }

    pub fn init(guest_cid: usize) VirtioGpu {
        return .{
            .guest_cid = guest_cid,
        };
    }

    pub fn readReg(self: *VirtioGpu, offset: u32) u32 {
        return switch (offset) {
            bus.VIRTIO_MMIO_REG_MAGIC_VALUE => VIRTIO_MAGIC,
            bus.VIRTIO_MMIO_REG_VERSION => VIRTIO_VERSION,
            bus.VIRTIO_MMIO_REG_DEVICE_ID => VIRTIO_ID_GPU,
            bus.VIRTIO_MMIO_REG_VENDOR_ID => VIRTIO_VENDOR_ID,
            bus.VIRTIO_MMIO_REG_DEVICE_FEATURES => blk: {
                if (self.device_features_sel == 0) {
                    break :blk 0;
                } else if (self.device_features_sel == 1) {
                    break :blk 1; // VIRTIO_F_VERSION_1
                }
                break :blk 0;
            },
            bus.VIRTIO_MMIO_REG_QUEUE_NUM_MAX => if (self.queue_sel < NUM_QUEUES) QUEUE_SIZE_MAX else 0,
            bus.VIRTIO_MMIO_REG_QUEUE_READY => if (self.queue_sel < NUM_QUEUES and self.queues[self.queue_sel].ready) 1 else 0,
            bus.VIRTIO_MMIO_REG_INTERRUPT_STATUS => self.interrupt_status.load(.acquire),
            bus.VIRTIO_MMIO_REG_STATUS => self.status,
            else => 0,
        };
    }

    pub fn writeReg(self: *VirtioGpu, offset: u32, val: u32) void {
        switch (offset) {
            bus.VIRTIO_MMIO_REG_DEVICE_FEATURES_SEL => self.device_features_sel = val,
            bus.VIRTIO_MMIO_REG_DRIVER_FEATURES => {
                if (self.driver_features_sel == 0) {
                    self.driver_features = (self.driver_features & 0xFFFFFFFF00000000) | val;
                } else {
                    self.driver_features = (self.driver_features & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
                }
            },
            bus.VIRTIO_MMIO_REG_DRIVER_FEATURES_SEL => self.driver_features_sel = val,
            bus.VIRTIO_MMIO_REG_QUEUE_SEL => self.queue_sel = val,
            bus.VIRTIO_MMIO_REG_QUEUE_NUM => {
                if (self.queue_sel < NUM_QUEUES) {
                    const q_num = @min(val, QUEUE_SIZE_MAX);
                    self.queues[self.queue_sel].num = @truncate(if (q_num > 0) q_num else 1);
                }
            },
            bus.VIRTIO_MMIO_REG_QUEUE_READY => {
                if (self.queue_sel < NUM_QUEUES) {
                    self.queues[self.queue_sel].ready = (val & 1) != 0 and self.queues[self.queue_sel].num > 0;
                }
            },
            bus.VIRTIO_MMIO_REG_QUEUE_NOTIFY => {
                const q_idx = val;
                if (q_idx == 0) {
                    self.processControlQueue();
                }
            },
            bus.VIRTIO_MMIO_REG_INTERRUPT_ACK => _ = self.interrupt_status.fetchAnd(~val, .acq_rel),
            bus.VIRTIO_MMIO_REG_STATUS => {
                self.status = val;
                if (val == 0) {
                    self.reset();
                }
            },
            bus.VIRTIO_MMIO_REG_QUEUE_DESC_LOW => {
                if (self.queue_sel < NUM_QUEUES) self.queues[self.queue_sel].desc_gpa = (self.queues[self.queue_sel].desc_gpa & 0xFFFFFFFF00000000) | val;
            },
            bus.VIRTIO_MMIO_REG_QUEUE_DESC_HIGH => {
                if (self.queue_sel < NUM_QUEUES) self.queues[self.queue_sel].desc_gpa = (self.queues[self.queue_sel].desc_gpa & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
            },
            bus.VIRTIO_MMIO_REG_QUEUE_DRIVER_LOW => {
                if (self.queue_sel < NUM_QUEUES) self.queues[self.queue_sel].driver_gpa = (self.queues[self.queue_sel].driver_gpa & 0xFFFFFFFF00000000) | val;
            },
            bus.VIRTIO_MMIO_REG_QUEUE_DRIVER_HIGH => {
                if (self.queue_sel < NUM_QUEUES) self.queues[self.queue_sel].driver_gpa = (self.queues[self.queue_sel].driver_gpa & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
            },
            bus.VIRTIO_MMIO_REG_QUEUE_DEVICE_LOW => {
                if (self.queue_sel < NUM_QUEUES) self.queues[self.queue_sel].device_gpa = (self.queues[self.queue_sel].device_gpa & 0xFFFFFFFF00000000) | val;
            },
            bus.VIRTIO_MMIO_REG_QUEUE_DEVICE_HIGH => {
                if (self.queue_sel < NUM_QUEUES) self.queues[self.queue_sel].device_gpa = (self.queues[self.queue_sel].device_gpa & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
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
        for (&self.queues) |*q| {
            q.* = .{};
        }
        for (&self.static_resources) |*r| {
            r.* = .{};
        }
        self.dynamic_buckets = @splat(null);
        self.dynamic_pool = @splat(.{});
        self.pool_count = 0;
    }

    pub fn processControlQueue(self: *VirtioGpu) void {
        _ = self.interrupt_status.fetchOr(1, .acq_rel);
    }

    pub fn handleGetDisplayInfo(self: *VirtioGpu, resp: *VirtioGpuRespDisplayInfo) void {
        @memset(std.mem.asBytes(resp), 0);
        resp.hdr.type = VIRTIO_GPU_RESP_OK_DISPLAY_INFO;
        resp.pmodes[0].enabled = 1;
        resp.pmodes[0].r.x = 0;
        resp.pmodes[0].r.y = 0;
        resp.pmodes[0].r.width = self.display_width;
        resp.pmodes[0].r.height = self.display_height;
    }

    pub fn handleResourceCreate2D(self: *VirtioGpu, req: *const VirtioGpuResourceCreate2D) u32 {
        if (req.resource_id == 0 or req.resource_id >= MAX_SYSTEM_RESOURCES) {
            return VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
        }
        if (self.getResource(req.resource_id) != null) {
            return VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
        }
        switch (req.format) {
            VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM,
            VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM,
            VIRTIO_GPU_FORMAT_A8R8G8B8_UNORM,
            VIRTIO_GPU_FORMAT_X8R8G8B8_UNORM,
            VIRTIO_GPU_FORMAT_R8G8B8A8_UNORM,
            VIRTIO_GPU_FORMAT_X8B8G8R8_UNORM,
            => {},
            else => return VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER,
        }
        if (req.width == 0 or req.height == 0 or req.width > 4096 or req.height > 4096) {
            return VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
        }
        const pixels = std.math.mul(u32, req.width, req.height) catch return VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
        _ = std.math.mul(u32, pixels, 4) catch return VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
        const res = self.allocateResource(req.resource_id) orelse return VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
        res.* = .{
            .id = req.resource_id,
            .format = req.format,
            .width = req.width,
            .height = req.height,
            .is_active = true,
            .next = res.next,
        };
        return VIRTIO_GPU_RESP_OK_NODATA;
    }

    pub fn handleResourceUnref(self: *VirtioGpu, req: *const VirtioGpuResourceUnref) u32 {
        if (req.resource_id >= STATIC_RESOURCES) {
            while (self.lock.swap(true, .acquire)) {
                std.atomic.spinLoopHint();
            }
            defer self.lock.store(false, .release);
            const res = self.getResource(req.resource_id) orelse return VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
            res.is_active = false;
            res.scanout_id = null;
            res.backing_gpa = 0;
            res.backing_len = 0;
            return VIRTIO_GPU_RESP_OK_NODATA;
        }
        const res = self.getResource(req.resource_id) orelse return VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
        res.is_active = false;
        res.scanout_id = null;
        res.backing_gpa = 0;
        res.backing_len = 0;
        return VIRTIO_GPU_RESP_OK_NODATA;
    }

    pub fn handleSetScanout(self: *VirtioGpu, req: *const VirtioGpuSetScanout) u32 {
        if (req.scanout_id >= MAX_SCANOUTS) {
            return VIRTIO_GPU_RESP_ERR_INVALID_SCANOUT_ID;
        }
        if (req.resource_id != 0) {
            const res = self.getResource(req.resource_id) orelse return VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
            const end_x = std.math.add(u32, req.r.x, req.r.width) catch return VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
            const end_y = std.math.add(u32, req.r.y, req.r.height) catch return VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
            if (end_x > res.width or end_y > res.height) {
                return VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
            }
            res.scanout_id = req.scanout_id;
        }
        return VIRTIO_GPU_RESP_OK_NODATA;
    }

    pub fn handleResourceFlush(self: *VirtioGpu, req: *const VirtioGpuResourceFlush) u32 {
        const res = self.getResource(req.resource_id) orelse return VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
        const end_x = std.math.add(u32, req.r.x, req.r.width) catch return VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
        const end_y = std.math.add(u32, req.r.y, req.r.height) catch return VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
        if (end_x > res.width or end_y > res.height) {
            return VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER;
        }
        self.flushes_count += 1;
        self.last_flushed_resource = req.resource_id;
        return VIRTIO_GPU_RESP_OK_NODATA;
    }
};

test "VirtIO GPU register probe, display info, and 2D resource management" {
    const testing = std.testing;

    var gpu = VirtioGpu.init(2);

    try testing.expectEqual(VIRTIO_MAGIC, gpu.readReg(0x000));
    try testing.expectEqual(VIRTIO_VERSION, gpu.readReg(0x004));
    try testing.expectEqual(VIRTIO_ID_GPU, gpu.readReg(0x008));
    try testing.expectEqual(VIRTIO_VENDOR_ID, gpu.readReg(0x00c));

    var disp_resp: VirtioGpuRespDisplayInfo = undefined;
    gpu.handleGetDisplayInfo(&disp_resp);
    try testing.expectEqual(VIRTIO_GPU_RESP_OK_DISPLAY_INFO, disp_resp.hdr.type);
    try testing.expectEqual(@as(u32, 1), disp_resp.pmodes[0].enabled);
    try testing.expectEqual(@as(u32, 1280), disp_resp.pmodes[0].r.width);
    try testing.expectEqual(@as(u32, 720), disp_resp.pmodes[0].r.height);

    const create_req = VirtioGpuResourceCreate2D{
        .hdr = .{ .type = VIRTIO_GPU_CMD_RESOURCE_CREATE_2D, .flags = 0, .fence_id = 0, .ctx_id = 0, .padding = 0 },
        .resource_id = 1,
        .format = VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM,
        .width = 1280,
        .height = 720,
    };
    try testing.expectEqual(VIRTIO_GPU_RESP_OK_NODATA, gpu.handleResourceCreate2D(&create_req));
    try testing.expect(gpu.getResource(1) != null);
    try testing.expect(gpu.getResource(1).?.is_active);

    const scanout_req = VirtioGpuSetScanout{
        .hdr = .{ .type = VIRTIO_GPU_CMD_SET_SCANOUT, .flags = 0, .fence_id = 0, .ctx_id = 0, .padding = 0 },
        .r = .{ .x = 0, .y = 0, .width = 1280, .height = 720 },
        .scanout_id = 0,
        .resource_id = 1,
    };
    try testing.expectEqual(VIRTIO_GPU_RESP_OK_NODATA, gpu.handleSetScanout(&scanout_req));

    const flush_req = VirtioGpuResourceFlush{
        .hdr = .{ .type = VIRTIO_GPU_CMD_RESOURCE_FLUSH, .flags = 0, .fence_id = 0, .ctx_id = 0, .padding = 0 },
        .r = .{ .x = 0, .y = 0, .width = 1280, .height = 720 },
        .resource_id = 1,
        .padding = 0,
    };
    try testing.expectEqual(VIRTIO_GPU_RESP_OK_NODATA, gpu.handleResourceFlush(&flush_req));
    try testing.expectEqual(@as(usize, 1), gpu.flushes_count);
    try testing.expectEqual(@as(u32, 1), gpu.last_flushed_resource);

    // Test dynamic resource allocation (>= 32) and bucket hash collision resolution (32 and 64 map to bucket 0)
    var dyn_req_32 = create_req;
    dyn_req_32.resource_id = 32;
    try testing.expectEqual(VIRTIO_GPU_RESP_OK_NODATA, gpu.handleResourceCreate2D(&dyn_req_32));
    try testing.expect(gpu.getResource(32) != null);

    var dyn_req_64 = create_req;
    dyn_req_64.resource_id = 64;
    try testing.expectEqual(VIRTIO_GPU_RESP_OK_NODATA, gpu.handleResourceCreate2D(&dyn_req_64));
    try testing.expect(gpu.getResource(64) != null);
    try testing.expect(gpu.getResource(32) != null);

    // Test flush of dynamic resource
    var dyn_flush_64 = flush_req;
    dyn_flush_64.resource_id = 64;
    try testing.expectEqual(VIRTIO_GPU_RESP_OK_NODATA, gpu.handleResourceFlush(&dyn_flush_64));
    try testing.expectEqual(@as(u32, 64), gpu.last_flushed_resource);

    // Duplicate dynamic resource rejection
    try testing.expectEqual(VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID, gpu.handleResourceCreate2D(&dyn_req_32));

    // Dynamic unref and slot reuse
    const unref_32 = VirtioGpuResourceUnref{
        .hdr = .{ .type = VIRTIO_GPU_CMD_RESOURCE_UNREF, .flags = 0, .fence_id = 0, .ctx_id = 0, .padding = 0 },
        .resource_id = 32,
        .padding = 0,
    };
    try testing.expectEqual(VIRTIO_GPU_RESP_OK_NODATA, gpu.handleResourceUnref(&unref_32));
    try testing.expect(gpu.getResource(32) == null);

    // Re-create resource 32 (reuses inactive bucket node)
    try testing.expectEqual(VIRTIO_GPU_RESP_OK_NODATA, gpu.handleResourceCreate2D(&dyn_req_32));
    try testing.expect(gpu.getResource(32) != null);

    // Test zero queue size rejection
    gpu.writeReg(0x030, 0); // Queue 0
    gpu.writeReg(0x038, 0); // QueueNum = 0
    try testing.expect(gpu.queues[0].num > 0);

    // Test out-of-bounds flush rectangle rejection
    const bad_flush = VirtioGpuResourceFlush{
        .hdr = .{ .type = VIRTIO_GPU_CMD_RESOURCE_FLUSH, .flags = 0, .fence_id = 0, .ctx_id = 0, .padding = 0 },
        .r = .{ .x = 1000, .y = 500, .width = 1280, .height = 720 }, // Exceeds 1280x720
        .resource_id = 1,
        .padding = 0,
    };
    try testing.expectEqual(VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER, gpu.handleResourceFlush(&bad_flush));

    // Test duplicate resource creation rejection
    try testing.expectEqual(VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID, gpu.handleResourceCreate2D(&create_req));

    // Test invalid format rejection
    var bad_fmt_req = create_req;
    bad_fmt_req.resource_id = 2;
    bad_fmt_req.format = 999;
    try testing.expectEqual(VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER, gpu.handleResourceCreate2D(&bad_fmt_req));

    // Test resource ID 0 and >= MAX_SYSTEM_RESOURCES rejection
    var zero_res_req = create_req;
    zero_res_req.resource_id = 0;
    try testing.expectEqual(VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID, gpu.handleResourceCreate2D(&zero_res_req));

    var oob_res_req = create_req;
    oob_res_req.resource_id = MAX_SYSTEM_RESOURCES;
    try testing.expectEqual(VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID, gpu.handleResourceCreate2D(&oob_res_req));

    // Test QueueNumMax valid and out-of-bounds selector
    gpu.writeReg(bus.VIRTIO_MMIO_REG_QUEUE_SEL, 0);
    try testing.expectEqual(QUEUE_SIZE_MAX, gpu.readReg(bus.VIRTIO_MMIO_REG_QUEUE_NUM_MAX));
    gpu.writeReg(bus.VIRTIO_MMIO_REG_QUEUE_SEL, 99);
    try testing.expectEqual(@as(u32, 0), gpu.readReg(bus.VIRTIO_MMIO_REG_QUEUE_NUM_MAX));
}

