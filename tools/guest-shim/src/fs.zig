// Freestanding FAT32, ext2/ext4, GPT, and MBR Boot Kernel Locator for
// `guest-shim`.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const loader = @import("loader.zig");
const storage = @import("storage.zig");

const FAT32_BYTES_PER_SEC_OFF: usize = 11;
const FAT32_SEC_PER_CLUS_OFF: usize = 13;
const FAT32_RSVD_SEC_CNT_OFF: usize = 14;
const FAT32_NUM_FATS_OFF: usize = 16;
const FAT32_FATSZ32_OFF: usize = 36;
const FAT32_ROOT_CLUS_OFF: usize = 44;
const FAT32_DIR_ENTRY_SIZE: usize = 32;
const FAT32_ATTR_OFF: usize = 11;
const FAT32_ATTR_LFN: u8 = 0x0f;
const FAT32_ATTR_DIR: u8 = 0x10;
const FAT32_ATTR_VOL_ID: u8 = 0x08;
const FAT32_CLUS_HI_OFF: usize = 20;
const FAT32_CLUS_LO_OFF: usize = 26;
const FAT32_FILE_SIZE_OFF: usize = 28;
const FAT32_CLUSTER_MASK: u32 = 0x0fff_ffff;
const MAX_DIR_ENTRIES_SCAN: usize = 256;
const SCAN_BLOCK_STEP: usize = 512;
const MAX_SCAN_BLOCKS: usize = 65536;

fn readU16Le(buf: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, buf[off..][0..2], .little);
}

fn readU32Le(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off..][0..4], .little);
}

fn fatClusterOffset(
    vol: []const u8,
    data_start_sec: usize,
    sec_per_clus: usize,
    bytes_per_sec: usize,
    cluster: u32,
) ?usize {
    const clus = cluster & FAT32_CLUSTER_MASK;
    if (clus < 2) return null;
    const rel_sec = std.math.mul(
        usize,
        @as(usize, clus - 2),
        sec_per_clus,
    ) catch return null;
    const abs_sec = std.math.add(usize, data_start_sec, rel_sec) catch
        return null;
    const byte_off = std.math.mul(usize, abs_sec, bytes_per_sec) catch
        return null;
    if (byte_off >= vol.len) return null;
    return byte_off;
}

fn scanFat32Directory(
    vol: []const u8,
    data_start_sec: usize,
    sec_per_clus: usize,
    bytes_per_sec: usize,
    dir_cluster: u32,
    depth: usize,
) ?[]const u8 {
    if (depth > 3) return null;
    const dir_off = fatClusterOffset(
        vol,
        data_start_sec,
        sec_per_clus,
        bytes_per_sec,
        dir_cluster,
    ) orelse return null;
    const clus_bytes = std.math.mul(usize, sec_per_clus, bytes_per_sec) catch
        return null;
    const scan_limit: usize = @min(
        vol.len - dir_off,
        @max(clus_bytes, MAX_DIR_ENTRIES_SCAN * FAT32_DIR_ENTRY_SIZE),
    );

    var pos: usize = 0;
    while (pos + FAT32_DIR_ENTRY_SIZE <= scan_limit) : ({
        pos += FAT32_DIR_ENTRY_SIZE;
    }) {
        const entry = vol[dir_off + pos ..][0..FAT32_DIR_ENTRY_SIZE];
        if (entry[0] == 0x00) break;
        if (entry[0] == 0xe5) continue;
        const attr = entry[FAT32_ATTR_OFF];
        if (attr == FAT32_ATTR_LFN or (attr & FAT32_ATTR_VOL_ID) != 0) continue;

        const clus_hi: u32 = readU16Le(entry, FAT32_CLUS_HI_OFF);
        const clus_lo: u32 = readU16Le(entry, FAT32_CLUS_LO_OFF);
        const first_clus = ((clus_hi << 16) | clus_lo) & FAT32_CLUSTER_MASK;
        if (first_clus < 2) continue;

        if ((attr & FAT32_ATTR_DIR) != 0) {
            if (entry[0] == '.') continue;
            if (scanFat32Directory(
                vol,
                data_start_sec,
                sec_per_clus,
                bytes_per_sec,
                first_clus,
                depth + 1,
            )) |found| {
                return found;
            }
            continue;
        }

        const file_size: usize = readU32Le(entry, FAT32_FILE_SIZE_OFF);
        if (file_size < loader.RISCV_IMAGE_HEADER_SIZE) continue;
        const file_off = fatClusterOffset(
            vol,
            data_start_sec,
            sec_per_clus,
            bytes_per_sec,
            first_clus,
        ) orelse continue;
        const file_end = std.math.add(usize, file_off, file_size) catch
            continue;
        if (file_end > vol.len) continue;
        const slice = vol[file_off..file_end];
        if (loader.detectKernelFormat(slice) != .unknown) {
            return slice;
        }
    }
    return null;
}

