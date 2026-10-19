// Diosix S-Mode Guest Bootloader Shim — Multi-OS Format & Storage Parser.
//
// Provides freestanding, allocation-free, bounds-checked parsers and loaders
// for booting any S/U-mode guest OS (Linux, FreeBSD, OpenBSD, NetBSD, QNX,
// Haiku, or custom microkernels) from installer ISOs or virtual disks:
//   - Executable formats: ELF64, ELF32, RISC-V flat Image ("RSC\x05"), and
//     PE32+ EFI applications (.efi) with a minimal EFI_SYSTEM_TABLE handoff.
//   - Partition & filesystem structures: GPT, MBR, ISO9660 (Primary Volume
//     Descriptor + El Torito Boot Record + Root Directory traversal), FAT32,
//     ext2/ext4, and BSD UFS2 superblock detection (in `storage.zig`).
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
pub const storage = @import("storage.zig");
pub const pe_efi = @import("efi.zig");

// Re-export storage and PE32+ EFI symbols used by callers.
pub const SECTOR_SIZE = storage.SECTOR_SIZE;
pub const ISO_SECTOR_SIZE = storage.ISO_SECTOR_SIZE;
pub const StorageFormat = storage.StorageFormat;
pub const MbrPartition = storage.MbrPartition;
pub const GptPartition = storage.GptPartition;
pub const IsoVolumeInfo = storage.IsoVolumeInfo;
pub const IsoFileExtent = storage.IsoFileExtent;
pub const detectStorageFormat = storage.detectStorageFormat;
pub const parseMbrPartitions = storage.parseMbrPartitions;
pub const parseGptPartitions = storage.parseGptPartitions;
pub const parseIso9660Volume = storage.parseIso9660Volume;
pub const findIso9660FileInDir = storage.findIso9660FileInDir;
pub const findIso9660Path = storage.findIso9660Path;

pub const MZ_SIGNATURE = pe_efi.MZ_SIGNATURE;
pub const DOS_HEADER_MIN_SIZE = pe_efi.DOS_HEADER_MIN_SIZE;
pub const PE_LFA_NEW_OFFSET = pe_efi.PE_LFA_NEW_OFFSET;
pub const PE_SIGNATURE = pe_efi.PE_SIGNATURE;
pub const COFF_HEADER_SIZE = pe_efi.COFF_HEADER_SIZE;
pub const IMAGE_FILE_MACHINE_RISCV64 = pe_efi.IMAGE_FILE_MACHINE_RISCV64;
pub const PE32_PLUS_MAGIC = pe_efi.PE32_PLUS_MAGIC;
pub const EfiTableHeader = pe_efi.EfiTableHeader;
pub const EfiBootServices64 = pe_efi.EfiBootServices64;
pub const EfiSystemTable64 = pe_efi.EfiSystemTable64;
pub const loadPe32PlusEfi = pe_efi.loadPe32PlusEfi;
pub const initMinimalEfiTables = pe_efi.initMinimalEfiTables;

