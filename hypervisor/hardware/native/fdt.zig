// Freestanding Zero-Allocation Flattened DeviceTree (FDT/DTB) Parser.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const FDT_MAGIC: u32 = 0xd00dfeed;
pub const FDT_HEADER_SIZE: u32 = 40;
pub const MAX_FDT_SIZE: u32 = 16 * 1024 * 1024; // 16 MiB max reasonable DTB
pub const MAX_FDT_DEPTH: usize = 16;

// Standard FDT node and property tokens.
pub const FDT_BEGIN_NODE: u32 = 0x00000001;
pub const FDT_END_NODE: u32 = 0x00000002;
pub const FDT_PROP: u32 = 0x00000003;
pub const FDT_NOP: u32 = 0x00000004;
pub const FDT_END: u32 = 0x00000009;

// Default platform addresses.
pub const DEFAULT_RAM_BASE: u64 = 0x80000000;
pub const DEFAULT_RAM_SIZE: u64 = 512 * 1024 * 1024; // 512 MiB default fallback
pub const DEFAULT_UART_BASE: usize = 0x10000000;
pub const DEFAULT_CLINT_BASE: usize = 0x02000000;
pub const DEFAULT_PLIC_BASE: usize = 0x0c000000;

pub const FdtHeader = struct {
    pub const OFF_MAGIC: usize = 0;
    pub const OFF_TOTALSIZE: usize = 4;
    pub const OFF_DT_STRUCT: usize = 8;
    pub const OFF_DT_STRINGS: usize = 12;
    pub const OFF_MEM_RSVMAP: usize = 16;
    pub const OFF_VERSION: usize = 20;
    pub const OFF_LAST_COMP_VERSION: usize = 24;
    pub const OFF_BOOT_CPUID_PHYS: usize = 28;
    pub const OFF_SIZE_DT_STRINGS: usize = 32;
    pub const OFF_SIZE_DT_STRUCT: usize = 36;

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

pub const SystemHardwareInfo = struct {
    ram_base: u64 = DEFAULT_RAM_BASE,
    ram_size: u64 = DEFAULT_RAM_SIZE,
    uart_base: ?usize = null,
    clint_base: ?usize = null,
    plic_base: ?usize = null,
};

const PropName = enum {
    @"#address-cells",
    @"#size-cells",
    reg,
    compatible,
};

/// Read 32-bit big-endian integer from unaligned memory.
inline fn readU32Be(ptr: [*]const u8) u32 {
    return (@as(u32, ptr[0]) << 24) |
        (@as(u32, ptr[1]) << 16) |
        (@as(u32, ptr[2]) << 8) |
        @as(u32, ptr[3]);
}

/// Read 64-bit big-endian integer from unaligned memory.
inline fn readU64Be(ptr: [*]const u8) u64 {
    return (@as(u64, readU32Be(ptr)) << 32) | @as(u64, readU32Be(ptr + 4));
}

/// Parse FDT header from raw memory pointer with comprehensive bounds checking.
pub fn parseHeader(dtb_ptr: [*]const u8) FdtError!FdtHeader {
    const magic = readU32Be(dtb_ptr + FdtHeader.OFF_MAGIC);
    if (magic != FDT_MAGIC) return FdtError.BadMagic;

    const totalsize = readU32Be(dtb_ptr + FdtHeader.OFF_TOTALSIZE);
    if (totalsize < FDT_HEADER_SIZE or totalsize > MAX_FDT_SIZE) {
        return FdtError.TruncatedHeader;
    }

    const off_dt_struct = readU32Be(dtb_ptr + FdtHeader.OFF_DT_STRUCT);
    const off_dt_strings = readU32Be(dtb_ptr + FdtHeader.OFF_DT_STRINGS);
    const off_mem_rsvmap = readU32Be(dtb_ptr + FdtHeader.OFF_MEM_RSVMAP);
    const version = readU32Be(dtb_ptr + FdtHeader.OFF_VERSION);
    const last_comp_version = readU32Be(
        dtb_ptr + FdtHeader.OFF_LAST_COMP_VERSION,
    );
    const boot_cpuid_phys = readU32Be(dtb_ptr + FdtHeader.OFF_BOOT_CPUID_PHYS);
    const size_dt_strings = readU32Be(dtb_ptr + FdtHeader.OFF_SIZE_DT_STRINGS);
    const size_dt_struct = readU32Be(dtb_ptr + FdtHeader.OFF_SIZE_DT_STRUCT);

    const end_struct = std.math.add(u32, off_dt_struct, size_dt_struct) catch
        return FdtError.CorruptStructure;
    const end_strings = std.math.add(u32, off_dt_strings, size_dt_strings) catch
        return FdtError.CorruptStructure;
    if (end_struct > totalsize or
        end_strings > totalsize or
        off_mem_rsvmap > totalsize)
    {
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

fn readCellBase(val_ptr: [*]const u8, addr_cells: usize, prop_len: u32) u64 {
    if (addr_cells == 2 and prop_len >= 8) return readU64Be(val_ptr);
    if (prop_len >= 4) return readU32Be(val_ptr);
    return 0;
}

/// Perform zero-allocation FDT scan to extract system RAM, UART, CLINT, and
/// PLIC MMIO bases. Defensively bounds-checked against malformed device trees.
pub fn parseHardwareInfo(dtb_ptr: [*]const u8) FdtError!SystemHardwareInfo {
    const header = try parseHeader(dtb_ptr);

    var info = SystemHardwareInfo{};
    const struct_ptr = dtb_ptr + header.off_dt_struct;
    const strings_ptr = dtb_ptr + header.off_dt_strings;

    var offset: usize = 0;
    var current_node: []const u8 = "";

    var addr_cells_stack: [MAX_FDT_DEPTH]usize = @splat(2);
    var size_cells_stack: [MAX_FDT_DEPTH]usize = @splat(2);
    var depth: usize = 0;

    while (offset + 4 <= header.size_dt_struct) {
        const token = readU32Be(struct_ptr + offset);
        offset += 4;

        switch (token) {
            FDT_BEGIN_NODE => {
                if (depth >= MAX_FDT_DEPTH) {
                    return FdtError.CorruptStructure;
                }
                if (depth == 0) {
                    addr_cells_stack[0] = 2;
                    size_cells_stack[0] = 2;
                } else {
                    addr_cells_stack[depth] = addr_cells_stack[depth - 1];
                    size_cells_stack[depth] = size_cells_stack[depth - 1];
                }
                depth += 1;

                const name_start = struct_ptr + offset;
                var len: usize = 0;
                while (offset + len < header.size_dt_struct and
                    name_start[len] != 0) : (len += 1)
                {}
                if (offset + len >= header.size_dt_struct) {
                    return FdtError.CorruptStructure;
                }

                current_node = name_start[0..len];

                const aligned_len = std.mem.alignForward(
                    usize,
                    len + 1,
                    @sizeOf(u32),
                );
                offset = std.math.add(usize, offset, aligned_len) catch
                    return FdtError.CorruptStructure;
            },
            FDT_END_NODE => {
                if (depth == 0) return FdtError.CorruptStructure;
                depth -= 1;
                current_node = "";
            },
            FDT_PROP => {
                if (depth == 0 or offset + 8 > header.size_dt_struct) {
                    return FdtError.CorruptStructure;
                }
                const prop_len = readU32Be(struct_ptr + offset);
                const name_off = readU32Be(struct_ptr + offset + 4);
                offset += 8;

                if (prop_len > header.size_dt_struct - offset or
                    name_off >= header.size_dt_strings)
                {
                    return FdtError.CorruptStructure;
                }

                const val_ptr = struct_ptr + offset;
                const prop_name_ptr = strings_ptr + name_off;

                var pname_len: usize = 0;
                while (name_off + pname_len < header.size_dt_strings and
                    prop_name_ptr[pname_len] != 0) : (pname_len += 1)
                {}
                if (name_off + pname_len >= header.size_dt_strings) {
                    return FdtError.CorruptStructure;
                }
                const prop_name = prop_name_ptr[0..pname_len];
                const node_name = current_node;

                const cur_idx = depth - 1;
                const parent_idx = if (depth >= 2) depth - 2 else 0;
                const address_cells = addr_cells_stack[parent_idx];
                const size_cells = size_cells_stack[parent_idx];

                if (std.meta.stringToEnum(PropName, prop_name)) |prop| {
                    switch (prop) {
                        .@"#address-cells" => {
                            if (prop_len >= 4) {
                                const cells = readU32Be(val_ptr);
                                if (cells <= 2) {
                                    addr_cells_stack[cur_idx] = cells;
                                }
                            }
                        },
                        .@"#size-cells" => {
                            if (prop_len >= 4) {
                                const cells = readU32Be(val_ptr);
                                if (cells <= 2) {
                                    size_cells_stack[cur_idx] = cells;
                                }
                            }
                        },
                        .reg => {
                            if (std.mem.startsWith(u8, node_name, "memory")) {
                                if (address_cells == 2) {
                                    if (size_cells == 2 and prop_len >= 16) {
                                        info.ram_base = readU64Be(val_ptr);
                                        info.ram_size = readU64Be(val_ptr + 8);
                                    } else if (size_cells == 1 and
                                        prop_len >= 12)
                                    {
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
                            } else {
                                const base = readCellBase(
                                    val_ptr,
                                    address_cells,
                                    prop_len,
                                );
                                if (base != 0) {
                                    if (containsString(node_name, "uart") or
                                        containsString(node_name, "serial"))
                                    {
                                        info.uart_base = @truncate(base);
                                    } else if (containsString(
                                        node_name,
                                        "clint",
                                    )) {
                                        info.clint_base = @truncate(base);
                                    } else if (containsString(
                                        node_name,
                                        "plic",
                                    )) {
                                        info.plic_base = @truncate(base);
                                    }
                                }
                            }
                        },
                        .compatible => {
                            const compat_val = val_ptr[0..prop_len];
                            if (containsString(compat_val, "ns16550a") or
                                containsString(compat_val, "sifive,uart0") or
                                containsString(compat_val, "snps,dw-apb-uart"))
                            {
                                if (info.uart_base == null) {
                                    info.uart_base = DEFAULT_UART_BASE;
                                }
                            } else if (containsString(
                                compat_val,
                                "riscv,clint0",
                            ) or
                                containsString(compat_val, "sifive,clint0"))
                            {
                                if (info.clint_base == null) {
                                    info.clint_base = DEFAULT_CLINT_BASE;
                                }
                            } else if (containsString(
                                compat_val,
                                "riscv,plic0",
                            ) or
                                containsString(compat_val, "sifive,plic-1.0.0"))
                            {
                                if (info.plic_base == null) {
                                    info.plic_base = DEFAULT_PLIC_BASE;
                                }
                            }
                        },
                    }
                }

                const aligned_prop_len = std.mem.alignForward(
                    usize,
                    prop_len,
                    @sizeOf(u32),
                );
                offset = std.math.add(usize, offset, aligned_prop_len) catch
                    return FdtError.CorruptStructure;
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

test {
    std.testing.refAllDecls(@This());
    _ = @import("fdt/tests.zig");
}
