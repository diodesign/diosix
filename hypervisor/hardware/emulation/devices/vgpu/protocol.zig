// VirtIO-GPU 2D Protocol Constants & Wire Structures
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const bus = @import("../bus.zig");

pub const VIRTIO_ID_GPU: u32 = 16;
pub const VIRTIO_VENDOR_ID: u32 = bus.VIRTIO_MMIO_VENDOR_QEMU;
pub const VIRTIO_MAGIC: u32 = bus.VIRTIO_MMIO_MAGIC;
pub const VIRTIO_VERSION: u32 = bus.VIRTIO_MMIO_VERSION_2;

pub const QUEUE_SIZE_MAX: u16 = 64;
pub const NUM_QUEUES: usize = 2; // 0 = controlq, 1 = cursorq.
pub const QUEUE_INDEX_CONTROL: usize = 0;
pub const QUEUE_INDEX_CURSOR: usize = 1;

pub const CONFIG_SPACE_BYTES: u32 = 16;
pub const REG_CONFIG_EVENTS_CLEAR: u32 = bus.VIRTIO_MMIO_REG_CONFIG_BASE + 4;
pub const ACTIVE_SCANOUTS: u32 = 1;
pub const VIRTIO_GPU_EVENT_DISPLAY: u32 = 1 << 0;
pub const VIRTIO_GPU_FLAG_FENCE: u32 = 1 << 0;

pub const MIN_DISPLAY_WIDTH: u32 = 320;
pub const MIN_DISPLAY_HEIGHT: u32 = 200;
pub const DEFAULT_DISPLAY_WIDTH: u32 = 1280;
pub const DEFAULT_DISPLAY_HEIGHT: u32 = 720;
pub const DISPLAY_WIDTH_ALIGN_MASK: u32 = 0x7;
pub const DISPLAY_HEIGHT_ALIGN_MASK: u32 = 0x1;
pub const MAX_RESOURCE_DIMENSION: u32 = 4096;
pub const CURSOR_DIMENSION: u32 = 64;
pub const BYTES_PER_PIXEL_RGBA: u32 = 4;
pub const MAX_BACKING_ENTRIES: u32 = 16_384;

// VirtIO GPU Pixel Formats.
pub const VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM: u32 = 1;
pub const VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM: u32 = 2;
pub const VIRTIO_GPU_FORMAT_A8R8G8B8_UNORM: u32 = 3;
pub const VIRTIO_GPU_FORMAT_X8R8G8B8_UNORM: u32 = 4;
pub const VIRTIO_GPU_FORMAT_R8G8B8A8_UNORM: u32 = 67;
pub const VIRTIO_GPU_FORMAT_X8B8G8R8_UNORM: u32 = 68;
pub const VIRTIO_GPU_FORMAT_A8B8G8R8_UNORM: u32 = 121;
pub const VIRTIO_GPU_FORMAT_R8G8B8X8_UNORM: u32 = 134;

// VirtIO GPU 2D & Cursor Commands.
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

// VirtIO GPU Responses.
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

pub const VirtioGpuCtrlHdr = extern struct {
    type: u32 = 0,
    flags: u32 = 0,
    fence_id: u64 = 0,
    ctx_id: u32 = 0,
    padding: u32 = 0,
};

