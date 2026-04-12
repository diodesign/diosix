// Device tree blob (DTB) parsing and generation
//
// Based on v0.4 of the specifications here: https://www.devicetree.org/specifications
// Ported to Zig from https://github.com/diodesign/devicetree
//
// To parse a DTB in memory:
// Use DeviceTreeBlob.init() for pre-parsing checks, then call .parse() to generate a DeviceTree
//
// To generate a DTB in memory:
// Use DeviceTree.init() and add elements, or update an existing DeviceTree, then call .toBlob()
//
// Copyright (c) 2024, 2025, 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const debug = @import("debug.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;

// ---- errors ----

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

// ---- constants ----

const LastSupportedVersion: u32 = 16;
const DtbVersion: u32 = 17;

const FdtBeginNode: u32 = 0x00000001;
const FdtEndNode: u32 = 0x00000002;
const FdtProp: u32 = 0x00000003;
const FdtNop: u32 = 0x00000004;
const FdtEnd: u32 = 0x00000009;

const DtbMagic: u32 = 0xd00dfeed;

const DefaultAddressCells: usize = 2;
const DefaultSizeCells: usize = 1;

// ---- alignment helpers ----

// advance to the NEXT u32 boundary (always moves forward by at least 1 byte)
inline fn alignToNextU32(address: usize) usize {
    return (address & ~@as(usize, 3)) + 4;
}

// round UP to the nearest u32 boundary (no-op if already aligned)
inline fn alignUpU32(address: usize) usize {
    return (address + 3) & ~@as(usize, 3);
}

inline fn isAlignedU32(address: usize) bool {
    return (address & 3) == 0;
}

// ---- big-endian read helper ----

// read a big-endian u32 from an unmanaged byte pointer at the given byte offset
// returns the value converted to native endianness, or an error if the address is not word-aligned
inline fn readU32(src: [*]const u8, offset: usize) !u32 {
    const target_ptr = src + offset;
    const addr = @intFromPtr(target_ptr);

    if ((addr & (@alignOf(u32) - 1)) != 0) {
        return DeviceTreeError.BadAlignment;
    }

    const word: *const u32 = @ptrFromInt(addr);
    return std.mem.bigToNative(u32, word.*);
}

// ---- big-endian byte-level helpers ----

fn readBeU32(data: []const u8) u32 {
    return @as(u32, data[0]) << 24 | @as(u32, data[1]) << 16 | @as(u32, data[2]) << 8 | @as(u32, data[3]);
}

fn readBeU64(data: []const u8) u64 {
    return @as(u64, data[0]) << 56 | @as(u64, data[1]) << 48 |
        @as(u64, data[2]) << 40 | @as(u64, data[3]) << 32 |
        @as(u64, data[4]) << 24 | @as(u64, data[5]) << 16 |
        @as(u64, data[6]) << 8 | @as(u64, data[7]);
}

fn countChar(s: []const u8, c: u8) usize {
    var n: usize = 0;
    for (s) |ch| {
        if (ch == c) n += 1;
    }
    return n;
}

// ---- ByteWriter: dynamic big-endian byte buffer for blob serialization ----

const ByteWriter = struct {
    buffer: []u8,
    len: usize,
    allocator: Allocator,

    const initial_capacity = 4096;

    fn init(allocator: Allocator) !ByteWriter {
        return .{
            .buffer = try allocator.alloc(u8, initial_capacity),
            .len = 0,
            .allocator = allocator,
        };
    }

    fn deinit(self: *ByteWriter) void {
        self.allocator.free(self.buffer);
    }

    fn ensureCapacity(self: *ByteWriter, additional: usize) !void {
        if (self.len + additional <= self.buffer.len) return;
        var new_cap = self.buffer.len;
        while (new_cap < self.len + additional) new_cap *= 2;
        const new_buf = try self.allocator.alloc(u8, new_cap);
        @memcpy(new_buf[0..self.len], self.buffer[0..self.len]);
        self.allocator.free(self.buffer);
        self.buffer = new_buf;
    }

    fn addU32(self: *ByteWriter, value: u32) !void {
        try self.ensureCapacity(4);
        self.buffer[self.len + 0] = @truncate(value >> 24);
        self.buffer[self.len + 1] = @truncate(value >> 16);
        self.buffer[self.len + 2] = @truncate(value >> 8);
        self.buffer[self.len + 3] = @truncate(value);
        self.len += 4;
    }

    fn addU64(self: *ByteWriter, value: u64) !void {
        try self.ensureCapacity(8);
        self.buffer[self.len + 0] = @truncate(value >> 56);
        self.buffer[self.len + 1] = @truncate(value >> 48);
        self.buffer[self.len + 2] = @truncate(value >> 40);
        self.buffer[self.len + 3] = @truncate(value >> 32);
        self.buffer[self.len + 4] = @truncate(value >> 24);
        self.buffer[self.len + 5] = @truncate(value >> 16);
        self.buffer[self.len + 6] = @truncate(value >> 8);
        self.buffer[self.len + 7] = @truncate(value);
        self.len += 8;
    }

    fn addU8(self: *ByteWriter, value: u8) !void {
        try self.ensureCapacity(1);
        self.buffer[self.len] = value;
        self.len += 1;
    }

    fn addBytes(self: *ByteWriter, data: []const u8) !void {
        try self.ensureCapacity(data.len);
        @memcpy(self.buffer[self.len .. self.len + data.len], data);
        self.len += data.len;
    }

    fn addNullTermString(self: *ByteWriter, s: []const u8) !void {
        try self.addBytes(s);
        try self.addU8(0);
    }

    fn padToU32(self: *ByteWriter) !void {
        while (!isAlignedU32(self.len)) {
            try self.addU8(0);
        }
    }

    fn alterU32(self: *ByteWriter, offset: usize, value: u32) !void {
        if (offset + 4 > self.len) return DeviceTreeError.OutOfBoundsWrite;
        self.buffer[offset + 0] = @truncate(value >> 24);
        self.buffer[offset + 1] = @truncate(value >> 16);
        self.buffer[offset + 2] = @truncate(value >> 8);
        self.buffer[offset + 3] = @truncate(value);
    }

    fn offset32(self: *const ByteWriter) u32 {
        return @intCast(self.len);
    }

    // return a right-sized owned slice and release the internal buffer
    fn toOwnedSlice(self: *ByteWriter) ![]u8 {
        const result = try self.allocator.alloc(u8, self.len);
        @memcpy(result, self.buffer[0..self.len]);
        self.allocator.free(self.buffer);
        self.buffer = @constCast(&[0]u8{});
        self.len = 0;
        return result;
    }
};

