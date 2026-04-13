// Root VM ELF loader.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const guest = @import("guest.zig");
const debug = @import("debug.zig");
const sv39x4 = @import("sv39x4.zig");
const elf_spec = @import("interface").elf;

pub const LoaderError = error{
    InvalidElfHeader,
    UnsupportedElfClass,
    UnsupportedElfData,
    UnsupportedElfMachine,
    InvalidProgramHeader,
    TranslationFailed,
};

pub const Loader = struct {
    pub fn load(root_vm: *guest.Guest, source: []const u8) !usize {
        // Basic ELF Header validation.
        if (source.len < 64) return LoaderError.InvalidElfHeader;
        if (!std.mem.eql(u8, source[elf_spec.EHDR.IDENT .. elf_spec.EHDR.IDENT + 4], elf_spec.MAGIC)) return LoaderError.InvalidElfHeader;
        
        // Class: 64-bit is 2.
        if (source[4] != elf_spec.CLASS_64) return LoaderError.UnsupportedElfClass;
        // Data: Little Endian is 1.
        if (source[5] != elf_spec.DATA_LSB) return LoaderError.UnsupportedElfData;

        // Machine: RISC-V is 0xF3.
        const machine = readU16(source, elf_spec.EHDR.MACHINE);
        if (machine != elf_spec.MACHINE_RISCV) return LoaderError.UnsupportedElfMachine;

        const entry_point = readU64(source, elf_spec.EHDR.ENTRY);
        const ph_off = readU64(source, elf_spec.EHDR.PHOFF);
        const ph_num = readU16(source, elf_spec.EHDR.PHNUM);
        const ph_size = readU16(source, elf_spec.EHDR.PHENTSIZE);

        var i: usize = 0;
        while (i < ph_num) : (i += 1) {
            const off = ph_off + (i * ph_size);
            if (off + ph_size > source.len) return LoaderError.InvalidProgramHeader;

            const p_type = readU32(source, off + elf_spec.PHDR.TYPE);
            if (p_type == elf_spec.PT_LOAD) {
                const p_offset = readU64(source, off + elf_spec.PHDR.OFFSET);
                const p_vaddr = readU64(source, off + elf_spec.PHDR.VADDR);
                const p_filesz = readU64(source, off + elf_spec.PHDR.FILESZ);
                const p_memsz = readU64(source, off + elf_spec.PHDR.MEMSZ);

                // Translate high virtual addresses to Guest Physical Addresses (GPA).
                const gpa = (p_vaddr & 0xFFFFFFFF);

                // Map and load the segment. 
                if (p_filesz > 0) {
                    const segment_data = source[p_offset .. p_offset + p_filesz];
                    const hpa = try root_vm.space.translateGPA(gpa);
                    @memcpy(@as([*]u8, @ptrFromInt(hpa))[0..p_filesz], segment_data);
                }
                
                // Map the segment in the guest's address space as RWX as requested.
                // We use p_memsz to cover the full segment size including BSS.
                // AddressSpace.map handles page alignment.
                const rwx_flags = sv39x4.PTEFlags.read | sv39x4.PTEFlags.write | sv39x4.PTEFlags.execute | sv39x4.PTEFlags.valid | sv39x4.PTEFlags.accessed | sv39x4.PTEFlags.dirty | sv39x4.PTEFlags.user;
                const hpa_start = try root_vm.space.translateGPA(gpa);
                try root_vm.space.map(gpa, hpa_start, p_memsz, rwx_flags);
                
                // Zero out any remaining memory in the segment (BSS).
                if (p_memsz > p_filesz) {
                    const bss_gpa = gpa + p_filesz;
                    const hpa = try root_vm.space.translateGPA(bss_gpa);
                    @memset(@as([*]u8, @ptrFromInt(hpa))[0 .. p_memsz - p_filesz], 0);
                }

                debug.printf("Loaded and mapped ELF segment: VADDR 0x{x} -> GPA 0x{x} ({} bytes)\n", .{ p_vaddr, gpa, p_memsz });
            }
        }

        return entry_point;
    }

    // Byte-level little-endian readers for manual parsing.
    fn readU16(buf: []const u8, off: usize) u16 {
        return @as(u16, buf[off]) | (@as(u16, buf[off + 1]) << 8);
    }

    fn readU32(buf: []const u8, off: usize) u32 {
        return @as(u32, buf[off]) | (@as(u32, buf[off + 1]) << 8) | (@as(u32, buf[off + 2]) << 16) | (@as(u32, buf[off + 3]) << 24);
    }

    fn readU64(buf: []const u8, off: usize) u64 {
        return @as(u64, buf[off]) | (@as(u64, buf[off + 1]) << 8) | (@as(u64, buf[off + 2]) << 16) | (@as(u64, buf[off + 3]) << 24) |
            (@as(u64, buf[off + 4]) << 32) | (@as(u64, buf[off + 5]) << 40) | (@as(u64, buf[off + 6]) << 48) | (@as(u64, buf[off + 7]) << 56);
    }
};
