// ELF binary loader and symbol table resolver for Guest VMs.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const guest = @import("guest.zig");
const vm = @import("vm.zig");
const physmem = @import("physmem.zig");
const sv39x4 = @import("../hardware/native/cpu/riscv64/sv39x4.zig");
const elf_spec = @import("interface").elf;

pub const symbols = @import("loader/symbols.zig");
pub const ElfLayout = symbols.ElfLayout;
const readWord = symbols.readWord;
const readU16 = symbols.readU16;
const readU32 = symbols.readU32;

pub const LoaderError = error{
    InvalidElfHeader,
    UnsupportedElfClass,
    UnsupportedElfData,
    UnsupportedElfMachine,
    InvalidProgramHeader,
    SegmentOutOfBounds,
    SegmentTooLarge,
    TranslationFailed,
    QuotaExceeded,
};

const ElfSource = union(enum) {
    slice: []const u8,
    guest_space: struct {
        space: *const vm.GuestSpace,
        base_gpa: usize,
        size: usize,
    },

    fn len(self: ElfSource) usize {
        return switch (self) {
            .slice => |s| s.len,
            .guest_space => |gs| gs.size,
        };
    }

    fn readBytes(self: ElfSource, dst: []u8, offset: usize) !void {
        const end = std.math.add(usize, offset, dst.len) catch
            return LoaderError.SegmentOutOfBounds;
        if (end > self.len()) return LoaderError.SegmentOutOfBounds;
        switch (self) {
            .slice => |s| @memcpy(dst, s[offset..end]),
            .guest_space => |gs| {
                const src_gpa = std.math.add(usize, gs.base_gpa, offset) catch
                    return LoaderError.SegmentOutOfBounds;
                gs.space.copyFromGuest(dst, src_gpa) catch
                    return LoaderError.TranslationFailed;
            },
        }
    }

    fn copyToGuest(
        self: ElfSource,
        dst_space: *vm.GuestSpace,
        dst_gpa: usize,
        src_offset: usize,
        count: usize,
    ) !void {
        if (count == 0) return;
        const src_end = std.math.add(usize, src_offset, count) catch
            return LoaderError.SegmentOutOfBounds;
        if (src_end > self.len()) return LoaderError.SegmentOutOfBounds;
        switch (self) {
            .slice => |s| dst_space.copyToGuest(
                dst_gpa,
                s[src_offset..src_end],
            ) catch return LoaderError.TranslationFailed,
            .guest_space => |gs| {
                var copied: usize = 0;
                const ps = physmem.PageSize;
                while (copied < count) {
                    const cur_dst = std.math.add(usize, dst_gpa, copied) catch
                        return LoaderError.SegmentOutOfBounds;
                    const off = src_offset + copied;
                    const cur_src = std.math.add(usize, gs.base_gpa, off) catch
                        return LoaderError.SegmentOutOfBounds;
                    const rem: usize =
                        @min(ps - (cur_dst % ps), ps - (cur_src % ps));
                    const chunk: usize = @min(count - copied, rem);
                    const src_hpa = gs.space.translateGPA(cur_src) catch
                        return LoaderError.TranslationFailed;
                    const dst_hpa = dst_space.translateGPA(cur_dst) catch
                        return LoaderError.TranslationFailed;
                    if (physmem.isHypervisorMemory(src_hpa, chunk) or
                        physmem.isHypervisorMemory(dst_hpa, chunk))
                    {
                        return LoaderError.TranslationFailed;
                    }
                    const d_ptr: [*]u8 = @ptrFromInt(dst_hpa);
                    const s_ptr: [*]const u8 = @ptrFromInt(src_hpa);
                    @memcpy(d_ptr[0..chunk], s_ptr[0..chunk]);
                    copied += chunk;
                }
            },
        }
    }
};

pub const MAX_PHNUM: usize = 128;

const ProgramHeader = struct {
    p_type: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
};

