// Flattened Device Tree (DTB) structured node tree and query API.
//
// Copyright (c) 2024-2026 Chris Sherlock.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const prop = @import("dt/prop.zig");
pub const blob = @import("dt/blob.zig");

pub const DeviceTreeError = prop.DeviceTreeError;
pub const DtbMagic = prop.DtbMagic;
pub const DtbMinSupportedVersion = prop.DtbMinSupportedVersion;
pub const DtbMaxSupportedVersion = prop.DtbMaxSupportedVersion;
pub const MaxDtbSize = prop.MaxDtbSize;
pub const DefaultAddressCells = prop.DefaultAddressCells;
pub const DefaultSizeCells = prop.DefaultSizeCells;
pub const ReservedMemoryEntry = prop.ReservedMemoryEntry;
pub const AddressSizeCells = prop.AddressSizeCells;
pub const DeviceTreeProperty = prop.DeviceTreeProperty;
pub const DeviceTreeBlob = blob.DeviceTreeBlob;

const readBeU32 = prop.readBeU32;
const readBeU64 = prop.readBeU64;
const countChar = prop.countChar;

pub const PropertyEntry = struct {
    name: []u8,
    value: DeviceTreeProperty,
};

pub const DeviceTreeNode = struct {
    path: []u8,
    props: []PropertyEntry,
    prop_count: usize,

    fn findProperty(self: *const DeviceTreeNode, label: []const u8) ?usize {
        for (0..self.prop_count) |i| {
            if (std.mem.eql(u8, self.props[i].name, label)) return i;
        }
        return null;
    }
};

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

