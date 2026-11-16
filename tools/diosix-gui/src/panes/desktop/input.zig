// Guest Desktop Evdev Keyboard, Mouse, Tablet & OSK Input Routing.
//
// Translates host pointer coordinates inside the scaled guest viewport into
// VirtIO-Input absolute tablet coordinates (0..32767), forwards mouse buttons
// and scroll wheel events, and injects physical or OSK keystrokes.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const sbi = @import("interface").sbi;
const fb = @import("../../framebuffer.zig");
const host_info = @import("../../host.zig");
const gui_mod = @import("../../gui.zig");
const DiosixGui = gui_mod.DiosixGui;
const panes_osk = @import("../osk.zig");
const panes_desktop = @import("../desktop.zig");

pub const EV_SYN: u16 = 0x00;
pub const EV_KEY: u16 = 0x01;
pub const EV_REL: u16 = 0x02;
pub const EV_ABS: u16 = 0x03;

pub const SYN_REPORT: u16 = 0x00;
pub const ABS_X: u16 = 0x00;
pub const ABS_Y: u16 = 0x01;
pub const ABS_MAX_COORD: u32 = 32_767;
pub const REL_WHEEL: u16 = 0x08;

pub const BTN_LEFT: u16 = 0x110;
pub const BTN_RIGHT: u16 = 0x111;
pub const BTN_MIDDLE: u16 = 0x112;

pub const KEY_BACKSPACE: u16 = 14;
pub const KEY_TAB: u16 = 15;
pub const KEY_ENTER: u16 = 28;
pub const KEY_LEFTSHIFT: u16 = 42;
pub const KEY_SPACE: u16 = 57;
pub const KEY_HOME: u16 = 102;
pub const KEY_LEFT: u16 = 105;
pub const KEY_RIGHT: u16 = 106;
pub const KEY_END: u16 = 107;
pub const KEY_DELETE: u16 = 111;

const MASK_BTN_LEFT: u8 = 1 << 0;
const MASK_BTN_RIGHT: u8 = 1 << 1;
const MASK_BTN_MIDDLE: u8 = 1 << 2;
const MAX_TRACKED_KEYCODE: u16 = 0x100;
const KEY_BITS_PER_BYTE: u4 = 8;

