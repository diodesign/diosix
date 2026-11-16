// Guest Shim Payload, Flat RISC-V Image, and Initrd Staging Helpers.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const api = @import("../api.zig");
const console = @import("../console.zig");
const fdt_patch = @import("../vm/fdt_patch.zig");
const fdt_guest = @import("../vm/fdt_guest.zig");

pub const SHIM_HEADER_OFFSET: usize = 0x0010_0000;
pub const SHIM_HEADER_MAGIC: u64 = 0x4d49_4853_5853_4f44; // "DOSXSHIM".
pub const PAGE_ALIGN: usize = 0x1000;
pub const LOAD_CHUNK_BYTES: usize = 2 * 1024 * 1024;
pub const DEFAULT_PARENT_MAP_GPA: usize = 0x2_0000_0000;
pub const MAP_CHILD_RW_FLAGS: usize = 3;

pub const RISCV_IMAGE_HEADER_SIZE: usize = 64;
pub const RISCV_IMAGE_TEXT_OFFSET_POS: usize = 8;
pub const RISCV_IMAGE_SIZE_POS: usize = 16;
pub const RISCV_IMAGE_MAGIC_POS: usize = 48;
pub const RISCV_IMAGE_MAGIC2_POS: usize = 56;
pub const RISCV_IMAGE_MAGIC_LEGACY: u32 =
    std.mem.readInt(u32, "RSCV", .little);
pub const RISCV_IMAGE_MAGIC2: u32 =
    std.mem.readInt(u32, "RSC\x05", .little);

pub const MZ_SIGNATURE: u16 = 0x5a4d;
pub const DOS_HEADER_MIN_SIZE: usize = 64;
pub const PE_LFA_NEW_OFFSET: usize = 0x3c;
pub const PE_SIGNATURE: u32 = 0x0000_4550;
pub const COFF_HEADER_SIZE: usize = 20;
pub const PE32_PLUS_MAGIC: u16 = 0x020b;

pub const GuestBootExtras = struct {
    initrd_data: []const u8 = &.{},
    cmdline: ?[]const u8 = null,
    is_shim_boot: bool = false,
    ip_autoconfig: ?[]const u8 = null,
};

pub fn isRiscvFlatImage(data: []const u8) bool {
    if (data.len < RISCV_IMAGE_HEADER_SIZE) return false;
    const m1 = std.mem.readInt(
        u32,
        data[RISCV_IMAGE_MAGIC_POS..][0..4],
        .little,
    );
    const m2 = std.mem.readInt(
        u32,
        data[RISCV_IMAGE_MAGIC2_POS..][0..4],
        .little,
    );
    return m2 == RISCV_IMAGE_MAGIC2 or m1 == RISCV_IMAGE_MAGIC_LEGACY;
}

pub fn isPe32PlusEfi(data: []const u8) bool {
    if (data.len < DOS_HEADER_MIN_SIZE) return false;
    if (std.mem.readInt(u16, data[0..2], .little) != MZ_SIGNATURE) return false;
    const pe_off: usize = std.mem.readInt(
        u32,
        data[PE_LFA_NEW_OFFSET..][0..4],
        .little,
    );
    const pe_end = std.math.add(
        usize,
        pe_off,
        4 + COFF_HEADER_SIZE + 2,
    ) catch return false;
    if (pe_end > data.len) return false;
    const sig = std.mem.readInt(u32, data[pe_off..][0..4], .little);
    const opt_magic = std.mem.readInt(
        u16,
        data[pe_off + 4 + COFF_HEADER_SIZE ..][0..2],
        .little,
    );
    return sig == PE_SIGNATURE and opt_magic == PE32_PLUS_MAGIC;
}

/// Returns `true` when `path` or `data` is a bootable disk/ISO/EFI image that
/// should be booted through `guest-shim` rather than direct ELF/Image loading.
pub fn requiresShimBoot(path: []const u8, data: []const u8) bool {
    if (std.mem.endsWith(u8, path, ".iso") or
        std.mem.endsWith(u8, path, ".efi") or
        std.mem.endsWith(u8, path, ".img") or
        std.mem.endsWith(u8, path, ".raw"))
    {
        return true;
    }
    if (isPe32PlusEfi(data)) return true;
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], "\x7fELF")) return false;
    if (isRiscvFlatImage(data)) return false;
    return true;
}

