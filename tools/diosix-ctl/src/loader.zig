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
pub const GuestBootExtras = pe.GuestBootExtras;
pub const isRiscvFlatImage = pe.isRiscvFlatImage;
pub const isPe32PlusEfi = pe.isPe32PlusEfi;
pub const requiresShimBoot = pe.requiresShimBoot;

pub const FDT_MAGIC_BE: u32 = fdt_patch.FDT_MAGIC_BE;
pub const FDT_OFF_DT_STRUCT: usize = fdt_patch.FDT_OFF_DT_STRUCT;
pub const FDT_OFF_DT_STRINGS: usize = fdt_patch.FDT_OFF_DT_STRINGS;
pub const FDT_MIN_HEADER_SIZE: usize = fdt_patch.FDT_MIN_HEADER_SIZE;
pub const FDT_ALIGN: usize = fdt_patch.FDT_ALIGN;
pub const FDT_PROP_HEADER_SIZE: usize = fdt_patch.FDT_PROP_HEADER_SIZE;
pub const FdtToken = fdt_patch.FdtToken;
pub const patchChildDtb = fdt_patch.patchChildDtb;

pub const MAX_FOREIGN_MAP_BYTES: usize = 256 * 1024 * 1024;
pub const LOAD_CHUNK_BYTES: usize = 2 * 1024 * 1024;
pub const PROGRESS_CHUNK_BYTES: usize = 8 * 1024 * 1024;
pub const DEFAULT_PARENT_MAP_GPA: usize = 0x2_0000_0000;
pub const MAP_CHILD_RW_FLAGS: usize = 3;

pub const ELF_MAGIC = "\x7fELF";
pub const ELF_EI_CLASS_OFFSET: usize = 4;
pub const ELF_E_MACHINE_OFFSET: usize = 18;
pub const ELFCLASS32: u8 = 1;
pub const ELFCLASS64: u8 = 2;
pub const EM_X86_64: u16 = 62;
pub const EM_AARCH64: u16 = 183;
pub const EM_RISCV: u16 = 243;
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

/// Detects the target architecture (`riscv64`, `riscv32`, `aarch64`, `x86_64`)
/// from an ELF header.
pub fn detectElfArch(elf_data: []const u8) ?api.TargetArch {
    if (elf_data.len < ELF32_EHDR_SIZE) return null;
    if (!std.mem.eql(u8, elf_data[0..4], ELF_MAGIC)) return null;
    const class = elf_data[ELF_EI_CLASS_OFFSET];
    const machine = readLeU16(elf_data, ELF_E_MACHINE_OFFSET);
    return switch (machine) {
        EM_RISCV => if (class == ELFCLASS32) .riscv32 else .riscv64,
        EM_AARCH64 => .aarch64,
        EM_X86_64 => .x86_64,
        else => null,
    };
}

/// Resolves the effective guest architecture from `elf_data` and `req_arch`.
/// Recognizes `aarch64` and `x86_64` VMs and reports a descriptive error that
/// those architectures are not yet supported.
pub fn checkGuestArch(
    elf_data: []const u8,
    req_arch: api.TargetArch,
) ?api.TargetArch {
    const eff_arch = detectElfArch(elf_data) orelse req_arch;
    if (eff_arch == .aarch64 or req_arch == .aarch64) {
        console.printStr(
            "Error: Guest VM architecture 'aarch64' is recognized, " ++
                "but AArch64 emulation is not yet supported " ++
                "(supported: riscv64, riscv32).\n",
        );
        return null;
    }
    if (eff_arch == .x86_64 or req_arch == .x86_64) {
        console.printStr(
            "Error: Guest VM architecture 'x86_64' is recognized, " ++
                "but x86_64 emulation is not yet supported " ++
                "(supported: riscv64, riscv32).\n",
        );
        return null;
    }
    return eff_arch;
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
    return loadGuestImageViaForeignMapping(
        client,
        child_cid,
        elf_data,
        dtb_data,
        shim_payload,
        .{},
        base_gpa,
        ram_bytes,
        vcpus,
    );
}

