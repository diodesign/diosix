// VirtIO-GPU Scatter-Gather Scanout Streaming & Hardware Cursor Compositor
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const vsock_mod = @import("../vsock.zig");
const proto = @import("protocol.zig");
const vgpu_mod = @import("../vgpu.zig");

const MemoryAccessor = vsock_mod.MemoryAccessor;
const VirtioGpu = vgpu_mod.VirtioGpu;

const ROW_CHUNK_PIXELS: usize = 64;

pub const ScanoutSnapshot = struct {
    active: bool = false,
    updated: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    frame_seq: u64 = 0,
};

pub const PixelChunkSink = struct {
    ctx: *anyopaque,
    writeFn: *const fn (ctx: *anyopaque, pixels: []const u32) bool,

    pub inline fn write(self: PixelChunkSink, pixels: []const u32) bool {
        return self.writeFn(self.ctx, pixels);
    }
};

pub inline fn pixelToXrgb8888(format: u32, raw: [4]u8) u32 {
    return switch (format) {
        proto.VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM,
        proto.VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM,
        => (@as(u32, raw[2]) << 16) | (@as(u32, raw[1]) << 8) | raw[0],
        proto.VIRTIO_GPU_FORMAT_A8R8G8B8_UNORM,
        proto.VIRTIO_GPU_FORMAT_X8R8G8B8_UNORM,
        => (@as(u32, raw[1]) << 16) | (@as(u32, raw[2]) << 8) | raw[3],
        proto.VIRTIO_GPU_FORMAT_R8G8B8A8_UNORM,
        proto.VIRTIO_GPU_FORMAT_R8G8B8X8_UNORM,
        => (@as(u32, raw[0]) << 16) | (@as(u32, raw[1]) << 8) | raw[2],
        proto.VIRTIO_GPU_FORMAT_X8B8G8R8_UNORM,
        proto.VIRTIO_GPU_FORMAT_A8B8G8R8_UNORM,
        => (@as(u32, raw[3]) << 16) | (@as(u32, raw[2]) << 8) | raw[1],
        else => 0,
    };
}

pub inline fn pixelAlpha(format: u32, raw: [4]u8) u32 {
    return switch (format) {
        proto.VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM,
        proto.VIRTIO_GPU_FORMAT_R8G8B8A8_UNORM,
        => raw[3],
        proto.VIRTIO_GPU_FORMAT_A8R8G8B8_UNORM,
        proto.VIRTIO_GPU_FORMAT_A8B8G8R8_UNORM,
        => raw[0],
        else => 0xff,
    };
}

pub const SgCursor = struct {
    entries: []const proto.VirtioGpuMemEntry,
    idx: usize = 0,
    entry_start: usize = 0,

    pub fn seekAndRead(
        self: *SgCursor,
        mem: MemoryAccessor,
        byte_offset: usize,
        out: []u8,
    ) bool {
        while (self.idx < self.entries.len) {
            const ent_len: usize = self.entries[self.idx].length;
            if (byte_offset < self.entry_start + ent_len) break;
            self.entry_start += ent_len;
            self.idx += 1;
        }
        var cur_idx = self.idx;
        var cur_start = self.entry_start;
        var dst_pos: usize = 0;
        var want_off = byte_offset;
        while (dst_pos < out.len) {
            if (cur_idx >= self.entries.len) return false;
            const ent = self.entries[cur_idx];
            const ent_len: usize = ent.length;
            if (want_off >= cur_start + ent_len) {
                cur_start += ent_len;
                cur_idx += 1;
                continue;
            }
            const in_ent = want_off - cur_start;
            const avail = ent_len - in_ent;
            const chunk: usize = @min(out.len - dst_pos, avail);
            const read_gpa = std.math.add(u64, ent.addr, in_ent) catch
                return false;
            if (!mem.read(read_gpa, out[dst_pos .. dst_pos + chunk])) {
                return false;
            }
            dst_pos += chunk;
            want_off += chunk;
        }
        self.idx = cur_idx;
        self.entry_start = cur_start;
        return true;
    }
};

fn compositeCursorChunk(
    gpu: *VirtioGpu,
    mem: MemoryAccessor,
    row_y: u32,
    chunk_x: usize,
    chunk_pixels: []u32,
) void {
    if (gpu.cursor_resource_id == 0) return;
    const cres = gpu.getResourceUnlocked(gpu.cursor_resource_id) orelse return;
    const centries = cres.entriesSlice();
    if (centries.len == 0 or cres.width == 0 or cres.height == 0) return;

    const top: i64 = @as(i64, gpu.cursor_y) - @as(i64, gpu.cursor_hot_y);
    const left: i64 = @as(i64, gpu.cursor_x) - @as(i64, gpu.cursor_hot_x);
    const ry: i64 = @intCast(row_y);
    if (ry < top or ry >= top + @as(i64, cres.height)) return;

    const cw: usize = @min(@as(usize, cres.width), proto.CURSOR_DIMENSION);
    const chunk_left: i64 = @intCast(chunk_x);
    const chunk_right: i64 = @intCast(chunk_x + chunk_pixels.len);
    if (left + @as(i64, @intCast(cw)) <= chunk_left or left >= chunk_right) {
        return;
    }

    const cy: usize = @intCast(ry - top);
    var raw_buf: [proto.CURSOR_DIMENSION * 4]u8 = undefined;
    var cur = SgCursor{ .entries = centries };
    const row_off = cy * (@as(usize, cres.width) * 4);
    if (!cur.seekAndRead(mem, row_off, raw_buf[0 .. cw * 4])) return;

    for (0..cw) |cx| {
        const dst_x = left + @as(i64, @intCast(cx));
        if (dst_x < chunk_left or dst_x >= chunk_right) continue;
        const p = raw_buf[cx * 4 ..][0..4].*;
        const alpha = pixelAlpha(cres.format, p);
        if (alpha == 0) continue;
        const fg = pixelToXrgb8888(cres.format, p);
        const idx_in_chunk: usize = @intCast(dst_x - chunk_left);
        if (alpha >= 250) {
            chunk_pixels[idx_in_chunk] = fg;
        } else {
            const bg = chunk_pixels[idx_in_chunk];
            const inv = 255 - alpha;
            const r = (((fg >> 16) & 0xff) * alpha +
                ((bg >> 16) & 0xff) * inv) / 255;
            const g = (((fg >> 8) & 0xff) * alpha +
                ((bg >> 8) & 0xff) * inv) / 255;
            const b = ((fg & 0xff) * alpha + (bg & 0xff) * inv) / 255;
            chunk_pixels[idx_in_chunk] = (r << 16) | (g << 8) | b;
        }
    }
}