// ---- reserved memory entry ----

pub const ReservedMemoryEntry = struct {
    address: u64,
    size: u64,
};

// ---- device tree property ----
//
// Properties are stored as raw big-endian byte arrays, matching the DTB wire format.
// Conversion methods interpret the bytes in various ways (u32, text, etc.).
// Construction helpers create the correct byte representation for the writer.

pub const DeviceTreeProperty = struct {
    data: ?[]u8, // null for empty property, owned bytes for data

    pub const empty = DeviceTreeProperty{ .data = null };

    pub fn deinitProp(self: *DeviceTreeProperty, allocator: Allocator) void {
        if (self.data) |d| allocator.free(d);
        self.data = null;
    }

    pub fn size(self: *const DeviceTreeProperty) usize {
        return if (self.data) |d| d.len else 0;
    }

    // ---- constructors (for creating properties when building a tree) ----

    pub fn fromBytes(allocator: Allocator, src: []const u8) !DeviceTreeProperty {
        const copy = try allocator.dupe(u8, src);
        return .{ .data = copy };
    }

    pub fn fromU32(allocator: Allocator, value: u32) !DeviceTreeProperty {
        const buf = try allocator.alloc(u8, 4);
        buf[0] = @truncate(value >> 24);
        buf[1] = @truncate(value >> 16);
        buf[2] = @truncate(value >> 8);
        buf[3] = @truncate(value);
        return .{ .data = buf };
    }

    pub fn fromText(allocator: Allocator, text: []const u8) !DeviceTreeProperty {
        const buf = try allocator.alloc(u8, text.len + 1);
        @memcpy(buf[0..text.len], text);
        buf[text.len] = 0; // null terminator
        return .{ .data = buf };
    }

    pub fn fromMultiU32(allocator: Allocator, values: []const u32) !DeviceTreeProperty {
        const buf = try allocator.alloc(u8, values.len * 4);
        for (values, 0..) |v, i| {
            buf[i * 4 + 0] = @truncate(v >> 24);
            buf[i * 4 + 1] = @truncate(v >> 16);
            buf[i * 4 + 2] = @truncate(v >> 8);
            buf[i * 4 + 3] = @truncate(v);
        }
        return .{ .data = buf };
    }

    pub fn fromMultiU64(allocator: Allocator, values: []const u64) !DeviceTreeProperty {
        const buf = try allocator.alloc(u8, values.len * 8);
        for (values, 0..) |v, i| {
            buf[i * 8 + 0] = @truncate(v >> 56);
            buf[i * 8 + 1] = @truncate(v >> 48);
            buf[i * 8 + 2] = @truncate(v >> 40);
            buf[i * 8 + 3] = @truncate(v >> 32);
            buf[i * 8 + 4] = @truncate(v >> 24);
            buf[i * 8 + 5] = @truncate(v >> 16);
            buf[i * 8 + 6] = @truncate(v >> 8);
            buf[i * 8 + 7] = @truncate(v);
        }
        return .{ .data = buf };
    }

    // ---- conversion methods (for reading parsed properties) ----

    // return the first 4 bytes as a big-endian u32
    pub fn asU32(self: *const DeviceTreeProperty) !u32 {
        const d = self.data orelse return DeviceTreeError.CannotConvert;
        if (d.len < 4) return DeviceTreeError.CannotConvert;
        return readBeU32(d[0..4]);
    }

    // return all bytes interpreted as an array of big-endian u32 values
    // caller owns the returned slice and must free it
    pub fn asMultiU32(self: *const DeviceTreeProperty, allocator: Allocator) ![]u32 {
        const d = self.data orelse return DeviceTreeError.CannotConvert;
        const count = d.len / 4;
        if (count == 0) return DeviceTreeError.CannotConvert;
        const result = try allocator.alloc(u32, count);
        for (0..count) |i| {
            result[i] = readBeU32(d[i * 4 .. i * 4 + 4]);
        }
        return result;
    }

    // return all bytes interpreted as an array of big-endian u64 values
    // caller owns the returned slice and must free it
    pub fn asMultiU64(self: *const DeviceTreeProperty, allocator: Allocator) ![]u64 {
        const d = self.data orelse return DeviceTreeError.CannotConvert;
        const count = d.len / 8;
        if (count == 0) return DeviceTreeError.CannotConvert;
        const result = try allocator.alloc(u64, count);
        for (0..count) |i| {
            result[i] = readBeU64(d[i * 8 .. i * 8 + 8]);
        }
        return result;
    }

    // return the bytes as a string up to the first null byte
    // the returned slice references the property's own data (no allocation)
    pub fn asText(self: *const DeviceTreeProperty) ![]const u8 {
        const d = self.data orelse return DeviceTreeError.CannotConvert;
        var end: usize = 0;
        while (end < d.len and d[end] != 0) : (end += 1) {}
        return d[0..end];
    }

    // return multiple null-terminated strings
    // caller owns the returned slice of slices and must free the outer slice
    pub fn asMultiText(self: *const DeviceTreeProperty, allocator: Allocator) ![]const []const u8 {
        const d = self.data orelse return DeviceTreeError.CannotConvert;
        // first pass: count strings
        var count: usize = 0;
        var i: usize = 0;
        while (i < d.len) {
            if (d[i] == 0) {
                count += 1;
                i += 1;
            } else {
                i += 1;
            }
        }
        if (count == 0 and d.len > 0) count = 1; // unterminated single string

        const result = try allocator.alloc([]const u8, count);
        // second pass: extract string slices (reference into property data)
        var idx: usize = 0;
        var start: usize = 0;
        i = 0;
        while (i < d.len and idx < count) {
            if (d[i] == 0) {
                result[idx] = d[start..i];
                idx += 1;
                start = i + 1;
                i += 1;
            } else {
                i += 1;
            }
        }
        // handle unterminated trailing string
        if (idx < count) {
            result[idx] = d[start..d.len];
        }
        return result;
    }
};

