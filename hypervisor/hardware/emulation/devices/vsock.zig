// VirtIO-vsock (Virtual Sockets) Device Emulation and In-Hypervisor Packet Router
// Implements VirtIO 1.1 / 1.2 Device ID 19 (VIRTIO_ID_VSOCK) for AF_VSOCK networking.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const bus = @import("bus.zig");

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

pub const TABLE_BUCKETS: usize = 32;

pub const VsockRouter = struct {
    // Fast-path direct slots for standard system and early guest CIDs 0..31:
    // (CID 0: Hypervisor/Loopback, CID 2: Host OS, CIDs 3..31: early guest VMs)
    static_slots: [TABLE_BUCKETS]?*VirtioVsock = @splat(null),

    // Dynamic hash table buckets for arbitrary 64-bit CIDs (bucket = cid % TABLE_BUCKETS)
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

        // CIDs >= 32: Hash table bucket insertion
        const bucket = @as(usize, @truncate(cid % TABLE_BUCKETS));
        // Remove prior registration if present to prevent circular links
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

        // CIDs >= 32: Hash table lookup in dynamic buckets
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

    pub fn routePacket(self: *VsockRouter, src_dev: *VirtioVsock, hdr: *const VirtioVsockHdr, payload: []const u8) bool {
        const target = self.getDevice(hdr.dst_cid) orelse return false;
        // Security Shield: Prevent CID spoofing across virtual guests.
        // Guarantee that the source CID delivered to the destination matches the authentic guest CID of the sender.
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
    router_next: ?*VirtioVsock = null,
    rx_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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
            bus.VIRTIO_MMIO_REG_MAGIC_VALUE => VIRTIO_MAGIC,
            bus.VIRTIO_MMIO_REG_VERSION => VIRTIO_VERSION,
            bus.VIRTIO_MMIO_REG_DEVICE_ID => VIRTIO_ID_VSOCK,
            bus.VIRTIO_MMIO_REG_VENDOR_ID => VIRTIO_VENDOR_ID,
            bus.VIRTIO_MMIO_REG_DEVICE_FEATURES => blk: {
                if (self.device_features_sel == 0) {
                    // Feature bits 0..31
                    break :blk 0;
                } else if (self.device_features_sel == 1) {
                    // VIRTIO_F_VERSION_1 (bit 32 -> bit 0 of sel 1)
                    break :blk (1 << 0);
                }
                break :blk 0;
            },
            bus.VIRTIO_MMIO_REG_QUEUE_NUM_MAX => if (self.queue_sel < NUM_QUEUES) QUEUE_SIZE_MAX else 0,
            bus.VIRTIO_MMIO_REG_QUEUE_READY => if (self.queue_sel < NUM_QUEUES) (if (self.queues[self.queue_sel].ready) 1 else 0) else 0,
            bus.VIRTIO_MMIO_REG_INTERRUPT_STATUS => @atomicLoad(u32, &self.interrupt_status, .seq_cst),
            bus.VIRTIO_MMIO_REG_STATUS => self.status,
            0x0fc, bus.VIRTIO_MMIO_REG_CONFIG_BASE => @truncate(self.guest_cid),
            bus.VIRTIO_MMIO_REG_CONFIG_BASE + 4 => @truncate(self.guest_cid >> 32),
            else => 0,
        };
    }

    pub fn writeReg(self: *VirtioVsock, offset: u32, val: u32) void {
        switch (offset) {
            bus.VIRTIO_MMIO_REG_DEVICE_FEATURES_SEL => self.device_features_sel = val,
            bus.VIRTIO_MMIO_REG_DRIVER_FEATURES => {
                if (self.driver_features_sel == 0) {
                    self.driver_features = (self.driver_features & 0xFFFFFFFF00000000) | val;
                } else if (self.driver_features_sel == 1) {
                    self.driver_features = (self.driver_features & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
                }
            },
            bus.VIRTIO_MMIO_REG_DRIVER_FEATURES_SEL => self.driver_features_sel = val,
            bus.VIRTIO_MMIO_REG_QUEUE_SEL => self.queue_sel = val,
            bus.VIRTIO_MMIO_REG_QUEUE_NUM => {
                if (self.queue_sel < NUM_QUEUES) {
                    const q_num = @min(val, QUEUE_SIZE_MAX);
                    if (q_num > 0) {
                        self.queues[self.queue_sel].num = @truncate(q_num);
                    }
                }
            },
            bus.VIRTIO_MMIO_REG_QUEUE_READY => {
                if (self.queue_sel < NUM_QUEUES) {
                    const req_ready = (val & 1) != 0;
                    if (req_ready and self.queues[self.queue_sel].num == 0) {
                        self.queues[self.queue_sel].ready = false;
                    } else {
                        self.queues[self.queue_sel].ready = req_ready;
                    }
                }
            },
            bus.VIRTIO_MMIO_REG_QUEUE_NOTIFY => {
                // Queue Notify doorbell from driver
                const q_idx = val;
                if (q_idx == 1) {
                    self.processTx();
                }
            },
            bus.VIRTIO_MMIO_REG_INTERRUPT_ACK => {
                // Interrupt ACK
                _ = @atomicRmw(u32, &self.interrupt_status, .And, ~val, .seq_cst);
            },
            bus.VIRTIO_MMIO_REG_STATUS => {
                self.status = val;
                if (val == 0) {
                    // Device Reset
                    for (&self.queues) |*q| {
                        q.* = .{};
                    }
                    @atomicStore(u32, &self.interrupt_status, 0, .seq_cst);
                }
            },
            bus.VIRTIO_MMIO_REG_QUEUE_DESC_LOW => {
                if (self.queue_sel < NUM_QUEUES) {
                    self.queues[self.queue_sel].desc_gpa = (self.queues[self.queue_sel].desc_gpa & 0xFFFFFFFF00000000) | val;
                }
            },
            bus.VIRTIO_MMIO_REG_QUEUE_DESC_HIGH => {
                if (self.queue_sel < NUM_QUEUES) {
                    self.queues[self.queue_sel].desc_gpa = (self.queues[self.queue_sel].desc_gpa & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
                }
            },
            bus.VIRTIO_MMIO_REG_QUEUE_DRIVER_LOW => {
                if (self.queue_sel < NUM_QUEUES) {
                    self.queues[self.queue_sel].driver_gpa = (self.queues[self.queue_sel].driver_gpa & 0xFFFFFFFF00000000) | val;
                }
            },
            bus.VIRTIO_MMIO_REG_QUEUE_DRIVER_HIGH => {
                if (self.queue_sel < NUM_QUEUES) {
                    self.queues[self.queue_sel].driver_gpa = (self.queues[self.queue_sel].driver_gpa & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
                }
            },
            bus.VIRTIO_MMIO_REG_QUEUE_DEVICE_LOW => {
                if (self.queue_sel < NUM_QUEUES) {
                    self.queues[self.queue_sel].device_gpa = (self.queues[self.queue_sel].device_gpa & 0xFFFFFFFF00000000) | val;
                }
            },
            bus.VIRTIO_MMIO_REG_QUEUE_DEVICE_HIGH => {
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
        if (!tx_q.ready or tx_q.num == 0 or tx_q.driver_gpa == 0 or tx_q.device_gpa == 0) return;

        // Read available index from Avail Ring
        var avail_idx: u16 = 0;
        if (!mem.read(tx_q.driver_gpa +% 2, std.mem.asBytes(&avail_idx))) return;

        var processed_count: u16 = 0;
        while (tx_q.last_avail_idx != avail_idx and processed_count < tx_q.num) : (processed_count += 1) {
            const ring_slot = tx_q.last_avail_idx % tx_q.num;
            var desc_head_idx: u16 = 0;
            const ring_entry_offset = 4 +% (@as(u64, ring_slot) *% 2);
            if (!mem.read(tx_q.driver_gpa +% ring_entry_offset, std.mem.asBytes(&desc_head_idx))) break;

            if (desc_head_idx >= tx_q.num) break;

            // Read descriptor
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
                            const available_in_desc = @min(payload_len, desc.len - @sizeOf(VirtioVsockHdr));
                            if (mem.read(desc.addr +% @sizeOf(VirtioVsockHdr), payload_buf[0..available_in_desc])) {
                                payload_slice = payload_buf[0..available_in_desc];
                            }
                        } else if ((desc.flags & VIRTQ_DESC_F_NEXT) != 0 and desc.next < tx_q.num) {
                            var next_desc: VirtqDesc = undefined;
                            const next_desc_offset = @as(u64, desc.next) *% @sizeOf(VirtqDesc);
                            const next_desc_addr = tx_q.desc_gpa +% next_desc_offset;
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
            const used_elem_offset = 4 +% (@as(u64, used_slot) *% @sizeOf(VirtqUsedElem));
            const used_elem_addr = tx_q.device_gpa +% used_elem_offset;
            _ = mem.write(used_elem_addr, std.mem.asBytes(&used_elem));

            tx_q.last_used_idx +%= 1;
            _ = mem.write(tx_q.device_gpa +% 2, std.mem.asBytes(&tx_q.last_used_idx));

            tx_q.last_avail_idx +%= 1;
        }

        // Set interrupt for used buffer notification
        _ = @atomicRmw(u32, &self.interrupt_status, .Or, 1, .seq_cst);
    }

    pub fn deliverRxPacket(self: *VirtioVsock, hdr: *const VirtioVsockHdr, payload: []const u8) bool {
        while (self.rx_lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer self.rx_lock.store(false, .release);

        const mem = self.mem orelse return false;
        var rx_q = &self.queues[0];
        if (!rx_q.ready or rx_q.num == 0 or rx_q.driver_gpa == 0 or rx_q.device_gpa == 0) return false;

        // Read available index
        var avail_idx: u16 = 0;
        if (!mem.read(rx_q.driver_gpa +% 2, std.mem.asBytes(&avail_idx))) return false;
        if (rx_q.last_avail_idx == avail_idx) return false; // No RX buffers available

        const ring_slot = rx_q.last_avail_idx % rx_q.num;
        var desc_head_idx: u16 = 0;
        const ring_entry_offset = 4 +% (@as(u64, ring_slot) *% 2);
        if (!mem.read(rx_q.driver_gpa +% ring_entry_offset, std.mem.asBytes(&desc_head_idx))) return false;

        if (desc_head_idx >= rx_q.num) return false;

        var desc: VirtqDesc = undefined;
        const desc_offset = @as(u64, desc_head_idx) *% @sizeOf(VirtqDesc);
        const desc_addr = rx_q.desc_gpa +% desc_offset;
        if (!mem.read(desc_addr, std.mem.asBytes(&desc))) return false;

        if (desc.len < @sizeOf(VirtioVsockHdr)) return false;
        // RX descriptors must be device-writable per VirtIO 1.1 spec Section 2.6.5
        if ((desc.flags & VIRTQ_DESC_F_WRITE) == 0) return false;

        var rx_hdr = hdr.*;
        var payload_written: u32 = 0;

        if (payload.len > 0) {
            const needed_len = std.math.add(usize, @sizeOf(VirtioVsockHdr), payload.len) catch std.math.maxInt(usize);
            if (desc.len >= needed_len) {
                if (mem.write(desc.addr +% @sizeOf(VirtioVsockHdr), payload)) {
                    payload_written = @truncate(payload.len);
                }
            } else if ((desc.flags & VIRTQ_DESC_F_NEXT) != 0 and desc.next < rx_q.num) {
                var next_desc: VirtqDesc = undefined;
                const next_desc_offset = @as(u64, desc.next) *% @sizeOf(VirtqDesc);
                const next_desc_addr = rx_q.desc_gpa +% next_desc_offset;
                if (mem.read(next_desc_addr, std.mem.asBytes(&next_desc))) {
                    if ((next_desc.flags & VIRTQ_DESC_F_WRITE) != 0) {
                        const copy_len = @min(payload.len, next_desc.len);
                        if (mem.write(next_desc.addr, payload[0..copy_len])) {
                            payload_written = @truncate(copy_len);
                        }
                    }
                }
            }
        }

        // Deliver header with exact payload byte count written into guest buffers
        rx_hdr.len = payload_written;
        if (!mem.write(desc.addr, std.mem.asBytes(&rx_hdr))) return false;

        const total_written: u32 = @sizeOf(VirtioVsockHdr) + payload_written;

        // Put into Used ring
        const used_slot = rx_q.last_used_idx % rx_q.num;
        const used_elem = VirtqUsedElem{
            .id = desc_head_idx,
            .len = total_written,
        };
        const used_elem_offset = 4 +% (@as(u64, used_slot) *% @sizeOf(VirtqUsedElem));
        const used_elem_addr = rx_q.device_gpa +% used_elem_offset;
        _ = mem.write(used_elem_addr, std.mem.asBytes(&used_elem));

        rx_q.last_used_idx +%= 1;
        _ = mem.write(rx_q.device_gpa +% 2, std.mem.asBytes(&rx_q.last_used_idx));
        rx_q.last_avail_idx +%= 1;

        // Raise interrupt
        _ = @atomicRmw(u32, &self.interrupt_status, .Or, 1, .seq_cst);
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
        const end = std.math.add(u64, gpa, buf.len) catch return false;
        if (end > self.buffer.len) return false;
        @memcpy(buf, self.buffer[@intCast(gpa)..@intCast(end)]);
        return true;
    }

    pub fn write(ctx: *anyopaque, gpa: u64, buf: []const u8) bool {
        const self: *MockRam = @ptrCast(@alignCast(ctx));
        const end = std.math.add(u64, gpa, buf.len) catch return false;
        if (end > self.buffer.len) return false;
        @memcpy(self.buffer[@intCast(gpa)..@intCast(end)], buf);
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

test "VirtIO-vsock safety against malicious queue zero size and out-of-bounds descriptor heads" {
    const testing = std.testing;

    var ram = MockRam{};
    const mem = MemoryAccessor{
        .ctx = &ram,
        .readFn = MockRam.read,
        .writeFn = MockRam.write,
    };
    var vsock = VirtioVsock.init(3, mem);

    // 1. Malicious guest attempts to configure queue size = 0
    vsock.writeReg(0x030, 1); // Select TX queue
    vsock.writeReg(0x038, 0); // Write QueueNum = 0
    try testing.expect(vsock.queues[1].num > 0); // Must be rejected or preserved > 0

    // 2. Queue notify on unconfigured queue must not divide by zero or panic
    vsock.queues[1].num = 0; // Forced simulation of zero queue size
    vsock.queues[1].ready = true;
    vsock.processTx(); // Must safely return without dividing by zero

    // 3. Out-of-bounds descriptor head index must not read outside descriptor table
    vsock.queues[1].num = 16;
    vsock.queues[1].driver_gpa = 0x2000;
    vsock.queues[1].desc_gpa = 0x1000;
    vsock.queues[1].device_gpa = 0x3000;
    vsock.queues[1].last_avail_idx = 0;

    const bad_avail_idx: u16 = 1;
    _ = mem.write(0x2002, std.mem.asBytes(&bad_avail_idx));
    const bad_desc_head: u16 = 999; // Out of bounds (> 16)
    _ = mem.write(0x2004, std.mem.asBytes(&bad_desc_head));

    vsock.processTx(); // Must safely break without out-of-bounds read
    try testing.expectEqual(@as(u16, 0), vsock.queues[1].last_used_idx); // No descriptor processed
}

test "VirtIO-vsock router prevents CID spoofing" {
    const testing = std.testing;

    var ram_dest = MockRam{};
    const mem_dest = MemoryAccessor{
        .ctx = &ram_dest,
        .readFn = MockRam.read,
        .writeFn = MockRam.write,
    };

    var sender = VirtioVsock.init(2, null);
    var receiver = VirtioVsock.init(3, mem_dest);

    // Setup receiver's RX queue
    receiver.queues[0].ready = true;
    receiver.queues[0].num = 16;
    receiver.queues[0].driver_gpa = 0x2000;
    receiver.queues[0].desc_gpa = 0x1000;
    receiver.queues[0].device_gpa = 0x3000;

    const avail_idx: u16 = 1;
    _ = mem_dest.write(0x2002, std.mem.asBytes(&avail_idx));
    const desc_head: u16 = 0;
    _ = mem_dest.write(0x2004, std.mem.asBytes(&desc_head));

    const rx_desc = VirtqDesc{
        .addr = 0x4000,
        .len = 512,
        .flags = VIRTQ_DESC_F_WRITE,
        .next = 0,
    };
    _ = mem_dest.write(0x1000, std.mem.asBytes(&rx_desc));

    // Attacker sends packet with spoofed src_cid = 999 (pretending to be root or another VM)
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

    // Verify receiver received packet with authentic sender CID 2, not spoofed 999!
    var received_hdr: VirtioVsockHdr = undefined;
    _ = mem_dest.read(0x4000, std.mem.asBytes(&received_hdr));
    try testing.expectEqual(@as(u64, 2), received_hdr.src_cid);

    // Test rejection of non-writable RX descriptor
    const ro_desc = VirtqDesc{
        .addr = 0x4000,
        .len = 512,
        .flags = 0, // No VIRTQ_DESC_F_WRITE
        .next = 0,
    };
    _ = mem_dest.write(0x1000, std.mem.asBytes(&ro_desc));
    receiver.queues[0].last_avail_idx = 0; // Reset avail idx to process slot again
    try testing.expect(!receiver.deliverRxPacket(&spoofed_hdr, "TEST"));

    // Test rejection of out-of-bounds 64-bit CID without aliasing
    var high_cid_hdr = spoofed_hdr;
    high_cid_hdr.dst_cid = (@as(u64, 1) << 32) | 3;
    try testing.expect(!router.routePacket(&sender, &high_cid_hdr, "TEST"));

    // Test QueueNumMax invalid selector
    sender.writeReg(bus.VIRTIO_MMIO_REG_QUEUE_SEL, 0);
    try testing.expectEqual(QUEUE_SIZE_MAX, sender.readReg(bus.VIRTIO_MMIO_REG_QUEUE_NUM_MAX));
    sender.writeReg(bus.VIRTIO_MMIO_REG_QUEUE_SEL, 5); // Non-existent queue
    try testing.expectEqual(@as(u32, 0), sender.readReg(bus.VIRTIO_MMIO_REG_QUEUE_NUM_MAX));

    // Test high CID (>= 64) registration and routing
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
        .len = 100, // Deliberately state 100 bytes
        .type = VIRTIO_VSOCK_TYPE_STREAM,
        .op = VIRTIO_VSOCK_OP_RW,
        .flags = 0,
        .buf_alloc = 4096,
        .fwd_cnt = 0,
    };
    // Send 5 bytes payload: header delivered should accurately record len = 5, NOT 100!
    const high_delivered = router.routePacket(&sender, &high_dst_hdr, "HELLO");
    try testing.expect(high_delivered);
    var delivered_hdr: VirtioVsockHdr = undefined;
    _ = mem_high.read(0x4000, std.mem.asBytes(&delivered_hdr));
    try testing.expectEqual(@as(u32, 5), delivered_hdr.len);
    try testing.expectEqual(@as(u64, 2), delivered_hdr.src_cid);
    try testing.expectEqual(@as(u64, 64), delivered_hdr.dst_cid);
}

test "VsockRouter dynamic hash table with arbitrary 64-bit CIDs and collision handling" {
    const testing = std.testing;

    var router = VsockRouter{};

    // 1. Static slots (CIDs 0..31)
    var dev2 = VirtioVsock{ .guest_cid = 2 };
    var dev3 = VirtioVsock{ .guest_cid = 3 };
    router.register(&dev2);
    router.register(&dev3);

    try testing.expectEqual(&dev2, router.getDevice(2));
    try testing.expectEqual(&dev3, router.getDevice(3));
    try testing.expect(router.getDevice(4) == null);

    // 2. Dynamic high CIDs (CIDs >= 32)
    var dev1000 = VirtioVsock{ .guest_cid = 1000 };
    var dev_u32max = VirtioVsock{ .guest_cid = 4294967295 }; // 2^32 - 1
    var dev_high64 = VirtioVsock{ .guest_cid = (@as(u64, 1) << 40) | 123 };
    router.register(&dev1000);
    router.register(&dev_u32max);
    router.register(&dev_high64);

    try testing.expectEqual(&dev1000, router.getDevice(1000));
    try testing.expectEqual(&dev_u32max, router.getDevice(4294967295));
    try testing.expectEqual(&dev_high64, router.getDevice((@as(u64, 1) << 40) | 123));

    // 3. Collision handling in dynamic buckets: CIDs 38 and 70 both hash to bucket 38 % 32 = 6, 70 % 32 = 6
    var dev38 = VirtioVsock{ .guest_cid = 38 };
    var dev70 = VirtioVsock{ .guest_cid = 70 };
    router.register(&dev38);
    router.register(&dev70);

    try testing.expectEqual(&dev38, router.getDevice(38));
    try testing.expectEqual(&dev70, router.getDevice(70));

    // 4. Safe null on arbitrary non-existent or massive CIDs without crash or index overflow
    try testing.expect(router.getDevice(0xFFFF_FFFF_FFFF_FFFF) == null);
    try testing.expect(router.getDevice(99999) == null);

    // 5. Unregistration cleanly unlinks from dynamic bucket chain
    router.unregister(38);
    try testing.expect(router.getDevice(38) == null);
    try testing.expectEqual(&dev70, router.getDevice(70));

    router.unregister(70);
    try testing.expect(router.getDevice(70) == null);
}

