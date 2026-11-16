// Freestanding Flattened Device Tree (FDT) `/chosen` initrd patcher for
// `guest-shim`.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const FDT_MAGIC: u32 = 0xd00d_feed;
pub const FDT_HEADER_SIZE: usize = 40;
pub const FDT_BEGIN_NODE: u32 = 1;
pub const FDT_END_NODE: u32 = 2;
pub const FDT_PROP: u32 = 3;
pub const FDT_NOP: u32 = 4;
pub const FDT_END: u32 = 9;
pub const TOKEN_BYTES: usize = 4;
const PROP_U64_BYTES: usize = 8;
const PROP_HEADER_BYTES: usize = 12;

pub const HDR_MAGIC: usize = 0;
pub const HDR_TOTALSIZE: usize = 4;
pub const HDR_OFF_DT_STRUCT: usize = 8;
pub const HDR_OFF_DT_STRINGS: usize = 12;
pub const HDR_OFF_MEM_RSVMAP: usize = 16;
pub const HDR_VERSION: usize = 20;
pub const HDR_LAST_COMP_VERSION: usize = 24;
pub const HDR_SIZE_DT_STRINGS: usize = 32;
pub const HDR_SIZE_DT_STRUCT: usize = 36;

fn align4(v: usize) usize {
    return (v + 3) & ~@as(usize, 3);
}

fn readBe32(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off..][0..4], .big);
}

fn writeBe32(buf: []u8, off: usize, val: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], val, .big);
}

fn writeBe64(buf: []u8, off: usize, val: u64) void {
    std.mem.writeInt(u64, buf[off..][0..8], val, .big);
}

fn propNameMatches(
    dtb: []const u8,
    off_strings: usize,
    size_strings: usize,
    nameoff: usize,
    target: []const u8,
) bool {
    if (nameoff >= size_strings) return false;
    const start = off_strings + nameoff;
    const end = start + target.len;
    if (end >= dtb.len) return false;
    return std.mem.eql(u8, dtb[start..end], target) and dtb[end] == 0;
}

fn findOrAppendString(
    dtb: []u8,
    off_strings: usize,
    size_strings: *usize,
    total_size: *usize,
    target: []const u8,
) ?u32 {
    var pos: usize = 0;
    while (pos + target.len < size_strings.*) {
        const s = off_strings + pos;
        if (std.mem.eql(u8, dtb[s .. s + target.len], target) and
            dtb[s + target.len] == 0)
        {
            return @intCast(pos);
        }
        while (pos < size_strings.* and
            dtb[off_strings + pos] != 0) : (pos += 1)
        {}
        pos += 1;
    }

    const add_len = target.len + 1;
    const str_end = off_strings + size_strings.*;
    if (str_end + add_len > dtb.len) return null;

    const new_off: u32 = @intCast(size_strings.*);
    @memcpy(dtb[str_end .. str_end + target.len], target);
    dtb[str_end + target.len] = 0;
    size_strings.* += add_len;
    if (off_strings + size_strings.* > total_size.*) {
        total_size.* = off_strings + size_strings.*;
    }
    return new_off;
}

