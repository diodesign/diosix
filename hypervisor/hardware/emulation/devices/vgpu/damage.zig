// VirtIO-GPU Dirty-Rect Damage Ring, Zero-Copy Validation & Cursor Extractor
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const proto = @import("protocol.zig");
const scanout = @import("scanout.zig");
const vgpu_mod = @import("../vgpu.zig");

const VirtioGpu = vgpu_mod.VirtioGpu;
const VirtioGpuRect = proto.VirtioGpuRect;
const VirtioGpuResource = proto.VirtioGpuResource;

pub const DAMAGE_RING_LEN: usize = 16;
const PAGE_SIZE: usize = 4096;
const PAGE_MASK: usize = PAGE_SIZE - 1;
pub const CURSOR_PIXELS: usize =
    proto.CURSOR_DIMENSION * proto.CURSOR_DIMENSION;

pub const DamageEntry = struct {
    seq: u64 = 0,
    x0: u32 = 0,
    y0: u32 = 0,
    x1: u32 = 0,
    y1: u32 = 0,
};

pub const CursorMeta = struct {
    visible: bool = false,
    width: u32 = 0,
    height: u32 = 0,
};

/// Bounded ring tracking dirty scanout rectangles across VirtIO-GPU updates.
pub const DamageRing = struct {
    entries: [DAMAGE_RING_LEN]DamageEntry = @splat(.{}),
    head: usize = 0,
    oldest_seq: u64 = 0,

    pub fn pushRect(self: *DamageRing, seq: u64, r: VirtioGpuRect) void {
        if (seq == 0 or r.width == 0 or r.height == 0) return;
        const evicted = self.entries[self.head].seq;
        if (evicted > self.oldest_seq) {
            self.oldest_seq = evicted;
        }
        self.entries[self.head] = .{
            .seq = seq,
            .x0 = r.x,
            .y0 = r.y,
            .x1 = r.x +| r.width,
            .y1 = r.y +| r.height,
        };
        self.head = (self.head + 1) % DAMAGE_RING_LEN;
    }

    /// Pushes bounding rectangles for both previous and new 64x64 cursor boxes.
    pub fn pushCursorMotion(
        self: *DamageRing,
        seq: u64,
        old_x: i64,
        old_y: i64,
        new_x: i64,
        new_y: i64,
    ) void {
        self.pushRect(seq, clampCursorRect(old_x, old_y));
        if (old_x != new_x or old_y != new_y) {
            self.pushRect(seq, clampCursorRect(new_x, new_y));
        }
    }

    /// Computes the union of dirty rectangles strictly newer than `client_seq`.
    pub fn computeDirtyRectSince(
        self: *const DamageRing,
        client_seq: u64,
        current_seq: u64,
        disp_w: u32,
        disp_h: u32,
    ) VirtioGpuRect {
        if (disp_w == 0 or disp_h == 0 or current_seq == client_seq) {
            return .{};
        }
        const full = VirtioGpuRect{
            .x = 0,
            .y = 0,
            .width = disp_w,
            .height = disp_h,
        };
        if (client_seq == 0 or client_seq < self.oldest_seq) {
            return full;
        }

        var min_x: u32 = disp_w;
        var min_y: u32 = disp_h;
        var max_x: u32 = 0;
        var max_y: u32 = 0;
        var any_hit = false;

        for (self.entries) |ent| {
            if (ent.seq <= client_seq or ent.seq == 0) continue;
            const ex0 = @min(ent.x0, disp_w);
            const ey0 = @min(ent.y0, disp_h);
            const ex1 = @min(ent.x1, disp_w);
            const ey1 = @min(ent.y1, disp_h);
            if (ex1 <= ex0 or ey1 <= ey0) continue;
            min_x = @min(min_x, ex0);
            min_y = @min(min_y, ey0);
            max_x = @max(max_x, ex1);
            max_y = @max(max_y, ey1);
            any_hit = true;
        }
        if (!any_hit) return full;
        return .{
            .x = min_x,
            .y = min_y,
            .width = max_x - min_x,
            .height = max_y - min_y,
        };
    }
};

fn clampCursorRect(x: i64, y: i64) VirtioGpuRect {
    const dim: i64 = @intCast(proto.CURSOR_DIMENSION);
    if (x + dim <= 0 or y + dim <= 0) return .{};
    const x0: u32 = if (x < 0)
        0
    else
        @intCast(@min(x, @as(i64, std.math.maxInt(u32))));
    const y0: u32 = if (y < 0)
        0
    else
        @intCast(@min(y, @as(i64, std.math.maxInt(u32))));
    const x1_raw = x + dim;
    const y1_raw = y + dim;
    const w: u32 = @intCast(@min(x1_raw - @as(i64, x0), dim));
    const h: u32 = @intCast(@min(y1_raw - @as(i64, y0), dim));
    return .{ .x = x0, .y = y0, .width = w, .height = h };
}

