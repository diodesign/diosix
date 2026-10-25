// Guest ELF64/32 Foreign Memory Loader, FDT Patcher, and Pre-Built Fallbacks.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("api.zig");
const console = @import("console.zig");
const sysconfig = @import("sysconfig.zig");
const fdt_patch = @import("vm/fdt_patch.zig");
const pe = @import("loader/pe.zig");

pub const GUEST_SHIM_PATH = sysconfig.GUEST_SHIM_PATH;
pub const DEFAULT_GUEST_IMAGE_PATH = sysconfig.DEFAULT_GUEST_IMAGE_PATH;
pub const FALLBACK_GUEST_IMAGE_PATH = sysconfig.FALLBACK_GUEST_IMAGE_PATH;
pub const FALLBACK_GUEST_ISO_PATH = sysconfig.FALLBACK_GUEST_ISO_PATH;

pub const SHIM_HEADER_OFFSET: usize = pe.SHIM_HEADER_OFFSET;
pub const SHIM_HEADER_MAGIC: u64 = pe.SHIM_HEADER_MAGIC;
pub const PAGE_ALIGN: usize = pe.PAGE_ALIGN;
pub const seedOfflineCatalogFallback = pe.seedOfflineCatalogFallback;

pub const FDT_MAGIC_BE: u32 = fdt_patch.FDT_MAGIC_BE;
pub const FDT_OFF_DT_STRUCT: usize = fdt_patch.FDT_OFF_DT_STRUCT;
pub const FDT_OFF_DT_STRINGS: usize = fdt_patch.FDT_OFF_DT_STRINGS;
pub const FDT_MIN_HEADER_SIZE: usize = fdt_patch.FDT_MIN_HEADER_SIZE;
pub const FDT_ALIGN: usize = fdt_patch.FDT_ALIGN;
pub const FDT_PROP_HEADER_SIZE: usize = fdt_patch.FDT_PROP_HEADER_SIZE;
pub const FdtToken = fdt_patch.FdtToken;
pub const patchChildDtb = fdt_patch.patchChildDtb;

pub const MAX_FOREIGN_MAP_BYTES: usize = 256 * 1024 * 1024;
pub const DEFAULT_PARENT_MAP_GPA: usize = 0x2_0000_0000;
pub const MAP_CHILD_RW_FLAGS: usize = 3;

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

fn readLeU16(buf: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, buf[off .. off + 2][0..2], .little);
}

fn readLeU32(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off .. off + 4][0..4], .little);
}

