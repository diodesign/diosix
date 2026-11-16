// VirtIO-Input (Keyboard & Pointer Device) Emulation
// Implements VirtIO 1.1 / 1.2 Device ID 18 (VIRTIO_ID_INPUT) for standard
// Linux evdev keyboard, mouse button, scroll wheel, and absolute tablet input.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const bus = @import("bus.zig");
const vsock_mod = @import("vsock.zig");

pub const MemoryAccessor = vsock_mod.MemoryAccessor;
pub const VIRTIO_ID_INPUT: u32 = 18;
pub const VIRTIO_VENDOR_ID: u32 = bus.VIRTIO_MMIO_VENDOR_QEMU;
pub const VIRTIO_MAGIC: u32 = bus.VIRTIO_MMIO_MAGIC;
pub const VIRTIO_VERSION: u32 = bus.VIRTIO_MMIO_VERSION_2;

pub const QUEUE_SIZE_MAX: u16 = 64;
pub const NUM_QUEUES: usize = 2; // 0 = eventq, 1 = statusq.
pub const QUEUE_INDEX_EVENT: usize = 0;
pub const QUEUE_INDEX_STATUS: usize = 1;

// VirtIO Input Config Selectors.
pub const VIRTIO_INPUT_CFG_UNSET: u8 = 0x00;
pub const VIRTIO_INPUT_CFG_ID_NAME: u8 = 0x01;
pub const VIRTIO_INPUT_CFG_ID_SERIAL: u8 = 0x02;
pub const VIRTIO_INPUT_CFG_ID_DEVIDS: u8 = 0x03;
pub const VIRTIO_INPUT_CFG_PROP_BITS: u8 = 0x10;
pub const VIRTIO_INPUT_CFG_EV_BITS: u8 = 0x11;
pub const VIRTIO_INPUT_CFG_ABS_INFO: u8 = 0x12;

// VirtIO-Input config register offsets within MMIO.
pub const REG_INPUT_CFG_SELECT: u32 = bus.VIRTIO_MMIO_REG_CONFIG_BASE;
pub const REG_INPUT_CFG_SUBSEL: u32 = bus.VIRTIO_MMIO_REG_CONFIG_BASE + 1;
pub const REG_INPUT_CFG_SIZE: u32 = bus.VIRTIO_MMIO_REG_CONFIG_BASE + 2;
pub const REG_INPUT_CFG_DATA_START: u32 = bus.VIRTIO_MMIO_REG_CONFIG_BASE + 8;
pub const REG_INPUT_CFG_DATA_SIZE: u32 = 128;
pub const REG_INPUT_CFG_END: u32 =
    REG_INPUT_CFG_DATA_START + REG_INPUT_CFG_DATA_SIZE;

// Standard Linux evdev Event Types & Codes.
pub const EV_SYN: u16 = 0x00;
pub const EV_KEY: u16 = 0x01;
pub const EV_REL: u16 = 0x02;
pub const EV_ABS: u16 = 0x03;

pub const ABS_X: u8 = 0x00;
pub const ABS_Y: u8 = 0x01;
pub const ABS_MAX_COORD: u32 = 32_767;
pub const REL_WHEEL_BYTE: u32 = 1; // REL_WHEEL = 8 -> byte 1, bit 0.
pub const EV_KEY_BITMAP_BYTES: usize = 36; // Keys 1..248 + 0x110..0x112.
pub const BTN_MOUSE_BYTE: u32 = 34; // 0x110 / 8 = 34 (BTN_LEFT/RIGHT/MIDDLE).

const BUS_VIRTUAL: u16 = 0x06;
const VIRTIO_INPUT_VENDOR: u16 = 0x1af4;
const VIRTIO_INPUT_PRODUCT: u16 = 0x1052;

pub const VirtioInputEvent = extern struct {
    type: u16,
    code: u16,
    value: u32,
};

pub const VirtioInputDevIds = extern struct {
    bustype: u16 = BUS_VIRTUAL,
    vendor: u16 = VIRTIO_INPUT_VENDOR,
    product: u16 = VIRTIO_INPUT_PRODUCT,
    version: u16 = 1,
};

pub const VirtioInputAbsInfo = extern struct {
    min: u32 = 0,
    max: u32 = ABS_MAX_COORD,
    fuzz: u32 = 0,
    flat: u32 = 0,
    res: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(VirtioInputEvent) == 8);
    std.debug.assert(@sizeOf(VirtioInputDevIds) == 8);
    std.debug.assert(@sizeOf(VirtioInputAbsInfo) == 20);
}

pub const VirtqDesc = bus.VirtqDesc;
pub const VirtqUsedElem = bus.VirtqUsedElem;
pub const VirtQueue = bus.VirtQueueConfig(QUEUE_SIZE_MAX);

