// VirtIO-vsock (Virtual Sockets) Device Emulation
// Implements VirtIO 1.1 / 1.2 Device ID 19 (VIRTIO_ID_VSOCK) for AF_VSOCK
// networking.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const bus = @import("bus.zig");
const router_mod = @import("vsock/router.zig");

pub const VIRTIO_ID_VSOCK: u32 = 19;
pub const VIRTIO_VENDOR_ID: u32 = 0x554d4551; // "QEMU" / Standard VirtIO.
pub const VIRTIO_MAGIC: u32 = 0x74726976; // "virt".
pub const VIRTIO_VERSION: u32 = 2; // Non-legacy / Modern.

pub const QUEUE_SIZE_MAX: u16 = 128;
pub const NUM_QUEUES: usize = 3; // 0 = rx, 1 = tx, 2 = event.

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

    /// Initialize a `VirtioVsock` instance by value.
    /// Note: Call `router.register(&vsock)` on the pinned destination struct
    /// rather than registering a temporary stack address here.
    pub fn init(cid: u64, mem: ?MemoryAccessor) VirtioVsock {
        return .{
            .guest_cid = cid,
            .mem = mem,
        };
    }

    pub fn readReg(self: *VirtioVsock, offset: u32) u32 {
        const q_valid = self.queue_sel < NUM_QUEUES;
        const feat_v1: u32 = if (self.device_features_sel == 1) 1 else 0;
        return switch (offset) {
            bus.VIRTIO_MMIO_REG_MAGIC_VALUE => VIRTIO_MAGIC,
            bus.VIRTIO_MMIO_REG_VERSION => VIRTIO_VERSION,
            bus.VIRTIO_MMIO_REG_DEVICE_ID => VIRTIO_ID_VSOCK,
            bus.VIRTIO_MMIO_REG_VENDOR_ID => VIRTIO_VENDOR_ID,
            bus.VIRTIO_MMIO_REG_DEVICE_FEATURES => feat_v1,
            bus.VIRTIO_MMIO_REG_QUEUE_NUM_MAX => if (q_valid)
                QUEUE_SIZE_MAX
            else
                0,
            bus.VIRTIO_MMIO_REG_QUEUE_READY => if (q_valid and
                self.queues[self.queue_sel].ready)
                1
            else
                0,
            bus.VIRTIO_MMIO_REG_INTERRUPT_STATUS => @atomicLoad(
                u32,
                &self.interrupt_status,
                .seq_cst,
            ),
            bus.VIRTIO_MMIO_REG_STATUS => self.status,
            0x0fc, bus.VIRTIO_MMIO_REG_CONFIG_BASE => @truncate(self.guest_cid),
            bus.VIRTIO_MMIO_REG_CONFIG_BASE + 4 => @truncate(
                self.guest_cid >> 32,
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
                if (val == 1) self.processTx();
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
                    for (&self.queues) |*q| q.* = .{};
                    @atomicStore(u32, &self.interrupt_status, 0, .seq_cst);
                }
            },
            else => {},
        }
    }

    pub fn processTx(self: *VirtioVsock) void {
        const mem = self.mem orelse return;
        var tx_q = &self.queues[1];
        if (!tx_q.ready or tx_q.num == 0 or
            tx_q.driver_gpa == 0 or tx_q.device_gpa == 0)
        {
            return;
        }

        var avail_idx: u16 = 0;
        if (!mem.read(tx_q.driver_gpa +% 2, std.mem.asBytes(&avail_idx))) {
            return;
        }

        var processed_count: u16 = 0;
        while (tx_q.last_avail_idx != avail_idx and
            processed_count < tx_q.num) : (processed_count += 1)
        {
            const ring_slot = tx_q.last_avail_idx % tx_q.num;
            var desc_head_idx: u16 = 0;
            const ring_entry_offset = 4 +% (@as(u64, ring_slot) *% 2);
            if (!mem.read(
                tx_q.driver_gpa +% ring_entry_offset,
                std.mem.asBytes(&desc_head_idx),
            )) break;

            if (desc_head_idx >= tx_q.num) break;

            var desc: VirtqDesc = undefined;
            const desc_offset = @as(u64, desc_head_idx) *% @sizeOf(VirtqDesc);
            const desc_addr = tx_q.desc_gpa +% desc_offset;
            if (!mem.read(desc_addr, std.mem.asBytes(&desc))) break;

            if (desc.len >= @sizeOf(VirtioVsockHdr)) {
                var hdr: VirtioVsockHdr = undefined;
                if (mem.read(desc.addr, std.mem.asBytes(&hdr))) {
                    var payload_buf: [4096]u8 = undefined;
                    var payload_slice: []const u8 = &.{};
                    const payload_len = @min(hdr.len, payload_buf.len);

                    if (payload_len > 0) {
                        if (desc.len > @sizeOf(VirtioVsockHdr)) {
                            const avail_in_desc = @min(
                                payload_len,
                                desc.len - @sizeOf(VirtioVsockHdr),
                            );
                            const pay_gpa =
                                desc.addr +% @sizeOf(VirtioVsockHdr);
                            if (mem.read(
                                pay_gpa,
                                payload_buf[0..avail_in_desc],
                            )) {
                                payload_slice = payload_buf[0..avail_in_desc];
                            }
                        } else if ((desc.flags & VIRTQ_DESC_F_NEXT) != 0 and
                            desc.next < tx_q.num)
                        {
                            var next_desc: VirtqDesc = undefined;
                            const next_off =
                                @as(u64, desc.next) *% @sizeOf(VirtqDesc);
                            const next_addr = tx_q.desc_gpa +% next_off;
                            if (mem.read(
                                next_addr,
                                std.mem.asBytes(&next_desc),
                            )) {
                                const copy_len =
                                    @min(payload_len, next_desc.len);
                                if (mem.read(
                                    next_desc.addr,
                                    payload_buf[0..copy_len],
                                )) {
                                    payload_slice = payload_buf[0..copy_len];
                                }
                            }
                        }
                    }

                    if (self.router) |r| {
                        _ = r.routePacket(self, &hdr, payload_slice);
                    }
                }
            }

            const used_slot = tx_q.last_used_idx % tx_q.num;
            const used_elem = VirtqUsedElem{
                .id = desc_head_idx,
                .len = 0,
            };
            const elem_size = @sizeOf(VirtqUsedElem);
            const used_off = 4 +% (@as(u64, used_slot) *% elem_size);
            const used_addr = tx_q.device_gpa +% used_off;
            _ = mem.write(used_addr, std.mem.asBytes(&used_elem));

            tx_q.last_used_idx +%= 1;
            _ = mem.write(
                tx_q.device_gpa +% 2,
                std.mem.asBytes(&tx_q.last_used_idx),
            );

            tx_q.last_avail_idx +%= 1;
        }

        _ = @atomicRmw(u32, &self.interrupt_status, .Or, 1, .seq_cst);
    }

    pub fn deliverRxPacket(
        self: *VirtioVsock,
        hdr: *const VirtioVsockHdr,
        payload: []const u8,
    ) bool {
        while (self.rx_lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer self.rx_lock.store(false, .release);

        const mem = self.mem orelse return false;
        var rx_q = &self.queues[0];
        if (!rx_q.ready or rx_q.num == 0 or
            rx_q.driver_gpa == 0 or rx_q.device_gpa == 0)
        {
            return false;
        }

        var avail_idx: u16 = 0;
        if (!mem.read(rx_q.driver_gpa +% 2, std.mem.asBytes(&avail_idx))) {
            return false;
        }
        if (rx_q.last_avail_idx == avail_idx) return false;

        const ring_slot = rx_q.last_avail_idx % rx_q.num;
        var desc_head_idx: u16 = 0;
        const ring_entry_offset = 4 +% (@as(u64, ring_slot) *% 2);
        if (!mem.read(
            rx_q.driver_gpa +% ring_entry_offset,
            std.mem.asBytes(&desc_head_idx),
        )) return false;

        if (desc_head_idx >= rx_q.num) return false;

        var desc: VirtqDesc = undefined;
        const desc_offset = @as(u64, desc_head_idx) *% @sizeOf(VirtqDesc);
        const desc_addr = rx_q.desc_gpa +% desc_offset;
        if (!mem.read(desc_addr, std.mem.asBytes(&desc))) return false;

        if (desc.len < @sizeOf(VirtioVsockHdr)) return false;
        if ((desc.flags & VIRTQ_DESC_F_WRITE) == 0) return false;

        var rx_hdr = hdr.*;
        var payload_written: u32 = 0;

        if (payload.len > 0) {
            const needed_len = std.math.add(
                usize,
                @sizeOf(VirtioVsockHdr),
                payload.len,
            ) catch std.math.maxInt(usize);
            if (desc.len >= needed_len) {
                if (mem.write(desc.addr +% @sizeOf(VirtioVsockHdr), payload)) {
                    payload_written = @truncate(payload.len);
                }
            } else if ((desc.flags & VIRTQ_DESC_F_NEXT) != 0 and
                desc.next < rx_q.num)
            {
                var next_desc: VirtqDesc = undefined;
                const next_off = @as(u64, desc.next) *% @sizeOf(VirtqDesc);
                const next_addr = rx_q.desc_gpa +% next_off;
                if (mem.read(next_addr, std.mem.asBytes(&next_desc))) {
                    if ((next_desc.flags & VIRTQ_DESC_F_WRITE) != 0) {
                        const copy_len = @min(payload.len, next_desc.len);
                        if (mem.write(next_desc.addr, payload[0..copy_len])) {
                            payload_written = @truncate(copy_len);
                        }
                    }
                }
            }
        }

        rx_hdr.len = payload_written;
        if (!mem.write(desc.addr, std.mem.asBytes(&rx_hdr))) return false;

        const total_written: u32 = @sizeOf(VirtioVsockHdr) + payload_written;

        const used_slot = rx_q.last_used_idx % rx_q.num;
        const used_elem = VirtqUsedElem{
            .id = desc_head_idx,
            .len = total_written,
        };
        const used_off = 4 +% (@as(u64, used_slot) *% @sizeOf(VirtqUsedElem));
        const used_addr = rx_q.device_gpa +% used_off;
        _ = mem.write(used_addr, std.mem.asBytes(&used_elem));

        rx_q.last_used_idx +%= 1;
        _ = mem.write(
            rx_q.device_gpa +% 2,
            std.mem.asBytes(&rx_q.last_used_idx),
        );
        rx_q.last_avail_idx +%= 1;

        _ = @atomicRmw(u32, &self.interrupt_status, .Or, 1, .seq_cst);
        return true;
    }
};