fn readLeU64(buf: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, buf[off .. off + 8][0..8], .little);
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
    var load_seg_total: usize = 0;
    var i: usize = 0;
    while (i < ph_num) : (i += 1) {
        const ph = elf_data[ph_off + (i * ph_size) ..];
        const p_type = readLeU32(ph, 0);
        const p_vaddr = readPhdrU64(ph, class, ELF32_P_VADDR, ELF64_P_VADDR);
        if (p_type == PT_LOAD) {
            load_seg_total += 1;
            if (p_vaddr < min_vaddr) min_vaddr = p_vaddr;
        }
    }
    if (min_vaddr == std.math.maxInt(u64)) min_vaddr = 0;
    if (entry_point < min_vaddr) return error.InvalidElfHeader;

    const parent_gpa: usize = DEFAULT_PARENT_MAP_GPA;
    const dtb_offset = if (ram_bytes > 4 * 1024 * 1024)
        ram_bytes - (3 * 1024 * 1024)
    else
        0;

    var seg_idx: usize = 0;
    i = 0;
    while (i < ph_num) : (i += 1) {
        const ph = elf_data[ph_off + (i * ph_size) ..];
        if (readLeU32(ph, 0) != PT_LOAD) continue;
        seg_idx += 1;

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
        if (p_memsz == 0) continue;
        const seg_offset = std.math.cast(usize, p_vaddr - min_vaddr) orelse
            return error.SegmentOutOfBounds;

        const src_end = std.math.add(usize, p_offset, p_filesz) catch
            return error.SegmentOutOfBounds;
        if (src_end > elf_data.len) return error.SegmentOutOfBounds;

        const seg_end = std.math.add(usize, seg_offset, p_memsz) catch
            return error.SegmentOutOfBounds;
        if (seg_end > ram_bytes) return error.SegmentOutOfBounds;

        const aligned_start = std.mem.alignBackward(usize, seg_offset, 4096);
        const aligned_end = std.mem.alignForward(usize, seg_end, 4096);
        const seg_map_sz = aligned_end - aligned_start;
        if (seg_map_sz > MAX_FOREIGN_MAP_BYTES) return error.SegmentOutOfBounds;

        const pct = 30 + (seg_idx * 55) / @max(@as(usize, 1), load_seg_total);
        console.printFmt(
            "[{d}%] Loading guest ELF segment {d}/{d} ({d} KB)...\n",
            .{ pct, seg_idx, load_seg_total, p_memsz / 1024 },
        );

        const seg_ram = try client.mapChildMemory(
            child_cid,
            base_gpa + aligned_start,
            parent_gpa,
            seg_map_sz,
            MAP_CHILD_RW_FLAGS,
        );
        defer client.unmapChildMemory(seg_ram, parent_gpa) catch {};

        const rel_start = seg_offset - aligned_start;
        const rel_file_end = rel_start + p_filesz;
        const rel_seg_end = rel_start + p_memsz;
        if (p_filesz > 0) {
            @memcpy(
                seg_ram[rel_start..rel_file_end],
                elf_data[p_offset..src_end],
            );
        }
        if (p_memsz > p_filesz) {
            @memset(seg_ram[rel_file_end..rel_seg_end], 0);
        }
    }

    const entry_off = std.math.cast(usize, entry_point - min_vaddr) orelse
        return error.InvalidElfHeader;
    if (entry_off >= ram_bytes) return error.SegmentOutOfBounds;
    const entry_gpa = std.math.add(usize, base_gpa, entry_off) catch
        return error.SegmentOutOfBounds;

    var dtb_gpa: usize = 0;
    if (dtb_data.len > 0) {
        const dtb_end = std.math.add(usize, dtb_offset, dtb_data.len) catch
            return error.SegmentOutOfBounds;
        if (dtb_end > ram_bytes) return error.SegmentOutOfBounds;
        patchChildDtb(dtb_data, base_gpa, @intCast(ram_bytes), vcpus);
        dtb_gpa = std.math.add(usize, base_gpa, dtb_offset) catch
            return error.SegmentOutOfBounds;
        const dtb_aligned = std.mem.alignBackward(usize, dtb_offset, 4096);
        const dtb_end_aligned = std.mem.alignForward(usize, dtb_end, 4096);
        const dtb_map_sz = dtb_end_aligned - dtb_aligned;
        const dtb_ram = try client.mapChildMemory(
            child_cid,
            base_gpa + dtb_aligned,
            parent_gpa,
            dtb_map_sz,
            MAP_CHILD_RW_FLAGS,
        );
        defer client.unmapChildMemory(dtb_ram, parent_gpa) catch {};
        const rel_dtb = dtb_offset - dtb_aligned;
        @memcpy(dtb_ram[rel_dtb .. rel_dtb + dtb_data.len], dtb_data);
    }

    if (shim_payload.len > 0) {
        const map_size: usize = @min(ram_bytes, MAX_FOREIGN_MAP_BYTES);
        const child_ram = try client.mapChildMemory(
            child_cid,
            base_gpa,
            parent_gpa,
            map_size,
            MAP_CHILD_RW_FLAGS,
        );
        defer client.unmapChildMemory(child_ram, parent_gpa) catch {};
        try pe.stageShimPayload(child_ram, shim_payload, dtb_offset);
    }

    console.printStr(
        "[95%] Configuring device tree and starting guest vCPUs...\n",
    );
    _ = try client.startGuest(child_cid, entry_gpa, dtb_gpa);
    return entry_gpa;
}

test "loader: patchChildDtb handles malformed FDT headers safely" {
    std.testing.refAllDecls(@This());
    _ = fdt_patch;
    _ = pe;
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