// ---- property list entry ----

const PropertyEntry = struct {
    name: []u8, // owned
    value: DeviceTreeProperty, // owned
};

// ---- internal node type ----

const DeviceTreeNode = struct {
    path: []u8, // owned, full canonical path
    props: []PropertyEntry, // allocated at prop_capacity
    prop_count: usize,

    fn findProperty(self: *const DeviceTreeNode, label: []const u8) ?usize {
        for (0..self.prop_count) |i| {
            if (std.mem.eql(u8, self.props[i].name, label)) return i;
        }
        return null;
    }
};

// ---- address/size cells ----

pub const AddressSizeCells = struct {
    address: usize,
    size: usize,
};

// ---- iterators ----

pub const NodeIterator = struct {
    nodes: []const DeviceTreeNode,
    index: usize,
    prefix: []const u8,
    max_depth: usize,

    pub fn next(self: *NodeIterator) ?[]const u8 {
        while (self.index < self.nodes.len) {
            const path = self.nodes[self.index].path;
            self.index += 1;
            if (countChar(path, '/') > self.max_depth) continue;
            if (std.mem.startsWith(u8, path, self.prefix)) return path;
        }
        return null;
    }
};

pub const PropertyIterator = struct {
    entries: []const PropertyEntry,
    index: usize,

    pub const Entry = struct {
        name: []const u8,
        value: *const DeviceTreeProperty,
    };

    pub fn next(self: *PropertyIterator) ?Entry {
        if (self.index >= self.entries.len) return null;
        const e = &self.entries[self.index];
        self.index += 1;
        return .{ .name = e.name, .value = &e.value };
    }
};

// ---- DeviceTree: the structured, queryable representation ----

