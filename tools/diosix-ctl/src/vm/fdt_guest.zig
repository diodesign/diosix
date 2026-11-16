// Child VM FDT `/chosen` Initrd, Memory Reservation, and Bootargs Injection.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fdt_patch = @import("fdt_patch.zig");
pub const bootargs_mod = @import("bootargs.zig");

pub const formatDnsSuffixFromResolv = bootargs_mod.formatDnsSuffixFromResolv;
pub const formatEffectiveBootargs = bootargs_mod.formatEffectiveBootargs;

pub const FDT_MAGIC_BE = fdt_patch.FDT_MAGIC_BE;
pub const FDT_ALIGN = fdt_patch.FDT_ALIGN;
pub const FDT_PROP_HEADER_SIZE = fdt_patch.FDT_PROP_HEADER_SIZE;
pub const FdtToken = fdt_patch.FdtToken;
pub const FDT_HEADER_SIZE: usize = 40;
pub const FDT_RSVMAP_OFFSET: usize = 48;
pub const FDT_RSVMAP_ENTRY_SIZE: usize = 16;
pub const HDR_MAGIC: usize = 0;
pub const HDR_TOTALSIZE: usize = 4;
pub const HDR_OFF_DT_STRUCT: usize = 8;
pub const HDR_OFF_DT_STRINGS: usize = 12;
pub const HDR_OFF_MEM_RSVMAP: usize = 16;
pub const HDR_VERSION: usize = 20;
pub const HDR_LAST_COMP_VERSION: usize = 24;
pub const HDR_SIZE_DT_STRINGS: usize = 32;
pub const HDR_SIZE_DT_STRUCT: usize = 36;

pub const MemReserveEntry = struct {
    address: u64,
    size: u64,
};

pub const ChosenConfig = struct {
    vcpus: usize = 1,
    is_shim_boot: bool = false,
    custom_cmdline: ?[]const u8 = null,
    ip_autoconfig: ?[]const u8 = null,
    initrd_start: u64 = 0,
    initrd_end: u64 = 0,
    reserved_regions: []const MemReserveEntry = &.{},
};

fn readBeU32(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off .. off + 4][0..4], .big);
}

fn readBeU64(buf: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, buf[off .. off + 8][0..8], .big);
}

fn writeBeU32(buf: []u8, off: usize, val: u32) void {
    std.mem.writeInt(u32, buf[off .. off + 4][0..4], val, .big);
}

fn writeBeU64(buf: []u8, off: usize, val: u64) void {
    std.mem.writeInt(u64, buf[off .. off + 8][0..8], val, .big);
}

fn findOrAppendString(
    allocator: std.mem.Allocator,
    strings: *std.ArrayList(u8),
    name: []const u8,
) !u32 {
    var pos: usize = 0;
    while (pos + name.len < strings.items.len) {
        if (std.mem.eql(u8, strings.items[pos .. pos + name.len], name) and
            strings.items[pos + name.len] == 0)
        {
            return @intCast(pos);
        }
        while (pos < strings.items.len and
            strings.items[pos] != 0) : (pos += 1)
        {}
        pos += 1;
    }
    const off: u32 = @intCast(strings.items.len);
    try strings.appendSlice(allocator, name);
    try strings.append(allocator, 0);
    return off;
}

fn appendPropU64(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    name_off: u32,
    val: u64,
) !void {
    var raw: [20]u8 = undefined;
    writeBeU32(&raw, 0, @backingInt(FdtToken.prop));
    writeBeU32(&raw, 4, 8);
    writeBeU32(&raw, 8, name_off);
    writeBeU64(&raw, 12, val);
    try buf.appendSlice(allocator, &raw);
}