// Executable format constants and ELF header/segment field offsets.
pub const ELF_MAGIC = "\x7fELF";
pub const ELF_EI_CLASS: usize = 4;
pub const ELF_EI_DATA: usize = 5;
pub const ELF_CLASS_32: u8 = 1;
pub const ELF_CLASS_64: u8 = 2;
pub const ELF_DATA_LSB: u8 = 1;
pub const ELF32_EHDR_SIZE: usize = 52;
pub const ELF64_EHDR_SIZE: usize = 64;
pub const ELF32_E_ENTRY_OFFSET: usize = 24;
pub const ELF32_E_PHOFF_OFFSET: usize = 28;
pub const ELF32_E_PHENTSIZE_OFFSET: usize = 42;
pub const ELF32_E_PHNUM_OFFSET: usize = 44;
pub const ELF64_E_ENTRY_OFFSET: usize = 24;
pub const ELF64_E_PHOFF_OFFSET: usize = 32;
pub const ELF64_E_PHENTSIZE_OFFSET: usize = 54;
pub const ELF64_E_PHNUM_OFFSET: usize = 56;
pub const ELF32_PHDR_SIZE: usize = 32;
pub const ELF64_PHDR_SIZE: usize = 56;
pub const ELF32_P_OFFSET_OFFSET: usize = 4;
pub const ELF32_P_VADDR_OFFSET: usize = 8;
pub const ELF32_P_FILESZ_OFFSET: usize = 16;
pub const ELF32_P_MEMSZ_OFFSET: usize = 20;
pub const ELF64_P_OFFSET_OFFSET: usize = 8;
pub const ELF64_P_VADDR_OFFSET: usize = 16;
pub const ELF64_P_FILESZ_OFFSET: usize = 32;
pub const ELF64_P_MEMSZ_OFFSET: usize = 40;
pub const PT_LOAD: u32 = 1;
pub const MAX_ELF_PHDRS: u16 = 128;

// RISC-V Linux / BSD flat Image header constants.
pub const RISCV_IMAGE_HEADER_SIZE: usize = 64;
pub const RISCV_IMAGE_TEXT_OFFSET_POS: usize = 8;
pub const RISCV_IMAGE_SIZE_POS: usize = 16;
pub const RISCV_IMAGE_FLAGS_POS: usize = 24;
pub const RISCV_IMAGE_VERSION_POS: usize = 32;
pub const RISCV_IMAGE_MAGIC_POS: usize = 48;
pub const RISCV_IMAGE_MAGIC2_POS: usize = 56;
pub const RISCV_IMAGE_MAGIC_LEGACY: u32 =
    std.mem.readInt(u32, "RSCV", .little);
pub const RISCV_IMAGE_MAGIC2: u32 =
    std.mem.readInt(u32, "RSC\x05", .little);

// Diosix Shim Staging Header Constants (+1 MiB into Guest RAM).
pub const SHIM_HEADER_OFFSET: usize = 0x0010_0000;
pub const SHIM_HEADER_MAGIC: u64 = std.mem.readInt(u64, "DOSXSHIM", .little);
pub const SHIM_HDR_MAGIC_OFFSET: usize = 0;
pub const SHIM_HDR_PAYLOAD_OFF_OFFSET: usize = 8;
pub const SHIM_HDR_PAYLOAD_LEN_OFFSET: usize = 16;
pub const SHIM_KERNEL_DEST_OFFSET: usize = 0x0020_0000; // +2 MiB PMD aligned.
pub const RISCV_DRAM_BASE: u64 = 0x8000_0000;

pub const BootLoaderError = error{
    BufferTooSmall,
    UnknownKernelFormat,
    InvalidElfHeader,
    UnsupportedElfClass,
    UnsupportedElfEndian,
    SegmentOutOfBounds,
    DestinationOutOfBounds,
    NoLoadableSegments,
    InvalidRiscvImageHeader,
    InvalidPeHeader,
    UnsupportedPeMachine,
    InvalidGptHeader,
    InvalidMbrSignature,
    InvalidIsoVolume,
    FileNotFound,
};

pub const KernelFormat = enum {
    elf64,
    elf32,
    riscv_image,
    pe32_plus_efi,
    unknown,
};

pub const KernelLoadResult = struct {
    format: KernelFormat,
    entry_offset: usize,
    loaded_end_offset: usize,
    preferred_base_gpa: u64,
};

inline fn readU16Le(buf: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, buf[off..][0..2], .little);
}

inline fn readU32Le(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off..][0..4], .little);
}

inline fn readU64Le(buf: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, buf[off..][0..8], .little);
}

