// VirtIO-Input (Keyboard & Pointer Device) Emulation
// Implements VirtIO 1.1 / 1.2 Device ID 18 (VIRTIO_ID_INPUT) for standard evdev input handling.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

const bus = @import("bus.zig");

pub const VIRTIO_ID_INPUT: u32 = 18;
pub const VIRTIO_VENDOR_ID: u32 = 0x554d4551; // "QEMU" / Standard VirtIO
pub const VIRTIO_MAGIC: u32 = 0x74726976; // "virt"
pub const VIRTIO_VERSION: u32 = 2; // Modern VirtIO

pub const QUEUE_SIZE_MAX: u16 = 64;
pub const NUM_QUEUES: usize = 2; // 0 = eventq, 1 = statusq

// VirtIO Input Config Selectors
pub const VIRTIO_INPUT_CFG_UNSET: u8 = 0x00;
pub const VIRTIO_INPUT_CFG_ID_NAME: u8 = 0x01;
pub const VIRTIO_INPUT_CFG_ID_SERIAL: u8 = 0x02;
pub const VIRTIO_INPUT_CFG_ID_DEVIDS: u8 = 0x03;
pub const VIRTIO_INPUT_CFG_PROP_BITS: u8 = 0x10;
pub const VIRTIO_INPUT_CFG_EV_BITS: u8 = 0x11;
pub const VIRTIO_INPUT_CFG_ABS_INFO: u8 = 0x12;

// VirtIO-Input config register offsets within MMIO
pub const REG_INPUT_CFG_SELECT: u32 = bus.VIRTIO_MMIO_REG_CONFIG_BASE;
pub const REG_INPUT_CFG_SUBSEL: u32 = bus.VIRTIO_MMIO_REG_CONFIG_BASE + 1;
pub const REG_INPUT_CFG_SIZE: u32 = bus.VIRTIO_MMIO_REG_CONFIG_BASE + 2;
pub const REG_INPUT_CFG_DATA_START: u32 = bus.VIRTIO_MMIO_REG_CONFIG_BASE + 8;
pub const REG_INPUT_CFG_DATA_SIZE: u32 = 128;
pub const REG_INPUT_CFG_DATA_END: u32 = REG_INPUT_CFG_DATA_START + REG_INPUT_CFG_DATA_SIZE;

// Standard Linux evdev Event Types
pub const EV_SYN: u16 = 0x00;
pub const EV_KEY: u16 = 0x01;
pub const EV_REL: u16 = 0x02;
pub const EV_ABS: u16 = 0x03;

pub const VirtioInputEvent = extern struct {
    type: u16,
    code: u16,
    value: u32,
};

pub const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
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

pub const MAX_EVENTS_BUFFER: usize = 128;

