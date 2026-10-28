// Dockable On-Screen Keyboard (OSK) & Seat Profile Engine for Diosix GUI.
//
// Supports Touch/Tablet, Desktop Keyboard/Mouse, and Headless Serial seat
// profiles with an FF7/8-styled dockable QWERTY/Symbol virtual keyboard.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const SeatProfile = enum {
    headless_serial,
    desktop_kbd,
    touch_tablet,

    pub fn label(self: SeatProfile) []const u8 {
        return switch (self) {
            .headless_serial => "headless-serial",
            .desktop_kbd => "desktop-kbd",
            .touch_tablet => "touch-tablet",
        };
    }
};

pub const OskLayout = enum {
    qwerty_lower,
    qwerty_upper,
    symbols,

    pub fn label(self: OskLayout) []const u8 {
        return switch (self) {
            .qwerty_lower => "abc",
            .qwerty_upper => "ABC",
            .symbols => "#+=",
        };
    }
};

pub const OskAction = union(enum) {
    char: u8,
    backspace,
    enter,
    space,
    toggle_shift,
    toggle_symbols,
    hide,
};

pub const KeyCap = struct {
    id_offset: u32,
    label: []const u8,
    action: OskAction,
    width_units: u8 = 1, // 1 = standard, 2 = wide, 4 = spacebar.
};

pub const ROW1_LOWER = [_]KeyCap{
    .{ .id_offset = 0, .label = "q", .action = .{ .char = 'q' } },
    .{ .id_offset = 1, .label = "w", .action = .{ .char = 'w' } },
    .{ .id_offset = 2, .label = "e", .action = .{ .char = 'e' } },
    .{ .id_offset = 3, .label = "r", .action = .{ .char = 'r' } },
    .{ .id_offset = 4, .label = "t", .action = .{ .char = 't' } },
    .{ .id_offset = 5, .label = "y", .action = .{ .char = 'y' } },
    .{ .id_offset = 6, .label = "u", .action = .{ .char = 'u' } },
    .{ .id_offset = 7, .label = "i", .action = .{ .char = 'i' } },
    .{ .id_offset = 8, .label = "o", .action = .{ .char = 'o' } },
    .{ .id_offset = 9, .label = "p", .action = .{ .char = 'p' } },
    .{ .id_offset = 34, .label = "`", .action = .{ .char = '`' } },
    .{ .id_offset = 35, .label = "|", .action = .{ .char = '|' } },
    .{ .id_offset = 36, .label = "/", .action = .{ .char = '/' } },
};

pub const ROW2_LOWER = [_]KeyCap{
    .{ .id_offset = 10, .label = "a", .action = .{ .char = 'a' } },
    .{ .id_offset = 11, .label = "s", .action = .{ .char = 's' } },
    .{ .id_offset = 12, .label = "d", .action = .{ .char = 'd' } },
    .{ .id_offset = 13, .label = "f", .action = .{ .char = 'f' } },
    .{ .id_offset = 14, .label = "g", .action = .{ .char = 'g' } },
    .{ .id_offset = 15, .label = "h", .action = .{ .char = 'h' } },
    .{ .id_offset = 16, .label = "j", .action = .{ .char = 'j' } },
    .{ .id_offset = 17, .label = "k", .action = .{ .char = 'k' } },
    .{ .id_offset = 18, .label = "l", .action = .{ .char = 'l' } },
    .{ .id_offset = 37, .label = "[", .action = .{ .char = '[' } },
    .{ .id_offset = 38, .label = "]", .action = .{ .char = ']' } },
    .{ .id_offset = 39, .label = "{", .action = .{ .char = '{' } },
    .{ .id_offset = 40, .label = "}", .action = .{ .char = '}' } },
};

pub const ROW3_LOWER = [_]KeyCap{
    .{
        .id_offset = 19,
        .label = "Shift",
        .action = .toggle_shift,
        .width_units = 2,
    },
    .{ .id_offset = 20, .label = "z", .action = .{ .char = 'z' } },
    .{ .id_offset = 21, .label = "x", .action = .{ .char = 'x' } },
    .{ .id_offset = 22, .label = "c", .action = .{ .char = 'c' } },
    .{ .id_offset = 23, .label = "v", .action = .{ .char = 'v' } },
    .{ .id_offset = 24, .label = "b", .action = .{ .char = 'b' } },
    .{ .id_offset = 25, .label = "n", .action = .{ .char = 'n' } },
    .{ .id_offset = 26, .label = "m", .action = .{ .char = 'm' } },
    .{ .id_offset = 41, .label = "<", .action = .{ .char = '<' } },
    .{ .id_offset = 42, .label = ">", .action = .{ .char = '>' } },
    .{
        .id_offset = 27,
        .label = "Bksp",
        .action = .backspace,
        .width_units = 2,
    },
};

