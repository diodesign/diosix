// Unit tests for Flattened DeviceTree (FDT/DTB) parsing.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fdt = @import("../fdt.zig");

test "FDT header parsing" {
    std.testing.refAllDecls(@This());
    var raw_header: [40]u8 = std.mem.zeroes([40]u8);
    raw_header[0] = 0xd0;
    raw_header[1] = 0x0d;
    raw_header[2] = 0xfe;
    raw_header[3] = 0xed;

    raw_header[6] = 0x01;
    raw_header[7] = 0x00;

    const header = try fdt.parseHeader(&raw_header);
    try std.testing.expectEqual(@as(u32, fdt.FDT_MAGIC), header.magic);
    try std.testing.expectEqual(@as(u32, 256), header.totalsize);
}

test "FDT corrupt and out-of-bounds rejection" {
    var bad_magic: [40]u8 = std.mem.zeroes([40]u8);
    try std.testing.expectError(
        fdt.FdtError.BadMagic,
        fdt.parseHeader(&bad_magic),
    );

    var trunc: [40]u8 = std.mem.zeroes([40]u8);
    trunc[0] = 0xd0;
    trunc[1] = 0x0d;
    trunc[2] = 0xfe;
    trunc[3] = 0xed;
    trunc[7] = 20;
    try std.testing.expectError(
        fdt.FdtError.TruncatedHeader,
        fdt.parseHeader(&trunc),
    );

    var bad_offsets: [40]u8 = std.mem.zeroes([40]u8);
    bad_offsets[0] = 0xd0;
    bad_offsets[1] = 0x0d;
    bad_offsets[2] = 0xfe;
    bad_offsets[3] = 0xed;
    bad_offsets[7] = 100;
    bad_offsets[11] = 120;
    try std.testing.expectError(
        fdt.FdtError.CorruptStructure,
        fdt.parseHeader(&bad_offsets),
    );
}

test "FDT parseHardwareInfo with long node name and reg before compatible" {
    var dtb: [512]u8 = @splat(0);
    dtb[0] = 0xd0;
    dtb[1] = 0x0d;
    dtb[2] = 0xfe;
    dtb[3] = 0xed;
    dtb[6] = 0x02;
    dtb[7] = 0x00; // totalsize = 512
    dtb[11] = 48; // off_dt_struct = 48
    dtb[14] = 0x01;
    dtb[15] = 0x2c; // off_dt_strings = 300
    dtb[19] = 40; // off_mem_rsvmap = 40
    dtb[23] = 17; // version = 17
    dtb[27] = 16; // last_comp_version = 16
    dtb[35] = 64; // size_dt_strings = 64
    dtb[38] = 0x00;
    dtb[39] = 220; // size_dt_struct = 220

    const str_table = dtb[300..];
    @memcpy(str_table[0..4], "reg\x00");
    @memcpy(str_table[4..19], "#address-cells\x00");
    @memcpy(str_table[19..31], "#size-cells\x00");
    @memcpy(str_table[31..42], "compatible\x00");

    var s_idx: usize = 48;

    // FDT_BEGIN_NODE (root "")
    std.mem.writeInt(u32, dtb[s_idx..][0..4], fdt.FDT_BEGIN_NODE, .big);
    s_idx += 4;
    dtb[s_idx] = 0;
    s_idx += 4;

    // FDT_PROP #address-cells = 1
    std.mem.writeInt(u32, dtb[s_idx..][0..4], fdt.FDT_PROP, .big);
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], 4, .big);
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], 4, .big);
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], 1, .big);
    s_idx += 4;

    // FDT_PROP #size-cells = 1
    std.mem.writeInt(u32, dtb[s_idx..][0..4], fdt.FDT_PROP, .big);
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], 4, .big);
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], 19, .big);
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], 1, .big);
    s_idx += 4;

    // FDT_BEGIN_NODE: long serial node name (> 64 bytes) at custom 0x10002000
    const long_name =
        "serial-device-with-a-very-long-name-exceeding-" ++
        "sixty-four-bytes@10002000";
    std.mem.writeInt(u32, dtb[s_idx..][0..4], fdt.FDT_BEGIN_NODE, .big);
    s_idx += 4;
    @memcpy(dtb[s_idx..][0..long_name.len], long_name);
    dtb[s_idx + long_name.len] = 0;
    const aligned_name_len = std.mem.alignForward(
        usize,
        long_name.len + 1,
        @sizeOf(u32),
    );
    s_idx += aligned_name_len;

    // FDT_PROP reg = 0x10002000, len 8 (placed BEFORE compatible!)
    std.mem.writeInt(u32, dtb[s_idx..][0..4], fdt.FDT_PROP, .big);
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], 8, .big);
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], 0, .big);
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], 0x10002000, .big);
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], 0x100, .big);
    s_idx += 4;

    // FDT_PROP compatible = "ns16550a\x00" (must not overwrite 0x10002000!)
    const compat = "ns16550a\x00";
    std.mem.writeInt(u32, dtb[s_idx..][0..4], fdt.FDT_PROP, .big);
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], compat.len, .big);
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], 31, .big);
    s_idx += 4;
    @memcpy(dtb[s_idx..][0..compat.len], compat);
    s_idx += std.mem.alignForward(usize, compat.len, @sizeOf(u32));

    // FDT_END_NODE (serial) + FDT_END_NODE (root) + FDT_END
    std.mem.writeInt(u32, dtb[s_idx..][0..4], fdt.FDT_END_NODE, .big);
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], fdt.FDT_END_NODE, .big);
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], fdt.FDT_END, .big);

    const info = try fdt.parseHardwareInfo(&dtb);
    try std.testing.expectEqual(@as(?usize, 0x10002000), info.uart_base);
}

