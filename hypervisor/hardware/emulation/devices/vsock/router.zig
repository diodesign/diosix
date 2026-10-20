// VirtIO-vsock In-Hypervisor Packet Router & Wire Protocol Header
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const bus = @import("../bus.zig");
const vsock_mod = @import("../vsock.zig");
const VirtioVsock = vsock_mod.VirtioVsock;

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
    src_cid: u64 align(1),
    dst_cid: u64 align(1),
    src_port: u32 align(1),
    dst_port: u32 align(1),
    len: u32 align(1),
    type: u16 align(1),
    op: u16 align(1),
    flags: u32 align(1),
    buf_alloc: u32 align(1),
    fwd_cnt: u32 align(1),
};

comptime {
    std.debug.assert(@sizeOf(VirtioVsockHdr) == 44);
}

pub const TABLE_BUCKETS: usize = 32;

pub const VsockRouter = struct {
    /// Fast-path direct slots for standard system and early guest CIDs 0..31.
    static_slots: [TABLE_BUCKETS]?*VirtioVsock = @splat(null),

    /// Dynamic hash table buckets for arbitrary 64-bit CIDs (cid % 32).
    dynamic_buckets: [TABLE_BUCKETS]?*VirtioVsock = @splat(null),
    lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn unregisterLocked(self: *VsockRouter, cid: u64) void {
        const bucket = @as(usize, @truncate(cid % TABLE_BUCKETS));
        var curr = self.dynamic_buckets[bucket];
        var prev: ?*VirtioVsock = null;

        while (curr) |d| {
            if (d.guest_cid == cid) {
                if (prev) |p| {
                    p.router_next = d.router_next;
                } else {
                    self.dynamic_buckets[bucket] = d.router_next;
                }
                d.router_next = null;
                return;
            }
            prev = curr;
            curr = d.router_next;
        }
    }

    pub fn register(self: *VsockRouter, dev: *VirtioVsock) void {
        const cid = dev.guest_cid;
        if (cid < TABLE_BUCKETS) {
            self.static_slots[@as(usize, @truncate(cid))] = dev;
            return;
        }

        while (self.lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer self.lock.store(false, .release);

        const bucket = @as(usize, @truncate(cid % TABLE_BUCKETS));
        self.unregisterLocked(cid);

        dev.router_next = self.dynamic_buckets[bucket];
        self.dynamic_buckets[bucket] = dev;
    }

    pub fn unregister(self: *VsockRouter, cid: u64) void {
        if (cid < TABLE_BUCKETS) {
            self.static_slots[@as(usize, @truncate(cid))] = null;
            return;
        }

        while (self.lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer self.lock.store(false, .release);

        self.unregisterLocked(cid);
    }

    pub fn getDevice(self: *VsockRouter, cid: u64) ?*VirtioVsock {
        if (cid < TABLE_BUCKETS) {
            return self.static_slots[@as(usize, @truncate(cid))];
        }

        while (self.lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer self.lock.store(false, .release);

        const bucket = @as(usize, @truncate(cid % TABLE_BUCKETS));
        var curr = self.dynamic_buckets[bucket];
        while (curr) |d| {
            if (d.guest_cid == cid) {
                return d;
            }
            curr = d.router_next;
        }
        return null;
    }

    pub fn routePacket(
        self: *VsockRouter,
        src_dev: *VirtioVsock,
        hdr: *const VirtioVsockHdr,
        payload: []const u8,
    ) bool {
        const target = self.getDevice(hdr.dst_cid) orelse return false;
        // Security Shield: Prevent CID spoofing across virtual guests.
        var authentic_hdr = hdr.*;
        authentic_hdr.src_cid = src_dev.guest_cid;
        authentic_hdr.len = @truncate(payload.len);
        return target.deliverRxPacket(&authentic_hdr, payload);
    }

    pub fn reset(self: *VsockRouter) void {
        while (self.lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer self.lock.store(false, .release);

        self.static_slots = @splat(null);
        self.dynamic_buckets = @splat(null);
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

test "VirtIO-vsock router prevents CID spoofing" {
    const testing = std.testing;
    testing.refAllDecls(@This());

    const MOCK_RAM_BYTES: usize = 65536;
    const MockRam = struct {
        buffer: [MOCK_RAM_BYTES]u8 = @splat(0),

        fn read(ctx: *anyopaque, gpa: u64, buf: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const end = std.math.add(u64, gpa, buf.len) catch return false;
            if (end > self.buffer.len) return false;
            @memcpy(buf, self.buffer[@intCast(gpa)..@intCast(end)]);
            return true;
        }

        fn write(ctx: *anyopaque, gpa: u64, buf: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const end = std.math.add(u64, gpa, buf.len) catch return false;
            if (end > self.buffer.len) return false;
            @memcpy(self.buffer[@intCast(gpa)..@intCast(end)], buf);
            return true;
        }

        fn accessor(self: *@This()) MemoryAccessor {
            return .{
                .ctx = self,
                .readFn = read,
                .writeFn = write,
            };
        }
    };

    var ram_dest = MockRam{};
    const mem_dest = ram_dest.accessor();

    var sender = VirtioVsock.init(2, null);
    var receiver = VirtioVsock.init(3, mem_dest);

    receiver.queues[0].ready = true;
    receiver.queues[0].num = 16;
    receiver.queues[0].driver_gpa = 0x2000;
    receiver.queues[0].desc_gpa = 0x1000;
    receiver.queues[0].device_gpa = 0x3000;

    const avail_idx: u16 = 1;
    _ = mem_dest.write(0x2002, std.mem.asBytes(&avail_idx));
    const desc_head: u16 = 0;
    _ = mem_dest.write(0x2004, std.mem.asBytes(&desc_head));

    const rx_desc = bus.VirtqDesc{
        .addr = 0x4000,
        .len = 512,
        .flags = bus.VIRTQ_DESC_F_WRITE,
        .next = 0,
    };
    _ = mem_dest.write(0x1000, std.mem.asBytes(&rx_desc));

    const spoofed_hdr = VirtioVsockHdr{
        .src_cid = 999,
        .dst_cid = 3,
        .src_port = 1234,
        .dst_port = 5678,
        .len = 4,
        .type = VIRTIO_VSOCK_TYPE_STREAM,
        .op = VIRTIO_VSOCK_OP_RW,
        .flags = 0,
        .buf_alloc = 4096,
        .fwd_cnt = 0,
    };

    var router = VsockRouter{};
    router.register(&sender);
    router.register(&receiver);

    const delivered = router.routePacket(&sender, &spoofed_hdr, "TEST");
    try testing.expect(delivered);

    // Verify receiver received authentic sender CID 2, not spoofed 999.
    var received_hdr: VirtioVsockHdr = undefined;
    _ = mem_dest.read(0x4000, std.mem.asBytes(&received_hdr));
    try testing.expectEqual(@as(u64, 2), received_hdr.src_cid);

    // Test rejection of non-writable RX descriptor.
    const ro_desc = bus.VirtqDesc{
        .addr = 0x4000,
        .len = 512,
        .flags = 0, // No VIRTQ_DESC_F_WRITE.
        .next = 0,
    };
    _ = mem_dest.write(0x1000, std.mem.asBytes(&ro_desc));
    receiver.queues[0].last_avail_idx = 0;
    try testing.expect(!receiver.deliverRxPacket(&spoofed_hdr, "TEST"));

    // Test rejection of out-of-bounds 64-bit CID without aliasing.
    var high_cid_hdr = spoofed_hdr;
    high_cid_hdr.dst_cid = (@as(u64, 1) << 32) | 3;
    try testing.expect(!router.routePacket(&sender, &high_cid_hdr, "TEST"));

    // Test QueueNumMax invalid selector.
    sender.writeReg(bus.VIRTIO_MMIO_REG_QUEUE_SEL, 0);
    try testing.expectEqual(
        vsock_mod.QUEUE_SIZE_MAX,
        sender.readReg(bus.VIRTIO_MMIO_REG_QUEUE_NUM_MAX),
    );
    sender.writeReg(bus.VIRTIO_MMIO_REG_QUEUE_SEL, 5);
    try testing.expectEqual(
        @as(u32, 0),
        sender.readReg(bus.VIRTIO_MMIO_REG_QUEUE_NUM_MAX),
    );

    // Test high CID (>= 64) registration and routing.
    var mock_ram_high = MockRam{};
    const mem_high = mock_ram_high.accessor();
    var dev_high = VirtioVsock.init(64, mem_high);
    dev_high.queues[0].ready = true;
    dev_high.queues[0].num = 16;
    dev_high.queues[0].driver_gpa = 0x2000;
    dev_high.queues[0].desc_gpa = 0x1000;
    dev_high.queues[0].device_gpa = 0x3000;
    _ = mem_high.write(0x2002, std.mem.asBytes(&avail_idx));
    _ = mem_high.write(0x2004, std.mem.asBytes(&desc_head));
    _ = mem_high.write(0x1000, std.mem.asBytes(&rx_desc));

    router.register(&dev_high);
    try testing.expectEqual(&dev_high, router.getDevice(64));

    const high_dst_hdr = VirtioVsockHdr{
        .src_cid = 2,
        .dst_cid = 64,
        .src_port = 100,
        .dst_port = 200,
        .len = 100,
        .type = VIRTIO_VSOCK_TYPE_STREAM,
        .op = VIRTIO_VSOCK_OP_RW,
        .flags = 0,
        .buf_alloc = 4096,
        .fwd_cnt = 0,
    };
    const high_delivered = router.routePacket(&sender, &high_dst_hdr, "HELLO");
    try testing.expect(high_delivered);
    var delivered_hdr: VirtioVsockHdr = undefined;
    _ = mem_high.read(0x4000, std.mem.asBytes(&delivered_hdr));
    try testing.expectEqual(@as(u32, 5), delivered_hdr.len);
    try testing.expectEqual(@as(u64, 2), delivered_hdr.src_cid);
    try testing.expectEqual(@as(u64, 64), delivered_hdr.dst_cid);
}

test "VsockRouter dynamic hash table with 64-bit CIDs and collisions" {
    const testing = std.testing;
    testing.refAllDecls(@This());

    var router = VsockRouter{};

    // 1. Static slots (CIDs 0..31).
    var dev2 = VirtioVsock{ .guest_cid = 2 };
    var dev3 = VirtioVsock{ .guest_cid = 3 };
    router.register(&dev2);
    router.register(&dev3);

    try testing.expectEqual(&dev2, router.getDevice(2));
    try testing.expectEqual(&dev3, router.getDevice(3));
    try testing.expect(router.getDevice(4) == null);

    // 2. Dynamic high CIDs (CIDs >= 32).
    var dev1000 = VirtioVsock{ .guest_cid = 1000 };
    var dev_u32max = VirtioVsock{ .guest_cid = 4294967295 };
    var dev_high64 = VirtioVsock{ .guest_cid = (@as(u64, 1) << 40) | 123 };
    router.register(&dev1000);
    router.register(&dev_u32max);
    router.register(&dev_high64);

    try testing.expectEqual(&dev1000, router.getDevice(1000));
    try testing.expectEqual(&dev_u32max, router.getDevice(4294967295));
    try testing.expectEqual(
        &dev_high64,
        router.getDevice((@as(u64, 1) << 40) | 123),
    );

    // 3. Collision handling in dynamic buckets (38 % 32 == 70 % 32 == 6).
    var dev38 = VirtioVsock{ .guest_cid = 38 };
    var dev70 = VirtioVsock{ .guest_cid = 70 };
    router.register(&dev38);
    router.register(&dev70);

    try testing.expectEqual(&dev38, router.getDevice(38));
    try testing.expectEqual(&dev70, router.getDevice(70));

    // 4. Safe null on non-existent or max CIDs.
    try testing.expect(router.getDevice(0xffff_ffff_ffff_ffff) == null);
    try testing.expect(router.getDevice(99999) == null);

    // 5. Unregistration cleanly unlinks from dynamic bucket chain.
    router.unregister(38);
    try testing.expect(router.getDevice(38) == null);
    try testing.expectEqual(&dev70, router.getDevice(70));

    router.unregister(70);
    try testing.expect(router.getDevice(70) == null);
}
