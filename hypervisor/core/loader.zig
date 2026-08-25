const std = @import("std");
const guest = @import("guest.zig");
const debug = @import("debug.zig");
const sv39x4 = @import("../hardware/native/cpu/riscv64/sv39x4.zig");
const elf_spec = @import("interface").elf;

pub const LoaderError = error{
    InvalidElfHeader,
    UnsupportedElfClass,
    UnsupportedElfData,
    UnsupportedElfMachine,
    InvalidProgramHeader,
    SegmentOutOfBounds,
    SegmentTooLarge,
    TranslationFailed,
};

pub const Loader = struct {
    /// Detect the target architecture of the guest VM from the ELF header
    /// Detect the target architecture of the guest VM from the ELF header
    pub fn detectArch(source: []const u8) !guest.TargetArch {
        if (source.len < elf_spec.MIN_HEADER_LEN) return LoaderError.InvalidElfHeader;
        if (!std.mem.eql(u8, source[0..4], elf_spec.MAGIC)) return LoaderError.InvalidElfHeader;

        const class = source[elf_spec.EI_CLASS];
        const machine = @as(u16, source[elf_spec.EHDR.MACHINE]) | (@as(u16, source[elf_spec.EHDR.MACHINE + 1]) << 8);

        if (machine == elf_spec.MACHINE_RISCV) {
            if (class == elf_spec.CLASS_32) {
                return .riscv32;
            } else if (class == elf_spec.CLASS_64) {
                return .riscv64;
            } else {
                return LoaderError.UnsupportedElfClass;
            }
        } else if (machine == elf_spec.MACHINE_AARCH64) {
            return .aarch64;
        } else if (machine == elf_spec.MACHINE_X86_64) {
            return .x86_64;
        } else {
            return LoaderError.UnsupportedElfMachine;
        }
    }

    /// Load an ELF binary from `source` into `root_vm`'s guest address space.
    /// Returns the guest physical entry point address.
    pub fn load(root_vm: *guest.Guest, source: []const u8) !usize {
        if (source.len < elf_spec.MIN_HEADER_LEN) return LoaderError.InvalidElfHeader;
        if (!std.mem.eql(u8, source[0..4], elf_spec.MAGIC)) return LoaderError.InvalidElfHeader;

        // Data: Little Endian is required
        if (source[elf_spec.EI_DATA] != elf_spec.DATA_LSB) return LoaderError.UnsupportedElfData;

        const class = source[elf_spec.EI_CLASS];
        var entry_point: u64 = 0;
        var ph_off: u64 = 0;
        var ph_num: u16 = 0;
        var ph_size: u16 = 0;

        if (class == elf_spec.CLASS_32) {
            if (source.len < elf_spec.ELF32_EHDR_SIZE) return LoaderError.InvalidElfHeader;
            entry_point = readU32(source, elf_spec.EHDR32.ENTRY);
            ph_off = readU32(source, elf_spec.EHDR32.PHOFF);
            ph_size = readU16(source, elf_spec.EHDR32.PHENTSIZE);
            ph_num = readU16(source, elf_spec.EHDR32.PHNUM);
        } else if (class == elf_spec.CLASS_64) {
            if (source.len < elf_spec.ELF64_EHDR_SIZE) return LoaderError.InvalidElfHeader;
            entry_point = readU64(source, elf_spec.EHDR.ENTRY);
            ph_off = readU64(source, elf_spec.EHDR.PHOFF);
            ph_size = readU16(source, elf_spec.EHDR.PHENTSIZE);
            ph_num = readU16(source, elf_spec.EHDR.PHNUM);
        } else {
            return LoaderError.UnsupportedElfClass;
        }

        // Validate program header table fits within source.
        if (ph_off + @as(u64, ph_num) * @as(u64, ph_size) > source.len) {
            return LoaderError.InvalidProgramHeader;
        }

        // First pass: find the minimum virtual and physical addresses among all loadable segments.
        var min_vaddr: u64 = std.math.maxInt(u64);
        var min_paddr: u64 = std.math.maxInt(u64);
        var i: usize = 0;
        while (i < ph_num) : (i += 1) {
            const off = ph_off + (i * ph_size);
            if (off + ph_size > source.len) return LoaderError.InvalidProgramHeader;
            
            var p_type: u32 = 0;
            var p_vaddr: u64 = 0;
            var p_paddr: u64 = 0;

            if (class == elf_spec.CLASS_32) {
                p_type = readU32(source, off + elf_spec.PHDR32.TYPE);
                p_vaddr = readU32(source, off + elf_spec.PHDR32.VADDR);
                p_paddr = readU32(source, off + elf_spec.PHDR32.PADDR);
            } else {
                p_type = readU32(source, off + elf_spec.PHDR.TYPE);
                p_vaddr = readU64(source, off + elf_spec.PHDR.VADDR);
                p_paddr = readU64(source, off + elf_spec.PHDR.PADDR);
            }

            if (p_type == elf_spec.PT_LOAD) {
                if (p_vaddr < min_vaddr) {
                    min_vaddr = p_vaddr;
                }
                if (p_paddr < min_paddr) {
                    min_paddr = p_paddr;
                }
            }
        }

        if (min_vaddr == std.math.maxInt(u64)) min_vaddr = 0;
        if (min_paddr == std.math.maxInt(u64)) min_paddr = 0;

        // Second pass: load and map the segments into the guest's physical memory.
        i = 0;
        while (i < ph_num) : (i += 1) {
            const off = ph_off + (i * ph_size);
            
            var p_type: u32 = 0;
            var p_offset: u64 = 0;
            var p_vaddr: u64 = 0;
            var p_paddr: u64 = 0;
            var p_filesz: u64 = 0;
            var p_memsz: u64 = 0;

            if (class == elf_spec.CLASS_32) {
                p_type = readU32(source, off + elf_spec.PHDR32.TYPE);
                p_offset = readU32(source, off + elf_spec.PHDR32.OFFSET);
                p_vaddr = readU32(source, off + elf_spec.PHDR32.VADDR);
                p_paddr = readU32(source, off + elf_spec.PHDR32.PADDR);
                p_filesz = readU32(source, off + elf_spec.PHDR32.FILESZ);
                p_memsz = readU32(source, off + elf_spec.PHDR32.MEMSZ);
            } else {
                p_type = readU32(source, off + elf_spec.PHDR.TYPE);
                p_offset = readU64(source, off + elf_spec.PHDR.OFFSET);
                p_vaddr = readU64(source, off + elf_spec.PHDR.VADDR);
                p_paddr = readU64(source, off + elf_spec.PHDR.PADDR);
                p_filesz = readU64(source, off + elf_spec.PHDR.FILESZ);
                p_memsz = readU64(source, off + elf_spec.PHDR.MEMSZ);
            }

            if (p_type == elf_spec.PT_LOAD) {
                // Validate segment data fits within the ELF source.
                if (p_filesz > 0) {
                    if (p_offset > source.len or p_filesz > source.len - p_offset) {
                        return LoaderError.SegmentOutOfBounds;
                    }
                }
                if (p_memsz < p_filesz) {
                    return LoaderError.InvalidProgramHeader;
                }

                // Translate virtual address to guest physical address.
                const gpa = if (root_vm.target_arch == .x86_64)
                    root_vm.space.base_gpa + @as(usize, @intCast(p_paddr))
                else
                    root_vm.space.base_gpa + @as(usize, @intCast(p_vaddr - min_vaddr));

                const hpa = try root_vm.space.translateGPA(gpa);

                // Map and load the segment.
                if (p_filesz > 0) {
                    const segment_data = source[p_offset .. p_offset + p_filesz];
                    @memcpy(@as([*]u8, @ptrFromInt(hpa))[0..p_filesz], segment_data);
                }

                // Map the segment in the guest's address space as RWX.
                const rwx_flags = sv39x4.PTEFlags.read | sv39x4.PTEFlags.write | sv39x4.PTEFlags.execute | sv39x4.PTEFlags.valid | sv39x4.PTEFlags.accessed | sv39x4.PTEFlags.dirty | sv39x4.PTEFlags.user;
                try root_vm.space.map(gpa, hpa, p_memsz, rwx_flags);

                // Zero out any remaining memory in the segment (BSS).
                if (p_memsz > p_filesz) {
                    const bss_gpa = gpa + p_filesz;
                    const bss_hpa = try root_vm.space.translateGPA(bss_gpa);
                    @memset(@as([*]u8, @ptrFromInt(bss_hpa))[0 .. p_memsz - p_filesz], 0);
                }
            }
        }


        // Look up early_top_pgt for non-x86_64 guests to configure the initial page tables.
        if (findSymbol(source, "early_top_pgt")) |pgt_vaddr| {
            if (root_vm.target_arch != .x86_64) {
                const pgt_offset = pgt_vaddr -% min_vaddr;
                root_vm.early_pgt_gpa = root_vm.space.base_gpa + @as(usize, @intCast(pgt_offset));
            }
        }

        if (root_vm.target_arch == .x86_64) {
            return root_vm.space.base_gpa + @as(usize, @intCast(entry_point));
        }

        const entry_offset = if (entry_point < min_vaddr)
            entry_point -% min_paddr
        else
            entry_point -% min_vaddr;
        return root_vm.space.base_gpa + @as(usize, @intCast(entry_offset));
    }

    /// Look up the virtual address of a symbol by name in the ELF's symbol table
    pub fn findSymbol(source: []const u8, name: []const u8) ?u64 {
        if (source.len < elf_spec.MIN_HEADER_LEN) return null;
        if (!std.mem.eql(u8, source[0..4], elf_spec.MAGIC)) return null;

        const class = source[elf_spec.EI_CLASS];
        var sh_off: u64 = 0;
        var sh_num: u16 = 0;
        var sh_size: u16 = 0;

        if (class == elf_spec.CLASS_32) {
            if (source.len < elf_spec.ELF32_EHDR_SIZE) return null;
            sh_off = readU32(source, elf_spec.EHDR32.SHOFF);
            sh_size = readU16(source, elf_spec.EHDR32.SHENTSIZE);
            sh_num = readU16(source, elf_spec.EHDR32.SHNUM);
        } else if (class == elf_spec.CLASS_64) {
            if (source.len < elf_spec.ELF64_EHDR_SIZE) return null;
            sh_off = readU64(source, elf_spec.EHDR.SHOFF);
            sh_size = readU16(source, elf_spec.EHDR.SHENTSIZE);
            sh_num = readU16(source, elf_spec.EHDR.SHNUM);
        } else {
            return null;
        }

        // Validate section header table fits within source
        if (sh_off + @as(u64, sh_num) * @as(u64, sh_size) > source.len) {
            return null;
        }

        // Find the SHT_SYMTAB section
        var symtab_sh_offset: u64 = 0;
        var symtab_sh_size: u64 = 0;
        var symtab_sh_entsize: u64 = 0;
        var symtab_sh_link: u32 = 0;

        var i: usize = 0;
        while (i < sh_num) : (i += 1) {
            const off = sh_off + (i * sh_size);
            const sh_type = readU32(source, off + 4);

            if (sh_type == elf_spec.SHT_SYMTAB) {
                if (class == elf_spec.CLASS_32) {
                    symtab_sh_offset = readU32(source, off + 16);
                    symtab_sh_size = readU32(source, off + 20);
                    symtab_sh_link = readU32(source, off + 32);
                    symtab_sh_entsize = readU32(source, off + 36);
                } else {
                    symtab_sh_offset = readU64(source, off + 24);
                    symtab_sh_size = readU64(source, off + 32);
                    symtab_sh_link = readU32(source, off + 40);
                    symtab_sh_entsize = readU64(source, off + 56);
                }
                break;
            }
        }

        if (symtab_sh_offset == 0 or symtab_sh_size == 0 or symtab_sh_entsize == 0) {
            return null;
        }

        // Find the associated SHT_STRTAB section via symtab_sh_link index
        if (symtab_sh_link >= sh_num) return null;
        const strtab_sh_off = sh_off + (symtab_sh_link * sh_size);
        const strtab_sh_type = readU32(source, strtab_sh_off + 4);
        if (strtab_sh_type != elf_spec.SHT_STRTAB) return null;

        var strtab_offset: u64 = 0;
        var strtab_size: u64 = 0;
        if (class == elf_spec.CLASS_32) {
            strtab_offset = readU32(source, strtab_sh_off + 16);
            strtab_size = readU32(source, strtab_sh_off + 20);
        } else {
            strtab_offset = readU64(source, strtab_sh_off + 24);
            strtab_size = readU64(source, strtab_sh_off + 32);
        }


        if (strtab_offset == 0 or strtab_size == 0) return null;
        if (strtab_offset + strtab_size > source.len) return null;
        if (symtab_sh_offset + symtab_sh_size > source.len) return null;

        // Iterate through symtab entries
        const sym_count = symtab_sh_size / symtab_sh_entsize;
        var sym_idx: usize = 0;
        while (sym_idx < sym_count) : (sym_idx += 1) {
            const sym_off = symtab_sh_offset + (sym_idx * symtab_sh_entsize);
            const st_name = readU32(source, sym_off + 0);
            if (st_name == 0 or st_name >= strtab_size) continue;

            // Get null-terminated string at strtab_offset + st_name bounded by strtab size
            const max_name_len = strtab_size - st_name;
            const sym_name_ptr = source[strtab_offset + st_name .. strtab_offset + st_name + max_name_len];
            const name_len = std.mem.indexOfScalar(u8, sym_name_ptr, 0) orelse continue;
            const sym_name = sym_name_ptr[0..name_len];

            if (std.mem.eql(u8, sym_name, name)) {
                if (class == 1) { // ELF32_Sym
                    return readU32(source, sym_off + 4); // st_value
                } else { // ELF64_Sym
                    return readU64(source, sym_off + 8); // st_value
                }
            }
        }

        return null;
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
