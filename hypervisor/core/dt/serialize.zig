// Device tree (DeviceTree) binary serialization into a flattened DTB blob.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const dt = @import("../dt.zig");
const prop = @import("prop.zig");
const blob_mod = @import("blob.zig");

const DeviceTree = dt.DeviceTree;
const ByteWriter = prop.ByteWriter;
const FDT_OFFSET_PLACEHOLDER = blob_mod.FDT_OFFSET_PLACEHOLDER;
const INIT_STRING_REFS_CAPACITY = blob_mod.INIT_STRING_REFS_CAPACITY;
const max_path_depth = blob_mod.max_path_depth;

// Convert a structured DeviceTree into a binary DTB blob.
// Caller owns the returned slice and must free it.
pub fn serializeToBlob(self: *const DeviceTree) ![]u8 {
    var bytes = try ByteWriter.init(self.allocator);
    errdefer bytes.deinit();

    try bytes.addU32(prop.DtbMagic);
    const ref_total_size = bytes.len;
    try bytes.addU32(FDT_OFFSET_PLACEHOLDER);
    const ref_off_struct = bytes.len;
    try bytes.addU32(FDT_OFFSET_PLACEHOLDER);
    const ref_off_strings = bytes.len;
    try bytes.addU32(FDT_OFFSET_PLACEHOLDER);
    const ref_off_memrsv = bytes.len;
    try bytes.addU32(FDT_OFFSET_PLACEHOLDER);
    try bytes.addU32(prop.DtbVersion);
    try bytes.addU32(prop.LastSupportedVersion);
    try bytes.addU32(self.boot_cpu_id);
    const ref_size_strings = bytes.len;
    try bytes.addU32(FDT_OFFSET_PLACEHOLDER);
    const ref_size_struct = bytes.len;
    try bytes.addU32(FDT_OFFSET_PLACEHOLDER);

    const rsv_pad = std.mem.alignForward(usize, bytes.len, 8) - bytes.len;
    for (0..rsv_pad) |_| try bytes.addU8(0);
    try bytes.alterU32(ref_off_memrsv, bytes.offset32());

    for (0..self.reserved_count) |i| {
        try bytes.addU64(self.reserved_memory[i].address);
        try bytes.addU64(self.reserved_memory[i].size);
    }
    try bytes.addU64(0);
    try bytes.addU64(0);

    try bytes.padToU32();
    const dtstruct_start = bytes.offset32();
    try bytes.alterU32(ref_off_struct, dtstruct_start);

    var prev_nodes: [max_path_depth][]const u8 = undefined;
    var prev_count: usize = 0;

    const PropRef = struct { offset: usize, name: []const u8 };
    var prop_refs = try self.allocator.alloc(
        PropRef,
        INIT_STRING_REFS_CAPACITY,
    );
    defer self.allocator.free(prop_refs);
    var prop_ref_count: usize = 0;

    for (0..self.node_count) |ni| {
        const node = &self.nodes[ni];
        var components: [max_path_depth][]const u8 = undefined;
        var comp_count: usize = 0;
        if (std.mem.eql(u8, node.path, "/")) {
            components[0] = "";
            comp_count = 1;
        } else {
            var split_it = std.mem.splitScalar(u8, node.path, '/');
            while (split_it.next()) |comp| {
                if (comp_count < max_path_depth) {
                    components[comp_count] = comp;
                    comp_count += 1;
                }
            }
        }

        for (0..comp_count) |idx| {
            if (idx < prev_count) {
                if (!std.mem.eql(u8, prev_nodes[idx], components[idx])) {
                    while (prev_count > idx) {
                        try bytes.addU32(prop.FdtEndNode);
                        prev_count -= 1;
                    }
                    try bytes.addU32(prop.FdtBeginNode);
                    try bytes.addNullTermString(components[idx]);
                    try bytes.padToU32();
                    prev_nodes[idx] = components[idx];
                    prev_count = idx + 1;
                }
            } else {
                try bytes.addU32(prop.FdtBeginNode);
                try bytes.addNullTermString(components[idx]);
                try bytes.padToU32();
                prev_nodes[idx] = components[idx];
                prev_count = idx + 1;
            }
        }

        for (0..node.prop_count) |pi| {
            const p = &node.props[pi];
            try bytes.addU32(prop.FdtProp);
            try bytes.addU32(@intCast(p.value.size()));

            if (prop_ref_count >= prop_refs.len) {
                const new_cap = try std.math.mul(usize, prop_refs.len, 2);
                const new_buf = try self.allocator.alloc(PropRef, new_cap);
                @memcpy(
                    new_buf[0..prop_ref_count],
                    prop_refs[0..prop_ref_count],
                );
                self.allocator.free(prop_refs);
                prop_refs = new_buf;
            }
            prop_refs[prop_ref_count] = .{
                .offset = bytes.len,
                .name = p.name,
            };
            prop_ref_count += 1;
            try bytes.addU32(FDT_OFFSET_PLACEHOLDER);

            if (p.value.data) |d| {
                try bytes.addBytes(d);
                try bytes.padToU32();
            }
        }
    }

    while (prev_count > 0) {
        try bytes.addU32(prop.FdtEndNode);
        prev_count -= 1;
    }

    try bytes.addU32(prop.FdtEnd);
    try bytes.padToU32();
    try bytes.alterU32(ref_size_struct, bytes.offset32() - dtstruct_start);

    const dtstrings_start = bytes.offset32();
    try bytes.alterU32(ref_off_strings, dtstrings_start);

    const StringOff = struct { name: []const u8, offset: u32 };
    var unique_strings = try self.allocator.alloc(
        StringOff,
        INIT_STRING_REFS_CAPACITY,
    );
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
                const new_cap = try std.math.mul(usize, unique_strings.len, 2);
                const new_buf = try self.allocator.alloc(StringOff, new_cap);
                @memcpy(
                    new_buf[0..unique_count],
                    unique_strings[0..unique_count],
                );
                self.allocator.free(unique_strings);
                unique_strings = new_buf;
            }
            unique_strings[unique_count] = .{
                .name = p_ref.name,
                .offset = off,
            };
            unique_count += 1;
            try bytes.addNullTermString(p_ref.name);
        }
    }

    try bytes.alterU32(ref_size_strings, bytes.offset32() - dtstrings_start);
    try bytes.alterU32(ref_total_size, bytes.offset32());
    return try bytes.toOwnedSlice();
}

test "DeviceTree binary serialization declarations" {
    std.testing.refAllDecls(@This());
}