pub fn detectKernelFormat(data: []const u8) KernelFormat {
    if (data.len >= ELF64_EHDR_SIZE and
        std.mem.eql(u8, data[0..ELF_MAGIC.len], ELF_MAGIC))
    {
        return switch (data[ELF_EI_CLASS]) {
            ELF_CLASS_64 => .elf64,
            ELF_CLASS_32 => .elf32,
            else => .unknown,
        };
    }

    if (data.len >= RISCV_IMAGE_HEADER_SIZE) {
        const magic1 = readU32Le(data, RISCV_IMAGE_MAGIC_POS);
        const magic2 = readU32Le(data, RISCV_IMAGE_MAGIC2_POS);
        if (magic2 == RISCV_IMAGE_MAGIC2 or
            magic1 == RISCV_IMAGE_MAGIC_LEGACY)
        {
            return .riscv_image;
        }
    }

    if (data.len >= DOS_HEADER_MIN_SIZE) {
        if (readU16Le(data, 0) == MZ_SIGNATURE) {
            const pe_off = readU32Le(data, PE_LFA_NEW_OFFSET);
            const pe_end = std.math.add(
                usize,
                pe_off,
                pe_efi.PE_SIGNATURE_SIZE + COFF_HEADER_SIZE + 2,
            ) catch return .unknown;
            if (pe_end <= data.len) {
                const pe_sig = readU32Le(data, pe_off);
                const opt_magic_off =
                    pe_off + pe_efi.PE_SIGNATURE_SIZE + COFF_HEADER_SIZE;
                const opt_magic = readU16Le(data, opt_magic_off);
                if (pe_sig == PE_SIGNATURE and opt_magic == PE32_PLUS_MAGIC) {
                    return .pe32_plus_efi;
                }
            }
        }
    }

    return .unknown;
}