pub fn streamScanoutLocked(
    gpu: *VirtioGpu,
    client_seq: u64,
    max_pixels: usize,
    sink: ?PixelChunkSink,
) ScanoutSnapshot {
    const seq = gpu.frame_seq.load(.acquire);
    if (gpu.active_scanout_res_id == 0) return .{ .frame_seq = seq };
    const res = gpu.getResourceUnlocked(gpu.active_scanout_res_id) orelse
        return .{ .frame_seq = seq };
    const entries = res.entriesSlice();
    const w = if (gpu.scanout_rect.width > 0)
        gpu.scanout_rect.width
    else
        res.width;
    const h = if (gpu.scanout_rect.height > 0)
        gpu.scanout_rect.height
    else
        res.height;
    if (w == 0 or h == 0 or entries.len == 0) return .{ .frame_seq = seq };

    var snap = ScanoutSnapshot{
        .active = true,
        .updated = false,
        .width = w,
        .height = h,
        .frame_seq = seq,
    };
    const out_sink = sink orelse return snap;
    if (seq == client_seq) return snap;
    const total_pixels = std.math.mul(usize, w, h) catch return snap;
    if (max_pixels < total_pixels) return snap;
    const mem = gpu.mem orelse return snap;

    var sg = SgCursor{ .entries = entries };
    const stride_bytes: usize = @as(usize, res.width) * 4;
    const x_off_bytes: usize = @as(usize, gpu.scanout_rect.x) * 4;
    var raw_chunk: [ROW_CHUNK_PIXELS * 4]u8 = undefined;
    var px_chunk: [ROW_CHUNK_PIXELS]u32 = undefined;

    for (0..h) |ry| {
        const src_y = @as(usize, gpu.scanout_rect.y) + ry;
        const row_base = src_y * stride_bytes + x_off_bytes;
        var rx: usize = 0;
        while (rx < w) {
            const n: usize = @min(w - rx, ROW_CHUNK_PIXELS);
            if (sg.seekAndRead(
                mem,
                row_base + rx * 4,
                raw_chunk[0 .. n * 4],
            )) {
                for (0..n) |i| {
                    px_chunk[i] = pixelToXrgb8888(
                        res.format,
                        raw_chunk[i * 4 ..][0..4].*,
                    );
                }
            } else {
                @memset(px_chunk[0..n], 0);
            }
            compositeCursorChunk(gpu, mem, @intCast(ry), rx, px_chunk[0..n]);
            if (!out_sink.write(px_chunk[0..n])) return snap;
            rx += n;
        }
    }
    snap.updated = true;
    return snap;
}

pub fn readScanoutLocked(
    gpu: *VirtioGpu,
    client_seq: u64,
    out_pixels: ?[]u32,
) ScanoutSnapshot {
    const dst = out_pixels orelse
        return streamScanoutLocked(gpu, client_seq, 0, null);
    const SliceSink = struct {
        buf: []u32,
        pos: usize = 0,
        fn write(ctx: *anyopaque, pixels: []const u32) bool {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            if (s.pos + pixels.len > s.buf.len) return false;
            @memcpy(s.buf[s.pos .. s.pos + pixels.len], pixels);
            s.pos += pixels.len;
            return true;
        }
    };
    var sink_ctx = SliceSink{ .buf = dst };
    return streamScanoutLocked(
        gpu,
        client_seq,
        dst.len,
        .{ .ctx = &sink_ctx, .writeFn = SliceSink.write },
    );
}

test "VirtIO GPU pixel format conversion and scatter-gather scanout readout" {
    const testing = std.testing;
    testing.refAllDecls(@This());

    try testing.expectEqual(
        @as(u32, 0x00112233),
        pixelToXrgb8888(
            proto.VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM,
            .{ 0x33, 0x22, 0x11, 0xff },
        ),
    );
    try testing.expectEqual(
        @as(u32, 0x00112233),
        pixelToXrgb8888(
            proto.VIRTIO_GPU_FORMAT_R8G8B8A8_UNORM,
            .{ 0x11, 0x22, 0x33, 0xff },
        ),
    );
}
