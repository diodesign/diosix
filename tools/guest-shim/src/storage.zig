// Diosix S-Mode Guest Bootloader Shim — Storage, Partition & Filesystem Parser.
//
// Provides freestanding, allocation-free, bounds-checked parsers for GPT, MBR,
// ISO9660 (Primary Volume Descriptor + El Torito Boot Record + Directory
// traversal), FAT32, ext2/ext4, and BSD UFS2 superblock detection.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const boot_loader = @import("loader.zig");
const BootLoaderError = boot_loader.BootLoaderError;

pub const SECTOR_SIZE: usize = 512;
pub const ISO_SECTOR_SIZE: usize = 2048;

// MBR constants and partition entry field offsets.
pub const MBR_PARTITION_TABLE_OFFSET: usize = 446;
pub const MBR_PARTITION_ENTRY_SIZE: usize = 16;
pub const MBR_MAX_PARTITIONS: usize = 4;
pub const MBR_SIGNATURE_OFFSET: usize = 510;
pub const MBR_SIGNATURE: u16 = 0xaa55;
pub const MBR_BOOTABLE_FLAG: u8 = 0x80;
pub const MBR_ENTRY_OS_TYPE_OFFSET: usize = 4;
pub const MBR_ENTRY_FIRST_LBA_OFFSET: usize = 8;
pub const MBR_ENTRY_SECTORS_OFFSET: usize = 12;
pub const MBR_TYPE_EMPTY: u8 = 0x00;
pub const MBR_TYPE_FAT32_LBA: u8 = 0x0c;
pub const MBR_TYPE_EFI_SYSTEM: u8 = 0xef;
pub const MBR_TYPE_GPT_PROTECTIVE: u8 = 0xee;

// GPT constants and header/entry field offsets.
pub const GPT_HEADER_LBA: usize = 1;
pub const GPT_HEADER_OFFSET: usize = GPT_HEADER_LBA * SECTOR_SIZE;
pub const GPT_HEADER_MIN_SIZE: usize = 92;
pub const GPT_SIGNATURE = "EFI PART";
pub const GPT_PART_ENTRY_LBA_OFFSET: usize = 72;
pub const GPT_NUM_PART_ENTRIES_OFFSET: usize = 80;
pub const GPT_SIZE_OF_PART_ENTRY_OFFSET: usize = 84;
pub const GPT_MIN_ENTRY_SIZE: u32 = 128;
pub const GPT_MAX_PARTITIONS: usize = 16;
pub const GPT_ENTRY_GUID_LEN: usize = 16;
pub const GPT_ENTRY_UNIQUE_GUID_OFFSET: usize = 16;
pub const GPT_ENTRY_FIRST_LBA_OFFSET: usize = 32;
pub const GPT_ENTRY_LAST_LBA_OFFSET: usize = 40;
pub const GPT_ENTRY_ATTRS_OFFSET: usize = 48;

// ISO9660 / El Torito constants and directory record offsets.
pub const ISO_PVD_SECTOR: usize = 16;
pub const ISO_MAX_VD_SCAN_SECTORS: usize = 16;
pub const ISO_PVD_OFFSET: usize = ISO_PVD_SECTOR * ISO_SECTOR_SIZE;
pub const ISO_STD_ID = "CD001";
pub const ISO_VD_TYPE_BOOT: u8 = 0;
pub const ISO_VD_TYPE_PRIMARY: u8 = 1;
pub const ISO_VD_TYPE_TERMINATOR: u8 = 255;
pub const ISO_ROOT_DIR_RECORD_OFFSET: usize = 156;
pub const ISO_DIR_RECORD_MIN_LEN: usize = 34;
pub const ISO_DIR_EXTENT_LBA_OFFSET: usize = 2;
pub const ISO_DIR_DATA_LEN_OFFSET: usize = 10;
pub const ISO_DIR_FLAGS_OFFSET: usize = 25;
pub const ISO_DIR_NAME_LEN_OFFSET: usize = 32;
pub const ISO_DIR_NAME_OFFSET: usize = 33;
pub const ISO_DIR_FLAG_DIRECTORY: u8 = 0x02;
pub const ISO_MAX_PATH_DEPTH: usize = 8;
pub const EL_TORITO_BOOT_CATALOG_OFFSET: usize = 0x47;
pub const EL_TORITO_VALIDATION_HEADER_ID: u8 = 0x01;
pub const EL_TORITO_BOOTABLE_INDICATOR: u8 = 0x88;

