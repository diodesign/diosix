// ELF class layout descriptors and binary reader helpers.
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

    pub fn forClass(class: u8) ?ElfLayout {
        if (class != elf_spec.CLASS_32 and class != elf_spec.CLASS_64) {
            return null;
        }
        const c32 = class == elf_spec.CLASS_32;
        const E32 = elf_spec.EHDR32;
        const P32 = elf_spec.PHDR32;
        const E64 = elf_spec.EHDR;
        const P64 = elf_spec.PHDR;
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
        };
    }
};

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

test "ELF layout class resolution" {
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
