// VirtIO-GPU (2D Graphics & Display Device) Emulation
// Implements VirtIO 1.1 / 1.2 Device ID 16 (VIRTIO_ID_GPU) for standard
// DRM/KMS desktop display.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const bus = @import("bus.zig");
const vsock_mod = @import("vsock.zig");
pub const proto = @import("vgpu/protocol.zig");
pub const commands = @import("vgpu/commands.zig");
pub const queue = @import("vgpu/queue.zig");
pub const scanout = @import("vgpu/scanout.zig");
pub const damage = @import("vgpu/damage.zig");

pub const MemoryAccessor = vsock_mod.MemoryAccessor;
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
pub const ScanoutSnapshot = scanout.ScanoutSnapshot;
pub const PixelChunkSink = scanout.PixelChunkSink;

pub const VirtqDesc = bus.VirtqDesc;
pub const VIRTQ_DESC_F_NEXT = bus.VIRTQ_DESC_F_NEXT;
pub const VIRTQ_DESC_F_WRITE = bus.VIRTQ_DESC_F_WRITE;
pub const VirtqUsedElem = bus.VirtqUsedElem;
pub const VirtQueue = bus.VirtQueueConfig(QUEUE_SIZE_MAX);

pub const VirtioGpu = struct {
    pub const proto_mod = proto;
    pub const commands_mod = commands;
    pub const damage_mod = damage;
    guest_cid: usize = 0,
    mem: ?MemoryAccessor = null,
    allocator: ?std.mem.Allocator = null,
    status: u32 = 0,
    device_features_sel: u32 = 0,
    driver_features_sel: u32 = 0,
    driver_features: u64 = 0,
    queue_sel: u32 = 0,
    events_read: u32 = 0,
    interrupt_status: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    queues: [NUM_QUEUES]VirtQueue = @splat(.{}),
    /// Column 1: Static fast-path resources 0..31 (O(1) direct index).
    static_resources: [STATIC_RESOURCES]VirtioGpuResource = @splat(.{}),
    /// Column 2: Dynamic hash buckets for resource IDs >= 32 (id % 32).
    dynamic_buckets: [DYNAMIC_HASH_BUCKETS]?*VirtioGpuResource = @splat(null),
    /// Embedded pool for standalone execution (up to 128 dynamic resources).
    dynamic_pool: [DYNAMIC_POOL_CAPACITY]VirtioGpuResource = @splat(.{}),
    pool_count: usize = 0,
    lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    display_width: u32 = DEFAULT_DISPLAY_WIDTH,
    display_height: u32 = DEFAULT_DISPLAY_HEIGHT,
    active_scanout_res_id: u32 = 0,
    scanout_rect: VirtioGpuRect = .{},
    cursor_resource_id: u32 = 0,
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
    cursor_hot_x: u32 = 0,
    cursor_hot_y: u32 = 0,
    frame_seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    cursor_seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    flushes_count: usize = 0,
    last_flushed_resource: u32 = 0,
    damage_ring: damage.DamageRing = .{},

    pub inline fn acquireLock(self: *VirtioGpu) void {
        while (self.lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
    }

    pub inline fn releaseLock(self: *VirtioGpu) void {
        self.lock.store(false, .release);
    }

    pub fn initWithMem(
        guest_cid: usize,
        mem: ?MemoryAccessor,
        allocator: ?std.mem.Allocator,
    ) VirtioGpu {
        return .{
            .guest_cid = guest_cid,
            .mem = mem,
            .allocator = allocator,
        };
    }

    fn getDynamicResourceLocked(
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

    pub fn getResourceUnlocked(self: *VirtioGpu, id: u32) ?*VirtioGpuResource {
        if (id == 0 or id >= MAX_SYSTEM_RESOURCES) return null;
        if (id < STATIC_RESOURCES) {
            const res = &self.static_resources[id];
            return if (res.is_active) res else null;
        }
        return self.getDynamicResourceLocked(id);
    }

    pub fn allocateResourceUnlocked(
        self: *VirtioGpu,
        id: u32,
    ) ?*VirtioGpuResource {
        if (id == 0 or id >= MAX_SYSTEM_RESOURCES) return null;
        if (id < STATIC_RESOURCES) {
            const res = &self.static_resources[id];
            if (res.is_active) return null;
            res.is_active = true;
            return res;
        }
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

    pub fn readReg(self: *VirtioGpu, offset: u32) u32 {
        self.acquireLock();
        defer self.releaseLock();

        const irq = self.interrupt_status.load(.acquire);
        if (bus.readVirtioCommon(
            self,
            VIRTIO_ID_GPU,
            NUM_QUEUES,
            QUEUE_SIZE_MAX,
            irq,
            offset,
        )) |common| return common;

        if (offset >= bus.VIRTIO_MMIO_REG_CONFIG_BASE and
            offset < bus.VIRTIO_MMIO_REG_CONFIG_BASE + proto.CONFIG_SPACE_BYTES)
        {
            var cfg: [proto.CONFIG_SPACE_BYTES]u8 = @splat(0);
            std.mem.writeInt(u32, cfg[0..4], self.events_read, .little);
            std.mem.writeInt(u32, cfg[8..12], proto.ACTIVE_SCANOUTS, .little);
            const rel: usize = @intCast(
                offset - bus.VIRTIO_MMIO_REG_CONFIG_BASE,
            );
            var word: [4]u8 = @splat(0);
            const copy_len: usize = @min(@as(usize, 4), cfg.len - rel);
            @memcpy(word[0..copy_len], cfg[rel .. rel + copy_len]);
            return std.mem.readInt(u32, &word, .little);
        }
        return 0;
    }

    pub fn writeReg(self: *VirtioGpu, offset: u32, val: u32) void {
        self.acquireLock();
        defer self.releaseLock();

        if (bus.writeVirtioQueueAndFeatureReg(
            self,
            NUM_QUEUES,
            QUEUE_SIZE_MAX,
            offset,
            val,
        )) return;

        switch (offset) {
            bus.VIRTIO_MMIO_REG_QUEUE_NOTIFY => {
                if (val == proto.QUEUE_INDEX_CONTROL or
                    val == proto.QUEUE_INDEX_CURSOR)
                {
                    queue.processQueueLocked(self, val);
                }
            },
            bus.VIRTIO_MMIO_REG_INTERRUPT_ACK => {
                _ = self.interrupt_status.fetchAnd(~val, .acq_rel);
            },
            bus.VIRTIO_MMIO_REG_STATUS => {
                self.status = val;
                if (val == 0) self.resetLocked();
            },
            proto.REG_CONFIG_EVENTS_CLEAR => {
                self.events_read &= ~val;
            },
            else => {},
        }
    }

    fn clearAllResourcesLocked(self: *VirtioGpu) void {
        for (&self.static_resources) |*r| {
            r.clearBacking(self.allocator);
            r.* = .{};
        }
        for (self.dynamic_pool[0..self.pool_count]) |*r| {
            r.clearBacking(self.allocator);
            r.* = .{};
        }
        self.dynamic_buckets = @splat(null);
        self.pool_count = 0;
        self.active_scanout_res_id = 0;
        self.scanout_rect = .{};
        self.cursor_resource_id = 0;
    }

    fn resetLocked(self: *VirtioGpu) void {
        self.status = 0;
        self.events_read = 0;
        self.interrupt_status.store(0, .release);
        for (&self.queues) |*q| q.* = .{};
        self.clearAllResourcesLocked();
        _ = self.frame_seq.fetchAdd(1, .acq_rel);
    }

    pub fn reset(self: *VirtioGpu) void {
        self.acquireLock();
        defer self.releaseLock();
        self.resetLocked();
    }

    pub fn deinit(self: *VirtioGpu) void {
        self.acquireLock();
        defer self.releaseLock();
        self.clearAllResourcesLocked();
    }

    /// Updates the preferred scanout resolution reported by `GET_DISPLAY_INFO`.
    /// Clamps dimensions to valid VirtIO-GPU bounds and aligns width to 8
    /// pixels and height to 2 pixels to match Linux `drm_cvt_mode` granularity.
    /// Raises `VIRTIO_GPU_EVENT_DISPLAY` and `VIRTIO_MMIO_INT_CONFIG` only
    /// once the guest driver has set `VIRTIO_CONFIG_S_DRIVER_OK`.
    pub fn setDisplaySize(self: *VirtioGpu, width: u32, height: u32) bool {
        if (width == 0 or height == 0) return false;
        const clamped_w: u32 = std.math.clamp(
            width,
            proto.MIN_DISPLAY_WIDTH,
            MAX_RESOURCE_DIMENSION,
        );
        const clamped_h: u32 = std.math.clamp(
            height,
            proto.MIN_DISPLAY_HEIGHT,
            MAX_RESOURCE_DIMENSION,
        );
        const aligned_w: u32 = clamped_w & ~proto.DISPLAY_WIDTH_ALIGN_MASK;
        const aligned_h: u32 = clamped_h & ~proto.DISPLAY_HEIGHT_ALIGN_MASK;

        self.acquireLock();
        defer self.releaseLock();

        if (self.display_width == aligned_w and
            self.display_height == aligned_h)
        {
            return false;
        }
        self.display_width = aligned_w;
        self.display_height = aligned_h;
        if ((self.status & bus.VIRTIO_CONFIG_S_DRIVER_OK) == 0) {
            return false;
        }
        self.events_read |= proto.VIRTIO_GPU_EVENT_DISPLAY;
        _ = self.interrupt_status.fetchOr(bus.VIRTIO_MMIO_INT_CONFIG, .acq_rel);
        return true;
    }

    pub fn streamScanout(
        self: *VirtioGpu,
        client_seq: u64,
        max_pixels: usize,
        sink: ?PixelChunkSink,
    ) ScanoutSnapshot {
        self.acquireLock();
        defer self.releaseLock();
        return scanout.streamScanoutLocked(self, client_seq, max_pixels, sink);
    }

    pub fn readScanout(
        self: *VirtioGpu,
        client_seq: u64,
        out_pixels: ?[]u32,
    ) ScanoutSnapshot {
        self.acquireLock();
        defer self.releaseLock();
        return scanout.readScanoutLocked(self, client_seq, out_pixels);
    }
};

test "VirtIO GPU register probe, config num_scanouts, and 2D scanout readout" {
    const testing = std.testing;
    testing.refAllDecls(@This());
    _ = proto;
    _ = commands;
    _ = queue;
    _ = scanout;
    _ = damage;

    const GuestRam = struct {
        buf: [4096]u8 = @splat(0),
        fn read(ctx: *anyopaque, gpa: u64, out: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const off: usize = @intCast(gpa);
            if (off + out.len > self.buf.len) return false;
            @memcpy(out, self.buf[off .. off + out.len]);
            return true;
        }
        fn write(ctx: *anyopaque, gpa: u64, data: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const off: usize = @intCast(gpa);
            if (off + data.len > self.buf.len) return false;
            @memcpy(self.buf[off .. off + data.len], data);
            return true;
        }
    };
    var ram = GuestRam{};
    var gpu = VirtioGpu.initWithMem(
        2,
        .{ .ctx = &ram, .readFn = GuestRam.read, .writeFn = GuestRam.write },
        testing.allocator,
    );
    defer gpu.deinit();

    try testing.expectEqual(VIRTIO_MAGIC, gpu.readReg(0x000));
    try testing.expectEqual(VIRTIO_VERSION, gpu.readReg(0x004));
    try testing.expectEqual(VIRTIO_ID_GPU, gpu.readReg(0x008));
    try testing.expectEqual(proto.ACTIVE_SCANOUTS, gpu.readReg(0x108));

    var disp_resp: VirtioGpuRespDisplayInfo = undefined;
    commands.handleGetDisplayInfoLocked(&gpu, &disp_resp);
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_OK_DISPLAY_INFO,
        disp_resp.hdr.type,
    );
    try testing.expectEqual(@as(u32, 1), disp_resp.pmodes[0].enabled);

    const create_req = VirtioGpuResourceCreate2D{
        .hdr = .{ .type = proto.VIRTIO_GPU_CMD_RESOURCE_CREATE_2D },
        .resource_id = 1,
        .format = proto.VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM,
        .width = 2,
        .height = 2,
    };
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_OK_NODATA,
        commands.handleResourceCreate2DLocked(&gpu, &create_req),
    );
    // Write 4 pixels in B8G8R8X8 at GPA 0x100: red, green, blue, white.
    @memcpy(ram.buf[0x100..0x110], &[_]u8{
        0x00, 0x00, 0xff, 0xff,
        0x00, 0xff, 0x00, 0xff,
        0xff, 0x00, 0x00, 0xff,
        0xff, 0xff, 0xff, 0xff,
    });
    const attach = VirtioGpuResourceAttachBacking{
        .hdr = .{},
        .resource_id = 1,
        .nr_entries = 1,
    };
    const ent = [_]VirtioGpuMemEntry{.{ .addr = 0x100, .length = 16 }};
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_OK_NODATA,
        commands.handleAttachBackingSliceLocked(&gpu, &attach, &ent),
    );
    const scan_req = VirtioGpuSetScanout{
        .hdr = .{},
        .r = .{ .x = 0, .y = 0, .width = 2, .height = 2 },
        .scanout_id = 0,
        .resource_id = 1,
    };
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_OK_NODATA,
        commands.handleSetScanoutLocked(&gpu, &scan_req),
    );
    try testing.expectEqual(
        proto.VIRTIO_GPU_RESP_OK_NODATA,
        commands.handleResourceFlushLocked(&gpu, &.{
            .hdr = .{},
            .r = .{ .x = 0, .y = 0, .width = 2, .height = 2 },
            .resource_id = 1,
            .padding = 0,
        }),
    );

    var px: [4]u32 = @splat(0);
    const snap = gpu.readScanout(0, &px);
    try testing.expect(snap.active and snap.updated);
    try testing.expectEqual(@as(u32, 0x00ff0000), px[0]);
    try testing.expectEqual(@as(u32, 0x0000ff00), px[1]);
    try testing.expectEqual(@as(u32, 0x000000ff), px[2]);
    try testing.expectEqual(@as(u32, 0x00ffffff), px[3]);
    // Unchanged frame_seq skips pixel copy.
    const unchanged = gpu.readScanout(snap.frame_seq, &px);
    try testing.expect(unchanged.active and !unchanged.updated);

    // Pre-DRIVER_OK resize updates dimensions without raising config IRQ.
    try testing.expect(!gpu.setDisplaySize(1015, 631));
    try testing.expectEqual(@as(u32, 1008), gpu.display_width);
    try testing.expectEqual(@as(u32, 630), gpu.display_height);
    try testing.expectEqual(
        @as(u32, 0),
        gpu.readReg(bus.VIRTIO_MMIO_REG_CONFIG_BASE),
    );

    // Post-DRIVER_OK resize raises VIRTIO_GPU_EVENT_DISPLAY + config IRQ.
    gpu.writeReg(bus.VIRTIO_MMIO_REG_STATUS, bus.VIRTIO_CONFIG_S_DRIVER_OK);
    try testing.expect(gpu.setDisplaySize(1080, 626));
    try testing.expectEqual(@as(u32, 1080), gpu.display_width);
    try testing.expectEqual(@as(u32, 626), gpu.display_height);
    try testing.expectEqual(
        proto.VIRTIO_GPU_EVENT_DISPLAY,
        gpu.readReg(bus.VIRTIO_MMIO_REG_CONFIG_BASE),
    );
    try testing.expect(!gpu.setDisplaySize(1080, 626));
}
