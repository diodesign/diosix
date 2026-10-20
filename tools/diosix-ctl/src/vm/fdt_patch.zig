// Child VM Flattened Device Tree (FDT) Sanitization & Patching.
//
// Strips host-only MMIO nodes, caps `/cpus` to the guest vCPU quota, and
// patches `/memory` `reg` to match the child VM's Stage-2 GPA and RAM size.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const common = @import("../common.zig");
const sysconfig = @import("../sysconfig.zig");

pub const FDT_MAGIC_BE: u32 = 0xd00dfeed;
pub const FDT_OFF_DT_STRUCT: usize = 8;
pub const FDT_OFF_DT_STRINGS: usize = 12;
pub const FDT_MIN_HEADER_SIZE: usize = 32;
pub const FDT_ALIGN: usize = 4;
pub const FDT_PROP_HEADER_SIZE: usize = 8;

pub const FdtToken = enum(u32) {
    begin_node = 1,
    end_node = 2,
    prop = 3,
    nop = 4,
    end = 9,
    _,
};

const HOST_FDT_PREFIXES = [_][]const u8{
    "virtio_mmio@",  "pci@",  "pcie@",  "serial@",
    "uart@",         "rtc@",  "flash@", "fw-cfg@",
    "platform-bus@", "plic@", "clint@", "aliases",
};

fn readBeU32(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off .. off + 4][0..4], .big);
}

fn writeBeU32(buf: []u8, off: usize, val: u32) void {
    std.mem.writeInt(u32, buf[off .. off + 4][0..4], val, .big);
}

fn writeBeU64(buf: []u8, off: usize, val: u64) void {
    std.mem.writeInt(u64, buf[off .. off + 8][0..8], val, .big);
}

fn nopFdtRange(dtb: []u8, start_off: usize, end_off: usize) void {
    const limit = @min(end_off, dtb.len);
    var cur = start_off;
    const nop_val = @backingInt(FdtToken.nop);
    while (cur + FDT_ALIGN <= limit) : (cur += FDT_ALIGN) {
        writeBeU32(dtb, cur, nop_val);
    }
}

fn scanNopSubtree(dtb: []const u8, start_off: usize) usize {
    var depth: usize = 1;
    var scan_off = start_off;
    while (scan_off + FDT_ALIGN <= dtb.len and depth > 0) {
        const sub_tag: FdtToken = @fromBackingInt(
            @intCast(readBeU32(dtb, scan_off)),
        );
        scan_off += FDT_ALIGN;
        switch (sub_tag) {
            .begin_node => {
                while (scan_off < dtb.len and
                    dtb[scan_off] != 0) : (scan_off += 1)
                {}
                scan_off = std.mem.alignForward(usize, scan_off + 1, FDT_ALIGN);
                depth += 1;
            },
            .end_node => depth -= 1,
            .prop => {
                if (scan_off + FDT_PROP_HEADER_SIZE > dtb.len) break;
                const prop_len: usize = readBeU32(dtb, scan_off);
                const step = std.math.add(
                    usize,
                    FDT_PROP_HEADER_SIZE,
                    prop_len,
                ) catch break;
                scan_off = std.math.add(usize, scan_off, step) catch break;
                scan_off = std.mem.alignForward(usize, scan_off, FDT_ALIGN);
            },
            .nop => {},
            .end => break,
            _ => break,
        }
    }
    return @min(scan_off, dtb.len);
}

/// Reads the host FDT (`/sys/firmware/fdt`) or a custom `--dtb` file into a
/// writable anonymous mapping ready for `patchChildDtb`.
pub fn loadHostOrCustomDtb(dtb_path: ?[]const u8) []u8 {
    const dtb_src = dtb_path orelse sysconfig.SYS_FIRMWARE_FDT_PATH;
    return common.readBinaryFile(dtb_src, common.MAX_DTB_FILE_SIZE) catch
        @constCast(&[_]u8{});
}