pub const DeviceTree = struct {
    nodes: []DeviceTreeNode,
    node_count: usize,
    node_capacity: usize,
    boot_cpu_id: u32,
    reserved_memory: []ReservedMemoryEntry,
    reserved_count: usize,
    reserved_capacity: usize,
    allocator: Allocator,

    // create a new empty device tree
    pub fn init(allocator: Allocator) !*DeviceTree {
        const dt = try allocator.create(DeviceTree);
        errdefer allocator.destroy(dt);

        const nodes = try allocator.alloc(DeviceTreeNode, 16);
        errdefer allocator.free(nodes);

        const reserved = try allocator.alloc(ReservedMemoryEntry, 4);
        errdefer allocator.free(reserved);

        dt.* = .{
            .nodes = nodes,
            .node_count = 0,
            .node_capacity = 16,
            .boot_cpu_id = 0,
            .reserved_memory = reserved,
            .reserved_count = 0,
            .reserved_capacity = 4,
            .allocator = allocator,
        };
        return dt;
    }

    // free all nodes, properties, and the tree itself
    pub fn deinit(self: *DeviceTree) void {
        const alloc = self.allocator;
        for (0..self.node_count) |i| {
            self.freeNode(&self.nodes[i]);
        }
        alloc.free(self.nodes[0..self.node_capacity]);
        alloc.free(self.reserved_memory[0..self.reserved_capacity]);
        alloc.destroy(self);
    }

    fn freeNode(self: *DeviceTree, node: *DeviceTreeNode) void {
        for (0..node.prop_count) |i| {
            self.allocator.free(node.props[i].name);
            node.props[i].value.deinitProp(self.allocator);
        }
        if (node.props.len > 0) self.allocator.free(node.props);
        self.allocator.free(node.path);
    }

    pub fn setBootCpuId(self: *DeviceTree, cpu_id: u32) void {
        self.boot_cpu_id = cpu_id;
    }

    // add a reserved memory region
    pub fn addReservedMemory(self: *DeviceTree, address: u64, mem_size: u64) !void {
        if (self.reserved_count >= self.reserved_capacity) {
            const new_cap = self.reserved_capacity * 2;
            const new_buf = try self.allocator.alloc(ReservedMemoryEntry, new_cap);
            @memcpy(new_buf[0..self.reserved_count], self.reserved_memory[0..self.reserved_count]);
            self.allocator.free(self.reserved_memory[0..self.reserved_capacity]);
            self.reserved_memory = new_buf;
            self.reserved_capacity = new_cap;
        }
        self.reserved_memory[self.reserved_count] = .{ .address = address, .size = mem_size };
        self.reserved_count += 1;
    }

    // ---- node lookup (binary search on sorted path array) ----

    fn findNodeIndex(self: *const DeviceTree, path: []const u8) ?usize {
        var low: usize = 0;
        var high: usize = self.node_count;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const order = std.mem.order(u8, self.nodes[mid].path, path);
            switch (order) {
                .eq => return mid,
                .lt => low = mid + 1,
                .gt => high = mid,
            }
        }
        return null;
    }

    fn findInsertionPoint(self: *const DeviceTree, path: []const u8) usize {
        var low: usize = 0;
        var high: usize = self.node_count;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const order = std.mem.order(u8, self.nodes[mid].path, path);
            switch (order) {
                .lt => low = mid + 1,
                else => high = mid,
            }
        }
        return low;
    }

    fn ensureNodeCapacity(self: *DeviceTree) !void {
        if (self.node_count < self.node_capacity) return;
        const new_cap = self.node_capacity * 2;
        const new_buf = try self.allocator.alloc(DeviceTreeNode, new_cap);
        @memcpy(new_buf[0..self.node_count], self.nodes[0..self.node_count]);
        self.allocator.free(self.nodes[0..self.node_capacity]);
        self.nodes = new_buf;
        self.node_capacity = new_cap;
    }

    // ---- property manipulation ----

    // add or update a property. creates the node if it doesn't exist.
    // takes ownership of value; label and node_path are duplicated.
    pub fn editProperty(self: *DeviceTree, node_path: []const u8, label: []const u8, value: DeviceTreeProperty) !void {
        var owned_value = value;
        errdefer owned_value.deinitProp(self.allocator);

        const node_idx = self.findNodeIndex(node_path) orelse blk: {
            // create new node at sorted position
            try self.ensureNodeCapacity();
            const pos = self.findInsertionPoint(node_path);
            // shift elements right
            if (self.node_count > pos) {
                std.mem.copyBackwards(
                    DeviceTreeNode,
                    self.nodes[pos + 1 .. self.node_count + 1],
                    self.nodes[pos..self.node_count],
                );
            }
            const path = try self.allocator.dupe(u8, node_path);
            errdefer self.allocator.free(path);

            const props = try self.allocator.alloc(PropertyEntry, 8);
            errdefer self.allocator.free(props);

            self.nodes[pos] = .{
                .path = path,
                .props = props,
                .prop_count = 0,
            };
            self.node_count += 1;
            break :blk pos;
        };

        const node = &self.nodes[node_idx];

        // check if property already exists
        if (node.findProperty(label)) |pi| {
            node.props[pi].value.deinitProp(self.allocator);
            node.props[pi].value = owned_value;
            owned_value = DeviceTreeProperty.empty;
            return;
        }

        // add new property — grow if needed
        if (node.prop_count >= node.props.len) {
            const new_cap = node.props.len * 2;
            const new_buf = try self.allocator.alloc(PropertyEntry, new_cap);
            @memcpy(new_buf[0..node.prop_count], node.props[0..node.prop_count]);
            self.allocator.free(node.props);
            node.props = new_buf;
        }
        node.props[node.prop_count] = .{
            .name = try self.allocator.dupe(u8, label),
            .value = owned_value,
        };
        owned_value = DeviceTreeProperty.empty;
        node.prop_count += 1;
    }

    // remove a property from a node. returns true if found and removed.
    pub fn deleteProperty(self: *DeviceTree, node_path: []const u8, label: []const u8) bool {
        const node_idx = self.findNodeIndex(node_path) orelse return false;
        const node = &self.nodes[node_idx];
        const pi = node.findProperty(label) orelse return false;

        self.allocator.free(node.props[pi].name);
        node.props[pi].value.deinitProp(self.allocator);

        // shift remaining entries left
        if (pi + 1 < node.prop_count) {
            std.mem.copyForwards(
                PropertyEntry,
                node.props[pi .. node.prop_count - 1],
                node.props[pi + 1 .. node.prop_count],
            );
        }
        node.prop_count -= 1;
        return true;
    }

    // look up a property value (returns a reference to the property, not a copy)
    pub fn getProperty(self: *const DeviceTree, node_path: []const u8, label: []const u8) !*const DeviceTreeProperty {
        const node_idx = self.findNodeIndex(node_path) orelse return DeviceTreeError.NotFound;
        const node = &self.nodes[node_idx];
        const pi = node.findProperty(label) orelse return DeviceTreeError.NotFound;
        return &node.props[pi].value;
    }

    // remove an entire node and all its properties
    pub fn deleteNode(self: *DeviceTree, node_path: []const u8) void {
        const node_idx = self.findNodeIndex(node_path) orelse return;
        self.freeNode(&self.nodes[node_idx]);
        // shift remaining nodes left
        if (node_idx + 1 < self.node_count) {
            std.mem.copyForwards(
                DeviceTreeNode,
                self.nodes[node_idx .. self.node_count - 1],
                self.nodes[node_idx + 1 .. self.node_count],
            );
        }
        self.node_count -= 1;
    }

    pub fn nodeExists(self: *const DeviceTree, node_path: []const u8) bool {
        return self.findNodeIndex(node_path) != null;
    }

    /// Count the number of CPU nodes in the tree
    pub fn countCpus(self: *const DeviceTree) usize {
        var count: usize = 0;
        var node_it = self.iter("/cpus", 2);
        while (node_it.next()) |path| {
            // CPU nodes are usually children of /cpus and have device_type = "cpu"
            if (self.getProperty(path, "device_type")) |prop| {
                if (prop.asText()) |text| {
                    if (std.mem.eql(u8, text, "cpu")) {
                        count += 1;
                    }
                } else |_| {}
            } else |_| {}
        }
        // Fallback to at least one CPU if the device tree is malformed or missing CPU nodes
        return if (count > 0) count else 1;
    }

    // get #address-cells and #size-cells for a node, falling back to spec defaults
    pub fn getAddressSizeCells(self: *const DeviceTree, node_path: []const u8) AddressSizeCells {
        var addr_cells = DefaultAddressCells;
        var size_cells = DefaultSizeCells;

        if (self.getProperty(node_path, "#address-cells")) |prop| {
            if (prop.asU32()) |v| addr_cells = @intCast(v) else |_| {}
        } else |_| {}

        if (self.getProperty(node_path, "#size-cells")) |prop| {
            if (prop.asU32()) |v| size_cells = @intCast(v) else |_| {}
        } else |_| {}

        return .{ .address = addr_cells, .size = size_cells };
    }

    // iterate over nodes whose paths start with the given prefix, limited by depth
    pub fn iter(self: *const DeviceTree, prefix: []const u8, max_depth: usize) NodeIterator {
        return .{
            .nodes = self.nodes[0..self.node_count],
            .index = 0,
            .prefix = prefix,
            .max_depth = max_depth,
        };
    }

    // iterate over properties in a node
    pub fn propertyIter(self: *const DeviceTree, node_path: []const u8) ?PropertyIterator {
        const node_idx = self.findNodeIndex(node_path) orelse return null;
        const node = &self.nodes[node_idx];
        return .{
            .entries = node.props[0..node.prop_count],
            .index = 0,
        };
    }

    // ---- blob serialization ----

    const max_path_depth = 32;

    // convert this device tree into a binary DTB blob
    // caller owns the returned slice and must free it
    pub fn toBlob(self: *const DeviceTree) ![]u8 {
        var bytes = try ByteWriter.init(self.allocator);
        errdefer bytes.deinit();

        // we track offsets that need back-patching
        var ref_total_size: usize = 0;
        var ref_off_struct: usize = 0;
        var ref_off_strings: usize = 0;
        var ref_off_memrsv: usize = 0;
        var ref_size_strings: usize = 0;
        var ref_size_struct: usize = 0;

        // header
        try bytes.addU32(DtbMagic);
        ref_total_size = bytes.len;
        try bytes.addU32(0xffffffff); // totalsize placeholder
        ref_off_struct = bytes.len;
        try bytes.addU32(0xffffffff); // off_dt_struct placeholder
        ref_off_strings = bytes.len;
        try bytes.addU32(0xffffffff); // off_dt_strings placeholder
        ref_off_memrsv = bytes.len;
        try bytes.addU32(0xffffffff); // off_mem_rsvmap placeholder
        try bytes.addU32(DtbVersion);
        try bytes.addU32(LastSupportedVersion);
        try bytes.addU32(self.boot_cpu_id);
        ref_size_strings = bytes.len;
        try bytes.addU32(0xffffffff); // size_dt_strings placeholder
        ref_size_struct = bytes.len;
        try bytes.addU32(0xffffffff); // size_dt_struct placeholder

        // memory reservation block (8-byte aligned)
        while (!isAlignedU32(bytes.len) or (bytes.len & 7) != 0) {
            try bytes.addU8(0);
        }
        try bytes.alterU32(ref_off_memrsv, bytes.offset32());

        // write reserved memory entries
        for (0..self.reserved_count) |i| {
            try bytes.addU64(self.reserved_memory[i].address);
            try bytes.addU64(self.reserved_memory[i].size);
        }
        // terminating entry
        try bytes.addU64(0);
        try bytes.addU64(0);

        // structure block
        try bytes.padToU32();
        const dtstruct_start = bytes.offset32();
        try bytes.alterU32(ref_off_struct, dtstruct_start);

        // track previous path components for proper BEGIN/END nesting
        var prev_nodes: [max_path_depth][]const u8 = undefined;
        var prev_count: usize = 0;

        // collect property name offsets that need back-patching
        // use a temporary buffer: (byte_offset_in_output, property_name)
        const PropRef = struct { offset: usize, name: []const u8 };
        var prop_refs = try self.allocator.alloc(PropRef, 256);
        defer self.allocator.free(prop_refs);
        var prop_ref_count: usize = 0;

        for (0..self.node_count) |ni| {
            const node = &self.nodes[ni];

            // split path into components
            var components: [max_path_depth][]const u8 = undefined;
            var comp_count: usize = 0;
            var split_it = std.mem.splitScalar(u8, node.path, '/');
            while (split_it.next()) |comp| {
                if (comp_count < max_path_depth) {
                    components[comp_count] = comp;
                    comp_count += 1;
                }
            }

            // emit BEGIN_NODE / END_NODE tokens for proper nesting
            for (0..comp_count) |idx| {
                if (idx < prev_count) {
                    // check if this component differs from previous
                    if (!std.mem.eql(u8, prev_nodes[idx], components[idx])) {
                        // close all deeper nodes
                        while (prev_count > idx) {
                            try bytes.addU32(FdtEndNode);
                            prev_count -= 1;
                        }
                        // open new node
                        try bytes.addU32(FdtBeginNode);
                        try bytes.addNullTermString(components[idx]);
                        try bytes.padToU32();
                        prev_nodes[idx] = components[idx];
                        prev_count = idx + 1;
                    }
                } else {
                    // new deeper component
                    try bytes.addU32(FdtBeginNode);
                    try bytes.addNullTermString(components[idx]);
                    try bytes.padToU32();
                    prev_nodes[idx] = components[idx];
                    prev_count = idx + 1;
                }
            }

            // emit properties for this node
            for (0..node.prop_count) |pi| {
                const prop = &node.props[pi];
                try bytes.addU32(FdtProp);
                try bytes.addU32(@intCast(prop.value.size()));

                // record property name offset placeholder
                if (prop_ref_count >= prop_refs.len) {
                    const new_buf = try self.allocator.alloc(PropRef, prop_refs.len * 2);
                    @memcpy(new_buf[0..prop_ref_count], prop_refs[0..prop_ref_count]);
                    self.allocator.free(prop_refs);
                    prop_refs = new_buf;
                }
                prop_refs[prop_ref_count] = .{ .offset = bytes.len, .name = prop.name };
                prop_ref_count += 1;
                try bytes.addU32(0xffffffff); // name off placeholder

                if (prop.value.data) |d| {
                    try bytes.addBytes(d);
                    try bytes.padToU32();
                }
            }
        }

        // close all remaining nodes
        while (prev_count > 1) {
            try bytes.addU32(FdtEndNode);
            prev_count -= 1;
        }

        try bytes.addU32(FdtEnd);
        try bytes.padToU32();
        try bytes.alterU32(ref_size_struct, bytes.offset32() - dtstruct_start);

        // strings block
        const dtstrings_start = bytes.offset32();
        try bytes.alterU32(ref_off_strings, dtstrings_start);

        // serialize unique property names and back-patch offsets
        // use a small hashmap-like structure for string deduplication in the table
        const StringOff = struct { name: []const u8, offset: u32 };
        var unique_strings = try self.allocator.alloc(StringOff, 256);
        defer self.allocator.free(unique_strings);
        var unique_count: usize = 0;

        for (0..prop_ref_count) |i| {
            const p_ref = &prop_refs[i];
            var found_off: ?u32 = null;
            for (0..unique_count) |ui| {
                if (std.mem.eql(u8, unique_strings[ui].name, p_ref.name)) {
                    found_off = unique_strings[ui].offset;
                    break;
                }
            }

            if (found_off) |off| {
                try bytes.alterU32(p_ref.offset, off);
            } else {
                const off = bytes.offset32() - dtstrings_start;
                try bytes.alterU32(p_ref.offset, off);
                if (unique_count >= unique_strings.len) {
                    const new_buf = try self.allocator.alloc(StringOff, unique_strings.len * 2);
                    @memcpy(new_buf[0..unique_count], unique_strings[0..unique_count]);
                    self.allocator.free(unique_strings);
                    unique_strings = new_buf;
                }
                unique_strings[unique_count] = .{ .name = p_ref.name, .offset = off };
                unique_count += 1;
                try bytes.addNullTermString(p_ref.name);
            }
        }

        try bytes.alterU32(ref_size_strings, bytes.offset32() - dtstrings_start);
        try bytes.alterU32(ref_total_size, bytes.offset32());

        return try bytes.toOwnedSlice();
    }
};

