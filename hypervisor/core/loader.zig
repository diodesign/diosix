const std = @import("std");
const guest = @import("guest.zig");
const vm = @import("vm.zig");
const debug = @import("debug.zig");
const physmem = @import("physmem.zig");
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
    pub fn detectArch(source: []const u8) !guest.TargetArch {
        if (source.len < elf_spec.MIN_HEADER_LEN) return LoaderError.InvalidElfHeader;
        if (!std.mem.eql(u8, source[0..4], elf_spec.MAGIC)) return LoaderError.InvalidElfHeader;

        const class = source[elf_spec.EI_CLASS];
        const machine = readU16(source, elf_spec.EHDR.MACHINE);

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

    /// Detect the target architecture of the guest VM from the ELF header in another guest's memory
    pub fn detectArchFromGuest(source_space: *const vm.GuestSpace, elf_gpa: usize, elf_size: usize) !guest.TargetArch {
        if (elf_size < elf_spec.MIN_HEADER_LEN) return LoaderError.InvalidElfHeader;
        var header_buf: [elf_spec.MIN_HEADER_LEN]u8 = undefined;
        source_space.copyFromGuest(&header_buf, elf_gpa) catch return LoaderError.TranslationFailed;
        return detectArch(&header_buf);
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
        const total_ph_size = std.math.mul(u64, ph_num, ph_size) catch return LoaderError.InvalidProgramHeader;
        const ph_end = std.math.add(u64, ph_off, total_ph_size) catch return LoaderError.InvalidProgramHeader;
        if (ph_end > source.len) {
            return LoaderError.InvalidProgramHeader;
        }

        // First pass: find the minimum virtual and physical addresses among all loadable segments.
        var min_vaddr: u64 = std.math.maxInt(u64);
        var min_paddr: u64 = std.math.maxInt(u64);
        var i: usize = 0;
        while (i < ph_num) : (i += 1) {
            const i_ph_size = std.math.mul(u64, i, ph_size) catch return LoaderError.InvalidProgramHeader;
            const off = std.math.add(u64, ph_off, i_ph_size) catch return LoaderError.InvalidProgramHeader;
            const off_end = std.math.add(u64, off, ph_size) catch return LoaderError.InvalidProgramHeader;
            if (off_end > source.len) return LoaderError.InvalidProgramHeader;

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
            const i_ph_size = std.math.mul(u64, i, ph_size) catch return LoaderError.InvalidProgramHeader;
            const off = std.math.add(u64, ph_off, i_ph_size) catch return LoaderError.InvalidProgramHeader;

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
                const gpa_offset = if (root_vm.target_arch == .x86_64)
                    std.math.cast(usize, p_paddr) orelse return LoaderError.InvalidProgramHeader
                else blk: {
                    if (p_vaddr < min_vaddr) return LoaderError.InvalidProgramHeader;
                    break :blk std.math.cast(usize, p_vaddr - min_vaddr) orelse return LoaderError.InvalidProgramHeader;
                };
                const gpa = std.math.add(usize, root_vm.space.base_gpa, gpa_offset) catch return LoaderError.SegmentOutOfBounds;

                // Ensure physical memory is mapped in the guest's address space for this segment
                const page_offset = gpa % physmem.PageSize;
                const aligned_gpa = gpa - page_offset;
                const mem_sz_usize = std.math.cast(usize, p_memsz) orelse return LoaderError.SegmentOutOfBounds;
                const total_size = std.math.add(usize, mem_sz_usize, page_offset) catch return LoaderError.SegmentOutOfBounds;
                if (total_size > std.math.maxInt(usize) - physmem.PageSize) return LoaderError.SegmentOutOfBounds;
                const aligned_size = std.mem.alignForward(usize, total_size, physmem.PageSize);
                const rwx_flags = sv39x4.PTEFlags.read | sv39x4.PTEFlags.write | sv39x4.PTEFlags.execute | sv39x4.PTEFlags.valid | sv39x4.PTEFlags.accessed | sv39x4.PTEFlags.dirty | sv39x4.PTEFlags.user;

                var map_offset: usize = 0;
                while (map_offset < aligned_size) : (map_offset += physmem.PageSize) {
                    const page_gpa = std.math.add(usize, aligned_gpa, map_offset) catch return LoaderError.SegmentOutOfBounds;
                    if (root_vm.space.translateGPA(page_gpa) catch null) |_| {
                        continue;
                    }
                    const new_page_hpa = try physmem.allocPage();
                    @memset(@as([*]u8, @ptrFromInt(new_page_hpa))[0..physmem.PageSize], 0);
                    try root_vm.space.map(page_gpa, new_page_hpa, physmem.PageSize, rwx_flags);
                    physmem.decrementPageRef(new_page_hpa);
                }

                // Copy segment file data into guest physical address space
                var copied: usize = 0;
                const file_sz_usize = std.math.cast(usize, p_filesz) orelse return LoaderError.SegmentOutOfBounds;
                const file_off_usize = std.math.cast(usize, p_offset) orelse return LoaderError.SegmentOutOfBounds;
                while (copied < file_sz_usize) {
                    const cur_gpa = std.math.add(usize, gpa, copied) catch return LoaderError.SegmentOutOfBounds;
                    const cur_page_offset = cur_gpa % physmem.PageSize;
                    const chunk = @min(file_sz_usize - copied, physmem.PageSize - cur_page_offset);
                    const cur_hpa = try root_vm.space.translateGPA(cur_gpa);
                    if (physmem.isHypervisorMemory(cur_hpa, chunk)) return LoaderError.TranslationFailed;
                    const src_start = std.math.add(usize, file_off_usize, copied) catch return LoaderError.SegmentOutOfBounds;
                    @memcpy(@as([*]u8, @ptrFromInt(cur_hpa))[0..chunk], source[src_start .. src_start + chunk]);
                    copied += chunk;
                }

                // Zero any remaining memory in the segment (BSS)
                var zeroed: usize = file_sz_usize;
                while (zeroed < mem_sz_usize) {
                    const cur_gpa = std.math.add(usize, gpa, zeroed) catch return LoaderError.SegmentOutOfBounds;
                    const cur_page_offset = cur_gpa % physmem.PageSize;
                    const chunk = @min(mem_sz_usize - zeroed, physmem.PageSize - cur_page_offset);
                    const cur_hpa = try root_vm.space.translateGPA(cur_gpa);
                    if (physmem.isHypervisorMemory(cur_hpa, chunk)) return LoaderError.TranslationFailed;
                    @memset(@as([*]u8, @ptrFromInt(cur_hpa))[0..chunk], 0);
                    zeroed += chunk;
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

    /// Load an ELF binary directly from another guest's address space (`source_space`)
    /// into `child_vm`'s guest address space.
    /// Returns the guest physical entry point address.
    /// This streams segment data using a fixed-size buffer, avoiding unbounded hypervisor
    /// memory allocations and seamlessly handling discontiguous guest physical pages.
    pub fn loadFromGuest(child_vm: *guest.Guest, source_space: *const vm.GuestSpace, elf_gpa: usize, elf_size: usize) !usize {
        if (elf_size < elf_spec.MIN_HEADER_LEN) return LoaderError.InvalidElfHeader;

        var hdr_buf: [64]u8 = undefined;
        source_space.copyFromGuest(hdr_buf[0..elf_spec.MIN_HEADER_LEN], elf_gpa) catch return LoaderError.TranslationFailed;
        if (!std.mem.eql(u8, hdr_buf[0..4], elf_spec.MAGIC)) return LoaderError.InvalidElfHeader;
        if (hdr_buf[elf_spec.EI_DATA] != elf_spec.DATA_LSB) return LoaderError.UnsupportedElfData;

        const class = hdr_buf[elf_spec.EI_CLASS];
        var entry_point: u64 = 0;
        var ph_off: u64 = 0;
        var ph_num: u16 = 0;
        var ph_size: u16 = 0;

        if (class == elf_spec.CLASS_32) {
            if (elf_size < elf_spec.ELF32_EHDR_SIZE) return LoaderError.InvalidElfHeader;
            source_space.copyFromGuest(hdr_buf[0..elf_spec.ELF32_EHDR_SIZE], elf_gpa) catch return LoaderError.TranslationFailed;
            entry_point = readU32(&hdr_buf, elf_spec.EHDR32.ENTRY);
            ph_off = readU32(&hdr_buf, elf_spec.EHDR32.PHOFF);
            ph_size = readU16(&hdr_buf, elf_spec.EHDR32.PHENTSIZE);
            ph_num = readU16(&hdr_buf, elf_spec.EHDR32.PHNUM);
        } else if (class == elf_spec.CLASS_64) {
            if (elf_size < elf_spec.ELF64_EHDR_SIZE) return LoaderError.InvalidElfHeader;
            source_space.copyFromGuest(hdr_buf[0..elf_spec.ELF64_EHDR_SIZE], elf_gpa) catch return LoaderError.TranslationFailed;
            entry_point = readU64(&hdr_buf, elf_spec.EHDR.ENTRY);
            ph_off = readU64(&hdr_buf, elf_spec.EHDR.PHOFF);
            ph_size = readU16(&hdr_buf, elf_spec.EHDR.PHENTSIZE);
            ph_num = readU16(&hdr_buf, elf_spec.EHDR.PHNUM);
        } else {
            return LoaderError.UnsupportedElfClass;
        }

        const total_ph_size = std.math.mul(u64, ph_num, ph_size) catch return LoaderError.InvalidProgramHeader;
        const ph_end = std.math.add(u64, ph_off, total_ph_size) catch return LoaderError.InvalidProgramHeader;
        if (ph_end > elf_size) return LoaderError.InvalidProgramHeader;

        // First pass: find minimum virtual and physical addresses
        var min_vaddr: u64 = std.math.maxInt(u64);
        var min_paddr: u64 = std.math.maxInt(u64);
        var ph_buf: [64]u8 = undefined;
        var i: usize = 0;
        while (i < ph_num) : (i += 1) {
            const i_ph_size = std.math.mul(u64, i, ph_size) catch return LoaderError.InvalidProgramHeader;
            const off = std.math.add(u64, ph_off, i_ph_size) catch return LoaderError.InvalidProgramHeader;
            const off_end = std.math.add(u64, off, ph_size) catch return LoaderError.InvalidProgramHeader;
            if (off_end > elf_size) return LoaderError.InvalidProgramHeader;
            if (ph_size > ph_buf.len) return LoaderError.InvalidProgramHeader;

            const off_usize = std.math.cast(usize, off) orelse return LoaderError.InvalidProgramHeader;
            const src_ph_gpa = std.math.add(usize, elf_gpa, off_usize) catch return LoaderError.SegmentOutOfBounds;
            source_space.copyFromGuest(ph_buf[0..ph_size], src_ph_gpa) catch return LoaderError.TranslationFailed;

            var p_type: u32 = 0;
            var p_vaddr: u64 = 0;
            var p_paddr: u64 = 0;

            if (class == elf_spec.CLASS_32) {
                p_type = readU32(&ph_buf, elf_spec.PHDR32.TYPE);
                p_vaddr = readU32(&ph_buf, elf_spec.PHDR32.VADDR);
                p_paddr = readU32(&ph_buf, elf_spec.PHDR32.PADDR);
            } else {
                p_type = readU32(&ph_buf, elf_spec.PHDR.TYPE);
                p_vaddr = readU64(&ph_buf, elf_spec.PHDR.VADDR);
                p_paddr = readU64(&ph_buf, elf_spec.PHDR.PADDR);
            }

            if (p_type == elf_spec.PT_LOAD) {
                if (p_vaddr < min_vaddr) min_vaddr = p_vaddr;
                if (p_paddr < min_paddr) min_paddr = p_paddr;
            }
        }

        if (min_vaddr == std.math.maxInt(u64)) min_vaddr = 0;
        if (min_paddr == std.math.maxInt(u64)) min_paddr = 0;

        // Second pass: load and map segments into child guest address space
        i = 0;
        while (i < ph_num) : (i += 1) {
            const i_ph_size = std.math.mul(u64, i, ph_size) catch return LoaderError.InvalidProgramHeader;
            const off = std.math.add(u64, ph_off, i_ph_size) catch return LoaderError.InvalidProgramHeader;
            const off_usize = std.math.cast(usize, off) orelse return LoaderError.InvalidProgramHeader;
            const src_ph_gpa = std.math.add(usize, elf_gpa, off_usize) catch return LoaderError.SegmentOutOfBounds;
            source_space.copyFromGuest(ph_buf[0..ph_size], src_ph_gpa) catch return LoaderError.TranslationFailed;

            var p_type: u32 = 0;
            var p_offset: u64 = 0;
            var p_vaddr: u64 = 0;
            var p_paddr: u64 = 0;
            var p_filesz: u64 = 0;
            var p_memsz: u64 = 0;

            if (class == elf_spec.CLASS_32) {
                p_type = readU32(&ph_buf, elf_spec.PHDR32.TYPE);
                p_offset = readU32(&ph_buf, elf_spec.PHDR32.OFFSET);
                p_vaddr = readU32(&ph_buf, elf_spec.PHDR32.VADDR);
                p_paddr = readU32(&ph_buf, elf_spec.PHDR32.PADDR);
                p_filesz = readU32(&ph_buf, elf_spec.PHDR32.FILESZ);
                p_memsz = readU32(&ph_buf, elf_spec.PHDR32.MEMSZ);
            } else {
                p_type = readU32(&ph_buf, elf_spec.PHDR.TYPE);
                p_offset = readU64(&ph_buf, elf_spec.PHDR.OFFSET);
                p_vaddr = readU64(&ph_buf, elf_spec.PHDR.VADDR);
                p_paddr = readU64(&ph_buf, elf_spec.PHDR.PADDR);
                p_filesz = readU64(&ph_buf, elf_spec.PHDR.FILESZ);
                p_memsz = readU64(&ph_buf, elf_spec.PHDR.MEMSZ);
            }

            if (p_type == elf_spec.PT_LOAD) {
                if (p_filesz > 0) {
                    if (p_offset > elf_size or p_filesz > elf_size - p_offset) {
                        return LoaderError.SegmentOutOfBounds;
                    }
                }
                if (p_memsz < p_filesz) {
                    return LoaderError.InvalidProgramHeader;
                }

                const gpa_offset = if (child_vm.target_arch == .x86_64)
                    std.math.cast(usize, p_paddr) orelse return LoaderError.InvalidProgramHeader
                else blk: {
                    if (p_vaddr < min_vaddr) return LoaderError.InvalidProgramHeader;
                    break :blk std.math.cast(usize, p_vaddr - min_vaddr) orelse return LoaderError.InvalidProgramHeader;
                };
                const gpa = std.math.add(usize, child_vm.space.base_gpa, gpa_offset) catch return LoaderError.SegmentOutOfBounds;

                const page_offset = gpa % physmem.PageSize;
                const aligned_gpa = gpa - page_offset;
                const mem_sz_usize = std.math.cast(usize, p_memsz) orelse return LoaderError.SegmentOutOfBounds;
                const total_size = std.math.add(usize, mem_sz_usize, page_offset) catch return LoaderError.SegmentOutOfBounds;
                if (total_size > std.math.maxInt(usize) - physmem.PageSize) return LoaderError.SegmentOutOfBounds;
                const aligned_size = std.mem.alignForward(usize, total_size, physmem.PageSize);
                const rwx_flags = sv39x4.PTEFlags.read | sv39x4.PTEFlags.write | sv39x4.PTEFlags.execute | sv39x4.PTEFlags.valid | sv39x4.PTEFlags.accessed | sv39x4.PTEFlags.dirty | sv39x4.PTEFlags.user;

                var map_offset: usize = 0;
                while (map_offset < aligned_size) : (map_offset += physmem.PageSize) {
                    const page_gpa = std.math.add(usize, aligned_gpa, map_offset) catch return LoaderError.SegmentOutOfBounds;
                    if (child_vm.space.translateGPA(page_gpa) catch null) |_| {
                        continue;
                    }
                    const new_page_hpa = try physmem.allocPage();
                    @memset(@as([*]u8, @ptrFromInt(new_page_hpa))[0..physmem.PageSize], 0);
                    try child_vm.space.map(page_gpa, new_page_hpa, physmem.PageSize, rwx_flags);
                    physmem.decrementPageRef(new_page_hpa);
                }

                // Stream segment file data from source_space into child_vm.space using bounce buffer
                var stream_buf: [physmem.PageSize]u8 = undefined;
                var copied: usize = 0;
                const file_sz_usize = std.math.cast(usize, p_filesz) orelse return LoaderError.SegmentOutOfBounds;
                const file_off_usize = std.math.cast(usize, p_offset) orelse return LoaderError.SegmentOutOfBounds;
                while (copied < file_sz_usize) {
                    const chunk = @min(file_sz_usize - copied, stream_buf.len);
                    const off_copied = std.math.add(usize, file_off_usize, copied) catch return LoaderError.SegmentOutOfBounds;
                    const src_addr = std.math.add(usize, elf_gpa, off_copied) catch return LoaderError.SegmentOutOfBounds;
                    const dst_addr = std.math.add(usize, gpa, copied) catch return LoaderError.SegmentOutOfBounds;
                    source_space.copyFromGuest(stream_buf[0..chunk], src_addr) catch return LoaderError.TranslationFailed;
                    child_vm.space.copyToGuest(dst_addr, stream_buf[0..chunk]) catch return LoaderError.TranslationFailed;
                    copied += chunk;
                }

                // Zero any remaining memory in the segment (BSS)
                if (mem_sz_usize > file_sz_usize) {
                    @memset(&stream_buf, 0);
                    var zeroed: usize = file_sz_usize;
                    while (zeroed < mem_sz_usize) {
                        const chunk = @min(mem_sz_usize - zeroed, stream_buf.len);
                        const dst_addr = std.math.add(usize, gpa, zeroed) catch return LoaderError.SegmentOutOfBounds;
                        child_vm.space.copyToGuest(dst_addr, stream_buf[0..chunk]) catch return LoaderError.TranslationFailed;
                        zeroed += chunk;
                    }
                }
            }
        }

        if (child_vm.target_arch == .x86_64) {
            const ep = std.math.cast(usize, entry_point) orelse return LoaderError.InvalidElfHeader;
            return std.math.add(usize, child_vm.space.base_gpa, ep) catch return LoaderError.InvalidElfHeader;
        }

        const entry_offset = if (entry_point < min_vaddr) blk: {
            if (entry_point < min_paddr) return LoaderError.InvalidElfHeader;
            break :blk entry_point - min_paddr;
        } else (entry_point - min_vaddr);

        const ep_usize = std.math.cast(usize, entry_offset) orelse return LoaderError.InvalidElfHeader;
        return std.math.add(usize, child_vm.space.base_gpa, ep_usize) catch return LoaderError.InvalidElfHeader;
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
        const total_sh_size = std.math.mul(u64, sh_num, sh_size) catch return null;
        const sh_end = std.math.add(u64, sh_off, total_sh_size) catch return null;
        if (sh_end > source.len) {
            return null;
        }

        // Find the SHT_SYMTAB section
        var symtab_sh_offset: u64 = 0;
        var symtab_sh_size: u64 = 0;
        var symtab_sh_entsize: u64 = 0;
        var symtab_sh_link: u32 = 0;

        var i: usize = 0;
        while (i < sh_num) : (i += 1) {
            const i_sh_size = std.math.mul(u64, i, sh_size) catch break;
            const off = std.math.add(u64, sh_off, i_sh_size) catch break;
            const sh_type = if (class == elf_spec.CLASS_32)
                readU32(source, off + elf_spec.SHDR32.TYPE)
            else
                readU32(source, off + elf_spec.SHDR.TYPE);

            if (sh_type == elf_spec.SHT_SYMTAB) {
                if (class == elf_spec.CLASS_32) {
                    symtab_sh_offset = readU32(source, off + elf_spec.SHDR32.OFFSET);
                    symtab_sh_size = readU32(source, off + elf_spec.SHDR32.SIZE);
                    symtab_sh_link = readU32(source, off + elf_spec.SHDR32.LINK);
                    symtab_sh_entsize = readU32(source, off + elf_spec.SHDR32.ENTSIZE);
                } else {
                    symtab_sh_offset = readU64(source, off + elf_spec.SHDR.OFFSET);
                    symtab_sh_size = readU64(source, off + elf_spec.SHDR.SIZE);
                    symtab_sh_link = readU32(source, off + elf_spec.SHDR.LINK);
                    symtab_sh_entsize = readU64(source, off + elf_spec.SHDR.ENTSIZE);
                }
                break;
            }
        }

        if (symtab_sh_offset == 0 or symtab_sh_size == 0 or symtab_sh_entsize == 0) {
            return null;
        }

        // Find the associated SHT_STRTAB section via symtab_sh_link index
        if (symtab_sh_link >= sh_num) return null;
        const link_sh_size = std.math.mul(u64, symtab_sh_link, sh_size) catch return null;
        const strtab_sh_off = std.math.add(u64, sh_off, link_sh_size) catch return null;
        const strtab_sh_type = if (class == elf_spec.CLASS_32)
            readU32(source, strtab_sh_off + elf_spec.SHDR32.TYPE)
        else
            readU32(source, strtab_sh_off + elf_spec.SHDR.TYPE);
        if (strtab_sh_type != elf_spec.SHT_STRTAB) return null;

        var strtab_offset: u64 = 0;
        var strtab_size: u64 = 0;
        if (class == elf_spec.CLASS_32) {
            strtab_offset = readU32(source, strtab_sh_off + elf_spec.SHDR32.OFFSET);
            strtab_size = readU32(source, strtab_sh_off + elf_spec.SHDR32.SIZE);
        } else {
            strtab_offset = readU64(source, strtab_sh_off + elf_spec.SHDR.OFFSET);
            strtab_size = readU64(source, strtab_sh_off + elf_spec.SHDR.SIZE);
        }

        if (strtab_offset == 0 or strtab_size == 0) return null;
        const strtab_end = std.math.add(u64, strtab_offset, strtab_size) catch return null;
        if (strtab_end > source.len) return null;
        const symtab_end = std.math.add(u64, symtab_sh_offset, symtab_sh_size) catch return null;
        if (symtab_end > source.len) return null;

        // Iterate through symtab entries
        const sym_count = symtab_sh_size / symtab_sh_entsize;
        var sym_idx: usize = 0;
        while (sym_idx < sym_count) : (sym_idx += 1) {
            const sym_off_idx = std.math.mul(u64, sym_idx, symtab_sh_entsize) catch break;
            const sym_off = std.math.add(u64, symtab_sh_offset, sym_off_idx) catch break;
            const st_name = if (class == elf_spec.CLASS_32)
                readU32(source, sym_off + elf_spec.SYM32.NAME)
            else
                readU32(source, sym_off + elf_spec.SYM.NAME);
            if (st_name == 0 or st_name >= strtab_size) continue;

            // Get null-terminated string at strtab_offset + st_name bounded by strtab size
            const max_name_len = strtab_size - st_name;
            const strtab_name_start = std.math.add(u64, strtab_offset, st_name) catch continue;
            const strtab_name_end = std.math.add(u64, strtab_name_start, max_name_len) catch continue;
            const start_usize = std.math.cast(usize, strtab_name_start) orelse continue;
            const end_usize = std.math.cast(usize, strtab_name_end) orelse continue;
            if (end_usize > source.len) continue;
            const sym_name_ptr = source[start_usize..end_usize];
            const name_len = std.mem.indexOfScalar(u8, sym_name_ptr, 0) orelse continue;
            const sym_name = sym_name_ptr[0..name_len];

            if (std.mem.eql(u8, sym_name, name)) {
                if (class == elf_spec.CLASS_32) { // ELF32_Sym
                    return readU32(source, sym_off + elf_spec.SYM32.VALUE); // st_value
                } else { // ELF64_Sym
                    return readU64(source, sym_off + elf_spec.SYM.VALUE); // st_value
                }
            }
        }

        return null;
    }

    // Byte-level little-endian readers with bounds checking.
    fn readU16(buf: []const u8, off: usize) u16 {
        const end = std.math.add(usize, off, 2) catch return 0;
        if (end > buf.len) return 0;
        return std.mem.readInt(u16, buf[off..][0..2], .little);
    }

    fn readU32(buf: []const u8, off: usize) u32 {
        const end = std.math.add(usize, off, 4) catch return 0;
        if (end > buf.len) return 0;
        return std.mem.readInt(u32, buf[off..][0..4], .little);
    }

    fn readU64(buf: []const u8, off: usize) u64 {
        const end = std.math.add(usize, off, 8) catch return 0;
        if (end > buf.len) return 0;
        return std.mem.readInt(u64, buf[off..][0..8], .little);
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

test "ELF loader and readers overflow safety" {
    const testing = std.testing;

    // 1. Test readU16, readU32, readU64 at maximum offsets
    const dummy = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try testing.expectEqual(@as(u16, 0), Loader.readU16(&dummy, std.math.maxInt(usize)));
    try testing.expectEqual(@as(u32, 0), Loader.readU32(&dummy, std.math.maxInt(usize)));
    try testing.expectEqual(@as(u64, 0), Loader.readU64(&dummy, std.math.maxInt(usize)));

    // 2. Test malicious ELF with overflowing program header table offset
    var bad_elf: [128]u8 = std.mem.zeroes([128]u8);
    @memcpy(bad_elf[0..4], elf_spec.MAGIC);
    bad_elf[elf_spec.EI_CLASS] = elf_spec.CLASS_64;
    bad_elf[elf_spec.EI_DATA] = elf_spec.DATA_LSB;
    bad_elf[elf_spec.EHDR.EHSIZE] = 64;
    std.mem.writeInt(u64, bad_elf[elf_spec.EHDR.PHOFF..][0..8], std.math.maxInt(u64) - 10, .little);
    std.mem.writeInt(u16, bad_elf[elf_spec.EHDR.PHENTSIZE..][0..2], 56, .little);
    std.mem.writeInt(u16, bad_elf[elf_spec.EHDR.PHNUM..][0..2], 10, .little);

    var phys_test = try physmem.initForTest(testing.allocator, 128);
    defer phys_test.deinit();

    const g = try guest.createGuest(testing.allocator, true, true, null, 0x80000000, 0, 0x100000, .riscv64);
    defer g.deinit();

    try testing.expectError(LoaderError.InvalidProgramHeader, Loader.load(g, &bad_elf));
}
