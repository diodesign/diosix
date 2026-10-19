// Guest ELF64/32 Foreign Memory Loader, FDT Patcher, and Pre-Built Fallbacks.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("api.zig");
const catalog = @import("catalog.zig");
const common = @import("common.zig");

pub const GUEST_SHIM_CANDIDATES = [_][]const u8{
    "/usr/share/diosix/shim/guest-shim-riscv64.elf",
    "/var/lib/diosix/images/guest-shim.elf",
    "/boot/guest-shim.elf",
};

pub const DEFAULT_GUEST_CANDIDATES = [_][]const u8{
    "/var/lib/diosix/images/linux-guest.elf",
    "/boot/vmlinux.elf",
    "/boot/linux-guest.elf",
    "/var/lib/diosix/images/default.elf",
    "/boot/default.elf",
    "/var/lib/diosix/images/micro-guest.elf",
    "/boot/micro-guest.elf",
};

pub const FALLBACK_ISO_CANDIDATES = [_][]const u8{
    "/var/lib/diosix/images/micro-guest.iso",
    "/boot/micro-guest.iso",
};

pub const SHIM_HEADER_OFFSET: usize = 0x0010_0000;
pub const SHIM_HEADER_MAGIC: u64 = 0x4d49_4853_5853_4f44; // "DOSXSHIM".

const HOST_FDT_PREFIXES = [_][]const u8{
    "virtio_mmio@",  "pci@",  "pcie@",  "serial@",
    "uart@",         "rtc@",  "flash@", "fw-cfg@",
    "platform-bus@", "plic@", "clint@", "aliases",
};

fn nopFdtRange(dtb: []u8, start_off: usize, end_off: usize) void {
    const limit = @min(end_off, dtb.len);
    var cur = start_off;
    while (cur + 4 <= limit) : (cur += 4) {
        std.mem.writeInt(u32, dtb[cur .. cur + 4][0..4], 4, .big);
    }
}

fn scanNopSubtree(dtb: []const u8, start_off: usize) usize {
    var depth: usize = 1;
    var scan_off = start_off;
    while (scan_off + 4 <= dtb.len and depth > 0) {
        const sub_tag = std.mem.readInt(
            u32,
            dtb[scan_off .. scan_off + 4][0..4],
            .big,
        );
        scan_off += 4;
        switch (sub_tag) {
            1 => { // Nested FDT_BEGIN_NODE.
                while (scan_off < dtb.len and
                    dtb[scan_off] != 0) : (scan_off += 1)
                {}
                scan_off = (scan_off + 4) & ~@as(usize, 3);
                depth += 1;
            },
            2 => depth -= 1, // FDT_END_NODE.
            3 => { // FDT_PROP.
                if (scan_off + 8 > dtb.len) break;
                const prop_len: usize = std.mem.readInt(
                    u32,
                    dtb[scan_off .. scan_off + 4][0..4],
                    .big,
                );
                const step = std.math.add(usize, 8, prop_len) catch break;
                scan_off = std.math.add(usize, scan_off, step) catch break;
                scan_off = (scan_off + 3) & ~@as(usize, 3);
            },
            4 => {}, // FDT_NOP.
            9 => break, // FDT_END.
            else => break,
        }
    }
    return @min(scan_off, dtb.len);
}

