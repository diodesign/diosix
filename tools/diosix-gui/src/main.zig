// Main Entry Point and Display Loop for Diosix Monolithic GUI
// Final Fantasy 7 & 8 Inspired BIOS/UEFI Menu Environment
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const fb = @import("framebuffer.zig");
const font = @import("font.zig");
const drm = @import("drm.zig");
const gui_mod = @import("gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const icon_mod = @import("icon.zig");
const Icon = icon_mod.Icon;
const window_mod = @import("window.zig");
const Window = window_mod.Window;
const intro_mod = @import("intro.zig");
const audio_mod = @import("audio.zig");

pub const Display = struct {
    width: u32,
    height: u32,
    stride: usize,
    fb_ptr: [*]u32,
    drm_dev: ?drm.DrmDevice,
    fb_fd: i32,
    backbuffer: fb.Surface,
    backbuffer_mem: []u32,
    clean_buffer: fb.Surface,
    clean_buffer_mem: []u32,
    prev_cursor_box: fb.Box = fb.Box{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 },
    prev_cursor_x: i32 = -1,
    prev_cursor_y: i32 = -1,
    cursor_drawn: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Display {
        // Try DRM/KMS first (e.g. VirtIO-GPU)
        const dri_paths = [_][]const u8{ "/dev/dri/card0", "/dev/dri/card1" };
        for (dri_paths) |card_path| {
            if (drm.DrmDevice.init(card_path)) |dev| {
                const stride_pixels = dev.pitch / @sizeOf(u32);
                const buffer_pixels = stride_pixels * dev.height;
                const bb_mem = try allocator.alloc(u32, buffer_pixels);
                const cb_mem = try allocator.alloc(u32, buffer_pixels);
                return Display{
                    .width = dev.width,
                    .height = dev.height,
                    .stride = dev.pitch,
                    .fb_ptr = dev.screen_surface.pixels,
                    .drm_dev = dev,
                    .fb_fd = -1,
                    .backbuffer = fb.Surface.init(bb_mem.ptr, dev.width, dev.height, dev.pitch),
                    .backbuffer_mem = bb_mem,
                    .clean_buffer = fb.Surface.init(cb_mem.ptr, dev.width, dev.height, dev.pitch),
                    .clean_buffer_mem = cb_mem,
                };
            } else |_| {}
        }

        // Fallback to legacy /dev/fb0
        const fb_path = "/dev/fb0";
        const fd_rc = linux.open(fb_path, .{ .ACCMODE = .RDWR }, 0);
        const signed_fd: isize = @bitCast(fd_rc);
        if (signed_fd >= 0) {
            const fd: i32 = @intCast(signed_fd);
            const w: u32 = drm.PREFERRED_WIDTH;
            const h: u32 = drm.PREFERRED_HEIGHT;
            const stride: usize = w * @sizeOf(u32);
            const map_size = stride * h;

            const map_res = linux.mmap(null, map_size, linux.PROT{ .READ = true, .WRITE = true }, linux.MAP{ .TYPE = .SHARED }, fd, 0);
            const signed_map: isize = @bitCast(map_res);
            if (signed_map >= 0) {
                const pixels: [*]u32 = @ptrFromInt(map_res);
                const bb_mem = try allocator.alloc(u32, w * h);
                const cb_mem = try allocator.alloc(u32, w * h);
                return Display{
                    .width = w,
                    .height = h,
                    .stride = stride,
                    .fb_ptr = pixels,
                    .drm_dev = null,
                    .fb_fd = fd,
                    .backbuffer = fb.Surface.init(bb_mem.ptr, w, h, @intCast(stride)),
                    .backbuffer_mem = bb_mem,
                    .clean_buffer = fb.Surface.init(cb_mem.ptr, w, h, @intCast(stride)),
                    .clean_buffer_mem = cb_mem,
                };
            }
            _ = linux.close(fd);
        }

        return error.NoDisplayDeviceFound;
    }

    pub fn deinit(self: *Display, allocator: std.mem.Allocator) void {
        allocator.free(self.backbuffer_mem);
        allocator.free(self.clean_buffer_mem);
        if (self.drm_dev) |*d| d.deinit();
        if (self.fb_fd >= 0) {
            const map_size = self.stride * self.height;
            if (map_size > 0) {
                _ = linux.munmap(@ptrCast(self.fb_ptr), map_size);
            }
            _ = linux.close(self.fb_fd);
            self.fb_fd = -1;
        }
    }

    pub fn screenSurface(self: *Display) fb.Surface {
        return fb.Surface.init(self.fb_ptr, self.width, self.height, @intCast(self.stride));
    }

    pub fn flushDamage(self: *Display, damage: fb.Box) void {
        const x0 = @max(0, damage.x0);
        const y0 = @max(0, damage.y0);
        const x1 = @min(@as(i32, @intCast(self.width)), damage.x1);
        const y1 = @min(@as(i32, @intCast(self.height)), damage.y1);
        if (x0 >= x1 or y0 >= y1) return;

        const w: usize = @intCast(x1 - x0);
        const stride_pixels = self.stride / @sizeOf(u32);
        const ux0: usize = @intCast(x0);

        var y: usize = @intCast(y0);
        const end_y: usize = @intCast(y1);
        const max_len = @min(self.backbuffer_mem.len, (self.stride * self.height) / @sizeOf(u32));

        while (y < end_y) : (y += 1) {
            const row_start = std.math.mul(usize, y, stride_pixels) catch break;
            const row_offset = std.math.add(usize, row_start, ux0) catch break;
            const row_end = std.math.add(usize, row_offset, w) catch break;
            if (row_end > max_len) break;
            @memcpy(self.fb_ptr[row_offset..row_end], self.backbuffer_mem[row_offset..row_end]);
        }

        if (self.drm_dev) |*d| {
            d.dirtyFb(damage);
        }
    }

    pub fn flush(self: *Display) void {
        self.flushDamage(fb.Box.fromPosSize(0, 0, self.width, self.height));
    }
};

pub const MS_PER_SEC: i64 = 1000;
pub const NS_PER_MS: i64 = 1_000_000;
pub const TARGET_FPS: i64 = 60;
pub const FRAME_INTERVAL_MS: i64 = MS_PER_SEC / TARGET_FPS; // 16 ms (~60 FPS)
pub const POLL_TIMEOUT_MS: i32 = @intCast(FRAME_INTERVAL_MS);
pub const MAX_INPUT_DEVICES: usize = 32;

fn getMilliTimestamp() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * MS_PER_SEC + @divTrunc(@as(i64, @intCast(ts.nsec)), NS_PER_MS);
}

pub const InputEvent = extern struct {
    sec: isize,
    usec: isize,
    type: u16,
    code: u16,
    value: i32,
};

pub const EV_KEY: u16 = 0x01;
pub const EV_REL: u16 = 0x02;
pub const EV_ABS: u16 = 0x03;

pub const REL_X: u16 = 0x00;
pub const REL_Y: u16 = 0x01;
pub const ABS_X: u16 = 0x00;
pub const ABS_Y: u16 = 0x01;
pub const EVDEV_ABS_MAX: i64 = 32767;

pub const BTN_LEFT: u16 = 0x110;
pub const BTN_TOUCH: u16 = 0x14a;