pub fn loadGuestImageViaForeignMapping(
    client: *api.DiosixClient,
    child_cid: usize,
    elf_data: []const u8,
    dtb_data: []u8,
    shim_payload: []const u8,
    extras: GuestBootExtras,
    base_gpa: usize,
    ram_bytes: usize,
    vcpus: usize,
) !usize {
    if (pe.isRiscvFlatImage(elf_data)) {
        const entry_gpa = try pe.loadFlatImageToChildRam(
            client,
            child_cid,
            elf_data,
            base_gpa,
            ram_bytes,
        );
        return pe.finalizeChildBootState(
            client,
            child_cid,
            entry_gpa,
            dtb_data,
            shim_payload,
            extras,
            base_gpa,
            ram_bytes,
            vcpus,
        );
    }
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

        const rel_start = seg_offset - aligned_start;
        const rel_file_end = rel_start + p_filesz;
        const rel_seg_end = rel_start + p_memsz;
        const seg_base_pct = 30 +
            ((seg_idx - 1) * 55) / @max(@as(usize, 1), load_seg_total);
        const seg_span_pct = 55 / @max(@as(usize, 1), load_seg_total);

        var chunk_off: usize = 0;
        while (chunk_off < seg_map_sz) : (chunk_off += LOAD_CHUNK_BYTES) {
            const chunk_sz = @min(LOAD_CHUNK_BYTES, seg_map_sz - chunk_off);
            const chunk_end = chunk_off + chunk_sz;
            if (chunk_off == 0 or (chunk_off % PROGRESS_CHUNK_BYTES) == 0) {
                const denom = @max(@as(usize, 1), seg_map_sz);
                const pct = seg_base_pct + (chunk_off * seg_span_pct) / denom;
                console.printFmt(
                    "[{d}%] Loading guest ELF segment {d}/{d} ({d} KB)...\n",
                    .{ pct, seg_idx, load_seg_total, p_memsz / 1024 },
                );
            }
            const seg_ram = try client.mapChildMemory(
                child_cid,
                base_gpa + aligned_start + chunk_off,
                parent_gpa,
                chunk_sz,
                MAP_CHILD_RW_FLAGS,
            );
            defer client.unmapChildMemory(seg_ram, parent_gpa) catch {};

            const copy_start = @max(chunk_off, rel_start);
            const copy_end = @min(chunk_end, rel_file_end);
            if (copy_end > copy_start) {
                const dst_off = copy_start - chunk_off;
                const src_off = p_offset + (copy_start - rel_start);
                const len = copy_end - copy_start;
                @memcpy(
                    seg_ram[dst_off .. dst_off + len],
                    elf_data[src_off .. src_off + len],
                );
            }
            const bss_start = @max(chunk_off, rel_file_end);
            const bss_end = @min(chunk_end, rel_seg_end);
            if (bss_end > bss_start) {
                @memset(
                    seg_ram[(bss_start - chunk_off)..(bss_end - chunk_off)],
                    0,
                );
            }
        }
    }

    const entry_off = std.math.cast(usize, entry_point - min_vaddr) orelse
        return error.InvalidElfHeader;
    if (entry_off >= ram_bytes) return error.SegmentOutOfBounds;
    const entry_gpa = std.math.add(usize, base_gpa, entry_off) catch
        return error.SegmentOutOfBounds;

    return pe.finalizeChildBootState(
        client,
        child_cid,
        entry_gpa,
        dtb_data,
        shim_payload,
        extras,
        base_gpa,
        ram_bytes,
        vcpus,
    );
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

    var elf_hdr: [ELF64_EHDR_SIZE]u8 = @splat(0);
    @memcpy(elf_hdr[0..4], ELF_MAGIC);
    elf_hdr[ELF_EI_CLASS_OFFSET] = ELFCLASS64;
    std.mem.writeInt(
        u16,
        elf_hdr[ELF_E_MACHINE_OFFSET..][0..2],
        EM_AARCH64,
        .little,
    );
    try std.testing.expectEqual(
        api.TargetArch.aarch64,
        detectElfArch(&elf_hdr).?,
    );
    try std.testing.expect(
        checkGuestArch(&elf_hdr, .riscv64) == null,
    );

    std.mem.writeInt(
        u16,
        elf_hdr[ELF_E_MACHINE_OFFSET..][0..2],
        EM_X86_64,
        .little,
    );
    try std.testing.expectEqual(
        api.TargetArch.x86_64,
        detectElfArch(&elf_hdr).?,
    );
    try std.testing.expect(
        checkGuestArch(&elf_hdr, .riscv64) == null,
    );
}