pub const ROW4_COMMON = [_]KeyCap{
    .{
        .id_offset = 28,
        .label = "123",
        .action = .toggle_symbols,
        .width_units = 2,
    },
    .{ .id_offset = 29, .label = "-", .action = .{ .char = '-' } },
    .{ .id_offset = 43, .label = "=", .action = .{ .char = '=' } },
    .{ .id_offset = 30, .label = "Space", .action = .space, .width_units = 3 },
    .{ .id_offset = 31, .label = ".", .action = .{ .char = '.' } },
    .{ .id_offset = 44, .label = "#", .action = .{ .char = '#' } },
    .{ .id_offset = 32, .label = "Enter", .action = .enter, .width_units = 2 },
    .{ .id_offset = 33, .label = "Hide", .action = .hide, .width_units = 2 },
};

const SYM_ROW1 = "1234567890";
const SYM_ROW2 = "/:;()$&@\"";
const SYM_ROW3 = ".,?!'_~";

/// Capacity of the OSK input line. It is a bounded text field: further key
/// presses are ignored once full, and it is sized to fit the one-line OSK
/// display label (Icon.text_buf) together with its "Input [layout]: " prefix.
pub const MAX_OSK_BUFFER_LEN: usize = 128;

pub const OskState = struct {
    visible: bool = false,
    dock_bottom: bool = true,
    layout: OskLayout = .qwerty_lower,
    seat_profile: SeatProfile = .desktop_kbd,
    input_buf: [MAX_OSK_BUFFER_LEN]u8 = @splat(0),
    input_len: usize = 0,
    submitted_count: u32 = 0,

    pub fn init(seat: SeatProfile) OskState {
        return OskState{
            .visible = (seat == .touch_tablet),
            .dock_bottom = true,
            .layout = .qwerty_lower,
            .seat_profile = seat,
        };
    }

    pub fn toggle(self: *OskState) void {
        self.visible = !self.visible;
    }

    pub fn getInputText(self: *const OskState) []const u8 {
        return self.input_buf[0..self.input_len];
    }

    pub fn clearInput(self: *OskState) void {
        self.input_len = 0;
    }

    pub fn applyAction(self: *OskState, action: OskAction) void {
        switch (action) {
            .char => |c| {
                if (self.input_len < MAX_OSK_BUFFER_LEN) {
                    const out_char: u8 = if (self.layout == .qwerty_upper)
                        std.ascii.toUpper(c)
                    else
                        c;
                    self.input_buf[self.input_len] = out_char;
                    self.input_len += 1;
                }
            },
            .space => {
                if (self.input_len < MAX_OSK_BUFFER_LEN) {
                    self.input_buf[self.input_len] = ' ';
                    self.input_len += 1;
                }
            },
            .backspace => {
                if (self.input_len > 0) {
                    self.input_len -= 1;
                }
            },
            .enter => {
                self.submitted_count += 1;
            },
            .toggle_shift => {
                self.layout = switch (self.layout) {
                    .qwerty_lower => .qwerty_upper,
                    .qwerty_upper => .qwerty_lower,
                    .symbols => .symbols,
                };
            },
            .toggle_symbols => {
                self.layout = switch (self.layout) {
                    .symbols => .qwerty_lower,
                    else => .symbols,
                };
            },
            .hide => {
                self.visible = false;
            },
        }
    }

    pub fn keyLabel(self: *const OskState, k: KeyCap) []const u8 {
        if (k.id_offset == 28 and self.layout == .symbols) return "ABC";
        switch (self.layout) {
            .qwerty_lower => return k.label,
            .qwerty_upper => {
                const upper = "QWERTYUIOPASDFGHJKL";
                const upper_r3 = "ZXCVBNM";
                if (k.id_offset <= 18) {
                    return upper[k.id_offset .. k.id_offset + 1];
                }
                if (k.id_offset >= 20 and k.id_offset <= 26) {
                    const idx = k.id_offset - 20;
                    return upper_r3[idx .. idx + 1];
                }
                return k.label;
            },
            .symbols => {
                if (k.id_offset <= 9) {
                    return SYM_ROW1[k.id_offset .. k.id_offset + 1];
                }
                if (k.id_offset >= 10 and k.id_offset <= 18) {
                    const idx = k.id_offset - 10;
                    return SYM_ROW2[idx .. idx + 1];
                }
                if (k.id_offset >= 20 and k.id_offset <= 26) {
                    const idx = k.id_offset - 20;
                    return SYM_ROW3[idx .. idx + 1];
                }
                if (k.id_offset == 36) return "\\";
                if (k.id_offset == 43) return "+";
                if (k.id_offset == 31) return "*";
                if (k.id_offset == 44) return "%";
                return k.label;
            },
        }
    }

    pub fn applyKeyOffset(self: *OskState, id_offset: u32) bool {
        if (self.layout == .symbols) {
            const sym_override: ?u8 = switch (id_offset) {
                36 => '\\',
                43 => '+',
                31 => '*',
                44 => '%',
                else => null,
            };
            if (sym_override) |ch| {
                self.applyAction(.{ .char = ch });
                return true;
            }
        }
        for (ROW1_LOWER, 0..) |k, idx| {
            if (k.id_offset == id_offset) {
                if (self.layout == .symbols and idx < SYM_ROW1.len) {
                    self.applyAction(.{ .char = SYM_ROW1[idx] });
                } else {
                    self.applyAction(k.action);
                }
                return true;
            }
        }
        for (ROW2_LOWER, 0..) |k, idx| {
            if (k.id_offset == id_offset) {
                if (self.layout == .symbols and idx < SYM_ROW2.len) {
                    self.applyAction(.{ .char = SYM_ROW2[idx] });
                } else {
                    self.applyAction(k.action);
                }
                return true;
            }
        }
        for (ROW3_LOWER) |k| {
            if (k.id_offset == id_offset) {
                if (self.layout == .symbols and
                    id_offset >= 20 and id_offset <= 26)
                {
                    self.applyAction(.{ .char = SYM_ROW3[id_offset - 20] });
                } else {
                    self.applyAction(k.action);
                }
                return true;
            }
        }
        for (ROW4_COMMON) |k| {
            if (k.id_offset == id_offset) {
                self.applyAction(k.action);
                return true;
            }
        }
        return false;
    }
};

