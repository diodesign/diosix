// VirtIO-blk (Virtual Block Device) Emulation
// Implements VirtIO 1.1 / 1.2 Device ID 2 (VIRTIO_ID_BLK) for guest block
// storage backed by a staged guest RAM window or explicit GPA range.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const bus = @import("bus.zig");
const vsock_mod = @import("vsock.zig");
const io = @import("vblk/io.zig");
const MemoryAccessor = vsock_mod.MemoryAccessor;
const VirtqDesc = bus.VirtqDesc;

pub const VIRTIO_ID_BLK: u32 = 2;
pub const VIRTIO_VENDOR_ID: u32 = bus.VIRTIO_MMIO_VENDOR_QEMU;
pub const VIRTIO_MAGIC: u32 = bus.VIRTIO_MMIO_MAGIC;
pub const VIRTIO_VERSION: u32 = bus.VIRTIO_MMIO_VERSION_2;

pub const QUEUE_SIZE_MAX: u16 = 128;
pub const NUM_QUEUES: usize = 1;
pub const QUEUE_INDEX_REQ: usize = 0;

pub const SECTOR_SIZE: u64 = 512;
pub const SECTOR_SHIFT: u6 = 9;
pub const IO_CHUNK_BYTES: usize = 512;
pub const MAX_CHAIN_DESCRIPTORS: usize = QUEUE_SIZE_MAX;

pub const VIRTIO_BLK_F_RO: u32 = 1 << 5;
pub const VIRTIO_BLK_F_FLUSH: u32 = 1 << 9;

pub const VIRTIO_BLK_T_IN: u32 = 0;
pub const VIRTIO_BLK_T_OUT: u32 = 1;
pub const VIRTIO_BLK_T_FLUSH: u32 = 4;
pub const VIRTIO_BLK_T_GET_ID: u32 = 8;

pub const VIRTIO_BLK_S_OK: u8 = 0;
pub const VIRTIO_BLK_S_IOERR: u8 = 1;
pub const VIRTIO_BLK_S_UNSUPP: u8 = 2;

pub const VIRTIO_BLK_ID_BYTES: usize = 20;

pub const SHIM_HEADER_OFFSET: u64 = 0x0010_0000;
pub const SHIM_HEADER_MAGIC: u64 = 0x4d49_4853_5853_4f44; // "DOSXSHIM".
const SHIM_HEADER_BYTES: usize = 24;

pub const VirtioBlkReqHdr = extern struct {
    req_type: u32 align(1),
    ioprio: u32 align(1),
    sector: u64 align(1),
};

comptime {
    std.debug.assert(@sizeOf(VirtioBlkReqHdr) == 16);
}

pub const VirtQueue = bus.VirtQueueConfig(QUEUE_SIZE_MAX);

pub const VirtioBlk = struct {
    status: u32 = 0,
    device_features_sel: u32 = 0,
    driver_features_sel: u32 = 0,
    driver_features: u64 = 0,
    queue_sel: u32 = 0,
    interrupt_status: u32 = 0,
    queues: [NUM_QUEUES]VirtQueue = @splat(.{}),
    mem: ?MemoryAccessor = null,
    base_gpa: u64 = 0,
    backing_gpa: u64 = 0,
    capacity_bytes: u64 = 0,
    read_only: bool = false,
    req_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(base_gpa: u64, mem: ?MemoryAccessor) VirtioBlk {
        return .{
            .base_gpa = base_gpa,
            .mem = mem,
        };
    }

    pub fn configureBacking(
        self: *VirtioBlk,
        backing_gpa: u64,
        capacity_bytes: u64,
        read_only: bool,
    ) void {
        self.backing_gpa = backing_gpa;
        self.capacity_bytes = capacity_bytes & ~(SECTOR_SIZE - 1);
        self.read_only = read_only;
    }

    fn ensureBackingStore(self: *VirtioBlk) void {
        if (self.backing_gpa != 0 and self.capacity_bytes != 0) return;
        const mem = self.mem orelse return;
        if (self.base_gpa == 0) return;

        var hdr: [SHIM_HEADER_BYTES]u8 = undefined;
        const hdr_gpa = std.math.add(
            u64,
            self.base_gpa,
            SHIM_HEADER_OFFSET,
        ) catch return;
        if (!mem.read(hdr_gpa, &hdr)) return;

        const magic = std.mem.readInt(u64, hdr[0..8], .little);
        if (magic != SHIM_HEADER_MAGIC) return;
        const payload_off = std.mem.readInt(u64, hdr[8..16], .little);
        const payload_len = std.mem.readInt(u64, hdr[16..24], .little);
        if (payload_off == 0 or payload_len < SECTOR_SIZE) return;

        const backing = std.math.add(
            u64,
            self.base_gpa,
            payload_off,
        ) catch return;
        const cap_aligned = payload_len & ~(SECTOR_SIZE - 1);
        _ = std.math.add(u64, backing, cap_aligned) catch return;
        self.backing_gpa = backing;
        self.capacity_bytes = cap_aligned;
    }

    pub fn capacitySectors(self: *VirtioBlk) u64 {
        self.ensureBackingStore();
        return self.capacity_bytes >> SECTOR_SHIFT;
    }

    pub fn readReg(self: *VirtioBlk, offset: u32) u32 {
        const sectors = self.capacitySectors();
        if (offset == bus.VIRTIO_MMIO_REG_DEVICE_ID) {
            return if (sectors > 0)
                VIRTIO_ID_BLK
            else
                bus.VIRTIO_MMIO_DEVICE_NONE;
        }

        if (offset == bus.VIRTIO_MMIO_REG_DEVICE_FEATURES) {
            if (sectors == 0) return 0;
            if (self.device_features_sel == 0) {
                var feat: u32 = VIRTIO_BLK_F_FLUSH;
                if (self.read_only) feat |= VIRTIO_BLK_F_RO;
                return feat;
            }
            if (self.device_features_sel == bus.VIRTIO_F_VERSION_1_SEL) {
                return bus.VIRTIO_F_VERSION_1_BIT;
            }
            return 0;
        }

        const irq = @atomicLoad(u32, &self.interrupt_status, .seq_cst);
        if (bus.readVirtioCommon(
            self,
            VIRTIO_ID_BLK,
            NUM_QUEUES,
            QUEUE_SIZE_MAX,
            irq,
            offset,
        )) |common| return common;

        return switch (offset) {
            bus.VIRTIO_MMIO_REG_CONFIG_BASE => @truncate(sectors),
            bus.VIRTIO_MMIO_REG_CONFIG_BASE + 4 => @truncate(
                sectors >> bus.HIGH_WORD_SHIFT,
            ),
            else => 0,
        };
    }

    pub fn writeReg(self: *VirtioBlk, offset: u32, val: u32) void {
        if (bus.writeVirtioQueueAndFeatureReg(
            self,
            NUM_QUEUES,
            QUEUE_SIZE_MAX,
            offset,
            val,
        )) return;

        switch (offset) {
            bus.VIRTIO_MMIO_REG_QUEUE_NOTIFY => {
                if (val == QUEUE_INDEX_REQ) self.processQueue();
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
                    while (self.req_lock.swap(true, .acquire)) {
                        std.atomic.spinLoopHint();
                    }
                    defer self.req_lock.store(false, .release);
                    for (&self.queues) |*q| q.* = .{};
                    @atomicStore(u32, &self.interrupt_status, 0, .seq_cst);
                }
            },
            else => {},
        }
    }

    pub fn processQueue(self: *VirtioBlk) void {
        while (self.req_lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer self.req_lock.store(false, .release);

        self.ensureBackingStore();
        io.processQueueLocked(self);
    }
};

