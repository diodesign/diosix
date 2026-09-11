// Final Fantasy 7/8 Window Pane System for Diosix GUI
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("framebuffer.zig");
const font = @import("font.zig");
const icon_mod = @import("icon.zig");
const Icon = icon_mod.Icon;

pub const Window = struct {
    id: u32,
    x: i32,
    y: i32,
    width: u32,
    height: u32,

    // Coordinates for moving on/off screen
    onscreen_x: i32,
    onscreen_y: i32,
    offscreen_x: i32,
    offscreen_y: i32,
    is_onscreen: bool = true,

    title: ?[]const u8 = null,
    allocator: std.mem.Allocator,
    icons: std.ArrayList(Icon) = .empty,
    focused_icon_idx: ?usize = null,

    is_active: bool = false,
    z_order: u32 = 0,

    // Custom gradient corner colors (defaults to FF7/8 classic gradient)
    c_tl: u32 = fb.Color.FF_LIGHT_BLUE,
    c_tr: u32 = fb.Color.FF_MID_BLUE,
    c_bl: u32 = fb.Color.FF_DARK_BLUE,
    c_br: u32 = fb.Color.FF_BLACK_CORNER,

    pub const CORNER_RADIUS: i32 = 10;
    pub const DEFAULT_OFFSCREEN_OFFSET: i32 = 2000;

    pub fn init(
        allocator: std.mem.Allocator,
        id: u32,
        onscreen_x: i32,
        onscreen_y: i32,
        width: u32,
        height: u32,
        title: ?[]const u8,
    ) Window {
        // Default offscreen parking position is far off to the left/top
        const off_x: i32 = onscreen_x - DEFAULT_OFFSCREEN_OFFSET;
        const off_y: i32 = onscreen_y;

        return .{
            .id = id,
            .allocator = allocator,
            .x = off_x,
            .y = off_y,
            .width = width,
            .height = height,
            .onscreen_x = onscreen_x,
            .onscreen_y = onscreen_y,
            .offscreen_x = off_x,
            .offscreen_y = off_y,
            .is_onscreen = false,
            .title = title,
            .icons = .empty,
        };
    }

    pub fn deinit(self: *Window) void {
        self.icons.deinit(self.allocator);
    }

    pub fn addIcon(self: *Window, icon: Icon) !*Icon {
        try self.icons.append(self.allocator, icon);
        const idx = self.icons.items.len - 1;
        // Default first interactive icon as focused
        if (self.focused_icon_idx == null and icon.icon_type != .read_only_text and icon.is_enabled) {
            self.focused_icon_idx = idx;
            self.icons.items[idx].is_focused = true;
        }
        return &self.icons.items[idx];
    }

    pub fn getIconById(self: *Window, id: u32) ?*Icon {
        for (self.icons.items) |*icon| {
            if (icon.id == id) return icon;
        }
        return null;
    }

    pub fn setOnScreen(self: *Window, on: bool) void {
        self.is_onscreen = on;
        if (on) {
            self.x = self.onscreen_x;
            self.y = self.onscreen_y;
        } else {
            self.x = self.offscreen_x;
            self.y = self.offscreen_y;
        }
    }

    pub fn getBox(self: *const Window) fb.Box {
        return fb.Box.fromPosSize(self.x, self.y, self.width, self.height);
    }

    pub fn contains(self: *const Window, px: i32, py: i32) bool {
        if (!self.is_onscreen) return false;
        return self.getBox().contains(px, py);
    }

    pub fn intersectsBox(self: *const Window, box: fb.Box) bool {
        if (!self.is_onscreen) return false;
        return self.getBox().intersects(box);
    }

    // Move keyboard focus to next interactive icon
    pub fn focusNextIcon(self: *Window) void {
        if (self.icons.items.len == 0) return;
        const start = if (self.focused_icon_idx) |idx| idx + 1 else 0;

        var i: usize = 0;
        while (i < self.icons.items.len) : (i += 1) {
            const check_idx = (start + i) % self.icons.items.len;
            const ic = &self.icons.items[check_idx];
            if (ic.icon_type != .read_only_text and ic.is_enabled) {
                self.setFocusedIndex(check_idx);
                return;
            }
        }
    }

    // Move keyboard focus to previous interactive icon
    pub fn focusPrevIcon(self: *Window) void {
        if (self.icons.items.len == 0) return;
        const cur = self.focused_icon_idx orelse 0;

        var i: usize = 0;
        while (i < self.icons.items.len) : (i += 1) {
            const check_idx = (cur + self.icons.items.len - 1 - i) % self.icons.items.len;
            const ic = &self.icons.items[check_idx];
            if (ic.icon_type != .read_only_text and ic.is_enabled) {
                self.setFocusedIndex(check_idx);
                return;
            }
        }
    }

    pub fn setFocusedIndex(self: *Window, new_idx: ?usize) void {
        if (self.focused_icon_idx) |old_idx| {
            if (old_idx < self.icons.items.len) {
                self.icons.items[old_idx].is_focused = false;
            }
        }
        self.focused_icon_idx = new_idx;
        if (new_idx) |idx| {
            if (idx < self.icons.items.len) {
                self.icons.items[idx].is_focused = true;
            }
        }
    }

    // Trigger icon click with grouping exclusivity handling
    pub fn triggerIcon(self: *Window, gui_ctx: *anyopaque, icon: *Icon) void {
        if (!icon.is_enabled) return;

        switch (icon.icon_type) {
            .tick_box => {
                if (icon.group_mode == .exclusive and icon.group_id != null) {
                    // Exclusive group (Radio behavior): check this one and uncheck all others in the group
                    const target_group = icon.group_id.?;
                    for (self.icons.items) |*other| {
                        if (other.group_id == target_group and other.group_mode == .exclusive) {
                            other.is_ticked = (other.id == icon.id);
                        }
                    }
                    icon.is_ticked = true;
                } else {
                    // Inclusive group or independent toggle
                    icon.is_ticked = !icon.is_ticked;
                }
            },
            .button => {
                icon.is_active_press = true;
            },
            .read_write_text => {
                // Focus for text editing
            },
            .slider => {},
            .read_only_text => {},
        }

        // Fire optional user callback
        if (icon.callback) |cb| {
            cb(gui_ctx, @ptrCast(self), icon);
        }
    }

    // Handle mouse click inside window
    pub fn handleMouseClick(self: *Window, gui_ctx: *anyopaque, px: i32, py: i32) bool {
        if (!self.is_onscreen) return false;
        if (!self.contains(px, py)) return false;

        for (self.icons.items, 0..) |*icon, idx| {
            if (icon.hitTest(self.x, self.y, px, py)) {
                self.setFocusedIndex(idx);

                // Handle slider specific direct position setting
                if (icon.icon_type == .slider) {
                    const sx = self.x + icon.rel_x;
                    const track_w = if (icon.width > 16) icon.width - 16 else 1;
                    const click_offset = std.math.clamp(px - sx - 8, 0, @as(i32, @intCast(track_w)));
                    const span = if (icon.slider_max > icon.slider_min) icon.slider_max - icon.slider_min else 1;
                    const new_val = icon.slider_min + @divTrunc(click_offset * span, @as(i32, @intCast(track_w)));
                    icon.setSliderValue(new_val);
                    if (icon.callback) |cb| cb(gui_ctx, @ptrCast(self), icon);
                } else {
                    self.triggerIcon(gui_ctx, icon);
                }
                return true;
            }
        }
        return true; // Clicked on window background
    }

    // Handle mouse motion for hover highlights and slider drags
    // Returns true if visual state changed (requiring repaint)
    pub fn handleMouseMove(self: *Window, gui_ctx: *anyopaque, px: i32, py: i32, left_down: bool) bool {
        if (!self.is_onscreen) return false;

        var changed = false;
        for (self.icons.items) |*icon| {
            const hit = icon.hitTest(self.x, self.y, px, py);
            if (icon.is_hovered != hit) {
                icon.is_hovered = hit;
                changed = true;
            }

            // Slider drag support
            if (hit and left_down and icon.icon_type == .slider) {
                const sx = self.x + icon.rel_x;
                const track_w = if (icon.width > 16) icon.width - 16 else 1;
                const click_offset = std.math.clamp(px - sx - 8, 0, @as(i32, @intCast(track_w)));
                const span = if (icon.slider_max > icon.slider_min) icon.slider_max - icon.slider_min else 1;
                const new_val = icon.slider_min + @divTrunc(click_offset * span, @as(i32, @intCast(track_w)));
                if (icon.slider_val != new_val) {
                    icon.setSliderValue(new_val);
                    if (icon.callback) |cb| cb(gui_ctx, @ptrCast(self), icon);
                    changed = true;
                }
            }
        }
        return changed;
    }

    // Render this window and all its contained icons
    pub fn render(self: *Window, surface: *fb.Surface, opacity_alpha: u8) void {
        if (!self.is_onscreen) return;

        const box = self.getBox();

        // 1. Draw neutral glass pane with dynamic opacity and subtly rounded corners
        const border_col = if (self.is_active) fb.Color.GLASS_BTN_BORDER else fb.Color.GLASS_BORDER;
        surface.drawRoundedTranslucentBox(box, CORNER_RADIUS, fb.Color.GLASS_BG, opacity_alpha, border_col);

        // 2. Optional Title Banner
        if (self.title) |t| {
            font.drawTextWithShadow(surface, t, self.x + 18, self.y + 12, fb.Color.ACCENT_GOLD, fb.Color.BLACK);
            // Thin translucent divider line under title
            const div_box = fb.Box.fromPosSize(self.x + 16, self.y + 34, self.width - 32, 1);
            surface.fillBox(div_box, fb.Color.GLASS_DIVIDER);
        }

        // 3. Render all icons inside window (icons do not overlap)
        for (self.icons.items) |*icon| {
            icon.render(surface, self.x, self.y, self.is_active);
        }
    }
};