test "FDT cell stack isolates child /cpus cells from sibling /memory" {
    var dtb: [512]u8 = @splat(0);
    dtb[0] = 0xd0;
    dtb[1] = 0x0d;
    dtb[2] = 0xfe;
    dtb[3] = 0xed;
    dtb[6] = 0x02;
    dtb[7] = 0x00; // totalsize = 512
    dtb[11] = 48; // off_dt_struct = 48
    dtb[14] = 0x01;
    dtb[15] = 0x2c; // off_dt_strings = 300
    dtb[19] = 40; // off_mem_rsvmap = 40
    dtb[23] = 17; // version = 17
    dtb[27] = 16; // last_comp_version = 16
    dtb[35] = 64; // size_dt_strings = 64
    dtb[39] = 200; // size_dt_struct = 200

    const str_table = dtb[300..];
    @memcpy(str_table[0..4], "reg\x00");
    @memcpy(str_table[4..19], "#address-cells\x00");
    @memcpy(str_table[19..31], "#size-cells\x00");

    var s_idx: usize = 48;

    // Root node "/" with #address-cells = 2, #size-cells = 2
    std.mem.writeInt(u32, dtb[s_idx..][0..4], fdt.FDT_BEGIN_NODE, .big);
    s_idx += 4;
    dtb[s_idx] = 0;
    s_idx += 4;

    // #address-cells = 2
    std.mem.writeInt(u32, dtb[s_idx..][0..4], fdt.FDT_PROP, .big);
    std.mem.writeInt(u32, dtb[s_idx + 4 ..][0..4], 4, .big);
    std.mem.writeInt(u32, dtb[s_idx + 8 ..][0..4], 4, .big);
    std.mem.writeInt(u32, dtb[s_idx + 12 ..][0..4], 2, .big);
    s_idx += 16;

    // #size-cells = 2
    std.mem.writeInt(u32, dtb[s_idx..][0..4], fdt.FDT_PROP, .big);
    std.mem.writeInt(u32, dtb[s_idx + 4 ..][0..4], 4, .big);
    std.mem.writeInt(u32, dtb[s_idx + 8 ..][0..4], 19, .big);
    std.mem.writeInt(u32, dtb[s_idx + 12 ..][0..4], 2, .big);
    s_idx += 16;

    // Child node "cpus" with #address-cells = 1, #size-cells = 0
    std.mem.writeInt(u32, dtb[s_idx..][0..4], fdt.FDT_BEGIN_NODE, .big);
    s_idx += 4;
    @memcpy(dtb[s_idx..][0..5], "cpus\x00");
    s_idx += 8;

    std.mem.writeInt(u32, dtb[s_idx..][0..4], fdt.FDT_PROP, .big);
    std.mem.writeInt(u32, dtb[s_idx + 4 ..][0..4], 4, .big);
    std.mem.writeInt(u32, dtb[s_idx + 8 ..][0..4], 4, .big);
    std.mem.writeInt(u32, dtb[s_idx + 12 ..][0..4], 1, .big);
    s_idx += 16;

    std.mem.writeInt(u32, dtb[s_idx..][0..4], fdt.FDT_PROP, .big);
    std.mem.writeInt(u32, dtb[s_idx + 4 ..][0..4], 4, .big);
    std.mem.writeInt(u32, dtb[s_idx + 8 ..][0..4], 19, .big);
    std.mem.writeInt(u32, dtb[s_idx + 12 ..][0..4], 0, .big);
    s_idx += 16;

    std.mem.writeInt(u32, dtb[s_idx..][0..4], fdt.FDT_END_NODE, .big);
    s_idx += 4;

    // Sibling node "memory@80000000" with 64-bit reg = <0x80000000, 0x40000000>
    const mem_name = "memory@80000000";
    std.mem.writeInt(u32, dtb[s_idx..][0..4], fdt.FDT_BEGIN_NODE, .big);
    s_idx += 4;
    @memcpy(dtb[s_idx..][0..mem_name.len], mem_name);
    dtb[s_idx + mem_name.len] = 0;
    s_idx += std.mem.alignForward(usize, mem_name.len + 1, @sizeOf(u32));

    std.mem.writeInt(u32, dtb[s_idx..][0..4], fdt.FDT_PROP, .big);
    std.mem.writeInt(u32, dtb[s_idx + 4 ..][0..4], 16, .big);
    std.mem.writeInt(u32, dtb[s_idx + 8 ..][0..4], 0, .big);
    std.mem.writeInt(u64, dtb[s_idx + 12 ..][0..8], 0x80000000, .big);
    std.mem.writeInt(u64, dtb[s_idx + 20 ..][0..8], 0x40000000, .big);
    s_idx += 28;

    std.mem.writeInt(u32, dtb[s_idx..][0..4], fdt.FDT_END_NODE, .big);
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], fdt.FDT_END_NODE, .big);
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], fdt.FDT_END, .big);

    const info = try fdt.parseHardwareInfo(&dtb);
    try std.testing.expectEqual(@as(u64, 0x80000000), info.ram_base);
    try std.testing.expectEqual(@as(u64, 0x40000000), info.ram_size);
}