/// Computes the target GPA offset in child RAM for staging a `guest-shim`
/// payload near the top of RAM, leaving `[+2 MiB .. payload_offset]`
/// maximally contiguous for kernel decompression and guest system memory.
pub fn computeShimPayloadOffset(
    ram_bytes: usize,
    dtb_offset: usize,
    payload_len: usize,
) !?usize {
    if (payload_len == 0 or
        dtb_offset <= 0x0080_0000 or
        SHIM_HEADER_OFFSET + 24 > ram_bytes)
    {
        return null;
    }
    const aligned_len = std.mem.alignForward(usize, payload_len, PAGE_ALIGN);
    const min_needed = std.math.add(
        usize,
        aligned_len,
        0x0040_0000 + PAGE_ALIGN,
    ) catch return error.SegmentOutOfBounds;
    if (min_needed > dtb_offset) return error.SegmentOutOfBounds;

    const max_start = dtb_offset - aligned_len - PAGE_ALIGN;
    const pmd_aligned = std.mem.alignBackward(usize, max_start, 0x0020_0000);
    const payload_offset: usize = if (pmd_aligned >= 0x0040_0000)
        pmd_aligned
    else
        std.mem.alignBackward(usize, max_start, PAGE_ALIGN);
    if (payload_offset < 0x0040_0000 or
        payload_offset >= dtb_offset or
        payload_len > dtb_offset - payload_offset)
    {
        return error.SegmentOutOfBounds;
    }
    return payload_offset;
}

/// Writes the 24-byte `DOSXSHIM` header into the mapped header page.
pub fn writeShimHeader(
    hdr_page: []u8,
    payload_offset: usize,
    payload_len: usize,
) void {
    std.mem.writeInt(u64, hdr_page[0..8], SHIM_HEADER_MAGIC, .little);
    std.mem.writeInt(u64, hdr_page[8..16], payload_offset, .little);
    std.mem.writeInt(u64, hdr_page[16..24], payload_len, .little);
}

/// Loads a flat RISC-V `Image` (`RSC\x05` / `RSCV`) into child RAM via
/// foreign memory mapping and returns the entry GPA.
pub fn loadFlatImageToChildRam(
    client: *api.DiosixClient,
    child_cid: usize,
    image_data: []const u8,
    base_gpa: usize,
    ram_bytes: usize,
) !usize {
    if (!isRiscvFlatImage(image_data)) return error.InvalidElfHeader;
    const raw_text_off: usize = @intCast(
        std.mem.readInt(
            u64,
            image_data[RISCV_IMAGE_TEXT_OFFSET_POS..][0..8],
            .little,
        ),
    );
    const raw_img_sz: usize = @intCast(
        std.mem.readInt(
            u64,
            image_data[RISCV_IMAGE_SIZE_POS..][0..8],
            .little,
        ),
    );
    const text_off: usize = if (raw_text_off < ram_bytes / 2)
        std.mem.alignBackward(usize, raw_text_off, PAGE_ALIGN)
    else
        0x0020_0000;
    const mem_sz: usize = @max(image_data.len, raw_img_sz);
    const img_end = std.math.add(usize, text_off, mem_sz) catch
        return error.SegmentOutOfBounds;
    if (img_end > ram_bytes) return error.SegmentOutOfBounds;

    const aligned_end = std.mem.alignForward(usize, img_end, PAGE_ALIGN);
    const map_total = aligned_end - text_off;

    var chunk_off: usize = 0;
    while (chunk_off < map_total) : (chunk_off += LOAD_CHUNK_BYTES) {
        const chunk_sz = @min(LOAD_CHUNK_BYTES, map_total - chunk_off);
        const seg_ram = try client.mapChildMemory(
            child_cid,
            base_gpa + text_off + chunk_off,
            DEFAULT_PARENT_MAP_GPA,
            chunk_sz,
            MAP_CHILD_RW_FLAGS,
        );
        defer client.unmapChildMemory(seg_ram, DEFAULT_PARENT_MAP_GPA) catch {};

        if (chunk_off < image_data.len) {
            const copy_len = @min(chunk_sz, image_data.len - chunk_off);
            @memcpy(
                seg_ram[0..copy_len],
                image_data[chunk_off .. chunk_off + copy_len],
            );
            if (copy_len < chunk_sz) @memset(seg_ram[copy_len..chunk_sz], 0);
        } else {
            @memset(seg_ram[0..chunk_sz], 0);
        }
    }
    console.printFmt(
        "[80%] Loaded RISC-V flat Image ({d} KB) at +0x{x}...\n",
        .{ image_data.len / 1024, text_off },
    );
    return base_gpa + text_off;
}

