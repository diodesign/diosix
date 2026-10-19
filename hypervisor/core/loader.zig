const std = @import("std");
const guest = @import("guest.zig");
const vm = @import("vm.zig");
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
                    const rem = @min(ps - (cur_dst % ps), ps - (cur_src % ps));
                    const chunk = @min(count - copied, rem);
                    const src_hpa = gs.space.translateGPA(cur_src) catch
                        return LoaderError.TranslationFailed;
                    const dst_hpa = dst_space.translateGPA(cur_dst) catch
                        return LoaderError.TranslationFailed;
                    if (physmem.isHypervisorMemory(src_hpa, chunk) or
                        physmem.isHypervisorMemory(dst_hpa, chunk))
                        return LoaderError.TranslationFailed;
                    const d_ptr: [*]u8 = @ptrFromInt(dst_hpa);
                    const s_ptr: [*]const u8 = @ptrFromInt(src_hpa);
                    @memcpy(d_ptr[0..chunk], s_ptr[0..chunk]);
                    copied += chunk;
                }
            },
        }
    }
};
const ProgramHeader = struct {
    p_type: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
};

const ElfLayout = struct {
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

    fn forClass(class: u8) ?ElfLayout {
        if (class != elf_spec.CLASS_32 and class != elf_spec.CLASS_64)
            return null;
        const c32 = class == elf_spec.CLASS_32;
        const E32 = elf_spec.EHDR32;
        const P32 = elf_spec.PHDR32;
        const S32 = elf_spec.SHDR32;
        const E64 = elf_spec.EHDR;
        const P64 = elf_spec.PHDR;
        const S64 = elf_spec.SHDR;
        return .{
            .is_32 = c32,
            .ehdr_sz = if (c32) 52 else 64,
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

pub const Loader = struct {
    pub fn detectArch(source: []const u8) !guest.TargetArch {
        if (source.len < elf_spec.MIN_HEADER_LEN or
            !std.mem.eql(u8, source[0..4], elf_spec.MAGIC))
            return LoaderError.InvalidElfHeader;
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

    pub fn detectArchFromGuest(
        sp: *const vm.GuestSpace,
        gpa: usize,
        sz: usize,
    ) !guest.TargetArch {
        if (sz < elf_spec.MIN_HEADER_LEN) return LoaderError.InvalidElfHeader;
        var header_buf: [elf_spec.MIN_HEADER_LEN]u8 = undefined;
        sp.copyFromGuest(&header_buf, gpa) catch
            return LoaderError.TranslationFailed;
        return detectArch(&header_buf);
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
        var ph_buf: [64]u8 = undefined;
        if (off_end > src.len() or ph_size > ph_buf.len)
            return LoaderError.InvalidProgramHeader;
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
        if (src.len() < elf_spec.MIN_HEADER_LEN)
            return LoaderError.InvalidElfHeader;
        var hdr_buf: [64]u8 = undefined;
        try src.readBytes(hdr_buf[0..elf_spec.MIN_HEADER_LEN], 0);
        if (!std.mem.eql(u8, hdr_buf[0..4], elf_spec.MAGIC))
            return LoaderError.InvalidElfHeader;
        if (hdr_buf[elf_spec.EI_DATA] != elf_spec.DATA_LSB)
            return LoaderError.UnsupportedElfData;
        const lay = ElfLayout.forClass(hdr_buf[elf_spec.EI_CLASS]) orelse
            return LoaderError.UnsupportedElfClass;
        if (src.len() < lay.ehdr_sz) return LoaderError.InvalidElfHeader;
        try src.readBytes(hdr_buf[0..lay.ehdr_sz], 0);
        const entry_point = readWord(&hdr_buf, lay.entry, lay.is_32);
        const ph_off = readWord(&hdr_buf, lay.phoff, lay.is_32);
        const ph_size = readU16(&hdr_buf, lay.phentsize);
        const ph_num = readU16(&hdr_buf, lay.phnum);
        const total_ph = std.math.mul(u64, ph_num, ph_size) catch
            return LoaderError.InvalidProgramHeader;
        const ph_end = std.math.add(u64, ph_off, total_ph) catch
            return LoaderError.InvalidProgramHeader;
        if (ph_end > src.len()) return LoaderError.InvalidProgramHeader;
        var min_vaddr: u64 = std.math.maxInt(u64);
        var min_paddr: u64 = std.math.maxInt(u64);
        for (0..ph_num) |i| {
            const ph = try readProgramHeader(src, lay, ph_off, ph_size, i);
            if (ph.p_type == elf_spec.PT_LOAD) {
                if (ph.p_vaddr < min_vaddr) min_vaddr = ph.p_vaddr;
                if (ph.p_paddr < min_paddr) min_paddr = ph.p_paddr;
            }
        }
        if (min_vaddr == std.math.maxInt(u64)) min_vaddr = 0;
        if (min_paddr == std.math.maxInt(u64)) min_paddr = 0;
        for (0..ph_num) |i| {
            const ph = try readProgramHeader(src, lay, ph_off, ph_size, i);
            if (ph.p_type != elf_spec.PT_LOAD) continue;
            if (ph.p_filesz > 0 and (ph.p_offset > src.len() or
                ph.p_filesz > src.len() - ph.p_offset))
                return LoaderError.SegmentOutOfBounds;
            if (ph.p_memsz < ph.p_filesz)
                return LoaderError.InvalidProgramHeader;
            const gpa_offset = if (target_vm.target_arch == .x86_64)
                std.math.cast(usize, ph.p_paddr) orelse
                    return LoaderError.InvalidProgramHeader
            else blk: {
                if (ph.p_vaddr < min_vaddr)
                    return LoaderError.InvalidProgramHeader;
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
            if (total_sz > std.math.maxInt(usize) - physmem.PageSize)
                return LoaderError.SegmentOutOfBounds;
            const ps = physmem.PageSize;
            const aligned_sz = std.mem.alignForward(usize, total_sz, ps);
            const rwx = sv39x4.PTEFlags.read | sv39x4.PTEFlags.write |
                sv39x4.PTEFlags.execute | sv39x4.PTEFlags.valid |
                sv39x4.PTEFlags.accessed | sv39x4.PTEFlags.dirty |
                sv39x4.PTEFlags.user;
            var map_off: usize = 0;
            while (map_off < aligned_sz) : (map_off += ps) {
                const page_gpa = std.math.add(usize, aligned_gpa, map_off) catch
                    return LoaderError.SegmentOutOfBounds;
                if (target_vm.space.translateGPA(page_gpa) catch null) |_|
                    continue;
                if (!target_vm.checkRamQuota(1))
                    return LoaderError.QuotaExceeded;
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
                const chunk = @min(mem_sz - zeroed, rem);
                const cur_hpa = try target_vm.space.translateGPA(cur_gpa);
                if (physmem.isHypervisorMemory(cur_hpa, chunk))
                    return LoaderError.TranslationFailed;
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
        if (readU32(source, str_sh + lay.sh_type) != elf_spec.SHT_STRTAB)
            return null;
        const str_off = readWord(source, str_sh + lay.sh_offset, lay.is_32);
        const str_sz = readWord(source, str_sh + lay.sh_size, lay.is_32);
        if (str_off == 0 or str_sz == 0) return null;
        const str_end = std.math.add(u64, str_off, str_sz) catch return null;
        const sym_end = std.math.add(u64, sym_sh_off, sym_sh_sz) catch
            return null;
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
            const n_len = std.mem.indexOfScalar(u8, sym_slice, 0) orelse
                continue;
            if (std.mem.eql(u8, sym_slice[0..n_len], name)) {
                return readWord(source, sym_off + lay.sym_value, lay.is_32);
            }
        }
        return null;
    }

    fn readWord(buf: []const u8, off: usize, is_32: bool) u64 {
        return if (is_32) readInt(u32, buf, off) else readInt(u64, buf, off);
    }
    fn readInt(comptime T: type, buf: []const u8, off: usize) T {
        const end = std.math.add(usize, off, @sizeOf(T)) catch return 0;
        if (end > buf.len) return 0;
        return std.mem.readInt(T, buf[off..][0..@sizeOf(T)], .little);
    }
    fn readU16(buf: []const u8, off: usize) u16 {
        return readInt(u16, buf, off);
    }
    fn readU32(buf: []const u8, off: usize) u32 {
        return readInt(u32, buf, off);
    }
};

test "ELF header validation, symbol resolution, and RAM quota enforcement" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const bad = &[_]u8{ 0x7f, 'E', 'L' };
    try testing.expectError(error.InvalidElfHeader, Loader.detectArch(bad));

    const E = elf_spec.EHDR;
    const P = elf_spec.PHDR;
    var b: [512]u8 = std.mem.zeroes([512]u8);
    @memcpy(b[0..4], elf_spec.MAGIC);
    b[elf_spec.EI_CLASS] = elf_spec.CLASS_64;
    b[elf_spec.EI_DATA] = elf_spec.DATA_LSB;
    const rv_mach = elf_spec.MACHINE_RISCV;
    std.mem.writeInt(u16, b[E.MACHINE..][0..2], rv_mach, .little);
    const det = try Loader.detectArch(&b);
    try testing.expectEqual(guest.TargetArch.riscv64, det);
    std.mem.writeInt(u64, b[E.SHOFF..][0..8], 64, .little);
    std.mem.writeInt(u16, b[E.SHENTSIZE..][0..2], 64, .little);
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
    std.mem.writeInt(u64, b[E.PHOFF..][0..8], 64, .little);
    std.mem.writeInt(u16, b[E.PHENTSIZE..][0..2], 56, .little);
    std.mem.writeInt(u16, b[E.PHNUM..][0..2], 1, .little);
    const ph = b[64..120];
    std.mem.writeInt(u32, ph[P.TYPE..][0..4], elf_spec.PT_LOAD, .little);
    std.mem.writeInt(u64, ph[P.VADDR..][0..8], 0x80000000, .little);
    std.mem.writeInt(u64, ph[P.PADDR..][0..8], 0x80000000, .little);
    std.mem.writeInt(u64, ph[P.FILESZ..][0..8], 64, .little);
    std.mem.writeInt(u64, ph[P.MEMSZ..][0..8], 4096, .little);
    const res1 = Loader.load(g, b[0..256]);
    try testing.expectError(LoaderError.QuotaExceeded, res1);
    g.quotas.max_ram_pages = 1;
    const ep = try Loader.load(g, b[0..256]);
    try testing.expectEqual(@as(usize, 0x80000000), ep);
}