pub const KEY_ESC: u16 = 1;
pub const KEY_1: u16 = 2;
pub const KEY_2: u16 = 3;
pub const KEY_3: u16 = 4;
pub const KEY_4: u16 = 5;
pub const KEY_5: u16 = 6;
pub const KEY_6: u16 = 7;
pub const KEY_7: u16 = 8;
pub const KEY_8: u16 = 9;
pub const KEY_9: u16 = 10;
pub const KEY_0: u16 = 11;
pub const KEY_MINUS: u16 = 12;
pub const KEY_EQUAL: u16 = 13;
pub const KEY_BACKSPACE: u16 = 14;
pub const KEY_TAB: u16 = 15;
pub const KEY_Q: u16 = 16;
pub const KEY_W: u16 = 17;
pub const KEY_E: u16 = 18;
pub const KEY_R: u16 = 19;
pub const KEY_T: u16 = 20;
pub const KEY_Y: u16 = 21;
pub const KEY_U: u16 = 22;
pub const KEY_I: u16 = 23;
pub const KEY_O: u16 = 24;
pub const KEY_P: u16 = 25;
pub const KEY_ENTER: u16 = 28;
pub const KEY_A: u16 = 30;
pub const KEY_S: u16 = 31;
pub const KEY_D: u16 = 32;
pub const KEY_F: u16 = 33;
pub const KEY_G: u16 = 34;
pub const KEY_H: u16 = 35;
pub const KEY_J: u16 = 36;
pub const KEY_K: u16 = 37;
pub const KEY_L: u16 = 38;
pub const KEY_Z: u16 = 44;
pub const KEY_X: u16 = 45;
pub const KEY_C: u16 = 46;
pub const KEY_V: u16 = 47;
pub const KEY_B: u16 = 48;
pub const KEY_N: u16 = 49;
pub const KEY_M: u16 = 50;
pub const KEY_DOT: u16 = 52;
pub const KEY_SLASH: u16 = 53;
pub const KEY_LEFTCTRL: u16 = 29;
pub const KEY_LEFTSHIFT: u16 = 42;
pub const KEY_RIGHTSHIFT: u16 = 54;
pub const KEY_SPACE: u16 = 57;
pub const KEY_F6: u16 = 64;
pub const KEY_RIGHTCTRL: u16 = 97;
pub const KEY_UP: u16 = 103;
pub const KEY_LEFT: u16 = 105;
pub const KEY_RIGHT: u16 = 106;
pub const KEY_DOWN: u16 = 108;
pub const KEY_DELETE: u16 = 111;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Singleton lock: prevent concurrent GUI processes from conflicting on display
    const pid_file_path = "/tmp/.diosix-gui.pid";
    const open_res = linux.open(pid_file_path, .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(open_res)) >= 0) {
        const pfd: i32 = @intCast(open_res);
        var pbuf: [32]u8 = undefined;
        const read_res = linux.read(pfd, &pbuf, pbuf.len);
        _ = linux.close(pfd);
        const signed_read: isize = @bitCast(read_res);
        if (signed_read > 0) {
            const n: usize = @intCast(signed_read);
            const pid_str = std.mem.trim(u8, pbuf[0..n], " \r\n\t");
            if (std.fmt.parseInt(i32, pid_str, 10)) |other_pid| {
                const kill_res = linux.kill(other_pid, @enumFromInt(0));
                const signed_kill: isize = @bitCast(kill_res);
                if (signed_kill == 0) {
                    std.debug.print("diosix-gui: Instance already running (PID {d}). Exiting.\n", .{other_pid});
                    return;
                }
            } else |_| {}
        }
    }

    const creat_res = linux.open(pid_file_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (@as(isize, @bitCast(creat_res)) >= 0) {
        const cfd: i32 = @intCast(creat_res);
        const my_pid = linux.getpid();
        var pbuf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&pbuf, "{d}\n", .{my_pid}) catch "";
        if (s.len > 0) {
            _ = linux.write(cfd, s.ptr, s.len);
        }
        _ = linux.close(cfd);
    }

    var stdout_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&stdout_buf, "Starting Diosix Monolithic GUI (diosix-gui)...\n", .{}) catch return;
    _ = linux.write(1, msg.ptr, msg.len);

    // 1. Initialize Display
    var display = Display.init(allocator) catch |err| {
        std.debug.print("Failed to initialize display: {}\n", .{err});
        return;
    };
    defer display.deinit(allocator);

    std.debug.print("Display initialized: {d}x{d}, Final Fantasy 7/8 theme engine active.\n", .{ display.width, display.height });

    // 2. Initialize Diosix GUI Coordinator
    var gui = try DiosixGui.init(allocator, display.width, display.height);
    defer gui.deinit();

    // 3. Open Evdev Input Devices
    var input_fds: [MAX_INPUT_DEVICES]i32 = undefined;
    var input_count: usize = 0;
    var dev_idx: u8 = 0;
    while (dev_idx < MAX_INPUT_DEVICES) : (dev_idx += 1) {
        var path_buf: [32]u8 = undefined;
        const p_slice = std.fmt.bufPrint(&path_buf, "/dev/input/event{d}", .{dev_idx}) catch continue;
        path_buf[p_slice.len] = 0;
        const dev_z: [*:0]const u8 = @ptrCast(path_buf[0..p_slice.len :0]);
        const rc = linux.open(dev_z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
        const signed_rc: isize = @bitCast(rc);
        if (signed_rc >= 0) {
            input_fds[input_count] = @intCast(signed_rc);
            input_count += 1;
        }
    }

    // 4. Graphical Intro Animation and Audio Chime (Plays once per boot)
    var audio_player = audio_mod.AudioPlayer{};
    defer audio_player.stop();

    if (intro_mod.shouldPlayIntro()) {
        std.debug.print("Playing Diosix graphical intro chime...\n", .{});
        audio_player.start();

        var intro_state = intro_mod.IntroState.init(getMilliTimestamp());
        var intro_last_time: i64 = intro_state.start_time_ms;

        while (intro_state.is_active) {
            const now = getMilliTimestamp();
            const dt: u32 = @intCast(@max(1, now - intro_last_time));
            intro_last_time = now;

            // Check if user pressed key or mouse to skip intro
            var pfds: [MAX_INPUT_DEVICES]linux.pollfd = undefined;
            for (input_fds[0..input_count], 0..) |fd, i| {
                pfds[i] = linux.pollfd{
                    .fd = fd,
                    .events = linux.POLL.IN,
                    .revents = 0,
                };
            }
            const poll_res = linux.poll(&pfds, input_count, 0);
            const signed_poll: isize = @bitCast(poll_res);
            if (signed_poll > 0) {
                var i: usize = 0;
                var skip_requested = false;
                while (i < input_count) : (i += 1) {
                    if ((pfds[i].revents & linux.POLL.IN) != 0) {
                        var ev_buf: [32]InputEvent = undefined;
                        const rd = linux.read(pfds[i].fd, @ptrCast(&ev_buf), @sizeOf(@TypeOf(ev_buf)));
                        const signed_rd: isize = @bitCast(rd);
                        if (signed_rd > 0) {
                            const count = @as(usize, @intCast(signed_rd)) / @sizeOf(InputEvent);
                            for (ev_buf[0..count]) |ev| {
                                // Only explicit Escape (code 1) or Space (code 57) keypress skips the intro
                                if (ev.type == EV_KEY and ev.value == 1 and (ev.code == 1 or ev.code == 57)) {
                                    skip_requested = true;
                                    break;
                                }
                            }
                        }
                    }
                    if (skip_requested) break;
                }
                if (skip_requested) {
                    audio_player.stop();
                    intro_state.skip();
                    break;
                }
            }

            intro_state.tick(dt, now, display.width, display.height);
            intro_state.render(&display.backbuffer, &gui);
            display.flushDamage(fb.Box.fromPosSize(0, 0, display.width, display.height));

            // Pace intro frame rate (~60 FPS)
            const frame_end = getMilliTimestamp();
            const frame_dur = frame_end - now;
            if (frame_dur < FRAME_INTERVAL_MS) {
                var sleep_ts = linux.timespec{
                    .sec = 0,
                    .nsec = @intCast((FRAME_INTERVAL_MS - frame_dur) * 1_000_000),
                };
                _ = linux.nanosleep(&sleep_ts, null);
            }
        }
        std.debug.print("Intro sequence completed (elapsed {d}ms). Handing over to live desktop.\n", .{intro_state.elapsed_ms});
    }

    // 5. Initial Render Frame (Full Screen Composited)
    gui.markFullDirty();
    const init_damage = gui.renderDamaged(&display.clean_buffer);
    display.backbuffer.copyBoxFrom(&display.clean_buffer, init_damage);
    gui.cursor.draw(&display.backbuffer);
    display.prev_cursor_box = gui.cursor.getBox();
    display.prev_cursor_x = gui.cursor.x;
    display.prev_cursor_y = gui.cursor.y;
    display.cursor_drawn = true;
    display.flushDamage(init_damage);

    // 5. Main Multitasking and Event Loop with 60 FPS Frame Pacing
    var last_time: i64 = getMilliTimestamp();
    var last_render_time: i64 = last_time;

    while (true) {
        const cur_time = getMilliTimestamp();
        const elapsed_since_render = cur_time - last_render_time;
        const poll_timeout: i32 = if (elapsed_since_render >= FRAME_INTERVAL_MS)
            0
        else
            @intCast(FRAME_INTERVAL_MS - elapsed_since_render);

        var pfds: [MAX_INPUT_DEVICES]linux.pollfd = undefined;
        for (input_fds[0..input_count], 0..) |fd, i| {
            pfds[i] = linux.pollfd{
                .fd = fd,
                .events = linux.POLL.IN,
                .revents = 0,
            };
        }

        const poll_res = linux.poll(&pfds, input_count, poll_timeout);
        const signed_poll: isize = @bitCast(poll_res);

        const now = getMilliTimestamp();
        const dt_ms: u32 = @intCast(@max(1, now - last_time));
        last_time = now;

        // Preemptive Multitasking: Deliver CPU time to all sub-programs every frame
        gui.tick(dt_ms);

        if (signed_poll > 0) {
            var i: usize = 0;
            while (i < input_count) : (i += 1) {
                if ((pfds[i].revents & linux.POLL.IN) != 0) {
                    var ev_buf: [64]InputEvent = undefined;
                    const rd = linux.read(pfds[i].fd, @ptrCast(&ev_buf), @sizeOf(@TypeOf(ev_buf)));
                    const signed_rd: isize = @bitCast(rd);
                    if (signed_rd > 0) {
                        const count = @as(usize, @intCast(signed_rd)) / @sizeOf(InputEvent);
                        for (ev_buf[0..count]) |ev| {
                            switch (ev.type) {
                                EV_KEY => {
                                    const pressed = (ev.value != 0);
                                    const code = ev.code;

                                    if (code == BTN_LEFT or code == BTN_TOUCH) {
                                        if (pressed) {
                                            gui.handleMouseClick(gui.cursor.x, gui.cursor.y);
                                        } else {
                                            gui.handleMouseRelease();
                                        }
                                        gui.mouse_left_down = pressed;
                                    } else if (code == KEY_LEFTCTRL or code == KEY_RIGHTCTRL) {
                                        gui.ctrl_down = pressed;
                                    } else if (code == KEY_LEFTSHIFT or code == KEY_RIGHTSHIFT) {
                                        gui.shift_down = pressed;
                                    } else {
                                        const key_char = mapEvdevToAscii(code, gui.shift_down);
                                        gui.handleKey(code, key_char, pressed);
                                    }
                                },
                                EV_REL => {
                                    var nx = gui.cursor.x;
                                    var ny = gui.cursor.y;
                                    if (ev.code == REL_X) nx += ev.value;
                                    if (ev.code == REL_Y) ny += ev.value;
                                    nx = std.math.clamp(nx, 0, @as(i32, @intCast(display.width - 1)));
                                    ny = std.math.clamp(ny, 0, @as(i32, @intCast(display.height - 1)));
                                    gui.handleMouseMove(nx, ny, gui.mouse_left_down);
                                },
                                EV_ABS => {
                                    // Handle tablet absolute coordinates
                                    if (ev.code == ABS_X) {
                                        const nx = @divTrunc(@as(i64, ev.value) * @as(i64, @intCast(display.width)), EVDEV_ABS_MAX);
                                        gui.handleMouseMove(@intCast(nx), gui.cursor.y, gui.mouse_left_down);
                                    } else if (ev.code == ABS_Y) {
                                        const ny = @divTrunc(@as(i64, ev.value) * @as(i64, @intCast(display.height)), EVDEV_ABS_MAX);
                                        gui.handleMouseMove(gui.cursor.x, @intCast(ny), gui.mouse_left_down);
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                }
            }
        }

        // Pace frame composition and scanout to the target framerate (~60 FPS)
        if (now - last_render_time >= FRAME_INTERVAL_MS or signed_poll <= 0) {
            last_render_time = now;

            // Render updated frame with intelligent damage tracking
            const damage = gui.renderDamaged(&display.clean_buffer);
            const cursor_moved = (gui.cursor.x != display.prev_cursor_x or gui.cursor.y != display.prev_cursor_y);
            const cursor_box = gui.cursor.getBox();

            if (!damage.isEmpty() or cursor_moved or !display.cursor_drawn) {
                var flush_box = fb.Box{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };

                // 1. If clean_buffer had damage, copy damaged rect to backbuffer
                if (!damage.isEmpty()) {
                    display.backbuffer.copyBoxFrom(&display.clean_buffer, damage);
                    flush_box = flush_box.merge(damage);
                }

                // 2. If cursor moved, restore old cursor area from clean_buffer into backbuffer
                if (cursor_moved and display.cursor_drawn) {
                    display.backbuffer.copyBoxFrom(&display.clean_buffer, display.prev_cursor_box);
                    flush_box = flush_box.merge(display.prev_cursor_box);
                }

                // 3. Stamp cursor sprite onto backbuffer
                gui.cursor.draw(&display.backbuffer);
                flush_box = flush_box.merge(cursor_box);

                display.prev_cursor_box = cursor_box;
                display.prev_cursor_x = gui.cursor.x;
                display.prev_cursor_y = gui.cursor.y;
                display.cursor_drawn = true;

                // 4. Flush only the damaged region to hardware scanout and DRM
                display.flushDamage(flush_box);
            }
        }
    }
}

// Convert evdev keycode to standard ASCII character
fn mapEvdevToAscii(code: u16, shift: bool) ?u8 {
    if (shift) {
        return switch (code) {
            KEY_1 => '!',
            KEY_2 => '@',
            KEY_3 => '#',
            KEY_4 => '$',
            KEY_5 => '%',
            KEY_6 => '^',
            KEY_7 => '&',
            KEY_8 => '*',
            KEY_9 => '(',
            KEY_0 => ')',
            KEY_MINUS => '_',
            KEY_EQUAL => '+',
            KEY_A => 'A',
            KEY_B => 'B',
            KEY_C => 'C',
            KEY_D => 'D',
            KEY_E => 'E',
            KEY_F => 'F',
            KEY_G => 'G',
            KEY_H => 'H',
            KEY_I => 'I',
            KEY_J => 'J',
            KEY_K => 'K',
            KEY_L => 'L',
            KEY_M => 'M',
            KEY_N => 'N',
            KEY_O => 'O',
            KEY_P => 'P',
            KEY_Q => 'Q',
            KEY_R => 'R',
            KEY_S => 'S',
            KEY_T => 'T',
            KEY_U => 'U',
            KEY_V => 'V',
            KEY_W => 'W',
            KEY_X => 'X',
            KEY_Y => 'Y',
            KEY_Z => 'Z',
            KEY_SPACE => ' ',
            KEY_DOT => '>',
            KEY_SLASH => '?',
            else => null,
        };
    }
    return switch (code) {
        KEY_1 => '1',
        KEY_2 => '2',
        KEY_3 => '3',
        KEY_4 => '4',
        KEY_5 => '5',
        KEY_6 => '6',
        KEY_7 => '7',
        KEY_8 => '8',
        KEY_9 => '9',
        KEY_0 => '0',
        KEY_MINUS => '-',
        KEY_EQUAL => '=',
        KEY_A => 'a',
        KEY_B => 'b',
        KEY_C => 'c',
        KEY_D => 'd',
        KEY_E => 'e',
        KEY_F => 'f',
        KEY_G => 'g',
        KEY_H => 'h',
        KEY_I => 'i',
        KEY_J => 'j',
        KEY_K => 'k',
        KEY_L => 'l',
        KEY_M => 'm',
        KEY_N => 'n',
        KEY_O => 'o',
        KEY_P => 'p',
        KEY_Q => 'q',
        KEY_R => 'r',
        KEY_S => 's',
        KEY_T => 't',
        KEY_U => 'u',
        KEY_V => 'v',
        KEY_W => 'w',
        KEY_X => 'x',
        KEY_Y => 'y',
        KEY_Z => 'z',
        KEY_SPACE => ' ',
        KEY_DOT => '.',
        KEY_SLASH => '/',
        else => null,
    };
}

// --- Unit Tests for diosix-gui ---

const testing = std.testing;

test "diosix-gui: surface drawing and translucent window pane" {
    var pixel_buffer: [100 * 100]u32 = undefined;
    @memset(&pixel_buffer, 0x004C8BE0);
    var surface = fb.Surface.init(&pixel_buffer, 100, 100, 400);

    const test_box = fb.Box.fromPosSize(10, 10, 80, 80);
    surface.drawWindowPane(test_box);

    // Check that inside client area is translucent blended with background
    const client_pixel = surface.getPixel(50, 50);
    try testing.expect(client_pixel != 0x004C8BE0);
    try testing.expect(client_pixel != fb.Color.GLASS_BG);

    // Outside corner should remain untouched background
    const outside_corner = surface.getPixel(10, 10);
    try testing.expectEqual(@as(u32, 0x004C8BE0), outside_corner);
}

test "diosix-gui: text rendering with drop shadow" {
    var pixel_buffer: [200 * 50]u32 = undefined;
    @memset(&pixel_buffer, 0);
    var surface = fb.Surface.init(&pixel_buffer, 200, 50, 800);

    font.drawTextWithShadow(&surface, "DIOSIX", 10, 10, fb.Color.WHITE, fb.Color.BLACK);

    // Verify string width measurement
    const measured_w = font.measureString("DIOSIX");
    try testing.expect(measured_w > 0);
}

test "diosix-gui: icon types, sliders, and editing" {
    var ic_ro = Icon.createReadOnly(1, 0, 0, 100, 20, "Read-Only");
    try testing.expectEqualStrings("Read-Only", ic_ro.getText());

    var ic_rw = Icon.createReadWrite(2, 0, 25, 100, 25, "Initial");
    ic_rw.insertChar('!');
    try testing.expectEqualStrings("Initial!", ic_rw.getText());
    ic_rw.deleteBackward();
    try testing.expectEqualStrings("Initial", ic_rw.getText());

    var ic_sl = Icon.createSlider(3, 0, 55, 120, 30, 0, 100, 50, "%");
    ic_sl.adjustSlider(10);
    try testing.expectEqual(@as(i32, 60), ic_sl.slider_val);
    ic_sl.adjustSlider(-100);
    try testing.expectEqual(@as(i32, 0), ic_sl.slider_val); // Clamped to min
}

test "diosix-gui: icon grouping and exclusive radio behavior" {
    const allocator = testing.allocator;
    var win = Window.init(allocator, 1, 0, 0, 300, 300, "Group Test");
    defer win.deinit();

    // Add 3 radio tick boxes in exclusive group 1
    const r1 = try win.addIcon(Icon.createTickBox(10, 10, 10, 200, 24, "Option A", true, 1, .exclusive));
    const r2 = try win.addIcon(Icon.createTickBox(11, 10, 40, 200, 24, "Option B", false, 1, .exclusive));
    const r3 = try win.addIcon(Icon.createTickBox(12, 10, 70, 200, 24, "Option C", false, 1, .exclusive));

    try testing.expect(r1.is_ticked);
    try testing.expect(!r2.is_ticked);
    try testing.expect(!r3.is_ticked);

    // Trigger option B: option A and C must become unticked!
    var dummy_gui: usize = 0;
    win.triggerIcon(@ptrCast(&dummy_gui), r2);

    try testing.expect(!win.icons.items[0].is_ticked);
    try testing.expect(win.icons.items[1].is_ticked);
    try testing.expect(!win.icons.items[2].is_ticked);
}

test "diosix-gui: window offscreen parking and movement" {
    const allocator = testing.allocator;
    var win = Window.init(allocator, 42, 50, 60, 400, 300, "Window Move Test");
    defer win.deinit();

    // Starts parked offscreen
    try testing.expect(!win.is_onscreen);
    try testing.expect(win.x < 0);

    // Bring onscreen
    win.setOnScreen(true);
    try testing.expect(win.is_onscreen);
    try testing.expectEqual(@as(i32, 50), win.x);
    try testing.expectEqual(@as(i32, 60), win.y);

    // Park window back offscreen
    win.setOnScreen(false);
    try testing.expect(!win.is_onscreen);
    try testing.expect(win.x < 0);
}

test "diosix-gui: coordinator initialization and preemptive multitasking" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    try testing.expectEqual(@as(usize, 5), gui.subprograms.items.len);
    try testing.expectEqual(@as(usize, 0), gui.active_sub_idx);

    // Initial subprogram 0 is active: its windows are on-screen
    try testing.expect(gui.windows.items[0].is_onscreen); // specs pane
    try testing.expect(!gui.windows.items[3].is_onscreen); // icon showcase pane parked

    // Check that subprograms get background CPU time on tick
    gui.tick(100);
    gui.tick(500);

    // Switch tab
    gui.activateSubProgram(1);
    try testing.expectEqual(@as(usize, 1), gui.active_sub_idx);

    // Ensure tab 0 windows are parked off-screen and tab 1 windows are on screen
    try testing.expect(!gui.windows.items[0].is_onscreen);
    try testing.expect(gui.windows.items[3].is_onscreen); // icon showcase pane
}

test "diosix-gui: static graduated background rendering" {
    var pixel_buffer: [100 * 100]u32 = undefined;
    var surface = fb.Surface.init(&pixel_buffer, 100, 100, 400);

    const top_col: u32 = 0x004C8BE0; // Light Blue
    const bot_col: u32 = 0x000C1836; // Dark Blue

    surface.drawGraduatedBackground(top_col, bot_col);

    // Top row has light blue hue
    const top_px = surface.getPixel(50, 0);
    const top_b = top_px & 0xFF;
    try testing.expect(top_b >= 200);

    // Bottom row has dark blue hue
    const bot_px = surface.getPixel(50, 99);
    const bot_r = (bot_px >> 16) & 0xFF;
    const bot_b = bot_px & 0xFF;
    try testing.expect(bot_r < 50 and bot_b < 80);

    // Middle row (y=50) is smoothly interpolated between top and bot
    const mid_col = surface.getPixel(50, 50);
    const mid_b = mid_col & 0xFF;
    try testing.expect(mid_b < top_b and mid_b > bot_b);
}

test "diosix-gui: real-time window transparency and backdrop controls" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 800, 600);
    defer gui.deinit();

    // Default transparency is 50%
    try testing.expectEqual(@as(u32, 50), gui.window_transparency);
    try testing.expectEqual(@as(u8, 127), gui.getWindowOpacityAlpha());

    // Adjust transparency to 0% (fully opaque)
    gui.setWindowTransparency(0);
    try testing.expectEqual(@as(u32, 0), gui.window_transparency);
    try testing.expectEqual(@as(u8, 255), gui.getWindowOpacityAlpha());

    // Adjust transparency to 80% (20% opaque)
    gui.setWindowTransparency(80);
    try testing.expectEqual(@as(u32, 80), gui.window_transparency);
    try testing.expectEqual(@as(u8, 51), gui.getWindowOpacityAlpha());

    // Default blur strength is 50% (radius 5)
    try testing.expectEqual(@as(u32, 50), gui.getBlurStrength());
    try testing.expectEqual(@as(u32, 5), gui.getBlurRadius());

    // Adjust blur strength to 100% (radius 10)
    gui.setBlurStrength(100);
    try testing.expectEqual(@as(u32, 100), gui.getBlurStrength());
    try testing.expectEqual(@as(u32, 10), gui.getBlurRadius());

    // Adjust blur strength to 0% (radius 0)
    gui.setBlurStrength(0);
    try testing.expectEqual(@as(u32, 0), gui.getBlurStrength());
    try testing.expectEqual(@as(u32, 0), gui.getBlurRadius());

    // Adjust backdrop colors
    gui.setBackdropTopColor(0x002EB8D8);
    gui.setBackdropBotColor(0x00060B18);
    try testing.expectEqual(@as(u32, 0x002EB8D8), gui.bg_top_color);
    try testing.expectEqual(@as(u32, 0x00060B18), gui.bg_bot_color);
}

test "diosix-gui: surface copyBoxFrom tile copying" {
    var src_buf: [100 * 100]u32 = @splat(0x00FF0000); // Red
    var dst_buf: [100 * 100]u32 = @splat(0x000000FF); // Blue

    var src = fb.Surface.init(&src_buf, 100, 100, 400);
    var dst = fb.Surface.init(&dst_buf, 100, 100, 400);

    // Copy a 20x20 tile at (30, 40)
    const copy_box = fb.Box.fromPosSize(30, 40, 20, 20);
    dst.copyBoxFrom(&src, copy_box);

    // Inside tile should be red
    try testing.expectEqual(@as(u32, 0x00FF0000), dst.getPixel(30, 40));
    try testing.expectEqual(@as(u32, 0x00FF0000), dst.getPixel(49, 59));

    // Outside tile should remain blue
    try testing.expectEqual(@as(u32, 0x000000FF), dst.getPixel(29, 40));
    try testing.expectEqual(@as(u32, 0x000000FF), dst.getPixel(50, 40));
    try testing.expectEqual(@as(u32, 0x000000FF), dst.getPixel(30, 39));
    try testing.expectEqual(@as(u32, 0x000000FF), dst.getPixel(30, 60));
}

test "diosix-gui: intelligent damage tracking and idle frame skipping" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const clean_buf = try allocator.alloc(u32, 1280 * 800);
    defer allocator.free(clean_buf);
    var clean_surface = fb.Surface.init(clean_buf.ptr, 1280, 800, 1280 * 4);

    // 1. On startup, gui is full dirty
    try testing.expect(gui.isDirty());
    const init_damage = gui.renderDamaged(&clean_surface);
    try testing.expectEqual(@as(i32, 0), init_damage.x0);
    try testing.expectEqual(@as(i32, 0), init_damage.y0);
    try testing.expectEqual(@as(i32, 1280), init_damage.x1);
    try testing.expectEqual(@as(i32, 800), init_damage.y1);

    // 2. Immediately afterwards (idle), damage must be completely EMPTY!
    try testing.expect(!gui.isDirty());
    const idle_damage = gui.renderDamaged(&clean_surface);
    try testing.expect(idle_damage.isEmpty());

    // 3. Updating an icon in Window 0 marks only that window dirty
    if (gui.findIcon(100, 1008)) |ic| { // WIN_SPECS_ID, ICON_UPTIME_ID
        ic.setText("Uptime: 5s");
    }
    try testing.expect(gui.isDirty());

    // 4. Redraw damaged region: must ONLY damage window 0's bounds, not full screen!
    const win_damage = gui.renderDamaged(&clean_surface);
    try testing.expect(!win_damage.isEmpty());
    try testing.expect(win_damage.width() <= 780);
    try testing.expect(win_damage.height() <= 536);
    try testing.expect(!gui.isDirty());
}

test "diosix-gui: icon text selection, select-all, and cut/copy/paste primitives" {
    var ic = Icon.createReadWrite(101, 10, 10, 200, 30, "Hello World");
    try testing.expectEqualStrings("Hello World", ic.getText());
    try testing.expect(!ic.hasSelection());

    // 1. Select all
    ic.selectAll();
    try testing.expect(ic.hasSelection());
    try testing.expectEqualStrings("Hello World", ic.getSelectedText());

    // 2. Delete selection
    try testing.expect(ic.deleteSelection());
    try testing.expectEqualStrings("", ic.getText());
    try testing.expect(!ic.hasSelection());
    try testing.expectEqual(@as(usize, 0), ic.cursor_pos);

    // 3. Insert string
    ic.insertString("Diosix Microkernel");
    try testing.expectEqualStrings("Diosix Microkernel", ic.getText());

    // 4. Partial selection: select "Microkernel"
    ic.selection_start = 7;
    ic.selection_end = 18;
    try testing.expect(ic.hasSelection());
    try testing.expectEqualStrings("Microkernel", ic.getSelectedText());

    // 5. Delete selection
    try testing.expect(ic.deleteSelection());
    try testing.expectEqualStrings("Diosix ", ic.getText());
    try testing.expectEqual(@as(usize, 7), ic.cursor_pos);

    // 6. Clear field
    ic.clearField();
    try testing.expectEqualStrings("", ic.getText());
    try testing.expectEqual(@as(usize, 0), ic.cursor_pos);
}

test "diosix-gui: keyboard handling with arrow keys, tab navigation, and control codes" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // Switch to Subprogram 1 (Interactive controls showcase)
    gui.activateSubProgram(1);

    // Get active window (Controls pane)
    const win = gui.getActiveWindow().?;

    // Find the read-write text field icon
    var rw_idx: ?usize = null;
    for (win.icons.items, 0..) |*ic, i| {
        if (ic.icon_type == .read_write_text) {
            rw_idx = i;
            break;
        }
    }
    try testing.expect(rw_idx != null);
    win.setFocusedIndex(rw_idx.?);

    const rw_icon = &win.icons.items[rw_idx.?];
    try testing.expect(rw_icon.is_focused);

    // Reset initial text
    rw_icon.setText("Diosix RISC-V");
    try testing.expectEqualStrings("Diosix RISC-V", rw_icon.getText());
    try testing.expectEqual(@as(usize, 13), rw_icon.cursor_pos);

    // 1. Arrow Keys: Left moves cursor backward, Right moves cursor forward
    gui.handleKey(gui_mod.Key.LEFT, null, true);
    try testing.expectEqual(@as(usize, 12), rw_icon.cursor_pos);
    gui.handleKey(gui_mod.Key.LEFT, null, true);
    try testing.expectEqual(@as(usize, 11), rw_icon.cursor_pos);
    gui.handleKey(gui_mod.Key.RIGHT, null, true);
    try testing.expectEqual(@as(usize, 12), rw_icon.cursor_pos);

    // 2. Control-A: Select all
    gui.handleKeyWithModifiers(gui_mod.Key.A, 'a', true, true, false);
    try testing.expect(rw_icon.hasSelection());
    try testing.expectEqualStrings("Diosix RISC-V", rw_icon.getSelectedText());

    // 3. Control-C: Copy selected text to clipboard
    gui.handleKeyWithModifiers(gui_mod.Key.C, 'c', true, true, false);
    try testing.expectEqualStrings("Diosix RISC-V", gui.getClipboard());

    // 4. Control-X: Cut selected text to clipboard
    gui.handleKeyWithModifiers(gui_mod.Key.X, 'x', true, true, false);
    try testing.expectEqualStrings("", rw_icon.getText());
    try testing.expectEqualStrings("Diosix RISC-V", gui.getClipboard());

    // 5. Control-V: Paste from clipboard
    gui.handleKeyWithModifiers(gui_mod.Key.V, 'v', true, true, false);
    try testing.expectEqualStrings("Diosix RISC-V", rw_icon.getText());

    // 6. Typing numbers in text field must NOT trigger subprogram tab switching!
    gui.handleKey(0, '1', true);
    gui.handleKey(0, '2', true);
    try testing.expectEqualStrings("Diosix RISC-V12", rw_icon.getText());
    try testing.expectEqual(@as(usize, 1), gui.active_sub_idx); // Still on tab 1!

    // 7. Control-U: Clear the whole field
    gui.handleKeyWithModifiers(gui_mod.Key.U, 'u', true, true, false);
    try testing.expectEqualStrings("", rw_icon.getText());

    // 8. Tab Navigation: moves focus to the next item (away from text field to slider)
    gui.handleKey(gui_mod.Key.TAB, null, true);
    try testing.expect(!rw_icon.is_focused);
    try testing.expect(win.focused_icon_idx != rw_idx.?);

    const next_icon = &win.icons.items[win.focused_icon_idx.?];
    try testing.expectEqual(icon_mod.IconType.slider, next_icon.icon_type);

    // 9. Slider arrow navigation: Left / Right adjusts slider
    const initial_val = next_icon.slider_val;
    gui.handleKey(gui_mod.Key.LEFT, null, true);
    try testing.expectEqual(initial_val - 5, next_icon.slider_val);
    gui.handleKey(gui_mod.Key.RIGHT, null, true);
    try testing.expectEqual(initial_val, next_icon.slider_val);

    // 10. Shift-Tab moves focus back to previous item (the text field)
    gui.handleKeyWithModifiers(gui_mod.Key.TAB, null, true, false, true);
    try testing.expect(rw_icon.is_focused);
}