// Filesystem superblock offsets and magic numbers.
pub const FAT32_BS_FILSYSTYPE_OFFSET: usize = 82;
pub const FAT32_FILSYSTYPE = "FAT32   ";
pub const EXT4_SUPERBLOCK_OFFSET: usize = 1024;
pub const EXT4_MAGIC_OFFSET: usize = EXT4_SUPERBLOCK_OFFSET + 56;
pub const EXT4_SUPER_MAGIC: u16 = 0xef53;
pub const UFS2_SUPERBLOCK_OFFSET: usize = 65536;
pub const UFS2_MAGIC_OFFSET: usize = UFS2_SUPERBLOCK_OFFSET + 1372;
pub const UFS2_MAGIC: u32 = 0x19540119;

pub const StorageFormat = enum {
    iso9660,
    gpt,
    mbr,
    fat32,
    ext4,
    ufs2,
    unknown,
};

pub const MbrPartition = struct {
    bootable: bool,
    os_type: u8,
    first_lba: u32,
    sector_count: u32,
};

pub const GptPartition = struct {
    type_guid: [16]u8,
    unique_guid: [16]u8,
    first_lba: u64,
    last_lba: u64,
    attributes: u64,
};

pub const IsoVolumeInfo = struct {
    root_extent_lba: u32,
    root_data_length: u32,
    boot_catalog_lba: ?u32,
};