pub fn patchChildDtb(
    dtb: []u8,
    base_gpa: u64,
    ram_bytes: u64,
    vcpus: usize,
) void {
    if (dtb.len < 32) return;
    if (dtb[0] != 0xd0 or dtb[1] != 0x0d or dtb[2] != 0xfe or dtb[3] != 0xed) {
        return;
    }

    const off_dt_struct = std.mem.readInt(u32, dtb[8..12][0..4], .big);
    const off_dt_strings = std.mem.readInt(u32, dtb[12..16][0..4], .big);
    if (off_dt_struct >= dtb.len or off_dt_strings >= dtb.len) return;

    var offset: usize = off_dt_struct;
    var in_memory_node = false;

    while (offset + 4 <= dtb.len) {
        const node_tag_offset = offset;
        const tag = std.mem.readInt(u32, dtb[offset .. offset + 4][0..4], .big);
        offset += 4;

        switch (tag) {
            1 => { // FDT_BEGIN_NODE.
                const name_start = offset;
                while (offset < dtb.len and dtb[offset] != 0) : (offset += 1) {}
                const name = dtb[name_start..offset];
                offset = (offset + 4) & ~@as(usize, 3);

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
            2 => in_memory_node = false, // FDT_END_NODE.
            3 => { // FDT_PROP.
                if (offset + 8 > dtb.len) break;
                const prop_len: usize = std.mem.readInt(
                    u32,
                    dtb[offset .. offset + 4][0..4],
                    .big,
                );
                const name_off: usize = std.mem.readInt(
                    u32,
                    dtb[offset + 4 .. offset + 8][0..4],
                    .big,
                );
                offset += 8;

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
                                    std.mem.writeInt(
                                        u64,
                                        dtb[offset .. offset + 8][0..8],
                                        base_gpa,
                                        .big,
                                    );
                                    std.mem.writeInt(
                                        u64,
                                        dtb[offset + 8 .. offset + 16][0..8],
                                        ram_bytes,
                                        .big,
                                    );
                                } else if (prop_len >= 8) {
                                    std.mem.writeInt(
                                        u32,
                                        dtb[offset .. offset + 4][0..4],
                                        @truncate(base_gpa),
                                        .big,
                                    );
                                    std.mem.writeInt(
                                        u32,
                                        dtb[offset + 4 .. offset + 8][0..4],
                                        @truncate(ram_bytes),
                                        .big,
                                    );
                                }
                            },
                            .@"stdout-path" => {
                                const end_aligned =
                                    (prop_end + 3) & ~@as(usize, 3);
                                nopFdtRange(dtb, node_tag_offset, end_aligned);
                            },
                        }
                    }
                }

                offset = (prop_end + 3) & ~@as(usize, 3);
            },
            4 => {}, // FDT_NOP.
            9 => break, // FDT_END.
            else => break,
        }
    }
}

fn readPhdrU64(elf: []const u8, class: u8, off32: usize, off64: usize) u64 {
    return if (class == 1)
        @as(u64, std.mem.readInt(u32, elf[off32 .. off32 + 4][0..4], .little))
    else
        std.mem.readInt(u64, elf[off64 .. off64 + 8][0..8], .little);
}