/// Stages `initrd_data`, `dtb_data`, and `shim_payload` into child RAM and
/// starts the guest VM.
pub fn finalizeChildBootState(
    client: *api.DiosixClient,
    child_cid: usize,
    entry_gpa: usize,
    dtb_data: []u8,
    shim_payload: []const u8,
    extras: GuestBootExtras,
    base_gpa: usize,
    ram_bytes: usize,
    vcpus: usize,
) !usize {
    const dtb_offset = if (ram_bytes > 4 * 1024 * 1024)
        ram_bytes - (3 * 1024 * 1024)
    else
        0;

    var initrd_start_gpa: u64 = 0;
    var initrd_end_gpa: u64 = 0;
    if (extras.initrd_data.len > 0 and dtb_offset > PAGE_ALIGN) {
        const aligned_initrd_len = std.mem.alignForward(
            usize,
            extras.initrd_data.len,
            PAGE_ALIGN,
        );
        if (aligned_initrd_len + 0x0040_0000 >= dtb_offset) {
            return error.SegmentOutOfBounds;
        }
        const initrd_off = std.mem.alignBackward(
            usize,
            dtb_offset - aligned_initrd_len - PAGE_ALIGN,
            PAGE_ALIGN,
        );
        var off: usize = 0;
        while (off < extras.initrd_data.len) : (off += LOAD_CHUNK_BYTES) {
            const copy_sz = @min(
                LOAD_CHUNK_BYTES,
                extras.initrd_data.len - off,
            );
            const map_sz = std.mem.alignForward(usize, copy_sz, PAGE_ALIGN);
            const chunk_ram = try client.mapChildMemory(
                child_cid,
                base_gpa + initrd_off + off,
                DEFAULT_PARENT_MAP_GPA,
                map_sz,
                MAP_CHILD_RW_FLAGS,
            );
            defer client.unmapChildMemory(
                chunk_ram,
                DEFAULT_PARENT_MAP_GPA,
            ) catch {};
            @memcpy(
                chunk_ram[0..copy_sz],
                extras.initrd_data[off .. off + copy_sz],
            );
        }
        initrd_start_gpa = @intCast(base_gpa + initrd_off);
        initrd_end_gpa = initrd_start_gpa + extras.initrd_data.len;
    }

    const payload_ceiling = if (initrd_start_gpa != 0)
        @as(usize, @intCast(initrd_start_gpa - base_gpa))
    else
        dtb_offset;
    const maybe_payload_offset = try computeShimPayloadOffset(
        ram_bytes,
        payload_ceiling,
        shim_payload.len,
    );

    var dtb_gpa: usize = 0;
    if (dtb_data.len > 0) {
        const expanded = fdt_patch.expandChildDtbCpuNodes(
            std.heap.page_allocator,
            dtb_data,
            vcpus,
        );
        defer if (expanded) |exp| std.heap.page_allocator.free(exp);
        const cpu_dtb = expanded orelse dtb_data;
        fdt_patch.patchChildDtb(cpu_dtb, base_gpa, @intCast(ram_bytes), vcpus);

        var rsv_entries: [2]fdt_guest.MemReserveEntry = @splat(
            .{ .address = 0, .size = 0 },
        );
        var rsv_count: usize = 0;
        if (maybe_payload_offset) |poff| {
            rsv_entries[0] = .{
                .address = @intCast(base_gpa + SHIM_HEADER_OFFSET),
                .size = PAGE_ALIGN,
            };
            rsv_entries[1] = .{
                .address = @intCast(base_gpa + poff),
                .size = @intCast(
                    std.mem.alignForward(usize, shim_payload.len, PAGE_ALIGN),
                ),
            };
            rsv_count = 2;
        }

        const need_inject = extras.is_shim_boot or
            extras.cmdline != null or
            initrd_start_gpa != 0 or
            rsv_count > 0;
        const injected = if (need_inject)
            fdt_guest.injectChosenProperties(
                std.heap.page_allocator,
                cpu_dtb,
                .{
                    .vcpus = vcpus,
                    .is_shim_boot = extras.is_shim_boot,
                    .custom_cmdline = extras.cmdline,
                    .ip_autoconfig = extras.ip_autoconfig,
                    .initrd_start = initrd_start_gpa,
                    .initrd_end = initrd_end_gpa,
                    .reserved_regions = rsv_entries[0..rsv_count],
                },
            )
        else
            null;
        defer if (injected) |inj| std.heap.page_allocator.free(inj);
        const eff_dtb = injected orelse cpu_dtb;

        const dtb_end = std.math.add(usize, dtb_offset, eff_dtb.len) catch
            return error.SegmentOutOfBounds;
        if (dtb_end > ram_bytes) return error.SegmentOutOfBounds;
        dtb_gpa = std.math.add(usize, base_gpa, dtb_offset) catch
            return error.SegmentOutOfBounds;
        const dtb_aligned = std.mem.alignBackward(
            usize,
            dtb_offset,
            PAGE_ALIGN,
        );
        const dtb_end_aligned = std.mem.alignForward(
            usize,
            dtb_end,
            PAGE_ALIGN,
        );
        const dtb_map_sz = dtb_end_aligned - dtb_aligned;
        const dtb_ram = try client.mapChildMemory(
            child_cid,
            base_gpa + dtb_aligned,
            DEFAULT_PARENT_MAP_GPA,
            dtb_map_sz,
            MAP_CHILD_RW_FLAGS,
        );
        defer client.unmapChildMemory(dtb_ram, DEFAULT_PARENT_MAP_GPA) catch {};
        const rel_dtb = dtb_offset - dtb_aligned;
        @memcpy(dtb_ram[rel_dtb .. rel_dtb + eff_dtb.len], eff_dtb);
    }

    if (maybe_payload_offset) |payload_offset| {
        var off: usize = 0;
        while (off < shim_payload.len) : (off += LOAD_CHUNK_BYTES) {
            const copy_sz = @min(LOAD_CHUNK_BYTES, shim_payload.len - off);
            const map_sz = std.mem.alignForward(usize, copy_sz, PAGE_ALIGN);
            const chunk_ram = try client.mapChildMemory(
                child_cid,
                base_gpa + payload_offset + off,
                DEFAULT_PARENT_MAP_GPA,
                map_sz,
                MAP_CHILD_RW_FLAGS,
            );
            defer client.unmapChildMemory(
                chunk_ram,
                DEFAULT_PARENT_MAP_GPA,
            ) catch {};
            @memcpy(chunk_ram[0..copy_sz], shim_payload[off .. off + copy_sz]);
        }
        const hdr_ram = try client.mapChildMemory(
            child_cid,
            base_gpa + SHIM_HEADER_OFFSET,
            DEFAULT_PARENT_MAP_GPA,
            PAGE_ALIGN,
            MAP_CHILD_RW_FLAGS,
        );
        defer client.unmapChildMemory(hdr_ram, DEFAULT_PARENT_MAP_GPA) catch {};
        writeShimHeader(hdr_ram, payload_offset, shim_payload.len);
    }

    console.printStr(
        "[95%] Configuring device tree and starting guest vCPUs...\n",
    );
    _ = try client.startGuest(child_cid, entry_gpa, dtb_gpa);
    return entry_gpa;
}

test "loader/pe: computeShimPayloadOffset, writeShimHeader, and format checks" {
    std.testing.refAllDecls(@This());
    var hdr_page: [PAGE_ALIGN]u8 = @splat(0);
    const payload = "test-payload";
    const off = (try computeShimPayloadOffset(
        0x0100_0000,
        0x00c0_0000,
        payload.len,
    )).?;
    writeShimHeader(&hdr_page, off, payload.len);
    const magic = std.mem.readInt(u64, hdr_page[0..8], .little);
    try std.testing.expectEqual(SHIM_HEADER_MAGIC, magic);

    var rsc_hdr: [64]u8 = @splat(0);
    @memcpy(rsc_hdr[56..60], "RSC\x05");
    try std.testing.expect(isRiscvFlatImage(&rsc_hdr));
    try std.testing.expect(!requiresShimBoot("Image", &rsc_hdr));
    try std.testing.expect(requiresShimBoot("installer.iso", &rsc_hdr));
}
