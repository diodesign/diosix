// Tier 1 Stage-2 Zero-Copy Mapped Scanout Polling for Diosix GUI Host Bridge.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const sbi = @import("interface").sbi;
const desktop = @import("../desktop.zig");

pub const MappedScanoutResult = struct {
    width: u32 = 0,
    height: u32 = 0,
    dirty_x: u32 = 0,
    dirty_y: u32 = 0,
    dirty_w: u32 = 0,
    dirty_h: u32 = 0,
    active: bool = false,
    updated: bool = false,
    zero_copy: bool = false,
    frame_seq: u64 = 0,
    pixels: ?[]const u32 = null,
    cursor_visible: bool = false,
    cursor_shape_updated: bool = false,
    cursor_x: i32 = 0,
    cursor_y: i32 = 0,
    cursor_hot_x: u32 = 0,
    cursor_hot_y: u32 = 0,
    cursor_w: u32 = 0,
    cursor_h: u32 = 0,
    cursor_seq: u64 = 0,
};

var scanout_aperture: ?[]align(std.heap.page_size_min) const u8 = null;
var scanout_mmap_failed: bool = false;

pub fn closeScanoutAperture() void {
    if (scanout_aperture) |ap| {
        _ = linux.munmap(ap.ptr, ap.len);
        scanout_aperture = null;
    }
    scanout_mmap_failed = false;
}

fn ensureScanoutAperture(fd: i32) ?[]align(std.heap.page_size_min) const u8 {
    if (scanout_aperture) |ap| return ap;
    if (scanout_mmap_failed) return null;
    const rc = linux.mmap(
        null,
        sbi.SCANOUT_APERTURE_BYTES,
        .{ .READ = true },
        .{ .TYPE = .SHARED },
        fd,
        @intCast(sbi.SCANOUT_MAP_GPA_BASE),
    );
    if (@as(isize, @bitCast(rc)) < 0) {
        scanout_mmap_failed = true;
        return null;
    }
    const ptr: [*]align(std.heap.page_size_min) const u8 = @ptrFromInt(rc);
    scanout_aperture = ptr[0..sbi.SCANOUT_APERTURE_BYTES];
    return scanout_aperture;
}

pub fn unmapGuestScanout(cid: u64) void {
    if (builtin.is_test or desktop.mock_scanout != null) return;
    const fd = desktop.getOpenDevDiosixFd() orelse return;
    var args = sbi.GpuMapScanoutArgs{
        .target_cid = cid,
        .flags = sbi.GpuScanoutFlags.UNMAP,
    };
    _ = linux.ioctl(
        fd,
        desktop.IOCTL_GPU_MAP_SCANOUT,
        @intFromPtr(&args),
    );
}

fn fillMockMappedScanout(
    ms: desktop.MockScanoutState,
    prev_frame_seq: u64,
    prev_cursor_seq: u64,
    was_cursor_vis: bool,
    cursor_buf: ?*[sbi.CURSOR_MAX_PIXELS]u32,
) MappedScanoutResult {
    const updated = ms.frame_seq != prev_frame_seq;
    const dw = if (ms.dirty_w > 0) ms.dirty_w else ms.width;
    const dh = if (ms.dirty_h > 0) ms.dirty_h else ms.height;
    const shape_upd = ms.cursor_visible and
        (ms.cursor_seq != prev_cursor_seq or !was_cursor_vis);
    if (shape_upd) {
        if (cursor_buf) |cb| {
            const copy_n: usize = @min(cb.len, ms.cursor_pixels.len);
            @memcpy(cb[0..copy_n], ms.cursor_pixels[0..copy_n]);
            if (copy_n < cb.len) @memset(cb[copy_n..], 0);
        }
    }
    return .{
        .width = ms.width,
        .height = ms.height,
        .dirty_x = ms.dirty_x,
        .dirty_y = ms.dirty_y,
        .dirty_w = if (updated) dw else 0,
        .dirty_h = if (updated) dh else 0,
        .active = true,
        .updated = updated,
        .zero_copy = true,
        .frame_seq = ms.frame_seq,
        .pixels = ms.pixels,
        .cursor_visible = ms.cursor_visible,
        .cursor_shape_updated = shape_upd and cursor_buf != null,
        .cursor_x = ms.cursor_x,
        .cursor_y = ms.cursor_y,
        .cursor_hot_x = ms.cursor_hot_x,
        .cursor_hot_y = ms.cursor_hot_y,
        .cursor_w = ms.cursor_w,
        .cursor_h = ms.cursor_h,
        .cursor_seq = ms.cursor_seq,
    };
}

fn fallbackToReadScanout(
    cid: u64,
    prev_frame_seq: u64,
    fallback_buf: ?[]u32,
    req_width: u32,
    req_height: u32,
) ?MappedScanoutResult {
    const r = desktop.readGuestScanout(
        cid,
        prev_frame_seq,
        fallback_buf,
        req_width,
        req_height,
    ) orelse return null;
    return .{
        .width = r.width,
        .height = r.height,
        .dirty_w = if (r.updated) r.width else 0,
        .dirty_h = if (r.updated) r.height else 0,
        .active = r.active,
        .updated = r.updated,
        .zero_copy = false,
        .frame_seq = r.frame_seq,
    };
}

