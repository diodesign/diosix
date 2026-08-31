// ELF definitions shareable between hypervisor and guests
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const MAGIC = "\x7fELF";

pub const MIN_HEADER_LEN: usize = 24;
pub const ELF32_EHDR_SIZE: usize = 52;
pub const ELF64_EHDR_SIZE: usize = 64;
pub const ELF32_PHDR_SIZE: usize = 32;
pub const ELF64_PHDR_SIZE: usize = 56;

// Identification (e_ident) byte indices
pub const EI_MAG0 = 0;
pub const EI_MAG1 = 1;
pub const EI_MAG2 = 2;
pub const EI_MAG3 = 3;
pub const EI_CLASS = 4;
pub const EI_DATA = 5;
pub const EI_VERSION = 6;
pub const EI_OSABI = 7;
pub const EI_ABIVERSION = 8;
pub const EI_PAD = 9;
pub const EI_NIDENT = 16;

// File classes (e_ident[EI_CLASS])
pub const CLASS_32: u8 = 1;
pub const CLASS_64: u8 = 2;

// Data encodings (e_ident[EI_DATA])
pub const DATA_LSB: u8 = 1; // 2's complement, little endian
pub const DATA_MSB: u8 = 2; // 2's complement, big endian

// Version
pub const EV_CURRENT: u32 = 1;

// Object file types (e_type)
pub const TYPE_NONE: u16 = 0;
pub const TYPE_REL: u16 = 1;
pub const TYPE_EXEC: u16 = 2;
pub const TYPE_DYN: u16 = 3;
pub const TYPE_CORE: u16 = 4;

// Target machine architectures (e_machine)
pub const MACHINE_NONE: u16 = 0;
pub const MACHINE_X86_64: u16 = 62; // AMD x86-64 / EM_X86_64
pub const MACHINE_AARCH64: u16 = 183; // ARM 64-bit / EM_AARCH64
pub const MACHINE_RISCV: u16 = 0xF3; // RISC-V / EM_RISCV (243)

// Segment types (p_type)
pub const PT_NULL: u32 = 0;
pub const PT_LOAD: u32 = 1;
pub const PT_DYNAMIC: u32 = 2;
pub const PT_INTERP: u32 = 3;
pub const PT_NOTE: u32 = 4;
pub const PT_SHLIB: u32 = 5;
pub const PT_PHDR: u32 = 6;
pub const PT_TLS: u32 = 7;

// Segment permission flags (p_flags)
pub const PF_X: u32 = 1 << 0; // Execute
pub const PF_W: u32 = 1 << 1; // Write
pub const PF_R: u32 = 1 << 2; // Read

// Section header types (sh_type)
pub const SHT_NULL: u32 = 0;
pub const SHT_PROGBITS: u32 = 1;
pub const SHT_SYMTAB: u32 = 2;
pub const SHT_STRTAB: u32 = 3;
pub const SHT_RELA: u32 = 4;
pub const SHT_HASH: u32 = 5;
pub const SHT_DYNAMIC: u32 = 6;
pub const SHT_NOTE: u32 = 7;
pub const SHT_NOBITS: u32 = 8;
pub const SHT_REL: u32 = 9;

// Offsets within 64-bit ELF Header (EHDR64)
pub const EHDR = struct {
    pub const IDENT = 0;
    pub const TYPE = 16;
    pub const MACHINE = 18;
    pub const VERSION = 20;
    pub const ENTRY = 24;
    pub const PHOFF = 32;
    pub const SHOFF = 40;
    pub const FLAGS = 48;
    pub const EHSIZE = 52;
    pub const PHENTSIZE = 54;
    pub const PHNUM = 56;
    pub const SHENTSIZE = 58;
    pub const SHNUM = 60;
    pub const SHSTRNDX = 62;
};

// Offsets within 32-bit ELF Header (EHDR32)
pub const EHDR32 = struct {
    pub const IDENT = 0;
    pub const TYPE = 16;
    pub const MACHINE = 18;
    pub const VERSION = 20;
    pub const ENTRY = 24;
    pub const PHOFF = 28;
    pub const SHOFF = 32;
    pub const FLAGS = 36;
    pub const EHSIZE = 40;
    pub const PHENTSIZE = 42;
    pub const PHNUM = 44;
    pub const SHENTSIZE = 46;
    pub const SHNUM = 48;
    pub const SHSTRNDX = 50;
};

// Offsets within 64-bit Program Header (PHDR64)
pub const PHDR = struct {
    pub const TYPE = 0;
    pub const FLAGS = 4;
    pub const OFFSET = 8;
    pub const VADDR = 16;
    pub const PADDR = 24;
    pub const FILESZ = 32;
    pub const MEMSZ = 40;
    pub const ALIGN = 48;
};

// Offsets within 32-bit Program Header (PHDR32)
pub const PHDR32 = struct {
    pub const TYPE = 0;
    pub const OFFSET = 4;
    pub const VADDR = 8;
    pub const PADDR = 12;
    pub const FILESZ = 16;
    pub const MEMSZ = 20;
    pub const FLAGS = 24;
    pub const ALIGN = 28;
};

test "ELF specification constants and header layout validation" {
    const testing = std.testing;

    try testing.expectEqualStrings("\x7fELF", MAGIC);
    try testing.expectEqual(@as(usize, 52), ELF32_EHDR_SIZE);
    try testing.expectEqual(@as(usize, 64), ELF64_EHDR_SIZE);
    try testing.expectEqual(@as(usize, 32), ELF32_PHDR_SIZE);
    try testing.expectEqual(@as(usize, 56), ELF64_PHDR_SIZE);

    // Verify machine identifiers
    try testing.expectEqual(@as(u16, 243), MACHINE_RISCV);
    try testing.expectEqual(@as(u16, 183), MACHINE_AARCH64);
    try testing.expectEqual(@as(u16, 62), MACHINE_X86_64);
}