pub const DeviceTree = struct {
    pub const max_path_depth = 32;

    nodes: []DeviceTreeNode,
    node_count: usize,
    node_capacity: usize,
    boot_cpu_id: u32,
    reserved_memory: []ReservedMemoryEntry,
    reserved_count: usize,
    reserved_capacity: usize,
    allocator: Allocator,

    /// Creates a new empty device tree.
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

    /// Frees all nodes, properties, and the tree itself.
    pub fn deinit(self: *DeviceTree) void {
        const alloc = self.allocator;
        for (0..self.node_count) |i| self.freeNode(&self.nodes[i]);
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

    /// Adds a reserved memory region.
    pub fn addReservedMemory(
        self: *DeviceTree,
        address: u64,
        mem_size: u64,
    ) !void {
        if (self.reserved_count >= self.reserved_capacity) {
            const new_cap = self.reserved_capacity * 2;
            const new_buf = try self.allocator.alloc(
                ReservedMemoryEntry,
                new_cap,
            );
            @memcpy(
                new_buf[0..self.reserved_count],
                self.reserved_memory[0..self.reserved_count],
            );
            self.allocator.free(
                self.reserved_memory[0..self.reserved_capacity],
            );
            self.reserved_memory = new_buf;
            self.reserved_capacity = new_cap;
        }
        self.reserved_memory[self.reserved_count] = .{
            .address = address,
            .size = mem_size,
        };
        self.reserved_count += 1;
    }

    fn findNodeIndex(self: *const DeviceTree, path: []const u8) ?usize {
        var low: usize = 0;
        var high: usize = self.node_count;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, self.nodes[mid].path, path)) {
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
            switch (std.mem.order(u8, self.nodes[mid].path, path)) {
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

    /// Adds or updates a property, creating the node if it does not exist.
    /// Takes ownership of `value`; `label` and `node_path` are duplicated.
    pub fn editProperty(
        self: *DeviceTree,
        node_path: []const u8,
        label: []const u8,
        value: DeviceTreeProperty,
    ) !void {
        var owned_value = value;
        errdefer owned_value.deinitProp(self.allocator);

        const node_idx = self.findNodeIndex(node_path) orelse blk: {
            try self.ensureNodeCapacity();
            const pos = self.findInsertionPoint(node_path);
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
        if (node.findProperty(label)) |pi| {
            node.props[pi].value.deinitProp(self.allocator);
            node.props[pi].value = owned_value;
            owned_value = DeviceTreeProperty.empty;
            return;
        }

        if (node.prop_count >= node.props.len) {
            const new_cap = node.props.len * 2;
            const new_buf = try self.allocator.alloc(PropertyEntry, new_cap);
            @memcpy(
                new_buf[0..node.prop_count],
                node.props[0..node.prop_count],
            );
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

    /// Removes a property from a node. Returns true if found and removed.
    pub fn deleteProperty(
        self: *DeviceTree,
        node_path: []const u8,
        label: []const u8,
    ) bool {
        const node_idx = self.findNodeIndex(node_path) orelse return false;
        const node = &self.nodes[node_idx];
        const pi = node.findProperty(label) orelse return false;

        self.allocator.free(node.props[pi].name);
        node.props[pi].value.deinitProp(self.allocator);
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

    /// Looks up a property value (returns a reference to the property).
    pub fn getProperty(
        self: *const DeviceTree,
        node_path: []const u8,
        label: []const u8,
    ) !*const DeviceTreeProperty {
        const node_idx = self.findNodeIndex(node_path) orelse
            return DeviceTreeError.NotFound;
        const node = &self.nodes[node_idx];
        const pi = node.findProperty(label) orelse
            return DeviceTreeError.NotFound;
        return &node.props[pi].value;
    }

    /// Removes an entire node and all its properties.
    pub fn deleteNode(self: *DeviceTree, node_path: []const u8) void {
        const node_idx = self.findNodeIndex(node_path) orelse return;
        self.freeNode(&self.nodes[node_idx]);
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

    /// Counts the number of CPU nodes in the tree.
    pub fn countCpus(self: *const DeviceTree) usize {
        var count: usize = 0;
        var node_it = self.iter("/cpus", 2);
        while (node_it.next()) |path| {
            if (self.getProperty(path, "device_type")) |p| {
                if (p.asText()) |text| {
                    if (std.mem.eql(u8, text, "cpu")) count += 1;
                } else |_| {}
            } else |_| {}
        }
        return if (count > 0) count else 1;
    }

    /// Returns `#address-cells` and `#size-cells` for a node, falling back to
    /// specification defaults.
    pub fn getAddressSizeCells(
        self: *const DeviceTree,
        node_path: []const u8,
    ) AddressSizeCells {
        var addr_cells = DefaultAddressCells;
        var size_cells = DefaultSizeCells;
        if (self.getProperty(node_path, "#address-cells")) |p| {
            if (p.asU32()) |v| addr_cells = @intCast(v) else |_| {}
        } else |_| {}
        if (self.getProperty(node_path, "#size-cells")) |p| {
            if (p.asU32()) |v| size_cells = @intCast(v) else |_| {}
        } else |_| {}
        return .{ .address = addr_cells, .size = size_cells };
    }

    /// Reads a node's base address from its `reg` property, dynamically
    /// accounting for parent address cells.
    pub fn readAddress(self: *const DeviceTree, path: []const u8) !?usize {
        const reg_prop = self.getProperty(path, "reg") catch return null;
        const data = reg_prop.data orelse return null;
        const parent_path = try getParent(self.allocator, path);
        defer self.allocator.free(parent_path);
        const cells = self.getAddressSizeCells(parent_path);
        if (data.len >= cells.address * 4) {
            if (cells.address == 1) return @as(usize, readBeU32(data[0..4]));
            if (cells.address == 2) return @intCast(readBeU64(data[0..8]));
        }
        return null;
    }

    pub fn iter(
        self: *const DeviceTree,
        prefix: []const u8,
        max_depth: usize,
    ) NodeIterator {
        return .{
            .nodes = self.nodes[0..self.node_count],
            .index = 0,
            .prefix = prefix,
            .max_depth = max_depth,
        };
    }

    pub fn propertyIter(
        self: *const DeviceTree,
        node_path: []const u8,
    ) ?PropertyIterator {
        const node_idx = self.findNodeIndex(node_path) orelse return null;
        const node = &self.nodes[node_idx];
        return .{ .entries = node.props[0..node.prop_count], .index = 0 };
    }

    pub fn toBlob(self: *const DeviceTree) ![]u8 {
        return blob.serializeToBlob(self);
    }
};

pub fn getParent(allocator: Allocator, path: []const u8) ![]u8 {
    if (path.len == 0) return allocator.dupe(u8, "/");
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

test {
    _ = prop;
    _ = blob;
}

test "device tree manipulation, iteration, and getParent" {
    const allocator = std.testing.allocator;
    const dt = try DeviceTree.init(allocator);
    defer dt.deinit();

    const P = DeviceTreeProperty;
    const cells = dt.getAddressSizeCells("/");
    try std.testing.expectEqual(@as(usize, 2), cells.address);
    try std.testing.expectEqual(@as(usize, 1), cells.size);

    try dt.editProperty("/", "compatible", try P.fromText(allocator, "test"));
    try dt.editProperty("/cpus", "#address-cells", try P.fromU32(allocator, 1));
    try dt.editProperty("/cpus", "#size-cells", try P.fromU32(allocator, 0));
    try dt.editProperty("/cpus/cpu@0", "reg", try P.fromU32(allocator, 0));
    try dt.editProperty("/cpus/cpu@1", "reg", try P.fromU32(allocator, 1));

    var it = dt.iter("/cpus/cpu", 2);
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);

    try dt.editProperty("/cpus", "#address-cells", try P.fromU32(allocator, 2));
    const updated = try dt.getProperty("/cpus", "#address-cells");
    try std.testing.expectEqual(@as(u32, 2), try updated.asU32());

    try std.testing.expect(dt.deleteProperty("/cpus", "#size-cells"));
    try std.testing.expectError(
        DeviceTreeError.NotFound,
        dt.getProperty("/cpus", "#size-cells"),
    );

    dt.deleteNode("/cpus");
    try std.testing.expect(!dt.nodeExists("/cpus"));

    const p1 = try getParent(allocator, "/cpus/cpu@0");
    defer allocator.free(p1);
    try std.testing.expectEqualStrings("/cpus", p1);
    const p2 = try getParent(allocator, "/cpus");
    defer allocator.free(p2);
    try std.testing.expectEqualStrings("/", p2);
}
