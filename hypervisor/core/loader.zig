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
                if (class == elf_spec.CLASS_32) { // ELF32_Sym
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

test "ELF header validation and arch detection" {
    const testing = std.testing;

    // Test 1: Truncated header
    const truncated = [_]u8{ 0x7f, 'E', 'L' };
    try testing.expectError(error.InvalidElfHeader, Loader.detectArch(&truncated));


    // Test 2: Invalid magic
    var bad_magic: [64]u8 = std.mem.zeroes([64]u8);
    @memcpy(bad_magic[0..4], "NOPE");
    try testing.expectError(error.InvalidElfHeader, Loader.detectArch(&bad_magic));


    // Helper to create a valid 64-bit ELF header
    var rv64_hdr: [64]u8 = std.mem.zeroes([64]u8);
    @memcpy(rv64_hdr[0..4], elf_spec.MAGIC);
    rv64_hdr[elf_spec.EI_CLASS] = elf_spec.CLASS_64;
    rv64_hdr[elf_spec.EI_DATA] = elf_spec.DATA_LSB;
    rv64_hdr[elf_spec.EI_VERSION] = 1;
    // e_type = ET_EXEC (2)
    rv64_hdr[elf_spec.EHDR.TYPE] = elf_spec.TYPE_EXEC;
    // e_machine = EM_RISCV (243 = 0xF3)
    rv64_hdr[elf_spec.EHDR.MACHINE] = @truncate(elf_spec.MACHINE_RISCV);
    rv64_hdr[elf_spec.EHDR.MACHINE + 1] = @truncate(elf_spec.MACHINE_RISCV >> 8);
    // e_version = 1
    rv64_hdr[elf_spec.EHDR.VERSION] = 1;
    // e_ehsize = 64
    rv64_hdr[elf_spec.EHDR.EHSIZE] = elf_spec.ELF64_EHDR_SIZE;

    try testing.expectEqual(guest.TargetArch.riscv64, try Loader.detectArch(&rv64_hdr));

    // Test 3: RV32 ELF Header
    var rv32_hdr: [52]u8 = std.mem.zeroes([52]u8);
    @memcpy(rv32_hdr[0..4], elf_spec.MAGIC);
    rv32_hdr[elf_spec.EI_CLASS] = elf_spec.CLASS_32;
    rv32_hdr[elf_spec.EI_DATA] = elf_spec.DATA_LSB;
    rv32_hdr[elf_spec.EI_VERSION] = 1;
    rv32_hdr[elf_spec.EHDR32.TYPE] = elf_spec.TYPE_EXEC;
    rv32_hdr[elf_spec.EHDR32.MACHINE] = @truncate(elf_spec.MACHINE_RISCV);
    rv32_hdr[elf_spec.EHDR32.MACHINE + 1] = @truncate(elf_spec.MACHINE_RISCV >> 8);
    rv32_hdr[elf_spec.EHDR32.VERSION] = 1;
    rv32_hdr[elf_spec.EHDR32.EHSIZE] = elf_spec.ELF32_EHDR_SIZE;

    try testing.expectEqual(guest.TargetArch.riscv32, try Loader.detectArch(&rv32_hdr));

    // Test 4: AArch64 ELF Header
    var aarch64_hdr = rv64_hdr;
    aarch64_hdr[elf_spec.EHDR.MACHINE] = @truncate(elf_spec.MACHINE_AARCH64);
    aarch64_hdr[elf_spec.EHDR.MACHINE + 1] = @truncate(elf_spec.MACHINE_AARCH64 >> 8);
    try testing.expectEqual(guest.TargetArch.aarch64, try Loader.detectArch(&aarch64_hdr));

    // Test 5: x86_64 ELF Header
    var x86_hdr = rv64_hdr;
    x86_hdr[elf_spec.EHDR.MACHINE] = @truncate(elf_spec.MACHINE_X86_64);
    x86_hdr[elf_spec.EHDR.MACHINE + 1] = @truncate(elf_spec.MACHINE_X86_64 >> 8);
    try testing.expectEqual(guest.TargetArch.x86_64, try Loader.detectArch(&x86_hdr));

    // Test 6: Unsupported machine architecture
    var bad_arch_hdr = rv64_hdr;
    bad_arch_hdr[elf_spec.EHDR.MACHINE] = 0x99;
    bad_arch_hdr[elf_spec.EHDR.MACHINE + 1] = 0x00;
    try testing.expectError(error.UnsupportedElfMachine, Loader.detectArch(&bad_arch_hdr));
}


test "ELF symbol resolution" {
    const testing = std.testing;

    // Reject non-ELF buffer
    const non_elf = "Hello world";
    try testing.expect(Loader.findSymbol(non_elf, "main") == null);

    // Build a mock 64-bit ELF image with 1 symtab and 1 strtab
    // Layout:
    // [0..64]: ELF Header
    // [64..128]: Section Header 0 (Null)
    // [128..192]: Section Header 1 (SHT_SYMTAB)
    // [192..256]: Section Header 2 (SHT_STRTAB)
    // [256..280]: Symtab entry 0 (null sym)
    // [280..304]: Symtab entry 1 (symbol "start_kernel" @ 0x80200000)
    // [304..330]: Strtab ("\x00start_kernel\x00")
    var elf_buf: [512]u8 = std.mem.zeroes([512]u8);

    @memcpy(elf_buf[0..4], elf_spec.MAGIC);
    elf_buf[elf_spec.EI_CLASS] = elf_spec.CLASS_64;
    elf_buf[elf_spec.EI_DATA] = elf_spec.DATA_LSB;
    elf_buf[elf_spec.EI_VERSION] = 1;
    elf_buf[elf_spec.EHDR.TYPE] = elf_spec.TYPE_EXEC;
    elf_buf[elf_spec.EHDR.MACHINE] = @truncate(elf_spec.MACHINE_RISCV);
    elf_buf[elf_spec.EHDR.MACHINE + 1] = @truncate(elf_spec.MACHINE_RISCV >> 8);
    elf_buf[elf_spec.EHDR.VERSION] = 1;
    elf_buf[elf_spec.EHDR.EHSIZE] = 64;

    // Section header table offset = 64, shentsize = 64, shnum = 3
    std.mem.writeInt(u64, elf_buf[elf_spec.EHDR.SHOFF..][0..8], 64, .little);
    std.mem.writeInt(u16, elf_buf[elf_spec.EHDR.SHENTSIZE..][0..2], 64, .little);
    std.mem.writeInt(u16, elf_buf[elf_spec.EHDR.SHNUM..][0..2], 3, .little);

    // Section 1: SHT_SYMTAB @ offset 128
    const sh1 = 128;
    std.mem.writeInt(u32, elf_buf[sh1 + 4 ..][0..4], elf_spec.SHT_SYMTAB, .little); // sh_type
    std.mem.writeInt(u64, elf_buf[sh1 + 24 ..][0..8], 256, .little); // sh_offset (symtab data)
    std.mem.writeInt(u64, elf_buf[sh1 + 32 ..][0..8], 48, .little); // sh_size (2 * 24 bytes)
    std.mem.writeInt(u32, elf_buf[sh1 + 40 ..][0..4], 2, .little); // sh_link (index of strtab section = 2)
    std.mem.writeInt(u64, elf_buf[sh1 + 56 ..][0..8], 24, .little); // sh_entsize (ELF64_Sym = 24 bytes)

    // Section 2: SHT_STRTAB @ offset 192
    const sh2 = 192;
    std.mem.writeInt(u32, elf_buf[sh2 + 4 ..][0..4], elf_spec.SHT_STRTAB, .little); // sh_type
    std.mem.writeInt(u64, elf_buf[sh2 + 24 ..][0..8], 304, .little); // sh_offset (strtab data)
    std.mem.writeInt(u64, elf_buf[sh2 + 32 ..][0..8], 32, .little); // sh_size

    // Symtab entry 1 @ offset 280 (st_name = 1, st_value = 0x80200000)
    std.mem.writeInt(u32, elf_buf[280..284], 1, .little); // st_name = 1
    std.mem.writeInt(u64, elf_buf[288..296], 0x80200000, .little); // st_value = 0x80200000

    // Strtab @ offset 304: "\x00start_kernel\x00"
    const strtab_data = "\x00start_kernel\x00";
    @memcpy(elf_buf[304 .. 304 + strtab_data.len], strtab_data);

    // Look up existing symbol
    const sym_addr = Loader.findSymbol(&elf_buf, "start_kernel");
    try testing.expect(sym_addr != null);
    try testing.expectEqual(@as(u64, 0x80200000), sym_addr.?);

    // Look up non-existent symbol
    try testing.expect(Loader.findSymbol(&elf_buf, "nonexistent") == null);
}