pub fn loadElfViaForeignMapping(
    client: *api.DiosixClient,
    child_cid: usize,
    elf_data: []const u8,
    dtb_data: []u8,
    shim_payload: []const u8,
    base_gpa: usize,
    ram_bytes: usize,
    vcpus: usize,
) !usize {
    if (elf_data.len < 52) return error.InvalidElfHeader;
    if (!std.mem.eql(u8, elf_data[0..4], "\x7fELF")) {
        return error.InvalidElfHeader;
    }

    const class = elf_data[4];
    var entry_point: u64 = 0;
    var ph_off: usize = 0;
    var ph_num: u16 = 0;
    var ph_size: usize = 0;

    if (class == 1) { // 32-bit ELF.
        entry_point = std.mem.readInt(u32, elf_data[24..28][0..4], .little);
        ph_off = std.mem.readInt(u32, elf_data[28..32][0..4], .little);
        ph_size = std.mem.readInt(u16, elf_data[42..44][0..2], .little);
        ph_num = std.mem.readInt(u16, elf_data[44..46][0..2], .little);
        if (ph_size < 32) return error.InvalidElfHeader;
    } else if (class == 2) { // 64-bit ELF.
        if (elf_data.len < 64) return error.InvalidElfHeader;
        entry_point = std.mem.readInt(u64, elf_data[24..32][0..8], .little);
        const raw_ph_off =
            std.mem.readInt(u64, elf_data[32..40][0..8], .little);
        ph_off = std.math.cast(usize, raw_ph_off) orelse
            return error.SegmentOutOfBounds;
        ph_size = std.mem.readInt(u16, elf_data[54..56][0..2], .little);
        ph_num = std.mem.readInt(u16, elf_data[56..58][0..2], .little);
        if (ph_size < 56) return error.InvalidElfHeader;
    } else {
        return error.InvalidElfHeader;
    }

    if (ph_num == 0 or ph_num > 128) return error.InvalidElfHeader;
    const ph_table_bytes = std.math.mul(usize, ph_size, ph_num) catch
        return error.SegmentOutOfBounds;
    const ph_table_end = std.math.add(usize, ph_off, ph_table_bytes) catch
        return error.SegmentOutOfBounds;
    if (ph_table_end > elf_data.len) return error.SegmentOutOfBounds;

    var min_vaddr: u64 = std.math.maxInt(u64);
    var i: usize = 0;
    while (i < ph_num) : (i += 1) {
        const off = ph_off + (i * ph_size);
        const p_type =
            std.mem.readInt(u32, elf_data[off .. off + 4][0..4], .little);
        const p_vaddr = readPhdrU64(elf_data, class, off + 8, off + 16);
        if (p_type == 1 and p_vaddr < min_vaddr) min_vaddr = p_vaddr;
    }
    if (min_vaddr == std.math.maxInt(u64)) min_vaddr = 0;
    if (entry_point < min_vaddr) return error.InvalidElfHeader;

    const map_size = @min(ram_bytes, 256 * 1024 * 1024);
    const parent_gpa: usize = 0x2_0000_0000;
    const child_ram = try client.mapChildMemory(
        child_cid,
        base_gpa,
        parent_gpa,
        map_size,
        3,
    );
    defer client.unmapChildMemory(child_ram, parent_gpa) catch {};

    i = 0;
    while (i < ph_num) : (i += 1) {
        const off = ph_off + (i * ph_size);
        const p_type =
            std.mem.readInt(u32, elf_data[off .. off + 4][0..4], .little);
        if (p_type != 1) continue; // Only PT_LOAD.

        const p_offset_u64 = readPhdrU64(elf_data, class, off + 4, off + 8);
        const p_vaddr = readPhdrU64(elf_data, class, off + 8, off + 16);
        const p_filesz_u64 = readPhdrU64(elf_data, class, off + 16, off + 32);
        const p_memsz_u64 = readPhdrU64(elf_data, class, off + 20, off + 40);

        if (p_filesz_u64 > p_memsz_u64 or p_vaddr < min_vaddr) {
            return error.SegmentOutOfBounds;
        }
        const p_offset = std.math.cast(usize, p_offset_u64) orelse
            return error.SegmentOutOfBounds;
        const p_filesz = std.math.cast(usize, p_filesz_u64) orelse
            return error.SegmentOutOfBounds;
        const p_memsz = std.math.cast(usize, p_memsz_u64) orelse
            return error.SegmentOutOfBounds;
        const seg_offset = std.math.cast(usize, p_vaddr - min_vaddr) orelse
            return error.SegmentOutOfBounds;

        const src_end = std.math.add(usize, p_offset, p_filesz) catch
            return error.SegmentOutOfBounds;
        if (src_end > elf_data.len) return error.SegmentOutOfBounds;

        const file_end = std.math.add(usize, seg_offset, p_filesz) catch
            return error.SegmentOutOfBounds;
        const seg_end = std.math.add(usize, seg_offset, p_memsz) catch
            return error.SegmentOutOfBounds;
        if (seg_end > child_ram.len) return error.SegmentOutOfBounds;

        if (p_filesz > 0) {
            @memcpy(
                child_ram[seg_offset..file_end],
                elf_data[p_offset..src_end],
            );
        }
        if (p_memsz > p_filesz) {
            @memset(child_ram[file_end..seg_end], 0);
        }
    }

    const entry_off = std.math.cast(usize, entry_point - min_vaddr) orelse
        return error.InvalidElfHeader;
    if (entry_off >= child_ram.len) return error.SegmentOutOfBounds;
    const entry_gpa = std.math.add(usize, base_gpa, entry_off) catch
        return error.SegmentOutOfBounds;
    const dtb_offset = if (child_ram.len > 4 * 1024 * 1024)
        child_ram.len - (3 * 1024 * 1024)
    else
        0;
    var dtb_gpa: usize = 0;
    if (dtb_data.len > 0) {
        const dtb_end = std.math.add(usize, dtb_offset, dtb_data.len) catch
            return error.SegmentOutOfBounds;
        if (dtb_end > child_ram.len) return error.SegmentOutOfBounds;
        patchChildDtb(dtb_data, base_gpa, @intCast(ram_bytes), vcpus);
        dtb_gpa = std.math.add(usize, base_gpa, dtb_offset) catch
            return error.SegmentOutOfBounds;
        @memcpy(child_ram[dtb_offset..dtb_end], dtb_data);
    }

    if (shim_payload.len > 0 and
        dtb_offset > 0x0080_0000 and
        SHIM_HEADER_OFFSET + 24 <= child_ram.len)
    {
        const payload_offset = @max(
            @as(usize, 0x0040_0000),
            (dtb_offset / 2) & ~@as(usize, 0xfff),
        );
        if (payload_offset >= dtb_offset) return error.SegmentOutOfBounds;
        const max_stage = dtb_offset - payload_offset;
        if (shim_payload.len > max_stage) return error.SegmentOutOfBounds;
        const copy_len = shim_payload.len;
        @memcpy(
            child_ram[payload_offset .. payload_offset + copy_len],
            shim_payload[0..copy_len],
        );
        const hdr = child_ram[SHIM_HEADER_OFFSET .. SHIM_HEADER_OFFSET + 24];
        std.mem.writeInt(u64, hdr[0..8], SHIM_HEADER_MAGIC, .little);
        std.mem.writeInt(u64, hdr[8..16], payload_offset, .little);
        std.mem.writeInt(u64, hdr[16..24], copy_len, .little);
    }

    _ = try client.startGuest(child_cid, entry_gpa, dtb_gpa);
    return entry_gpa;
}