fn appendPropString(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    name_off: u32,
    str: []const u8,
) !void {
    const str_with_nul = str.len + 1;
    const aligned_len = std.mem.alignForward(usize, str_with_nul, FDT_ALIGN);
    var hdr: [12]u8 = undefined;
    writeBeU32(&hdr, 0, @backingInt(FdtToken.prop));
    writeBeU32(&hdr, 4, @intCast(str_with_nul));
    writeBeU32(&hdr, 8, name_off);
    try buf.appendSlice(allocator, &hdr);
    try buf.appendSlice(allocator, str);
    var pad: usize = str.len;
    while (pad < aligned_len) : (pad += 1) {
        try buf.append(allocator, 0);
    }
}

fn appendRsvEntry(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    addr: u64,
    size: u64,
) !void {
    var raw: [FDT_RSVMAP_ENTRY_SIZE]u8 = undefined;
    writeBeU64(&raw, 0, addr);
    writeBeU64(&raw, 8, size);
    try buf.appendSlice(allocator, &raw);
}

/// Injects custom `bootargs`, `linux,initrd-start`, `linux,initrd-end`, and
/// `mem_rsvmap` entries into `dtb`, returning a newly allocated DTB slice.
pub fn injectChosenProperties(
    allocator: std.mem.Allocator,
    dtb: []const u8,
    cfg: ChosenConfig,
) ?[]u8 {
    if (dtb.len < FDT_HEADER_SIZE) return null;
    if (readBeU32(dtb, HDR_MAGIC) != FDT_MAGIC_BE) return null;

    const total_size: usize = readBeU32(dtb, HDR_TOTALSIZE);
    const off_struct: usize = readBeU32(dtb, HDR_OFF_DT_STRUCT);
    const size_struct: usize = readBeU32(dtb, HDR_SIZE_DT_STRUCT);
    const off_strings: usize = readBeU32(dtb, HDR_OFF_DT_STRINGS);
    const size_strings: usize = readBeU32(dtb, HDR_SIZE_DT_STRINGS);
    const off_rsvmap: usize = readBeU32(dtb, HDR_OFF_MEM_RSVMAP);

    if (total_size > dtb.len or off_struct + size_struct > dtb.len or
        off_strings + size_strings > dtb.len)
    {
        return null;
    }

    const struct_copy = allocator.dupe(
        u8,
        dtb[off_struct .. off_struct + size_struct],
    ) catch return null;
    defer allocator.free(struct_copy);

    var cursor: usize = 0;
    var depth: usize = 0;
    var in_chosen = false;
    var chosen_rel_insert: ?usize = null;

    while (cursor + FDT_ALIGN <= struct_copy.len) {
        const prop_tag_off = cursor;
        const tag: FdtToken = @fromBackingInt(
            @intCast(readBeU32(struct_copy, cursor)),
        );
        cursor += FDT_ALIGN;
        switch (tag) {
            .begin_node => {
                const nstart = cursor;
                while (cursor < struct_copy.len and struct_copy[cursor] != 0) {
                    cursor += 1;
                }
                const name = struct_copy[nstart..cursor];
                cursor = std.mem.alignForward(usize, cursor + 1, FDT_ALIGN);
                depth += 1;
                if (depth == 2 and std.mem.eql(u8, name, "chosen")) {
                    in_chosen = true;
                    chosen_rel_insert = cursor;
                }
            },
            .end_node => {
                if (in_chosen and depth == 2) in_chosen = false;
                depth -|= 1;
            },
            .prop => {
                if (cursor + FDT_PROP_HEADER_SIZE > struct_copy.len) {
                    return null;
                }
                const plen: usize = readBeU32(struct_copy, cursor);
                const noff: usize = readBeU32(struct_copy, cursor + 4);
                cursor += FDT_PROP_HEADER_SIZE;
                if (cursor + plen > struct_copy.len) return null;
                const next_cur = std.mem.alignForward(
                    usize,
                    cursor + plen,
                    FDT_ALIGN,
                );
                if (in_chosen and off_strings + noff < dtb.len) {
                    const pname = std.mem.sliceTo(
                        dtb[off_strings + noff ..],
                        0,
                    );
                    if (std.mem.eql(u8, pname, "bootargs") or
                        std.mem.eql(u8, pname, "linux,initrd-start") or
                        std.mem.eql(u8, pname, "linux,initrd-end"))
                    {
                        var nop_cur = prop_tag_off;
                        while (nop_cur + FDT_ALIGN <= next_cur) : (nop_cur +=
                            FDT_ALIGN)
                        {
                            writeBeU32(
                                struct_copy,
                                nop_cur,
                                @backingInt(FdtToken.nop),
                            );
                        }
                    }
                }
                cursor = next_cur;
            },
            .nop => {},
            .end => break,
            _ => return null,
        }
    }

    const rel_insert = chosen_rel_insert orelse return null;
    const bootargs = bootargs_mod.formatBootargs(allocator, .{
        .vcpus = cfg.vcpus,
        .is_shim_boot = cfg.is_shim_boot,
        .custom_cmdline = cfg.custom_cmdline,
        .ip_autoconfig = cfg.ip_autoconfig,
    }) catch return null;
    defer allocator.free(bootargs);

    var rsvmap = std.ArrayList(u8).empty;
    defer rsvmap.deinit(allocator);
    if (off_rsvmap >= FDT_HEADER_SIZE and off_rsvmap < off_struct) {
        var rpos = off_rsvmap;
        while (rpos + FDT_RSVMAP_ENTRY_SIZE <= off_struct and
            rpos + FDT_RSVMAP_ENTRY_SIZE <= dtb.len) : (rpos +=
            FDT_RSVMAP_ENTRY_SIZE)
        {
            const r_addr = readBeU64(dtb, rpos);
            const r_size = readBeU64(dtb, rpos + 8);
            if (r_addr == 0 and r_size == 0) break;
            appendRsvEntry(allocator, &rsvmap, r_addr, r_size) catch
                return null;
        }
    }
    for (cfg.reserved_regions) |reg| {
        if (reg.size == 0) continue;
        appendRsvEntry(allocator, &rsvmap, reg.address, reg.size) catch
            return null;
    }
    appendRsvEntry(allocator, &rsvmap, 0, 0) catch return null;

    var strings = std.ArrayList(u8).empty;
    defer strings.deinit(allocator);
    strings.appendSlice(
        allocator,
        dtb[off_strings .. off_strings + size_strings],
    ) catch return null;

    var inject = std.ArrayList(u8).empty;
    defer inject.deinit(allocator);

    const bootargs_noff = findOrAppendString(
        allocator,
        &strings,
        "bootargs",
    ) catch return null;
    appendPropString(allocator, &inject, bootargs_noff, bootargs) catch
        return null;

    if (cfg.initrd_end > cfg.initrd_start and cfg.initrd_start != 0) {
        const start_noff = findOrAppendString(
            allocator,
            &strings,
            "linux,initrd-start",
        ) catch return null;
        const end_noff = findOrAppendString(
            allocator,
            &strings,
            "linux,initrd-end",
        ) catch return null;
        appendPropU64(allocator, &inject, start_noff, cfg.initrd_start) catch
            return null;
        appendPropU64(allocator, &inject, end_noff, cfg.initrd_end) catch
            return null;
    }

    const new_off_struct = FDT_RSVMAP_OFFSET + rsvmap.items.len;
    const new_struct_size = struct_copy.len + inject.items.len;
    const new_off_strings = std.mem.alignForward(
        usize,
        new_off_struct + new_struct_size,
        FDT_ALIGN,
    );
    const new_total = std.mem.alignForward(
        usize,
        new_off_strings + strings.items.len,
        FDT_ALIGN,
    );

    const out = allocator.alloc(u8, new_total) catch return null;
    @memset(out, 0);
    @memcpy(out[0..FDT_HEADER_SIZE], dtb[0..FDT_HEADER_SIZE]);
    @memcpy(
        out[FDT_RSVMAP_OFFSET .. FDT_RSVMAP_OFFSET + rsvmap.items.len],
        rsvmap.items,
    );
    @memcpy(
        out[new_off_struct .. new_off_struct + rel_insert],
        struct_copy[0..rel_insert],
    );
    const after_prefix = new_off_struct + rel_insert;
    @memcpy(out[after_prefix .. after_prefix + inject.items.len], inject.items);
    const after_inject = after_prefix + inject.items.len;
    @memcpy(
        out[after_inject .. new_off_struct + new_struct_size],
        struct_copy[rel_insert..],
    );
    @memcpy(
        out[new_off_strings .. new_off_strings + strings.items.len],
        strings.items,
    );

    writeBeU32(out, HDR_TOTALSIZE, @intCast(new_total));
    writeBeU32(out, HDR_OFF_MEM_RSVMAP, @intCast(FDT_RSVMAP_OFFSET));
    writeBeU32(out, HDR_OFF_DT_STRUCT, @intCast(new_off_struct));
    writeBeU32(out, HDR_SIZE_DT_STRUCT, @intCast(new_struct_size));
    writeBeU32(out, HDR_OFF_DT_STRINGS, @intCast(new_off_strings));
    writeBeU32(out, HDR_SIZE_DT_STRINGS, @intCast(strings.items.len));
    return out;
}