pub fn findKernelInFat32Volume(vol: []const u8) ?[]const u8 {
    if (vol.len < storage.SECTOR_SIZE) return null;
    const bytes_per_sec: usize = readU16Le(vol, FAT32_BYTES_PER_SEC_OFF);
    const sec_per_clus: usize = vol[FAT32_SEC_PER_CLUS_OFF];
    const rsvd_sec_cnt: usize = readU16Le(vol, FAT32_RSVD_SEC_CNT_OFF);
    const num_fats: usize = vol[FAT32_NUM_FATS_OFF];
    const fatsz32: usize = readU32Le(vol, FAT32_FATSZ32_OFF);
    const root_clus: u32 = readU32Le(vol, FAT32_ROOT_CLUS_OFF);

    if (bytes_per_sec == 0 or (bytes_per_sec % 512) != 0 or sec_per_clus == 0) {
        return null;
    }
    const fat_secs = std.math.mul(usize, num_fats, fatsz32) catch return null;
    const data_start_sec = std.math.add(usize, rsvd_sec_cnt, fat_secs) catch
        return null;
    return scanFat32Directory(
        vol,
        data_start_sec,
        sec_per_clus,
        bytes_per_sec,
        root_clus,
        0,
    );
}

pub fn findKernelInExtVolume(vol: []const u8) ?[]const u8 {
    var off: usize = 2048;
    var steps: usize = 0;
    while (off + loader.RISCV_IMAGE_HEADER_SIZE <= vol.len and
        steps < MAX_SCAN_BLOCKS) : ({
        off += SCAN_BLOCK_STEP;
        steps += 1;
    }) {
        const rem = vol[off..];
        const fmt = loader.detectKernelFormat(rem);
        if (fmt == .riscv_image) {
            const img_sz: usize = @intCast(
                std.mem.readInt(
                    u64,
                    rem[loader.RISCV_IMAGE_SIZE_POS..][0..8],
                    .little,
                ),
            );
            const len: usize = if (img_sz > 0 and img_sz <= rem.len)
                img_sz
            else
                rem.len;
            return rem[0..len];
        } else if (fmt == .elf64 or fmt == .elf32 or fmt == .pe32_plus_efi) {
            return rem;
        }
    }
    return null;
}

fn findKernelInVolumeSlice(vol: []const u8) ?[]const u8 {
    return switch (storage.detectStorageFormat(vol)) {
        .fat32 => findKernelInFat32Volume(vol) orelse
            findKernelInExtVolume(vol),
        .ext4, .ufs2 => findKernelInExtVolume(vol),
        else => null,
    };
}

