// GDB software breakpoint table and target architecture XML definitions.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const vcore = @import("../vcore.zig");

pub const X86_64_TARGET_XML =
    \\<?xml version="1.0"?>
    \\<!DOCTYPE target SYSTEM "gdb-target.dtd">
    \\<target version="1.0">
    \\  <architecture>i386:x86-64</architecture>
    \\  <feature name="org.gnu.gdb.i386.64bit">
    \\    <reg name="rax" bitsize="64" type="int64"/>
    \\    <reg name="rbx" bitsize="64" type="int64"/>
    \\    <reg name="rcx" bitsize="64" type="int64"/>
    \\    <reg name="rdx" bitsize="64" type="int64"/>
    \\    <reg name="rsi" bitsize="64" type="int64"/>
    \\    <reg name="rdi" bitsize="64" type="int64"/>
    \\    <reg name="rbp" bitsize="64" type="data_ptr"/>
    \\    <reg name="rsp" bitsize="64" type="data_ptr"/>
    \\    <reg name="r8"  bitsize="64" type="int64"/>
    \\    <reg name="r9"  bitsize="64" type="int64"/>
    \\    <reg name="r10" bitsize="64" type="int64"/>
    \\    <reg name="r11" bitsize="64" type="int64"/>
    \\    <reg name="r12" bitsize="64" type="int64"/>
    \\    <reg name="r13" bitsize="64" type="int64"/>
    \\    <reg name="r14" bitsize="64" type="int64"/>
    \\    <reg name="r15" bitsize="64" type="int64"/>
    \\    <reg name="rip" bitsize="64" type="code_ptr"/>
    \\    <reg name="eflags" bitsize="32" type="int32"/>
    \\    <reg name="cs" bitsize="32" type="int32"/>
    \\    <reg name="ss" bitsize="32" type="int32"/>
    \\    <reg name="ds" bitsize="32" type="int32"/>
    \\    <reg name="es" bitsize="32" type="int32"/>
    \\    <reg name="fs" bitsize="32" type="int32"/>
    \\    <reg name="gs" bitsize="32" type="int32"/>
    \\  </feature>
    \\</target>
;

pub const STATIC_BREAKPOINTS: usize = 32;
pub const DYNAMIC_HASH_BUCKETS: usize = 32;
pub const MAX_DYNAMIC_BREAKPOINTS: usize = 1024;
const INT3_OPCODE: u8 = 0xcc;

pub const SwBreakpoint = struct {
    addr: u64 = 0,
    orig_byte: u8 = 0,
    active: bool = false,
    next: ?*SwBreakpoint = null,
};

pub const BreakpointTable = struct {
    // Column 1: Fast-path static array for first 32 breakpoints.
    static_slots: [STATIC_BREAKPOINTS]SwBreakpoint = @splat(.{}),
    // Column 2: Dynamic hash buckets for overflow breakpoints.
    dynamic_buckets: [DYNAMIC_HASH_BUCKETS]?*SwBreakpoint = @splat(null),
    dynamic_pool: [MAX_DYNAMIC_BREAKPOINTS]SwBreakpoint = @splat(.{}),
    dynamic_count: usize = 0,

    pub fn bucketIndex(addr: u64) usize {
        return @intCast((addr >> 2) % DYNAMIC_HASH_BUCKETS);
    }

    pub fn reset(self: *BreakpointTable) void {
        for (&self.static_slots) |*bp| bp.* = .{};
        self.dynamic_buckets = @splat(null);
        self.dynamic_count = 0;
    }

    pub fn find(self: *BreakpointTable, addr: u64) ?*SwBreakpoint {
        for (&self.static_slots) |*bp| {
            if (bp.active and bp.addr == addr) return bp;
        }
        const bucket = bucketIndex(addr);
        var curr = self.dynamic_buckets[bucket];
        while (curr) |bp| : (curr = bp.next) {
            if (bp.active and bp.addr == addr) return bp;
        }
        return null;
    }

    pub fn allocate(
        self: *BreakpointTable,
        addr: u64,
        orig_byte: u8,
    ) ?*SwBreakpoint {
        if (self.find(addr) != null) return null;

        for (&self.static_slots) |*bp| {
            if (!bp.active) {
                bp.* = .{
                    .addr = addr,
                    .orig_byte = orig_byte,
                    .active = true,
                    .next = null,
                };
                return bp;
            }
        }

        const bucket = bucketIndex(addr);
        var curr = self.dynamic_buckets[bucket];
        while (curr) |bp| : (curr = bp.next) {
            if (!bp.active) {
                bp.addr = addr;
                bp.orig_byte = orig_byte;
                bp.active = true;
                return bp;
            }
        }

        if (self.dynamic_count < self.dynamic_pool.len) {
            const bp = &self.dynamic_pool[self.dynamic_count];
            self.dynamic_count += 1;
            bp.* = .{
                .addr = addr,
                .orig_byte = orig_byte,
                .active = true,
                .next = self.dynamic_buckets[bucket],
            };
            self.dynamic_buckets[bucket] = bp;
            return bp;
        }

        return null;
    }
};