fn isKeyPressed(bitmap: *const [32]u8, code: u16) bool {
    if (code >= MAX_TRACKED_KEYCODE) return false;
    const byte_idx: usize = @intCast(code / KEY_BITS_PER_BYTE);
    const bit_idx: u3 = @intCast(code % KEY_BITS_PER_BYTE);
    return (bitmap[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
}

fn setKeyPressed(bitmap: *[32]u8, code: u16, pressed: bool) void {
    if (code >= MAX_TRACKED_KEYCODE) return;
    const byte_idx: usize = @intCast(code / KEY_BITS_PER_BYTE);
    const bit_idx: u3 = @intCast(code % KEY_BITS_PER_BYTE);
    const mask: u8 = @as(u8, 1) << bit_idx;
    if (pressed) {
        bitmap[byte_idx] |= mask;
    } else {
        bitmap[byte_idx] &= ~mask;
    }
}

const MappedKey = struct {
    code: u16,
    shift: bool = false,
};

fn buttonMask(btn_code: u16) u8 {
    return switch (btn_code) {
        BTN_LEFT => MASK_BTN_LEFT,
        BTN_RIGHT => MASK_BTN_RIGHT,
        BTN_MIDDLE => MASK_BTN_MIDDLE,
        else => 0,
    };
}

pub fn mapViewportPoint(
    vbox: fb.Box,
    px: i32,
    py: i32,
) ?struct { abs_x: u32, abs_y: u32 } {
    if (vbox.isEmpty()) return null;
    const cx = std.math.clamp(px, vbox.x0, vbox.x1 - 1);
    const cy = std.math.clamp(py, vbox.y0, vbox.y1 - 1);
    const vw = vbox.width();
    const vh = vbox.height();
    const rel_x: u64 = @intCast(cx - vbox.x0);
    const rel_y: u64 = @intCast(cy - vbox.y0);

    const abs_x: u32 = if (vw <= 1)
        0
    else
        @intCast((rel_x * ABS_MAX_COORD) / @as(u64, vw - 1));
    const abs_y: u32 = if (vh <= 1)
        0
    else
        @intCast((rel_y * ABS_MAX_COORD) / @as(u64, vh - 1));
    return .{ .abs_x = abs_x, .abs_y = abs_y };
}

pub fn releaseAllButtons(self: *DiosixGui) void {
    const held = self.desktop.pointer_buttons;
    const keys = self.desktop.pressed_keys;
    self.desktop.pointer_buttons = 0;
    self.desktop.pressed_keys = @splat(0);
    if (!self.desktop.active) return;

    var batch: [sbi.MAX_INPUT_BATCH_EVENTS]sbi.InputEventItem = undefined;
    var n: usize = 0;
    if ((held & MASK_BTN_LEFT) != 0) {
        batch[n] = .{ .type = EV_KEY, .code = BTN_LEFT, .value = 0 };
        n += 1;
    }
    if ((held & MASK_BTN_RIGHT) != 0) {
        batch[n] = .{ .type = EV_KEY, .code = BTN_RIGHT, .value = 0 };
        n += 1;
    }
    if ((held & MASK_BTN_MIDDLE) != 0) {
        batch[n] = .{ .type = EV_KEY, .code = BTN_MIDDLE, .value = 0 };
        n += 1;
    }
    var code: u16 = 1;
    while (code < MAX_TRACKED_KEYCODE) : (code += 1) {
        if (!isKeyPressed(&keys, code)) continue;
        if (n + 1 >= sbi.MAX_INPUT_BATCH_EVENTS) {
            batch[n] = .{ .type = EV_SYN, .code = SYN_REPORT, .value = 0 };
            n += 1;
            _ = host_info.desktop.sendGuestInputEvents(
                self.desktop.target_cid,
                batch[0..n],
            );
            n = 0;
        }
        batch[n] = .{ .type = EV_KEY, .code = code, .value = 0 };
        n += 1;
    }
    if (n > 0) {
        batch[n] = .{ .type = EV_SYN, .code = SYN_REPORT, .value = 0 };
        n += 1;
        _ = host_info.desktop.sendGuestInputEvents(
            self.desktop.target_cid,
            batch[0..n],
        );
    }
}

pub fn handleDesktopPointerMove(self: *DiosixGui, px: i32, py: i32) void {
    if (!panes_desktop.isDesktopWindowOpen(self) or
        !self.desktop.scanout_active)
    {
        return;
    }
    const vbox = self.desktop.viewport_box;
    if (!vbox.contains(px, py) and self.desktop.pointer_buttons == 0) return;
    const pt = mapViewportPoint(vbox, px, py) orelse return;

    const evs = [_]sbi.InputEventItem{
        .{ .type = EV_ABS, .code = ABS_X, .value = pt.abs_x },
        .{ .type = EV_ABS, .code = ABS_Y, .value = pt.abs_y },
        .{ .type = EV_SYN, .code = SYN_REPORT, .value = 0 },
    };
    _ = host_info.desktop.sendGuestInputEvents(self.desktop.target_cid, &evs);
}

pub fn handleDesktopMouseButton(
    self: *DiosixGui,
    px: i32,
    py: i32,
    btn_code: u16,
    pressed: bool,
) bool {
    const mask = buttonMask(btn_code);
    if (mask == 0) return false;
    if (!pressed) return handleDesktopMouseRelease(self, btn_code);

    if (!panes_desktop.isDesktopWindowOpen(self) or
        !self.desktop.scanout_active)
    {
        return false;
    }
    const vbox = self.desktop.viewport_box;
    if (!vbox.contains(px, py)) return false;
    const pt = mapViewportPoint(vbox, px, py) orelse return false;

    self.desktop.pointer_buttons |= mask;
    const evs = [_]sbi.InputEventItem{
        .{ .type = EV_ABS, .code = ABS_X, .value = pt.abs_x },
        .{ .type = EV_ABS, .code = ABS_Y, .value = pt.abs_y },
        .{ .type = EV_KEY, .code = btn_code, .value = 1 },
        .{ .type = EV_SYN, .code = SYN_REPORT, .value = 0 },
    };
    _ = host_info.desktop.sendGuestInputEvents(self.desktop.target_cid, &evs);
    return true;
}

pub fn handleDesktopMouseRelease(self: *DiosixGui, btn_code: u16) bool {
    const mask = buttonMask(btn_code);
    if (mask == 0) return false;
    if ((self.desktop.pointer_buttons & mask) == 0) return false;

    self.desktop.pointer_buttons &= ~mask;
    if (self.desktop.active) {
        const evs = [_]sbi.InputEventItem{
            .{ .type = EV_KEY, .code = btn_code, .value = 0 },
            .{ .type = EV_SYN, .code = SYN_REPORT, .value = 0 },
        };
        _ = host_info.desktop.sendGuestInputEvents(
            self.desktop.target_cid,
            &evs,
        );
    }
    return true;
}

pub fn handleDesktopScroll(
    self: *DiosixGui,
    px: i32,
    py: i32,
    gui_scroll_delta: i32,
) bool {
    if (!panes_desktop.isDesktopWindowOpen(self) or
        !self.desktop.scanout_active)
    {
        return false;
    }
    if (!self.desktop.viewport_box.contains(px, py)) return false;
    const wheel_i32 = std.math.clamp(0 -| gui_scroll_delta, -120, 120);
    if (wheel_i32 == 0) return true;

    const evs = [_]sbi.InputEventItem{
        .{
            .type = EV_REL,
            .code = REL_WHEEL,
            .value = @bitCast(wheel_i32),
        },
        .{ .type = EV_SYN, .code = SYN_REPORT, .value = 0 },
    };
    _ = host_info.desktop.sendGuestInputEvents(self.desktop.target_cid, &evs);
    return true;
}

pub fn handleDesktopEvdevKey(self: *DiosixGui, code: u16, value: i32) bool {
    if (!panes_desktop.isDesktopWindowOpen(self)) return false;
    if (panes_osk.hasFocusedTextInput(self)) return false;
    if (code == 0 or code >= MAX_TRACKED_KEYCODE) return false;
    // Consume host kernel autorepeat events so the guest compositor/TTY drives
    // its own repeat timer without double-repetition bursts.
    if (value == 2) return true;

    const ev_val: u32 = if (value > 0) blk: {
        if (isKeyPressed(&self.desktop.pressed_keys, code)) return true;
        setKeyPressed(&self.desktop.pressed_keys, code, true);
        break :blk 1;
    } else if (value == 0) blk: {
        if (!isKeyPressed(&self.desktop.pressed_keys, code)) return true;
        setKeyPressed(&self.desktop.pressed_keys, code, false);
        break :blk 0;
    } else return false;

    const evs = [_]sbi.InputEventItem{
        .{ .type = EV_KEY, .code = code, .value = ev_val },
        .{ .type = EV_SYN, .code = SYN_REPORT, .value = 0 },
    };
    _ = host_info.desktop.sendGuestInputEvents(self.desktop.target_cid, &evs);
    return true;
}

fn mapAsciiToEvdev(ch: u8) ?MappedKey {
    if (ch >= 'a' and ch <= 'z') return lookupLowerLetter(ch);
    if (ch >= 'A' and ch <= 'Z') {
        const m = lookupLowerLetter(ch + ('a' - 'A')) orelse return null;
        return .{ .code = m.code, .shift = true };
    }
    if (ch >= '1' and ch <= '9') {
        return .{ .code = @as(u16, ch - '1') + 2 };
    }
    return switch (ch) {
        '0' => .{ .code = 11 },
        '\n', '\r' => .{ .code = KEY_ENTER },
        '\t' => .{ .code = KEY_TAB },
        ' ' => .{ .code = KEY_SPACE },
        '!' => .{ .code = 2, .shift = true },
        '@' => .{ .code = 3, .shift = true },
        '#' => .{ .code = 4, .shift = true },
        '$' => .{ .code = 5, .shift = true },
        '%' => .{ .code = 6, .shift = true },
        '^' => .{ .code = 7, .shift = true },
        '&' => .{ .code = 8, .shift = true },
        '*' => .{ .code = 9, .shift = true },
        '(' => .{ .code = 10, .shift = true },
        ')' => .{ .code = 11, .shift = true },
        '-' => .{ .code = 12 },
        '_' => .{ .code = 12, .shift = true },
        '=' => .{ .code = 13 },
        '+' => .{ .code = 13, .shift = true },
        '[' => .{ .code = 26 },
        '{' => .{ .code = 26, .shift = true },
        ']' => .{ .code = 27 },
        '}' => .{ .code = 27, .shift = true },
        ';' => .{ .code = 39 },
        ':' => .{ .code = 39, .shift = true },
        '\'' => .{ .code = 40 },
        '"' => .{ .code = 40, .shift = true },
        '`' => .{ .code = 41 },
        '~' => .{ .code = 41, .shift = true },
        '\\' => .{ .code = 43 },
        '|' => .{ .code = 43, .shift = true },
        ',' => .{ .code = 51 },
        '<' => .{ .code = 51, .shift = true },
        '.' => .{ .code = 52 },
        '>' => .{ .code = 52, .shift = true },
        '/' => .{ .code = 53 },
        '?' => .{ .code = 53, .shift = true },
        else => null,
    };
}

fn lookupLowerLetter(ch: u8) ?MappedKey {
    const row1 = "qwertyuiop";
    for (row1, 0..) |c, idx| {
        if (c == ch) return .{ .code = @intCast(16 + idx) };
    }
    const row2 = "asdfghjkl";
    for (row2, 0..) |c, idx| {
        if (c == ch) return .{ .code = @intCast(30 + idx) };
    }
    const row3 = "zxcvbnm";
    for (row3, 0..) |c, idx| {
        if (c == ch) return .{ .code = @intCast(44 + idx) };
    }
    return null;
}

pub fn sendAsciiToDesktop(self: *DiosixGui, ch: u8) bool {
    if (!panes_desktop.isDesktopWindowOpen(self)) return false;
    const mapped = mapAsciiToEvdev(ch) orelse return true;

    var batch: [6]sbi.InputEventItem = undefined;
    var n: usize = 0;
    if (mapped.shift) {
        batch[n] = .{ .type = EV_KEY, .code = KEY_LEFTSHIFT, .value = 1 };
        n += 1;
    }
    batch[n] = .{ .type = EV_KEY, .code = mapped.code, .value = 1 };
    n += 1;
    batch[n] = .{ .type = EV_SYN, .code = SYN_REPORT, .value = 0 };
    n += 1;
    batch[n] = .{ .type = EV_KEY, .code = mapped.code, .value = 0 };
    n += 1;
    if (mapped.shift) {
        batch[n] = .{ .type = EV_KEY, .code = KEY_LEFTSHIFT, .value = 0 };
        n += 1;
    }
    batch[n] = .{ .type = EV_SYN, .code = SYN_REPORT, .value = 0 };
    n += 1;
    _ = host_info.desktop.sendGuestInputEvents(
        self.desktop.target_cid,
        batch[0..n],
    );
    return true;
}

pub fn sendSpecialToDesktop(
    self: *DiosixGui,
    cmd: panes_osk.KeyCommand,
) bool {
    if (!panes_desktop.isDesktopWindowOpen(self)) return false;
    const code: u16 = switch (cmd) {
        .backspace => KEY_BACKSPACE,
        .delete => KEY_DELETE,
        .left => KEY_LEFT,
        .right => KEY_RIGHT,
        .home => KEY_HOME,
        .end => KEY_END,
    };
    const evs = [_]sbi.InputEventItem{
        .{ .type = EV_KEY, .code = code, .value = 1 },
        .{ .type = EV_SYN, .code = SYN_REPORT, .value = 0 },
        .{ .type = EV_KEY, .code = code, .value = 0 },
        .{ .type = EV_SYN, .code = SYN_REPORT, .value = 0 },
    };
    _ = host_info.desktop.sendGuestInputEvents(self.desktop.target_cid, &evs);
    return true;
}

test "desktop/input: viewport coordinate scaling to VirtIO tablet range" {
    const testing = std.testing;
    testing.refAllDecls(@This());

    const vbox = fb.Box.fromPosSize(100, 50, 801, 601);
    const tl = mapViewportPoint(vbox, 100, 50).?;
    try testing.expectEqual(@as(u32, 0), tl.abs_x);
    try testing.expectEqual(@as(u32, 0), tl.abs_y);

    const br = mapViewportPoint(vbox, 900, 650).?;
    try testing.expectEqual(ABS_MAX_COORD, br.abs_x);
    try testing.expectEqual(ABS_MAX_COORD, br.abs_y);

    const mid = mapViewportPoint(vbox, 500, 350).?;
    try testing.expect(mid.abs_x >= 16_380 and mid.abs_x <= 16_386);
    try testing.expect(mid.abs_y >= 16_380 and mid.abs_y <= 16_386);

    defer host_info.desktop.resetDesktopMocks();
    var gui = try DiosixGui.init(testing.allocator, 1280, 800);
    defer gui.deinit();
    try gui.openGuestDesktop(2);
    gui.completeNavAnimation();
    host_info.desktop.mock_last_input = null;

    // Host autorepeat (value == 2) and duplicate key-down are suppressed.
    try testing.expect(handleDesktopEvdevKey(&gui, 45, 1));
    try testing.expectEqual(
        @as(u32, 1),
        host_info.desktop.mock_last_input.?.events[0].value,
    );
    host_info.desktop.mock_last_input = null;
    try testing.expect(handleDesktopEvdevKey(&gui, 45, 2));
    try testing.expect(host_info.desktop.mock_last_input == null);
    try testing.expect(handleDesktopEvdevKey(&gui, 45, 1));
    try testing.expect(host_info.desktop.mock_last_input == null);
    try testing.expect(handleDesktopEvdevKey(&gui, 45, 0));
    try testing.expectEqual(
        @as(u32, 0),
        host_info.desktop.mock_last_input.?.events[0].value,
    );
}
