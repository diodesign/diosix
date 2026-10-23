// Main Entry Point and Display Loop for Diosix Monolithic GUI.
// Final Fantasy 7 & 8 Inspired BIOS/UEFI Menu Environment.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const linux = std.os.linux;
const fb = @import("framebuffer.zig");
const gui_mod = @import("gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const intro_mod = @import("intro.zig");
const audio_mod = @import("audio.zig");
const ipc = @import("ipc.zig");
const paths = @import("paths.zig");
pub const display_mod = @import("display.zig");
pub const banner_font_mod = @import("font/banner.zig");
pub const host_info = @import("host.zig");
pub const cursor_mod = @import("cursor.zig");

pub const Display = display_mod.Display;
pub const InputEvent = display_mod.InputEvent;
pub const InputDeviceInfo = display_mod.InputDeviceInfo;
pub const input_absinfo = display_mod.input_absinfo;
pub const EVIOCGABS = display_mod.EVIOCGABS;
pub const MS_PER_SEC = display_mod.MS_PER_SEC;
pub const NS_PER_MS = display_mod.NS_PER_MS;
pub const TARGET_FPS = display_mod.TARGET_FPS;
pub const FRAME_INTERVAL_MS = display_mod.FRAME_INTERVAL_MS;
pub const POLL_TIMEOUT_MS = display_mod.POLL_TIMEOUT_MS;
pub const MAX_INPUT_DEVICES = display_mod.MAX_INPUT_DEVICES;
pub const EV_KEY = display_mod.EV_KEY;
pub const EV_REL = display_mod.EV_REL;
pub const EV_ABS = display_mod.EV_ABS;
pub const REL_X = display_mod.REL_X;
pub const REL_Y = display_mod.REL_Y;
pub const REL_WHEEL = display_mod.REL_WHEEL;
pub const ABS_X = display_mod.ABS_X;
pub const ABS_Y = display_mod.ABS_Y;
pub const ABS_MT_POSITION_X = display_mod.ABS_MT_POSITION_X;
pub const ABS_MT_POSITION_Y = display_mod.ABS_MT_POSITION_Y;
pub const EVDEV_ABS_MAX = display_mod.EVDEV_ABS_MAX;
pub const BTN_LEFT = display_mod.BTN_LEFT;
pub const BTN_RIGHT = display_mod.BTN_RIGHT;
pub const BTN_MIDDLE = display_mod.BTN_MIDDLE;
pub const BTN_TOUCH = display_mod.BTN_TOUCH;

const getMilliTimestamp = display_mod.getMilliTimestamp;

/// Capacity for the PID line written to the lock file: pid_t is an i32, so
/// at most ten digits ("2147483647") plus the trailing newline.
const MAX_PID_LINE_BYTES: usize = "2147483647\n".len;

/// Capacity for the DRM driver name shown in the startup log line. Kernel
/// driver names are short identifiers (e.g. "virtio_gpu"); a longer name is
/// truncated to this prefix, which only affects the log text.
const DRM_DRIVER_NAME_LOG_BYTES: usize = 64;

const STARTUP_MSG = "Starting Diosix Monolithic GUI (diosix-gui)...\n";

fn pollMainInput(
    devs: []const InputDeviceInfo,
    pfds: []const linux.pollfd,
    display: *Display,
    gui: *DiosixGui,
) void {
    var coords_changed = false;
    var pending_x = gui.cursor.x;
    var pending_y = gui.cursor.y;

    for (devs, 0..) |*dev_info, i| {
        if ((pfds[i].revents & linux.POLL.IN) != 0) {
            while (true) {
                var ev_buf: [64]InputEvent = undefined;
                const rd = linux.read(
                    pfds[i].fd,
                    @ptrCast(&ev_buf),
                    @sizeOf(@TypeOf(ev_buf)),
                );
                const signed_rd: isize = @bitCast(rd);
                if (signed_rd <= 0) break;

                const n_bytes: usize = @intCast(signed_rd);
                const count = n_bytes / @sizeOf(InputEvent);
                for (ev_buf[0..count]) |ev| {
                    switch (ev.type) {
                        EV_KEY => {
                            const pressed = (ev.value != 0);
                            const code = ev.code;
                            if (code == BTN_LEFT or code == BTN_TOUCH) {
                                if (coords_changed) {
                                    gui.handleMouseMove(
                                        pending_x,
                                        pending_y,
                                        gui.mouse_left_down,
                                    );
                                    coords_changed = false;
                                }
                                if (pressed) {
                                    gui.mouse_left_down = true;
                                    gui.handleMouseClick(pending_x, pending_y);
                                } else {
                                    gui.mouse_left_down = false;
                                    gui.handleMouseRelease();
                                }
                            }
                        },
                        EV_REL => {
                            if (ev.code == REL_WHEEL) {
                                const dy = 0 -| ev.value;
                                gui.handleMouseScroll(pending_x, pending_y, dy);
                            } else {
                                display_mod.applyMotionEvent(
                                    ev,
                                    dev_info,
                                    display.width,
                                    display.height,
                                    &pending_x,
                                    &pending_y,
                                    &coords_changed,
                                );
                            }
                        },
                        EV_ABS => {
                            display_mod.applyMotionEvent(
                                ev,
                                dev_info,
                                display.width,
                                display.height,
                                &pending_x,
                                &pending_y,
                                &coords_changed,
                            );
                        },
                        else => {},
                    }
                }
            }
        }
    }

    if (coords_changed) {
        gui.handleMouseMove(pending_x, pending_y, gui.mouse_left_down);
    }
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Kernel-level privilege enforcement: running the GUI requires UID 0.
    if (linux.getuid() != 0) {
        std.debug.print(
            "diosix-gui: Access denied. " ++
                "Running the GUI requires root privileges.\n",
            .{},
        );
        return;
    }

    // Singleton lock: kernel-enforced flock preventing concurrent instances.
    var lock_fd: i32 = -1;
    const run_dir_path = paths.RUN_DIOSIX_DIR;
    const run_lock_path = paths.GUI_LOCK_PATH;
    const lock_flags = linux.O{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .NOFOLLOW = true,
    };

    const RUN_DIR_MODE: usize = 0o755;
    const PRIVATE_FILE_MODE: usize = 0o600;
    const LOCK_EX: i32 = 2;
    const LOCK_NB: i32 = 4;
    const LOCK_EX_NB: i32 = LOCK_EX | LOCK_NB;
    _ = linux.mkdir(run_dir_path, RUN_DIR_MODE);
    const lock_rc = linux.open(run_lock_path, lock_flags, PRIVATE_FILE_MODE);
    const signed_lock: isize = @bitCast(lock_rc);
    if (signed_lock >= 0) {
        lock_fd = @intCast(signed_lock);
        const flock_rc = linux.flock(lock_fd, LOCK_EX_NB);
        const signed_flock: isize = @bitCast(flock_rc);
        if (signed_flock != 0) {
            std.debug.print(
                "diosix-gui: Another instance is already running " ++
                    "(locked). Exiting.\n",
                .{},
            );
            _ = linux.close(lock_fd);
            return;
        }
        var pbuf: [MAX_PID_LINE_BYTES]u8 = undefined;
        const my_pid = linux.getpid();
        // Cannot fail: MAX_PID_LINE_BYTES fits any pid_t plus newline.
        const s = std.fmt.bufPrint(&pbuf, "{d}\n", .{my_pid}) catch
            unreachable;
        _ = linux.write(lock_fd, s.ptr, s.len);
    }
    defer {
        if (lock_fd >= 0) _ = linux.close(lock_fd);
    }

    _ = linux.write(1, STARTUP_MSG.ptr, STARTUP_MSG.len);

    // 1. Initialize Display.
    var display = Display.init(allocator) catch |err| {
        if (err == error.AccessDenied) {
            std.debug.print(
                "diosix-gui: Permission denied accessing display device " ++
                    "(/dev/dri/card* or /dev/fb0).\n",
                .{},
            );
        } else {
            std.debug.print("Failed to initialize display: {}\n", .{err});
        }
        return;
    };
    defer display.deinit(allocator);

    std.debug.print(
        "Display initialized: {d}x{d}, " ++
            "Final Fantasy 7/8 theme engine active.\n",
        .{ display.width, display.height },
    );

    // 2. Initialize Diosix GUI Coordinator.
    var gui = try DiosixGui.init(allocator, display.width, display.height);
    defer gui.deinit();
    gui.color_depth = display.color_depth;
    try gui.setPhysicalDimensions(display.mm_width, display.mm_height);

    // Detect hardware GPU acceleration (VirtIO-GPU, PowerVR, Panfrost, etc.).
    const is_accel = if (display.drm_dev) |*d|
        d.hasHardwareAcceleration()
    else
        false;
    var drv_buf: [DRM_DRIVER_NAME_LOG_BYTES]u8 = undefined;
    if (is_accel) {
        const drv_name = if (display.drm_dev) |*d|
            d.getDriverName(&drv_buf)
        else
            "unknown";
        std.debug.print(
            "diosix-gui: GPU acceleration detected ({s}). " ++
                "Dynamic backdrop morphing enabled.\n",
            .{drv_name},
        );
        gui.setRenderMode(.accelerated);
    } else {
        const drv_name = if (display.drm_dev) |*d|
            d.getDriverName(&drv_buf)
        else
            "software";
        std.debug.print(
            "diosix-gui: Running in software mode ({s}). " ++
                "Fast translucent panes and static backdrop for 60 FPS.\n",
            .{drv_name},
        );
        gui.setRenderMode(.degraded);
    }

    // 3. Open Evdev Input Devices with EVIOCGABS calibration.
    var input_devs: [MAX_INPUT_DEVICES]InputDeviceInfo = undefined;
    var had_input_eacces = false;
    const input_count = display_mod.openInputDevices(
        &input_devs,
        &had_input_eacces,
    );
    defer display_mod.closeInputDevices(input_devs[0..input_count]);

    if (input_count == 0) {
        if (had_input_eacces) {
            std.debug.print(
                "diosix-gui: Warning: Permission denied accessing " ++
                    "input devices (/dev/input/event*).\n",
                .{},
            );
        } else {
            std.debug.print(
                "diosix-gui: Warning: No input devices " ++
                    "(/dev/input/event*) detected.\n",
                .{},
            );
        }
    }

    // 4. Graphical Intro Animation and Audio Chime (Plays once per boot).
    var audio_player = audio_mod.AudioPlayer{};
    defer audio_player.stop();

    if (intro_mod.shouldPlayIntro()) {
        std.debug.print(
            "Playing Diosix graphical intro animation and chime...\n",
            .{},
        );
        audio_player.start();

        var intro_state = intro_mod.IntroState.init(getMilliTimestamp());
        var intro_last_time: i64 = intro_state.start_time_ms;

        while (intro_state.is_active) {
            const now = getMilliTimestamp();
            const dt: u32 = @intCast(@max(1, now - intro_last_time));
            intro_last_time = now;

            display_mod.pollIntroInput(
                input_devs[0..input_count],
                &display,
                &gui,
                &intro_state,
            );
            if (!intro_state.is_active) break;

            intro_state.tick(dt, now, display.width, display.height);
            intro_state.render(&display.backbuffer, &gui);
            const screen_box = fb.Box.fromPosSize(
                0,
                0,
                display.width,
                display.height,
            );
            display.flushDamage(screen_box);

            // Pace intro frame rate (~60 FPS).
            const frame_end = getMilliTimestamp();
            const frame_dur = frame_end - now;
            if (frame_dur < FRAME_INTERVAL_MS) {
                const rem_ms = FRAME_INTERVAL_MS - frame_dur;
                var sleep_ts = linux.timespec{
                    .sec = 0,
                    .nsec = @intCast(rem_ms * 1_000_000),
                };
                _ = linux.nanosleep(&sleep_ts, null);
            }
        }
        std.debug.print(
            "Intro sequence completed (elapsed {d}ms). " ++
                "Handing over to live desktop.\n",
            .{intro_state.elapsed_ms},
        );
    }

    // 5. Initial Render Frame (Full Screen Composited).
    gui.markFullDirty();
    const init_damage = gui.renderDamaged(&display.clean_buffer);
    display.backbuffer.copyBoxFrom(&display.clean_buffer, init_damage);
    if (gui.cursor.visible) {
        gui.cursor.draw(&display.backbuffer);
        display.prev_cursor_box = gui.cursor.getBox();
        display.prev_cursor_x = gui.cursor.x;
        display.prev_cursor_y = gui.cursor.y;
        display.cursor_drawn = true;
    } else {
        display.cursor_drawn = false;
    }
    display.flushDamage(init_damage);

    // 6. Main Multitasking and Event Loop with 60 FPS Frame Pacing.
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
        display_mod.fillPollFds(input_devs[0..input_count], &pfds);

        const poll_res = linux.poll(&pfds, input_count, poll_timeout);
        const signed_poll: isize = @bitCast(poll_res);

        const now = getMilliTimestamp();
        const dt_ms: u32 = @intCast(@max(1, now - last_time));
        last_time = now;

        // Preemptive Multitasking: Deliver CPU time to sub-programs.
        gui.tick(dt_ms);

        if (signed_poll > 0) {
            pollMainInput(input_devs[0..input_count], &pfds, &display, &gui);
        }

        ipc.checkSemanticIpcCommand(&gui);

        if (gui.display_reconfig_pending) {
            gui.display_reconfig_pending = false;
            display.reconfigure(
                allocator,
                gui.width,
                gui.height,
                gui.color_depth,
            ) catch {};
            gui.markFullDirty();
        }

        const cursor_should_show = gui.cursor.visible;
        const dx_ne = gui.cursor.x != display.prev_cursor_x;
        const dy_ne = gui.cursor.y != display.prev_cursor_y;
        const cursor_moved = cursor_should_show and (dx_ne or dy_ne);
        const cursor_state_changed = cursor_should_show != display.cursor_drawn;
        const time_due = (now - last_render_time) >= FRAME_INTERVAL_MS;
        const should_render = gui.isDirty() or cursor_moved or
            cursor_state_changed or (gui.hasActiveAnimation() and time_due);

        if (should_render) {
            last_render_time = now;
            const damage = gui.renderDamaged(&display.clean_buffer);
            const cursor_box = gui.cursor.getBox();

            if (!damage.isEmpty()) {
                ipc.exportSemanticStateFile(&gui);
            }

            if (!damage.isEmpty() or cursor_moved or cursor_state_changed) {
                var flush_box = fb.Box{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };

                if (!damage.isEmpty()) {
                    const clean = &display.clean_buffer;
                    display.backbuffer.copyBoxFrom(clean, damage);
                    flush_box = flush_box.merge(damage);
                }

                const hid_cursor = !cursor_should_show and display.cursor_drawn;
                const need_restore = cursor_moved or hid_cursor;
                if (need_restore and display.cursor_drawn) {
                    const clean = &display.clean_buffer;
                    const prev_box = display.prev_cursor_box;
                    display.backbuffer.copyBoxFrom(clean, prev_box);
                    flush_box = flush_box.merge(prev_box);
                }

                if (cursor_should_show) {
                    gui.cursor.draw(&display.backbuffer);
                    flush_box = flush_box.merge(cursor_box);

                    display.prev_cursor_box = cursor_box;
                    display.prev_cursor_x = gui.cursor.x;
                    display.prev_cursor_y = gui.cursor.y;
                    display.cursor_drawn = true;
                } else {
                    display.cursor_drawn = false;
                }

                if (!flush_box.isEmpty()) {
                    display.flushDamage(flush_box);
                }
            }
        }
    }
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("tests.zig");
    _ = ipc;
}
