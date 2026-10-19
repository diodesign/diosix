// Diosix S-Mode Guest Bootloader Shim — PE32+ EFI Loader & UEFI Table Handoff.
//
// Provides freestanding, allocation-free parsing and loading of RISC-V 64
// PE32+ EFI applications (`.efi`) and minimal UEFI 2.10 System / Boot Services
// tables with IEEE 802.3 CRC32 header checksums.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const boot_loader = @import("loader.zig");
const BootLoaderError = boot_loader.BootLoaderError;
const KernelLoadResult = boot_loader.KernelLoadResult;

// PE32+ (.efi) constants.
pub const MZ_SIGNATURE: u16 = 0x5a4d; // "MZ".
pub const DOS_HEADER_MIN_SIZE: usize = 64;
pub const PE_LFA_NEW_OFFSET: usize = 0x3c;
pub const PE_SIGNATURE: u32 = 0x00004550; // "PE\0\0".
pub const COFF_HEADER_SIZE: usize = 20;
pub const IMAGE_FILE_MACHINE_RISCV64: u16 = 0x5064;
pub const PE32_PLUS_MAGIC: u16 = 0x020b;
pub const PE32_PLUS_MIN_OPT_HDR_SIZE: usize = 112;
pub const PE_SECTION_HEADER_SIZE: usize = 40;
pub const MAX_PE_SECTIONS: u16 = 64;

// Minimal UEFI Specification 2.10 table signatures.
pub const EFI_SYSTEM_TABLE_SIGNATURE: u64 = 0x5453595320494249; // "IBI SYST".
pub const EFI_BOOT_SERVICES_SIGNATURE: u64 = 0x56524553544f4f42; // "BOOTSERV".
pub const EFI_SPECIFICATION_REVISION: u32 = (2 << 16) | 100;

// Minimal UEFI Table Handoff Structures for S-Mode .efi Boot Loaders.
pub const EfiTableHeader = extern struct {
    signature: u64,
    revision: u32,
    header_size: u32,
    crc32: u32,
    reserved: u32 = 0,
};

pub const EfiBootServices64 = extern struct {
    hdr: EfiTableHeader,
    raise_tpl: u64 = 0,
    restore_tpl: u64 = 0,
    allocate_pages: u64 = 0,
    free_pages: u64 = 0,
    get_memory_map: u64 = 0,
    allocate_pool: u64 = 0,
    free_pool: u64 = 0,
    exit_boot_services: u64 = 0,
};

pub const EfiSystemTable64 = extern struct {
    hdr: EfiTableHeader,
    firmware_vendor: u64 = 0,
    firmware_revision: u32 = EFI_SPECIFICATION_REVISION,
    padding: u32 = 0,
    console_in_handle: u64 = 0,
    con_in: u64 = 0,
    console_out_handle: u64 = 0,
    con_out: u64 = 0,
    standard_error_handle: u64 = 0,
    std_err: u64 = 0,
    runtime_services: u64 = 0,
    boot_services: u64 = 0,
    number_of_table_entries: u64 = 0,
    configuration_table: u64 = 0,
};

