// JSON string escaping for the Diosix GUI semantic state export.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const gui_mod = @import("../gui.zig");
const DiosixGui = gui_mod.DiosixGui;

/// Worst-case growth when escaping one byte: '"' and '\' become two bytes.
const MAX_ESCAPED_BYTES_PER_CHAR: usize = 2;

/// Escape '"' and '\' in an input string for safe JSON emission. Bytes
/// outside printable ASCII (0x20..0x7e) are dropped, as they cannot appear
/// in a valid OSK string. The result is never truncated; the caller owns
/// it and must free it with `allocator`.
pub fn escapeStr(
    allocator: std.mem.Allocator,
    raw: []const u8,
) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(
        allocator,
        raw.len * MAX_ESCAPED_BYTES_PER_CHAR,
    );
    for (raw) |c| {
        if (c == '"' or c == '\\') {
            out.appendAssumeCapacity('\\');
            out.appendAssumeCapacity(c);
        } else if (c >= 0x20 and c <= 0x7e) {
            out.appendAssumeCapacity(c);
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn triggerSemanticAction(self: *DiosixGui, action: []const u8) !bool {
    const SemAct = gui_mod.SemanticAction;
    const act = std.meta.stringToEnum(SemAct, action) orelse return false;
    switch (act) {
        .@"menu.create_vm" => {
            try self.activateMenuItem(gui_mod.ICON_MENU_CREATE_VM_ID);
            self.completeNavAnimation();
        },
        .@"menu.about", .@"menu.status" => {
            try self.activateMenuItem(gui_mod.ICON_MENU_ABOUT_ID);
            self.completeNavAnimation();
        },
        .@"menu.config" => {
            try self.activateMenuItem(gui_mod.ICON_MENU_CONFIG_ID);
            self.completeNavAnimation();
        },
        .@"menu.back" => {
            try self.navigateBack();
            self.completeNavAnimation();
        },
        .@"osk.toggle" => try self.toggleOsk(),
        .@"osk.show" => {
            self.osk_state.visible = true;
            try self.buildOskWindow();
        },
        .@"osk.hide" => {
            self.osk_state.visible = false;
            _ = self.destroyWindow(gui_mod.WIN_OSK_ID);
            self.markFullDirty();
        },
        .@"welcome.open" => try self.showWelcomeModal(),
        .@"welcome.close" => {
            self.welcome_state.closeWelcome();
            _ = self.destroyWindow(gui_mod.WIN_WELCOME_ID);
            self.markFullDirty();
        },
        .@"welcome.try_desktop" => {
            gui_mod.demo_mod.launchDemoVm(self, .desktop);
        },
        .@"welcome.try_cli" => {
            gui_mod.demo_mod.launchDemoVm(self, .cli);
        },
        .@"tour.start" => {
            self.welcome_state.startTour();
            try self.showTourModal();
        },
        .@"tour.next" => {
            self.welcome_state.nextStep();
            if (self.welcome_state.tour_visible) {
                try self.showTourModal();
            } else {
                _ = self.destroyWindow(gui_mod.WIN_TOUR_ID);
                self.markFullDirty();
            }
        },
        .@"tour.prev" => {
            self.welcome_state.prevStep();
            if (self.welcome_state.tour_visible) {
                try self.showTourModal();
            }
        },
        .@"tour.close" => {
            self.welcome_state.closeTour();
            _ = self.destroyWindow(gui_mod.WIN_TOUR_ID);
            self.markFullDirty();
        },
    }
    return true;
}

pub fn exportSemanticStateJson(
    self: *const DiosixGui,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error![]u8 {
    const active_pane: []const u8 = if (self.active_menu_id) |mid|
        switch (mid) {
            gui_mod.ICON_MENU_CREATE_VM_ID => "create_vm",
            gui_mod.ICON_MENU_ABOUT_ID => "about",
            gui_mod.ICON_MENU_CONFIG_ID => "config",
            gui_mod.ICON_MENU_DISPLAY_ID => "guest_display",
            else => "submenu",
        }
    else
        "main";

    const esc_osk = try escapeStr(allocator, self.osk_state.getInputText());
    defer allocator.free(esc_osk);
    const fmt =
        "{{\"width\":{d},\"height\":{d},\"render_mode\":\"{s}\"," ++
        "\"active_pane\":\"{s}\",\"window_count\":{d}," ++
        "\"osk_visible\":{s}," ++
        "\"osk_layout\":\"{s}\",\"osk_input\":\"{s}\"," ++
        "\"welcome_visible\":{s},\"tour_visible\":{s},\"tour_step\":{d}}}\n";

    return allocator.print(fmt, .{
        self.width,
        self.height,
        if (self.render_mode == .accelerated) "accelerated" else "degraded",
        active_pane,
        self.windows.items.len,
        if (self.osk_state.visible) "true" else "false",
        self.osk_state.layout.label(),
        esc_osk,
        if (self.welcome_state.welcome_visible) "true" else "false",
        if (self.welcome_state.tour_visible) "true" else "false",
        self.welcome_state.current_step + 1,
    });
}

test "escapeStr escapes quotes and backslashes" {
    const out = try escapeStr(std.testing.allocator, "a\"b\\c");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a\\\"b\\\\c", out);
}

test "escapeStr drops control and non-ascii bytes" {
    const out = try escapeStr(std.testing.allocator, "x\n\x01\xffy");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("xy", out);
}

test "escapeStr never truncates long input" {
    const LONG_INPUT_BYTES: usize = 1000;
    const raw = try std.testing.allocator.alloc(u8, LONG_INPUT_BYTES);
    defer std.testing.allocator.free(raw);
    @memset(raw, '"');
    const out = try escapeStr(std.testing.allocator, raw);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(
        LONG_INPUT_BYTES * MAX_ESCAPED_BYTES_PER_CHAR,
        out.len,
    );
    try std.testing.expectEqualStrings("\\\"\\\"", out[out.len - 4 ..]);
}

test "escapeStr of empty input is empty" {
    const out = try escapeStr(std.testing.allocator, "");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test {
    std.testing.refAllDecls(@This());
}
