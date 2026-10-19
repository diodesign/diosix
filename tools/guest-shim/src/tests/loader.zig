// Diosix S-Mode Guest Bootloader Shim — Format & Storage Unit Tests.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const testing = std.testing;
const boot_loader = @import("../loader.zig");
const storage = boot_loader.storage;
const pe_efi = boot_loader.pe_efi;

const ELF_MAGIC = boot_loader.ELF_MAGIC;
const ELF_CLASS_64 = boot_loader.ELF_CLASS_64;
const ELF_DATA_LSB = boot_loader.ELF_DATA_LSB;
const PT_LOAD = boot_loader.PT_LOAD;
const RISCV_IMAGE_TEXT_OFFSET_POS = boot_loader.RISCV_IMAGE_TEXT_OFFSET_POS;
const RISCV_IMAGE_SIZE_POS = boot_loader.RISCV_IMAGE_SIZE_POS;
const RISCV_IMAGE_MAGIC2_POS = boot_loader.RISCV_IMAGE_MAGIC2_POS;
const RISCV_IMAGE_MAGIC2 = boot_loader.RISCV_IMAGE_MAGIC2;
const SHIM_KERNEL_DEST_OFFSET = boot_loader.SHIM_KERNEL_DEST_OFFSET;
const MZ_SIGNATURE = pe_efi.MZ_SIGNATURE;
const PE_LFA_NEW_OFFSET = pe_efi.PE_LFA_NEW_OFFSET;
const PE_SIGNATURE = pe_efi.PE_SIGNATURE;
const IMAGE_FILE_MACHINE_RISCV64 = pe_efi.IMAGE_FILE_MACHINE_RISCV64;
const PE32_PLUS_MAGIC = pe_efi.PE32_PLUS_MAGIC;
const EFI_SYSTEM_TABLE_SIGNATURE = pe_efi.EFI_SYSTEM_TABLE_SIGNATURE;
const EFI_BOOT_SERVICES_SIGNATURE = pe_efi.EFI_BOOT_SERVICES_SIGNATURE;
const MBR_SIGNATURE_OFFSET = storage.MBR_SIGNATURE_OFFSET;
const MBR_SIGNATURE = storage.MBR_SIGNATURE;
const MBR_PARTITION_TABLE_OFFSET = storage.MBR_PARTITION_TABLE_OFFSET;
const MBR_TYPE_EFI_SYSTEM = storage.MBR_TYPE_EFI_SYSTEM;
const GPT_HEADER_OFFSET = storage.GPT_HEADER_OFFSET;
const GPT_SIGNATURE = storage.GPT_SIGNATURE;
const ISO_SECTOR_SIZE = storage.ISO_SECTOR_SIZE;
const ISO_VD_TYPE_PRIMARY = storage.ISO_VD_TYPE_PRIMARY;
const ISO_VD_TYPE_BOOT = storage.ISO_VD_TYPE_BOOT;
const ISO_STD_ID = storage.ISO_STD_ID;
const ISO_ROOT_DIR_RECORD_OFFSET = storage.ISO_ROOT_DIR_RECORD_OFFSET;
const ISO_DIR_FLAG_DIRECTORY = storage.ISO_DIR_FLAG_DIRECTORY;
const EL_TORITO_BOOT_CATALOG_OFFSET = storage.EL_TORITO_BOOT_CATALOG_OFFSET;

const KernelFormat = boot_loader.KernelFormat;
const StorageFormat = boot_loader.StorageFormat;
const EfiSystemTable64 = boot_loader.EfiSystemTable64;
const EfiBootServices64 = boot_loader.EfiBootServices64;
const MbrPartition = boot_loader.MbrPartition;
const GptPartition = boot_loader.GptPartition;

const detectKernelFormat = boot_loader.detectKernelFormat;
const loadElfKernel = boot_loader.loadElfKernel;
const loadRiscvFlatImage = boot_loader.loadRiscvFlatImage;
const loadKernelAuto = boot_loader.loadKernelAuto;
const initMinimalEfiTables = boot_loader.initMinimalEfiTables;
const detectStorageFormat = boot_loader.detectStorageFormat;
const parseMbrPartitions = boot_loader.parseMbrPartitions;
const parseGptPartitions = boot_loader.parseGptPartitions;
const parseIso9660Volume = boot_loader.parseIso9660Volume;
const findIso9660FileInDir = boot_loader.findIso9660FileInDir;
const findIso9660Path = boot_loader.findIso9660Path;