pub const MAX_EVENTS_BUFFER: usize = 128;

pub const VirtioInput = struct {
    guest_cid: usize = 0,
    mem: ?MemoryAccessor = null,
    status: u32 = 0,
    device_features_sel: u32 = 0,
    driver_features_sel: u32 = 0,
    driver_features: u64 = 0,
    queue_sel: u32 = 0,
    interrupt_status: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    cfg_select: u8 = VIRTIO_INPUT_CFG_UNSET,
    cfg_subsel: u8 = 0,

    queues: [NUM_QUEUES]VirtQueue = @splat(.{}),

    event_queue: [MAX_EVENTS_BUFFER]VirtioInputEvent = undefined,
    event_head: usize = 0,
    event_tail: usize = 0,
    event_count: usize = 0,

    device_name: []const u8 = "Diosix Virtual Input Device",
    serial_name: []const u8 = "diosix-input-0",

    pub fn initWithMem(guest_cid: usize, mem: ?MemoryAccessor) VirtioInput {
        return .{ .guest_cid = guest_cid, .mem = mem };
    }

    inline fn acquireLock(self: *VirtioInput) void {
        while (self.lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
    }

    inline fn releaseLock(self: *VirtioInput) void {
        self.lock.store(false, .release);
    }

    fn readConfigByteLocked(self: *const VirtioInput, offset: u32) u8 {
        return switch (offset) {
            REG_INPUT_CFG_SELECT => self.cfg_select,
            REG_INPUT_CFG_SUBSEL => self.cfg_subsel,
            REG_INPUT_CFG_SIZE => @truncate(self.getConfigSizeLocked()),
            else => if (offset >= REG_INPUT_CFG_DATA_START and
                offset < REG_INPUT_CFG_END)
            blk: {
                const data_off = offset - REG_INPUT_CFG_DATA_START;
                break :blk @truncate(self.readConfigDataLocked(data_off));
            } else 0,
        };
    }

    pub fn readReg(self: *VirtioInput, offset: u32) u32 {
        self.acquireLock();
        defer self.releaseLock();

        const irq = self.interrupt_status.load(.acquire);
        if (bus.readVirtioCommon(
            self,
            VIRTIO_ID_INPUT,
            NUM_QUEUES,
            QUEUE_SIZE_MAX,
            irq,
            offset,
        )) |common| return common;

        if (offset >= REG_INPUT_CFG_SELECT and offset < REG_INPUT_CFG_END) {
            var word: [4]u8 = @splat(0);
            for (0..4) |i| {
                const off = offset + @as(u32, @intCast(i));
                if (off < REG_INPUT_CFG_END) {
                    word[i] = self.readConfigByteLocked(off);
                }
            }
            return std.mem.readInt(u32, &word, .little);
        }
        return 0;
    }

    fn writeConfigRegLocked(
        self: *VirtioInput,
        offset: u32,
        val: u32,
        size: u8,
    ) void {
        if (offset == REG_INPUT_CFG_SELECT) {
            self.cfg_select = @truncate(val);
            if (size >= 2) self.cfg_subsel = @truncate(val >> 8);
        } else if (offset == REG_INPUT_CFG_SUBSEL) {
            self.cfg_subsel = @truncate(val);
        }
    }

    pub fn writeConfigReg(
        self: *VirtioInput,
        offset: u32,
        val: u32,
        size: u8,
    ) void {
        self.acquireLock();
        defer self.releaseLock();
        self.writeConfigRegLocked(offset, val, size);
    }

    pub fn writeReg(self: *VirtioInput, offset: u32, val: u32) void {
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
                if (val == QUEUE_INDEX_EVENT) {
                    if (self.flushEventsLocked() or self.event_count > 0) {
                        _ = self.interrupt_status.fetchOr(1, .release);
                    }
                } else if (val == QUEUE_INDEX_STATUS) {
                    self.drainStatusQueueLocked();
                }
            },
            bus.VIRTIO_MMIO_REG_INTERRUPT_ACK => {
                _ = self.interrupt_status.fetchAnd(~val, .release);
            },
            bus.VIRTIO_MMIO_REG_STATUS => {
                self.status = val;
                if (val == 0) self.resetLocked();
            },
            REG_INPUT_CFG_SELECT, REG_INPUT_CFG_SUBSEL => {
                self.writeConfigRegLocked(offset, val, 1);
            },
            else => {},
        }
    }

    fn resetLocked(self: *VirtioInput) void {
        self.status = 0;
        self.cfg_select = VIRTIO_INPUT_CFG_UNSET;
        self.cfg_subsel = 0;
        self.interrupt_status.store(0, .release);
        self.event_head = 0;
        self.event_tail = 0;
        self.event_count = 0;
        for (&self.queues) |*q| q.* = .{};
    }

    pub fn reset(self: *VirtioInput) void {
        self.acquireLock();
        defer self.releaseLock();
        self.resetLocked();
    }

    fn getConfigSizeLocked(self: *const VirtioInput) usize {
        return switch (self.cfg_select) {
            VIRTIO_INPUT_CFG_ID_NAME => self.device_name.len,
            VIRTIO_INPUT_CFG_ID_SERIAL => self.serial_name.len,
            VIRTIO_INPUT_CFG_ID_DEVIDS => @sizeOf(VirtioInputDevIds),
            VIRTIO_INPUT_CFG_EV_BITS => switch (self.cfg_subsel) {
                0 => 1, // EV_SYN, EV_KEY, EV_REL, EV_ABS summary bitmap.
                EV_KEY => EV_KEY_BITMAP_BYTES,
                EV_REL => 2,
                EV_ABS => 1,
                else => 0,
            },
            VIRTIO_INPUT_CFG_ABS_INFO => if (self.cfg_subsel == ABS_X or
                self.cfg_subsel == ABS_Y)
                @sizeOf(VirtioInputAbsInfo)
            else
                0,
            else => 0,
        };
    }

    fn readConfigDataLocked(self: *const VirtioInput, byte_idx: u32) u32 {
        switch (self.cfg_select) {
            VIRTIO_INPUT_CFG_ID_NAME => {
                if (byte_idx < self.device_name.len) {
                    return self.device_name[byte_idx];
                }
            },
            VIRTIO_INPUT_CFG_ID_SERIAL => {
                if (byte_idx < self.serial_name.len) {
                    return self.serial_name[byte_idx];
                }
            },
            VIRTIO_INPUT_CFG_ID_DEVIDS => {
                const ids = VirtioInputDevIds{};
                const raw = std.mem.asBytes(&ids);
                if (byte_idx < raw.len) return raw[byte_idx];
            },
            VIRTIO_INPUT_CFG_EV_BITS => switch (self.cfg_subsel) {
                0 => if (byte_idx == 0)
                    return (1 << EV_SYN) | (1 << EV_KEY) |
                        (1 << EV_REL) | (1 << EV_ABS),
                EV_KEY => {
                    if (byte_idx == 0) return 0xfe; // Keys 1..7.
                    if (byte_idx >= 1 and byte_idx < 31) return 0xff; // 8..247.
                    if (byte_idx == BTN_MOUSE_BYTE) return 0x07; // L/R/M click.
                },
                EV_REL => if (byte_idx == REL_WHEEL_BYTE) return 0x01,
                EV_ABS => if (byte_idx == 0)
                    return (1 << ABS_X) | (1 << ABS_Y),
                else => {},
            },
            VIRTIO_INPUT_CFG_ABS_INFO => {
                if (self.cfg_subsel == ABS_X or self.cfg_subsel == ABS_Y) {
                    const info = VirtioInputAbsInfo{};
                    const raw = std.mem.asBytes(&info);
                    if (byte_idx < raw.len) return raw[byte_idx];
                }
            },
            else => {},
        }
        return 0;
    }

    fn drainStatusQueueLocked(self: *VirtioInput) void {
        const mem = self.mem orelse return;
        const q = &self.queues[QUEUE_INDEX_STATUS];
        if (!q.ready or q.num == 0 or q.driver_gpa == 0 or q.device_gpa == 0) {
            return;
        }
        var avail_idx: u16 = 0;
        if (!mem.read(
            q.driver_gpa +% bus.VIRTQ_RING_IDX_OFFSET,
            std.mem.asBytes(&avail_idx),
        )) return;
        var drained: u16 = 0;
        while (q.last_avail_idx != avail_idx and
            drained < q.num) : (drained += 1)
        {
            const slot = q.last_avail_idx % q.num;
            var head_idx: u16 = 0;
            const off = bus.VIRTQ_RING_ELEMS_OFFSET +%
                (@as(u64, slot) *% @sizeOf(u16));
            if (!mem.read(q.driver_gpa +% off, std.mem.asBytes(&head_idx))) {
                break;
            }
            if (head_idx >= q.num) break;
            bus.pushVirtqUsed(mem, q, head_idx, 0);
        }
        if (drained > 0) _ = self.interrupt_status.fetchOr(1, .release);
    }

    fn flushEventsLocked(self: *VirtioInput) bool {
        const mem = self.mem orelse return false;
        const q = &self.queues[QUEUE_INDEX_EVENT];
        if (!q.ready or q.num == 0 or q.driver_gpa == 0 or q.device_gpa == 0) {
            return false;
        }
        var avail_idx: u16 = 0;
        if (!mem.read(
            q.driver_gpa +% bus.VIRTQ_RING_IDX_OFFSET,
            std.mem.asBytes(&avail_idx),
        )) return false;

        var delivered = false;
        var steps: u16 = 0;
        while (self.event_count > 0 and q.last_avail_idx != avail_idx and
            steps < q.num) : (steps += 1)
        {
            const slot = q.last_avail_idx % q.num;
            var head_idx: u16 = 0;
            const entry_off = bus.VIRTQ_RING_ELEMS_OFFSET +%
                (@as(u64, slot) *% @sizeOf(u16));
            if (!mem.read(
                q.driver_gpa +% entry_off,
                std.mem.asBytes(&head_idx),
            )) break;
            if (head_idx >= q.num) break;

            var desc: VirtqDesc = undefined;
            if (!mem.read(
                q.desc_gpa +% (@as(u64, head_idx) *% @sizeOf(VirtqDesc)),
                std.mem.asBytes(&desc),
            )) break;
            if ((desc.flags & bus.VIRTQ_DESC_F_WRITE) == 0 or
                desc.len < @sizeOf(VirtioInputEvent))
            {
                break;
            }

            const ev = self.event_queue[self.event_head];
            if (!mem.write(desc.addr, std.mem.asBytes(&ev))) break;
            self.event_head = (self.event_head + 1) % MAX_EVENTS_BUFFER;
            self.event_count -= 1;
            bus.pushVirtqUsed(mem, q, head_idx, @sizeOf(VirtioInputEvent));
            delivered = true;
        }
        return delivered;
    }

    pub fn pushEvent(
        self: *VirtioInput,
        event_type: u16,
        code: u16,
        value: u32,
    ) bool {
        self.acquireLock();
        defer self.releaseLock();

        if (self.event_count >= MAX_EVENTS_BUFFER) {
            self.event_head = (self.event_head + 1) % MAX_EVENTS_BUFFER;
            self.event_count -= 1;
        }
        self.event_queue[self.event_tail] = .{
            .type = event_type,
            .code = code,
            .value = value,
        };
        self.event_tail = (self.event_tail + 1) % MAX_EVENTS_BUFFER;
        self.event_count += 1;

        _ = self.flushEventsLocked();
        _ = self.interrupt_status.fetchOr(1, .release);
        return true;
    }
};

