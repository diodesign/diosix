// Freestanding Zero-Allocation Flattened DeviceTree (FDT/DTB) Parser
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const FDT_MAGIC: u32 = 0xd00dfeed;
pub const FDT_HEADER_SIZE: u32 = 40;
pub const MAX_FDT_SIZE: u32 = 16 * 1024 * 1024; // 16MB max reasonable DTB size

// Standard FDT node and property tokens
pub const FDT_BEGIN_NODE: u32 = 0x00000001;
pub const FDT_END_NODE: u32   = 0x00000002;
pub const FDT_PROP: u32       = 0x00000003;
pub const FDT_NOP: u32        = 0x00000004;
pub const FDT_END: u32        = 0x00000009;

// Default platform addresses
pub const DEFAULT_RAM_BASE: u64   = 0x80000000;
pub const DEFAULT_RAM_SIZE: u64   = 512 * 1024 * 1024; // 512MB default fallback
pub const DEFAULT_UART_BASE: usize = 0x10000000;
pub const DEFAULT_CLINT_BASE: usize= 0x02000000;
pub const DEFAULT_PLIC_BASE: usize = 0x0c000000;

pub const FdtHeader = struct {
    magic: u32,
    totalsize: u32,
    off_dt_struct: u32,
    off_dt_strings: u32,
    off_mem_rsvmap: u32,
    version: u32,
    last_comp_version: u32,
    boot_cpuid_phys: u32,
    size_dt_strings: u32,
    size_dt_struct: u32,
};

pub const FdtError = error{
    BadMagic,
    TruncatedHeader,
    CorruptStructure,
};

pub const FdtNode = struct {
    name: []const u8,
};

pub const FdtProperty = struct {
    name: []const u8,
    value: []const u8,
};

pub const SystemHardwareInfo = struct {
    ram_base: u64 = DEFAULT_RAM_BASE,
    ram_size: u64 = DEFAULT_RAM_SIZE,
    uart_base: ?usize = null,
    clint_base: ?usize = null,
    plic_base: ?usize = null,
};

/// Read 32-bit big-endian integer from unaligned memory
inline fn readU32Be(ptr: [*]const u8) u32 {
    return (@as(u32, ptr[0]) << 24) |
        (@as(u32, ptr[1]) << 16) |
        (@as(u32, ptr[2]) << 8) |
        @as(u32, ptr[3]);
}

/// Read 64-bit big-endian integer from unaligned memory
inline fn readU64Be(ptr: [*]const u8) u64 {
    return (@as(u64, readU32Be(ptr)) << 32) | @as(u64, readU32Be(ptr + 4));
}

/// Parse FDT Header from raw memory pointer with comprehensive bounds checking
pub fn parseHeader(dtb_ptr: [*]const u8) FdtError!FdtHeader {
    const magic = readU32Be(dtb_ptr);
    if (magic != FDT_MAGIC) return FdtError.BadMagic;

    const totalsize = readU32Be(dtb_ptr + 4);
    if (totalsize < FDT_HEADER_SIZE or totalsize > MAX_FDT_SIZE) return FdtError.TruncatedHeader;

    const off_dt_struct = readU32Be(dtb_ptr + 8);
    const off_dt_strings = readU32Be(dtb_ptr + 12);
    const off_mem_rsvmap = readU32Be(dtb_ptr + 16);
    const version = readU32Be(dtb_ptr + 20);
    const last_comp_version = readU32Be(dtb_ptr + 24);
    const boot_cpuid_phys = readU32Be(dtb_ptr + 28);
    const size_dt_strings = readU32Be(dtb_ptr + 32);
    const size_dt_struct = readU32Be(dtb_ptr + 36);

    const end_struct = std.math.add(u32, off_dt_struct, size_dt_struct) catch return FdtError.CorruptStructure;
    const end_strings = std.math.add(u32, off_dt_strings, size_dt_strings) catch return FdtError.CorruptStructure;
    if (end_struct > totalsize or end_strings > totalsize or off_mem_rsvmap > totalsize) {
        return FdtError.CorruptStructure;
    }

    return FdtHeader{
        .magic = magic,
        .totalsize = totalsize,
        .off_dt_struct = off_dt_struct,
        .off_dt_strings = off_dt_strings,
        .off_mem_rsvmap = off_mem_rsvmap,
        .version = version,
        .last_comp_version = last_comp_version,
        .boot_cpuid_phys = boot_cpuid_phys,
        .size_dt_strings = size_dt_strings,
        .size_dt_struct = size_dt_struct,
    };
}

