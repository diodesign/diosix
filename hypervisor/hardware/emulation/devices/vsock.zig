// VirtIO-vsock (Virtual Sockets) Device Emulation
// Implements VirtIO 1.1 / 1.2 Device ID 19 (VIRTIO_ID_VSOCK) for AF_VSOCK
// networking.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const bus = @import("bus.zig");
const router_mod = @import("vsock/router.zig");
const queues_mod = @import("vsock/queues.zig");

pub const VIRTIO_ID_VSOCK: u32 = 19;
pub const VIRTIO_VENDOR_ID: u32 = bus.VIRTIO_MMIO_VENDOR_QEMU;
pub const VIRTIO_MAGIC: u32 = bus.VIRTIO_MMIO_MAGIC;
pub const VIRTIO_VERSION: u32 = bus.VIRTIO_MMIO_VERSION_2;

pub const QUEUE_SIZE_MAX: u16 = 128;
pub const NUM_QUEUES: usize = 3; // 0 = rx, 1 = tx, 2 = event.
pub const QUEUE_INDEX_RX: usize = 0;
pub const QUEUE_INDEX_TX: usize = 1;
pub const MAX_PACKET_PAYLOAD: usize = 4096;

pub const VIRTIO_VSOCK_TYPE_STREAM = router_mod.VIRTIO_VSOCK_TYPE_STREAM;
pub const VIRTIO_VSOCK_TYPE_SEQPACKET = router_mod.VIRTIO_VSOCK_TYPE_SEQPACKET;
pub const VIRTIO_VSOCK_OP_INVALID = router_mod.VIRTIO_VSOCK_OP_INVALID;
pub const VIRTIO_VSOCK_OP_REQUEST = router_mod.VIRTIO_VSOCK_OP_REQUEST;
pub const VIRTIO_VSOCK_OP_RESPONSE = router_mod.VIRTIO_VSOCK_OP_RESPONSE;
pub const VIRTIO_VSOCK_OP_RST = router_mod.VIRTIO_VSOCK_OP_RST;
pub const VIRTIO_VSOCK_OP_SHUTDOWN = router_mod.VIRTIO_VSOCK_OP_SHUTDOWN;
pub const VIRTIO_VSOCK_OP_RW = router_mod.VIRTIO_VSOCK_OP_RW;
pub const VIRTIO_VSOCK_OP_CREDIT_UPDATE =
    router_mod.VIRTIO_VSOCK_OP_CREDIT_UPDATE;
pub const VIRTIO_VSOCK_OP_CREDIT_REQUEST =
    router_mod.VIRTIO_VSOCK_OP_CREDIT_REQUEST;

pub const VirtioVsockHdr = router_mod.VirtioVsockHdr;
pub const TABLE_BUCKETS = router_mod.TABLE_BUCKETS;
pub const VsockRouter = router_mod.VsockRouter;
pub const global_vsock_router = &router_mod.global_vsock_router;
pub const MemoryAccessor = router_mod.MemoryAccessor;

pub const VirtqDesc = bus.VirtqDesc;
pub const VIRTQ_DESC_F_NEXT = bus.VIRTQ_DESC_F_NEXT;
pub const VIRTQ_DESC_F_WRITE = bus.VIRTQ_DESC_F_WRITE;
pub const VirtqUsedElem = bus.VirtqUsedElem;
pub const VirtQueue = bus.VirtQueueConfig(QUEUE_SIZE_MAX);

