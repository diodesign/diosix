// Guest VirtIO-GPU Scanout & VirtIO-Input Host Bridge for Diosix GUI.
//
// Invokes IOCTL_GPU_READ_SCANOUT and IOCTL_INPUT_SEND_EVENT on /dev/diosix
// to stream guest framebuffer pixels and inject evdev keyboard, mouse, and
// tablet events into running child VMs.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const sbi = @import("interface").sbi;
const paths = @import("../paths.zig");
pub const mapped = @import("desktop/mapped.zig");

pub const IOCTL_GPU_READ_SCANOUT: u32 = 0x101b;
pub const IOCTL_INPUT_SEND_EVENT: u32 = 0x101c;
pub const IOCTL_GPU_MAP_SCANOUT: u32 = 0x101d;
pub const MAX_GPU_SCANOUT_PIXELS: usize =
    @as(usize, sbi.MAX_GPU_SCANOUT_PAGES) * 1024;

pub const MappedScanoutResult = mapped.MappedScanoutResult;
pub const pollGuestScanout = mapped.pollGuestScanout;
pub const unmapGuestScanout = mapped.unmapGuestScanout;

pub const ScanoutResult = struct {
    width: u32,
    height: u32,
    active: bool,
    updated: bool,
    frame_seq: u64,
};

pub const MockScanoutState = struct {
    cid: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    requested_width: u32 = 0,
    requested_height: u32 = 0,
    active: bool = false,
    zero_copy: bool = false,
    frame_seq: u64 = 0,
    dirty_x: u32 = 0,
    dirty_y: u32 = 0,
    dirty_w: u32 = 0,
    dirty_h: u32 = 0,
    cursor_visible: bool = false,
    cursor_seq: u64 = 0,
    cursor_x: i32 = 0,
    cursor_y: i32 = 0,
    cursor_hot_x: u32 = 0,
    cursor_hot_y: u32 = 0,
    cursor_w: u32 = 0,
    cursor_h: u32 = 0,
    cursor_pixels: []const u32 = &.{},
    pixels: []const u32 = &.{},
};

pub const MockInputBatch = struct {
    target_cid: u64 = 0,
    count: usize = 0,
    events: [sbi.MAX_INPUT_BATCH_EVENTS]sbi.InputEventItem = @splat(.{}),
};

pub var mock_scanout: ?MockScanoutState = null;
pub var mock_last_input: ?MockInputBatch = null;

var dev_diosix_fd: i32 = -1;

pub fn resetDesktopMocks() void {
    mock_scanout = null;
    mock_last_input = null;
}

pub fn getOpenDevDiosixFd() ?i32 {
    return if (dev_diosix_fd >= 0) dev_diosix_fd else null;
}

pub fn closeDevDiosixFd() void {
    mapped.closeScanoutAperture();
    if (dev_diosix_fd >= 0) {
        _ = linux.close(dev_diosix_fd);
        dev_diosix_fd = -1;
    }
}

pub fn openDevDiosixFd() ?i32 {
    if (dev_diosix_fd >= 0) return dev_diosix_fd;
    const rc = linux.open(
        paths.DEV_DIOSIX_PATH,
        .{ .ACCMODE = .RDWR, .CLOEXEC = true },
        0,
    );
    const signed_rc: isize = @bitCast(rc);
    if (signed_rc < 0) return null;
    dev_diosix_fd = @intCast(signed_rc);
    return dev_diosix_fd;
}