test "diosix-gui: mouse click and select dragging in text field" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    gui.activateSubProgram(1);
    const win = gui.getActiveWindow().?;

    var rw_idx: ?usize = null;
    for (win.icons.items, 0..) |*ic, i| {
        if (ic.icon_type == .read_write_text) {
            rw_idx = i;
            break;
        }
    }
    const icon = &win.icons.items[rw_idx.?];
    icon.setText("Diosix Drag Test");

    // Click at beginning of text field
    const click_x = win.x + icon.rel_x + 10;
    const click_y = win.y + icon.rel_y + 10;

    _ = win.handleMouseClick(@ptrCast(&gui), click_x, click_y);
    try testing.expect(icon.is_focused);
    try testing.expect(icon.is_dragging_select);
    try testing.expectEqual(@as(usize, 0), icon.selection_start.?);

    // Drag mouse to the right across multiple characters
    const drag_x = win.x + icon.rel_x + 80;
    _ = win.handleMouseMove(@ptrCast(&gui), drag_x, click_y, true);
    try testing.expect(icon.hasSelection());
    try testing.expect(icon.selection_end.? > 0);

    // Release mouse button
    _ = win.handleMouseRelease();
    try testing.expect(!icon.is_dragging_select);
    try testing.expect(icon.hasSelection());

    // Backspace on active mouse-drag selection deletes the selected text
    gui.handleKey(gui_mod.Key.BACKSPACE, null, true);
    try testing.expect(!icon.hasSelection());
    try testing.expect(icon.getText().len < 16);
}