// ---- DeviceTreeBlob: raw DTB in memory ----

pub const DeviceTreeBlob = struct {
    magic: u32,
    totalsize: u32,
    off_dt_struct: u32,
    off_dt_strings: u32,
    off_mem_rsvmap: u32,
    version: u32,
    last_comp_version: u32,
    boot_cpuid_phys: u32,
    size_dt_strings: u32,
    size_dt_struct: u32,

    blob: []u8, // owned copy
    allocator: Allocator,

    pub fn compatibilityCheck(self: *const DeviceTreeBlob) !void {
        if (self.magic != DtbMagic) return DeviceTreeError.BadMagic;
        if (self.last_comp_version > LastSupportedVersion) return DeviceTreeError.UnsupportedVersion;
    }

    // create a DeviceTreeBlob from a raw pointer to a device tree blob in memory.
    // takes a heap copy of the blob data.
    pub fn init(allocator: Allocator, blob: [*]u8) !*DeviceTreeBlob {
        const blob_size = try readU32(blob, 1 * 4);

        const new_dtb = try allocator.create(DeviceTreeBlob);
        errdefer allocator.destroy(new_dtb);

        new_dtb.allocator = allocator;
        new_dtb.magic = try readU32(blob, 0 * 4);
        new_dtb.totalsize = try readU32(blob, 1 * 4);
        new_dtb.off_dt_struct = try readU32(blob, 2 * 4);
        new_dtb.off_dt_strings = try readU32(blob, 3 * 4);
        new_dtb.off_mem_rsvmap = try readU32(blob, 4 * 4);
        new_dtb.version = try readU32(blob, 5 * 4);
        new_dtb.last_comp_version = try readU32(blob, 6 * 4);
        new_dtb.boot_cpuid_phys = try readU32(blob, 7 * 4);
        new_dtb.size_dt_strings = try readU32(blob, 8 * 4);
        new_dtb.size_dt_struct = try readU32(blob, 9 * 4);

        try new_dtb.compatibilityCheck();

        // take a copy of the blob
        new_dtb.blob = try allocator.alloc(u8, blob_size);
        errdefer allocator.free(new_dtb.blob);
        @memcpy(new_dtb.blob, blob[0..blob_size]);

        debug.printf("DeviceTreeBlob.init: Device tree blob at {*}, blob size = 0x{x}\n", .{ blob, blob_size });
        return new_dtb;
    }

    pub fn deinit(self: *DeviceTreeBlob) void {
        self.allocator.free(self.blob);
        self.allocator.destroy(self);
    }

    // parse the DTB blob into a structured DeviceTree
    pub fn parse(self: *const DeviceTreeBlob) !*DeviceTree {
        const dt = try DeviceTree.init(self.allocator);
        errdefer dt.deinit();

        dt.boot_cpu_id = self.boot_cpuid_phys;

        // parse reserved memory entries
        var mem_rsv_offset: usize = @intCast(self.off_mem_rsvmap);
        while (mem_rsv_offset + 16 <= self.blob.len) {
            const addr = readBeU64(self.blob[mem_rsv_offset .. mem_rsv_offset + 8]);
            const rsv_size = readBeU64(self.blob[mem_rsv_offset + 8 .. mem_rsv_offset + 16]);
            mem_rsv_offset += 16;
            if (addr == 0 and rsv_size == 0) break;
            try dt.addReservedMemory(addr, rsv_size);
        }

        // walk the structure block
        var offset: usize = @intCast(self.off_dt_struct);
        // path component stack (references into blob copy, so stable while parsing)
        var path_stack: [DeviceTree.max_path_depth][]const u8 = undefined;
        var path_depth: usize = 0;

        while (true) {
            if (!isAlignedU32(offset)) return DeviceTreeError.BadAlignment;
            if (offset + 4 > self.blob.len) return DeviceTreeError.ReachedUnexpectedEnd;

            const token = readBeU32(self.blob[offset .. offset + 4]);
            offset = alignToNextU32(offset);

            switch (token) {
                FdtBeginNode => {
                    // read null-terminated node name
                    const name_start = offset;
                    while (offset < self.blob.len and self.blob[offset] != 0 and self.blob[offset] != ':') {
                        offset += 1;
                    }
                    const name = self.blob[name_start..offset];
                    // offset now points at the null byte; alignToNextU32 advances
                    // past the null terminator and any padding to the next word boundary
                    offset = alignToNextU32(offset);

                    if (path_depth < DeviceTree.max_path_depth) {
                        path_stack[path_depth] = name;
                        path_depth += 1;
                    }
                },
                FdtEndNode => {
                    if (path_depth > 0) path_depth -= 1;
                },
                FdtProp => {
                    if (offset + 8 > self.blob.len) return DeviceTreeError.ReachedUnexpectedEnd;
                    const length = readBeU32(self.blob[offset .. offset + 4]);
                    offset = alignToNextU32(offset);
                    const string_offset = readBeU32(self.blob[offset .. offset + 4]);
                    offset = alignToNextU32(offset);

                    // read property data
                    const data_len: usize = @intCast(length);
                    const value = if (data_len == 0)
                        DeviceTreeProperty.empty
                    else blk: {
                        if (offset + data_len > self.blob.len) return DeviceTreeError.ReachedUnexpectedEnd;
                        break :blk try DeviceTreeProperty.fromBytes(self.allocator, self.blob[offset .. offset + data_len]);
                    };

                    if (data_len > 0) {
                        offset += data_len;
                        // align up to word boundary (no-op if already aligned)
                        offset = alignUpU32(offset);
                    }

                    // build full path
                    const full_path = try self.buildPath(path_stack[0..path_depth]);
                    defer self.allocator.free(full_path);

                    // get property name from strings block
                    const str_off: usize = @intCast(self.off_dt_strings + string_offset);
                    var name_end = str_off;
                    while (name_end < self.blob.len and self.blob[name_end] != 0) : (name_end += 1) {}
                    const prop_name = self.blob[str_off..name_end];

                    try dt.editProperty(full_path, prop_name, value);
                },
                FdtNop => {},
                FdtEnd => break,
                else => return DeviceTreeError.BadToken,
            }
        }

        return dt;
    }

    // build a "/" separated path from path stack components
    fn buildPath(self: *const DeviceTreeBlob, components: []const []const u8) ![]u8 {
        if (components.len == 0) return self.allocator.dupe(u8, "");
        if (components.len == 1) return self.allocator.dupe(u8, "/");

        // calculate total length
        var total: usize = 0;
        for (1..components.len) |i| {
            total += 1 + components[i].len; // "/" + component
        }

        const result = try self.allocator.alloc(u8, total);
        var pos: usize = 0;
        for (1..components.len) |i| {
            result[pos] = '/';
            pos += 1;
            @memcpy(result[pos .. pos + components[i].len], components[i]);
            pos += components[i].len;
        }
        return result;
    }
};