pub const IsoFileExtent = struct {
    extent_lba: u32,
    data_length: u32,
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

pub fn detectStorageFormat(disk_data: []const u8) StorageFormat {
    if (disk_data.len >= ISO_PVD_OFFSET + 7) {
        const vd_type = disk_data[ISO_PVD_OFFSET];
        const std_id =
            disk_data[ISO_PVD_OFFSET + 1 ..][0..ISO_STD_ID.len];
        const is_iso_vd =
            (vd_type == ISO_VD_TYPE_PRIMARY or vd_type == ISO_VD_TYPE_BOOT);
        if (is_iso_vd and std.mem.eql(u8, std_id, ISO_STD_ID)) {
            return .iso9660;
        }
    }

    if (disk_data.len >= GPT_HEADER_OFFSET + GPT_HEADER_MIN_SIZE) {
        const sig = disk_data[GPT_HEADER_OFFSET..][0..GPT_SIGNATURE.len];
        if (std.mem.eql(u8, sig, GPT_SIGNATURE)) {
            return .gpt;
        }
    }

    if (disk_data.len >= EXT4_MAGIC_OFFSET + 2) {
        if (readU16Le(disk_data, EXT4_MAGIC_OFFSET) == EXT4_SUPER_MAGIC) {
            return .ext4;
        }
    }

    if (disk_data.len >= UFS2_MAGIC_OFFSET + 4) {
        if (readU32Le(disk_data, UFS2_MAGIC_OFFSET) == UFS2_MAGIC) {
            return .ufs2;
        }
    }

    if (disk_data.len >= SECTOR_SIZE) {
        if (readU16Le(disk_data, MBR_SIGNATURE_OFFSET) == MBR_SIGNATURE) {
            const fs_off = FAT32_BS_FILSYSTYPE_OFFSET;
            const fs_tag = disk_data[fs_off..][0..FAT32_FILSYSTYPE.len];
            if (std.mem.eql(u8, fs_tag, FAT32_FILSYSTYPE)) {
                return .fat32;
            }
            return .mbr;
        }
    }

    return .unknown;
}

/// Parses up to 4 primary MBR partitions from sector 0.
pub fn parseMbrPartitions(
    disk_data: []const u8,
    out_partitions: []MbrPartition,
) BootLoaderError!usize {
    if (disk_data.len < SECTOR_SIZE) return error.BufferTooSmall;
    if (readU16Le(disk_data, MBR_SIGNATURE_OFFSET) != MBR_SIGNATURE) {
        return error.InvalidMbrSignature;
    }

    var count: usize = 0;
    var idx: usize = 0;
    while (idx < MBR_MAX_PARTITIONS and
        count < out_partitions.len) : (idx += 1)
    {
        const off = MBR_PARTITION_TABLE_OFFSET + idx * MBR_PARTITION_ENTRY_SIZE;
        const boot_ind = disk_data[off];
        const os_type = disk_data[off + MBR_ENTRY_OS_TYPE_OFFSET];
        const first_lba =
            readU32Le(disk_data, off + MBR_ENTRY_FIRST_LBA_OFFSET);
        const sectors = readU32Le(disk_data, off + MBR_ENTRY_SECTORS_OFFSET);

        if (os_type == MBR_TYPE_EMPTY or sectors == 0) continue;
        out_partitions[count] = .{
            .bootable = (boot_ind == MBR_BOOTABLE_FLAG),
            .os_type = os_type,
            .first_lba = first_lba,
            .sector_count = sectors,
        };
        count += 1;
    }
    return count;
}

/// Parses active non-empty GPT partitions from LBA 1 and the partition array.
pub fn parseGptPartitions(
    disk_data: []const u8,
    out_partitions: []GptPartition,
) BootLoaderError!usize {
    if (disk_data.len < GPT_HEADER_OFFSET + GPT_HEADER_MIN_SIZE) {
        return error.BufferTooSmall;
    }
    const hdr = disk_data[GPT_HEADER_OFFSET..];
    if (!std.mem.eql(u8, hdr[0..GPT_SIGNATURE.len], GPT_SIGNATURE)) {
        return error.InvalidGptHeader;
    }

    const part_entry_lba = readU64Le(hdr, GPT_PART_ENTRY_LBA_OFFSET);
    const num_entries = readU32Le(hdr, GPT_NUM_PART_ENTRIES_OFFSET);
    const entry_size = readU32Le(hdr, GPT_SIZE_OF_PART_ENTRY_OFFSET);

    if (entry_size < GPT_MIN_ENTRY_SIZE or (entry_size % 8) != 0) {
        return error.InvalidGptHeader;
    }
    const table_offset_u64 = std.math.mul(
        u64,
        part_entry_lba,
        SECTOR_SIZE,
    ) catch return error.InvalidGptHeader;
    const table_offset = std.math.cast(
        usize,
        table_offset_u64,
    ) orelse return error.InvalidGptHeader;

    var count: usize = 0;
    const max_scan = @min(@as(usize, num_entries), GPT_MAX_PARTITIONS * 8);
    var idx: usize = 0;
    while (idx < max_scan and count < out_partitions.len) : (idx += 1) {
        const step = std.math.mul(
            usize,
            idx,
            @as(usize, entry_size),
        ) catch break;
        const entry_off = std.math.add(usize, table_offset, step) catch break;
        const entry_end = std.math.add(
            usize,
            entry_off,
            GPT_MIN_ENTRY_SIZE,
        ) catch break;
        if (entry_end > disk_data.len) break;

        const entry = disk_data[entry_off..entry_end];
        var is_empty = true;
        for (entry[0..GPT_ENTRY_GUID_LEN]) |b| {
            if (b != 0) {
                is_empty = false;
                break;
            }
        }
        if (is_empty) continue;

        const first_lba = readU64Le(entry, GPT_ENTRY_FIRST_LBA_OFFSET);
        const last_lba = readU64Le(entry, GPT_ENTRY_LAST_LBA_OFFSET);
        const attrs = readU64Le(entry, GPT_ENTRY_ATTRS_OFFSET);
        if (first_lba == 0 or last_lba < first_lba) continue;

        var p: GptPartition = .{
            .type_guid = undefined,
            .unique_guid = undefined,
            .first_lba = first_lba,
            .last_lba = last_lba,
            .attributes = attrs,
        };
        @memcpy(&p.type_guid, entry[0..GPT_ENTRY_GUID_LEN]);
        @memcpy(
            &p.unique_guid,
            entry[GPT_ENTRY_UNIQUE_GUID_OFFSET..][0..GPT_ENTRY_GUID_LEN],
        );
        out_partitions[count] = p;
        count += 1;
    }

    return count;
}

/// Parses the ISO9660 Volume Descriptor sequence starting at sector 16.
pub fn parseIso9660Volume(iso_data: []const u8) BootLoaderError!IsoVolumeInfo {
    if (iso_data.len < (ISO_PVD_SECTOR + 1) * ISO_SECTOR_SIZE) {
        return error.BufferTooSmall;
    }

    var found_pvd = false;
    var info = IsoVolumeInfo{
        .root_extent_lba = 0,
        .root_data_length = 0,
        .boot_catalog_lba = null,
    };

    var sector: usize = ISO_PVD_SECTOR;
    while (sector < ISO_PVD_SECTOR + ISO_MAX_VD_SCAN_SECTORS) : (sector += 1) {
        const off = sector * ISO_SECTOR_SIZE;
        if (off + ISO_SECTOR_SIZE > iso_data.len) break;
        const vd = iso_data[off .. off + ISO_SECTOR_SIZE];
        const vd_type = vd[0];
        if (!std.mem.eql(u8, vd[1..][0..ISO_STD_ID.len], ISO_STD_ID)) {
            if (sector == ISO_PVD_SECTOR) return error.InvalidIsoVolume;
            break;
        }

        if (vd_type == ISO_VD_TYPE_PRIMARY) {
            const rec_off = ISO_ROOT_DIR_RECORD_OFFSET;
            const root_rec = vd[rec_off .. rec_off + ISO_DIR_RECORD_MIN_LEN];
            info.root_extent_lba =
                readU32Le(root_rec, ISO_DIR_EXTENT_LBA_OFFSET);
            info.root_data_length =
                readU32Le(root_rec, ISO_DIR_DATA_LEN_OFFSET);
            found_pvd = true;
        } else if (vd_type == ISO_VD_TYPE_BOOT) {
            info.boot_catalog_lba =
                readU32Le(vd, EL_TORITO_BOOT_CATALOG_OFFSET);
        } else if (vd_type == ISO_VD_TYPE_TERMINATOR) {
            break;
        }
    }

    if (!found_pvd or info.root_extent_lba == 0) return error.InvalidIsoVolume;
    return info;
}

fn matchIsoIdentifier(raw_ident: []const u8, target_name: []const u8) bool {
    // Strip ISO9660 ";1" version suffix and trailing '.' if present.
    var clean_len = raw_ident.len;
    if (std.mem.indexOfScalar(u8, raw_ident, ';')) |semi| {
        clean_len = semi;
    }
    while (clean_len > 0 and raw_ident[clean_len - 1] == '.') {
        clean_len -= 1;
    }
    return std.ascii.eqlIgnoreCase(raw_ident[0..clean_len], target_name);
}

fn findIso9660EntryInDir(
    iso_data: []const u8,
    dir_lba: u32,
    dir_len: u32,
    entry_name: []const u8,
    expect_dir: bool,
) BootLoaderError!IsoFileExtent {
    const start_off = std.math.mul(
        usize,
        dir_lba,
        ISO_SECTOR_SIZE,
    ) catch return error.FileNotFound;
    const end_off = std.math.add(
        usize,
        start_off,
        dir_len,
    ) catch return error.FileNotFound;
    if (end_off > iso_data.len) return error.BufferTooSmall;

    var pos = start_off;
    while (pos < end_off) {
        const rec_len = iso_data[pos];
        if (rec_len == 0) {
            // Advance to next 2048-byte sector boundary.
            const next_sector = ((pos / ISO_SECTOR_SIZE) + 1) * ISO_SECTOR_SIZE;
            if (next_sector <= pos or next_sector >= end_off) break;
            pos = next_sector;
            continue;
        }
        if (rec_len < ISO_DIR_RECORD_MIN_LEN or rec_len > end_off - pos) break;

        const rec = iso_data[pos .. pos + rec_len];
        const extent_lba = readU32Le(rec, ISO_DIR_EXTENT_LBA_OFFSET);
        const data_len = readU32Le(rec, ISO_DIR_DATA_LEN_OFFSET);
        const flags = rec[ISO_DIR_FLAGS_OFFSET];
        const name_len = rec[ISO_DIR_NAME_LEN_OFFSET];

        if (ISO_DIR_NAME_OFFSET + @as(usize, name_len) <= rec_len and
            name_len > 0)
        {
            const ident = rec[ISO_DIR_NAME_OFFSET..][0..name_len];
            // Skip '.' (0x00) and '..' (0x01) directory entries.
            if (!(name_len == 1 and (ident[0] == 0 or ident[0] == 1))) {
                const is_dir = (flags & ISO_DIR_FLAG_DIRECTORY) != 0;
                if (is_dir == expect_dir and
                    matchIsoIdentifier(ident, entry_name))
                {
                    return IsoFileExtent{
                        .extent_lba = extent_lba,
                        .data_length = data_len,
                    };
                }
            }
        }
        pos += rec_len;
    }

    return error.FileNotFound;
}

/// Finds a file inside an ISO9660 directory extent by case-insensitive name.
pub fn findIso9660FileInDir(
    iso_data: []const u8,
    dir_lba: u32,
    dir_len: u32,
    filename: []const u8,
) BootLoaderError!IsoFileExtent {
    return findIso9660EntryInDir(iso_data, dir_lba, dir_len, filename, false);
}

/// Resolves a potentially nested file path (e.g., `"EFI/BOOT/BOOTRISCV64.EFI"`
/// or `"boot/kernel/kernel"`) starting from the ISO9660 root directory.
pub fn findIso9660Path(
    iso_data: []const u8,
    vol: IsoVolumeInfo,
    path: []const u8,
) BootLoaderError!IsoFileExtent {
    var trimmed = path;
    while (trimmed.len > 0 and trimmed[0] == '/') {
        trimmed = trimmed[1..];
    }
    if (trimmed.len == 0) return error.FileNotFound;

    var cur_lba = vol.root_extent_lba;
    var cur_len = vol.root_data_length;
    var rem = trimmed;
    var depth: usize = 0;

    while (depth < ISO_MAX_PATH_DEPTH) : (depth += 1) {
        if (std.mem.indexOfScalar(u8, rem, '/')) |slash| {
            const comp = rem[0..slash];
            rem = rem[slash + 1 ..];
            while (rem.len > 0 and rem[0] == '/') {
                rem = rem[1..];
            }
            if (comp.len == 0 or rem.len == 0) return error.FileNotFound;
            const sub_dir = try findIso9660EntryInDir(
                iso_data,
                cur_lba,
                cur_len,
                comp,
                true,
            );
            cur_lba = sub_dir.extent_lba;
            cur_len = sub_dir.data_length;
        } else {
            return findIso9660EntryInDir(
                iso_data,
                cur_lba,
                cur_len,
                rem,
                false,
            );
        }
    }

    return error.FileNotFound;
}

test {
    std.testing.refAllDecls(@This());
}