pub const VirtioInput = struct {
    guest_cid: usize = 0,
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

    pub fn init(guest_cid: usize) VirtioInput {
        return .{
            .guest_cid = guest_cid,
        };
    }

    pub fn readReg(self: *VirtioInput, offset: u32) u32 {
        return switch (offset) {
            bus.VIRTIO_MMIO_REG_MAGIC_VALUE => VIRTIO_MAGIC,
            bus.VIRTIO_MMIO_REG_VERSION => VIRTIO_VERSION,
            bus.VIRTIO_MMIO_REG_DEVICE_ID => VIRTIO_ID_INPUT,
            bus.VIRTIO_MMIO_REG_VENDOR_ID => VIRTIO_VENDOR_ID,
            bus.VIRTIO_MMIO_REG_DEVICE_FEATURES => blk: {
                if (self.device_features_sel == 0) {
                    break :blk 0;
                } else if (self.device_features_sel == 1) {
                    break :blk 1; // VIRTIO_F_VERSION_1
                }
                break :blk 0;
            },
            bus.VIRTIO_MMIO_REG_QUEUE_NUM_MAX => if (self.queue_sel < NUM_QUEUES) QUEUE_SIZE_MAX else 0,
            bus.VIRTIO_MMIO_REG_QUEUE_READY => if (self.queue_sel < NUM_QUEUES and self.queues[self.queue_sel].ready) 1 else 0,
            bus.VIRTIO_MMIO_REG_INTERRUPT_STATUS => self.interrupt_status.load(.acquire),
            bus.VIRTIO_MMIO_REG_STATUS => self.status,
            // Config space
            REG_INPUT_CFG_SELECT => self.cfg_select,
            REG_INPUT_CFG_SUBSEL => self.cfg_subsel,
            REG_INPUT_CFG_SIZE => @truncate(self.getConfigSize()),
            else => blk: {
                if (offset >= REG_INPUT_CFG_DATA_START and offset < REG_INPUT_CFG_DATA_END) {
                    const byte_idx = offset - REG_INPUT_CFG_DATA_START;
                    break :blk self.readConfigData(byte_idx);
                }
                break :blk 0;
            },
        };
    }

    pub fn writeReg(self: *VirtioInput, offset: u32, val: u32) void {
        switch (offset) {
            bus.VIRTIO_MMIO_REG_DEVICE_FEATURES_SEL => self.device_features_sel = val,
            bus.VIRTIO_MMIO_REG_DRIVER_FEATURES => {
                if (self.driver_features_sel == 0) {
                    self.driver_features = (self.driver_features & 0xFFFFFFFF00000000) | val;
                } else {
                    self.driver_features = (self.driver_features & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
                }
            },
            bus.VIRTIO_MMIO_REG_DRIVER_FEATURES_SEL => self.driver_features_sel = val,
            bus.VIRTIO_MMIO_REG_QUEUE_SEL => self.queue_sel = val,
            bus.VIRTIO_MMIO_REG_QUEUE_NUM => {
                if (self.queue_sel < NUM_QUEUES) {
                    const q_num = @min(val, QUEUE_SIZE_MAX);
                    self.queues[self.queue_sel].num = @truncate(if (q_num > 0) q_num else 1);
                }
            },
            bus.VIRTIO_MMIO_REG_QUEUE_READY => {
                if (self.queue_sel < NUM_QUEUES) {
                    self.queues[self.queue_sel].ready = (val & 1) != 0 and self.queues[self.queue_sel].num > 0;
                }
            },
            bus.VIRTIO_MMIO_REG_QUEUE_NOTIFY => {
                const q_idx = val;
                if (q_idx == 0) {
                    while (self.lock.swap(true, .acquire)) {
                        std.atomic.spinLoopHint();
                    }
                    const has_pending = self.event_count > 0;
                    self.lock.store(false, .release);
                    if (has_pending) {
                        _ = self.interrupt_status.fetchOr(1, .release);
                    }
                }
            },
            bus.VIRTIO_MMIO_REG_INTERRUPT_ACK => _ = self.interrupt_status.fetchAnd(~val, .release),
            bus.VIRTIO_MMIO_REG_STATUS => {
                self.status = val;
                if (val == 0) {
                    self.reset();
                }
            },
            bus.VIRTIO_MMIO_REG_QUEUE_DESC_LOW => {
                if (self.queue_sel < NUM_QUEUES) self.queues[self.queue_sel].desc_gpa = (self.queues[self.queue_sel].desc_gpa & 0xFFFFFFFF00000000) | val;
            },
            bus.VIRTIO_MMIO_REG_QUEUE_DESC_HIGH => {
                if (self.queue_sel < NUM_QUEUES) self.queues[self.queue_sel].desc_gpa = (self.queues[self.queue_sel].desc_gpa & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
            },
            bus.VIRTIO_MMIO_REG_QUEUE_DRIVER_LOW => {
                if (self.queue_sel < NUM_QUEUES) self.queues[self.queue_sel].driver_gpa = (self.queues[self.queue_sel].driver_gpa & 0xFFFFFFFF00000000) | val;
            },
            bus.VIRTIO_MMIO_REG_QUEUE_DRIVER_HIGH => {
                if (self.queue_sel < NUM_QUEUES) self.queues[self.queue_sel].driver_gpa = (self.queues[self.queue_sel].driver_gpa & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
            },
            bus.VIRTIO_MMIO_REG_QUEUE_DEVICE_LOW => {
                if (self.queue_sel < NUM_QUEUES) self.queues[self.queue_sel].device_gpa = (self.queues[self.queue_sel].device_gpa & 0xFFFFFFFF00000000) | val;
            },
            bus.VIRTIO_MMIO_REG_QUEUE_DEVICE_HIGH => {
                if (self.queue_sel < NUM_QUEUES) self.queues[self.queue_sel].device_gpa = (self.queues[self.queue_sel].device_gpa & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
            },
            REG_INPUT_CFG_SELECT => self.cfg_select = @truncate(val),
            REG_INPUT_CFG_SUBSEL => self.cfg_subsel = @truncate(val),
            else => {},
        }
    }

    pub fn reset(self: *VirtioInput) void {
        while (self.lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer self.lock.store(false, .release);

        self.status = 0;
        self.interrupt_status.store(0, .release);
        self.event_head = 0;
        self.event_tail = 0;
        self.event_count = 0;
        for (&self.queues) |*q| {
            q.* = .{};
        }
    }

    pub fn getConfigSize(self: *const VirtioInput) usize {
        return switch (self.cfg_select) {
            VIRTIO_INPUT_CFG_ID_NAME => self.device_name.len,
            VIRTIO_INPUT_CFG_EV_BITS => 8,
            else => 0,
        };
    }

    pub fn readConfigData(self: *const VirtioInput, byte_idx: u32) u32 {
        switch (self.cfg_select) {
            VIRTIO_INPUT_CFG_ID_NAME => {
                if (byte_idx < self.device_name.len) {
                    return self.device_name[byte_idx];
                }
            },
            VIRTIO_INPUT_CFG_EV_BITS => {
                if (self.cfg_subsel == EV_KEY and byte_idx == 0) {
                    return 0xFF; // Support keys
                }
            },
            else => {},
        }
        return 0;
    }

    pub fn pushEvent(self: *VirtioInput, event_type: u16, code: u16, value: u32) bool {
        while (self.lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer self.lock.store(false, .release);

        if (self.event_count >= MAX_EVENTS_BUFFER) {
            // Drop oldest event on buffer overflow to keep input responsive
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
        _ = self.interrupt_status.fetchOr(1, .release);
        return true;
    }

    pub fn popEvent(self: *VirtioInput) ?VirtioInputEvent {
        while (self.lock.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        defer self.lock.store(false, .release);

        if (self.event_count == 0) return null;
        const ev = self.event_queue[self.event_head];
        self.event_head = (self.event_head + 1) % MAX_EVENTS_BUFFER;
        self.event_count -= 1;
        return ev;
    }
};

test "VirtIO Input register probe, config query, and event queueing" {
    const testing = std.testing;

    var input = VirtioInput.init(2);

    try testing.expectEqual(VIRTIO_MAGIC, input.readReg(0x000));
    try testing.expectEqual(VIRTIO_VERSION, input.readReg(0x004));
    try testing.expectEqual(VIRTIO_ID_INPUT, input.readReg(0x008));
    try testing.expectEqual(VIRTIO_VENDOR_ID, input.readReg(0x00c));

    // Test Config Select: Name
    input.writeReg(0x100, VIRTIO_INPUT_CFG_ID_NAME);
    try testing.expectEqual(VIRTIO_INPUT_CFG_ID_NAME, input.readReg(0x100));
    try testing.expectEqual(input.device_name.len, input.readReg(0x102));
    try testing.expectEqual(@as(u32, 'D'), input.readReg(0x108));

    // Test Event Push and Pop
    try testing.expect(input.pushEvent(EV_KEY, 30, 1)); // 'A' key press
    try testing.expect(input.pushEvent(EV_SYN, 0, 0));  // Sync event

    const ev1 = input.popEvent().?;
    try testing.expectEqual(EV_KEY, ev1.type);
    try testing.expectEqual(@as(u16, 30), ev1.code);
    try testing.expectEqual(@as(u32, 1), ev1.value);

    const ev2 = input.popEvent().?;
    try testing.expectEqual(EV_SYN, ev2.type);
    try testing.expect(input.popEvent() == null);

    // Test QueueNumMax behavior
    input.writeReg(bus.VIRTIO_MMIO_REG_QUEUE_SEL, 0);
    try testing.expectEqual(QUEUE_SIZE_MAX, input.readReg(bus.VIRTIO_MMIO_REG_QUEUE_NUM_MAX));
    input.writeReg(bus.VIRTIO_MMIO_REG_QUEUE_SEL, 99); // Out-of-bounds queue
    try testing.expectEqual(@as(u32, 0), input.readReg(bus.VIRTIO_MMIO_REG_QUEUE_NUM_MAX));

    // Test Queue Notify doorbell with pending event
    input.interrupt_status.store(0, .release);
    try testing.expect(input.pushEvent(EV_KEY, 1, 1));
    input.interrupt_status.store(0, .release); // Clear it to verify notify triggers it
    input.writeReg(bus.VIRTIO_MMIO_REG_QUEUE_NOTIFY, 0);
    try testing.expectEqual(@as(u32, 1), input.interrupt_status.load(.acquire) & 1);

    // Test buffer overflow resilience: fill beyond MAX_EVENTS_BUFFER (128)
    // Drain existing event
    _ = input.popEvent();
    var idx: u16 = 0;
    while (idx < MAX_EVENTS_BUFFER + 5) : (idx += 1) {
        try testing.expect(input.pushEvent(EV_KEY, idx, 1));
    }
    try testing.expectEqual(MAX_EVENTS_BUFFER, input.event_count);
    // Oldest 5 events (0..4) should have been dropped; head should be 5
    const head_ev = input.popEvent().?;
    try testing.expectEqual(@as(u16, 5), head_ev.code);
}