test "diosix-gui: keyboard navigation between panes via Tab, F6, and Left/Right arrows" {
    const guests_sub = @import("subprograms/guests.zig");
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // Activate Guests subprogram (tab index 2)
    gui.activateSubProgram(2);

    // Verify initial active window is Guest List (first interactive pane)
    const win_list = gui.getActiveWindow().?;
    try testing.expectEqual(guests_sub.WIN_GUEST_LIST_ID, win_list.id);
    try testing.expect(win_list.focused_icon_idx != null);
    try testing.expectEqual(guests_sub.ICON_GUEST_ROW1_ID, win_list.icons.items[win_list.focused_icon_idx.?].id);

    // 1. Press Key.RIGHT on a button in the left pane to jump to the right pane (Domain Actions)
    gui.handleKey(gui_mod.Key.RIGHT, null, true);
    const win_actions = gui.getActiveWindow().?;
    try testing.expectEqual(guests_sub.WIN_GUEST_ACTIONS_ID, win_actions.id);
    try testing.expect(win_actions.focused_icon_idx != null);
    try testing.expectEqual(guests_sub.ICON_GUEST_ACTION_LAUNCH_ID, win_actions.icons.items[win_actions.focused_icon_idx.?].id);

    // 2. Press Key.LEFT on an action button in the right pane to jump back to the left pane
    gui.handleKey(gui_mod.Key.LEFT, null, true);
    try testing.expectEqual(guests_sub.WIN_GUEST_LIST_ID, gui.getActiveWindow().?.id);

    // 3. Press Key.F6 to cycle directly between panes
    gui.handleKey(gui_mod.Key.F6, null, true);
    try testing.expectEqual(guests_sub.WIN_GUEST_ACTIONS_ID, gui.getActiveWindow().?.id);
    gui.handleKey(gui_mod.Key.F6, null, true);
    try testing.expectEqual(guests_sub.WIN_GUEST_LIST_ID, gui.getActiveWindow().?.id);

    // 4. Tab through all 3 guest items in the inventory pane and overflow into Domain Actions pane
    // Currently on item 0 (row 1).
    gui.handleKey(gui_mod.Key.TAB, null, true); // to row 2
    try testing.expectEqual(guests_sub.WIN_GUEST_LIST_ID, gui.getActiveWindow().?.id);
    gui.handleKey(gui_mod.Key.TAB, null, true); // to row 3
    try testing.expectEqual(guests_sub.WIN_GUEST_LIST_ID, gui.getActiveWindow().?.id);
    // Tab again: reaches end of Guest List and transitions into Domain Actions pane!
    gui.handleKey(gui_mod.Key.TAB, null, true);
    try testing.expectEqual(guests_sub.WIN_GUEST_ACTIONS_ID, gui.getActiveWindow().?.id);
    try testing.expectEqual(guests_sub.ICON_GUEST_ACTION_LAUNCH_ID, gui.getActiveWindow().?.icons.items[gui.getActiveWindow().?.focused_icon_idx.?].id);

    // 5. Shift-Tab underflow from top of Domain Actions pane wraps back to bottom of Guest List pane
    gui.handleKeyWithModifiers(gui_mod.Key.TAB, null, true, false, true);
    try testing.expectEqual(guests_sub.WIN_GUEST_LIST_ID, gui.getActiveWindow().?.id);
    try testing.expectEqual(guests_sub.ICON_GUEST_ROW3_ID, gui.getActiveWindow().?.icons.items[gui.getActiveWindow().?.focused_icon_idx.?].id);
}

