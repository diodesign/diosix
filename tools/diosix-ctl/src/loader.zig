// Guest ELF64/32 Foreign Memory Loader, FDT Patcher, and Pre-Built Fallbacks.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("api.zig");
const catalog = @import("catalog.zig");
const common = @import("common.zig");

pub const GUEST_SHIM_PATH = "/usr/share/diosix/shim/guest-shim-riscv64.elf";
pub const DEFAULT_GUEST_IMAGE_PATH = "/var/lib/diosix/images/default.elf";
pub const FALLBACK_GUEST_IMAGE_PATH = "/var/lib/diosix/images/micro-guest.elf";
pub const FALLBACK_GUEST_ISO_PATH = "/var/lib/diosix/iso/micro-guest.iso";

pub const SHIM_HEADER_OFFSET: usize = 0x0010_0000;
pub const SHIM_HEADER_MAGIC: u64 = 0x4d49_4853_5853_4f44; // "DOSXSHIM".

pub const FDT_MAGIC_BE: u32 = 0xd00dfeed;
pub const FDT_OFF_DT_STRUCT: usize = 8;
pub const FDT_OFF_DT_STRINGS: usize = 12;
pub const FDT_MIN_HEADER_SIZE: usize = 32;
pub const FDT_ALIGN: usize = 4;
pub const FDT_PROP_HEADER_SIZE: usize = 8;
pub const PAGE_ALIGN: usize = 0x1000;

pub const MAX_FOREIGN_MAP_BYTES: usize = 256 * 1024 * 1024;
pub const DEFAULT_PARENT_MAP_GPA: usize = 0x2_0000_0000;
pub const MAP_CHILD_RW_FLAGS: usize = 3;

pub const FdtToken = enum(u32) {
    begin_node = 1,
    end_node = 2,
    prop = 3,
    nop = 4,
    end = 9,
    _,
};

pub const ELF_MAGIC = "\x7fELF";
pub const ELF_EI_CLASS_OFFSET: usize = 4;
pub const ELFCLASS32: u8 = 1;
pub const ELFCLASS64: u8 = 2;
pub const PT_LOAD: u32 = 1;
pub const ELF32_EHDR_SIZE: usize = 52;
pub const ELF64_EHDR_SIZE: usize = 64;
pub const ELF32_PHDR_SIZE: usize = 32;
pub const ELF64_PHDR_SIZE: usize = 56;
pub const MAX_ELF_PHDRS: u16 = 128;

pub const ELF_E_ENTRY_OFFSET: usize = 24;
pub const ELF32_E_PHOFF_OFFSET: usize = 28;
pub const ELF32_E_PHENTSIZE_OFFSET: usize = 42;
pub const ELF32_E_PHNUM_OFFSET: usize = 44;
pub const ELF64_E_PHOFF_OFFSET: usize = 32;
pub const ELF64_E_PHENTSIZE_OFFSET: usize = 54;
pub const ELF64_E_PHNUM_OFFSET: usize = 56;

pub const ELF32_P_OFFSET: usize = 4;
pub const ELF32_P_VADDR: usize = 8;
pub const ELF32_P_FILESZ: usize = 16;
pub const ELF32_P_MEMSZ: usize = 20;
pub const ELF64_P_OFFSET: usize = 8;
pub const ELF64_P_VADDR: usize = 16;
pub const ELF64_P_FILESZ: usize = 32;
pub const ELF64_P_MEMSZ: usize = 40;

const HOST_FDT_PREFIXES = [_][]const u8{
    "virtio_mmio@",  "pci@",  "pcie@",  "serial@",
    "uart@",         "rtc@",  "flash@", "fw-cfg@",
    "platform-bus@", "plic@", "clint@", "aliases",
};

fn readBeU32(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off .. off + 4][0..4], .big);
}

fn readLeU16(buf: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, buf[off .. off + 2][0..2], .little);
}

fn readLeU32(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off .. off + 4][0..4], .little);
}

fn readLeU64(buf: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, buf[off .. off + 8][0..8], .little);
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

