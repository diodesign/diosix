// Child VM Flattened Device Tree (FDT) Sanitization & Patching.
//
// Strips host-only MMIO nodes, caps `/cpus` to the guest vCPU quota, and
// patches `/memory` `reg` to match the child VM's Stage-2 GPA and RAM size.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const common = @import("../common.zig");
const sysconfig = @import("../sysconfig.zig");

pub const FDT_MAGIC_BE: u32 = 0xd00dfeed;
pub const FDT_OFF_DT_STRUCT: usize = 8;
pub const FDT_OFF_DT_STRINGS: usize = 12;
pub const FDT_MIN_HEADER_SIZE: usize = 32;
pub const FDT_ALIGN: usize = 4;
pub const FDT_PROP_HEADER_SIZE: usize = 8;

pub const FdtToken = enum(u32) {
    begin_node = 1,
    end_node = 2,
    prop = 3,
    nop = 4,
    end = 9,
    _,
};

const HOST_FDT_PREFIXES = [_][]const u8{
    "virtio_mmio@",  "pci@",  "pcie@",  "serial@",
    "uart@",         "rtc@",  "flash@", "fw-cfg@",
    "platform-bus@", "plic@", "clint@", "aliases",
    "cpu-map",
};

fn readBeU32(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off .. off + 4][0..4], .big);
}

fn writeBeU32(buf: []u8, off: usize, val: u32) void {
    std.mem.writeInt(u32, buf[off .. off + 4][0..4], val, .big);
}

fn writeBeU64(buf: []u8, off: usize, val: u64) void {
    std.mem.writeInt(u64, buf[off .. off + 8][0..8], val, .big);
}

fn nopFdtRange(dtb: []u8, start_off: usize, end_off: usize) void {
    const limit = @min(end_off, dtb.len);
    var cur = start_off;
    const nop_val = @backingInt(FdtToken.nop);
    while (cur + FDT_ALIGN <= limit) : (cur += FDT_ALIGN) {
        writeBeU32(dtb, cur, nop_val);
    }
}

fn scanNopSubtree(dtb: []const u8, start_off: usize) usize {
    var depth: usize = 1;
    var scan_off = start_off;
    while (scan_off + FDT_ALIGN <= dtb.len and depth > 0) {
        const sub_tag: FdtToken = @fromBackingInt(
            @intCast(readBeU32(dtb, scan_off)),
        );
        scan_off += FDT_ALIGN;
        switch (sub_tag) {
            .begin_node => {
                while (scan_off < dtb.len and
                    dtb[scan_off] != 0) : (scan_off += 1)
                {}
                scan_off = std.mem.alignForward(usize, scan_off + 1, FDT_ALIGN);
                depth += 1;
            },
            .end_node => depth -= 1,
            .prop => {
                if (scan_off + FDT_PROP_HEADER_SIZE > dtb.len) break;
                const prop_len: usize = readBeU32(dtb, scan_off);
                const step = std.math.add(
                    usize,
                    FDT_PROP_HEADER_SIZE,
                    prop_len,
                ) catch break;
                scan_off = std.math.add(usize, scan_off, step) catch break;
                scan_off = std.mem.alignForward(usize, scan_off, FDT_ALIGN);
            },
            .nop => {},
            .end => break,
            _ => break,
        }
    }
    return @min(scan_off, dtb.len);
}

/// Reads the host FDT (`/sys/firmware/fdt`) or a custom `--dtb` file into a
/// writable anonymous mapping ready for `patchChildDtb`.
pub fn loadHostOrCustomDtb(dtb_path: ?[]const u8) []u8 {
    const dtb_src = dtb_path orelse sysconfig.SYS_FIRMWARE_FDT_PATH;
    return common.readBinaryFile(dtb_src, common.MAX_DTB_FILE_SIZE) catch
        @constCast(&[_]u8{});
}