test "diosix-gui: action button selection via Space and Enter with press and release feedback" {
    const guests_sub = @import("subprograms/guests.zig");
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    gui.activateSubProgram(2);

    // Jump to Domain Actions pane
    gui.handleKey(gui_mod.Key.RIGHT, null, true);
    const win = gui.getActiveWindow().?;
    try testing.expectEqual(guests_sub.WIN_GUEST_ACTIONS_ID, win.id);

    // Focused button is Launch Guest
    const btn_launch = &win.icons.items[win.focused_icon_idx.?];
    try testing.expectEqual(guests_sub.ICON_GUEST_ACTION_LAUNCH_ID, btn_launch.id);
    try testing.expect(!btn_launch.is_active_press);

    // 1. Press SPACE: button becomes active press and executes callback
    gui.handleKey(gui_mod.Key.SPACE, ' ', true);
    try testing.expect(btn_launch.is_active_press);

    // Verify detail pane text updated by action callback
    const detail_icon = gui.findIcon(guests_sub.WIN_GUEST_DETAILS_ID, guests_sub.ICON_GUEST_DETAIL_TEXT_ID).?;
    try testing.expectEqualStrings("Spawn Command: dsx run default --name guest-vm --ram 512M --vcpus 2", detail_icon.getText());

    // 2. Release SPACE: button releases from active press
    gui.handleKey(gui_mod.Key.SPACE, ' ', false);
    try testing.expect(!btn_launch.is_active_press);

    // 3. Move down to Terminate Domain button
    gui.handleKey(gui_mod.Key.DOWN, null, true);
    const btn_stop = &win.icons.items[win.focused_icon_idx.?];
    try testing.expectEqual(guests_sub.ICON_GUEST_ACTION_STOP_ID, btn_stop.id);

    // 4. Press ENTER: button becomes active press and executes terminate callback
    gui.handleKey(gui_mod.Key.ENTER, '\n', true);
    try testing.expect(btn_stop.is_active_press);
    try testing.expectEqualStrings("Terminate Command: Sending hypercall stop request to target child domain.", detail_icon.getText());

    // 5. Release ENTER: button releases
    gui.handleKey(gui_mod.Key.ENTER, '\n', false);
    try testing.expect(!btn_stop.is_active_press);
}