test "vm/fdt_guest: injectChosenProperties and FDT mem_rsvmap serialization" {
    std.testing.refAllDecls(@This());
    _ = bootargs_mod;
    const testing = std.testing;
    const alloc = testing.allocator;

    var dtb: [128]u8 = @splat(0);
    const off_struct: u32 = 64;
    var s: usize = off_struct;
    writeBeU32(&dtb, s, @backingInt(FdtToken.begin_node));
    s += 8;
    writeBeU32(&dtb, s, @backingInt(FdtToken.begin_node));
    s += 4;
    @memcpy(dtb[s .. s + 6], "chosen");
    s = std.mem.alignForward(usize, s + 7, FDT_ALIGN);
    writeBeU32(&dtb, s, @backingInt(FdtToken.end_node));
    s += 4;
    writeBeU32(&dtb, s, @backingInt(FdtToken.end_node));
    s += 4;
    writeBeU32(&dtb, s, @backingInt(FdtToken.end));
    s += 4;

    writeBeU32(&dtb, HDR_MAGIC, FDT_MAGIC_BE);
    writeBeU32(&dtb, HDR_TOTALSIZE, @intCast(s));
    writeBeU32(&dtb, HDR_OFF_DT_STRUCT, off_struct);
    writeBeU32(&dtb, HDR_OFF_DT_STRINGS, @intCast(s));
    writeBeU32(&dtb, HDR_OFF_MEM_RSVMAP, 48);
    writeBeU32(&dtb, HDR_VERSION, 17);
    writeBeU32(&dtb, HDR_LAST_COMP_VERSION, 16);
    writeBeU32(&dtb, HDR_SIZE_DT_STRUCT, @intCast(s - off_struct));
    writeBeU32(&dtb, HDR_SIZE_DT_STRINGS, 0);

    const rsv = [_]MemReserveEntry{
        .{ .address = 0xe010_0000, .size = 0x1000 },
        .{ .address = 0xfc40_0000, .size = 0x0380_0000 },
    };
    const out = injectChosenProperties(alloc, &dtb, .{
        .vcpus = 2,
        .is_shim_boot = true,
        .initrd_start = 0x8400_0000,
        .initrd_end = 0x8410_0000,
        .reserved_regions = &rsv,
    }).?;
    defer alloc.free(out);
    try testing.expectEqual(@as(u64, 0xe010_0000), readBeU64(out, 48));
    try testing.expectEqual(@as(u64, 0xfc40_0000), readBeU64(out, 64));
    try testing.expectEqual(@as(u64, 0), readBeU64(out, 80));
    try testing.expect(
        std.mem.indexOf(u8, out, "linux,initrd-start") != null,
    );
}