test "VirtIO-vsock MMIO register discovery and feature negotiation" {
    const testing = std.testing;
    _ = router_mod;

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

test "VirtIO-vsock inter-VM packet routing between Root VM and Guest VM" {
    const testing = std.testing;

    var router = VsockRouter{};
    var ram1 = router_mod.MockRam{};
    var ram2 = router_mod.MockRam{};

    const mem1 = ram1.accessor();
    const mem2 = ram2.accessor();

    var root_vsock = VirtioVsock{
        .guest_cid = 1,
        .mem = mem1,
        .router = &router,
    };
    var guest_vsock = VirtioVsock{
        .guest_cid = 2,
        .mem = mem2,
        .router = &router,
    };

    router.register(&root_vsock);
    router.register(&guest_vsock);

    guest_vsock.queues[0] = .{
        .ready = true,
        .desc_gpa = 0x1000,
        .driver_gpa = 0x2000,
        .device_gpa = 0x3000,
        .last_avail_idx = 0,
        .last_used_idx = 0,
    };

    const rx_desc = VirtqDesc{
        .addr = 0x4000,
        .len = 2048,
        .flags = VIRTQ_DESC_F_WRITE,
        .next = 0,
    };
    _ = mem2.write(0x1000, std.mem.asBytes(&rx_desc));

    const rx_desc_head: u16 = 0;
    _ = mem2.write(0x2004, std.mem.asBytes(&rx_desc_head));
    const avail_idx: u16 = 1;
    _ = mem2.write(0x2002, std.mem.asBytes(&avail_idx));

    const tx_hdr = VirtioVsockHdr{
        .src_cid = 1,
        .dst_cid = 2,
        .src_port = 1024,
        .dst_port = 22,
        .len = 5,
        .type = VIRTIO_VSOCK_TYPE_STREAM,
        .op = VIRTIO_VSOCK_OP_RW,
        .flags = 0,
        .buf_alloc = 65536,
        .fwd_cnt = 0,
    };

    const routed = router.routePacket(&root_vsock, &tx_hdr, "HELLO");
    try testing.expect(routed);

    var received_hdr: VirtioVsockHdr = undefined;
    _ = mem2.read(0x4000, std.mem.asBytes(&received_hdr));
    try testing.expectEqual(@as(u64, 1), received_hdr.src_cid);
    try testing.expectEqual(@as(u64, 2), received_hdr.dst_cid);
    try testing.expectEqual(@as(u32, 1024), received_hdr.src_port);
    try testing.expectEqual(@as(u32, 22), received_hdr.dst_port);
    try testing.expectEqual(VIRTIO_VSOCK_OP_RW, received_hdr.op);

    var received_payload: [5]u8 = undefined;
    _ = mem2.read(0x4000 + @sizeOf(VirtioVsockHdr), &received_payload);
    try testing.expectEqualStrings("HELLO", &received_payload);
    try testing.expect(guest_vsock.interrupt_status & 1 != 0);
}

test "VirtIO-vsock safety against zero queue size and OOB descriptor heads" {
    const testing = std.testing;

    var ram = router_mod.MockRam{};
    const mem = ram.accessor();
    var vsock = VirtioVsock.init(3, mem);

    // 1. Malicious guest attempts to configure queue size = 0.
    vsock.writeReg(0x030, 1);
    vsock.writeReg(0x038, 0);
    try testing.expect(vsock.queues[1].num > 0);

    // 2. Queue notify on unconfigured queue must not divide by zero.
    vsock.queues[1].num = 0;
    vsock.queues[1].ready = true;
    vsock.processTx();

    // 3. Out-of-bounds descriptor head index must not read OOB.
    vsock.queues[1].num = 16;
    vsock.queues[1].driver_gpa = 0x2000;
    vsock.queues[1].desc_gpa = 0x1000;
    vsock.queues[1].device_gpa = 0x3000;
    vsock.queues[1].last_avail_idx = 0;

    const bad_avail_idx: u16 = 1;
    _ = mem.write(0x2002, std.mem.asBytes(&bad_avail_idx));
    const bad_desc_head: u16 = 999;
    _ = mem.write(0x2004, std.mem.asBytes(&bad_desc_head));

    vsock.processTx();
    try testing.expectEqual(@as(u16, 0), vsock.queues[1].last_used_idx);
}
