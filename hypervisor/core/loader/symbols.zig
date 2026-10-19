// ELF class layout descriptors and symbol table resolution.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const elf_spec = @import("interface").elf;

pub const ElfLayout = struct {
    is_32: bool,
    ehdr_sz: usize,
    entry: usize,
    phoff: usize,
    phentsize: usize,
    phnum: usize,
    ph_off: usize,
    ph_vaddr: usize,
    ph_paddr: usize,
    ph_filesz: usize,
    ph_memsz: usize,
    shoff: usize,
    shentsize: usize,
    shnum: usize,
    sh_type: usize,
    sh_offset: usize,
    sh_size: usize,
    sh_link: usize,
    sh_entsize: usize,
    sym_name: usize,
    sym_value: usize,

    pub fn forClass(class: u8) ?ElfLayout {
        if (class != elf_spec.CLASS_32 and class != elf_spec.CLASS_64) {
            return null;
        }
        const c32 = class == elf_spec.CLASS_32;
        const E32 = elf_spec.EHDR32;
        const P32 = elf_spec.PHDR32;
        const S32 = elf_spec.SHDR32;
        const E64 = elf_spec.EHDR;
        const P64 = elf_spec.PHDR;
        const S64 = elf_spec.SHDR;
        return .{
            .is_32 = c32,
            .ehdr_sz = if (c32)
                elf_spec.ELF32_EHDR_SIZE
            else
                elf_spec.ELF64_EHDR_SIZE,
            .entry = if (c32) E32.ENTRY else E64.ENTRY,
            .phoff = if (c32) E32.PHOFF else E64.PHOFF,
            .phentsize = if (c32) E32.PHENTSIZE else E64.PHENTSIZE,
            .phnum = if (c32) E32.PHNUM else E64.PHNUM,
            .ph_off = if (c32) P32.OFFSET else P64.OFFSET,
            .ph_vaddr = if (c32) P32.VADDR else P64.VADDR,
            .ph_paddr = if (c32) P32.PADDR else P64.PADDR,
            .ph_filesz = if (c32) P32.FILESZ else P64.FILESZ,
            .ph_memsz = if (c32) P32.MEMSZ else P64.MEMSZ,
            .shoff = if (c32) E32.SHOFF else E64.SHOFF,
            .shentsize = if (c32) E32.SHENTSIZE else E64.SHENTSIZE,
            .shnum = if (c32) E32.SHNUM else E64.SHNUM,
            .sh_type = if (c32) S32.TYPE else S64.TYPE,
            .sh_offset = if (c32) S32.OFFSET else S64.OFFSET,
            .sh_size = if (c32) S32.SIZE else S64.SIZE,
            .sh_link = if (c32) S32.LINK else S64.LINK,
            .sh_entsize = if (c32) S32.ENTSIZE else S64.ENTSIZE,
            .sym_name = if (c32) elf_spec.SYM32.NAME else elf_spec.SYM.NAME,
            .sym_value = if (c32) elf_spec.SYM32.VALUE else elf_spec.SYM.VALUE,
        };
    }
};