/// Loads an ELF32 or ELF64 kernel image into `dest_buf`, zeroing BSS segments.
pub fn loadElfKernel(
    elf_data: []const u8,
    dest_buf: []u8,
) BootLoaderError!KernelLoadResult {
    if (elf_data.len < ELF32_EHDR_SIZE) return error.InvalidElfHeader;
    if (!std.mem.eql(u8, elf_data[0..ELF_MAGIC.len], ELF_MAGIC)) {
        return error.InvalidElfHeader;
    }

    const class = elf_data[ELF_EI_CLASS];
    const endian = elf_data[ELF_EI_DATA];
    if (endian != ELF_DATA_LSB) return error.UnsupportedElfEndian;

    var entry_point: u64 = 0;
    var ph_off: usize = 0;
    var ph_size: usize = 0;
    var ph_num: u16 = 0;
    var fmt: KernelFormat = .elf64;

    if (class == ELF_CLASS_32) {
        fmt = .elf32;
        entry_point = readU32Le(elf_data, ELF32_E_ENTRY_OFFSET);
        ph_off = readU32Le(elf_data, ELF32_E_PHOFF_OFFSET);
        ph_size = readU16Le(elf_data, ELF32_E_PHENTSIZE_OFFSET);
        ph_num = readU16Le(elf_data, ELF32_E_PHNUM_OFFSET);
        if (ph_size < ELF32_PHDR_SIZE) return error.InvalidElfHeader;
    } else if (class == ELF_CLASS_64) {
        if (elf_data.len < ELF64_EHDR_SIZE) return error.InvalidElfHeader;
        fmt = .elf64;
        const raw_ph_off = readU64Le(elf_data, ELF64_E_PHOFF_OFFSET);
        ph_off = std.math.cast(
            usize,
            raw_ph_off,
        ) orelse return error.SegmentOutOfBounds;
        entry_point = readU64Le(elf_data, ELF64_E_ENTRY_OFFSET);
        ph_size = readU16Le(elf_data, ELF64_E_PHENTSIZE_OFFSET);
        ph_num = readU16Le(elf_data, ELF64_E_PHNUM_OFFSET);
        if (ph_size < ELF64_PHDR_SIZE) return error.InvalidElfHeader;
    } else {
        return error.UnsupportedElfClass;
    }

    if (ph_num == 0 or ph_num > MAX_ELF_PHDRS) return error.InvalidElfHeader;
    const ph_table_bytes = std.math.mul(
        usize,
        ph_size,
        ph_num,
    ) catch return error.SegmentOutOfBounds;
    const ph_table_end = std.math.add(
        usize,
        ph_off,
        ph_table_bytes,
    ) catch return error.SegmentOutOfBounds;
    if (ph_table_end > elf_data.len) return error.SegmentOutOfBounds;

    var min_vaddr: u64 = std.math.maxInt(u64);
    var loadable_count: usize = 0;

    var i: usize = 0;
    while (i < ph_num) : (i += 1) {
        const off = ph_off + i * ph_size;
        if (readU32Le(elf_data, off) != PT_LOAD) continue;
        const p_vaddr = if (class == ELF_CLASS_32)
            @as(u64, readU32Le(elf_data, off + ELF32_P_VADDR_OFFSET))
        else
            readU64Le(elf_data, off + ELF64_P_VADDR_OFFSET);

        if (p_vaddr < min_vaddr) min_vaddr = p_vaddr;
        loadable_count += 1;
    }

    if (loadable_count == 0 or entry_point < min_vaddr) {
        return error.NoLoadableSegments;
    }

    var max_seg_end: usize = 0;
    i = 0;
    while (i < ph_num) : (i += 1) {
        const off = ph_off + i * ph_size;
        if (readU32Le(elf_data, off) != PT_LOAD) continue;

        const p_offset_u64 = if (class == ELF_CLASS_32)
            @as(u64, readU32Le(elf_data, off + ELF32_P_OFFSET_OFFSET))
        else
            readU64Le(elf_data, off + ELF64_P_OFFSET_OFFSET);

        const p_vaddr = if (class == ELF_CLASS_32)
            @as(u64, readU32Le(elf_data, off + ELF32_P_VADDR_OFFSET))
        else
            readU64Le(elf_data, off + ELF64_P_VADDR_OFFSET);

        const p_filesz_u64 = if (class == ELF_CLASS_32)
            @as(u64, readU32Le(elf_data, off + ELF32_P_FILESZ_OFFSET))
        else
            readU64Le(elf_data, off + ELF64_P_FILESZ_OFFSET);

        const p_memsz_u64 = if (class == ELF_CLASS_32)
            @as(u64, readU32Le(elf_data, off + ELF32_P_MEMSZ_OFFSET))
        else
            readU64Le(elf_data, off + ELF64_P_MEMSZ_OFFSET);

        if (p_filesz_u64 > p_memsz_u64) return error.SegmentOutOfBounds;

        const p_offset = std.math.cast(
            usize,
            p_offset_u64,
        ) orelse return error.SegmentOutOfBounds;
        const p_filesz = std.math.cast(
            usize,
            p_filesz_u64,
        ) orelse return error.SegmentOutOfBounds;
        const p_memsz = std.math.cast(
            usize,
            p_memsz_u64,
        ) orelse return error.SegmentOutOfBounds;
        const seg_dest_off = std.math.cast(
            usize,
            p_vaddr - min_vaddr,
        ) orelse return error.DestinationOutOfBounds;

        const src_end = std.math.add(
            usize,
            p_offset,
            p_filesz,
        ) catch return error.SegmentOutOfBounds;
        if (src_end > elf_data.len) return error.SegmentOutOfBounds;

        const dst_mem_end = std.math.add(
            usize,
            seg_dest_off,
            p_memsz,
        ) catch return error.DestinationOutOfBounds;
        if (dst_mem_end > dest_buf.len) return error.DestinationOutOfBounds;

        if (p_filesz > 0) {
            @memcpy(
                dest_buf[seg_dest_off .. seg_dest_off + p_filesz],
                elf_data[p_offset..src_end],
            );
        }
        if (p_memsz > p_filesz) {
            @memset(dest_buf[seg_dest_off + p_filesz .. dst_mem_end], 0);
        }

        if (dst_mem_end > max_seg_end) max_seg_end = dst_mem_end;
    }

    const entry_off = std.math.cast(
        usize,
        entry_point - min_vaddr,
    ) orelse return error.DestinationOutOfBounds;
    if (entry_off >= max_seg_end) return error.InvalidElfHeader;

    return KernelLoadResult{
        .format = fmt,
        .entry_offset = entry_off,
        .loaded_end_offset = max_seg_end,
        .preferred_base_gpa = min_vaddr,
    };
}