fn patchClonedCpuBody(
    body: []u8,
    dtb: []const u8,
    off_dt_strings: usize,
    cpu_idx: usize,
) void {
    var off: usize = 0;
    var depth: usize = 1;
    var ph_sub: u32 = 0;
    while (off + FDT_ALIGN <= body.len and depth > 0) {
        const tag: FdtToken = @fromBackingInt(@intCast(readBeU32(body, off)));
        off += FDT_ALIGN;
        switch (tag) {
            .begin_node => {
                while (off < body.len and body[off] != 0) : (off += 1) {}
                off = std.mem.alignForward(usize, off + 1, FDT_ALIGN);
                depth += 1;
            },
            .end_node => depth -= 1,
            .prop => {
                if (off + FDT_PROP_HEADER_SIZE > body.len) break;
                const plen: usize = readBeU32(body, off);
                const noff: usize = readBeU32(body, off + 4);
                off += FDT_PROP_HEADER_SIZE;
                if (off + plen > body.len) break;
                const spos = off_dt_strings +| noff;
                if (spos < dtb.len) {
                    const s = std.mem.sliceTo(dtb[spos..], 0);
                    if (depth == 1 and std.mem.eql(u8, s, "reg")) {
                        if (plen >= 8) {
                            writeBeU64(body, off, cpu_idx);
                        } else if (plen >= 4) {
                            writeBeU32(body, off, @truncate(cpu_idx));
                        }
                    } else if (plen == 4 and
                        (std.mem.eql(u8, s, "phandle") or
                            std.mem.eql(u8, s, "linux,phandle")))
                    {
                        const new_ph: u32 = 0x4000 +
                            @as(u32, @truncate(cpu_idx * 2)) + ph_sub;
                        writeBeU32(body, off, new_ph);
                        ph_sub += 1;
                    }
                }
                off = std.mem.alignForward(usize, off + plen, FDT_ALIGN);
            },
            .nop => {},
            else => break,
        }
    }
}

/// Expands `/cpus/cpu@N` nodes in `dtb` when `vcpus` exceeds the number of
/// CPU nodes present in the host template FDT (up to 4096 vCPUs).
pub fn expandChildDtbCpuNodes(
    allocator: std.mem.Allocator,
    dtb: []const u8,
    vcpus: usize,
) ?[]u8 {
    if (vcpus <= 1 or dtb.len < FDT_MIN_HEADER_SIZE) return null;
    if (readBeU32(dtb, 0) != FDT_MAGIC_BE) return null;
    const off_struct = readBeU32(dtb, FDT_OFF_DT_STRUCT);
    const off_strings = readBeU32(dtb, FDT_OFF_DT_STRINGS);
    if (off_struct >= dtb.len or off_strings >= dtb.len) return null;

    var off: usize = off_struct;
    var depth: usize = 0;
    var cpus_depth: usize = 0;
    var cpu0_body_start: usize = 0;
    var cpu0_end: usize = 0;
    var cpus_end_off: usize = 0;
    var existing_cpus: usize = 0;

    while (off + FDT_ALIGN <= dtb.len) {
        const tag_off = off;
        const tag: FdtToken = @fromBackingInt(@intCast(readBeU32(dtb, off)));
        off += FDT_ALIGN;
        switch (tag) {
            .begin_node => {
                const nstart = off;
                while (off < dtb.len and dtb[off] != 0) : (off += 1) {}
                const name = dtb[nstart..off];
                off = std.mem.alignForward(usize, off + 1, FDT_ALIGN);
                depth += 1;
                if (depth == 2 and std.mem.eql(u8, name, "cpus")) {
                    cpus_depth = depth;
                } else if (cpus_depth > 0 and depth == cpus_depth + 1 and
                    std.mem.startsWith(u8, name, "cpu@"))
                {
                    existing_cpus += 1;
                    const sub_end = scanNopSubtree(dtb, off);
                    if (cpu0_end == 0) {
                        cpu0_body_start = off;
                        cpu0_end = sub_end;
                    }
                    off = sub_end;
                    depth -= 1;
                }
            },
            .end_node => {
                if (cpus_depth > 0 and depth == cpus_depth) {
                    cpus_end_off = tag_off;
                    cpus_depth = 0;
                }
                depth -|= 1;
            },
            .prop => {
                if (off + FDT_PROP_HEADER_SIZE > dtb.len) break;
                const plen: usize = readBeU32(dtb, off);
                off = std.mem.alignForward(
                    usize,
                    off + FDT_PROP_HEADER_SIZE + plen,
                    FDT_ALIGN,
                );
            },
            .nop => {},
            else => break,
        }
    }

    const target_vcpus = @min(vcpus, 4096);
    if (target_vcpus <= existing_cpus or cpu0_end <= cpu0_body_start or
        cpus_end_off == 0 or off_strings < cpus_end_off)
    {
        return null;
    }

    const body_tpl = dtb[cpu0_body_start..cpu0_end];
    var extra = std.ArrayList(u8).empty;
    defer extra.deinit(allocator);

    for (existing_cpus..target_vcpus) |idx| {
        var hdr_buf: [20]u8 = @splat(0);
        writeBeU32(&hdr_buf, 0, @backingInt(FdtToken.begin_node));
        const name_s = std.fmt.bufPrint(
            hdr_buf[4..19],
            "cpu@{x}",
            .{idx},
        ) catch return null;
        const hdr_len = std.mem.alignForward(
            usize,
            4 + name_s.len + 1,
            FDT_ALIGN,
        );
        extra.appendSlice(allocator, hdr_buf[0..hdr_len]) catch return null;
        const bstart = extra.items.len;
        extra.appendSlice(allocator, body_tpl) catch return null;
        patchClonedCpuBody(
            extra.items[bstart..],
            dtb,
            off_strings,
            idx,
        );
    }

    const add_len: u32 = @intCast(extra.items.len);
    const out = allocator.alloc(u8, dtb.len + extra.items.len) catch
        return null;
    @memcpy(out[0..cpus_end_off], dtb[0..cpus_end_off]);
    @memcpy(
        out[cpus_end_off .. cpus_end_off + extra.items.len],
        extra.items,
    );
    @memcpy(
        out[cpus_end_off + extra.items.len ..],
        dtb[cpus_end_off..],
    );
    writeBeU32(out, 4, readBeU32(dtb, 4) + add_len);
    writeBeU32(out, FDT_OFF_DT_STRINGS, off_strings + add_len);
    if (out.len >= 40) {
        writeBeU32(out, 36, readBeU32(dtb, 36) + add_len);
    }
    return out;
}

