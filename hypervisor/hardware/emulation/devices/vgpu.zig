// VirtIO-GPU (2D Graphics & Display Device) Emulation
// Implements VirtIO 1.1 / 1.2 Device ID 16 (VIRTIO_ID_GPU) for standard DRM/KMS desktop display.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

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
pub const MAX_RESOURCES: usize = 64;

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
    interrupt_status: u32 = 0,

    queues: [NUM_QUEUES]VirtQueue = @splat(.{}),
    resources: [MAX_RESOURCES]VirtioGpuResource = @splat(.{}),

    display_width: u32 = 1280,
    display_height: u32 = 720,
    flushes_count: usize = 0,
    last_flushed_resource: u32 = 0,

    pub fn init(guest_cid: usize) VirtioGpu {
        return .{
            .guest_cid = guest_cid,
        };
    }

    pub fn readReg(self: *VirtioGpu, offset: u32) u32 {
        return switch (offset) {
            0x000 => VIRTIO_MAGIC,
            0x004 => VIRTIO_VERSION,
            0x008 => VIRTIO_ID_GPU,
            0x00c => VIRTIO_VENDOR_ID,
            0x010 => blk: {
                if (self.device_features_sel == 0) {
                    break :blk 0;
                } else if (self.device_features_sel == 1) {
                    break :blk 1; // VIRTIO_F_VERSION_1
                }
                break :blk 0;
            },
            0x034 => QUEUE_SIZE_MAX,
            0x044 => if (self.queue_sel < NUM_QUEUES and self.queues[self.queue_sel].ready) 1 else 0,
            0x060 => self.interrupt_status,
            0x070 => self.status,
            else => 0,
        };
    }

    pub fn writeReg(self: *VirtioGpu, offset: u32, val: u32) void {
        switch (offset) {
            0x014 => self.device_features_sel = val,
            0x020 => {
                if (self.driver_features_sel == 0) {
                    self.driver_features = (self.driver_features & 0xFFFFFFFF00000000) | val;
                } else {
                    self.driver_features = (self.driver_features & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
                }
            },
            0x024 => self.driver_features_sel = val,
            0x030 => self.queue_sel = val,
            0x038 => {
                if (self.queue_sel < NUM_QUEUES) {
                    self.queues[self.queue_sel].num = @truncate(@min(val, QUEUE_SIZE_MAX));
                }
            },
            0x044 => {
                if (self.queue_sel < NUM_QUEUES) {
                    self.queues[self.queue_sel].ready = (val & 1) != 0;
                }
            },
            0x050 => {
                const q_idx = val;
                if (q_idx == 0) {
                    self.processControlQueue();
                }
            },
            0x064 => self.interrupt_status &= ~val,
            0x070 => {
                self.status = val;
                if (val == 0) {
                    self.reset();
                }
            },
            0x080 => {
                if (self.queue_sel < NUM_QUEUES) self.queues[self.queue_sel].desc_gpa = (self.queues[self.queue_sel].desc_gpa & 0xFFFFFFFF00000000) | val;
            },
            0x084 => {
                if (self.queue_sel < NUM_QUEUES) self.queues[self.queue_sel].desc_gpa = (self.queues[self.queue_sel].desc_gpa & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
            },
            0x090 => {
                if (self.queue_sel < NUM_QUEUES) self.queues[self.queue_sel].driver_gpa = (self.queues[self.queue_sel].driver_gpa & 0xFFFFFFFF00000000) | val;
            },
            0x094 => {
                if (self.queue_sel < NUM_QUEUES) self.queues[self.queue_sel].driver_gpa = (self.queues[self.queue_sel].driver_gpa & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
            },
            0x0a0 => {
                if (self.queue_sel < NUM_QUEUES) self.queues[self.queue_sel].device_gpa = (self.queues[self.queue_sel].device_gpa & 0xFFFFFFFF00000000) | val;
            },
            0x0a4 => {
                if (self.queue_sel < NUM_QUEUES) self.queues[self.queue_sel].device_gpa = (self.queues[self.queue_sel].device_gpa & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
            },
            else => {},
        }
    }

    pub fn reset(self: *VirtioGpu) void {
        self.status = 0;
        self.interrupt_status = 0;
        for (&self.queues) |*q| {
            q.* = .{};
        }
        for (&self.resources) |*r| {
            r.* = .{};
        }
    }

    pub fn processControlQueue(self: *VirtioGpu) void {
        self.interrupt_status |= 1;
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
        if (req.resource_id == 0 or req.resource_id >= MAX_RESOURCES) {
            return VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
        }
        self.resources[req.resource_id] = .{
            .id = req.resource_id,
            .format = req.format,
            .width = req.width,
            .height = req.height,
            .is_active = true,
        };
        return VIRTIO_GPU_RESP_OK_NODATA;
    }

    pub fn handleResourceUnref(self: *VirtioGpu, req: *const VirtioGpuResourceUnref) u32 {
        if (req.resource_id == 0 or req.resource_id >= MAX_RESOURCES or !self.resources[req.resource_id].is_active) {
            return VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
        }
        self.resources[req.resource_id] = .{};
        return VIRTIO_GPU_RESP_OK_NODATA;
    }

    pub fn handleSetScanout(self: *VirtioGpu, req: *const VirtioGpuSetScanout) u32 {
        if (req.scanout_id >= MAX_SCANOUTS) {
            return VIRTIO_GPU_RESP_ERR_INVALID_SCANOUT_ID;
        }
        if (req.resource_id != 0) {
            if (req.resource_id >= MAX_RESOURCES or !self.resources[req.resource_id].is_active) {
                return VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
            }
            self.resources[req.resource_id].scanout_id = req.scanout_id;
        }
        return VIRTIO_GPU_RESP_OK_NODATA;
    }

    pub fn handleResourceFlush(self: *VirtioGpu, req: *const VirtioGpuResourceFlush) u32 {
        if (req.resource_id == 0 or req.resource_id >= MAX_RESOURCES or !self.resources[req.resource_id].is_active) {
            return VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
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
    try testing.expect(gpu.resources[1].is_active);

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
}
