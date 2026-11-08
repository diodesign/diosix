// Diosix Guest VM Physical RAM Checkpoint & Restore Engine.
//
// Reads and restores non-zero 4 KiB physical RAM pages of a child VM via
// `/dev/diosix` `MAP_CHILD_MEM` (`client.mapChildMemory`), storing compact
// sparse page records (`[u64 offset, u32 length, data]`) in `<snap>.mem`.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const api = @import("../api.zig");
const common = @import("../common.zig");
const loader = @import("../loader.zig");

pub const SNAP_MEM_MAGIC = "DSXMEM01";
pub const SNAP_RECORD_HDR_LEN: usize = 12;
pub const PAGE_BYTES: usize = 4096;
pub const CHUNK_BYTES: usize = 2 * 1024 * 1024;
pub const GUEST_BASE_GPA: usize = 0xe000_0000;
pub const MAX_SNAPSHOT_RAM_BYTES: usize = 64 * 1024 * 1024;

pub const SavedVmMeta = struct {
    cid: usize = 0,
    vcpus: usize = 1,
    ram_mb: usize = 256,
    pcpu_quota_pct: u32 = 25,
    saved_pages: usize = 0,
};

pub fn isPageAllZero(page: []const u8) bool {
    for (page) |b| {
        if (b != 0) return false;
    }
    return true;
}

/// Resolves a target VM name or numeric CID to a child CID (`>= 2`) and
/// queries the hypervisor for its live configuration.
pub fn queryTargetVmMeta(
    client: *api.DiosixClient,
    target_str: []const u8,
) SavedVmMeta {
    var meta = SavedVmMeta{};
    meta.cid = common.parseCid(target_str) catch 0;

    if (common.readBinaryFile(
        common.GUEST_REGISTRY_PATH,
        common.MAX_MANIFEST_SIZE,
    )) |reg| {
        defer common.unmapBinaryFile(reg);
        var iter = common.GuestRegistryIter.init(reg);
        while (iter.next()) |entry| {
            if (common.matchTarget(
                target_str,
                meta.cid,
                entry.cid,
                entry.name,
            )) {
                meta.cid = entry.cid;
                meta.vcpus = entry.vcpus;
                const mb = common.parseMemorySizeMb(entry.ram);
                if (mb > 0) meta.ram_mb = mb;
                break;
            }
        }
    } else |_| {}

    if (meta.cid >= common.CID_FIRST_CHILD and client.dev_fd != null) {
        if (client.getInfo(meta.cid)) |info| {
            if (info.vcpus > 0) meta.vcpus = info.vcpus;
            if (info.self_ram_pages > 0) {
                meta.ram_mb = (info.self_ram_pages * 4) / 1024;
            }
            if (info.pcpu_quota_pct > 0) {
                meta.pcpu_quota_pct = info.pcpu_quota_pct;
            }
        } else |_| {}
    }
    return meta;
}

/// Flushes any modified guest-shim disk payload at `SHIM_PAYLOAD_GPA_OFFSET`
/// back to `disk_path` if the child VM has a persistent virtual disk attached.
pub fn syncChildDiskPayload(
    client: *api.DiosixClient,
    cid: usize,
    disk_path: []const u8,
) void {
    if (builtin.is_test or client.dev_fd == null or
        cid < common.CID_FIRST_CHILD or disk_path.len == 0)
    {
        return;
    }
    var z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const z_path = common.toPathZ(disk_path, &z_buf) orelse return;
    const fd_res = linux.open(
        z_path.ptr,
        .{ .ACCMODE = .WRONLY },
        common.PRIVATE_FILE_MODE,
    );
    const fd_signed: isize = @bitCast(fd_res);
    if (fd_signed < 0) return;
    const fd: i32 = @intCast(fd_signed);
    defer _ = linux.close(fd);

    var st: linux.Stat = undefined;
    if (@as(isize, @bitCast(linux.fstat(fd, &st))) < 0 or st.size <= 0) return;
    const sync_bytes: usize = @min(
        @as(usize, @intCast(st.size)),
        CHUNK_BYTES * 8,
    );
    const parent_gpa = loader.DEFAULT_PARENT_MAP_GPA;
    const payload_gpa = GUEST_BASE_GPA + loader.SHIM_PAYLOAD_GPA_OFFSET;
    var off: usize = 0;
    while (off < sync_bytes) : (off += CHUNK_BYTES) {
        const chunk_sz: usize = @min(CHUNK_BYTES, sync_bytes - off);
        const mapped = client.mapChildMemory(
            cid,
            payload_gpa + off,
            parent_gpa,
            chunk_sz,
            loader.MAP_CHILD_RW_FLAGS,
        ) catch break;
        defer client.unmapChildMemory(mapped, parent_gpa) catch {};
        _ = linux.write(fd, mapped.ptr, chunk_sz);
    }
}