// ---- utility: return the parent path of a given node path ----

pub fn getParent(allocator: Allocator, path: []const u8) ![]u8 {
    if (path.len == 0) return allocator.dupe(u8, "/");
    // find last '/'
    var last_sep: ?usize = null;
    for (0..path.len) |i| {
        if (path[i] == '/') last_sep = i;
    }
    if (last_sep) |idx| {
        if (idx == 0) return allocator.dupe(u8, "/");
        return allocator.dupe(u8, path[0..idx]);
    }
    return allocator.dupe(u8, "/");
}

// =============== tests ===============

test "property from/as u32" {
    const allocator = std.testing.allocator;
    var prop = try DeviceTreeProperty.fromU32(allocator, 0x12345678);
    defer prop.deinitProp(allocator);

    const val = try prop.asU32();
    try std.testing.expectEqual(@as(u32, 0x12345678), val);
}

test "property from/as text" {
    const allocator = std.testing.allocator;
    var prop = try DeviceTreeProperty.fromText(allocator, "hello");
    defer prop.deinitProp(allocator);

    const text = try prop.asText();
    try std.testing.expectEqualStrings("hello", text);
}

test "property from/as multi u32" {
    const allocator = std.testing.allocator;
    var prop = try DeviceTreeProperty.fromMultiU32(allocator, &[_]u32{ 0xAA, 0xBB, 0xCC });
    defer prop.deinitProp(allocator);

    const vals = try prop.asMultiU32(allocator);
    defer allocator.free(vals);

    try std.testing.expectEqual(@as(usize, 3), vals.len);
    try std.testing.expectEqual(@as(u32, 0xAA), vals[0]);
    try std.testing.expectEqual(@as(u32, 0xBB), vals[1]);
    try std.testing.expectEqual(@as(u32, 0xCC), vals[2]);
}

