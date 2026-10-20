// Device tree blob (DTB) binary parsing and serialization.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const Allocator = std.mem.Allocator;
const debug = @import("../debug.zig");
const dt = @import("../dt.zig");
const prop = @import("prop.zig");

const DeviceTree = dt.DeviceTree;
const DeviceTreeError = prop.DeviceTreeError;
const DeviceTreeProperty = prop.DeviceTreeProperty;
const ByteWriter = prop.ByteWriter;

pub const FDT_OFF_MAGIC: usize = 0 * @sizeOf(u32);
pub const FDT_OFF_TOTALSIZE: usize = 1 * @sizeOf(u32);
pub const FDT_OFF_OFF_DT_STRUCT: usize = 2 * @sizeOf(u32);
pub const FDT_OFF_OFF_DT_STRINGS: usize = 3 * @sizeOf(u32);
pub const FDT_OFF_OFF_MEM_RSVMAP: usize = 4 * @sizeOf(u32);
pub const FDT_OFF_VERSION: usize = 5 * @sizeOf(u32);
pub const FDT_OFF_LAST_COMP_VERSION: usize = 6 * @sizeOf(u32);
pub const FDT_OFF_BOOT_CPUID_PHYS: usize = 7 * @sizeOf(u32);
pub const FDT_OFF_SIZE_DT_STRINGS: usize = 8 * @sizeOf(u32);
pub const FDT_OFF_SIZE_DT_STRUCT: usize = 9 * @sizeOf(u32);
pub const FDT_HEADER_SIZE: usize = 10 * @sizeOf(u32);
pub const FDT_OFFSET_PLACEHOLDER: u32 = 0xffff_ffff;
pub const INIT_STRING_REFS_CAPACITY: usize = 256;