test "VirtIO-blk sector read, write, read-only guard, and DOSXSHIM discovery" {
    _ = io;
    const testing = std.testing;
    testing.refAllDecls(@This());

    const MOCK_RAM_BYTES: usize = 0x0020_0000;
    const MockRam = struct {
        buffer: []u8,

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
            return .{ .ctx = self, .readFn = read, .writeFn = write };
        }
    };

    const backing_buf = try testing.allocator.alloc(u8, MOCK_RAM_BYTES);
    defer testing.allocator.free(backing_buf);
    @memset(backing_buf, 0);

    var ram = MockRam{ .buffer = backing_buf };
    const mem = ram.accessor();

    var blk = VirtioBlk.init(0, mem);
    blk.configureBacking(0x10000, 4096, false);

    try testing.expectEqual(VIRTIO_ID_BLK, blk.readReg(0x008));
    try testing.expectEqual(@as(u32, 8), blk.readReg(0x100));

    blk.queues[QUEUE_INDEX_REQ] = .{
        .ready = true,
        .desc_gpa = 0x1000,
        .driver_gpa = 0x2000,
        .device_gpa = 0x3000,
    };

    const write_req = VirtioBlkReqHdr{
        .req_type = VIRTIO_BLK_T_OUT,
        .ioprio = 0,
        .sector = 1,
    };
    _ = mem.write(0x4000, std.mem.asBytes(&write_req));
    _ = mem.write(0x4100, "DIOSIX-SECTOR-1");

    const d0 = VirtqDesc{
        .addr = 0x4000,
        .len = @sizeOf(VirtioBlkReqHdr),
        .flags = bus.VIRTQ_DESC_F_NEXT,
        .next = 1,
    };
    const d1 = VirtqDesc{
        .addr = 0x4100,
        .len = 512,
        .flags = bus.VIRTQ_DESC_F_NEXT,
        .next = 2,
    };
    const d2 = VirtqDesc{
        .addr = 0x4300,
        .len = 1,
        .flags = bus.VIRTQ_DESC_F_WRITE,
        .next = 0,
    };
    _ = mem.write(0x1000, std.mem.asBytes(&d0));
    _ = mem.write(0x1010, std.mem.asBytes(&d1));
    _ = mem.write(0x1020, std.mem.asBytes(&d2));

    const head: u16 = 0;
    const avail: u16 = 1;
    _ = mem.write(0x2004, std.mem.asBytes(&head));
    _ = mem.write(0x2002, std.mem.asBytes(&avail));

    blk.writeReg(bus.VIRTIO_MMIO_REG_QUEUE_NOTIFY, 0);
    try testing.expectEqual(VIRTIO_BLK_S_OK, backing_buf[0x4300]);
    try testing.expectEqualStrings(
        "DIOSIX-SECTOR-1",
        backing_buf[0x10200 .. 0x10200 + 15],
    );
}
