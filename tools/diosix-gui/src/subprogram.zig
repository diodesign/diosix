// Sub-Program Architecture and Preemptive Multitasking Interface for Diosix GUI
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const window_mod = @import("window.zig");
const Window = window_mod.Window;

pub const SubProgram = struct {
    id: u32,
    name: []const u8,
    tab_title: []const u8,

    init_fn: *const fn (self: *SubProgram, gui_ctx: *anyopaque) void,
    tick_fn: *const fn (self: *SubProgram, gui_ctx: *anyopaque, dt_ms: u32, is_active: bool) void,
    on_activate_fn: *const fn (self: *SubProgram, gui_ctx: *anyopaque) void,
    on_deactivate_fn: *const fn (self: *SubProgram, gui_ctx: *anyopaque) void,
    handle_key_fn: *const fn (self: *SubProgram, gui_ctx: *anyopaque, key_code: u16, key_char: ?u8, pressed: bool) bool,
    handle_mouse_click_fn: *const fn (self: *SubProgram, gui_ctx: *anyopaque, px: i32, py: i32) bool,
    handle_mouse_move_fn: *const fn (self: *SubProgram, gui_ctx: *anyopaque, px: i32, py: i32, left_down: bool) void,

    allocator: std.mem.Allocator,
    window_ids: std.ArrayList(u32) = .empty,
    user_data: ?*anyopaque = null,

    pub fn init(
        allocator: std.mem.Allocator,
        id: u32,
        name: []const u8,
        tab_title: []const u8,
        init_fn: *const fn (self: *SubProgram, gui_ctx: *anyopaque) void,
        tick_fn: *const fn (self: *SubProgram, gui_ctx: *anyopaque, dt_ms: u32, is_active: bool) void,
        on_activate_fn: *const fn (self: *SubProgram, gui_ctx: *anyopaque) void,
        on_deactivate_fn: *const fn (self: *SubProgram, gui_ctx: *anyopaque) void,
        handle_key_fn: *const fn (self: *SubProgram, gui_ctx: *anyopaque, key_code: u16, key_char: ?u8, pressed: bool) bool,
        handle_mouse_click_fn: *const fn (self: *SubProgram, gui_ctx: *anyopaque, px: i32, py: i32) bool,
        handle_mouse_move_fn: *const fn (self: *SubProgram, gui_ctx: *anyopaque, px: i32, py: i32, left_down: bool) void,
    ) SubProgram {
        return .{
            .id = id,
            .allocator = allocator,
            .name = name,
            .tab_title = tab_title,
            .init_fn = init_fn,
            .tick_fn = tick_fn,
            .on_activate_fn = on_activate_fn,
            .on_deactivate_fn = on_deactivate_fn,
            .handle_key_fn = handle_key_fn,
            .handle_mouse_click_fn = handle_mouse_click_fn,
            .handle_mouse_move_fn = handle_mouse_move_fn,
            .window_ids = .empty,
        };
    }

    pub fn deinit(self: *SubProgram) void {
        self.window_ids.deinit(self.allocator);
    }
};