pub fn findSymbol(source: []const u8, name: []const u8) ?u64 {
    if (source.len < elf_spec.MIN_HEADER_LEN or
        !std.mem.eql(u8, source[0..4], elf_spec.MAGIC)) return null;
    const lay = ElfLayout.forClass(source[elf_spec.EI_CLASS]) orelse
        return null;
    if (source.len < lay.ehdr_sz) return null;
    const sh_off = readWord(source, lay.shoff, lay.is_32);
    const sh_size = readU16(source, lay.shentsize);
    const sh_num = readU16(source, lay.shnum);
    const total_sh = std.math.mul(u64, sh_num, sh_size) catch return null;
    const sh_end = std.math.add(u64, sh_off, total_sh) catch return null;
    if (sh_end > source.len) return null;

    var sym_sh_off: u64 = 0;
    var sym_sh_sz: u64 = 0;
    var sym_sh_ent: u64 = 0;
    var sym_sh_lnk: u32 = 0;
    for (0..sh_num) |i| {
        const i_sh = std.math.mul(u64, i, sh_size) catch break;
        const off = std.math.add(u64, sh_off, i_sh) catch break;
        if (readU32(source, off + lay.sh_type) == elf_spec.SHT_SYMTAB) {
            sym_sh_off = readWord(source, off + lay.sh_offset, lay.is_32);
            sym_sh_sz = readWord(source, off + lay.sh_size, lay.is_32);
            sym_sh_lnk = readU32(source, off + lay.sh_link);
            sym_sh_ent = readWord(source, off + lay.sh_entsize, lay.is_32);
            break;
        }
    }
    if (sym_sh_off == 0 or sym_sh_sz == 0 or
        sym_sh_ent == 0 or sym_sh_lnk >= sh_num) return null;
    const lnk_sh = std.math.mul(u64, sym_sh_lnk, sh_size) catch return null;
    const str_sh = std.math.add(u64, sh_off, lnk_sh) catch return null;
    if (readU32(source, str_sh + lay.sh_type) != elf_spec.SHT_STRTAB) {
        return null;
    }
    const str_off = readWord(source, str_sh + lay.sh_offset, lay.is_32);
    const str_sz = readWord(source, str_sh + lay.sh_size, lay.is_32);
    if (str_off == 0 or str_sz == 0) return null;
    const str_end = std.math.add(u64, str_off, str_sz) catch return null;
    const sym_end = std.math.add(u64, sym_sh_off, sym_sh_sz) catch return null;
    if (str_end > source.len or sym_end > source.len) return null;

    const sym_count = sym_sh_sz / sym_sh_ent;
    for (0..sym_count) |idx| {
        const idx_off = std.math.mul(u64, idx, sym_sh_ent) catch break;
        const sym_off = std.math.add(u64, sym_sh_off, idx_off) catch break;
        const st_name = readU32(source, sym_off + lay.sym_name);
        if (st_name == 0 or st_name >= str_sz) continue;
        const s_start = std.math.add(u64, str_off, st_name) catch continue;
        const s_end = std.math.add(u64, s_start, str_sz - st_name) catch
            continue;
        const start_u = std.math.cast(usize, s_start) orelse continue;
        const end_u = std.math.cast(usize, s_end) orelse continue;
        if (end_u > source.len) continue;
        const sym_slice = source[start_u..end_u];
        const n_len = std.mem.indexOfScalar(u8, sym_slice, 0) orelse continue;
        if (std.mem.eql(u8, sym_slice[0..n_len], name)) {
            return readWord(source, sym_off + lay.sym_value, lay.is_32);
        }
    }
    return null;
}

pub fn readWord(buf: []const u8, off: usize, is_32: bool) u64 {
    return if (is_32) readInt(u32, buf, off) else readInt(u64, buf, off);
}

pub fn readInt(comptime T: type, buf: []const u8, off: usize) T {
    const end = std.math.add(usize, off, @sizeOf(T)) catch return 0;
    if (end > buf.len) return 0;
    return std.mem.readInt(T, buf[off..][0..@sizeOf(T)], .little);
}

pub fn readU16(buf: []const u8, off: usize) u16 {
    return readInt(u16, buf, off);
}

pub fn readU32(buf: []const u8, off: usize) u32 {
    return readInt(u32, buf, off);
}

test "ELF layout class resolution and symbol lookup" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;

    try testing.expect(ElfLayout.forClass(0) == null);
    const l32 = ElfLayout.forClass(elf_spec.CLASS_32).?;
    try testing.expect(l32.is_32);
    try testing.expectEqual(elf_spec.ELF32_EHDR_SIZE, l32.ehdr_sz);

    const l64 = ElfLayout.forClass(elf_spec.CLASS_64).?;
    try testing.expect(!l64.is_32);
    try testing.expectEqual(elf_spec.ELF64_EHDR_SIZE, l64.ehdr_sz);
}