test "VirtIO Input register probe, config query, and eventq DMA delivery" {
    const testing = std.testing;
    testing.refAllDecls(@This());

    const GuestRam = struct {
        buf: [2048]u8 = @splat(0),
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
    var input = VirtioInput.initWithMem(
        2,
        .{ .ctx = &ram, .readFn = GuestRam.read, .writeFn = GuestRam.write },
    );

    try testing.expectEqual(VIRTIO_MAGIC, input.readReg(0x000));
    try testing.expectEqual(VIRTIO_VERSION, input.readReg(0x004));
    try testing.expectEqual(VIRTIO_ID_INPUT, input.readReg(0x008));
    try testing.expectEqual(VIRTIO_VENDOR_ID, input.readReg(0x00c));

    // Config Select: Name & ABS_INFO.
    input.writeReg(0x100, VIRTIO_INPUT_CFG_ID_NAME);
    try testing.expectEqual(
        VIRTIO_INPUT_CFG_ID_NAME,
        @as(u8, @truncate(input.readReg(0x100))),
    );
    try testing.expectEqual(
        @as(u8, 'D'),
        @as(u8, @truncate(input.readReg(0x108))),
    );
    input.writeConfigReg(
        0x100,
        VIRTIO_INPUT_CFG_ABS_INFO | (@as(u32, ABS_X) << 8),
        2,
    );
    try testing.expectEqual(ABS_MAX_COORD, input.readReg(0x10c));

    // Setup eventq (desc 0x000, avail 0x100, used 0x200, dst 0x300).
    input.queues[0] = .{
        .num = 8,
        .ready = true,
        .desc_gpa = 0x000,
        .driver_gpa = 0x100,
        .device_gpa = 0x200,
    };
    const d0 = VirtqDesc{
        .addr = 0x300,
        .len = @sizeOf(VirtioInputEvent),
        .flags = bus.VIRTQ_DESC_F_WRITE,
        .next = 0,
    };
    @memcpy(ram.buf[0x000..0x010], std.mem.asBytes(&d0));
    std.mem.writeInt(u16, ram.buf[0x102..0x104], 1, .little);
    std.mem.writeInt(u16, ram.buf[0x104..0x106], 0, .little);

    try testing.expect(input.pushEvent(EV_KEY, 30, 1));
    try testing.expectEqual(@as(u16, 1), input.queues[0].last_used_idx);
    var ev: VirtioInputEvent = undefined;
    @memcpy(std.mem.asBytes(&ev), ram.buf[0x300..0x308]);
    try testing.expectEqual(EV_KEY, ev.type);
    try testing.expectEqual(@as(u16, 30), ev.code);
    try testing.expectEqual(@as(u32, 1), ev.value);
}