test "diosix-gui: clipboard overflow immunity with arbitrarily long strings and multi-byte UTF-8" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    // 1. Attempt to copy an oversized 1000-byte ASCII string into the 256-byte clipboard
    var huge_buf: [1000]u8 = undefined;
    @memset(&huge_buf, 'X');
    gui.setClipboard(&huge_buf);

    // Verify clipboard safely clamped to CLIPBOARD_CAPACITY (256 bytes)
    const clip = gui.getClipboard();
    try testing.expectEqual(@as(usize, gui_mod.CLIPBOARD_CAPACITY), clip.len);
    try testing.expectEqual(@as(u8, 'X'), clip[0]);
    try testing.expectEqual(@as(u8, 'X'), clip[255]);
    // Guaranteed null terminator in buffer
    try testing.expectEqual(@as(u8, 0), gui.clipboard_buf[256]);

    // 2. Test multi-byte UTF-8 boundary truncation safety
    // Create a 255-byte ASCII prefix, followed by a 3-byte UTF-8 sequence (e.g. '€' = 0xE2 0x82 0xAC)
    var utf8_test_buf: [300]u8 = undefined;
    @memset(utf8_test_buf[0..255], 'A');
    utf8_test_buf[255] = 0xE2;
    utf8_test_buf[256] = 0x82;
    utf8_test_buf[257] = 0xAC;
    @memset(utf8_test_buf[258..300], 'B');

    // Passing this to setClipboard would truncate at index 256 right in the middle of '€' (after 0xE2).
    // Our hardened setClipboard must detect this and truncate safely BEFORE the incomplete sequence!
    gui.setClipboard(&utf8_test_buf);
    const safe_clip = gui.getClipboard();
    try testing.expectEqual(@as(usize, 255), safe_clip.len);
    try testing.expectEqual(@as(u8, 0), gui.clipboard_buf[255]);

    // 3. Test pasting oversized clipboard data into a text field
    gui.activateSubProgram(1);
    const win = gui.getActiveWindow().?;
    var rw_icon: *icon_mod.Icon = undefined;
    for (win.icons.items) |*ic| {
        if (ic.icon_type == .read_write_text) {
            rw_icon = ic;
            break;
        }
    }

    // Set clipboard to a 256-byte string
    var clip_256: [256]u8 = undefined;
    @memset(&clip_256, 'Z');
    gui.setClipboard(&clip_256);

    // Paste into text field with max_input_len = 64
    rw_icon.clearField();
    rw_icon.insertString(gui.getClipboard());

    // Verify text field length is strictly clamped to max_input_len (64)
    try testing.expectEqual(@as(usize, rw_icon.max_input_len), rw_icon.text_len);
    try testing.expect(rw_icon.text_len < rw_icon.text_buf.len);
    try testing.expectEqual(@as(u8, 0), rw_icon.text_buf[rw_icon.text_len]);
}