/// Validates whether `res` is eligible for read-only Stage-2 zero-copy scanout.
/// Returns the total aligned 4 KiB page count on success, or `null` otherwise.
pub fn isZeroCopyCompatible(
    gpu: *const VirtioGpu,
    res: *const VirtioGpuResource,
    max_pages: usize,
) ?u32 {
    if (res.format != proto.VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM and
        res.format != proto.VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM)
    {
        return null;
    }
    if (gpu.scanout_rect.x != 0 or gpu.scanout_rect.y != 0) return null;

    const w = if (gpu.scanout_rect.width > 0)
        gpu.scanout_rect.width
    else
        res.width;
    const h = if (gpu.scanout_rect.height > 0)
        gpu.scanout_rect.height
    else
        res.height;
    if (w == 0 or h == 0 or w != res.width or h != res.height) return null;

    const entries = res.entriesSlice();
    if (entries.len == 0) return null;
    const needed_px = std.math.mul(usize, w, h) catch return null;
    const needed_bytes = std.math.mul(
        usize,
        needed_px,
        proto.BYTES_PER_PIXEL_RGBA,
    ) catch return null;

    var total_bytes: usize = 0;
    var total_pages: usize = 0;
    for (entries, 0..) |ent, i| {
        if ((ent.addr & PAGE_MASK) != 0 or ent.length == 0) return null;
        if (i + 1 < entries.len and (ent.length & PAGE_MASK) != 0) return null;
        total_bytes = std.math.add(usize, total_bytes, ent.length) catch
            return null;
        const ent_pages = std.math.divCeil(usize, ent.length, PAGE_SIZE) catch
            return null;
        total_pages = std.math.add(usize, total_pages, ent_pages) catch
            return null;
    }
    if (total_bytes < needed_bytes) return null;
    if (total_pages == 0 or total_pages > max_pages) return null;
    return @intCast(total_pages);
}

/// Returns active cursor visibility and clamped dimensions under `gpu.lock`.
pub fn getCursorMetaLocked(gpu: *VirtioGpu) CursorMeta {
    if (gpu.cursor_resource_id == 0) return .{};
    const cres = gpu.getResourceUnlocked(gpu.cursor_resource_id) orelse
        return .{};
    if (!cres.is_active or cres.entriesSlice().len == 0 or
        cres.width == 0 or cres.height == 0)
    {
        return .{};
    }
    return .{
        .visible = true,
        .width = @min(cres.width, @as(u32, proto.CURSOR_DIMENSION)),
        .height = @min(cres.height, @as(u32, proto.CURSOR_DIMENSION)),
    };
}

/// Streams a single 64-pixel ARGB8888 cursor row into `out_row` with zero
/// heap allocation so M-mode harts avoid large stack buffers.
pub fn extractCursorRowArgb64(
    gpu: *VirtioGpu,
    row_y: usize,
    out_row: *[proto.CURSOR_DIMENSION]u32,
) bool {
    @memset(out_row, 0);
    const meta = getCursorMetaLocked(gpu);
    if (!meta.visible or row_y >= meta.height) return false;
    const mem = gpu.mem orelse return false;
    const cres = gpu.getResourceUnlocked(gpu.cursor_resource_id) orelse
        return false;
    const centries = cres.entriesSlice();
    if (centries.len == 0) return false;

    const cw: usize = @intCast(meta.width);
    var raw_buf: [proto.CURSOR_DIMENSION * 4]u8 = undefined;
    var cur = scanout.SgCursor{ .entries = centries };
    const row_off = row_y * (@as(usize, cres.width) * 4);
    if (!cur.seekAndRead(mem, row_off, raw_buf[0 .. cw * 4])) return false;

    for (0..cw) |cx| {
        const p = raw_buf[cx * 4 ..][0..4].*;
        const alpha = scanout.pixelAlpha(cres.format, p);
        const rgb = scanout.pixelToXrgb8888(cres.format, p) & 0x00ff_ffff;
        out_row[cx] = (alpha << 24) | rgb;
    }
    return true;
}

/// Extracts a full 64x64 ARGB8888 hardware cursor image into `out_argb`.
pub fn extractCursorArgb64(
    gpu: *VirtioGpu,
    out_argb: *[CURSOR_PIXELS]u32,
) CursorMeta {
    @memset(out_argb, 0);
    const meta = getCursorMetaLocked(gpu);
    if (!meta.visible) return meta;
    for (0..@as(usize, meta.height)) |row_y| {
        const off = row_y * proto.CURSOR_DIMENSION;
        const row_dst = out_argb[off..][0..proto.CURSOR_DIMENSION];
        if (!extractCursorRowArgb64(gpu, row_y, row_dst)) return .{};
    }
    return meta;
}