test "property from/as multi u64" {
    const allocator = std.testing.allocator;
    var prop = try DeviceTreeProperty.fromMultiU64(allocator, &[_]u64{ 0x100000000, 0x200000000 });
    defer prop.deinitProp(allocator);

    const vals = try prop.asMultiU64(allocator);
    defer allocator.free(vals);

    try std.testing.expectEqual(@as(usize, 2), vals.len);
    try std.testing.expectEqual(@as(u64, 0x100000000), vals[0]);
    try std.testing.expectEqual(@as(u64, 0x200000000), vals[1]);
}

test "device tree edit, get, delete property" {
    const allocator = std.testing.allocator;
    const dt = try DeviceTree.init(allocator);
    defer dt.deinit();

    // add a property
    try dt.editProperty("/", "compatible", try DeviceTreeProperty.fromText(allocator, "riscv-virtio"));
    try dt.editProperty("/cpus", "#address-cells", try DeviceTreeProperty.fromU32(allocator, 1));
    try dt.editProperty("/cpus", "#size-cells", try DeviceTreeProperty.fromU32(allocator, 0));

    // read it back
    const compat = try dt.getProperty("/", "compatible");
    try std.testing.expectEqualStrings("riscv-virtio", try compat.asText());

    const addr_cells = try dt.getProperty("/cpus", "#address-cells");
    try std.testing.expectEqual(@as(u32, 1), try addr_cells.asU32());

    // update a property
    try dt.editProperty("/cpus", "#address-cells", try DeviceTreeProperty.fromU32(allocator, 2));
    const updated = try dt.getProperty("/cpus", "#address-cells");
    try std.testing.expectEqual(@as(u32, 2), try updated.asU32());

    // delete a property
    try std.testing.expect(dt.deleteProperty("/cpus", "#size-cells"));
    try std.testing.expectError(DeviceTreeError.NotFound, dt.getProperty("/cpus", "#size-cells"));

    // delete a node
    dt.deleteNode("/cpus");
    try std.testing.expect(!dt.nodeExists("/cpus"));
}

test "device tree get address size cells defaults" {
    const allocator = std.testing.allocator;
    const dt = try DeviceTree.init(allocator);
    defer dt.deinit();

    // no properties set, should return defaults
    const cells = dt.getAddressSizeCells("/");
    try std.testing.expectEqual(@as(usize, 2), cells.address);
    try std.testing.expectEqual(@as(usize, 1), cells.size);
}