/// Polls a direct child VM's desktop using Tier 1 Stage-2 zero-copy mapping
/// when available, falling back seamlessly to IOCTL_GPU_READ_SCANOUT.
pub fn pollGuestScanout(
    cid: u64,
    prev_frame_seq: u64,
    prev_cursor_seq: u64,
    was_cursor_vis: bool,
    cursor_buf: ?*[sbi.CURSOR_MAX_PIXELS]u32,
    fallback_buf: ?[]u32,
    req_width: u32,
    req_height: u32,
) ?MappedScanoutResult {
    if (builtin.is_test or desktop.mock_scanout != null) {
        if (desktop.mock_scanout) |*ms_mut| {
            if (ms_mut.cid == cid and req_width > 0 and req_height > 0) {
                ms_mut.requested_width = req_width;
                ms_mut.requested_height = req_height;
            }
        }
        const ms = desktop.mock_scanout orelse return .{};
        if (ms.cid != cid or !ms.active or ms.width == 0 or ms.height == 0) {
            return .{
                .width = if (ms.cid == cid) ms.width else 0,
                .height = if (ms.cid == cid) ms.height else 0,
            };
        }
        if (ms.zero_copy) {
            return fillMockMappedScanout(
                ms,
                prev_frame_seq,
                prev_cursor_seq,
                was_cursor_vis,
                cursor_buf,
            );
        }
        return fallbackToReadScanout(
            cid,
            prev_frame_seq,
            fallback_buf,
            req_width,
            req_height,
        );
    }

    const fd = desktop.openDevDiosixFd() orelse return null;
    if (ensureScanoutAperture(fd)) |ap| {
        const set_size = req_width > 0 and req_height > 0;
        var in_flags: u32 = 0;
        if (set_size) in_flags |= sbi.GpuScanoutFlags.SET_DISPLAY_SIZE;
        if (was_cursor_vis) in_flags |= sbi.GpuScanoutFlags.CURSOR_VISIBLE;
        var margs = sbi.GpuMapScanoutArgs{
            .target_cid = cid,
            .cursor_pixels_ptr = if (cursor_buf) |cb|
                @intFromPtr(cb.ptr)
            else
                0,
            .width = if (set_size) req_width else 0,
            .height = if (set_size) req_height else 0,
            .flags = in_flags,
            .frame_seq = prev_frame_seq,
            .cursor_seq = prev_cursor_seq,
        };
        const rc = linux.ioctl(
            fd,
            desktop.IOCTL_GPU_MAP_SCANOUT,
            @intFromPtr(&margs),
        );
        if (@as(isize, @bitCast(rc)) >= 0) {
            const active = (margs.flags & sbi.GpuScanoutFlags.ACTIVE) != 0;
            if (!active) {
                return .{
                    .frame_seq = margs.frame_seq,
                    .cursor_seq = margs.cursor_seq,
                };
            }
            const zero_copy = (margs.flags &
                sbi.GpuScanoutFlags.MAPPED_ZERO_COPY) != 0;
            if (zero_copy and margs.mapped_bytes >= 4 and
                margs.slot_offset_bytes <= ap.len and
                margs.mapped_bytes <= ap.len - margs.slot_offset_bytes and
                (margs.slot_offset_bytes & 3) == 0)
            {
                const off = margs.slot_offset_bytes;
                const byte_slice = ap[off .. off + margs.mapped_bytes];
                const px_ptr: [*]const u32 = @ptrCast(
                    @alignCast(byte_slice.ptr),
                );
                return .{
                    .width = margs.width,
                    .height = margs.height,
                    .dirty_x = margs.dirty_x,
                    .dirty_y = margs.dirty_y,
                    .dirty_w = margs.dirty_w,
                    .dirty_h = margs.dirty_h,
                    .active = true,
                    .updated = (margs.flags & sbi.GpuScanoutFlags.UPDATED) != 0,
                    .zero_copy = true,
                    .frame_seq = margs.frame_seq,
                    .pixels = px_ptr[0 .. margs.mapped_bytes / @sizeOf(u32)],
                    .cursor_visible = (margs.flags &
                        sbi.GpuScanoutFlags.CURSOR_VISIBLE) != 0,
                    .cursor_shape_updated = (margs.flags &
                        sbi.GpuScanoutFlags.CURSOR_SHAPE_UPDATED) != 0,
                    .cursor_x = margs.cursor_x,
                    .cursor_y = margs.cursor_y,
                    .cursor_hot_x = margs.cursor_hot_x,
                    .cursor_hot_y = margs.cursor_hot_y,
                    .cursor_w = margs.cursor_w,
                    .cursor_h = margs.cursor_h,
                    .cursor_seq = margs.cursor_seq,
                };
            }
        }
    }

    return fallbackToReadScanout(
        cid,
        prev_frame_seq,
        fallback_buf,
        req_width,
        req_height,
    );
}