pub fn patchChildDtb(
    dtb: []u8,
    base_gpa: u64,
    ram_bytes: u64,
    vcpus: usize,
) void {
    if (dtb.len < FDT_MIN_HEADER_SIZE) return;
    if (readBeU32(dtb, 0) != FDT_MAGIC_BE) return;

    const off_dt_struct = readBeU32(dtb, FDT_OFF_DT_STRUCT);
    const off_dt_strings = readBeU32(dtb, FDT_OFF_DT_STRINGS);
    if (off_dt_struct >= dtb.len or off_dt_strings >= dtb.len) return;

    var offset: usize = off_dt_struct;
    var in_memory_node = false;

    while (offset + FDT_ALIGN <= dtb.len) {
        const node_tag_offset = offset;
        const tag: FdtToken = @fromBackingInt(@intCast(readBeU32(dtb, offset)));
        offset += FDT_ALIGN;

        switch (tag) {
            .begin_node => {
                const name_start = offset;
                while (offset < dtb.len and dtb[offset] != 0) : (offset += 1) {}
                const name = dtb[name_start..offset];
                offset = std.mem.alignForward(usize, offset + 1, FDT_ALIGN);

                in_memory_node = std.mem.startsWith(u8, name, "memory@") or
                    std.mem.eql(u8, name, "memory");

                var should_nop_node = false;
                for (HOST_FDT_PREFIXES) |prefix| {
                    if (std.mem.startsWith(u8, name, prefix) or
                        std.mem.eql(u8, name, prefix))
                    {
                        should_nop_node = true;
                        break;
                    }
                }
                if (!should_nop_node and std.mem.startsWith(u8, name, "cpu@")) {
                    const cpu_str = name[4..];
                    const cpu_idx = std.fmt.parseInt(usize, cpu_str, 16) catch
                        (std.fmt.parseInt(usize, cpu_str, 10) catch 0);
                    if (cpu_idx >= vcpus) should_nop_node = true;
                }

                if (should_nop_node) {
                    const nop_end = scanNopSubtree(dtb, offset);
                    nopFdtRange(dtb, node_tag_offset, nop_end);
                    offset = nop_end;
                }
            },
            .end_node => in_memory_node = false,
            .prop => {
                if (offset + FDT_PROP_HEADER_SIZE > dtb.len) break;
                const prop_len: usize = readBeU32(dtb, offset);
                const name_off: usize = readBeU32(dtb, offset + 4);
                offset += FDT_PROP_HEADER_SIZE;

                const prop_end = std.math.add(usize, offset, prop_len) catch
                    break;
                if (prop_end > dtb.len) break;

                const str_pos = std.math.add(
                    usize,
                    off_dt_strings,
                    name_off,
                ) catch break;
                if (str_pos < dtb.len) {
                    const str_slice = dtb[str_pos..];
                    var str_len: usize = 0;
                    while (str_len < str_slice.len and
                        str_slice[str_len] != 0) : (str_len += 1)
                    {}
                    const prop_name = str_slice[0..str_len];

                    const DtbProperty = enum { reg, @"stdout-path" };
                    if (std.meta.stringToEnum(DtbProperty, prop_name)) |prop| {
                        switch (prop) {
                            .reg => if (in_memory_node) {
                                if (prop_len >= 16) {
                                    writeBeU64(dtb, offset, base_gpa);
                                    writeBeU64(dtb, offset + 8, ram_bytes);
                                } else if (prop_len >= 8) {
                                    writeBeU32(
                                        dtb,
                                        offset,
                                        @truncate(base_gpa),
                                    );
                                    writeBeU32(
                                        dtb,
                                        offset + 4,
                                        @truncate(ram_bytes),
                                    );
                                }
                            },
                            .@"stdout-path" => {
                                const end_aligned = std.mem.alignForward(
                                    usize,
                                    prop_end,
                                    FDT_ALIGN,
                                );
                                nopFdtRange(dtb, node_tag_offset, end_aligned);
                            },
                        }
                    }
                }

                offset = std.mem.alignForward(usize, prop_end, FDT_ALIGN);
            },
            .nop => {},
            .end => break,
            _ => break,
        }
    }
}

test "vm/fdt_patch: patchChildDtb handles malformed FDT headers safely" {
    std.testing.refAllDecls(@This());
    const malformed_dtb_len: usize = 64;
    var bad_dtb: [malformed_dtb_len]u8 = @splat(0);
    patchChildDtb(&bad_dtb, 0x8000_0000, 0x1000_0000, 1);

    std.mem.writeInt(u32, bad_dtb[0..4], FDT_MAGIC_BE, .big);
    std.mem.writeInt(u32, bad_dtb[8..12], 32, .big);
    std.mem.writeInt(u32, bad_dtb[12..16], 48, .big);
    std.mem.writeInt(
        u32,
        bad_dtb[32..36],
        @backingInt(FdtToken.prop),
        .big,
    );
    std.mem.writeInt(u32, bad_dtb[36..40], 0xffff_ffff, .big);
    patchChildDtb(&bad_dtb, 0x8000_0000, 0x1000_0000, 1);
}