pub const Loader = struct {
    pub const findSymbol = symbols.findSymbol;

    pub fn detectArchFromHeader(source: []const u8) !guest.TargetArch {
        if (source.len < elf_spec.MIN_HEADER_LEN or
            !std.mem.eql(u8, source[0..4], elf_spec.MAGIC))
        {
            return LoaderError.InvalidElfHeader;
        }
        if (source[elf_spec.EI_DATA] != elf_spec.DATA_LSB) {
            return LoaderError.UnsupportedElfData;
        }
        const class = source[elf_spec.EI_CLASS];
        const machine = readU16(source, elf_spec.EHDR.MACHINE);
        if (machine == elf_spec.MACHINE_RISCV) {
            if (class == elf_spec.CLASS_32) return .riscv32;
            if (class == elf_spec.CLASS_64) return .riscv64;
            return LoaderError.UnsupportedElfClass;
        }
        if (machine == elf_spec.MACHINE_AARCH64) return .aarch64;
        if (machine == elf_spec.MACHINE_X86_64) return .x86_64;
        return LoaderError.UnsupportedElfMachine;
    }

    pub const detectArch = detectArchFromHeader;

    pub fn detectArchFromGuest(
        sp: *const vm.GuestSpace,
        gpa: usize,
        sz: usize,
    ) !guest.TargetArch {
        if (sz < elf_spec.MIN_HEADER_LEN) return LoaderError.InvalidElfHeader;
        var header_buf: [elf_spec.MIN_HEADER_LEN]u8 = undefined;
        sp.copyFromGuest(&header_buf, gpa) catch
            return LoaderError.TranslationFailed;
        return detectArchFromHeader(&header_buf);
    }

    pub fn load(root_vm: *guest.Guest, source: []const u8) !usize {
        return loadImpl(root_vm, .{ .slice = source });
    }

    pub fn loadFromGuest(
        g: *guest.Guest,
        sp: *const vm.GuestSpace,
        gpa: usize,
        sz: usize,
    ) !usize {
        return loadImpl(g, .{
            .guest_space = .{ .space = sp, .base_gpa = gpa, .size = sz },
        });
    }

    fn readProgramHeader(
        src: ElfSource,
        lay: ElfLayout,
        ph_off: u64,
        ph_size: u16,
        index: usize,
    ) !ProgramHeader {
        const i_ph = std.math.mul(u64, index, ph_size) catch
            return LoaderError.InvalidProgramHeader;
        const off = std.math.add(u64, ph_off, i_ph) catch
            return LoaderError.InvalidProgramHeader;
        const off_end = std.math.add(u64, off, ph_size) catch
            return LoaderError.InvalidProgramHeader;
        var ph_buf: [elf_spec.ELF64_EHDR_SIZE]u8 = undefined;
        if (off_end > src.len() or ph_size > ph_buf.len) {
            return LoaderError.InvalidProgramHeader;
        }
        const off_u = std.math.cast(usize, off) orelse
            return LoaderError.InvalidProgramHeader;
        try src.readBytes(ph_buf[0..ph_size], off_u);
        return .{
            .p_type = readU32(&ph_buf, 0),
            .p_offset = readWord(&ph_buf, lay.ph_off, lay.is_32),
            .p_vaddr = readWord(&ph_buf, lay.ph_vaddr, lay.is_32),
            .p_paddr = readWord(&ph_buf, lay.ph_paddr, lay.is_32),
            .p_filesz = readWord(&ph_buf, lay.ph_filesz, lay.is_32),
            .p_memsz = readWord(&ph_buf, lay.ph_memsz, lay.is_32),
        };
    }

    fn loadImpl(target_vm: *guest.Guest, src: ElfSource) !usize {
        const hdr_len: usize = @min(src.len(), elf_spec.ELF64_EHDR_SIZE);
        if (hdr_len < elf_spec.MIN_HEADER_LEN) {
            return LoaderError.InvalidElfHeader;
        }
        var hdr_buf: [elf_spec.ELF64_EHDR_SIZE]u8 = @splat(0);
        try src.readBytes(hdr_buf[0..hdr_len], 0);
        const detected_arch = try detectArchFromHeader(hdr_buf[0..hdr_len]);
        const lay = ElfLayout.forClass(hdr_buf[elf_spec.EI_CLASS]) orelse
            return LoaderError.UnsupportedElfClass;
        if (hdr_len < lay.ehdr_sz) return LoaderError.InvalidElfHeader;
        target_vm.target_arch = detected_arch;

        const entry_point = readWord(&hdr_buf, lay.entry, lay.is_32);
        const ph_off = readWord(&hdr_buf, lay.phoff, lay.is_32);
        const ph_size = readU16(&hdr_buf, lay.phentsize);
        const ph_num = readU16(&hdr_buf, lay.phnum);
        if (ph_num > MAX_PHNUM) return LoaderError.InvalidProgramHeader;
        const total_ph = std.math.mul(u64, ph_num, ph_size) catch
            return LoaderError.InvalidProgramHeader;
        const ph_end = std.math.add(u64, ph_off, total_ph) catch
            return LoaderError.InvalidProgramHeader;
        if (ph_end > src.len()) return LoaderError.InvalidProgramHeader;

        var ph_table: [MAX_PHNUM]ProgramHeader = undefined;
        var min_vaddr: u64 = std.math.maxInt(u64);
        var min_paddr: u64 = std.math.maxInt(u64);
        for (0..ph_num) |i| {
            const ph = try readProgramHeader(src, lay, ph_off, ph_size, i);
            ph_table[i] = ph;
            if (ph.p_type == elf_spec.PT_LOAD) {
                if (ph.p_vaddr < min_vaddr) min_vaddr = ph.p_vaddr;
                if (ph.p_paddr < min_paddr) min_paddr = ph.p_paddr;
            }
        }
        if (min_vaddr == std.math.maxInt(u64)) min_vaddr = 0;
        if (min_paddr == std.math.maxInt(u64)) min_paddr = 0;

        for (ph_table[0..ph_num]) |ph| {
            if (ph.p_type != elf_spec.PT_LOAD) continue;
            if (ph.p_filesz > 0 and (ph.p_offset > src.len() or
                ph.p_filesz > src.len() - ph.p_offset))
            {
                return LoaderError.SegmentOutOfBounds;
            }
            if (ph.p_memsz < ph.p_filesz) {
                return LoaderError.InvalidProgramHeader;
            }
            const gpa_offset = if (target_vm.target_arch == .x86_64)
                std.math.cast(usize, ph.p_paddr) orelse
                    return LoaderError.InvalidProgramHeader
            else blk: {
                if (ph.p_vaddr < min_vaddr) {
                    return LoaderError.InvalidProgramHeader;
                }
                break :blk std.math.cast(usize, ph.p_vaddr - min_vaddr) orelse
                    return LoaderError.InvalidProgramHeader;
            };
            const base_gpa = target_vm.space.base_gpa;
            const gpa = std.math.add(usize, base_gpa, gpa_offset) catch
                return LoaderError.SegmentOutOfBounds;
            const page_offset = gpa % physmem.PageSize;
            const aligned_gpa = gpa - page_offset;
            const mem_sz = std.math.cast(usize, ph.p_memsz) orelse
                return LoaderError.SegmentOutOfBounds;
            const total_sz = std.math.add(usize, mem_sz, page_offset) catch
                return LoaderError.SegmentOutOfBounds;
            if (total_sz > std.math.maxInt(usize) - physmem.PageSize) {
                return LoaderError.SegmentOutOfBounds;
            }
            const ps = physmem.PageSize;
            const aligned_sz = std.mem.alignForward(usize, total_sz, ps);
            const rwx = sv39x4.PTEFlags.leaf_rwx_user;
            var map_off: usize = 0;
            while (map_off < aligned_sz) : (map_off += ps) {
                const page_gpa = std.math.add(usize, aligned_gpa, map_off) catch
                    return LoaderError.SegmentOutOfBounds;
                if (target_vm.space.translateGPA(page_gpa) catch null) |_| {
                    continue;
                }
                if (!target_vm.checkRamQuota(1)) {
                    return LoaderError.QuotaExceeded;
                }
                const new_hpa = try physmem.allocPage();
                target_vm.space.map(page_gpa, new_hpa, ps, rwx) catch |err| {
                    physmem.freePage(new_hpa);
                    return err;
                };
                target_vm.consumeQuota(1, 0);
                physmem.decrementPageRef(new_hpa);
            }
            const file_sz = std.math.cast(usize, ph.p_filesz) orelse
                return LoaderError.SegmentOutOfBounds;
            const file_off = std.math.cast(usize, ph.p_offset) orelse
                return LoaderError.SegmentOutOfBounds;
            try src.copyToGuest(&target_vm.space, gpa, file_off, file_sz);
            var zeroed: usize = file_sz;
            while (zeroed < mem_sz) {
                const cur_gpa = std.math.add(usize, gpa, zeroed) catch
                    return LoaderError.SegmentOutOfBounds;
                const rem = ps - (cur_gpa % ps);
                const chunk: usize = @min(mem_sz - zeroed, rem);
                const cur_hpa = try target_vm.space.translateGPA(cur_gpa);
                if (physmem.isHypervisorMemory(cur_hpa, chunk)) {
                    return LoaderError.TranslationFailed;
                }
                @memset(@as([*]u8, @ptrFromInt(cur_hpa))[0..chunk], 0);
                zeroed += chunk;
            }
        }
        if (src == .slice and target_vm.target_arch != .x86_64) {
            if (findSymbol(src.slice, "early_top_pgt")) |pgt_vaddr| {
                if (pgt_vaddr >= min_vaddr) {
                    if (std.math.cast(usize, pgt_vaddr - min_vaddr)) |off| {
                        const base = target_vm.space.base_gpa;
                        const def = target_vm.early_pgt_gpa;
                        target_vm.early_pgt_gpa =
                            std.math.add(usize, base, off) catch def;
                    }
                }
            }
        }
        const entry_offset = if (target_vm.target_arch == .x86_64)
            entry_point
        else if (entry_point < min_vaddr) blk: {
            if (entry_point < min_paddr) return LoaderError.InvalidElfHeader;
            break :blk entry_point - min_paddr;
        } else (entry_point - min_vaddr);
        const ep_u = std.math.cast(usize, entry_offset) orelse
            return LoaderError.InvalidElfHeader;
        return std.math.add(usize, target_vm.space.base_gpa, ep_u) catch
            return LoaderError.InvalidElfHeader;
    }
};