/// Dumps non-zero 4 KiB pages of child `cid` into `mem_path`, returning the
/// count of saved pages. Safe no-op when `client.fd < 0` or in unit tests.
pub fn dumpChildRamPages(
    client: *api.DiosixClient,
    cid: usize,
    ram_mb: usize,
    mem_path: []const u8,
) usize {
    if (builtin.is_test or client.dev_fd == null or
        cid < common.CID_FIRST_CHILD)
    {
        return 0;
    }

    var z_buf: [common.MAX_PATH_LEN]u8 = undefined;
    const z_path = common.toPathZ(mem_path, &z_buf) orelse return 0;
    const fd_res = linux.open(
        z_path.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        common.PRIVATE_FILE_MODE,
    );
    const fd_signed: isize = @bitCast(fd_res);
    if (fd_signed < 0) return 0;
    const fd: i32 = @intCast(fd_signed);
    defer _ = linux.close(fd);

    _ = linux.write(fd, SNAP_MEM_MAGIC.ptr, SNAP_MEM_MAGIC.len);

    const total_bytes: usize = @min(
        ram_mb * 1024 * 1024,
        MAX_SNAPSHOT_RAM_BYTES,
    );
    const parent_gpa = loader.DEFAULT_PARENT_MAP_GPA;
    var saved_pages: usize = 0;
    var chunk_off: usize = 0;

    while (chunk_off < total_bytes) : (chunk_off += CHUNK_BYTES) {
        const chunk_sz: usize = @min(CHUNK_BYTES, total_bytes - chunk_off);
        const mapped = client.mapChildMemory(
            cid,
            GUEST_BASE_GPA + chunk_off,
            parent_gpa,
            chunk_sz,
            loader.MAP_CHILD_RW_FLAGS,
        ) catch break;
        defer client.unmapChildMemory(mapped, parent_gpa) catch {};

        var page_off: usize = 0;
        while (page_off + PAGE_BYTES <= chunk_sz) : (page_off += PAGE_BYTES) {
            const page = mapped[page_off .. page_off + PAGE_BYTES];
            if (!isPageAllZero(page)) {
                var rec_hdr: [SNAP_RECORD_HDR_LEN]u8 = undefined;
                std.mem.writeInt(
                    u64,
                    rec_hdr[0..8],
                    @intCast(chunk_off + page_off),
                    .little,
                );
                std.mem.writeInt(
                    u32,
                    rec_hdr[8..12],
                    @intCast(PAGE_BYTES),
                    .little,
                );
                _ = linux.write(fd, &rec_hdr, rec_hdr.len);
                _ = linux.write(fd, page.ptr, PAGE_BYTES);
                saved_pages += 1;
            }
        }
    }
    return saved_pages;
}