pub var sw_breakpoints: BreakpointTable = .{};

fn readByte(vc: *vcore.VirtualCore, addr: u64) ?u8 {
    const target_gpa: usize = std.math.cast(usize, addr) orelse return null;
    var b: [1]u8 = undefined;
    vc.guest.space.copyFromGuest(&b, target_gpa) catch return null;
    return b[0];
}

fn writeByte(vc: *vcore.VirtualCore, addr: u64, val: u8) bool {
    const target_gpa: usize = std.math.cast(usize, addr) orelse return false;
    const b = [1]u8{val};
    vc.guest.space.copyToGuest(target_gpa, &b) catch return false;
    return true;
}

pub fn insertSwBreakpoint(active_vc: ?*vcore.VirtualCore, addr: u64) bool {
    const vc = active_vc orelse return false;
    if (vc.exec_path != .emulated) return false;

    if (sw_breakpoints.find(addr) != null) return true;

    const orig = readByte(vc, addr) orelse return false;
    const bp = sw_breakpoints.allocate(addr, orig) orelse return false;
    if (!writeByte(vc, addr, INT3_OPCODE)) {
        bp.active = false;
        return false;
    }
    return true;
}

pub fn removeSwBreakpoint(active_vc: ?*vcore.VirtualCore, addr: u64) bool {
    const vc = active_vc orelse return false;
    if (vc.exec_path != .emulated) return false;
    if (sw_breakpoints.find(addr)) |bp| {
        _ = writeByte(vc, addr, bp.orig_byte);
        bp.active = false;
        return true;
    }
    return false;
}

pub fn removeAllBreakpoints(active_vc: ?*vcore.VirtualCore) void {
    const vc = active_vc orelse return;
    if (vc.exec_path != .emulated) return;
    for (&sw_breakpoints.static_slots) |*bp| {
        if (bp.active) {
            _ = writeByte(vc, bp.addr, bp.orig_byte);
            bp.active = false;
        }
    }
    for (sw_breakpoints.dynamic_buckets) |head| {
        var curr = head;
        while (curr) |bp| : (curr = bp.next) {
            if (bp.active) {
                _ = writeByte(vc, bp.addr, bp.orig_byte);
                bp.active = false;
            }
        }
    }
}

test "GDB RSP BreakpointTable static and dynamic hash buckets" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    var table = BreakpointTable{};

    var i: u64 = 0;
    while (i < STATIC_BREAKPOINTS) : (i += 1) {
        const addr = 0x1000 + i * 4;
        const bp = table.allocate(addr, @as(u8, @intCast(i & 0xff)));
        try testing.expect(bp != null);
        try testing.expectEqual(addr, bp.?.addr);
        try testing.expectEqual(@as(u8, @intCast(i & 0xff)), bp.?.orig_byte);
    }

    i = 0;
    while (i < STATIC_BREAKPOINTS) : (i += 1) {
        const addr = 0x1000 + i * 4;
        const bp = table.find(addr);
        try testing.expect(bp != null);
        try testing.expectEqual(addr, bp.?.addr);
    }

    try testing.expect(table.allocate(0x1000, 0xaa) == null);

    const dyn_addr1: u64 = 0x8000;
    const dyn_bp1 = table.allocate(dyn_addr1, 0x11);
    try testing.expect(dyn_bp1 != null);
    try testing.expectEqual(dyn_addr1, dyn_bp1.?.addr);
    try testing.expectEqual(@as(usize, 1), table.dynamic_count);

    const dyn_addr2: u64 = 0x8080;
    const dyn_bp2 = table.allocate(dyn_addr2, 0x22);
    try testing.expect(dyn_bp2 != null);
    try testing.expectEqual(dyn_addr2, dyn_bp2.?.addr);
    try testing.expectEqual(@as(usize, 2), table.dynamic_count);

    try testing.expect(table.find(dyn_addr1) != null);
    try testing.expect(table.find(dyn_addr2) != null);

    dyn_bp1.?.active = false;
    try testing.expect(table.find(dyn_addr1) == null);

    const dyn_realloc = table.allocate(dyn_addr1, 0x33);
    try testing.expect(dyn_realloc != null);
    try testing.expectEqual(@as(usize, 2), table.dynamic_count);

    table.reset();
    try testing.expectEqual(@as(usize, 0), table.dynamic_count);
    try testing.expect(table.find(0x1000) == null);
    try testing.expect(table.find(dyn_addr1) == null);
}