/// Perform zero-allocation FDT scan to extract system RAM, UART, CLINT, and PLIC MMIO bases.
/// Defensively bounds-checked against malicious, truncated, or unterminated device trees.
pub fn parseHardwareInfo(dtb_ptr: [*]const u8) FdtError!SystemHardwareInfo {
    const header = try parseHeader(dtb_ptr);

    var info = SystemHardwareInfo{};
    const struct_ptr = dtb_ptr + header.off_dt_struct;
    const strings_ptr = dtb_ptr + header.off_dt_strings;

    var offset: usize = 0;
    var current_node: []const u8 = "";

    var address_cells: usize = 2;
    var size_cells: usize = 2;

    while (offset + 4 <= header.size_dt_struct) {
        const token = readU32Be(struct_ptr + offset);
        offset += 4;

        switch (token) {
            FDT_BEGIN_NODE => {
                const name_start = struct_ptr + offset;
                var len: usize = 0;
                while (offset + len < header.size_dt_struct and name_start[len] != 0) : (len += 1) {}
                if (offset + len >= header.size_dt_struct) return FdtError.CorruptStructure;

                current_node = name_start[0..len];

                // Align up to 4 bytes boundary past the null terminator
                const aligned_len = (len + 1 + 3) & ~@as(usize, 3);
                offset = std.math.add(usize, offset, aligned_len) catch return FdtError.CorruptStructure;
            },
            FDT_END_NODE => {
                current_node = "";
            },
            FDT_PROP => {
                if (offset + 8 > header.size_dt_struct) return FdtError.CorruptStructure;
                const prop_len = readU32Be(struct_ptr + offset);
                const name_off = readU32Be(struct_ptr + offset + 4);
                offset += 8;

                if (prop_len > header.size_dt_struct - offset) return FdtError.CorruptStructure;
                if (name_off >= header.size_dt_strings) return FdtError.CorruptStructure;

                const val_ptr = struct_ptr + offset;
                const prop_name_ptr = strings_ptr + name_off;

                var prop_name_len: usize = 0;
                while (name_off + prop_name_len < header.size_dt_strings and prop_name_ptr[prop_name_len] != 0) : (prop_name_len += 1) {}
                if (name_off + prop_name_len >= header.size_dt_strings) return FdtError.CorruptStructure;
                const prop_name = prop_name_ptr[0..prop_name_len];

                const node_name = current_node;

                if (std.mem.eql(u8, prop_name, "#address-cells") and prop_len >= 4) {
                    const cells = readU32Be(val_ptr);
                    if (cells >= 1 and cells <= 2) address_cells = cells;
                } else if (std.mem.eql(u8, prop_name, "#size-cells") and prop_len >= 4) {
                    const cells = readU32Be(val_ptr);
                    if (cells >= 1 and cells <= 2) size_cells = cells;
                } else if (std.mem.startsWith(u8, node_name, "memory") and std.mem.eql(u8, prop_name, "reg")) {
                    if (address_cells == 2) {
                        if (size_cells == 2 and prop_len >= 16) {
                            info.ram_base = readU64Be(val_ptr);
                            info.ram_size = readU64Be(val_ptr + 8);
                        } else if (size_cells == 1 and prop_len >= 12) {
                            info.ram_base = readU64Be(val_ptr);
                            info.ram_size = readU32Be(val_ptr + 8);
                        }
                    } else if (address_cells == 1) {
                        if (size_cells == 2 and prop_len >= 12) {
                            info.ram_base = readU32Be(val_ptr);
                            info.ram_size = readU64Be(val_ptr + 4);
                        } else if (prop_len >= 8) {
                            info.ram_base = readU32Be(val_ptr);
                            info.ram_size = readU32Be(val_ptr + 4);
                        }
                    }
                } else if (std.mem.eql(u8, prop_name, "compatible")) {
                    const compat_val = val_ptr[0..prop_len];
                    if (containsString(compat_val, "ns16550a") or containsString(compat_val, "sifive,uart0") or containsString(compat_val, "snps,dw-apb-uart")) {
                        info.uart_base = DEFAULT_UART_BASE;
                    } else if (containsString(compat_val, "riscv,clint0") or containsString(compat_val, "sifive,clint0")) {
                        info.clint_base = DEFAULT_CLINT_BASE;
                    } else if (containsString(compat_val, "riscv,plic0") or containsString(compat_val, "sifive,plic-1.0.0")) {
                        info.plic_base = DEFAULT_PLIC_BASE;
                    }
                } else if (std.mem.eql(u8, prop_name, "reg")) {
                    if (std.mem.indexOf(u8, node_name, "uart") != null or std.mem.indexOf(u8, node_name, "serial") != null) {
                        const base = if (address_cells == 2 and prop_len >= 8) readU64Be(val_ptr) else if (prop_len >= 4) readU32Be(val_ptr) else 0;
                        if (base != 0) info.uart_base = @truncate(base);
                    } else if (std.mem.indexOf(u8, node_name, "clint") != null) {
                        const base = if (address_cells == 2 and prop_len >= 8) readU64Be(val_ptr) else if (prop_len >= 4) readU32Be(val_ptr) else 0;
                        if (base != 0) info.clint_base = @truncate(base);
                    } else if (std.mem.indexOf(u8, node_name, "plic") != null) {
                        const base = if (address_cells == 2 and prop_len >= 8) readU64Be(val_ptr) else if (prop_len >= 4) readU32Be(val_ptr) else 0;
                        if (base != 0) info.plic_base = @truncate(base);
                    }
                }

                const aligned_prop_len = (prop_len + 3) & ~@as(usize, 3);
                offset = std.math.add(usize, offset, aligned_prop_len) catch return FdtError.CorruptStructure;
            },
            FDT_NOP => {},
            FDT_END => break,
            else => return FdtError.CorruptStructure,
        }
    }

    return info;
}