test "vgpu/damage: ring union, wrap fallback, zero-copy & cursor extract" {
    const testing = std.testing;
    testing.refAllDecls(@This());

    var ring = DamageRing{};
    ring.pushRect(1, .{ .x = 10, .y = 20, .width = 30, .height = 40 });
    ring.pushRect(2, .{ .x = 25, .y = 10, .width = 35, .height = 50 });
    const merged = ring.computeDirtyRectSince(0, 2, 800, 600);
    try testing.expectEqual(@as(u32, 0), merged.x);
    try testing.expectEqual(@as(u32, 800), merged.width);

    const partial = ring.computeDirtyRectSince(1, 2, 800, 600);
    try testing.expectEqual(@as(u32, 25), partial.x);
    try testing.expectEqual(@as(u32, 10), partial.y);
    try testing.expectEqual(@as(u32, 35), partial.width);
    try testing.expectEqual(@as(u32, 50), partial.height);

    // 16 more pushes evict seq 1 and seq 2 -> client_seq=1 overflows.
    for (3..19) |s| {
        ring.pushRect(
            @intCast(s),
            .{ .x = 1, .y = 1, .width = 2, .height = 2 },
        );
    }
    const overflow = ring.computeDirtyRectSince(1, 18, 640, 480);
    try testing.expectEqual(@as(u32, 0), overflow.x);
    try testing.expectEqual(@as(u32, 640), overflow.width);

    const exact_after = ring.computeDirtyRectSince(17, 18, 640, 480);
    try testing.expectEqual(@as(u32, 1), exact_after.x);
    try testing.expectEqual(@as(u32, 2), exact_after.width);

    // Zero-copy eligibility checks page alignment, format, and rect origin.
    var gpu = VirtioGpu.initWithMem(1, null, testing.allocator);
    defer gpu.deinit();
    var sg = [_]proto.VirtioGpuMemEntry{
        .{ .addr = 0x1000, .length = 4096 },
        .{ .addr = 0x3000, .length = 4096 },
    };
    var res = VirtioGpuResource{
        .id = 1,
        .format = proto.VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM,
        .width = 32,
        .height = 64,
        .backing_entries = &sg,
        .is_active = true,
    };
    try testing.expectEqual(
        @as(?u32, 2),
        isZeroCopyCompatible(&gpu, &res, 4096),
    );

    res.format = proto.VIRTIO_GPU_FORMAT_R8G8B8A8_UNORM;
    try testing.expectEqual(
        @as(?u32, null),
        isZeroCopyCompatible(&gpu, &res, 4096),
    );
    res.format = proto.VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM;
    sg[0].addr = 0x1100;
    try testing.expectEqual(
        @as(?u32, null),
        isZeroCopyCompatible(&gpu, &res, 4096),
    );
    sg[0].addr = 0x1000;
    gpu.scanout_rect.x = 4;
    try testing.expectEqual(
        @as(?u32, null),
        isZeroCopyCompatible(&gpu, &res, 4096),
    );
    gpu.scanout_rect = .{};

    // Cursor extraction via MemoryAccessor.
    var backing: [16]u8 = @splat(0);
    backing[0] = 0x11; // B
    backing[1] = 0x22; // G
    backing[2] = 0x33; // R
    backing[3] = 0x80; // A
    const Ctx = struct {
        buf: []const u8,
        fn readFn(ctx: *anyopaque, gpa: usize, out: []u8) bool {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (gpa + out.len > self.buf.len) return false;
            @memcpy(out, self.buf[gpa .. gpa + out.len]);
            return true;
        }
        fn writeFn(_: *anyopaque, _: usize, _: []const u8) bool {
            return false;
        }
    };
    var c = Ctx{ .buf = &backing };
    gpu.mem = .{ .ctx = &c, .readFn = Ctx.readFn, .writeFn = Ctx.writeFn };
    const cres = gpu.allocateResourceUnlocked(2).?;
    cres.* = .{
        .id = 2,
        .format = proto.VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM,
        .width = 2,
        .height = 2,
        .inline_entry = .{ .addr = 0, .length = 16 },
        .has_inline_entry = true,
        .is_active = true,
    };
    gpu.cursor_resource_id = 2;
    var argb: [CURSOR_PIXELS]u32 = undefined;
    const cmeta = extractCursorArgb64(&gpu, &argb);
    try testing.expect(cmeta.visible);
    try testing.expectEqual(@as(u32, 2), cmeta.width);
    try testing.expectEqual(@as(u32, 0x80332211), argb[0]);
}