test "detectKernelFormat and loadElfKernel for 64-bit ELF with BSS zeroing" {
    var elf_buf: [256]u8 = @splat(0);
    // ELF64 header.
    @memcpy(elf_buf[0..4], ELF_MAGIC);
    elf_buf[4] = ELF_CLASS_64;
    elf_buf[5] = ELF_DATA_LSB;
    elf_buf[6] = 1; // EV_CURRENT.
    std.mem.writeInt(u64, elf_buf[24..32], 0x80000004, .little); // e_entry.
    std.mem.writeInt(u64, elf_buf[32..40], 64, .little); // e_phoff.
    std.mem.writeInt(u16, elf_buf[54..56], 56, .little); // e_phentsize.
    std.mem.writeInt(u16, elf_buf[56..58], 1, .little); // e_phnum.

    // Program header 0 at offset 64.
    std.mem.writeInt(u32, elf_buf[64..68], PT_LOAD, .little); // p_type.
    std.mem.writeInt(u32, elf_buf[68..72], 5, .little); // p_flags (R+X).
    std.mem.writeInt(u64, elf_buf[72..80], 128, .little); // p_offset.
    std.mem.writeInt(u64, elf_buf[80..88], 0x80000000, .little); // p_vaddr.
    std.mem.writeInt(u64, elf_buf[88..96], 0x80000000, .little); // p_paddr.
    std.mem.writeInt(u64, elf_buf[96..104], 16, .little); // p_filesz.
    std.mem.writeInt(u64, elf_buf[104..112], 32, .little); // p_memsz.

    // Payload at offset 128.
    @memcpy(elf_buf[128..144], "DIOSIX_ELF64_BIN");

    try testing.expectEqual(KernelFormat.elf64, detectKernelFormat(&elf_buf));

    var dest: [64]u8 = @splat(0xaa);
    const res = try loadElfKernel(&elf_buf, &dest);
    try testing.expectEqual(KernelFormat.elf64, res.format);
    try testing.expectEqual(@as(usize, 4), res.entry_offset);
    try testing.expectEqual(@as(usize, 32), res.loaded_end_offset);
    try testing.expectEqual(@as(u64, 0x80000000), res.preferred_base_gpa);
    try testing.expectEqualStrings("DIOSIX_ELF64_BIN", dest[0..16]);
    // Verify BSS region [16..32] was zeroed.
    for (dest[16..32]) |b| {
        try testing.expectEqual(@as(u8, 0), b);
    }
}

test "loadElfKernel rejects out-of-bounds segment offsets" {
    var bad_elf: [128]u8 = @splat(0);
    @memcpy(bad_elf[0..4], ELF_MAGIC);
    bad_elf[4] = ELF_CLASS_64;
    bad_elf[5] = ELF_DATA_LSB;
    std.mem.writeInt(u64, bad_elf[24..32], 0x80000000, .little);
    std.mem.writeInt(u64, bad_elf[32..40], 64, .little);
    std.mem.writeInt(u16, bad_elf[54..56], 56, .little);
    std.mem.writeInt(u16, bad_elf[56..58], 1, .little);

    std.mem.writeInt(u32, bad_elf[64..68], PT_LOAD, .little);
    std.mem.writeInt(u64, bad_elf[72..80], 100, .little); // p_offset.
    std.mem.writeInt(u64, bad_elf[80..88], 0x80000000, .little);
    std.mem.writeInt(u64, bad_elf[96..104], 64, .little); // p_filesz > 128B.
    std.mem.writeInt(u64, bad_elf[104..112], 64, .little);

    var dest: [128]u8 = @splat(0);
    try testing.expectError(
        error.SegmentOutOfBounds,
        loadElfKernel(&bad_elf, &dest),
    );
}

