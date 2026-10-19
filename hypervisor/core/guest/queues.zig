// Asynchronous event, network packet, and PIT timer state for Guest VMs.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const atomic = @import("../atomic.zig");
const vm_space = @import("../vm.zig");
const guest_mod = @import("../guest.zig");
const sbi = @import("interface").sbi;

pub const max_events: usize = 32;
pub const MAX_PACKET_LEN: usize = 1536;
pub const MAX_NET_PACKETS: usize = 64;

pub const PIT_NUM_CHANNELS: usize = 3;
pub const PIT_BYTE_LSB: u2 = 1;
pub const PIT_BYTE_MSB: u2 = 2;
pub const PIT_ACCESS_LSB_MSB: u8 = 3;
pub const PIT_PORT61_GATE2_ENABLED: u8 = 0x01;
pub const PIC_ALL_IRQS_MASKED: u8 = 0xff;

pub const PitChannel = struct {
    latch: u16 = 0,
    count_latched: bool = false,
    latched_val: u16 = 0,
    // 0 = LSB, 1 = MSB.
    read_state: u8 = 0,
    write_state: u8 = 0,
    mode: u8 = 0,
    access: u8 = PIT_ACCESS_LSB_MSB,
    start_time: u64 = 0,
    period_ticks: u64 = 0,
    gate: u8 = 1,
};

pub const PitState = struct {
    channels: [PIT_NUM_CHANNELS]PitChannel = [_]PitChannel{ .{}, .{}, .{} },
    port_61: u8 = PIT_PORT61_GATE2_ENABLED,
    pic_master_imr: u8 = PIC_ALL_IRQS_MASKED,
    pic_slave_imr: u8 = PIC_ALL_IRQS_MASKED,
};

pub const EventQueue = struct {
    events: [max_events]sbi.Event = std.mem.zeroes([max_events]sbi.Event),
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    lock: atomic.SpinLock = atomic.SpinLock.init(),

    pub fn push(self: *EventQueue, ev: sbi.Event) void {
        const s = self.lock.lock();
        defer self.lock.unlock(s);
        if (self.count >= max_events) {
            self.tail = (self.tail + 1) % max_events;
            self.count -= 1;
        }
        self.events[self.head] = ev;
        self.head = (self.head + 1) % max_events;
        self.count += 1;
    }

    fn peekFilteredLocked(
        self: *const EventQueue,
        filter_cid: usize,
    ) ?sbi.Event {
        if (self.count == 0) return null;
        if (filter_cid == 0) return self.events[self.tail];
        for (0..self.count) |i| {
            const idx = (self.tail + i) % max_events;
            if (self.events[idx].cid == filter_cid) {
                return self.events[idx];
            }
        }
        return null;
    }

    pub fn peek(self: *EventQueue) ?sbi.Event {
        return self.peekFiltered(0);
    }

    pub fn peekFiltered(self: *EventQueue, filter_cid: usize) ?sbi.Event {
        const s = self.lock.lock();
        defer self.lock.unlock(s);
        return self.peekFilteredLocked(filter_cid);
    }

    fn popFilteredLocked(self: *EventQueue, filter_cid: usize) ?sbi.Event {
        if (self.count == 0) return null;
        if (filter_cid == 0) {
            const ev = self.events[self.tail];
            self.tail = (self.tail + 1) % max_events;
            self.count -= 1;
            return ev;
        }
        for (0..self.count) |i| {
            const idx = (self.tail + i) % max_events;
            if (self.events[idx].cid == filter_cid) {
                const found = self.events[idx];
                var j = i;
                while (j + 1 < self.count) : (j += 1) {
                    const cur_slot = (self.tail + j) % max_events;
                    const next_slot = (self.tail + j + 1) % max_events;
                    self.events[cur_slot] = self.events[next_slot];
                }
                self.head = (self.head + max_events - 1) % max_events;
                self.count -= 1;
                return found;
            }
        }
        return null;
    }

    pub fn pop(self: *EventQueue) ?sbi.Event {
        return self.popFiltered(0);
    }

    pub fn popFiltered(self: *EventQueue, filter_cid: usize) ?sbi.Event {
        const s = self.lock.lock();
        defer self.lock.unlock(s);
        return self.popFilteredLocked(filter_cid);
    }

    pub fn popIfWritten(
        self: *EventQueue,
        filter_cid: usize,
        g: *guest_mod.Guest,
        event_gpa: usize,
    ) !bool {
        const s = self.lock.lock();
        defer self.lock.unlock(s);

        const ev = self.peekFilteredLocked(filter_cid) orelse return false;
        try g.space.writeGuestStruct(sbi.Event, event_gpa, ev);
        _ = self.popFilteredLocked(filter_cid);
        return true;
    }

    pub fn getCount(self: *EventQueue) usize {
        const s = self.lock.lock();
        defer self.lock.unlock(s);
        return self.count;
    }
};

