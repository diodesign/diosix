// ELF definitions shareable between hypervisor and guests
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

pub const MAGIC = "\x7fELF";

pub const CLASS_64 = 2;
pub const DATA_LSB = 1;
pub const EV_CURRENT = 1;

pub const TYPE_EXEC = 2;
pub const MACHINE_RISCV = 0xF3;

pub const PT_LOAD = 1;

// Offsets within ELF Header (EHDR)
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

// Offsets within Program Header (PHDR)
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
