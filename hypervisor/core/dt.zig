// device tree blob (DTB) parsing and generation
//
// Based on v0.4 of the specifications here: https://www.devicetree.org/specifications
// Ported to Zig from https://github.com/diodesign/devicetree
//
// To parse a DTB in memory:
// Use DeviceTreeBlob.init() for pre-parsing checks, then call .parse() to generate a DeviceTree
//
// To generate a DTB in memory:
// Use DeviceTree.new() and add elements, or update an existing DeviceTree, then call .to_dtb()
//
// Copyright (c) 2024, 2025 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const debug = @import("debug.zig");
const LinkedList = @import("dsa.zip").LinkedList;
const Allocator = @import("alloc.zig").Allocator;
const bigToNative = @import("std").mem.bigToNative;

// DTB parsing and processing errors
const DeviceTreeError = error{ CannotConvert, BadMagic, UnsupportedVersion, ReachedEnd, ReachedUnexpectedEnd, BadAlignment, SkippedToken, BadToken, MissingRootNode, NotFound, WidthUnsupported, OutOfBoundsWrite, AllocFailure, DeAllocFailure };

// the device tree is stored in big-endian mode, so we'll need helper functions for non-BE systems (like RISC-V)
// => src = pointer to a big-endian byte-array to access
//    offset = byte offset into the array to read a u32
// <= the u32 at the requested offset, with endian corrected for the build target
// Note: if the computed address of the u32 is not word aligned, this function returns an error
inline fn readU32(src: [*]u8, offset: usize) !u32 {
    const addr: usize = @intFromPtr(src) + offset;
    if (addr & (@alignOf(u32) - 1) != 0) return DeviceTreeError.BadAlignment;

    const word: *u32 = @ptrFromInt(addr);
    return bigToNative(u32, word.*);
}

// support any DTB backwards compatible to this spec version number
const LastSupportedVersion: u32 = 16;

// follow version 17 of the DT specification
const DtbVersion: u32 = 17;

// DTB token ID numbers, hardwired into the spec
const FdtBeginNode: u32 = 0x00000001;
const FdtEndNode: u32 = 0x00000002;
const FdtProp: u32 = 0x00000003;
const FdtNop: u32 = 0x00000004;
const FdtEnd: u32 = 0x00000009;

// device tree blob (DTB) header magic number
const DtbMagic: u32 = 0xd00dfeed;

// defaults for #address-cells and #size-cells from the specification */
const DefaultAddressCells: usize = 2;
const DefaultSizeCells: usize = 1;

// round a memory address up to the next 32-bit word boundary
inline fn alignToNextU32(address: usize) usize {
    return (address & !3) + 4;
}

// move an address to the next byte
inline fn alignToNextU8(address: usize) usize {
    return address + 1;
}

// return true if address is aligned to a 32-bit word boundary
inline fn isAlignedU32(address: usize) bool {
    return (address & 3) == 0;
}

const DeviceTreeSeparator: []const u8 = "/";

// A copy of a DTB's header and the tree's raw blob data
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

    blob: [*]u8,
    allocator: *Allocator,

    // return no error if this appears to be legit DTB data, or an error code if not
    pub fn compatibilityCheck(self: *DeviceTreeBlob) !void {
        if (self.magic != DtbMagic) {
            return DeviceTreeError.BadMagic;
        }

        if (self.last_comp_version > LastSupportedVersion) {
            return DeviceTreeError.UnsupportedVersion;
        }
    }

    // create a DeviceTreeBlob structure from a device tree blob in memory.
    // Note: this will take a copy of the blob data.
    // => allocator to use, pointer to device tree blob in un-managed memory
    // <= pointer to caller-owned DeviceTreeBlob object, or error core for failure
    pub fn init(allocator: *Allocator, blob: [*]u8) !*DeviceTreeBlob {
        // extract the blob size pre-parsing
        const blob_size = try readU32(blob, 1 * 4);

        const new_dtb: *DeviceTreeBlob = try allocator.create(*DeviceTreeBlob, @sizeOf(DeviceTreeBlob));
        errdefer allocator.destroy(new_dtb) catch |err| {
            debug.printf("Failed to deallocate DTB object during failed initialization, reason: {}\n", .{err});
        };

        new_dtb.allocator = allocator;

        // fill out the metadata for this DTB object
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

        // bail out now if we can't work with this DTB
        try new_dtb.compatibilityCheck();

        // take a copy of the blob in our dtb structure
        new_dtb.blob = try allocator.create([*]u8, blob_size);
        errdefer allocator.destroy(new_dtb.blob) orelse DeviceTreeError.DeAllocFailure;

        @memcpy(new_dtb.blob[0..blob_size], blob[0..blob_size]);

        debug.printf("Device tree blob at 0x{x}, blob size = 0x{x}\n", .{ @intFromPtr(blob), blob_size });
        return new_dtb;
    }

    // release heap resources held by this DeviceTreeBlob
    pub fn deinit(self: *DeviceTreeBlob) !void {
        try self.allocator.destroy(self.blob);
        try self.allocator.destroy(self);
    }

    // turn a DTB in meory into a DeviceTree
    pub fn parse(self: *DeviceTreeBlob) !*DeviceTree {
        const new_dt: *DeviceTree = try self.allocator.create(*DeviceTree, @sizeOf(DeviceTree));
        errdefer self.allocator.destroy(new_dt) catch |err| {
            debug.printf("Failed to deallocate DT object during failed parse attempt, reason: {}\n", .{err});
        };

        return new_dt;
    }
};

// a device tree is made up of a collection of these properties
// there may be a nicer way of experessing this....
// see: https://www.reddit.com/r/Zig/comments/1gmd60c/idiomatic_style_of_using_the_tag_type_in_unionenum/

const DeviceTreePropertyType = enum {
    Empty,
    Bytes,

    MultipleUnsignedInt64_64,
    MultipleUnsignedInt64_32,
    MultipleUnsignedInt32_32,

    MultipleUnsignedInt64,
    MultipleUnsignedInt32,

    UnsignedInt32,
    Text,
    MultipleText,
};

const DeviceTreeProperty = union(DeviceTreePropertyType) {
    Empty: void,
    Bytes: [*]u8,

    MultipleUnsignedInt64_64: [*].{ u64, u64 },
    MultipleUnsignedInt64_32: [*].{ u64, u32 },
    MultipleUnsignedInt32_32: [*].{ u32, u32 },

    MultipleUnsignedInt64: [*]u64,
    MultipleUnsignedInt32: [*]u32,

    UnsignedInt32: u32,
    Text: [*]u8,
    MultipleText: [*][*]u8,
};

// our logical native representation of a device tree
// bake the tree structure code in as a sorted string-value map with multiple children per node is quite specific
// and unlikely to be used elsewhere in the
pub const DeviceTree = struct {
    // nodes: *StringTreeMap,

    // return a caller-owned empty device tree
    pub fn init(allocator: *Allocator) !*DeviceTree {
        const new_dt: *DeviceTree = try allocator.create(*DeviceTree, @sizeOf(DeviceTree));
        errdefer allocator.destroy(new_dt) catch |err| {
            debug.printf("Failed to deallocate DT object during failed initialization attempt, reason: {}\n", .{err});
        };

        // new_dt.nodes = try allocator.create(*StringTreeMap(*DeviceTreeProperty), @sizeOf(StringTreeMap));
        // new_dt.nodes.init(allocator);

        return new_dt;
    }

    // teardown a device tree
    pub fn deinit(self: *DeviceTree, allocator: *Allocator) !void {
        try allocator.destroy(self);
    }
};