/// Loads a RISC-V flat `Image` ("RSC\x05" or "RSCV") into `dest_buf`.
/// When `text_offset` equals `SHIM_KERNEL_DEST_OFFSET` (2 MiB, standard Linux
/// RISC-V load offset) and `dest_buf` already starts at `+2 MiB`, normalizes
/// the relative offset within `dest_buf` to `0` to avoid double-offsetting.
pub fn loadRiscvFlatImage(
    image_data: []const u8,
    dest_buf: []u8,
) BootLoaderError!KernelLoadResult {
    if (image_data.len < RISCV_IMAGE_HEADER_SIZE) {
        return error.InvalidRiscvImageHeader;
    }

    const magic1 = readU32Le(image_data, RISCV_IMAGE_MAGIC_POS);
    const magic2 = readU32Le(image_data, RISCV_IMAGE_MAGIC2_POS);
    if (magic2 != RISCV_IMAGE_MAGIC2 and magic1 != RISCV_IMAGE_MAGIC_LEGACY) {
        return error.InvalidRiscvImageHeader;
    }

    const text_offset_u64 = readU64Le(image_data, RISCV_IMAGE_TEXT_OFFSET_POS);
    const image_size_u64 = readU64Le(image_data, RISCV_IMAGE_SIZE_POS);

    const raw_text_offset = std.math.cast(
        usize,
        text_offset_u64,
    ) orelse return error.DestinationOutOfBounds;
    const text_offset = if (raw_text_offset >= SHIM_KERNEL_DEST_OFFSET)
        raw_text_offset - SHIM_KERNEL_DEST_OFFSET
    else
        raw_text_offset;

    const effective_mem_size = if (image_size_u64 > 0)
        (std.math.cast(
            usize,
            image_size_u64,
        ) orelse return error.DestinationOutOfBounds)
    else
        image_data.len;

    const copy_len = @min(image_data.len, effective_mem_size);
    const total_end = std.math.add(
        usize,
        text_offset,
        @max(copy_len, effective_mem_size),
    ) catch return error.DestinationOutOfBounds;
    if (total_end > dest_buf.len) return error.DestinationOutOfBounds;

    if (text_offset > 0) {
        @memset(dest_buf[0..text_offset], 0);
    }
    @memcpy(
        dest_buf[text_offset .. text_offset + copy_len],
        image_data[0..copy_len],
    );
    if (effective_mem_size > copy_len) {
        @memset(dest_buf[text_offset + copy_len .. total_end], 0);
    }

    return KernelLoadResult{
        .format = .riscv_image,
        .entry_offset = text_offset,
        .loaded_end_offset = total_end,
        .preferred_base_gpa = RISCV_DRAM_BASE +| text_offset_u64,
    };
}

/// Automatically detects and loads an ELF64, ELF32, RISC-V flat Image, or
/// PE32+ EFI kernel.
pub fn loadKernelAuto(
    kernel_data: []const u8,
    dest_buf: []u8,
) BootLoaderError!KernelLoadResult {
    return switch (detectKernelFormat(kernel_data)) {
        .elf64, .elf32 => loadElfKernel(kernel_data, dest_buf),
        .riscv_image => loadRiscvFlatImage(kernel_data, dest_buf),
        .pe32_plus_efi => loadPe32PlusEfi(kernel_data, dest_buf),
        .unknown => error.UnknownKernelFormat,
    };
}

test {
    _ = pe_efi;
    _ = storage;
    _ = @import("tests/loader.zig");
    std.testing.refAllDecls(@This());
}