pub const VirtioVsock = struct {
    guest_cid: u64 = 1,
    status: u32 = 0,
    device_features_sel: u32 = 0,
    driver_features_sel: u32 = 0,
    driver_features: u64 = 0,
    queue_sel: u32 = 0,
    interrupt_status: u32 = 0,
    queues: [NUM_QUEUES]VirtQueue = @splat(.{}),
    mem: ?MemoryAccessor = null,
    router: ?*VsockRouter = &router_mod.global_vsock_router,
    router_next: ?*VirtioVsock = null,
    rx_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    tx_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Initialize a `VirtioVsock` instance by value.
    /// Note: Call `router.register(&vsock)` on the pinned destination struct
    /// rather than registering a temporary stack address here.
    pub fn init(cid: u64, mem: ?MemoryAccessor) VirtioVsock {
        return .{
            .guest_cid = cid,
            .mem = mem,
        };
    }

    pub const REG_VSOCK_CID_LEGACY: u32 = 0x0fc;

    pub fn readReg(self: *VirtioVsock, offset: u32) u32 {
        const irq = @atomicLoad(u32, &self.interrupt_status, .seq_cst);
        if (bus.readVirtioCommon(
            self,
            VIRTIO_ID_VSOCK,
            NUM_QUEUES,
            QUEUE_SIZE_MAX,
            irq,
            offset,
        )) |common| return common;

        return switch (offset) {
            REG_VSOCK_CID_LEGACY,
            bus.VIRTIO_MMIO_REG_CONFIG_BASE,
            => @truncate(self.guest_cid),
            bus.VIRTIO_MMIO_REG_CONFIG_BASE + 4 => @truncate(
                self.guest_cid >> bus.HIGH_WORD_SHIFT,
            ),
            else => 0,
        };
    }

    pub fn writeReg(self: *VirtioVsock, offset: u32, val: u32) void {
        if (bus.writeVirtioQueueAndFeatureReg(
            self,
            NUM_QUEUES,
            QUEUE_SIZE_MAX,
            offset,
            val,
        )) return;

        switch (offset) {
            bus.VIRTIO_MMIO_REG_QUEUE_NOTIFY => {
                if (val == QUEUE_INDEX_TX) self.processTx();
            },
            bus.VIRTIO_MMIO_REG_INTERRUPT_ACK => {
                _ = @atomicRmw(
                    u32,
                    &self.interrupt_status,
                    .And,
                    ~val,
                    .seq_cst,
                );
            },
            bus.VIRTIO_MMIO_REG_STATUS => {
                self.status = val;
                if (val == 0) {
                    while (self.rx_lock.swap(true, .acquire)) {
                        std.atomic.spinLoopHint();
                    }
                    defer self.rx_lock.store(false, .release);
                    while (self.tx_lock.swap(true, .acquire)) {
                        std.atomic.spinLoopHint();
                    }
                    defer self.tx_lock.store(false, .release);
                    for (&self.queues) |*q| q.* = .{};
                    @atomicStore(u32, &self.interrupt_status, 0, .seq_cst);
                }
            },
            else => {},
        }
    }

    pub fn processTx(self: *VirtioVsock) void {
        queues_mod.processTx(self);
    }

    pub fn deliverRxPacket(
        self: *VirtioVsock,
        hdr: *const VirtioVsockHdr,
        payload: []const u8,
    ) bool {
        return queues_mod.deliverRxPacket(self, hdr, payload);
    }
};

test "VirtIO-vsock MMIO register discovery and feature negotiation" {
    const testing = std.testing;
    testing.refAllDecls(@This());
    _ = router_mod;
    _ = queues_mod;

    var vsock = VirtioVsock.init(2, null);

    try testing.expectEqual(VIRTIO_MAGIC, vsock.readReg(0x000));
    try testing.expectEqual(VIRTIO_VERSION, vsock.readReg(0x004));
    try testing.expectEqual(VIRTIO_ID_VSOCK, vsock.readReg(0x008));
    try testing.expectEqual(VIRTIO_VENDOR_ID, vsock.readReg(0x00c));

    try testing.expectEqual(@as(u32, 2), vsock.readReg(0x100)); // CID low.
    try testing.expectEqual(@as(u32, 0), vsock.readReg(0x104)); // CID high.

    vsock.writeReg(0x014, 1); // DeviceFeaturesSel = 1.
    try testing.expectEqual(@as(u32, 1), vsock.readReg(0x010));

    vsock.writeReg(0x070, 1 | 2 | 4 | 8);
    try testing.expectEqual(@as(u32, 15), vsock.readReg(0x070));

    vsock.writeReg(0x030, 0);
    try testing.expectEqual(QUEUE_SIZE_MAX, vsock.readReg(0x034));
    vsock.writeReg(0x044, 1);
    try testing.expectEqual(@as(u32, 1), vsock.readReg(0x044));
}
