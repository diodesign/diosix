// VirtIO-Input (Keyboard & Pointer Device) Emulation
// Implements VirtIO 1.1 / 1.2 Device ID 18 (VIRTIO_ID_INPUT) for standard evdev input handling.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

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

pub const MAX_EVENTS_BUFFER: usize = 32;

pub const VirtioInput = struct {
    guest_cid: usize = 0,
    status: u32 = 0,
    device_features_sel: u32 = 0,
    driver_features_sel: u32 = 0,
    driver_features: u64 = 0,
    queue_sel: u32 = 0,
    interrupt_status: u32 = 0,

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
            0x000 => VIRTIO_MAGIC,
            0x004 => VIRTIO_VERSION,
            0x008 => VIRTIO_ID_INPUT,
            0x00c => VIRTIO_VENDOR_ID,
            0x010 => blk: {
                if (self.device_features_sel == 0) {
                    break :blk 0;
                } else if (self.device_features_sel == 1) {
                    break :blk 1; // VIRTIO_F_VERSION_1
                }
                break :blk 0;
            },
            0x034 => QUEUE_SIZE_MAX,
            0x044 => if (self.queue_sel < NUM_QUEUES and self.queues[self.queue_sel].ready) 1 else 0,
            0x060 => self.interrupt_status,
            0x070 => self.status,
            // Config space starts at 0x100
            0x100 => self.cfg_select,
            0x101 => self.cfg_subsel,
            0x102 => @truncate(self.getConfigSize()),
            else => blk: {
                if (offset >= 0x108 and offset < 0x188) {
                    const byte_idx = offset - 0x108;
                    break :blk self.readConfigData(byte_idx);
                }
                break :blk 0;
            },
        };
    }

    pub fn writeReg(self: *VirtioInput, offset: u32, val: u32) void {
        switch (offset) {
            0x014 => self.device_features_sel = val,
            0x020 => {
                if (self.driver_features_sel == 0) {
                    self.driver_features = (self.driver_features & 0xFFFFFFFF00000000) | val;
                } else {
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
            0x064 => self.interrupt_status &= ~val,
            0x070 => {
                self.status = val;
                if (val == 0) {
                    self.reset();
                }
            },
            0x080 => {
                if (self.queue_sel < NUM_QUEUES) self.queues[self.queue_sel].desc_gpa = (self.queues[self.queue_sel].desc_gpa & 0xFFFFFFFF00000000) | val;
            },
            0x084 => {
                if (self.queue_sel < NUM_QUEUES) self.queues[self.queue_sel].desc_gpa = (self.queues[self.queue_sel].desc_gpa & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
            },
            0x090 => {
                if (self.queue_sel < NUM_QUEUES) self.queues[self.queue_sel].driver_gpa = (self.queues[self.queue_sel].driver_gpa & 0xFFFFFFFF00000000) | val;
            },
            0x094 => {
                if (self.queue_sel < NUM_QUEUES) self.queues[self.queue_sel].driver_gpa = (self.queues[self.queue_sel].driver_gpa & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
            },
            0x0a0 => {
                if (self.queue_sel < NUM_QUEUES) self.queues[self.queue_sel].device_gpa = (self.queues[self.queue_sel].device_gpa & 0xFFFFFFFF00000000) | val;
            },
            0x0a4 => {
                if (self.queue_sel < NUM_QUEUES) self.queues[self.queue_sel].device_gpa = (self.queues[self.queue_sel].device_gpa & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
            },
            0x100 => self.cfg_select = @truncate(val),
            0x101 => self.cfg_subsel = @truncate(val),
            else => {},
        }
    }

    pub fn reset(self: *VirtioInput) void {
        self.status = 0;
        self.interrupt_status = 0;
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
        if (self.event_count >= MAX_EVENTS_BUFFER) return false;
        self.event_queue[self.event_tail] = .{
            .type = event_type,
            .code = code,
            .value = value,
        };
        self.event_tail = (self.event_tail + 1) % MAX_EVENTS_BUFFER;
        self.event_count += 1;
        self.interrupt_status |= 1;
        return true;
    }

    pub fn popEvent(self: *VirtioInput) ?VirtioInputEvent {
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
}