test "ELF header validation, symbol resolution, and RAM quota enforcement" {
    _ = symbols;
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    const alloc = testing.allocator;
    const bad = &[_]u8{ 0x7f, 'E', 'L' };
    try testing.expectError(error.InvalidElfHeader, Loader.detectArch(bad));

    const E = elf_spec.EHDR;
    const P = elf_spec.PHDR;
    var b: [512]u8 = @splat(0);
    @memcpy(b[0..4], elf_spec.MAGIC);
    b[elf_spec.EI_CLASS] = elf_spec.CLASS_64;
    b[elf_spec.EI_DATA] = elf_spec.DATA_LSB;
    const rv_mach = elf_spec.MACHINE_RISCV;
    std.mem.writeInt(u16, b[E.MACHINE..][0..2], rv_mach, .little);
    const det = try Loader.detectArch(&b);
    try testing.expectEqual(guest.TargetArch.riscv64, det);
    const ehdr_sz64: u64 = elf_spec.ELF64_EHDR_SIZE;
    const shdr_sz16: u16 = @intCast(elf_spec.ELF64_SHDR_SIZE);
    std.mem.writeInt(u64, b[E.SHOFF..][0..8], ehdr_sz64, .little);
    std.mem.writeInt(u16, b[E.SHENTSIZE..][0..2], shdr_sz16, .little);
    std.mem.writeInt(u16, b[E.SHNUM..][0..2], 3, .little);
    std.mem.writeInt(u32, b[132..136], elf_spec.SHT_SYMTAB, .little);
    std.mem.writeInt(u64, b[152..160], 256, .little);
    std.mem.writeInt(u64, b[160..168], 48, .little);
    std.mem.writeInt(u32, b[168..172], 2, .little);
    std.mem.writeInt(u64, b[184..192], 24, .little);
    std.mem.writeInt(u32, b[196..200], elf_spec.SHT_STRTAB, .little);
    std.mem.writeInt(u64, b[216..224], 304, .little);
    std.mem.writeInt(u64, b[224..232], 32, .little);
    std.mem.writeInt(u32, b[280..284], 1, .little);
    std.mem.writeInt(u64, b[288..296], 0x80200000, .little);
    @memcpy(b[304..318], "\x00start_kernel\x00");
    const sym = Loader.findSymbol(&b, "start_kernel");
    try testing.expectEqual(@as(?u64, 0x80200000), sym);
    var phys_test = try physmem.initForTest(alloc, 128);
    defer phys_test.deinit();
    const g = try guest.createGuest(
        alloc,
        false,
        false,
        null,
        0x80000000,
        0,
        0x100000,
        .riscv64,
    );
    defer g.deinit();
    g.quotas.used_ram_pages = 0;
    g.quotas.max_ram_pages = 0;
    std.mem.writeInt(u64, b[E.ENTRY..][0..8], 0x80000000, .little);
    std.mem.writeInt(u64, b[E.PHOFF..][0..8], ehdr_sz64, .little);
    const phdr_sz16: u16 = @intCast(elf_spec.ELF64_PHDR_SIZE);
    std.mem.writeInt(u16, b[E.PHENTSIZE..][0..2], phdr_sz16, .little);
    std.mem.writeInt(u16, b[E.PHNUM..][0..2], 1, .little);
    const ph = b[elf_spec.ELF64_EHDR_SIZE..120];
    std.mem.writeInt(u32, ph[P.TYPE..][0..4], elf_spec.PT_LOAD, .little);
    std.mem.writeInt(u64, ph[P.VADDR..][0..8], 0x80000000, .little);
    std.mem.writeInt(u64, ph[P.PADDR..][0..8], 0x80000000, .little);
    std.mem.writeInt(u64, ph[P.FILESZ..][0..8], ehdr_sz64, .little);
    std.mem.writeInt(u64, ph[P.MEMSZ..][0..8], 4096, .little);
    const res1 = Loader.load(g, b[0..256]);
    try testing.expectError(LoaderError.QuotaExceeded, res1);
    g.quotas.max_ram_pages = 1;
    const ep = try Loader.load(g, b[0..256]);
    try testing.expectEqual(@as(usize, 0x80000000), ep);
}