fn containsString(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "FDT header parsing" {
    var raw_header: [40]u8 = std.mem.zeroes([40]u8);
    raw_header[0] = 0xd0;
    raw_header[1] = 0x0d;
    raw_header[2] = 0xfe;
    raw_header[3] = 0xed;

    raw_header[6] = 0x01;
    raw_header[7] = 0x00;

    const header = try parseHeader(&raw_header);
    try std.testing.expectEqual(@as(u32, FDT_MAGIC), header.magic);
    try std.testing.expectEqual(@as(u32, 256), header.totalsize);
}

test "FDT corrupt and out-of-bounds rejection" {
    // 1. Bad magic
    var bad_magic: [40]u8 = std.mem.zeroes([40]u8);
    try std.testing.expectError(FdtError.BadMagic, parseHeader(&bad_magic));

    // 2. Truncated header (totalsize < 40)
    var trunc: [40]u8 = std.mem.zeroes([40]u8);
    trunc[0] = 0xd0;
    trunc[1] = 0x0d;
    trunc[2] = 0xfe;
    trunc[3] = 0xed;
    trunc[7] = 20; // 20 bytes < FDT_HEADER_SIZE
    try std.testing.expectError(FdtError.TruncatedHeader, parseHeader(&trunc));

    // 3. Offsets exceeding totalsize
    var bad_offsets: [40]u8 = std.mem.zeroes([40]u8);
    bad_offsets[0] = 0xd0;
    bad_offsets[1] = 0x0d;
    bad_offsets[2] = 0xfe;
    bad_offsets[3] = 0xed;
    bad_offsets[7] = 100; // totalsize = 100
    bad_offsets[11] = 120; // off_dt_struct = 120 > totalsize
    try std.testing.expectError(FdtError.CorruptStructure, parseHeader(&bad_offsets));
}

test "FDT parseHardwareInfo with long node name exceeding 64 bytes" {
    var dtb: [512]u8 = @splat(0);
    // Header (40 bytes)
    dtb[0] = 0xd0; dtb[1] = 0x0d; dtb[2] = 0xfe; dtb[3] = 0xed; // magic
    dtb[6] = 0x02; dtb[7] = 0x00; // totalsize = 512
    dtb[11] = 48; // off_dt_struct = 48
    dtb[14] = 0x01; dtb[15] = 0x2c; // off_dt_strings = 300
    dtb[19] = 40; // off_mem_rsvmap = 40
    dtb[23] = 17; // version = 17
    dtb[27] = 16; // last_comp_version = 16
    dtb[35] = 64; // size_dt_strings = 64
    dtb[38] = 0x00; dtb[39] = 200; // size_dt_struct = 200

    // Strings table at offset 300
    const str_table = dtb[300..];
    @memcpy(str_table[0..4], "reg\x00");
    @memcpy(str_table[4..19], "#address-cells\x00");
    @memcpy(str_table[19..31], "#size-cells\x00");

    var s_idx: usize = 48;

    // FDT_BEGIN_NODE (root "")
    std.mem.writeInt(u32, dtb[s_idx..][0..4], FDT_BEGIN_NODE, .big);
    s_idx += 4;
    dtb[s_idx] = 0; // null name
    s_idx += 4; // aligned to 4

    // FDT_PROP #address-cells = 1
    std.mem.writeInt(u32, dtb[s_idx..][0..4], FDT_PROP, .big);
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], 4, .big);
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], 4, .big); // offset 4
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], 1, .big); // value 1
    s_idx += 4;

    // FDT_PROP #size-cells = 1
    std.mem.writeInt(u32, dtb[s_idx..][0..4], FDT_PROP, .big);
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], 4, .big);
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], 19, .big); // offset 19
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], 1, .big); // value 1
    s_idx += 4;

    // FDT_BEGIN_NODE: long serial node name (71 characters, > 64 bytes)
    const long_name = "serial-device-with-a-very-long-name-exceeding-sixty-four-bytes@10000000";
    std.mem.writeInt(u32, dtb[s_idx..][0..4], FDT_BEGIN_NODE, .big);
    s_idx += 4;
    @memcpy(dtb[s_idx..][0..long_name.len], long_name);
    dtb[s_idx + long_name.len] = 0;
    const aligned_name_len = (long_name.len + 1 + 3) & ~@as(usize, 3);
    s_idx += aligned_name_len;

    // FDT_PROP reg = 0x10000000, len 8
    std.mem.writeInt(u32, dtb[s_idx..][0..4], FDT_PROP, .big);
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], 8, .big);
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], 0, .big); // offset 0 ("reg")
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], 0x10000000, .big);
    s_idx += 4;
    std.mem.writeInt(u32, dtb[s_idx..][0..4], 0x100, .big);
    s_idx += 4;

    // FDT_END_NODE (serial)
    std.mem.writeInt(u32, dtb[s_idx..][0..4], FDT_END_NODE, .big);
    s_idx += 4;

    // FDT_END_NODE (root)
    std.mem.writeInt(u32, dtb[s_idx..][0..4], FDT_END_NODE, .big);
    s_idx += 4;

    // FDT_END
    std.mem.writeInt(u32, dtb[s_idx..][0..4], FDT_END, .big);
    s_idx += 4;

    const info = try parseHardwareInfo(&dtb);
    try std.testing.expectEqual(@as(usize, 0x10000000), info.uart_base);
}