pub const max_path_depth = 32;
pub const serialize = @import("serialize.zig");
pub const serializeToBlob = serialize.serializeToBlob;

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

    blob: []u8, // Owned copy.
    allocator: Allocator,

    pub fn compatibilityCheck(self: *const DeviceTreeBlob) !void {
        if (self.magic != prop.DtbMagic) return DeviceTreeError.BadMagic;
        if (self.last_comp_version > prop.LastSupportedVersion) {
            return DeviceTreeError.UnsupportedVersion;
        }
        if (self.totalsize < FDT_HEADER_SIZE or
            self.totalsize > prop.MaxDtbSize)
        {
            return DeviceTreeError.ReachedUnexpectedEnd;
        }
        const struct_end = std.math.add(
            u32,
            self.off_dt_struct,
            self.size_dt_struct,
        ) catch return DeviceTreeError.ReachedUnexpectedEnd;
        const strings_end = std.math.add(
            u32,
            self.off_dt_strings,
            self.size_dt_strings,
        ) catch return DeviceTreeError.ReachedUnexpectedEnd;
        if (struct_end > self.totalsize or
            strings_end > self.totalsize or
            self.off_mem_rsvmap > self.totalsize)
        {
            return DeviceTreeError.ReachedUnexpectedEnd;
        }
    }

    // Create a DeviceTreeBlob from a raw pointer in memory (takes a heap copy).
    pub fn init(allocator: Allocator, blob: [*]u8) !*DeviceTreeBlob {
        const blob_size = try prop.readU32(blob, FDT_OFF_TOTALSIZE);
        if (blob_size < FDT_HEADER_SIZE or blob_size > prop.MaxDtbSize) {
            return DeviceTreeError.ReachedUnexpectedEnd;
        }

        const new_dtb = try allocator.create(DeviceTreeBlob);
        errdefer allocator.destroy(new_dtb);

        new_dtb.allocator = allocator;
        new_dtb.magic = try prop.readU32(blob, FDT_OFF_MAGIC);
        new_dtb.totalsize = blob_size;
        new_dtb.off_dt_struct = try prop.readU32(blob, FDT_OFF_OFF_DT_STRUCT);
        new_dtb.off_dt_strings = try prop.readU32(blob, FDT_OFF_OFF_DT_STRINGS);
        new_dtb.off_mem_rsvmap = try prop.readU32(blob, FDT_OFF_OFF_MEM_RSVMAP);
        new_dtb.version = try prop.readU32(blob, FDT_OFF_VERSION);
        new_dtb.last_comp_version =
            try prop.readU32(blob, FDT_OFF_LAST_COMP_VERSION);
        new_dtb.boot_cpuid_phys =
            try prop.readU32(blob, FDT_OFF_BOOT_CPUID_PHYS);
        new_dtb.size_dt_strings =
            try prop.readU32(blob, FDT_OFF_SIZE_DT_STRINGS);
        new_dtb.size_dt_struct = try prop.readU32(blob, FDT_OFF_SIZE_DT_STRUCT);

        try new_dtb.compatibilityCheck();

        new_dtb.blob = try allocator.alloc(u8, blob_size);
        errdefer allocator.free(new_dtb.blob);
        @memcpy(new_dtb.blob, blob[0..blob_size]);

        debug.printf(
            "Device tree blob at HPA 0x{x}, size = 0x{x}\n",
            .{ @intFromPtr(blob), blob_size },
        );
        return new_dtb;
    }

    pub fn deinit(self: *DeviceTreeBlob) void {
        self.allocator.free(self.blob);
        self.allocator.destroy(self);
    }

    // Parse the DTB blob into a structured DeviceTree.
    pub fn parse(self: *const DeviceTreeBlob) !*DeviceTree {
        const tree = try DeviceTree.init(self.allocator);
        errdefer tree.deinit();

        tree.boot_cpu_id = self.boot_cpuid_phys;

        var mem_rsv_offset: usize = @intCast(self.off_mem_rsvmap);
        while (mem_rsv_offset <= self.blob.len and
            (self.blob.len - mem_rsv_offset) >= 16)
        {
            const addr = prop.readBeU64(self.blob[mem_rsv_offset..][0..8]);
            const rsv_size =
                prop.readBeU64(self.blob[mem_rsv_offset + 8 ..][0..8]);
            mem_rsv_offset += 16;
            if (addr == 0 and rsv_size == 0) break;
            try tree.addReservedMemory(addr, rsv_size);
        }

        var offset: usize = @intCast(self.off_dt_struct);
        const struct_end: usize =
            @as(usize, self.off_dt_struct) + @as(usize, self.size_dt_struct);
        const strings_end: usize =
            @as(usize, self.off_dt_strings) + @as(usize, self.size_dt_strings);
        var path_stack: [max_path_depth][]const u8 = undefined;
        var path_depth: usize = 0;

        while (true) {
            if (!prop.isAlignedU32(offset)) return DeviceTreeError.BadAlignment;
            const end_tok = std.math.add(usize, offset, 4) catch
                return DeviceTreeError.ReachedUnexpectedEnd;
            if (end_tok > struct_end or end_tok > self.blob.len) {
                return DeviceTreeError.ReachedUnexpectedEnd;
            }

            const token = prop.readBeU32(self.blob[offset..][0..4]);
            offset = prop.alignToNextU32(offset);

            switch (token) {
                prop.FdtBeginNode => {
                    const name_start = offset;
                    while (offset < struct_end and
                        self.blob[offset] != 0 and
                        self.blob[offset] != ':') : (offset += 1)
                    {}
                    if (offset >= struct_end) {
                        return DeviceTreeError.ReachedUnexpectedEnd;
                    }
                    const name = self.blob[name_start..offset];
                    while (offset < struct_end and
                        self.blob[offset] != 0) : (offset += 1)
                    {}
                    if (offset >= struct_end) {
                        return DeviceTreeError.ReachedUnexpectedEnd;
                    }
                    offset = prop.alignToNextU32(offset);
                    if (path_depth >= max_path_depth) {
                        return DeviceTreeError.ReachedUnexpectedEnd;
                    }
                    path_stack[path_depth] = name;
                    path_depth += 1;
                },
                prop.FdtEndNode => {
                    if (path_depth > 0) path_depth -= 1;
                },
                prop.FdtProp => {
                    const end_hdr = std.math.add(usize, offset, 8) catch
                        return DeviceTreeError.ReachedUnexpectedEnd;
                    if (end_hdr > struct_end) {
                        return DeviceTreeError.ReachedUnexpectedEnd;
                    }
                    const length = prop.readBeU32(self.blob[offset..][0..4]);
                    offset = prop.alignToNextU32(offset);
                    const str_rel = prop.readBeU32(self.blob[offset..][0..4]);
                    offset = prop.alignToNextU32(offset);

                    const data_len: usize = @intCast(length);
                    const data_end = std.math.add(usize, offset, data_len) catch
                        return DeviceTreeError.ReachedUnexpectedEnd;
                    if (data_end > struct_end) {
                        return DeviceTreeError.ReachedUnexpectedEnd;
                    }
                    const data_slice = self.blob[offset..data_end];
                    if (data_len > 0) offset = prop.alignUpU32(data_end);

                    const str_off32 = std.math.add(
                        u32,
                        self.off_dt_strings,
                        str_rel,
                    ) catch return DeviceTreeError.ReachedUnexpectedEnd;
                    const str_off: usize = @intCast(str_off32);
                    const str_limit: usize = @min(strings_end, self.blob.len);
                    if (str_off >= str_limit) {
                        return DeviceTreeError.ReachedUnexpectedEnd;
                    }
                    var name_end = str_off;
                    while (name_end < str_limit and
                        self.blob[name_end] != 0) : (name_end += 1)
                    {}
                    if (name_end >= str_limit) {
                        return DeviceTreeError.ReachedUnexpectedEnd;
                    }
                    const prop_name = self.blob[str_off..name_end];

                    const full_path =
                        try self.buildPath(path_stack[0..path_depth]);
                    defer self.allocator.free(full_path);

                    const value = if (data_len == 0)
                        DeviceTreeProperty.empty
                    else
                        try DeviceTreeProperty.fromBytes(
                            self.allocator,
                            data_slice,
                        );
                    try tree.editProperty(full_path, prop_name, value);
                },
                prop.FdtNop => {},
                prop.FdtEnd => break,
                else => return DeviceTreeError.BadToken,
            }
        }
        return tree;
    }

    fn buildPath(
        self: *const DeviceTreeBlob,
        components: []const []const u8,
    ) ![]u8 {
        if (components.len == 0) return self.allocator.dupe(u8, "");
        if (components.len == 1) return self.allocator.dupe(u8, "/");

        var total: usize = 0;
        for (1..components.len) |i| total += 1 + components[i].len;
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

test "round-trip: build tree, serialize to blob, parse back, and reserved mem" {
    _ = serialize;
    std.testing.refAllDecls(@This());
    const allocator = std.testing.allocator;
    const tree = try DeviceTree.init(allocator);
    defer tree.deinit();

    const P = DeviceTreeProperty;
    try tree.addReservedMemory(0x80000000, 0x1000);
    try tree.addReservedMemory(0x90000000, 0x2000);
    try tree.editProperty("/", "#address-cells", try P.fromU32(allocator, 2));
    try tree.editProperty("/", "#size-cells", try P.fromU32(allocator, 2));
    try tree.editProperty("/", "compatible", try P.fromText(allocator, "rv"));
    const c_ac = try P.fromU32(allocator, 1);
    try tree.editProperty("/cpus", "#address-cells", c_ac);
    try tree.editProperty("/cpus", "#size-cells", try P.fromU32(allocator, 0));
    const cpu0_t = try P.fromText(allocator, "cpu");
    try tree.editProperty("/cpus/cpu@0", "device_type", cpu0_t);
    try tree.editProperty("/cpus/cpu@0", "reg", try P.fromU32(allocator, 0));
    const cpu1_t = try P.fromText(allocator, "cpu");
    try tree.editProperty("/cpus/cpu@1", "device_type", cpu1_t);
    try tree.editProperty("/cpus/cpu@1", "reg", try P.fromU32(allocator, 1));
    const mem_p = try P.fromText(allocator, "memory");
    try tree.editProperty("/memory@80000000", "device_type", mem_p);
    const r_vals = [_]u64{ 0x80000000, 0x8000000 };
    const reg_p = try P.fromMultiU64(allocator, &r_vals);
    try tree.editProperty("/memory@80000000", "reg", reg_p);
    const out_p = try P.fromText(allocator, "/uart@10000000");
    try tree.editProperty("/chosen", "stdout-path", out_p);

    const blob_data = try tree.toBlob();
    defer allocator.free(blob_data);

    const dtb = try DeviceTreeBlob.init(allocator, blob_data.ptr);
    defer dtb.deinit();

    const parsed = try dtb.parse();
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.reserved_count);
    const r0 = parsed.reserved_memory[0].address;
    const r1 = parsed.reserved_memory[1].size;
    try std.testing.expectEqual(@as(u64, 0x80000000), r0);
    try std.testing.expectEqual(@as(u64, 0x2000), r1);

    const compat = try parsed.getProperty("/", "compatible");
    try std.testing.expectEqualStrings("rv", try compat.asText());
    try std.testing.expectEqual(@as(usize, 2), parsed.countCpus());

    const cpus_cells = parsed.getAddressSizeCells("/cpus");
    try std.testing.expectEqual(@as(usize, 1), cpus_cells.address);
    try std.testing.expectEqual(@as(usize, 0), cpus_cells.size);
}