test "detectKernelFormat and loadRiscvFlatImage for RSC\\x05 header" {
    var img_buf: [128]u8 = @splat(0);
    const txt_off = RISCV_IMAGE_TEXT_OFFSET_POS;
    const sz_off = RISCV_IMAGE_SIZE_POS;
    const m2_off = RISCV_IMAGE_MAGIC2_POS;

    std.mem.writeInt(u32, img_buf[0..4], 0x0000006f, .little); // j _start.
    std.mem.writeInt(u64, img_buf[txt_off .. txt_off + 8], 32, .little);
    std.mem.writeInt(u64, img_buf[sz_off .. sz_off + 8], 160, .little);
    std.mem.writeInt(
        u32,
        img_buf[m2_off .. m2_off + 4],
        RISCV_IMAGE_MAGIC2,
        .little,
    );
    @memcpy(img_buf[64..80], "RISCV_FLAT_IMAGE");

    try testing.expectEqual(
        KernelFormat.riscv_image,
        detectKernelFormat(&img_buf),
    );

    var dest: [256]u8 = @splat(0xff);
    const res = try loadRiscvFlatImage(&img_buf, &dest);
    try testing.expectEqual(KernelFormat.riscv_image, res.format);
    try testing.expectEqual(@as(usize, 32), res.entry_offset);
    try testing.expectEqual(@as(usize, 192), res.loaded_end_offset);
    try testing.expectEqualStrings(
        "RISCV_FLAT_IMAGE",
        dest[32 + 64 .. 32 + 80],
    );
    for (dest[0..32]) |b| {
        try testing.expectEqual(@as(u8, 0), b);
    }
    for (dest[32 + 128 .. 192]) |b| {
        try testing.expectEqual(@as(u8, 0), b);
    }

    // Also verify standard 2 MiB text_offset (SHIM_KERNEL_DEST_OFFSET) is
    // normalized to 0 when dest_buf already starts at +2 MiB.
    std.mem.writeInt(
        u64,
        img_buf[txt_off .. txt_off + 8],
        SHIM_KERNEL_DEST_OFFSET,
        .little,
    );
    var dest2: [256]u8 = @splat(0xff);
    const res2 = try loadRiscvFlatImage(&img_buf, &dest2);
    try testing.expectEqual(@as(usize, 0), res2.entry_offset);
    try testing.expectEqual(@as(usize, 160), res2.loaded_end_offset);
    try testing.expectEqualStrings("RISCV_FLAT_IMAGE", dest2[64..80]);
}

test "detectKernelFormat and loadPe32PlusEfi for RISC-V 64 EFI binary" {
    var pe_buf: [512]u8 = @splat(0);
    const lfa_off = PE_LFA_NEW_OFFSET;
    std.mem.writeInt(u16, pe_buf[0..2], MZ_SIGNATURE, .little);
    std.mem.writeInt(u32, pe_buf[lfa_off .. lfa_off + 4], 64, .little);

    // PE signature at 64.
    std.mem.writeInt(u32, pe_buf[64..68], PE_SIGNATURE, .little);
    // COFF header at 68..88.
    std.mem.writeInt(u16, pe_buf[68..70], IMAGE_FILE_MACHINE_RISCV64, .little);
    std.mem.writeInt(u16, pe_buf[70..72], 1, .little); // 1 section.
    std.mem.writeInt(u16, pe_buf[84..86], 112, .little); // OptHeader size.

    // Optional Header at 88..200.
    std.mem.writeInt(u16, pe_buf[88..90], PE32_PLUS_MAGIC, .little);
    std.mem.writeInt(u32, pe_buf[88 + 16 .. 88 + 20], 256, .little); // Entry.
    std.mem.writeInt(u64, pe_buf[88 + 24 .. 88 + 32], 0x80200000, .little);
    std.mem.writeInt(u32, pe_buf[88 + 56 .. 88 + 60], 384, .little); // Size.
    std.mem.writeInt(u32, pe_buf[88 + 60 .. 88 + 64], 240, .little); // Hdrs.

    // Section Header 0 at 200..240.
    @memcpy(pe_buf[200..205], ".text");
    std.mem.writeInt(u32, pe_buf[208..212], 16, .little); // VirtualSize.
    std.mem.writeInt(u32, pe_buf[212..216], 256, .little); // VirtualAddress.
    std.mem.writeInt(u32, pe_buf[216..220], 16, .little); // SizeOfRawData.
    std.mem.writeInt(u32, pe_buf[220..224], 300, .little); // PointerToRawData.

    @memcpy(pe_buf[300..316], "FREEBSD_EFI_STUB");

    try testing.expectEqual(
        KernelFormat.pe32_plus_efi,
        detectKernelFormat(&pe_buf),
    );

    var dest: [512]u8 = @splat(0);
    const res = try loadKernelAuto(&pe_buf, &dest);
    try testing.expectEqual(KernelFormat.pe32_plus_efi, res.format);
    try testing.expectEqual(@as(usize, 256), res.entry_offset);
    try testing.expectEqual(@as(usize, 384), res.loaded_end_offset);
    try testing.expectEqualStrings("FREEBSD_EFI_STUB", dest[256..272]);

    var sys_tbl: EfiSystemTable64 = undefined;
    var boot_srv: EfiBootServices64 = undefined;
    initMinimalEfiTables(&sys_tbl, &boot_srv);
    try testing.expectEqual(EFI_SYSTEM_TABLE_SIGNATURE, sys_tbl.hdr.signature);
    try testing.expectEqual(
        EFI_BOOT_SERVICES_SIGNATURE,
        boot_srv.hdr.signature,
    );
    try testing.expectEqual(@intFromPtr(&boot_srv), sys_tbl.boot_services);
    try testing.expect(sys_tbl.hdr.crc32 != 0);
    try testing.expect(boot_srv.hdr.crc32 != 0);
}

