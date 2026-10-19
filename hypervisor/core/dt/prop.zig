// Device tree property types, wire-format constants, and byte-level helpers.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DeviceTreeError = error{
    CannotConvert,
    BadMagic,
    UnsupportedVersion,
    ReachedEnd,
    ReachedUnexpectedEnd,
    BadAlignment,
    SkippedToken,
    BadToken,
    MissingRootNode,
    NotFound,
    WidthUnsupported,
    OutOfBoundsWrite,
};

pub const LastSupportedVersion: u32 = 16;
pub const DtbVersion: u32 = 17;

pub const FdtBeginNode: u32 = 0x00000001;
pub const FdtEndNode: u32 = 0x00000002;
pub const FdtProp: u32 = 0x00000003;
pub const FdtNop: u32 = 0x00000004;
pub const FdtEnd: u32 = 0x00000009;

pub const DtbMagic: u32 = 0xd00dfeed;
pub const MaxDtbSize: u32 = 16 * 1024 * 1024; // 16 MiB upper bound.

pub const DefaultAddressCells: usize = 2;
pub const DefaultSizeCells: usize = 1;

// Advance to the next u32 boundary (always moves forward by at least 1 byte).
pub inline fn alignToNextU32(address: usize) usize {
    return std.mem.alignBackward(usize, address, @alignOf(u32)) + @sizeOf(u32);
}

// Round up to the nearest u32 boundary (no-op if already aligned).
pub inline fn alignUpU32(address: usize) usize {
    return std.mem.alignForward(usize, address, @alignOf(u32));
}

pub inline fn isAlignedU32(address: usize) bool {
    return (address & (@alignOf(u32) - 1)) == 0;
}

// Read a big-endian u32 from an unmanaged byte pointer at a byte offset.
pub inline fn readU32(src: [*]const u8, offset: usize) !u32 {
    const target_ptr = src + offset;
    const addr = @intFromPtr(target_ptr);
    if (!isAlignedU32(addr)) {
        return DeviceTreeError.BadAlignment;
    }
    const word: *const u32 = @ptrFromInt(addr);
    return std.mem.bigToNative(u32, word.*);
}

pub inline fn readBeU32(data: []const u8) u32 {
    return std.mem.readInt(u32, data[0..@sizeOf(u32)], .big);
}

pub inline fn readBeU64(data: []const u8) u64 {
    return std.mem.readInt(u64, data[0..@sizeOf(u64)], .big);
}

pub fn countChar(s: []const u8, c: u8) usize {
    var n: usize = 0;
    for (s) |ch| {
        if (ch == c) n += 1;
    }
    return n;
}