/// Copies a pre-built guest ELF or ISO9660 image from `/boot` or
/// `/var/lib/diosix/images` when offline catalog seeding is requested.
pub fn seedOfflineCatalogFallback(
    entry: catalog.CatalogEntry,
    dest_path: []const u8,
) bool {
    const FormatType = enum { elf, iso9660 };
    const fmt = std.meta.stringToEnum(FormatType, entry.format) orelse
        return false;
    const candidates: []const []const u8 = switch (fmt) {
        .elf => &DEFAULT_GUEST_CANDIDATES,
        .iso9660 => &FALLBACK_ISO_CANDIDATES,
    };
    for (candidates) |cand| {
        if (common.readBinaryFile(cand, common.MAX_ELF_FILE_SIZE)) |data| {
            defer common.unmapBinaryFile(data);
            if (common.writeFile(dest_path, data)) |_| {
                return true;
            } else |_| {}
        } else |_| {}
    }
    return false;
}

test "loader: patchChildDtb handles malformed FDT headers safely" {
    std.testing.refAllDecls(@This());
    var bad_dtb: [64]u8 = @splat(0);
    patchChildDtb(&bad_dtb, 0x8000_0000, 0x1000_0000, 1);

    bad_dtb[0] = 0xd0;
    bad_dtb[1] = 0x0d;
    bad_dtb[2] = 0xfe;
    bad_dtb[3] = 0xed;
    std.mem.writeInt(u32, bad_dtb[8..12], 32, .big);
    std.mem.writeInt(u32, bad_dtb[12..16], 48, .big);
    std.mem.writeInt(u32, bad_dtb[32..36], 3, .big); // FDT_PROP.
    std.mem.writeInt(u32, bad_dtb[36..40], 0xffff_ffff, .big); // prop_len.
    patchChildDtb(&bad_dtb, 0x8000_0000, 0x1000_0000, 1);
}
