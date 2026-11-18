// VirtIO-net (Virtual Network Device) Emulation
// Implements VirtIO 1.1 / 1.2 Device ID 1 (VIRTIO_ID_NET) for standard
// Ethernet frame RX/TX bridged to the hypervisor's L2 virtual switch.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const bus = @import("bus.zig");
const vsock_mod = @import("vsock.zig");
const MemoryAccessor = vsock_mod.MemoryAccessor;
const VirtqDesc = bus.VirtqDesc;
const VirtqUsedElem = bus.VirtqUsedElem;

pub const VIRTIO_ID_NET: u32 = 1;
pub const VIRTIO_VENDOR_ID: u32 = bus.VIRTIO_MMIO_VENDOR_QEMU;
pub const VIRTIO_MAGIC: u32 = bus.VIRTIO_MMIO_MAGIC;
pub const VIRTIO_VERSION: u32 = bus.VIRTIO_MMIO_VERSION_2;

pub const QUEUE_SIZE_MAX: u16 = 128;
pub const NUM_QUEUES: usize = 2; // 0 = rx, 1 = tx.
pub const QUEUE_INDEX_RX: usize = 0;
pub const QUEUE_INDEX_TX: usize = 1;

pub const VIRTIO_NET_F_MAC: u32 = 1 << 5;
pub const VIRTIO_NET_F_STATUS: u32 = 1 << 16;
pub const VIRTIO_NET_S_LINK_UP: u16 = 1;

pub const VIRTIO_NET_HDR_SIZE: usize = 12;
pub const LEGACY_NET_HDR_SIZE: usize = 10;
pub const MAX_ETH_FRAME_BYTES: usize = 1536;
pub const CONFIG_SPACE_BYTES: u32 = 8;

/// Locally administered Diosix OUI prefix `02:00:00:00:<cid_hi>:<cid_lo>`.
pub const DEFAULT_MAC_PREFIX = [4]u8{ 0x02, 0x00, 0x00, 0x00 };

pub const VirtioNetHdr = extern struct {
    flags: u8 = 0,
    gso_type: u8 = 0,
    hdr_len: u16 align(1) = 0,
    gso_size: u16 align(1) = 0,
    csum_start: u16 align(1) = 0,
    csum_offset: u16 align(1) = 0,
    num_buffers: u16 align(1) = 1,
};

comptime {
    std.debug.assert(@sizeOf(VirtioNetHdr) == VIRTIO_NET_HDR_SIZE);
}

pub const VirtQueue = bus.VirtQueueConfig(QUEUE_SIZE_MAX);