// Dynamic big-endian byte buffer for DTB blob serialization.
pub const ByteWriter = struct {
    buffer: []u8,
    len: usize,
    allocator: Allocator,

    const initial_capacity = 4096;

    pub fn init(allocator: Allocator) !ByteWriter {
        return .{
            .buffer = try allocator.alloc(u8, initial_capacity),
            .len = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ByteWriter) void {
        self.allocator.free(self.buffer);
    }

    pub fn ensureCapacity(self: *ByteWriter, additional: usize) !void {
        const needed = try std.math.add(usize, self.len, additional);
        if (needed <= self.buffer.len) return;
        var new_cap = self.buffer.len;
        while (new_cap < needed) {
            new_cap = try std.math.mul(usize, new_cap, 2);
        }
        const new_buf = try self.allocator.alloc(u8, new_cap);
        @memcpy(new_buf[0..self.len], self.buffer[0..self.len]);
        self.allocator.free(self.buffer);
        self.buffer = new_buf;
    }

    pub fn addU32(self: *ByteWriter, value: u32) !void {
        try self.ensureCapacity(4);
        std.mem.writeInt(u32, self.buffer[self.len..][0..4], value, .big);
        self.len += 4;
    }

    pub fn addU64(self: *ByteWriter, value: u64) !void {
        try self.ensureCapacity(8);
        std.mem.writeInt(u64, self.buffer[self.len..][0..8], value, .big);
        self.len += 8;
    }

    pub fn addU8(self: *ByteWriter, value: u8) !void {
        try self.ensureCapacity(1);
        self.buffer[self.len] = value;
        self.len += 1;
    }

    pub fn addBytes(self: *ByteWriter, data: []const u8) !void {
        try self.ensureCapacity(data.len);
        @memcpy(self.buffer[self.len .. self.len + data.len], data);
        self.len += data.len;
    }

    pub fn addNullTermString(self: *ByteWriter, s: []const u8) !void {
        try self.addBytes(s);
        try self.addU8(0);
    }

    pub fn padToU32(self: *ByteWriter) !void {
        while (!isAlignedU32(self.len)) {
            try self.addU8(0);
        }
    }

    pub fn alterU32(self: *ByteWriter, offset: usize, value: u32) !void {
        const end = std.math.add(usize, offset, 4) catch
            return DeviceTreeError.OutOfBoundsWrite;
        if (end > self.len) return DeviceTreeError.OutOfBoundsWrite;
        std.mem.writeInt(u32, self.buffer[offset..][0..4], value, .big);
    }

    pub fn offset32(self: *const ByteWriter) u32 {
        return @intCast(self.len);
    }

    // Return a right-sized owned slice and release the internal buffer.
    pub fn toOwnedSlice(self: *ByteWriter) ![]u8 {
        const result = try self.allocator.alloc(u8, self.len);
        @memcpy(result, self.buffer[0..self.len]);
        self.allocator.free(self.buffer);
        self.buffer = @constCast(&[0]u8{});
        self.len = 0;
        return result;
    }
};

pub const ReservedMemoryEntry = struct {
    address: u64,
    size: u64,
};

pub const AddressSizeCells = struct {
    address: usize,
    size: usize,
};

// Properties are stored as raw big-endian byte arrays matching DTB wire format.
pub const DeviceTreeProperty = struct {
    data: ?[]u8, // Null for empty property, owned bytes for data.

    pub const empty = DeviceTreeProperty{ .data = null };

    pub fn deinitProp(self: *DeviceTreeProperty, allocator: Allocator) void {
        if (self.data) |d| allocator.free(d);
        self.data = null;
    }

    pub fn size(self: *const DeviceTreeProperty) usize {
        return if (self.data) |d| d.len else 0;
    }

    pub fn fromBytes(
        allocator: Allocator,
        src: []const u8,
    ) !DeviceTreeProperty {
        return .{ .data = try allocator.dupe(u8, src) };
    }

    pub fn fromU32(allocator: Allocator, value: u32) !DeviceTreeProperty {
        const buf = try allocator.alloc(u8, 4);
        std.mem.writeInt(u32, buf[0..4], value, .big);
        return .{ .data = buf };
    }

    pub fn fromText(
        allocator: Allocator,
        text: []const u8,
    ) !DeviceTreeProperty {
        const len = try std.math.add(usize, text.len, 1);
        const buf = try allocator.alloc(u8, len);
        @memcpy(buf[0..text.len], text);
        buf[text.len] = 0;
        return .{ .data = buf };
    }

    pub fn fromMultiU32(
        allocator: Allocator,
        values: []const u32,
    ) !DeviceTreeProperty {
        const byte_len = try std.math.mul(usize, values.len, @sizeOf(u32));
        const buf = try allocator.alloc(u8, byte_len);
        for (values, 0..) |v, i| {
            std.mem.writeInt(u32, buf[i * 4 ..][0..4], v, .big);
        }
        return .{ .data = buf };
    }

    pub fn fromMultiU64(
        allocator: Allocator,
        values: []const u64,
    ) !DeviceTreeProperty {
        const byte_len = try std.math.mul(usize, values.len, @sizeOf(u64));
        const buf = try allocator.alloc(u8, byte_len);
        for (values, 0..) |v, i| {
            std.mem.writeInt(u64, buf[i * 8 ..][0..8], v, .big);
        }
        return .{ .data = buf };
    }

    pub fn asU32(self: *const DeviceTreeProperty) !u32 {
        const d = self.data orelse return DeviceTreeError.CannotConvert;
        if (d.len < 4) return DeviceTreeError.CannotConvert;
        return readBeU32(d[0..4]);
    }

    // Caller owns the returned slice and must free it.
    pub fn asMultiU32(
        self: *const DeviceTreeProperty,
        allocator: Allocator,
    ) ![]u32 {
        const d = self.data orelse return DeviceTreeError.CannotConvert;
        const count = d.len / 4;
        if (count == 0) return DeviceTreeError.CannotConvert;
        const result = try allocator.alloc(u32, count);
        for (0..count) |i| {
            result[i] = readBeU32(d[i * 4 .. i * 4 + 4]);
        }
        return result;
    }

    // Caller owns the returned slice and must free it.
    pub fn asMultiU64(
        self: *const DeviceTreeProperty,
        allocator: Allocator,
    ) ![]u64 {
        const d = self.data orelse return DeviceTreeError.CannotConvert;
        const count = d.len / 8;
        if (count == 0) return DeviceTreeError.CannotConvert;
        const result = try allocator.alloc(u64, count);
        for (0..count) |i| {
            result[i] = readBeU64(d[i * 8 .. i * 8 + 8]);
        }
        return result;
    }

    // Return the bytes as a string up to the first null byte (no allocation).
    pub fn asText(self: *const DeviceTreeProperty) ![]const u8 {
        const d = self.data orelse return DeviceTreeError.CannotConvert;
        var end: usize = 0;
        while (end < d.len and d[end] != 0) : (end += 1) {}
        return d[0..end];
    }

    // Return multiple null-terminated strings; caller must free outer slice.
    pub fn asMultiText(
        self: *const DeviceTreeProperty,
        allocator: Allocator,
    ) ![]const []const u8 {
        const d = self.data orelse return DeviceTreeError.CannotConvert;
        var count: usize = 0;
        for (d) |ch| {
            if (ch == 0) count += 1;
        }
        if (count == 0 and d.len > 0) count = 1;

        const result = try allocator.alloc([]const u8, count);
        var idx: usize = 0;
        var start: usize = 0;
        for (d, 0..) |ch, i| {
            if (ch == 0 and idx < count) {
                result[idx] = d[start..i];
                idx += 1;
                start = i + 1;
            }
        }
        if (idx < count) {
            result[idx] = d[start..d.len];
        }
        return result;
    }
};

test "property from/as u32, text, multi u32, and multi u64" {
    std.testing.refAllDecls(@This());
    const allocator = std.testing.allocator;

    var prop_u32 = try DeviceTreeProperty.fromU32(allocator, 0x12345678);
    defer prop_u32.deinitProp(allocator);
    try std.testing.expectEqual(@as(u32, 0x12345678), try prop_u32.asU32());

    var prop_txt = try DeviceTreeProperty.fromText(allocator, "hello");
    defer prop_txt.deinitProp(allocator);
    try std.testing.expectEqualStrings("hello", try prop_txt.asText());

    var prop_m32 = try DeviceTreeProperty.fromMultiU32(
        allocator,
        &[_]u32{ 0xaa, 0xbb, 0xcc },
    );
    defer prop_m32.deinitProp(allocator);
    const vals32 = try prop_m32.asMultiU32(allocator);
    defer allocator.free(vals32);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0xaa, 0xbb, 0xcc }, vals32);

    var prop_m64 = try DeviceTreeProperty.fromMultiU64(
        allocator,
        &[_]u64{ 0x100000000, 0x200000000 },
    );
    defer prop_m64.deinitProp(allocator);
    const vals64 = try prop_m64.asMultiU64(allocator);
    defer allocator.free(vals64);
    try std.testing.expectEqualSlices(
        u64,
        &[_]u64{ 0x100000000, 0x200000000 },
        vals64,
    );
}