pub const Packet = struct {
    len: u16 = 0,
    data: [MAX_PACKET_LEN]u8 = undefined,
};

pub const PacketQueue = struct {
    packets: [MAX_NET_PACKETS]Packet = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    lock: atomic.SpinLock = atomic.SpinLock.init(),

    pub fn push(self: *PacketQueue, data: []const u8) bool {
        if (data.len == 0 or data.len > MAX_PACKET_LEN) return false;
        const s = self.lock.lock();
        defer self.lock.unlock(s);
        if (self.count >= MAX_NET_PACKETS) {
            // Drop oldest packet on overflow.
            self.tail = (self.tail + 1) % MAX_NET_PACKETS;
            self.count -= 1;
        }
        var pkt = &self.packets[self.head];
        pkt.len = @truncate(data.len);
        @memcpy(pkt.data[0..data.len], data);
        self.head = (self.head + 1) % MAX_NET_PACKETS;
        self.count += 1;
        return true;
    }

    pub fn pop(self: *PacketQueue, out_buf: []u8) ?usize {
        const s = self.lock.lock();
        defer self.lock.unlock(s);
        if (self.count == 0) return null;
        const pkt = &self.packets[self.tail];
        const copy_len: usize = @min(out_buf.len, @as(usize, pkt.len));
        @memcpy(out_buf[0..copy_len], pkt.data[0..copy_len]);
        self.tail = (self.tail + 1) % MAX_NET_PACKETS;
        self.count -= 1;
        return copy_len;
    }

    pub fn popToGuest(
        self: *PacketQueue,
        space: *vm_space.GuestSpace,
        gpa: usize,
        max_len: usize,
    ) !usize {
        const s = self.lock.lock();
        defer self.lock.unlock(s);
        if (self.count == 0) return 0;
        const pkt = &self.packets[self.tail];
        const copy_len: usize = @min(max_len, @as(usize, pkt.len));
        try space.copyToGuest(gpa, pkt.data[0..copy_len]);
        self.tail = (self.tail + 1) % MAX_NET_PACKETS;
        self.count -= 1;
        return copy_len;
    }

    pub fn getCount(self: *PacketQueue) usize {
        const s = self.lock.lock();
        defer self.lock.unlock(s);
        return self.count;
    }
};

test "EventQueue filtered polling by CID and PacketQueue FIFO semantics" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;

    var q = EventQueue{};
    q.push(.{ .cid = 10, .event_type = 1, .exit_code = 0 });
    q.push(.{ .cid = 20, .event_type = 2, .exit_code = 1 });
    q.push(.{ .cid = 30, .event_type = 3, .exit_code = 2 });
    try testing.expectEqual(@as(usize, 3), q.count);

    const peek20 = q.peekFiltered(20);
    try testing.expect(peek20 != null);
    try testing.expectEqual(@as(u64, 20), peek20.?.cid);
    try testing.expectEqual(@as(usize, 3), q.count);
    try testing.expect(q.peekFiltered(99) == null);

    const pop20 = q.popFiltered(20);
    try testing.expect(pop20 != null);
    try testing.expectEqual(@as(u64, 20), pop20.?.cid);
    try testing.expectEqual(@as(usize, 2), q.count);

    const pop10 = q.popFiltered(0);
    try testing.expectEqual(@as(u64, 10), pop10.?.cid);
    const pop30 = q.popFiltered(0);
    try testing.expectEqual(@as(u64, 30), pop30.?.cid);
    try testing.expect(q.popFiltered(0) == null);
    try testing.expectEqual(@as(usize, 0), q.count);

    var pq = PacketQueue{};
    try testing.expect(!pq.push(""));
    try testing.expect(pq.push("hello"));
    try testing.expectEqual(@as(usize, 1), pq.getCount());
    var out: [16]u8 = undefined;
    const n = pq.pop(&out).?;
    try testing.expectEqualStrings("hello", out[0..n]);
    try testing.expectEqual(@as(usize, 0), pq.getCount());
}