pub fn readGuestScanout(
    cid: u64,
    prev_frame_seq: u64,
    pixels_buf: ?[]u32,
    req_width: u32,
    req_height: u32,
) ?ScanoutResult {
    if (builtin.is_test or mock_scanout != null) {
        if (mock_scanout) |*ms_mut| {
            if (ms_mut.cid == cid and req_width > 0 and req_height > 0) {
                ms_mut.requested_width = req_width;
                ms_mut.requested_height = req_height;
            }
        }
        const ms = mock_scanout orelse return .{
            .width = 0,
            .height = 0,
            .active = false,
            .updated = false,
            .frame_seq = 0,
        };
        if (ms.cid != cid or !ms.active or ms.width == 0 or ms.height == 0) {
            return .{
                .width = if (ms.cid == cid) ms.width else 0,
                .height = if (ms.cid == cid) ms.height else 0,
                .active = false,
                .updated = false,
                .frame_seq = 0,
            };
        }
        const need_px = std.math.mul(
            usize,
            @as(usize, ms.width),
            @as(usize, ms.height),
        ) catch return null;
        if (need_px > MAX_GPU_SCANOUT_PIXELS) return null;

        const buf = pixels_buf orelse return .{
            .width = ms.width,
            .height = ms.height,
            .active = true,
            .updated = ms.frame_seq != prev_frame_seq,
            .frame_seq = ms.frame_seq,
        };
        if (buf.len < need_px) {
            return .{
                .width = ms.width,
                .height = ms.height,
                .active = true,
                .updated = false,
                .frame_seq = prev_frame_seq,
            };
        }
        const changed = (ms.frame_seq != prev_frame_seq);
        if (changed) {
            const copy_n: usize = @min(need_px, ms.pixels.len);
            @memcpy(buf[0..copy_n], ms.pixels[0..copy_n]);
            if (copy_n < need_px) {
                @memset(buf[copy_n..need_px], 0);
            }
        }
        return .{
            .width = ms.width,
            .height = ms.height,
            .active = true,
            .updated = changed,
            .frame_seq = ms.frame_seq,
        };
    }

    const fd = openDevDiosixFd() orelse return null;
    const max_px: u32 = if (pixels_buf) |b|
        @intCast(@min(b.len, MAX_GPU_SCANOUT_PIXELS))
    else
        0;
    const px_ptr: u64 = if (pixels_buf) |b|
        (if (b.len > 0) @intFromPtr(b.ptr) else 0)
    else
        0;

    const set_size = req_width > 0 and req_height > 0;
    var args = sbi.GpuScanoutArgs{
        .target_cid = cid,
        .pixels_ptr = px_ptr,
        .max_pixels = max_px,
        .width = if (set_size) req_width else 0,
        .height = if (set_size) req_height else 0,
        .flags = if (set_size) sbi.GpuScanoutFlags.SET_DISPLAY_SIZE else 0,
        .frame_seq = prev_frame_seq,
    };
    const rc = linux.ioctl(fd, IOCTL_GPU_READ_SCANOUT, @intFromPtr(&args));
    if (@as(isize, @bitCast(rc)) < 0) return null;

    return .{
        .width = args.width,
        .height = args.height,
        .active = (args.flags & sbi.GpuScanoutFlags.ACTIVE) != 0,
        .updated = (args.flags & sbi.GpuScanoutFlags.UPDATED) != 0,
        .frame_seq = args.frame_seq,
    };
}

pub fn sendGuestInputEvents(
    cid: u64,
    items: []const sbi.InputEventItem,
) bool {
    if (items.len == 0) return true;
    const count: usize = @min(items.len, sbi.MAX_INPUT_BATCH_EVENTS);

    if (builtin.is_test or mock_scanout != null or mock_last_input != null) {
        var batch = MockInputBatch{
            .target_cid = cid,
            .count = count,
        };
        @memcpy(batch.events[0..count], items[0..count]);
        mock_last_input = batch;
        return true;
    }

    const fd = openDevDiosixFd() orelse return false;
    var args = sbi.InputEventArgs{
        .target_cid = cid,
        .count = @intCast(count),
    };
    @memcpy(args.events[0..count], items[0..count]);
    const rc = linux.ioctl(fd, IOCTL_INPUT_SEND_EVENT, @intFromPtr(&args));
    return @as(isize, @bitCast(rc)) == 0;
}

test "host/desktop: mocked scanout probe, copy, and input event batching" {
    const testing = std.testing;
    _ = mapped;
    testing.refAllDecls(@This());
    defer resetDesktopMocks();

    const sample = [_]u32{ 0x00ff0000, 0x0000ff00, 0x000000ff, 0x00ffffff };
    mock_scanout = .{
        .cid = 2,
        .width = 2,
        .height = 2,
        .active = true,
        .frame_seq = 7,
        .pixels = &sample,
    };

    // Probe with undersized buffer reports dimensions without advancing seq.
    var small: [2]u32 = @splat(0);
    const probe = readGuestScanout(2, 0, &small, 1008, 630).?;
    try testing.expect(probe.active);
    try testing.expect(!probe.updated);
    try testing.expectEqual(@as(u32, 2), probe.width);
    try testing.expectEqual(@as(u32, 2), probe.height);
    try testing.expectEqual(@as(u64, 0), probe.frame_seq);
    try testing.expectEqual(@as(u32, 1008), mock_scanout.?.requested_width);
    try testing.expectEqual(@as(u32, 630), mock_scanout.?.requested_height);

    // Full-sized buffer receives frame pixels and advances frame_seq.
    var dst: [4]u32 = @splat(0);
    const full = readGuestScanout(2, 0, &dst, 1008, 630).?;
    try testing.expect(full.active);
    try testing.expect(full.updated);
    try testing.expectEqual(@as(u64, 7), full.frame_seq);
    try testing.expectEqualSlices(u32, &sample, &dst);

    // Subsequent poll at same frame_seq skips redundant copy.
    const unchanged = readGuestScanout(2, 7, &dst, 1008, 630).?;
    try testing.expect(unchanged.active);
    try testing.expect(!unchanged.updated);

    const evs = [_]sbi.InputEventItem{
        .{ .type = 1, .code = 30, .value = 1 },
        .{ .type = 0, .code = 0, .value = 0 },
    };
    try testing.expect(sendGuestInputEvents(2, &evs));
    try testing.expectEqual(@as(u64, 2), mock_last_input.?.target_cid);
    try testing.expectEqual(@as(usize, 2), mock_last_input.?.count);
    try testing.expectEqual(@as(u16, 30), mock_last_input.?.events[0].code);
}