test "parseMbrPartitions and parseGptPartitions" {
    // 1. MBR test.
    var mbr_disk: [1024]u8 = @splat(0);
    const sig_off = MBR_SIGNATURE_OFFSET;
    const pt_off = MBR_PARTITION_TABLE_OFFSET;
    std.mem.writeInt(
        u16,
        mbr_disk[sig_off .. sig_off + 2],
        MBR_SIGNATURE,
        .little,
    );
    mbr_disk[pt_off] = 0x80; // Bootable.
    mbr_disk[pt_off + 4] = MBR_TYPE_EFI_SYSTEM;
    std.mem.writeInt(u32, mbr_disk[pt_off + 8 .. pt_off + 12], 2048, .little);
    std.mem.writeInt(u32, mbr_disk[pt_off + 12 .. pt_off + 16], 65536, .little);

    try testing.expectEqual(StorageFormat.mbr, detectStorageFormat(&mbr_disk));
    var mbr_parts: [4]MbrPartition = undefined;
    const mbr_count = try parseMbrPartitions(&mbr_disk, &mbr_parts);
    try testing.expectEqual(@as(usize, 1), mbr_count);
    try testing.expect(mbr_parts[0].bootable);
    try testing.expectEqual(MBR_TYPE_EFI_SYSTEM, mbr_parts[0].os_type);
    try testing.expectEqual(@as(u32, 2048), mbr_parts[0].first_lba);

    // 2. GPT test.
    var gpt_disk: [2048]u8 = @splat(0);
    const g_off = GPT_HEADER_OFFSET;
    @memcpy(gpt_disk[g_off .. g_off + 8], GPT_SIGNATURE);
    // Entries at LBA 2 (offset 1024), 4 entries, 128 bytes per entry.
    std.mem.writeInt(u64, gpt_disk[g_off + 72 .. g_off + 80], 2, .little);
    std.mem.writeInt(u32, gpt_disk[g_off + 80 .. g_off + 84], 4, .little);
    std.mem.writeInt(u32, gpt_disk[g_off + 84 .. g_off + 88], 128, .little);

    // Entry 0 at offset 1024.
    gpt_disk[1024] = 0x28; // Non-zero type GUID.
    std.mem.writeInt(u64, gpt_disk[1024 + 32 .. 1024 + 40], 2048, .little);
    std.mem.writeInt(u64, gpt_disk[1024 + 40 .. 1024 + 48], 4095, .little);

    try testing.expectEqual(StorageFormat.gpt, detectStorageFormat(&gpt_disk));
    var gpt_parts: [4]GptPartition = undefined;
    const gpt_count = try parseGptPartitions(&gpt_disk, &gpt_parts);
    try testing.expectEqual(@as(usize, 1), gpt_count);
    try testing.expectEqual(@as(u64, 2048), gpt_parts[0].first_lba);
    try testing.expectEqual(@as(u64, 4095), gpt_parts[0].last_lba);
}