pub const VirtioGpuRect = extern struct {
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

pub const VirtioGpuDisplayOne = extern struct {
    r: VirtioGpuRect = .{},
    enabled: u32 = 0,
    flags: u32 = 0,
};

pub const VirtioGpuRespDisplayInfo = extern struct {
    hdr: VirtioGpuCtrlHdr = .{},
    pmodes: [MAX_SCANOUTS]VirtioGpuDisplayOne = @splat(.{}),
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
    addr: u64 = 0,
    length: u32 = 0,
    padding: u32 = 0,
};

pub const VirtioGpuResourceAttachBacking = extern struct {
    hdr: VirtioGpuCtrlHdr,
    resource_id: u32,
    nr_entries: u32,
};

pub const VirtioGpuResourceDetachBacking = extern struct {
    hdr: VirtioGpuCtrlHdr,
    resource_id: u32,
    padding: u32,
};

pub const VirtioGpuCursorPos = extern struct {
    scanout_id: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    padding: u32 = 0,
};

pub const VirtioGpuUpdateCursor = extern struct {
    hdr: VirtioGpuCtrlHdr,
    pos: VirtioGpuCursorPos,
    resource_id: u32,
    hot_x: u32,
    hot_y: u32,
    padding: u32,
};

pub fn initRespHdr(
    req_hdr: *const VirtioGpuCtrlHdr,
    resp_type: u32,
) VirtioGpuCtrlHdr {
    const fenced = (req_hdr.flags & VIRTIO_GPU_FLAG_FENCE) != 0;
    return .{
        .type = resp_type,
        .flags = if (fenced) VIRTIO_GPU_FLAG_FENCE else 0,
        .fence_id = if (fenced) req_hdr.fence_id else 0,
        .ctx_id = req_hdr.ctx_id,
        .padding = 0,
    };
}

pub const VirtioGpuResource = struct {
    id: u32 = 0,
    format: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    scanout_id: ?u32 = null,
    backing_gpa: u64 = 0,
    backing_len: usize = 0,
    backing_entries: ?[]VirtioGpuMemEntry = null,
    inline_entry: VirtioGpuMemEntry = .{},
    has_inline_entry: bool = false,
    backing_gen: u64 = 0,
    last_transfer_rect: VirtioGpuRect = .{},
    is_active: bool = false,
    next: ?*VirtioGpuResource = null,

    pub fn clearBacking(
        self: *VirtioGpuResource,
        allocator: ?std.mem.Allocator,
    ) void {
        if (self.backing_entries) |entries| {
            if (allocator) |alloc| alloc.free(entries);
            self.backing_entries = null;
        }
        self.inline_entry = .{};
        self.has_inline_entry = false;
        self.backing_gpa = 0;
        self.backing_len = 0;
        self.backing_gen +%= 1;
        self.last_transfer_rect = .{};
    }

    pub fn entriesSlice(
        self: *const VirtioGpuResource,
    ) []const VirtioGpuMemEntry {
        if (self.backing_entries) |entries| return entries;
        if (self.has_inline_entry) return (&self.inline_entry)[0..1];
        return &.{};
    }
};

comptime {
    std.debug.assert(@sizeOf(VirtioGpuCtrlHdr) == 24);
    std.debug.assert(@sizeOf(VirtioGpuRect) == 16);
    std.debug.assert(@sizeOf(VirtioGpuDisplayOne) == 24);
    std.debug.assert(@sizeOf(VirtioGpuResourceCreate2D) == 40);
    std.debug.assert(@sizeOf(VirtioGpuResourceUnref) == 32);
    std.debug.assert(@sizeOf(VirtioGpuSetScanout) == 48);
    std.debug.assert(@sizeOf(VirtioGpuResourceFlush) == 48);
    std.debug.assert(@sizeOf(VirtioGpuTransferToHost2D) == 56);
    std.debug.assert(@sizeOf(VirtioGpuMemEntry) == 16);
    std.debug.assert(@sizeOf(VirtioGpuResourceAttachBacking) == 32);
    std.debug.assert(@sizeOf(VirtioGpuResourceDetachBacking) == 32);
    std.debug.assert(@sizeOf(VirtioGpuCursorPos) == 16);
    std.debug.assert(@sizeOf(VirtioGpuUpdateCursor) == 56);
}

test "VirtIO GPU wire protocol structure sizes and fence propagation" {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(VirtioGpuCtrlHdr));
    try std.testing.expectEqual(
        @as(usize, 408),
        @sizeOf(VirtioGpuRespDisplayInfo),
    );
    const req = VirtioGpuCtrlHdr{
        .type = VIRTIO_GPU_CMD_RESOURCE_FLUSH,
        .flags = VIRTIO_GPU_FLAG_FENCE,
        .fence_id = 0xfeed_cafe,
        .ctx_id = 7,
    };
    const resp = initRespHdr(&req, VIRTIO_GPU_RESP_OK_NODATA);
    try std.testing.expectEqual(VIRTIO_GPU_FLAG_FENCE, resp.flags);
    try std.testing.expectEqual(@as(u64, 0xfeed_cafe), resp.fence_id);
    try std.testing.expectEqual(@as(u32, 7), resp.ctx_id);
}
