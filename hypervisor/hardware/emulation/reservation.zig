// Two-Column Atomic LR/SC Reservation Table for Emulated Virtual Harts
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const STATIC_RESERVATION_HARTS: usize = 32;

pub const DynamicReservationNode = struct {
    hart_id: usize,
    reservation_addr: std.atomic.Value(usize),
    next: ?*DynamicReservationNode = null,
};

pub const ReservationRow = struct {
    static_addr: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    dynamic_head: ?*DynamicReservationNode = null,
};

/// Fixed-length two-column table managing LR/SC atomic reservations:
/// - Column 1: Static atomic reservations for harts 0..31.
/// - Column 2: Linked-list buckets for dynamic harts (bucket = hart_id % 32).
pub var reservation_table: [STATIC_RESERVATION_HARTS]ReservationRow = blk: {
    var arr: [STATIC_RESERVATION_HARTS]ReservationRow = undefined;
    for (&arr) |*elem| {
        elem.* = .{
            .static_addr = std.atomic.Value(usize).init(0),
            .dynamic_head = null,
        };
    }
    break :blk arr;
};

var dynamic_pool: [128]DynamicReservationNode = undefined;
var dynamic_pool_count: usize = 0;
var res_lock = std.atomic.Value(bool).init(false);

fn getOrCreateDynamicNode(hart_id: usize) ?*DynamicReservationNode {
    const bucket = hart_id % STATIC_RESERVATION_HARTS;
    var curr = reservation_table[bucket].dynamic_head;
    while (curr) |node| {
        if (node.hart_id == hart_id) return node;
        curr = node.next;
    }

    while (res_lock.swap(true, .acquire)) {
        std.atomic.spinLoopHint();
    }
    defer res_lock.store(false, .release);

    curr = reservation_table[bucket].dynamic_head;
    while (curr) |node| {
        if (node.hart_id == hart_id) return node;
        curr = node.next;
    }

    if (dynamic_pool_count < dynamic_pool.len) {
        const idx = dynamic_pool_count;
        dynamic_pool_count += 1;
        const node = &dynamic_pool[idx];
        node.hart_id = hart_id;
        node.reservation_addr = std.atomic.Value(usize).init(0);
        node.next = reservation_table[bucket].dynamic_head;
        reservation_table[bucket].dynamic_head = node;
        return node;
    }
    return null;
}

pub fn setReservation(hart_id: usize, paddr: usize) void {
    const line = paddr & ~@as(usize, 0x3f);
    if (hart_id < STATIC_RESERVATION_HARTS) {
        reservation_table[hart_id].static_addr.store(line, .release);
        return;
    }
    if (getOrCreateDynamicNode(hart_id)) |node| {
        node.reservation_addr.store(line, .release);
    }
}

pub fn checkAndClearReservation(hart_id: usize, paddr: usize) bool {
    const line = paddr & ~@as(usize, 0x3f);
    if (hart_id < STATIC_RESERVATION_HARTS) {
        const cur = reservation_table[hart_id].static_addr.swap(0, .acq_rel);
        return (cur == line and line != 0);
    }
    const bucket = hart_id % STATIC_RESERVATION_HARTS;
    var curr = reservation_table[bucket].dynamic_head;
    while (curr) |node| {
        if (node.hart_id == hart_id) {
            const cur = node.reservation_addr.swap(0, .acq_rel);
            return (cur == line and line != 0);
        }
        curr = node.next;
    }
    return false;
}

pub fn clearReservation(hart_id: usize) void {
    if (hart_id < STATIC_RESERVATION_HARTS) {
        reservation_table[hart_id].static_addr.store(0, .monotonic);
        return;
    }
    const bucket = hart_id % STATIC_RESERVATION_HARTS;
    var curr = reservation_table[bucket].dynamic_head;
    while (curr) |node| {
        if (node.hart_id == hart_id) {
            node.reservation_addr.store(0, .monotonic);
            return;
        }
        curr = node.next;
    }
}

pub fn invalidateReservations(paddr: usize) void {
    const line = paddr & ~@as(usize, 0x3f);
    // Column 1: static reservations 0..31.
    for (0..STATIC_RESERVATION_HARTS) |i| {
        if (reservation_table[i].static_addr.load(.monotonic) == line) {
            reservation_table[i].static_addr.store(0, .monotonic);
        }
    }
    // Column 2: dynamic linked-list buckets.
    for (0..STATIC_RESERVATION_HARTS) |b| {
        var curr = reservation_table[b].dynamic_head;
        while (curr) |node| {
            if (node.reservation_addr.load(.monotonic) == line) {
                node.reservation_addr.store(0, .monotonic);
            }
            curr = node.next;
        }
    }
}

pub fn resetReservations() void {
    for (0..STATIC_RESERVATION_HARTS) |i| {
        reservation_table[i].static_addr.store(0, .monotonic);
        reservation_table[i].dynamic_head = null;
    }
    dynamic_pool_count = 0;
}

test "Dynamic atomic reservations with two-column table and collisions" {
    const testing = std.testing;

    resetReservations();
    defer resetReservations();

    const test_paddr: usize = 0x80201040;

    // 1. Test static harts 0..31 (e.g. hart 7 and hart 31).
    setReservation(7, test_paddr);
    try testing.expect(checkAndClearReservation(7, test_paddr));
    try testing.expect(!checkAndClearReservation(7, test_paddr));

    setReservation(31, test_paddr);
    try testing.expect(checkAndClearReservation(31, test_paddr));

    // 2. Test dynamic harts >= 32 (both 38 and 70 hash to bucket 6).
    setReservation(38, test_paddr);
    setReservation(70, test_paddr + 0x40);

    try testing.expect(checkAndClearReservation(38, test_paddr));
    try testing.expect(checkAndClearReservation(70, test_paddr + 0x40));
    try testing.expect(!checkAndClearReservation(38, test_paddr));
    try testing.expect(!checkAndClearReservation(70, test_paddr + 0x40));

    // 3. Test cross-core invalidation on the same 64B cache line.
    setReservation(5, test_paddr);
    setReservation(38, test_paddr);
    setReservation(70, test_paddr + 0x40); // Different cache line.

    invalidateReservations(test_paddr + 0x10);

    try testing.expect(!checkAndClearReservation(5, test_paddr));
    try testing.expect(!checkAndClearReservation(38, test_paddr));
    try testing.expect(checkAndClearReservation(70, test_paddr + 0x40));

    // 4. Test clearReservation.
    setReservation(50, test_paddr);
    clearReservation(50);
    try testing.expect(!checkAndClearReservation(50, test_paddr));
}