test "parseIso9660Volume and findIso9660Path with nested directories" {
    var iso_img: [22 * ISO_SECTOR_SIZE]u8 = @splat(0);

    // Primary Volume Descriptor at sector 16.
    const pvd = iso_img[16 * ISO_SECTOR_SIZE .. 17 * ISO_SECTOR_SIZE];
    pvd[0] = ISO_VD_TYPE_PRIMARY;
    @memcpy(pvd[1..6], ISO_STD_ID);
    pvd[6] = 1;
    // Root directory record at offset 156: extent LBA = 18, length = 2048.
    const r_off = ISO_ROOT_DIR_RECORD_OFFSET;
    pvd[r_off] = 34;
    std.mem.writeInt(u32, pvd[r_off + 2 .. r_off + 6], 18, .little);
    std.mem.writeInt(
        u32,
        pvd[r_off + 10 .. r_off + 14],
        ISO_SECTOR_SIZE,
        .little,
    );

    // El Torito Boot Record Volume Descriptor at sector 17.
    const brvd = iso_img[17 * ISO_SECTOR_SIZE .. 18 * ISO_SECTOR_SIZE];
    brvd[0] = ISO_VD_TYPE_BOOT;
    @memcpy(brvd[1..6], ISO_STD_ID);
    const cat_off = EL_TORITO_BOOT_CATALOG_OFFSET;
    std.mem.writeInt(u32, brvd[cat_off .. cat_off + 4], 19, .little);

    // Root directory at sector 18 containing "KERNEL.ELF;1" (LBA 19) and
    // "BOOT" (directory at LBA 20).
    const root_dir = iso_img[18 * ISO_SECTOR_SIZE .. 19 * ISO_SECTOR_SIZE];
    const fname = "KERNEL.ELF;1";
    const rec1_len: u8 = @intCast(33 + fname.len);
    root_dir[0] = rec1_len;
    std.mem.writeInt(u32, root_dir[2..6], 19, .little);
    std.mem.writeInt(u32, root_dir[10..14], 512, .little);
    root_dir[25] = 0; // Regular file.
    root_dir[32] = @intCast(fname.len);
    @memcpy(root_dir[33 .. 33 + fname.len], fname);

    const dname = "BOOT";
    const rec2_off: usize = rec1_len;
    const rec2_len: u8 = @intCast(33 + dname.len);
    root_dir[rec2_off] = rec2_len;
    std.mem.writeInt(u32, root_dir[rec2_off + 2 .. rec2_off + 6], 20, .little);
    std.mem.writeInt(
        u32,
        root_dir[rec2_off + 10 .. rec2_off + 14],
        ISO_SECTOR_SIZE,
        .little,
    );
    root_dir[rec2_off + 25] = ISO_DIR_FLAG_DIRECTORY; // Subdirectory.
    root_dir[rec2_off + 32] = @intCast(dname.len);
    @memcpy(root_dir[rec2_off + 33 .. rec2_off + 33 + dname.len], dname);

    // Subdirectory /BOOT at sector 20 containing "LOADER.EFI;1" (LBA 21).
    const boot_dir = iso_img[20 * ISO_SECTOR_SIZE .. 21 * ISO_SECTOR_SIZE];
    const efifname = "LOADER.EFI;1";
    const rec3_len: u8 = @intCast(33 + efifname.len);
    boot_dir[0] = rec3_len;
    std.mem.writeInt(u32, boot_dir[2..6], 21, .little);
    std.mem.writeInt(u32, boot_dir[10..14], 1024, .little);
    boot_dir[25] = 0; // Regular file.
    boot_dir[32] = @intCast(efifname.len);
    @memcpy(boot_dir[33 .. 33 + efifname.len], efifname);

    try testing.expectEqual(
        StorageFormat.iso9660,
        detectStorageFormat(&iso_img),
    );
    const vol = try parseIso9660Volume(&iso_img);
    try testing.expectEqual(@as(u32, 18), vol.root_extent_lba);
    try testing.expectEqual(@as(?u32, 19), vol.boot_catalog_lba);

    const file_ext = try findIso9660FileInDir(
        &iso_img,
        vol.root_extent_lba,
        vol.root_data_length,
        "kernel.elf",
    );
    try testing.expectEqual(@as(u32, 19), file_ext.extent_lba);
    try testing.expectEqual(@as(u32, 512), file_ext.data_length);

    const nested_ext = try findIso9660Path(&iso_img, vol, "/boot/loader.efi");
    try testing.expectEqual(@as(u32, 21), nested_ext.extent_lba);
    try testing.expectEqual(@as(u32, 1024), nested_ext.data_length);
}

test {
    std.testing.refAllDecls(@This());
}