/// Locates a bootable kernel slice inside a raw or GPT/MBR-partitioned disk.
pub fn findBootKernelInDisk(disk: []const u8) ?[]const u8 {
    switch (storage.detectStorageFormat(disk)) {
        .fat32, .ext4, .ufs2 => return findKernelInVolumeSlice(disk),
        .gpt => {
            var parts: [storage.GPT_MAX_PARTITIONS]storage.GptPartition =
                undefined;
            const n = storage.parseGptPartitions(disk, &parts) catch 0;
            for (parts[0..n]) |p| {
                const start = std.math.mul(
                    usize,
                    @intCast(p.first_lba),
                    storage.SECTOR_SIZE,
                ) catch continue;
                const end_lba = p.last_lba +| 1;
                const end = std.math.mul(
                    usize,
                    @intCast(end_lba),
                    storage.SECTOR_SIZE,
                ) catch continue;
                if (start < disk.len) {
                    const clamped_end: usize = @min(end, disk.len);
                    if (clamped_end > start) {
                        const part_slice = disk[start..clamped_end];
                        if (findKernelInVolumeSlice(part_slice)) |k| return k;
                    }
                }
            }
            return findKernelInExtVolume(disk);
        },
        .mbr => {
            var parts: [storage.MBR_MAX_PARTITIONS]storage.MbrPartition =
                undefined;
            const n = storage.parseMbrPartitions(disk, &parts) catch
                return findKernelInExtVolume(disk);
            for (parts[0..n]) |p| {
                if (p.os_type == storage.MBR_TYPE_EMPTY or
                    p.sector_count == 0) continue;
                const start = std.math.mul(
                    usize,
                    p.first_lba,
                    storage.SECTOR_SIZE,
                ) catch continue;
                const len = std.math.mul(
                    usize,
                    p.sector_count,
                    storage.SECTOR_SIZE,
                ) catch continue;
                if (start < disk.len) {
                    const clamped_end: usize = @min(start +| len, disk.len);
                    if (clamped_end > start) {
                        const part_slice = disk[start..clamped_end];
                        if (findKernelInVolumeSlice(part_slice)) |k| return k;
                    }
                }
            }
            return findKernelInExtVolume(disk);
        },
        else => return null,
    }
}

test "findBootKernelInDisk locates RISC-V flat Image on FAT32 volume" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;

    var disk: [16 * 512]u8 = @splat(0);
    // Construct a minimal FAT32 boot sector (1 sec/clus, 1 rsvd, 1 FAT).
    std.mem.writeInt(u16, disk[11..13], 512, .little);
    disk[13] = 1; // SecPerClus = 1
    std.mem.writeInt(u16, disk[14..16], 1, .little); // RsvdSecCnt = 1
    disk[16] = 1; // NumFATs = 1
    std.mem.writeInt(u32, disk[36..40], 1, .little); // FATSz32 = 1
    std.mem.writeInt(u32, disk[44..48], 2, .little); // RootClus = 2
    @memcpy(
        disk[storage.FAT32_BS_FILSYSTYPE_OFFSET..][0..8],
        storage.FAT32_FILSYSTYPE,
    );
    std.mem.writeInt(u16, disk[510..512], storage.MBR_SIGNATURE, .little);

    // Data starts at sector 2 (cluster 2 = root dir at offset 1024).
    // Place a directory entry at offset 1024 pointing to cluster 3 (off 1536).
    @memcpy(disk[1024..1035], "IMAGE      ");
    disk[1024 + FAT32_ATTR_OFF] = 0x20;
    std.mem.writeInt(u16, disk[1024 + FAT32_CLUS_LO_OFF ..][0..2], 3, .little);
    std.mem.writeInt(
        u32,
        disk[1024 + FAT32_FILE_SIZE_OFF ..][0..4],
        128,
        .little,
    );

    // Place a valid RISC-V flat Image header at cluster 3 (offset 1536).
    std.mem.writeInt(u64, disk[1536 + 8 ..][0..8], 0, .little);
    std.mem.writeInt(u64, disk[1536 + 16 ..][0..8], 128, .little);
    @memcpy(disk[1536 + 56 ..][0..4], "RSC\x05");

    const found = findBootKernelInDisk(&disk);
    try testing.expect(found != null);
    try testing.expectEqual(@as(usize, 128), found.?.len);
    try testing.expectEqual(
        loader.KernelFormat.riscv_image,
        loader.detectKernelFormat(found.?),
    );
}