fn readPhdrU64(elf: []const u8, class: u8, off32: usize, off64: usize) u64 {
    return if (class == ELFCLASS32)
        @as(u64, readLeU32(elf, off32))
    else
        readLeU64(elf, off64);
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
    if (elf_data.len < ELF32_EHDR_SIZE) return error.InvalidElfHeader;
    if (!std.mem.eql(u8, elf_data[0..4], ELF_MAGIC)) {
        return error.InvalidElfHeader;
    }

    const class = elf_data[ELF_EI_CLASS_OFFSET];
    var entry_point: u64 = 0;
    var ph_off: usize = 0;
    var ph_num: u16 = 0;
    var ph_size: usize = 0;

    if (class == ELFCLASS32) {
        entry_point = readLeU32(elf_data, ELF_E_ENTRY_OFFSET);
        ph_off = readLeU32(elf_data, ELF32_E_PHOFF_OFFSET);
        ph_size = readLeU16(elf_data, ELF32_E_PHENTSIZE_OFFSET);
        ph_num = readLeU16(elf_data, ELF32_E_PHNUM_OFFSET);
        if (ph_size < ELF32_PHDR_SIZE) return error.InvalidElfHeader;
    } else if (class == ELFCLASS64) {
        if (elf_data.len < ELF64_EHDR_SIZE) return error.InvalidElfHeader;
        entry_point = readLeU64(elf_data, ELF_E_ENTRY_OFFSET);
        const raw_ph_off = readLeU64(elf_data, ELF64_E_PHOFF_OFFSET);
        ph_off = std.math.cast(usize, raw_ph_off) orelse
            return error.SegmentOutOfBounds;
        ph_size = readLeU16(elf_data, ELF64_E_PHENTSIZE_OFFSET);
        ph_num = readLeU16(elf_data, ELF64_E_PHNUM_OFFSET);
        if (ph_size < ELF64_PHDR_SIZE) return error.InvalidElfHeader;
    } else {
        return error.InvalidElfHeader;
    }

    if (ph_num == 0 or ph_num > MAX_ELF_PHDRS) return error.InvalidElfHeader;
    const ph_table_bytes = std.math.mul(usize, ph_size, ph_num) catch
        return error.SegmentOutOfBounds;
    const ph_table_end = std.math.add(usize, ph_off, ph_table_bytes) catch
        return error.SegmentOutOfBounds;
    if (ph_table_end > elf_data.len) return error.SegmentOutOfBounds;

    var min_vaddr: u64 = std.math.maxInt(u64);
    var i: usize = 0;
    while (i < ph_num) : (i += 1) {
        const ph = elf_data[ph_off + (i * ph_size) ..];
        const p_type = readLeU32(ph, 0);
        const p_vaddr = readPhdrU64(ph, class, ELF32_P_VADDR, ELF64_P_VADDR);
        if (p_type == PT_LOAD and p_vaddr < min_vaddr) min_vaddr = p_vaddr;
    }
    if (min_vaddr == std.math.maxInt(u64)) min_vaddr = 0;
    if (entry_point < min_vaddr) return error.InvalidElfHeader;

    const map_size: usize = @min(ram_bytes, MAX_FOREIGN_MAP_BYTES);
    const parent_gpa: usize = DEFAULT_PARENT_MAP_GPA;
    const child_ram = try client.mapChildMemory(
        child_cid,
        base_gpa,
        parent_gpa,
        map_size,
        MAP_CHILD_RW_FLAGS,
    );
    defer client.unmapChildMemory(child_ram, parent_gpa) catch {};

    i = 0;
    while (i < ph_num) : (i += 1) {
        const ph = elf_data[ph_off + (i * ph_size) ..];
        if (readLeU32(ph, 0) != PT_LOAD) continue;

        const p_offset_u64 =
            readPhdrU64(ph, class, ELF32_P_OFFSET, ELF64_P_OFFSET);
        const p_vaddr =
            readPhdrU64(ph, class, ELF32_P_VADDR, ELF64_P_VADDR);
        const p_filesz_u64 =
            readPhdrU64(ph, class, ELF32_P_FILESZ, ELF64_P_FILESZ);
        const p_memsz_u64 =
            readPhdrU64(ph, class, ELF32_P_MEMSZ, ELF64_P_MEMSZ);

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
            std.mem.alignBackward(usize, dtb_offset / 2, PAGE_ALIGN),
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

/// Copies a pre-built guest ELF or ISO9660 image from `/var/lib/diosix`
/// when offline catalog seeding is requested.
pub fn seedOfflineCatalogFallback(
    entry: catalog.CatalogEntry,
    dest_path: []const u8,
) bool {
    const FormatType = enum { elf, iso9660 };
    const fmt = std.meta.stringToEnum(FormatType, entry.format) orelse
        return false;
    const elf_paths = [_][]const u8{
        DEFAULT_GUEST_IMAGE_PATH,
        FALLBACK_GUEST_IMAGE_PATH,
    };
    const iso_paths = [_][]const u8{FALLBACK_GUEST_ISO_PATH};
    const candidates: []const []const u8 = switch (fmt) {
        .elf => &elf_paths,
        .iso9660 => &iso_paths,
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

    std.mem.writeInt(u32, bad_dtb[0..4], FDT_MAGIC_BE, .big);
    std.mem.writeInt(u32, bad_dtb[8..12], 32, .big);
    std.mem.writeInt(u32, bad_dtb[12..16], 48, .big);
    std.mem.writeInt(
        u32,
        bad_dtb[32..36],
        @backingInt(FdtToken.prop),
        .big,
    );
    std.mem.writeInt(u32, bad_dtb[36..40], 0xffff_ffff, .big); // prop_len.
    patchChildDtb(&bad_dtb, 0x8000_0000, 0x1000_0000, 1);
}
