// Evdev Input Device Discovery & Motion/Intro Event Polling for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const display_mod = @import("../display.zig");
const gui_mod = @import("../gui.zig");
const intro_mod = @import("../intro.zig");
const paths = @import("../paths.zig");

pub const MAX_INPUT_DEVICES: usize = 32;

pub const InputEvent = extern struct {
    sec: i64,
    usec: i64,
    type: u16,
    code: u16,
    value: i32,
};

pub const EV_KEY: u16 = 0x01;
pub const EV_REL: u16 = 0x02;
pub const EV_ABS: u16 = 0x03;

pub const REL_X: u16 = 0x00;
pub const REL_Y: u16 = 0x01;
pub const REL_WHEEL: u16 = 0x08;
pub const ABS_X: u16 = 0x00;
pub const ABS_Y: u16 = 0x01;
pub const ABS_MT_POSITION_X: u16 = 0x35;
pub const ABS_MT_POSITION_Y: u16 = 0x36;
pub const EVDEV_ABS_MAX: i64 = 32767;

pub const BTN_LEFT: u16 = 0x110;
pub const BTN_RIGHT: u16 = 0x111;
pub const BTN_MIDDLE: u16 = 0x112;
pub const BTN_TOUCH: u16 = 0x14a;

pub const input_absinfo = extern struct {
    value: i32 = 0,
    minimum: i32 = 0,
    maximum: i32 = 0,
    fuzz: i32 = 0,
    flat: i32 = 0,
    resolution: i32 = 0,
};

const IOC_READ: u32 = 2;
const IOC_DIRSHIFT: u5 = 30;
const IOC_SIZESHIFT: u5 = 16;
const IOC_TYPESHIFT: u5 = 8;
const EV_IOC_TYPE: u32 = 'E';
const EVIOCGABS_BASE: u32 = 0x40;

pub fn EVIOCGABS(abs: u32) u32 {
    const size: u32 = @sizeOf(input_absinfo);
    return (IOC_READ << IOC_DIRSHIFT) |
        (size << IOC_SIZESHIFT) |
        (EV_IOC_TYPE << IOC_TYPESHIFT) |
        (EVIOCGABS_BASE + abs);
}

pub const InputDeviceInfo = struct {
    fd: i32,
    min_x: i32 = 0,
    max_x: i32 = EVDEV_ABS_MAX,
    min_y: i32 = 0,
    max_y: i32 = EVDEV_ABS_MAX,
    has_abs: bool = false,

    pub fn scaleX(self: *const InputDeviceInfo, raw_x: i32, screen_w: u32) i32 {
        if (screen_w == 0) return 0;
        const span: i64 = @as(i64, self.max_x) - @as(i64, self.min_x);
        if (span <= 0) return 0;
        const clamped_raw = std.math.clamp(raw_x, self.min_x, self.max_x);
        const rel: i64 = @as(i64, clamped_raw) - @as(i64, self.min_x);
        const w_i64: i64 = @intCast(screen_w);
        const res = @divTrunc(rel * w_i64, span);
        const max_coord: i32 = @intCast(screen_w - 1);
        return std.math.clamp(@as(i32, @intCast(res)), 0, max_coord);
    }

    pub fn scaleY(self: *const InputDeviceInfo, raw_y: i32, screen_h: u32) i32 {
        if (screen_h == 0) return 0;
        const span: i64 = @as(i64, self.max_y) - @as(i64, self.min_y);
        if (span <= 0) return 0;
        const clamped_raw = std.math.clamp(raw_y, self.min_y, self.max_y);
        const rel: i64 = @as(i64, clamped_raw) - @as(i64, self.min_y);
        const h_i64: i64 = @intCast(screen_h);
        const res = @divTrunc(rel * h_i64, span);
        const max_coord: i32 = @intCast(screen_h - 1);
        return std.math.clamp(@as(i32, @intCast(res)), 0, max_coord);
    }
};

fn queryAxis(ifd: i32, a: u32, b: u32, min_p: *i32, max_p: *i32) bool {
    var info = input_absinfo{};
    const ptr = @intFromPtr(&info);
    if (@as(isize, @bitCast(linux.ioctl(ifd, EVIOCGABS(a), ptr))) >= 0 and
        info.maximum > info.minimum)
    {
        min_p.* = info.minimum;
        max_p.* = info.maximum;
        return true;
    }
    if (@as(isize, @bitCast(linux.ioctl(ifd, EVIOCGABS(b), ptr))) >= 0 and
        info.maximum > info.minimum)
    {
        min_p.* = info.minimum;
        max_p.* = info.maximum;
        return true;
    }
    return false;
}

pub const INPUT_EVENT_PATH_PREFIX = paths.INPUT_EVENT_PATH_PREFIX;

const MAX_EVENT_INDEX_DIGITS: usize = std.math.log10_int(
    @as(u8, std.math.maxInt(u8)),
) + 1;

pub const INPUT_EVENT_PATH_BUF_BYTES: usize =
    INPUT_EVENT_PATH_PREFIX.len + MAX_EVENT_INDEX_DIGITS + 1;