test "diosix-gui: guest VM domain viewer with live video viewport and resource usage telemetry" {
    const guests_sub = @import("subprograms/guests.zig");
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    gui.activateSubProgram(2);

    // 1. Initial State: second-vm selected (VirtIO-GPU active, video signal true)
    const vid_icon = gui.findIcon(guests_sub.WIN_GUEST_VIDEO_ID, guests_sub.ICON_GUEST_VIDEO_VIEWPORT_ID).?;
    try testing.expectEqualStrings("second-vm", vid_icon.getText());
    try testing.expect(vid_icon.video_has_signal);

    const cpu_meter = gui.findIcon(guests_sub.WIN_GUEST_DETAILS_ID, guests_sub.ICON_GUEST_METER_CPU_ID).?;
    try testing.expectEqual(@as(u32, 42), cpu_meter.progress_val);
    try testing.expect(std.mem.indexOf(u8, cpu_meter.getText(), "42%") != null);

    const ram_meter = gui.findIcon(guests_sub.WIN_GUEST_DETAILS_ID, guests_sub.ICON_GUEST_METER_RAM_ID).?;
    try testing.expectEqual(@as(u32, 55), ram_meter.progress_val);
    try testing.expect(std.mem.indexOf(u8, ram_meter.getText(), "141 MB / 256 MB") != null);

    const disk_meter = gui.findIcon(guests_sub.WIN_GUEST_DETAILS_ID, guests_sub.ICON_GUEST_METER_DISK_ID).?;
    try testing.expectEqual(@as(u32, 35), disk_meter.progress_val);
    try testing.expect(std.mem.indexOf(u8, disk_meter.getText(), "184 MB / 512 MB") != null);

    const disk_text = gui.findIcon(guests_sub.WIN_GUEST_DETAILS_ID, guests_sub.ICON_GUEST_TEXT_DISK_INFO_ID).?;
    try testing.expect(std.mem.indexOf(u8, disk_text.getText(), "3.4 MB/s Read, 1.2 MB/s Write") != null);
    try testing.expect(std.mem.indexOf(u8, disk_text.getText(), "IOPS: 480") != null);

    // 2. Select debian-vm (Row 2): high load domain with VirtIO-GPU
    const row2 = gui.findIcon(guests_sub.WIN_GUEST_LIST_ID, guests_sub.ICON_GUEST_ROW2_ID).?;
    guests_sub.onGuestRowClicked(&gui, undefined, row2);

    try testing.expectEqualStrings("debian-vm", vid_icon.getText());
    try testing.expect(vid_icon.video_has_signal);
    try testing.expectEqual(@as(u32, 68), cpu_meter.progress_val);
    try testing.expectEqual(@as(u32, 59), ram_meter.progress_val);
    try testing.expectEqual(@as(u32, 37), disk_meter.progress_val);
    try testing.expect(std.mem.indexOf(u8, disk_text.getText(), "12.8 MB/s Read, 4.5 MB/s Write") != null);
    try testing.expect(std.mem.indexOf(u8, disk_text.getText(), "IOPS: 1240") != null);

    // 3. Select micro-guest (Row 3): headless domain with no GPU output
    const row3 = gui.findIcon(guests_sub.WIN_GUEST_LIST_ID, guests_sub.ICON_GUEST_ROW3_ID).?;
    guests_sub.onGuestRowClicked(&gui, undefined, row3);

    try testing.expectEqualStrings("micro-guest", vid_icon.getText());
    try testing.expect(!vid_icon.video_has_signal); // Headless CRT diagnostic panel
    try testing.expectEqual(@as(u32, 14), cpu_meter.progress_val);
    try testing.expectEqual(@as(u32, 28), ram_meter.progress_val);
    try testing.expectEqual(@as(u32, 28), disk_meter.progress_val);
    try testing.expect(std.mem.indexOf(u8, disk_text.getText(), "0.2 MB/s Read, 0.1 MB/s Write") != null);

    // 4. Terminate selected domain: verifies video signal and CPU telemetry drop
    const btn_stop = gui.findIcon(guests_sub.WIN_GUEST_ACTIONS_ID, guests_sub.ICON_GUEST_ACTION_STOP_ID).?;
    guests_sub.onStopGuestClicked(&gui, undefined, btn_stop);

    try testing.expect(!vid_icon.video_has_signal);
    try testing.expectEqual(@as(u32, 0), cpu_meter.progress_val);
    try testing.expectEqual(@as(u32, 0), ram_meter.progress_val);
    try testing.expect(std.mem.indexOf(u8, disk_text.getText(), "0.0 MB/s Read, 0.0 MB/s Write") != null);
    try testing.expect(std.mem.indexOf(u8, disk_text.getText(), "IOPS: 0") != null);
}

test "diosix-gui: fullscreen video display toggle and ESC key handling" {
    const guests_sub = @import("subprograms/guests.zig");
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    gui.activateSubProgram(2);

    // 1. Initially fullscreen is inactive
    try testing.expect(!guests_sub.isFullscreen());

    var win_list_onscreen: bool = false;
    var win_fs_onscreen: bool = false;
    for (gui.windows.items) |win| {
        if (win.id == guests_sub.WIN_GUEST_LIST_ID) win_list_onscreen = win.is_onscreen;
        if (win.id == guests_sub.WIN_GUEST_FULLSCREEN_VIDEO_ID) win_fs_onscreen = win.is_onscreen;
    }
    try testing.expect(win_list_onscreen);
    try testing.expect(!win_fs_onscreen);

    // 2. Press 'F' key to toggle fullscreen
    gui.handleKey(gui_mod.Key.F, 'f', true);
    try testing.expect(guests_sub.isFullscreen());

    for (gui.windows.items) |win| {
        if (win.id == guests_sub.WIN_GUEST_LIST_ID) win_list_onscreen = win.is_onscreen;
        if (win.id == guests_sub.WIN_GUEST_FULLSCREEN_VIDEO_ID) win_fs_onscreen = win.is_onscreen;
    }
    try testing.expect(!win_list_onscreen);
    try testing.expect(win_fs_onscreen);

    // Fullscreen viewport is populated
    const fs_vid = gui.findIcon(guests_sub.WIN_GUEST_FULLSCREEN_VIDEO_ID, guests_sub.ICON_GUEST_FULLSCREEN_VIEWPORT_ID).?;
    try testing.expectEqualStrings("second-vm", fs_vid.getText());
    try testing.expect(fs_vid.video_has_signal);

    // 3. Press ESC key to exit fullscreen
    gui.handleKey(gui_mod.Key.ESC, null, true);
    try testing.expect(!guests_sub.isFullscreen());

    for (gui.windows.items) |win| {
        if (win.id == guests_sub.WIN_GUEST_LIST_ID) win_list_onscreen = win.is_onscreen;
        if (win.id == guests_sub.WIN_GUEST_FULLSCREEN_VIDEO_ID) win_fs_onscreen = win.is_onscreen;
    }
    try testing.expect(win_list_onscreen);
    try testing.expect(!win_fs_onscreen);
}

fn writePpmFile(surface: *const fb.Surface, path_z: [*:0]const u8) !void {
    const rc = linux.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    const signed_rc: isize = @bitCast(rc);
    if (signed_rc < 0) return error.OpenFileFailed;
    const fd: i32 = @intCast(signed_rc);
    defer _ = linux.close(fd);

    var hdr_buf: [32]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "P6\n{d} {d}\n255\n", .{ surface.width, surface.height }) catch return;
    _ = linux.write(fd, hdr.ptr, hdr.len);

    var rgb_row: [1280 * 3]u8 = undefined;
    var y: u32 = 0;
    while (y < surface.height) : (y += 1) {
        var x: u32 = 0;
        while (x < surface.width) : (x += 1) {
            const px = surface.pixels[y * surface.stridePixels() + x];
            rgb_row[x * 3 + 0] = @intCast((px >> 16) & 0xFF);
            rgb_row[x * 3 + 1] = @intCast((px >> 8) & 0xFF);
            rgb_row[x * 3 + 2] = @intCast(px & 0xFF);
        }
        _ = linux.write(fd, &rgb_row, surface.width * 3);
    }
}

test "diosix-gui: render guest screenshots for visualization" {
    const guests_sub = @import("subprograms/guests.zig");
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const pixel_mem = try allocator.alloc(u32, 1280 * 800);
    defer allocator.free(pixel_mem);
    var surface = fb.Surface.init(pixel_mem.ptr, 1280, 800, 1280 * @sizeOf(u32));

    // 1. Render Tab 2 (Guests) with second-vm (VirtIO-GPU)
    gui.activateSubProgram(2);
    gui.markFullDirty();
    _ = gui.renderDamaged(&surface);
    try writePpmFile(&surface, "/tmp/diosix_guests_overview.ppm");

    // 2. Select micro-guest (headless domain)
    const row3 = gui.findIcon(guests_sub.WIN_GUEST_LIST_ID, guests_sub.ICON_GUEST_ROW3_ID).?;
    guests_sub.onGuestRowClicked(&gui, undefined, row3);
    gui.markFullDirty();
    _ = gui.renderDamaged(&surface);
    try writePpmFile(&surface, "/tmp/diosix_guests_headless.ppm");

    // 3. Switch back to second-vm and enter Fullscreen Video View
    const row1 = gui.findIcon(guests_sub.WIN_GUEST_LIST_ID, guests_sub.ICON_GUEST_ROW1_ID).?;
    guests_sub.onGuestRowClicked(&gui, undefined, row1);
    guests_sub.enterFullscreen(&gui);
    gui.markFullDirty();
    _ = gui.renderDamaged(&surface);
    try writePpmFile(&surface, "/tmp/diosix_guests_fullscreen.ppm");
}