// -----------------------------------------------------------------------------
// Unit Tests.
// -----------------------------------------------------------------------------
const testing = std.testing;

test "OskState auto-shows on touch_tablet seat and handles keystrokes" {
    testing.refAllDecls(@This());
    var osk = OskState.init(.touch_tablet);
    try testing.expect(osk.visible);
    try testing.expectEqual(OskLayout.qwerty_lower, osk.layout);

    // Type "dsx".
    _ = osk.applyKeyOffset(12); // 'd'.
    _ = osk.applyKeyOffset(11); // 's'.
    _ = osk.applyKeyOffset(21); // 'x'.
    try testing.expectEqualStrings("dsx", osk.getInputText());

    // Shift + space + 'A'.
    _ = osk.applyKeyOffset(30); // Space.
    _ = osk.applyKeyOffset(19); // Shift.
    try testing.expectEqual(OskLayout.qwerty_upper, osk.layout);
    _ = osk.applyKeyOffset(10); // 'A'.
    try testing.expectEqualStrings("dsx A", osk.getInputText());

    // Backspace.
    _ = osk.applyKeyOffset(27);
    try testing.expectEqualStrings("dsx ", osk.getInputText());

    // Symbols row 1, row 2, shell characters (` | / \ [ ] { } < > + * %), and
    // verify Shift (offset 19) is a no-op in symbols mode.
    _ = osk.applyKeyOffset(28); // Toggle symbols.
    try testing.expectEqual(OskLayout.symbols, osk.layout);
    _ = osk.applyKeyOffset(19); // Shift in symbols mode must be a no-op!
    try testing.expectEqual(OskLayout.symbols, osk.layout);
    _ = osk.applyKeyOffset(0); // '1'.
    _ = osk.applyKeyOffset(10); // '/'.
    _ = osk.applyKeyOffset(34); // '`'.
    _ = osk.applyKeyOffset(35); // '|'.
    _ = osk.applyKeyOffset(36); // '\'.
    try testing.expectEqualStrings("dsx 1/`|\\", osk.getInputText());

    // Hide.
    _ = osk.applyKeyOffset(33);
    try testing.expect(!osk.visible);
}
