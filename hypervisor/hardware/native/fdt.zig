// Freestanding Zero-Allocation Flattened DeviceTree (FDT/DTB) Parser
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const FDT_MAGIC: u32 = 0xd00dfeed;

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
    ram_base: u64 = 0x80000000,
    ram_size: u64 = 512 * 1024 * 1024, // 512MB default fallback
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

/// Parse FDT Header from raw memory pointer
pub fn parseHeader(dtb_ptr: [*]const u8) FdtError!FdtHeader {
    const magic = readU32Be(dtb_ptr);
    if (magic != FDT_MAGIC) return FdtError.BadMagic;

    return FdtHeader{
        .magic = magic,
        .totalsize = readU32Be(dtb_ptr + 4),
        .off_dt_struct = readU32Be(dtb_ptr + 8),
        .off_dt_strings = readU32Be(dtb_ptr + 12),
        .off_mem_rsvmap = readU32Be(dtb_ptr + 16),
        .version = readU32Be(dtb_ptr + 20),
        .last_comp_version = readU32Be(dtb_ptr + 24),
        .boot_cpuid_phys = readU32Be(dtb_ptr + 28),
        .size_dt_strings = readU32Be(dtb_ptr + 32),
        .size_dt_struct = readU32Be(dtb_ptr + 36),
    };
}

/// Perform zero-allocation FDT scan to extract system RAM, UART, CLINT, and PLIC MMIO bases
pub fn parseHardwareInfo(dtb_ptr: [*]const u8) FdtError!SystemHardwareInfo {
    const header = try parseHeader(dtb_ptr);

    var info = SystemHardwareInfo{};
    const struct_ptr = dtb_ptr + header.off_dt_struct;
    const strings_ptr = dtb_ptr + header.off_dt_strings;

    var offset: usize = 0;
    var current_node: [64]u8 = std.mem.zeroes([64]u8);
    var current_node_len: usize = 0;

    var address_cells: usize = 2;
    var size_cells: usize = 2;

    while (offset < header.size_dt_struct) {
        const token = readU32Be(struct_ptr + offset);
        offset += 4;

        switch (token) {
            0x00000001 => { // FDT_BEGIN_NODE
                const name_start = struct_ptr + offset;
                var len: usize = 0;
                while (name_start[len] != 0) : (len += 1) {}

                current_node_len = @min(len, current_node.len);
                @memcpy(current_node[0..current_node_len], name_start[0..current_node_len]);

                // Align up to 4 bytes boundary
                offset += (len + 1 + 3) & ~@as(usize, 3);
            },
            0x00000002 => { // FDT_END_NODE
                current_node_len = 0;
            },
            0x00000003 => { // FDT_PROP
                const prop_len = readU32Be(struct_ptr + offset);
                const name_off = readU32Be(struct_ptr + offset + 4);
                offset += 8;

                const val_ptr = struct_ptr + offset;
                const prop_name_ptr = strings_ptr + name_off;

                var prop_name_len: usize = 0;
                while (prop_name_ptr[prop_name_len] != 0) : (prop_name_len += 1) {}
                const prop_name = prop_name_ptr[0..prop_name_len];

                const node_name = current_node[0..current_node_len];

                if (std.mem.eql(u8, prop_name, "#address-cells") and prop_len >= 4) {
                    address_cells = readU32Be(val_ptr);
                } else if (std.mem.eql(u8, prop_name, "#size-cells") and prop_len >= 4) {
                    size_cells = readU32Be(val_ptr);
                } else if (std.mem.startsWith(u8, node_name, "memory") and std.mem.eql(u8, prop_name, "reg")) {
                    if (address_cells == 2 and prop_len >= 16) {
                        info.ram_base = readU64Be(val_ptr);
                        info.ram_size = if (size_cells == 2) readU64Be(val_ptr + 8) else readU32Be(val_ptr + 8);
                    } else if (address_cells == 1 and prop_len >= 8) {
                        info.ram_base = readU32Be(val_ptr);
                        info.ram_size = readU32Be(val_ptr + 4);
                    }
                } else if (std.mem.eql(u8, prop_name, "compatible")) {
                    const compat_val = val_ptr[0..prop_len];
                    if (containsString(compat_val, "ns16550a") or containsString(compat_val, "sifive,uart0") or containsString(compat_val, "snps,dw-apb-uart")) {
                        // Look up reg property if matched UART
                        info.uart_base = 0x10000000; // Standard fallback unless overridden
                    } else if (containsString(compat_val, "riscv,clint0") or containsString(compat_val, "sifive,clint0")) {
                        info.clint_base = 0x02000000;
                    } else if (containsString(compat_val, "riscv,plic0") or containsString(compat_val, "sifive,plic-1.0.0")) {
                        info.plic_base = 0x0c000000;
                    }
                } else if (std.mem.eql(u8, prop_name, "reg")) {
                    if (std.mem.indexOf(u8, node_name, "uart") != null or std.mem.indexOf(u8, node_name, "serial") != null) {
                        const base = if (address_cells == 2) readU64Be(val_ptr) else readU32Be(val_ptr);
                        info.uart_base = @truncate(base);
                    } else if (std.mem.indexOf(u8, node_name, "clint") != null) {
                        const base = if (address_cells == 2) readU64Be(val_ptr) else readU32Be(val_ptr);
                        info.clint_base = @truncate(base);
                    } else if (std.mem.indexOf(u8, node_name, "plic") != null) {
                        const base = if (address_cells == 2) readU64Be(val_ptr) else readU32Be(val_ptr);
                        info.plic_base = @truncate(base);
                    }
                }

                offset += (prop_len + 3) & ~@as(usize, 3);
            },
            0x00000004 => {}, // FDT_NOP
            0x00000009 => break, // FDT_END
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
