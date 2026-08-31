// VirtIO-vsock (Virtual Sockets) Device Emulation and In-Hypervisor Packet Router
// Implements VirtIO 1.1 / 1.2 Device ID 19 (VIRTIO_ID_VSOCK) for AF_VSOCK networking.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const VIRTIO_ID_VSOCK: u32 = 19;
pub const VIRTIO_VENDOR_ID: u32 = 0x554d4551; // "QEMU" / Standard VirtIO
pub const VIRTIO_MAGIC: u32 = 0x74726976; // "virt"
pub const VIRTIO_VERSION: u32 = 2; // Non-legacy / Modern

pub const QUEUE_SIZE_MAX: u16 = 128;
pub const NUM_QUEUES: usize = 3; // 0 = rx, 1 = tx, 2 = event

pub const VIRTIO_VSOCK_TYPE_STREAM: u16 = 1;
pub const VIRTIO_VSOCK_TYPE_SEQPACKET: u16 = 2;

pub const VIRTIO_VSOCK_OP_INVALID: u16 = 0;
pub const VIRTIO_VSOCK_OP_REQUEST: u16 = 1;
pub const VIRTIO_VSOCK_OP_RESPONSE: u16 = 2;
pub const VIRTIO_VSOCK_OP_RST: u16 = 3;
pub const VIRTIO_VSOCK_OP_SHUTDOWN: u16 = 4;
pub const VIRTIO_VSOCK_OP_RW: u16 = 5;
pub const VIRTIO_VSOCK_OP_CREDIT_UPDATE: u16 = 6;
pub const VIRTIO_VSOCK_OP_CREDIT_REQUEST: u16 = 7;