test "device tree node iteration" {
    const allocator = std.testing.allocator;
    const dt = try DeviceTree.init(allocator);
    defer dt.deinit();

    try dt.editProperty("/", "compatible", try DeviceTreeProperty.fromText(allocator, "test"));
    try dt.editProperty("/cpus", "#address-cells", try DeviceTreeProperty.fromU32(allocator, 1));
    try dt.editProperty("/cpus/cpu@0", "reg", try DeviceTreeProperty.fromU32(allocator, 0));
    try dt.editProperty("/cpus/cpu@1", "reg", try DeviceTreeProperty.fromU32(allocator, 1));
    try dt.editProperty("/memory@80000000", "reg", try DeviceTreeProperty.fromU32(allocator, 0x80000000));

    // iterate with prefix "/cpus/cpu", depth 2
    var it = dt.iter("/cpus/cpu", 2);
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "round-trip: build tree, serialize to blob, parse back" {
    const allocator = std.testing.allocator;

    // build a device tree
    const dt = try DeviceTree.init(allocator);
    defer dt.deinit();

    try dt.editProperty("/", "#address-cells", try DeviceTreeProperty.fromU32(allocator, 2));
    try dt.editProperty("/", "#size-cells", try DeviceTreeProperty.fromU32(allocator, 2));
    try dt.editProperty("/", "compatible", try DeviceTreeProperty.fromText(allocator, "riscv-virtio"));
    try dt.editProperty("/cpus", "#address-cells", try DeviceTreeProperty.fromU32(allocator, 1));
    try dt.editProperty("/cpus", "#size-cells", try DeviceTreeProperty.fromU32(allocator, 0));
    try dt.editProperty("/cpus/cpu@0", "device_type", try DeviceTreeProperty.fromText(allocator, "cpu"));
    try dt.editProperty("/cpus/cpu@0", "reg", try DeviceTreeProperty.fromU32(allocator, 0));
    try dt.editProperty("/cpus/cpu@1", "device_type", try DeviceTreeProperty.fromText(allocator, "cpu"));
    try dt.editProperty("/cpus/cpu@1", "reg", try DeviceTreeProperty.fromU32(allocator, 1));
    try dt.editProperty("/memory@80000000", "device_type", try DeviceTreeProperty.fromText(allocator, "memory"));
    try dt.editProperty("/memory@80000000", "reg", try DeviceTreeProperty.fromMultiU64(allocator, &[_]u64{ 0x80000000, 0x8000000 }));
    try dt.editProperty("/chosen", "stdout-path", try DeviceTreeProperty.fromText(allocator, "/uart@10000000"));

    // serialize to blob
    const blob_data = try dt.toBlob();
    defer allocator.free(blob_data);

    // parse back
    const dtb = try DeviceTreeBlob.init(allocator, blob_data.ptr);
    defer dtb.deinit();

    const parsed = try dtb.parse();
    defer parsed.deinit();

    // verify properties survived the round trip
    const compat = try parsed.getProperty("/", "compatible");
    try std.testing.expectEqualStrings("riscv-virtio", try compat.asText());

    const addr_cells_root = try parsed.getProperty("/", "#address-cells");
    try std.testing.expectEqual(@as(u32, 2), try addr_cells_root.asU32());

    const cpu0_reg = try parsed.getProperty("/cpus/cpu@0", "reg");
    try std.testing.expectEqual(@as(u32, 0), try cpu0_reg.asU32());

    const cpu1_reg = try parsed.getProperty("/cpus/cpu@1", "reg");
    try std.testing.expectEqual(@as(u32, 1), try cpu1_reg.asU32());

    const mem_reg = try parsed.getProperty("/memory@80000000", "reg");
    const mem_vals = try mem_reg.asMultiU64(allocator);
    defer allocator.free(mem_vals);
    try std.testing.expectEqual(@as(u64, 0x80000000), mem_vals[0]);
    try std.testing.expectEqual(@as(u64, 0x8000000), mem_vals[1]);

    const stdout = try parsed.getProperty("/chosen", "stdout-path");
    try std.testing.expectEqualStrings("/uart@10000000", try stdout.asText());

    // verify node iteration
    var cpu_it = parsed.iter("/cpus/cpu", 2);
    var cpu_count: usize = 0;
    while (cpu_it.next()) |_| cpu_count += 1;
    try std.testing.expectEqual(@as(usize, 2), cpu_count);

    // verify address/size cells
    const cpus_cells = parsed.getAddressSizeCells("/cpus");
    try std.testing.expectEqual(@as(usize, 1), cpus_cells.address);
    try std.testing.expectEqual(@as(usize, 0), cpus_cells.size);
}

test "reserved memory round trip" {
    const allocator = std.testing.allocator;
    const dt = try DeviceTree.init(allocator);
    defer dt.deinit();

    try dt.addReservedMemory(0x80000000, 0x1000);
    try dt.addReservedMemory(0x90000000, 0x2000);
    try dt.editProperty("/", "compatible", try DeviceTreeProperty.fromText(allocator, "test"));

    const blob_data = try dt.toBlob();
    defer allocator.free(blob_data);

    const dtb = try DeviceTreeBlob.init(allocator, blob_data.ptr);
    defer dtb.deinit();

    const parsed = try dtb.parse();
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.reserved_count);
    try std.testing.expectEqual(@as(u64, 0x80000000), parsed.reserved_memory[0].address);
    try std.testing.expectEqual(@as(u64, 0x1000), parsed.reserved_memory[0].size);
    try std.testing.expectEqual(@as(u64, 0x90000000), parsed.reserved_memory[1].address);
    try std.testing.expectEqual(@as(u64, 0x2000), parsed.reserved_memory[1].size);
}

test "getParent" {
    const allocator = std.testing.allocator;

    const p1 = try getParent(allocator, "/cpus/cpu@0");
    defer allocator.free(p1);
    try std.testing.expectEqualStrings("/cpus", p1);

    const p2 = try getParent(allocator, "/cpus");
    defer allocator.free(p2);
    try std.testing.expectEqualStrings("/", p2);

    const p3 = try getParent(allocator, "/");
    defer allocator.free(p3);
    try std.testing.expectEqualStrings("/", p3);
}