test "diosix-gui: render intro animation frames for the two warm moments" {
    const allocator = testing.allocator;
    var gui = try DiosixGui.init(allocator, 1280, 800);
    defer gui.deinit();

    const pixel_mem = try allocator.alloc(u32, 1280 * 800);
    defer allocator.free(pixel_mem);
    var surface = fb.Surface.init(pixel_mem.ptr, 1280, 800, 1280 * @sizeOf(u32));

    var intro = intro_mod.IntroState.init(0);

    // Capture key animation moments for verification:
    // Spell-out left to right:
    intro.elapsed_ms = 700; // 'd'
    intro.render(&surface, &gui);
    try writePpmFile(&surface, "/tmp/diosix_intro_step1_d.ppm");

    intro.elapsed_ms = 900; // 'di'
    intro.render(&surface, &gui);
    try writePpmFile(&surface, "/tmp/diosix_intro_step2_di.ppm");

    intro.elapsed_ms = 1100; // 'dio'
    intro.render(&surface, &gui);
    try writePpmFile(&surface, "/tmp/diosix_intro_step3_dio.ppm");

    intro.elapsed_ms = 1300; // 'dios'
    intro.render(&surface, &gui);
    try writePpmFile(&surface, "/tmp/diosix_intro_step4_dios.ppm");

    intro.elapsed_ms = 1500; // 'diosi'
    intro.render(&surface, &gui);
    try writePpmFile(&surface, "/tmp/diosix_intro_step5_diosi.ppm");

    intro.elapsed_ms = 1700; // 'diosix'
    intro.render(&surface, &gui);
    try writePpmFile(&surface, "/tmp/diosix_intro_step6_diosix.ppm");

    // Moment 1 peak with soft white corona:
    intro.elapsed_ms = 2100; // 'diosix' + soft white corona
    intro.render(&surface, &gui);
    try writePpmFile(&surface, "/tmp/diosix_intro_moment1.ppm");

    // Fade-out left to right:
    intro.elapsed_ms = 3200; // ' iosix'
    intro.render(&surface, &gui);
    try writePpmFile(&surface, "/tmp/diosix_intro_step7_iosix.ppm");

    intro.elapsed_ms = 3400; // '  osix'
    intro.render(&surface, &gui);
    try writePpmFile(&surface, "/tmp/diosix_intro_step8_osix.ppm");

    intro.elapsed_ms = 3600; // '   six'
    intro.render(&surface, &gui);
    try writePpmFile(&surface, "/tmp/diosix_intro_step9_six.ppm");

    intro.elapsed_ms = 3800; // '    ix'
    intro.render(&surface, &gui);
    try writePpmFile(&surface, "/tmp/diosix_intro_step10_ix.ppm");

    intro.elapsed_ms = 4000; // '     x'
    intro.render(&surface, &gui);
    try writePpmFile(&surface, "/tmp/diosix_intro_step11_x.ppm");

    // Moment 2 GUI Bloom & Settled:
    intro.elapsed_ms = 6000;
    intro.render(&surface, &gui);
    try writePpmFile(&surface, "/tmp/diosix_intro_moment2.ppm");

    intro.elapsed_ms = 8000;
    intro.render(&surface, &gui);
    try writePpmFile(&surface, "/tmp/diosix_intro_settled.ppm");
}

test "diosix-gui: graphical clipping of icons to bounding box" {
    const allocator = testing.allocator;
    const s_w: u32 = 200;
    const s_h: u32 = 100;
    const pixel_mem = try allocator.alloc(u32, s_w * s_h);
    defer allocator.free(pixel_mem);
    @memset(pixel_mem, 0);
    var surface = fb.Surface.init(pixel_mem.ptr, s_w, s_h, s_w * @sizeOf(u32));

    // Create a read-only text icon at (20, 20) with width 50, height 24
    // Give it a 500px wide string that would vastly exceed the 50px width without clipping
    var label_icon = icon_mod.Icon.createReadOnly(
        1001,
        20,
        20,
        50,
        24,
        "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW",
    );

    label_icon.render(&surface, 0, 0, false);

    // Verify that pixels inside [20..70, 20..44] contain rendered glyph pixels
    var inside_non_zero: usize = 0;
    var y: u32 = 20;
    while (y < 44) : (y += 1) {
        var x: u32 = 20;
        while (x < 70) : (x += 1) {
            if (pixel_mem[y * s_w + x] != 0) {
                inside_non_zero += 1;
            }
        }
    }
    try testing.expect(inside_non_zero > 0);

    // Verify that NO pixels outside the bounding box were modified
    // 1. Right of bounding box (x >= 70): must be all zero!
    y = 0;
    while (y < s_h) : (y += 1) {
        var x: u32 = 70;
        while (x < s_w) : (x += 1) {
            try testing.expectEqual(@as(u32, 0), pixel_mem[y * s_w + x]);
        }
    }

    // 2. Left of bounding box (x < 20): must be all zero!
    y = 0;
    while (y < s_h) : (y += 1) {
        var x: u32 = 0;
        while (x < 20) : (x += 1) {
            try testing.expectEqual(@as(u32, 0), pixel_mem[y * s_w + x]);
        }
    }

    // 3. Above bounding box (y < 20): must be all zero!
    y = 0;
    while (y < 20) : (y += 1) {
        var x: u32 = 0;
        while (x < s_w) : (x += 1) {
            try testing.expectEqual(@as(u32, 0), pixel_mem[y * s_w + x]);
        }
    }

    // 4. Below bounding box (y >= 44): must be all zero!
    y = 44;
    while (y < s_h) : (y += 1) {
        var x: u32 = 0;
        while (x < s_w) : (x += 1) {
            try testing.expectEqual(@as(u32, 0), pixel_mem[y * s_w + x]);
        }
    }
}

test "diosix-gui: graphical clipping inside button and editable text field" {
    const allocator = testing.allocator;
    const s_w: u32 = 180;
    const s_h: u32 = 80;
    const pixel_mem = try allocator.alloc(u32, s_w * s_h);
    defer allocator.free(pixel_mem);

    // 1. Test Button Clipping
    @memset(pixel_mem, 0);
    var surface = fb.Surface.init(pixel_mem.ptr, s_w, s_h, s_w * @sizeOf(u32));

    var btn = icon_mod.Icon.createButton(
        2001,
        10,
        10,
        60,
        30,
        "An Extremely Long Button Label That Exceeds Width",
    );
    btn.render(&surface, 0, 0, false);

    // Pixels to the right of the button (x >= 70) must remain strictly 0
    var y: u32 = 0;
    while (y < s_h) : (y += 1) {
        var x: u32 = 70;
        while (x < s_w) : (x += 1) {
            try testing.expectEqual(@as(u32, 0), pixel_mem[y * s_w + x]);
        }
    }

    // 2. Test Editable Text Field Clipping
    @memset(pixel_mem, 0);
    var field = icon_mod.Icon.createReadWrite(
        2002,
        10,
        10,
        60,
        28,
        "Default",
    );
    field.insertString("0123456789012345678901234567890123456789");
    field.render(&surface, 0, 0, false);

    // Pixels to the right of the field (x >= 70) must remain strictly 0
    y = 0;
    while (y < s_h) : (y += 1) {
        var x: u32 = 70;
        while (x < s_w) : (x += 1) {
            try testing.expectEqual(@as(u32, 0), pixel_mem[y * s_w + x]);
        }
    }
}

test "diosix-gui: Surface pushClip and popClip stack nesting" {
    const allocator = testing.allocator;
    const s_w: u32 = 100;
    const s_h: u32 = 100;
    const pixel_mem = try allocator.alloc(u32, s_w * s_h);
    defer allocator.free(pixel_mem);
    var surface = fb.Surface.init(pixel_mem.ptr, s_w, s_h, s_w * @sizeOf(u32));

    // Default clip is full surface
    try testing.expectEqual(@as(i32, 0), surface.clip.x0);
    try testing.expectEqual(@as(i32, 0), surface.clip.y0);
    try testing.expectEqual(@as(i32, 100), surface.clip.x1);
    try testing.expectEqual(@as(i32, 100), surface.clip.y1);

    // Push clip (10, 10, 50, 50) -> x0=10, y0=10, x1=60, y1=60
    const clip1 = surface.pushClip(fb.Box.fromPosSize(10, 10, 50, 50));
    try testing.expectEqual(@as(i32, 10), surface.clip.x0);
    try testing.expectEqual(@as(i32, 10), surface.clip.y0);
    try testing.expectEqual(@as(i32, 60), surface.clip.x1);
    try testing.expectEqual(@as(i32, 60), surface.clip.y1);

    // Push intersecting clip (30, 30, 50, 50) -> x0=30, y0=30, x1=80, y1=80
    // Intersection with (10, 10, 60, 60) is (30, 30, 60, 60)
    const clip2 = surface.pushClip(fb.Box.fromPosSize(30, 30, 50, 50));
    try testing.expectEqual(@as(i32, 30), surface.clip.x0);
    try testing.expectEqual(@as(i32, 30), surface.clip.y0);
    try testing.expectEqual(@as(i32, 60), surface.clip.x1);
    try testing.expectEqual(@as(i32, 60), surface.clip.y1);

    // Pop clip2
    surface.popClip(clip2);
    try testing.expectEqual(@as(i32, 10), surface.clip.x0);
    try testing.expectEqual(@as(i32, 10), surface.clip.y0);
    try testing.expectEqual(@as(i32, 60), surface.clip.x1);
    try testing.expectEqual(@as(i32, 60), surface.clip.y1);

    // Pop clip1
    surface.popClip(clip1);
    try testing.expectEqual(@as(i32, 0), surface.clip.x0);
    try testing.expectEqual(@as(i32, 0), surface.clip.y0);
    try testing.expectEqual(@as(i32, 100), surface.clip.x1);
    try testing.expectEqual(@as(i32, 100), surface.clip.y1);
}