pub fn patchChildDtb(
    dtb: []u8,
    base_gpa: u64,
    ram_bytes: u64,
    vcpus: usize,
) void {
    if (dtb.len < FDT_MIN_HEADER_SIZE) return;
    if (readBeU32(dtb, 0) != FDT_MAGIC_BE) return;

    const off_dt_struct = readBeU32(dtb, FDT_OFF_DT_STRUCT);
    const off_dt_strings = readBeU32(dtb, FDT_OFF_DT_STRINGS);
    if (off_dt_struct >= dtb.len or off_dt_strings >= dtb.len) return;

    var offset: usize = off_dt_struct;
    var in_memory_node = false;

    while (offset + FDT_ALIGN <= dtb.len) {
        const node_tag_offset = offset;
        const tag: FdtToken = @fromBackingInt(@intCast(readBeU32(dtb, offset)));
        offset += FDT_ALIGN;

        switch (tag) {
            .begin_node => {
                const name_start = offset;
                while (offset < dtb.len and dtb[offset] != 0) : (offset += 1) {}
                const name = dtb[name_start..offset];
                offset = std.mem.alignForward(usize, offset + 1, FDT_ALIGN);

                in_memory_node = std.mem.startsWith(u8, name, "memory@") or
                    std.mem.eql(u8, name, "memory");
                if (std.mem.startsWith(u8, name, "memory@") and
                    name.len == "memory@80000000".len)
                {
                    _ = std.fmt.bufPrint(
                        name[7..15],
                        "{x:0>8}",
                        .{@as(u32, @truncate(base_gpa))},
                    ) catch {};
                }

                var should_nop_node = false;
                for (HOST_FDT_PREFIXES) |prefix| {
                    if (std.mem.startsWith(u8, name, prefix) or
                        std.mem.eql(u8, name, prefix))
                    {
                        should_nop_node = true;
                        break;
                    }
                }
                if (!should_nop_node and std.mem.startsWith(u8, name, "cpu@")) {
                    const cpu_str = name[4..];
                    const cpu_idx = std.fmt.parseInt(usize, cpu_str, 16) catch
                        (std.fmt.parseInt(usize, cpu_str, 10) catch 0);
                    if (cpu_idx >= vcpus) should_nop_node = true;
                }

                if (should_nop_node) {
                    const nop_end = scanNopSubtree(dtb, offset);
                    nopFdtRange(dtb, node_tag_offset, nop_end);
                    offset = nop_end;
                }
            },
            .end_node => in_memory_node = false,
            .prop => {
                if (offset + FDT_PROP_HEADER_SIZE > dtb.len) break;
                const prop_len: usize = readBeU32(dtb, offset);
                const name_off: usize = readBeU32(dtb, offset + 4);
                offset += FDT_PROP_HEADER_SIZE;

                const prop_end = std.math.add(usize, offset, prop_len) catch
                    break;
                if (prop_end > dtb.len) break;

                const str_pos = std.math.add(
                    usize,
                    off_dt_strings,
                    name_off,
                ) catch break;
                if (str_pos < dtb.len) {
                    const str_slice = dtb[str_pos..];
                    var str_len: usize = 0;
                    while (str_len < str_slice.len and
                        str_slice[str_len] != 0) : (str_len += 1)
                    {}
                    const prop_name = str_slice[0..str_len];

                    const DtbProperty = enum {
                        reg,
                        @"stdout-path",
                        bootargs,
                    };
                    if (std.meta.stringToEnum(DtbProperty, prop_name)) |prop| {
                        switch (prop) {
                            .reg => if (in_memory_node) {
                                if (prop_len >= 16) {
                                    writeBeU64(dtb, offset, base_gpa);
                                    writeBeU64(dtb, offset + 8, ram_bytes);
                                } else if (prop_len >= 8) {
                                    writeBeU32(
                                        dtb,
                                        offset,
                                        @truncate(base_gpa),
                                    );
                                    writeBeU32(
                                        dtb,
                                        offset + 4,
                                        @truncate(ram_bytes),
                                    );
                                }
                            },
                            .@"stdout-path" => {
                                const end_aligned = std.mem.alignForward(
                                    usize,
                                    prop_end,
                                    FDT_ALIGN,
                                );
                                nopFdtRange(dtb, node_tag_offset, end_aligned);
                            },
                            .bootargs => {
                                var args_buf: [256]u8 = undefined;
                                const child_args = std.fmt.bufPrint(
                                    &args_buf,
                                    "console=hvc0 earlycon=sbi " ++
                                        "rootfstype=ramfs cma=0M no4lvl " ++
                                        "maxcpus={d} lpj=50000 " ++
                                        "rcupdate.rcu_cpu_stall_suppress=1 " ++
                                        "unaligned_scalar_speed=fast",
                                    .{@max(@as(usize, 1), vcpus)},
                                ) catch
                                    "console=hvc0 earlycon=sbi " ++
                                        "rootfstype=ramfs cma=0M no4lvl";
                                if (prop_len > child_args.len) {
                                    const prop_slice =
                                        dtb[offset .. offset + prop_len];
                                    @memset(prop_slice, 0);
                                    @memcpy(
                                        prop_slice[0..child_args.len],
                                        child_args,
                                    );
                                }
                            },
                        }
                    }
                }

                offset = std.mem.alignForward(usize, prop_end, FDT_ALIGN);
            },
            .nop => {},
            .end => break,
            _ => break,
        }
    }
}

test "vm/fdt_patch: patchChildDtb handles malformed FDT headers safely" {
    std.testing.refAllDecls(@This());
    const malformed_dtb_len: usize = 64;
    var bad_dtb: [malformed_dtb_len]u8 = @splat(0);
    patchChildDtb(&bad_dtb, 0x8000_0000, 0x1000_0000, 1);

    std.mem.writeInt(u32, bad_dtb[0..4], FDT_MAGIC_BE, .big);
    std.mem.writeInt(u32, bad_dtb[8..12], 32, .big);
    std.mem.writeInt(u32, bad_dtb[12..16], 48, .big);
    std.mem.writeInt(
        u32,
        bad_dtb[32..36],
        @backingInt(FdtToken.prop),
        .big,
    );
    std.mem.writeInt(u32, bad_dtb[36..40], 0xffff_ffff, .big);
    patchChildDtb(&bad_dtb, 0x8000_0000, 0x1000_0000, 1);
}