/// Restores saved physical RAM pages from `mem_path` into child `cid`.
pub fn restoreChildRamPages(
    client: *api.DiosixClient,
    cid: usize,
    mem_path: []const u8,
) usize {
    if (builtin.is_test or client.dev_fd == null or
        cid < common.CID_FIRST_CHILD)
    {
        return 0;
    }

    const data = common.readBinaryFile(
        mem_path,
        MAX_SNAPSHOT_RAM_BYTES,
    ) catch return 0;
    defer common.unmapBinaryFile(data);

    if (data.len < SNAP_MEM_MAGIC.len or
        !std.mem.eql(u8, data[0..SNAP_MEM_MAGIC.len], SNAP_MEM_MAGIC))
    {
        return 0;
    }

    const parent_gpa = loader.DEFAULT_PARENT_MAP_GPA;
    var pos: usize = SNAP_MEM_MAGIC.len;
    var restored_pages: usize = 0;

    while (pos + SNAP_RECORD_HDR_LEN <= data.len) {
        const gpa_off: usize = @intCast(
            std.mem.readInt(u64, data[pos..][0..8], .little),
        );
        const page_len: usize = @intCast(
            std.mem.readInt(u32, data[pos + 8 ..][0..4], .little),
        );
        pos += SNAP_RECORD_HDR_LEN;
        const next_pos = std.math.add(usize, pos, page_len) catch break;
        if (page_len != PAGE_BYTES or next_pos > data.len) break;
        if ((gpa_off & (PAGE_BYTES - 1)) != 0) {
            pos = next_pos;
            continue;
        }
        const target_gpa = std.math.add(usize, GUEST_BASE_GPA, gpa_off) catch
            break;

        if (client.mapChildMemory(
            cid,
            target_gpa,
            parent_gpa,
            PAGE_BYTES,
            loader.MAP_CHILD_RW_FLAGS,
        )) |mapped| {
            defer client.unmapChildMemory(mapped, parent_gpa) catch {};
            @memcpy(mapped[0..PAGE_BYTES], data[pos..next_pos]);
            restored_pages += 1;
        } else |_| {}
        pos = next_pos;
    }
    return restored_pages;
}

/// Parses `cid`, `vcpus`, and `pcpu_quota_pct` from a `.snap` TOML buffer.
pub fn parseSnapMetadata(content: []const u8) SavedVmMeta {
    const SnapKey = enum { cid, vcpus, ram_mb, pcpu_quota_pct, saved_pages };
    var meta = SavedVmMeta{};
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = common.trimAscii(raw);
        if (line.len == 0 or line[0] == '#' or line[0] == '[') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = common.trimAscii(line[0..eq]);
        const val = common.unquoteToml(line[eq + 1 ..]);
        if (std.meta.stringToEnum(SnapKey, key)) |k| switch (k) {
            .cid => meta.cid = std.fmt.parseInt(usize, val, 10) catch 0,
            .vcpus => meta.vcpus = std.fmt.parseInt(usize, val, 10) catch 1,
            .ram_mb => meta.ram_mb = std.fmt.parseInt(usize, val, 10) catch 256,
            .pcpu_quota_pct => {
                meta.pcpu_quota_pct =
                    std.fmt.parseInt(u32, val, 10) catch 25;
            },
            .saved_pages => {
                meta.saved_pages = std.fmt.parseInt(usize, val, 10) catch 0;
            },
        };
    }
    return meta;
}

test "snapshot/memory: isPageAllZero and parseSnapMetadata" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    var page: [PAGE_BYTES]u8 = @splat(0);
    try testing.expect(isPageAllZero(&page));
    page[123] = 1;
    try testing.expect(!isPageAllZero(&page));

    const sample =
        \\[snapshot]
        \\cid = 3
        \\vcpus = 4
        \\ram_mb = 512
        \\pcpu_quota_pct = 40
        \\saved_pages = 18
    ;
    const meta = parseSnapMetadata(sample);
    try testing.expectEqual(@as(usize, 3), meta.cid);
    try testing.expectEqual(@as(usize, 4), meta.vcpus);
    try testing.expectEqual(@as(usize, 512), meta.ram_mb);
    try testing.expectEqual(@as(u32, 40), meta.pcpu_quota_pct);
    try testing.expectEqual(@as(usize, 18), meta.saved_pages);
}
