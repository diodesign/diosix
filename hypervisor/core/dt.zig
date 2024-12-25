// device tree blob (DTB) parsing and generation
//
// Based on v0.4 of the specifications here: https://www.devicetree.org/specifications
// Ported to Zig from https://github.com/diodesign/devicetree
//
// Copyright (c) 2024 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const debug = @import("debug.zig");
const Allocator = @import("alloc.zig").Allocator;
const bigToNative = @import("std").mem.bigToNative;

// ok. deep breath. and... here. we. go.

// the device tree is stored in big-endian mode, so we'll need helper functions for non-BE systems (like RISC-V)
// => src = pointer to a big-endian byte-array to access
//    offset = byte offset into the array to read a u32
// <= the u32 at the requested offset, with endian corrected for the build target
// Note: if the computed address of the u32 is not word aligned, this function returns null
inline fn read_u32(src: [*]u8, offset: usize) ?u32 {
    const addr: usize = (@intFromPtr(src) + offset);
    if (addr & 0b11 != 0b00) return null;

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
inline fn align_to_next_u32(address: usize) usize {
    return (address & !3) + 4;
}

// move an address to the next byte
inline fn align_to_next_u8(address: usize) usize {
    return address + 1;
}

// return true if address is aligned to a 32-bit word boundary
inline fn is_aligned_u32(address: usize) bool {
    return (address & 3) == 0;
}

const DeviceTReeSeparator: []const u8 = "/";

// DTB parsing and processing errors
const DeviceTreeError = error{ CannotConvert, BadMagic, UnsupportedVersion, ReachedEnd, ReachedUnexpectedEnd, BadAlignment, SkippedToken, BadToken, MissingRootNode, NotFound, WidthUnsupported, OutOfBoundsWrite, AllocFailure, DeAllocFailure };

// DTB header plus a copy of the tree's blob
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

    // return no error if this appears to be legit DTB data, or an error code if not
    pub fn compatibility_check(self: *DeviceTreeBlob) !void {
        if (self.magic != DtbMagic) {
            return DeviceTreeError.BadMagic;
        }

        if (self.last_comp_version > LastSupportedVersion) {
            return DeviceTreeError.UnsupportedVersion;
        }
    }

    // create a DeviceTreeBlob structure from a device tree blob in memory.
    // Note: this will take a copy of the blob data.
    // => allocator to use, pointer to device tree blob
    // <= pointer to caller-owned DeviceTreeBlob object, or error core for failure
    pub fn init(allocator: *Allocator, blob: [*]u8) !*DeviceTreeBlob {
        // extract the blob size pre-parsing
        const blob_size = read_u32(blob, 1 * 4) orelse return DeviceTreeError.BadAlignment;

        const new_dtb: *DeviceTreeBlob = @as(*DeviceTreeBlob, @ptrCast(try allocator.*.create(@sizeOf(DeviceTreeBlob))));
        errdefer allocator.*.destroy(new_dtb) catch |err| {
            debug.printf("Failed to deallocate DTB object during failed initialization, reason: {}\n", .{err});
        };

        // fill out the metadata for this DTB object
        new_dtb.*.magic = read_u32(blob, 0 * 4) orelse return DeviceTreeError.BadAlignment;
        new_dtb.*.totalsize = read_u32(blob, 1 * 4) orelse return DeviceTreeError.BadAlignment;
        new_dtb.*.off_dt_struct = read_u32(blob, 2 * 4) orelse return DeviceTreeError.BadAlignment;
        new_dtb.*.off_dt_strings = read_u32(blob, 3 * 4) orelse return DeviceTreeError.BadAlignment;
        new_dtb.*.off_mem_rsvmap = read_u32(blob, 4 * 4) orelse return DeviceTreeError.BadAlignment;
        new_dtb.*.version = read_u32(blob, 5 * 4) orelse return DeviceTreeError.BadAlignment;
        new_dtb.*.last_comp_version = read_u32(blob, 6 * 4) orelse return DeviceTreeError.BadAlignment;
        new_dtb.*.boot_cpuid_phys = read_u32(blob, 7 * 4) orelse return DeviceTreeError.BadAlignment;
        new_dtb.*.size_dt_strings = read_u32(blob, 8 * 4) orelse return DeviceTreeError.BadAlignment;
        new_dtb.*.size_dt_struct = read_u32(blob, 9 * 4) orelse return DeviceTreeError.BadAlignment;

        // bail out now if we can't work with this DTB
        new_dtb.compatibility_check() catch |err| return err;

        // take a copy of the blob in our dtb structure
        new_dtb.blob = @as([*]u8, @ptrCast(try allocator.*.create(blob_size)));
        errdefer allocator.*.destroy(new_dtb.blob) orelse DeviceTreeError.DeAllocFailure;

        @memcpy(new_dtb.blob[0..blob_size], blob[0..blob_size]);

        debug.printf("Device tree blob at 0x{x}, blob size = 0x{x}\n", .{ @intFromPtr(blob), blob_size });
        return new_dtb;
    }

    // release heap resources held by this DeviceTreeBlob
    pub fn deinit(self: *DeviceTreeBlob, allocator: *Allocator) !void {
        try allocator.*.destroy(self.blob);
        try allocator.*.destroy(self);
    }
};