/// Loads a PE32+ RISC-V 64 EFI application (.efi) into `dest_buf`.
pub fn loadPe32PlusEfi(
    pe_data: []const u8,
    dest_buf: []u8,
) BootLoaderError!KernelLoadResult {
    if (pe_data.len < DOS_HEADER_MIN_SIZE) return error.InvalidPeHeader;
    if (std.mem.readInt(u16, pe_data[0..2], .little) != MZ_SIGNATURE) {
        return error.InvalidPeHeader;
    }

    const lfa_off = PE_LFA_NEW_OFFSET;
    const pe_off =
        std.mem.readInt(u32, pe_data[lfa_off .. lfa_off + 4][0..4], .little);
    const coff_off = std.math.add(
        usize,
        pe_off,
        4,
    ) catch return error.InvalidPeHeader;
    const opt_off = std.math.add(
        usize,
        coff_off,
        COFF_HEADER_SIZE,
    ) catch return error.InvalidPeHeader;
    if (opt_off + 2 > pe_data.len) return error.InvalidPeHeader;

    const pe_sig =
        std.mem.readInt(u32, pe_data[pe_off .. pe_off + 4][0..4], .little);
    if (pe_sig != PE_SIGNATURE) return error.InvalidPeHeader;

    const machine =
        std.mem.readInt(u16, pe_data[coff_off .. coff_off + 2][0..2], .little);
    if (machine != IMAGE_FILE_MACHINE_RISCV64) {
        return error.UnsupportedPeMachine;
    }

    const num_sections = std.mem.readInt(
        u16,
        pe_data[coff_off + 2 .. coff_off + 4][0..2],
        .little,
    );
    const size_of_opt_hdr = std.mem.readInt(
        u16,
        pe_data[coff_off + 16 .. coff_off + 18][0..2],
        .little,
    );
    if (num_sections == 0 or num_sections > MAX_PE_SECTIONS) {
        return error.InvalidPeHeader;
    }
    if (size_of_opt_hdr < PE32_PLUS_MIN_OPT_HDR_SIZE) {
        return error.InvalidPeHeader;
    }

    const sec_table_off = std.math.add(
        usize,
        opt_off,
        size_of_opt_hdr,
    ) catch return error.InvalidPeHeader;
    const sec_table_bytes = std.math.mul(
        usize,
        num_sections,
        PE_SECTION_HEADER_SIZE,
    ) catch return error.InvalidPeHeader;
    const sec_table_end = std.math.add(
        usize,
        sec_table_off,
        sec_table_bytes,
    ) catch return error.InvalidPeHeader;
    if (sec_table_end > pe_data.len) return error.InvalidPeHeader;

    const opt_magic =
        std.mem.readInt(u16, pe_data[opt_off .. opt_off + 2][0..2], .little);
    if (opt_magic != PE32_PLUS_MAGIC) return error.InvalidPeHeader;

    const entry_rva = std.mem.readInt(
        u32,
        pe_data[opt_off + 16 .. opt_off + 20][0..4],
        .little,
    );
    const image_base = std.mem.readInt(
        u64,
        pe_data[opt_off + 24 .. opt_off + 32][0..8],
        .little,
    );
    const size_of_image = std.mem.readInt(
        u32,
        pe_data[opt_off + 56 .. opt_off + 60][0..4],
        .little,
    );
    const size_of_headers = std.mem.readInt(
        u32,
        pe_data[opt_off + 60 .. opt_off + 64][0..4],
        .little,
    );

    if (size_of_image == 0 or size_of_image > dest_buf.len) {
        return error.DestinationOutOfBounds;
    }
    if (size_of_headers > pe_data.len or size_of_headers > size_of_image) {
        return error.InvalidPeHeader;
    }

    @memset(dest_buf[0..size_of_image], 0);
    @memcpy(dest_buf[0..size_of_headers], pe_data[0..size_of_headers]);

    var i: usize = 0;
    while (i < num_sections) : (i += 1) {
        const sh_off = sec_table_off + i * PE_SECTION_HEADER_SIZE;
        const virt_size = std.mem.readInt(
            u32,
            pe_data[sh_off + 8 .. sh_off + 12][0..4],
            .little,
        );
        const virt_addr = std.mem.readInt(
            u32,
            pe_data[sh_off + 12 .. sh_off + 16][0..4],
            .little,
        );
        const raw_size = std.mem.readInt(
            u32,
            pe_data[sh_off + 16 .. sh_off + 20][0..4],
            .little,
        );
        const raw_ptr = std.mem.readInt(
            u32,
            pe_data[sh_off + 20 .. sh_off + 24][0..4],
            .little,
        );

        const copy_sz =
            if (virt_size > 0) @min(virt_size, raw_size) else raw_size;
        if (copy_sz == 0) continue;

        const src_end = std.math.add(
            usize,
            raw_ptr,
            copy_sz,
        ) catch return error.SegmentOutOfBounds;
        if (src_end > pe_data.len) return error.SegmentOutOfBounds;

        const dst_end = std.math.add(
            usize,
            virt_addr,
            copy_sz,
        ) catch return error.DestinationOutOfBounds;
        if (dst_end > size_of_image) return error.DestinationOutOfBounds;

        @memcpy(dest_buf[virt_addr..dst_end], pe_data[raw_ptr..src_end]);
    }

    if (entry_rva >= size_of_image) return error.InvalidPeHeader;

    return KernelLoadResult{
        .format = .pe32_plus_efi,
        .entry_offset = entry_rva,
        .loaded_end_offset = size_of_image,
        .preferred_base_gpa = image_base,
    };
}

/// Initializes a minimal UEFI 2.10 System Table and Boot Services Table for
/// `.efi` stubs, computing IEEE 802.3 CRC32 checksums per the UEFI spec.
pub fn initMinimalEfiTables(
    sys_table: *EfiSystemTable64,
    boot_services: *EfiBootServices64,
) void {
    boot_services.* = .{
        .hdr = .{
            .signature = EFI_BOOT_SERVICES_SIGNATURE,
            .revision = EFI_SPECIFICATION_REVISION,
            .header_size = @sizeOf(EfiBootServices64),
            .crc32 = 0,
        },
    };
    boot_services.hdr.crc32 =
        std.hash.Crc32.hash(std.mem.asBytes(boot_services));

    sys_table.* = .{
        .hdr = .{
            .signature = EFI_SYSTEM_TABLE_SIGNATURE,
            .revision = EFI_SPECIFICATION_REVISION,
            .header_size = @sizeOf(EfiSystemTable64),
            .crc32 = 0,
        },
        .boot_services = @intFromPtr(boot_services),
    };
    sys_table.hdr.crc32 = std.hash.Crc32.hash(std.mem.asBytes(sys_table));
}