pub fn openInputDevices(
    input_devs: *[MAX_INPUT_DEVICES]InputDeviceInfo,
    had_eacces: *bool,
) usize {
    var input_count: usize = 0;
    var dev_idx: u8 = 0;
    had_eacces.* = false;

    while (dev_idx < MAX_INPUT_DEVICES) : (dev_idx += 1) {
        var path_buf: [INPUT_EVENT_PATH_BUF_BYTES]u8 = undefined;
        const p_slice = std.fmt.bufPrint(
            &path_buf,
            "{s}{d}",
            .{ INPUT_EVENT_PATH_PREFIX, dev_idx },
        ) catch unreachable;
        path_buf[p_slice.len] = 0;
        const dev_z: [*:0]const u8 = @ptrCast(path_buf[0..p_slice.len :0]);
        const flags = linux.O{ .ACCMODE = .RDONLY, .NONBLOCK = true };
        const rc = linux.open(dev_z, flags, 0);
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc >= 0) {
            const ifd: i32 = @intCast(signed_rc);
            var d = InputDeviceInfo{ .fd = ifd };
            if (queryAxis(ifd, ABS_X, ABS_MT_POSITION_X, &d.min_x, &d.max_x)) {
                d.has_abs = true;
            }
            if (queryAxis(ifd, ABS_Y, ABS_MT_POSITION_Y, &d.min_y, &d.max_y)) {
                d.has_abs = true;
            }
            input_devs[input_count] = d;
            input_count += 1;
        } else {
            const eacces = -@as(isize, @backingInt(linux.E.ACCES));
            if (signed_rc == eacces) had_eacces.* = true;
        }
    }
    return input_count;
}

pub fn closeInputDevices(devs: []const InputDeviceInfo) void {
    for (devs) |d| {
        if (d.fd >= 0) _ = linux.close(d.fd);
    }
}

pub fn fillPollFds(
    devs: []const InputDeviceInfo,
    pfds: *[MAX_INPUT_DEVICES]linux.pollfd,
) void {
    for (devs, 0..) |idev, i| {
        pfds[i] = linux.pollfd{
            .fd = idev.fd,
            .events = linux.POLL.IN,
            .revents = 0,
        };
    }
}

pub fn applyMotionEvent(
    ev: InputEvent,
    dev_info: *const InputDeviceInfo,
    screen_w: u32,
    screen_h: u32,
    pending_x: *i32,
    pending_y: *i32,
    coords_changed: *bool,
) void {
    const max_x: i32 = @intCast(screen_w -| 1);
    const max_y: i32 = @intCast(screen_h -| 1);
    switch (ev.type) {
        EV_REL => {
            if (ev.code == REL_X) {
                pending_x.* = std.math.clamp(pending_x.* +| ev.value, 0, max_x);
                coords_changed.* = true;
            } else if (ev.code == REL_Y) {
                pending_y.* = std.math.clamp(pending_y.* +| ev.value, 0, max_y);
                coords_changed.* = true;
            }
        },
        EV_ABS => {
            if (ev.code == ABS_X or ev.code == ABS_MT_POSITION_X) {
                pending_x.* = dev_info.scaleX(ev.value, screen_w);
                coords_changed.* = true;
            } else if (ev.code == ABS_Y or ev.code == ABS_MT_POSITION_Y) {
                pending_y.* = dev_info.scaleY(ev.value, screen_h);
                coords_changed.* = true;
            }
        },
        else => {},
    }
}

pub fn pollIntroInput(
    devs: []const InputDeviceInfo,
    display: *display_mod.Display,
    gui: *gui_mod.DiosixGui,
    intro_state: *intro_mod.IntroState,
) void {
    var pfds: [MAX_INPUT_DEVICES]linux.pollfd = undefined;
    fillPollFds(devs, &pfds);
    const poll_res = linux.poll(&pfds, devs.len, 0);
    const signed_poll: isize = @bitCast(poll_res);
    if (signed_poll <= 0) return;

    for (devs, 0..) |*dev_info, i| {
        if ((pfds[i].revents & linux.POLL.IN) != 0) {
            var ev_buf: [32]InputEvent = undefined;
            const rd = linux.read(
                pfds[i].fd,
                @ptrCast(&ev_buf),
                @sizeOf(@TypeOf(ev_buf)),
            );
            const signed_rd: isize = @bitCast(rd);
            if (signed_rd > 0) {
                const n_bytes: usize = @intCast(signed_rd);
                const count = n_bytes / @sizeOf(InputEvent);
                var pending_x = gui.cursor.x;
                var pending_y = gui.cursor.y;
                var coords_changed = false;
                var touch_skip = false;

                for (ev_buf[0..count]) |ev| {
                    applyMotionEvent(
                        ev,
                        dev_info,
                        display.width,
                        display.height,
                        &pending_x,
                        &pending_y,
                        &coords_changed,
                    );
                    if (ev.type == EV_KEY and ev.value != 0 and
                        (ev.code == BTN_LEFT or ev.code == BTN_TOUCH))
                    {
                        touch_skip = true;
                    }
                }

                if (coords_changed) {
                    const down = gui.mouse_left_down;
                    gui.handleMouseMove(pending_x, pending_y, down);
                }
                if (touch_skip) {
                    intro_state.skip();
                    gui.handleMouseClick(pending_x, pending_y);
                    gui.mouse_left_down = true;
                    break;
                }
            }
        }
        if (!intro_state.is_active) break;
    }
}

test "display input: event path buffer fits every device index" {
    std.testing.refAllDecls(@This());
    var path_buf: [INPUT_EVENT_PATH_BUF_BYTES]u8 = undefined;
    for (0..std.math.maxInt(u8) + 1) |idx| {
        const dev_idx: u8 = @intCast(idx);
        _ = try std.fmt.bufPrint(
            &path_buf,
            "{s}{d}",
            .{ INPUT_EVENT_PATH_PREFIX, dev_idx },
        );
    }
    const longest = "/dev/input/event255";
    try std.testing.expectEqual(longest.len + 1, INPUT_EVENT_PATH_BUF_BYTES);
}