/// Updates or inserts `linux,initrd-start` and `linux,initrd-end` (64-bit BE)
/// inside `/chosen` of `dtb_buf`. `dtb_buf` may include trailing slack space
/// after `totalsize` to allow in-place property insertion.
pub fn patchChosenInitrdInPlace(
    dtb_buf: []u8,
    initrd_start: u64,
    initrd_end: u64,
) bool {
    if (dtb_buf.len < FDT_HEADER_SIZE) return false;
    if (readBe32(dtb_buf, HDR_MAGIC) != FDT_MAGIC) return false;

    var total_size: usize = readBe32(dtb_buf, HDR_TOTALSIZE);
    if (total_size < FDT_HEADER_SIZE or total_size > dtb_buf.len) return false;

    const off_struct: usize = readBe32(dtb_buf, HDR_OFF_DT_STRUCT);
    var size_struct: usize = readBe32(dtb_buf, HDR_SIZE_DT_STRUCT);
    var off_strings: usize = readBe32(dtb_buf, HDR_OFF_DT_STRINGS);
    var size_strings: usize = readBe32(dtb_buf, HDR_SIZE_DT_STRINGS);

    if (off_struct + size_struct > total_size or
        off_strings + size_strings > total_size)
    {
        return false;
    }

    var cursor: usize = off_struct;
    const struct_end = off_struct + size_struct;
    var depth: usize = 0;
    var in_chosen = false;
    var chosen_insert_pos: ?usize = null;
    var start_val_off: ?usize = null;
    var end_val_off: ?usize = null;

    while (cursor + TOKEN_BYTES <= struct_end) {
        const token = readBe32(dtb_buf, cursor);
        cursor += TOKEN_BYTES;
        switch (token) {
            FDT_BEGIN_NODE => {
                const name_start = cursor;
                while (cursor < struct_end and dtb_buf[cursor] != 0) {
                    cursor += 1;
                }
                const name = dtb_buf[name_start..cursor];
                cursor = align4(cursor + 1);
                depth += 1;
                if (depth == 2 and std.mem.eql(u8, name, "chosen")) {
                    in_chosen = true;
                    chosen_insert_pos = cursor;
                }
            },
            FDT_END_NODE => {
                if (in_chosen and depth == 2) in_chosen = false;
                if (depth > 0) depth -= 1;
            },
            FDT_PROP => {
                if (cursor + 8 > struct_end) return false;
                const plen: usize = readBe32(dtb_buf, cursor);
                const nameoff: usize = readBe32(dtb_buf, cursor + 4);
                cursor += 8;
                if (cursor + plen > struct_end) return false;
                if (in_chosen and plen == PROP_U64_BYTES) {
                    if (propNameMatches(
                        dtb_buf,
                        off_strings,
                        size_strings,
                        nameoff,
                        "linux,initrd-start",
                    )) {
                        start_val_off = cursor;
                    } else if (propNameMatches(
                        dtb_buf,
                        off_strings,
                        size_strings,
                        nameoff,
                        "linux,initrd-end",
                    )) {
                        end_val_off = cursor;
                    }
                }
                cursor = align4(cursor + plen);
            },
            FDT_NOP => {},
            FDT_END => break,
            else => return false,
        }
    }

    if (start_val_off != null and end_val_off != null) {
        writeBe64(dtb_buf, start_val_off.?, initrd_start);
        writeBe64(dtb_buf, end_val_off.?, initrd_end);
        return true;
    }

    const insert_at = chosen_insert_pos orelse return false;
    const need_bytes: usize = 2 * (PROP_HEADER_BYTES + PROP_U64_BYTES);
    const tail_end = @max(off_struct + size_struct, off_strings + size_strings);
    if (tail_end + need_bytes + 64 > dtb_buf.len) return false;

    std.mem.copyBackwards(
        u8,
        dtb_buf[insert_at + need_bytes .. tail_end + need_bytes],
        dtb_buf[insert_at..tail_end],
    );
    size_struct += need_bytes;
    if (off_strings >= insert_at) off_strings += need_bytes;
    total_size = @max(total_size + need_bytes, off_strings + size_strings);

    const start_name = findOrAppendString(
        dtb_buf,
        off_strings,
        &size_strings,
        &total_size,
        "linux,initrd-start",
    ) orelse return false;
    const end_name = findOrAppendString(
        dtb_buf,
        off_strings,
        &size_strings,
        &total_size,
        "linux,initrd-end",
    ) orelse return false;

    writeBe32(dtb_buf, insert_at + 0, FDT_PROP);
    writeBe32(dtb_buf, insert_at + 4, PROP_U64_BYTES);
    writeBe32(dtb_buf, insert_at + 8, start_name);
    writeBe64(dtb_buf, insert_at + 12, initrd_start);

    const second_at = insert_at + PROP_HEADER_BYTES + PROP_U64_BYTES;
    writeBe32(dtb_buf, second_at + 0, FDT_PROP);
    writeBe32(dtb_buf, second_at + 4, PROP_U64_BYTES);
    writeBe32(dtb_buf, second_at + 8, end_name);
    writeBe64(dtb_buf, second_at + 12, initrd_end);

    writeBe32(dtb_buf, HDR_TOTALSIZE, @intCast(align4(total_size)));
    writeBe32(dtb_buf, HDR_SIZE_DT_STRUCT, @intCast(size_struct));
    writeBe32(dtb_buf, HDR_OFF_DT_STRINGS, @intCast(off_strings));
    writeBe32(dtb_buf, HDR_SIZE_DT_STRINGS, @intCast(size_strings));
    return true;
}

test "patchChosenInitrdInPlace inserts and updates initrd bounds in /chosen" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;

    var buf: [256]u8 = @splat(0);
    // Construct a minimal valid DTB with root `/` and `/chosen` node.
    const off_struct: u32 = 48;
    var s_off: usize = off_struct;
    writeBe32(&buf, s_off, FDT_BEGIN_NODE);
    s_off += 8; // "" + align4
    writeBe32(&buf, s_off, FDT_BEGIN_NODE);
    s_off += 4;
    @memcpy(buf[s_off .. s_off + 6], "chosen");
    s_off = align4(s_off + 7);
    writeBe32(&buf, s_off, FDT_END_NODE);
    s_off += 4;
    writeBe32(&buf, s_off, FDT_END_NODE);
    s_off += 4;
    writeBe32(&buf, s_off, FDT_END);
    s_off += 4;

    const size_struct: u32 = @intCast(s_off - off_struct);
    const off_strings: u32 = @intCast(s_off);
    writeBe32(&buf, HDR_MAGIC, FDT_MAGIC);
    writeBe32(&buf, HDR_TOTALSIZE, off_strings);
    writeBe32(&buf, HDR_OFF_DT_STRUCT, off_struct);
    writeBe32(&buf, HDR_OFF_DT_STRINGS, off_strings);
    writeBe32(&buf, HDR_OFF_MEM_RSVMAP, 40);
    writeBe32(&buf, HDR_VERSION, 17);
    writeBe32(&buf, HDR_LAST_COMP_VERSION, 16);
    writeBe32(&buf, HDR_SIZE_DT_STRUCT, size_struct);
    writeBe32(&buf, HDR_SIZE_DT_STRINGS, 0);

    try testing.expect(patchChosenInitrdInPlace(
        &buf,
        0x8400_0000,
        0x8420_0000,
    ));
    // Patching again updates the existing properties in-place.
    const size_after_insert = readBe32(&buf, HDR_TOTALSIZE);
    try testing.expect(patchChosenInitrdInPlace(
        &buf,
        0x8500_0000,
        0x8510_0000,
    ));
    try testing.expectEqual(
        size_after_insert,
        readBe32(&buf, HDR_TOTALSIZE),
    );
}