pub const VirtioVsockHdr = extern struct {
    src_cid: u64,
    dst_cid: u64,
    src_port: u32,
    dst_port: u32,
    len: u32,
    type: u16,
    op: u16,
    flags: u32,
    buf_alloc: u32,
    fwd_cnt: u32,
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

pub const MAX_VSOCK_DEVICES: usize = 64;

pub const VsockRouter = struct {
    devices: [MAX_VSOCK_DEVICES]?*VirtioVsock = @splat(null),

    pub fn register(self: *VsockRouter, dev: *VirtioVsock) void {
        const cid = dev.guest_cid;
        if (cid < MAX_VSOCK_DEVICES) {
            self.devices[cid] = dev;
        }
    }

    pub fn unregister(self: *VsockRouter, cid: usize) void {
        if (cid < MAX_VSOCK_DEVICES) {
            self.devices[cid] = null;
        }
    }

    pub fn getDevice(self: *VsockRouter, cid: usize) ?*VirtioVsock {
        if (cid < MAX_VSOCK_DEVICES) {
            return self.devices[cid];
        }
        return null;
    }

    pub fn routePacket(self: *VsockRouter, src_dev: *VirtioVsock, hdr: *const VirtioVsockHdr, payload: []const u8) bool {
        _ = src_dev;
        const target = self.getDevice(@truncate(hdr.dst_cid)) orelse return false;
        return target.deliverRxPacket(hdr, payload);
    }
};

pub var global_vsock_router: VsockRouter = .{};

pub const MemoryAccessor = struct {
    ctx: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, gpa: u64, buf: []u8) bool,
    writeFn: *const fn (ctx: *anyopaque, gpa: u64, buf: []const u8) bool,

    pub fn read(self: MemoryAccessor, gpa: u64, buf: []u8) bool {
        return self.readFn(self.ctx, gpa, buf);
    }

    pub fn write(self: MemoryAccessor, gpa: u64, buf: []const u8) bool {
        return self.writeFn(self.ctx, gpa, buf);
    }
};

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
    router: ?*VsockRouter = &global_vsock_router,

    pub fn init(cid: u64, mem: ?MemoryAccessor) VirtioVsock {
        var dev = VirtioVsock{
            .guest_cid = cid,
            .mem = mem,
        };
        if (dev.router) |r| {
            r.register(&dev);
        }
        return dev;
    }

    pub fn readReg(self: *VirtioVsock, offset: u32) u32 {
        return switch (offset) {
            0x000 => VIRTIO_MAGIC,
            0x004 => VIRTIO_VERSION,
            0x008 => VIRTIO_ID_VSOCK,
            0x00c => VIRTIO_VENDOR_ID,
            0x010 => blk: {
                if (self.device_features_sel == 0) {
                    // Feature bits 0..31
                    break :blk 0;
                } else if (self.device_features_sel == 1) {
                    // VIRTIO_F_VERSION_1 (bit 32 -> bit 0 of sel 1)
                    break :blk (1 << 0);
                }
                break :blk 0;
            },
            0x034 => QUEUE_SIZE_MAX,
            0x044 => if (self.queue_sel < NUM_QUEUES) (if (self.queues[self.queue_sel].ready) 1 else 0) else 0,
            0x060 => self.interrupt_status,
            0x070 => self.status,
            0x0fc, 0x100 => @truncate(self.guest_cid),
            0x104 => @truncate(self.guest_cid >> 32),
            else => 0,
        };
    }

    pub fn writeReg(self: *VirtioVsock, offset: u32, val: u32) void {
        switch (offset) {
            0x014 => self.device_features_sel = val,
            0x020 => {
                if (self.driver_features_sel == 0) {
                    self.driver_features = (self.driver_features & 0xFFFFFFFF00000000) | val;
                } else if (self.driver_features_sel == 1) {
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
                // Queue Notify doorbell from driver
                const q_idx = val;
                if (q_idx == 1) {
                    self.processTx();
                }
            },
            0x064 => {
                // Interrupt ACK
                self.interrupt_status &= ~val;
            },
            0x070 => {
                self.status = val;
                if (val == 0) {
                    // Device Reset
                    for (&self.queues) |*q| {
                        q.* = .{};
                    }
                    self.interrupt_status = 0;
                }
            },
            0x080 => {
                if (self.queue_sel < NUM_QUEUES) {
                    self.queues[self.queue_sel].desc_gpa = (self.queues[self.queue_sel].desc_gpa & 0xFFFFFFFF00000000) | val;
                }
            },
            0x084 => {
                if (self.queue_sel < NUM_QUEUES) {
                    self.queues[self.queue_sel].desc_gpa = (self.queues[self.queue_sel].desc_gpa & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
                }
            },
            0x090 => {
                if (self.queue_sel < NUM_QUEUES) {
                    self.queues[self.queue_sel].driver_gpa = (self.queues[self.queue_sel].driver_gpa & 0xFFFFFFFF00000000) | val;
                }
            },
            0x094 => {
                if (self.queue_sel < NUM_QUEUES) {
                    self.queues[self.queue_sel].driver_gpa = (self.queues[self.queue_sel].driver_gpa & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
                }
            },
            0x0a0 => {
                if (self.queue_sel < NUM_QUEUES) {
                    self.queues[self.queue_sel].device_gpa = (self.queues[self.queue_sel].device_gpa & 0xFFFFFFFF00000000) | val;
                }
            },
            0x0a4 => {
                if (self.queue_sel < NUM_QUEUES) {
                    self.queues[self.queue_sel].device_gpa = (self.queues[self.queue_sel].device_gpa & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
                }
            },
            else => {},
        }
    }

    pub fn processTx(self: *VirtioVsock) void {
        const mem = self.mem orelse return;
        var tx_q = &self.queues[1];
        if (!tx_q.ready or tx_q.driver_gpa == 0 or tx_q.device_gpa == 0) return;

        // Read available index from Avail Ring
        var avail_idx: u16 = 0;
        if (!mem.read(tx_q.driver_gpa + 2, std.mem.asBytes(&avail_idx))) return;

        while (tx_q.last_avail_idx != avail_idx) {
            const ring_slot = tx_q.last_avail_idx % tx_q.num;
            var desc_head_idx: u16 = 0;
            if (!mem.read(tx_q.driver_gpa + 4 + (@as(u64, ring_slot) * 2), std.mem.asBytes(&desc_head_idx))) break;

            // Read descriptor
            var desc: VirtqDesc = undefined;
            const desc_addr = tx_q.desc_gpa + (@as(u64, desc_head_idx) * @sizeOf(VirtqDesc));
            if (!mem.read(desc_addr, std.mem.asBytes(&desc))) break;

            if (desc.len >= @sizeOf(VirtioVsockHdr)) {
                var hdr: VirtioVsockHdr = undefined;
                if (mem.read(desc.addr, std.mem.asBytes(&hdr))) {
                    var payload_buf: [4096]u8 = undefined;
                    var payload_slice: []const u8 = &.{};
                    const payload_len = @min(hdr.len, payload_buf.len);

                    if (payload_len > 0) {
                        if (desc.len > @sizeOf(VirtioVsockHdr)) {
                            const available_in_desc = @min(payload_len, desc.len - @sizeOf(VirtioVsockHdr));
                            if (mem.read(desc.addr + @sizeOf(VirtioVsockHdr), payload_buf[0..available_in_desc])) {
                                payload_slice = payload_buf[0..available_in_desc];
                            }
                        } else if ((desc.flags & VIRTQ_DESC_F_NEXT) != 0) {
                            var next_desc: VirtqDesc = undefined;
                            const next_desc_addr = tx_q.desc_gpa + (@as(u64, desc.next) * @sizeOf(VirtqDesc));
                            if (mem.read(next_desc_addr, std.mem.asBytes(&next_desc))) {
                                const copy_len = @min(payload_len, next_desc.len);
                                if (mem.read(next_desc.addr, payload_buf[0..copy_len])) {
                                    payload_slice = payload_buf[0..copy_len];
                                }
                            }
                        }
                    }

                    // Route packet via the central Vsock Router
                    if (self.router) |r| {
                        _ = r.routePacket(self, &hdr, payload_slice);
                    }
                }
            }

            // Put descriptor into Used ring
            const used_slot = tx_q.last_used_idx % tx_q.num;
            const used_elem = VirtqUsedElem{
                .id = desc_head_idx,
                .len = 0,
            };
            const used_elem_addr = tx_q.device_gpa + 4 + (@as(u64, used_slot) * @sizeOf(VirtqUsedElem));
            _ = mem.write(used_elem_addr, std.mem.asBytes(&used_elem));

            tx_q.last_used_idx +%= 1;
            _ = mem.write(tx_q.device_gpa + 2, std.mem.asBytes(&tx_q.last_used_idx));

            tx_q.last_avail_idx +%= 1;
        }

        // Set interrupt for used buffer notification
        self.interrupt_status |= 1;
    }

    pub fn deliverRxPacket(self: *VirtioVsock, hdr: *const VirtioVsockHdr, payload: []const u8) bool {
        const mem = self.mem orelse return false;
        var rx_q = &self.queues[0];
        if (!rx_q.ready or rx_q.driver_gpa == 0 or rx_q.device_gpa == 0) return false;

        // Read available index
        var avail_idx: u16 = 0;
        if (!mem.read(rx_q.driver_gpa + 2, std.mem.asBytes(&avail_idx))) return false;
        if (rx_q.last_avail_idx == avail_idx) return false; // No RX buffers available

        const ring_slot = rx_q.last_avail_idx % rx_q.num;
        var desc_head_idx: u16 = 0;
        if (!mem.read(rx_q.driver_gpa + 4 + (@as(u64, ring_slot) * 2), std.mem.asBytes(&desc_head_idx))) return false;

        var desc: VirtqDesc = undefined;
        const desc_addr = rx_q.desc_gpa + (@as(u64, desc_head_idx) * @sizeOf(VirtqDesc));
        if (!mem.read(desc_addr, std.mem.asBytes(&desc))) return false;

        if (desc.len < @sizeOf(VirtioVsockHdr)) return false;

        // Write header to RX buffer
        if (!mem.write(desc.addr, std.mem.asBytes(hdr))) return false;

        var total_written: u32 = @sizeOf(VirtioVsockHdr);

        if (payload.len > 0) {
            if (desc.len >= @sizeOf(VirtioVsockHdr) + payload.len) {
                if (mem.write(desc.addr + @sizeOf(VirtioVsockHdr), payload)) {
                    total_written += @truncate(payload.len);
                }
            } else if ((desc.flags & VIRTQ_DESC_F_NEXT) != 0) {
                var next_desc: VirtqDesc = undefined;
                const next_desc_addr = rx_q.desc_gpa + (@as(u64, desc.next) * @sizeOf(VirtqDesc));
                if (mem.read(next_desc_addr, std.mem.asBytes(&next_desc))) {
                    const copy_len = @min(payload.len, next_desc.len);
                    if (mem.write(next_desc.addr, payload[0..copy_len])) {
                        total_written += @truncate(copy_len);
                    }
                }
            }
        }

        // Put into Used ring
        const used_slot = rx_q.last_used_idx % rx_q.num;
        const used_elem = VirtqUsedElem{
            .id = desc_head_idx,
            .len = total_written,
        };
        const used_elem_addr = rx_q.device_gpa + 4 + (@as(u64, used_slot) * @sizeOf(VirtqUsedElem));
        _ = mem.write(used_elem_addr, std.mem.asBytes(&used_elem));

        rx_q.last_used_idx +%= 1;
        _ = mem.write(rx_q.device_gpa + 2, std.mem.asBytes(&rx_q.last_used_idx));
        rx_q.last_avail_idx +%= 1;

        // Raise interrupt
        self.interrupt_status |= 1;
        return true;
    }
};

test "VirtIO-vsock MMIO register discovery and feature negotiation" {
    const testing = std.testing;

    var vsock = VirtioVsock.init(2, null);

    // Verify MMIO Identification Registers
    try testing.expectEqual(VIRTIO_MAGIC, vsock.readReg(0x000));
    try testing.expectEqual(VIRTIO_VERSION, vsock.readReg(0x004));
    try testing.expectEqual(VIRTIO_ID_VSOCK, vsock.readReg(0x008));
    try testing.expectEqual(VIRTIO_VENDOR_ID, vsock.readReg(0x00c));

    // Verify Guest CID reporting
    try testing.expectEqual(@as(u32, 2), vsock.readReg(0x100)); // CID low
    try testing.expectEqual(@as(u32, 0), vsock.readReg(0x104)); // CID high

    // Feature Negotiation
    vsock.writeReg(0x014, 1); // DeviceFeaturesSel = 1
    try testing.expectEqual(@as(u32, 1), vsock.readReg(0x010)); // VIRTIO_F_VERSION_1

    // Status handshakes
    vsock.writeReg(0x070, 1 | 2 | 4 | 8); // ACKNOWLEDGE | DRIVER | DRIVER_OK | FEATURES_OK
    try testing.expectEqual(@as(u32, 15), vsock.readReg(0x070));

    // Queue selection and configuration
    vsock.writeReg(0x030, 0); // Select RX queue
    try testing.expectEqual(QUEUE_SIZE_MAX, vsock.readReg(0x034));
    vsock.writeReg(0x044, 1); // Set ready
    try testing.expectEqual(@as(u32, 1), vsock.readReg(0x044));
}

const MockRam = struct {
    buffer: [65536]u8 = @splat(0),

    pub fn read(ctx: *anyopaque, gpa: u64, buf: []u8) bool {
        const self: *MockRam = @ptrCast(@alignCast(ctx));
        if (gpa + buf.len > self.buffer.len) return false;
        @memcpy(buf, self.buffer[@intCast(gpa)..@intCast(gpa + buf.len)]);
        return true;
    }

    pub fn write(ctx: *anyopaque, gpa: u64, buf: []const u8) bool {
        const self: *MockRam = @ptrCast(@alignCast(ctx));
        if (gpa + buf.len > self.buffer.len) return false;
        @memcpy(self.buffer[@intCast(gpa)..@intCast(gpa + buf.len)], buf);
        return true;
    }
};

test "VirtIO-vsock inter-VM packet routing between Root VM and Guest VM" {
    const testing = std.testing;

    var router = VsockRouter{};

    var ram1 = MockRam{};
    var ram2 = MockRam{};

    const mem1 = MemoryAccessor{
        .ctx = &ram1,
        .readFn = MockRam.read,
        .writeFn = MockRam.write,
    };
    const mem2 = MemoryAccessor{
        .ctx = &ram2,
        .readFn = MockRam.read,
        .writeFn = MockRam.write,
    };

    var root_vsock = VirtioVsock{ .guest_cid = 1, .mem = mem1, .router = &router };
    var guest_vsock = VirtioVsock{ .guest_cid = 2, .mem = mem2, .router = &router };

    router.register(&root_vsock);
    router.register(&guest_vsock);

    // Set up Guest VM (CID 2) RX Queue (Queue 0)
    guest_vsock.queues[0] = .{
        .ready = true,
        .desc_gpa = 0x1000,
        .driver_gpa = 0x2000,
        .device_gpa = 0x3000,
        .last_avail_idx = 0,
        .last_used_idx = 0,
    };

    // Configure 1 RX descriptor in Guest VM RAM
    const rx_desc = VirtqDesc{
        .addr = 0x4000,
        .len = 2048,
        .flags = VIRTQ_DESC_F_WRITE,
        .next = 0,
    };
    _ = mem2.write(0x1000, std.mem.asBytes(&rx_desc));

    // Put descriptor 0 into Guest VM Avail ring with avail_idx = 1
    const rx_desc_head: u16 = 0;
    _ = mem2.write(0x2004, std.mem.asBytes(&rx_desc_head));
    const avail_idx: u16 = 1;
    _ = mem2.write(0x2002, std.mem.asBytes(&avail_idx));

    // Root VM (CID 1) transmits a packet to Guest VM (CID 2)
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
    const test_payload = "HELLO";

    const routed = router.routePacket(&root_vsock, &tx_hdr, test_payload);
    try testing.expect(routed);

    // Verify Guest VM received the packet in its RX buffer (0x4000)
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

    // Verify Guest VM received interrupt
    try testing.expect(guest_vsock.interrupt_status & 1 != 0);
}