pub const VirtioNet = struct {
    guest_cid: u64 = 1,
    mac: [6]u8 = .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 },
    status: u32 = 0,
    device_features_sel: u32 = 0,
    driver_features_sel: u32 = 0,
    driver_features: u64 = 0,
    queue_sel: u32 = 0,
    interrupt_status: u32 = 0,
    queues: [NUM_QUEUES]VirtQueue = @splat(.{}),
    mem: ?MemoryAccessor = null,
    tx_ctx: ?*anyopaque = null,
    tx_fn: ?*const fn (ctx: *anyopaque, frame: []const u8) void = null,
    rx_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    tx_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(cid: u64, mem: ?MemoryAccessor) VirtioNet {
        var mac: [6]u8 = undefined;
        @memcpy(mac[0..4], &DEFAULT_MAC_PREFIX);
        mac[4] = @truncate(cid >> 8);
        mac[5] = @truncate(cid);
        return .{
            .guest_cid = cid,
            .mac = mac,
            .mem = mem,
        };
    }

    pub fn isRxReady(self: *const VirtioNet) bool {
        const rx_q = &self.queues[QUEUE_INDEX_RX];
        return rx_q.ready and rx_q.num > 0 and
            rx_q.driver_gpa != 0 and rx_q.device_gpa != 0;
    }

    pub fn readReg(self: *VirtioNet, offset: u32) u32 {
        if (offset == bus.VIRTIO_MMIO_REG_DEVICE_FEATURES) {
            if (self.device_features_sel == 0) {
                return VIRTIO_NET_F_MAC | VIRTIO_NET_F_STATUS;
            }
            if (self.device_features_sel == bus.VIRTIO_F_VERSION_1_SEL) {
                return bus.VIRTIO_F_VERSION_1_BIT;
            }
            return 0;
        }

        const irq = @atomicLoad(u32, &self.interrupt_status, .seq_cst);
        if (bus.readVirtioCommon(
            self,
            VIRTIO_ID_NET,
            NUM_QUEUES,
            QUEUE_SIZE_MAX,
            irq,
            offset,
        )) |common| return common;

        if (offset >= bus.VIRTIO_MMIO_REG_CONFIG_BASE and
            offset < bus.VIRTIO_MMIO_REG_CONFIG_BASE + CONFIG_SPACE_BYTES)
        {
            var cfg: [CONFIG_SPACE_BYTES]u8 = @splat(0);
            @memcpy(cfg[0..6], &self.mac);
            std.mem.writeInt(u16, cfg[6..8], VIRTIO_NET_S_LINK_UP, .little);
            const rel: usize = @intCast(
                offset - bus.VIRTIO_MMIO_REG_CONFIG_BASE,
            );
            var word: [4]u8 = @splat(0);
            const copy_len = @min(@as(usize, 4), cfg.len - rel);
            @memcpy(word[0..copy_len], cfg[rel .. rel + copy_len]);
            return std.mem.readInt(u32, &word, .little);
        }
        return 0;
    }

    pub fn writeReg(self: *VirtioNet, offset: u32, val: u32) void {
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

    fn pushUsed(
        mem: MemoryAccessor,
        q: *VirtQueue,
        head_idx: u16,
        len: u32,
    ) void {
        const used_slot = q.last_used_idx % q.num;
        const used_elem = VirtqUsedElem{ .id = head_idx, .len = len };
        const used_off = bus.VIRTQ_RING_ELEMS_OFFSET +%
            (@as(u64, used_slot) *% @sizeOf(VirtqUsedElem));
        _ = mem.write(q.device_gpa +% used_off, std.mem.asBytes(&used_elem));
        bus.memoryBarrier();
        q.last_used_idx +%= 1;
        _ = mem.write(
            q.device_gpa +% bus.VIRTQ_RING_IDX_OFFSET,
            std.mem.asBytes(&q.last_used_idx),
        );
        q.last_avail_idx +%= 1;
    }

    pub fn processTx(self: *VirtioNet) void {
        while (self.tx_lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer self.tx_lock.store(false, .release);

        const mem = self.mem orelse return;
        const tx_q = &self.queues[QUEUE_INDEX_TX];
        if (!tx_q.ready or tx_q.num == 0 or
            tx_q.driver_gpa == 0 or tx_q.device_gpa == 0)
        {
            return;
        }

        var avail_idx: u16 = 0;
        if (!mem.read(
            tx_q.driver_gpa +% bus.VIRTQ_RING_IDX_OFFSET,
            std.mem.asBytes(&avail_idx),
        )) return;

        var processed: u16 = 0;
        while (tx_q.last_avail_idx != avail_idx and
            processed < tx_q.num) : (processed += 1)
        {
            bus.memoryBarrier();
            const slot = tx_q.last_avail_idx % tx_q.num;
            var head_idx: u16 = 0;
            const entry_off = bus.VIRTQ_RING_ELEMS_OFFSET +%
                (@as(u64, slot) *% @sizeOf(u16));
            if (!mem.read(
                tx_q.driver_gpa +% entry_off,
                std.mem.asBytes(&head_idx),
            )) break;
            if (head_idx >= tx_q.num) break;

            var desc: VirtqDesc = undefined;
            if (!mem.read(
                tx_q.desc_gpa +% (@as(u64, head_idx) *% @sizeOf(VirtqDesc)),
                std.mem.asBytes(&desc),
            )) break;

            var frame_buf: [MAX_ETH_FRAME_BYTES]u8 = undefined;
            var frame_len: usize = 0;

            if (desc.len > VIRTIO_NET_HDR_SIZE) {
                const avail_bytes: usize = desc.len - VIRTIO_NET_HDR_SIZE;
                const copy_len = @min(avail_bytes, frame_buf.len);
                if (mem.read(
                    desc.addr +% VIRTIO_NET_HDR_SIZE,
                    frame_buf[0..copy_len],
                )) {
                    frame_len = copy_len;
                }
            } else if (desc.len >= LEGACY_NET_HDR_SIZE and
                (desc.flags & bus.VIRTQ_DESC_F_NEXT) != 0 and
                desc.next < tx_q.num)
            {
                var next_desc: VirtqDesc = undefined;
                if (mem.read(
                    tx_q.desc_gpa +%
                        (@as(u64, desc.next) *% @sizeOf(VirtqDesc)),
                    std.mem.asBytes(&next_desc),
                )) {
                    const copy_len = @min(
                        @as(usize, next_desc.len),
                        frame_buf.len,
                    );
                    if (mem.read(next_desc.addr, frame_buf[0..copy_len])) {
                        frame_len = copy_len;
                    }
                }
            }

            if (frame_len > 0) {
                if (self.tx_fn) |tf| {
                    if (self.tx_ctx) |ctx| {
                        tf(ctx, frame_buf[0..frame_len]);
                    }
                }
            }
            pushUsed(mem, tx_q, head_idx, 0);
        }

        _ = @atomicRmw(u32, &self.interrupt_status, .Or, 1, .seq_cst);
    }

    pub fn deliverRxFrame(self: *VirtioNet, frame: []const u8) bool {
        if (frame.len == 0 or frame.len > MAX_ETH_FRAME_BYTES) return false;

        while (self.rx_lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer self.rx_lock.store(false, .release);

        const mem = self.mem orelse return false;
        const rx_q = &self.queues[QUEUE_INDEX_RX];
        if (!rx_q.ready or rx_q.num == 0 or
            rx_q.driver_gpa == 0 or rx_q.device_gpa == 0)
        {
            return false;
        }

        var avail_idx: u16 = 0;
        if (!mem.read(
            rx_q.driver_gpa +% bus.VIRTQ_RING_IDX_OFFSET,
            std.mem.asBytes(&avail_idx),
        )) return false;
        if (rx_q.last_avail_idx == avail_idx) return false;
        bus.memoryBarrier();

        const slot = rx_q.last_avail_idx % rx_q.num;
        var head_idx: u16 = 0;
        const entry_off = bus.VIRTQ_RING_ELEMS_OFFSET +%
            (@as(u64, slot) *% @sizeOf(u16));
        if (!mem.read(
            rx_q.driver_gpa +% entry_off,
            std.mem.asBytes(&head_idx),
        )) return false;
        if (head_idx >= rx_q.num) return false;

        var desc: VirtqDesc = undefined;
        if (!mem.read(
            rx_q.desc_gpa +% (@as(u64, head_idx) *% @sizeOf(VirtqDesc)),
            std.mem.asBytes(&desc),
        )) return false;
        if ((desc.flags & bus.VIRTQ_DESC_F_WRITE) == 0 or
            desc.len < VIRTIO_NET_HDR_SIZE)
        {
            return false;
        }

        const hdr = VirtioNetHdr{};
        if (!mem.write(desc.addr, std.mem.asBytes(&hdr))) return false;

        var payload_written: usize = 0;
        if (desc.len >= VIRTIO_NET_HDR_SIZE + frame.len) {
            if (!mem.write(desc.addr +% VIRTIO_NET_HDR_SIZE, frame)) {
                return false;
            }
            payload_written = frame.len;
        } else if ((desc.flags & bus.VIRTQ_DESC_F_NEXT) != 0 and
            desc.next < rx_q.num)
        {
            var next_desc: VirtqDesc = undefined;
            if (!mem.read(
                rx_q.desc_gpa +% (@as(u64, desc.next) *% @sizeOf(VirtqDesc)),
                std.mem.asBytes(&next_desc),
            )) return false;
            if ((next_desc.flags & bus.VIRTQ_DESC_F_WRITE) == 0 or
                next_desc.len < frame.len)
            {
                return false;
            }
            if (!mem.write(next_desc.addr, frame)) return false;
            payload_written = frame.len;
        } else {
            return false;
        }

        const total_len: u32 = @intCast(VIRTIO_NET_HDR_SIZE + payload_written);
        pushUsed(mem, rx_q, head_idx, total_len);
        _ = @atomicRmw(u32, &self.interrupt_status, .Or, 1, .seq_cst);
        return true;
    }
};

test "VirtIO-net MAC config read, TX callback, and RX frame delivery" {
    const testing = std.testing;
    testing.refAllDecls(@This());

    const MOCK_RAM_BYTES: usize = 65536;
    const MockRam = struct {
        buffer: [MOCK_RAM_BYTES]u8 = @splat(0),
        last_tx_len: usize = 0,
        last_tx: [64]u8 = @splat(0),

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

        fn onTx(ctx: *anyopaque, frame: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const n = @min(frame.len, self.last_tx.len);
            @memcpy(self.last_tx[0..n], frame[0..n]);
            self.last_tx_len = n;
        }
    };

    var ram = MockRam{};
    const mem = MemoryAccessor{
        .ctx = &ram,
        .readFn = MockRam.read,
        .writeFn = MockRam.write,
    };
    var vnet = VirtioNet.init(0x0203, mem);
    vnet.tx_ctx = &ram;
    vnet.tx_fn = MockRam.onTx;

    try testing.expectEqual(VIRTIO_ID_NET, vnet.readReg(0x008));
    const mac0: u8 = @truncate(vnet.readReg(0x100));
    const mac1: u8 = @truncate(vnet.readReg(0x101));
    const mac4: u8 = @truncate(vnet.readReg(0x104));
    const mac5: u8 = @truncate(vnet.readReg(0x105));
    try testing.expectEqual(@as(u8, 0x02), mac0);
    try testing.expectEqual(@as(u8, 0x00), mac1);
    try testing.expectEqual(@as(u8, 0x02), mac4);
    try testing.expectEqual(@as(u8, 0x03), mac5);

    vnet.queues[QUEUE_INDEX_RX] = .{
        .ready = true,
        .desc_gpa = 0x1000,
        .driver_gpa = 0x2000,
        .device_gpa = 0x3000,
    };
    const rx_d = VirtqDesc{
        .addr = 0x4000,
        .len = 2048,
        .flags = bus.VIRTQ_DESC_F_WRITE,
        .next = 0,
    };
    _ = mem.write(0x1000, std.mem.asBytes(&rx_d));
    const head: u16 = 0;
    const avail: u16 = 1;
    _ = mem.write(0x2004, std.mem.asBytes(&head));
    _ = mem.write(0x2002, std.mem.asBytes(&avail));

    try testing.expect(vnet.deliverRxFrame("ETH-TEST-FRAME"));
    try testing.expectEqualStrings(
        "ETH-TEST-FRAME",
        ram.buffer[0x4000 + VIRTIO_NET_HDR_SIZE ..][0..14],
    );
}
