// Diosix GUI Translucent Slate Glass Window System.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("framebuffer.zig");
const font = @import("font.zig");
const icon_mod = @import("icon.zig");
const Icon = icon_mod.Icon;
const window_input = @import("window/input.zig");

pub const Window = struct {
    id: u32,
    x: i32,
    y: i32,
    width: u32,
    height: u32,

    // Coordinates for moving on/off screen.
    onscreen_x: i32,
    onscreen_y: i32,
    offscreen_x: i32,
    offscreen_y: i32,
    is_onscreen: bool = true,

    title: ?[]const u8 = null,
    allocator: std.mem.Allocator,
    icons: std.ArrayList(Icon) = .empty,
    focused_icon_idx: ?usize = null,
    active_drag_icon_idx: ?usize = null,

    is_active: bool = false,
    z_order: u32 = 0,
    is_modal: bool = false,

    // Scrollable pane state.
    scroll_y: i32 = 0,
    is_dragging_scrollbar: bool = false,
    scrollbar_drag_start_y: i32 = 0,
    scrollbar_drag_start_scroll_y: i32 = 0,
    scrollbar_alpha: u8 = 0,

    // Linked list pane hierarchy: parent -> child -> sub-child.
    parent_window_id: ?u32 = null,
    child_window_id: ?u32 = null,
    linked_menu_item_id: ?u32 = null,

    // Contextual help text for this pane (Priority 2 help text).
    help_text: ?[]const u8 = null,

    pub fn setHelpText(self: *Window, text: ?[]const u8) void {
        self.help_text = text;
    }

    pub fn getHelpText(self: *const Window) ?[]const u8 {
        return self.help_text;
    }

    pub const CORNER_RADIUS: i32 = 10;
    pub const DEFAULT_OFFSCREEN_OFFSET: i32 = 2000;
    pub const SCROLLBAR_WIDTH: u32 = 6;
    pub const SCROLLBAR_MARGIN_RIGHT: i32 = 8;
    pub const SCROLLBAR_PROXIMITY_PX: i32 = 16;
    pub const SCROLLBAR_PROXIMITY_DIST_SQ: i64 =
        @as(i64, SCROLLBAR_PROXIMITY_PX) * @as(i64, SCROLLBAR_PROXIMITY_PX);

    pub fn init(
        allocator: std.mem.Allocator,
        id: u32,
        onscreen_x: i32,
        onscreen_y: i32,
        width: u32,
        height: u32,
        title: ?[]const u8,
    ) Window {
        // Default offscreen parking position is far off to the left/top.
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
        return &self.icons.items[self.icons.items.len - 1];
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

    /// Check if this window has any enabled interactive icons.
    pub fn hasInteractiveIcons(self: *const Window) bool {
        for (self.icons.items) |*ic| {
            if (ic.is_selectable and ic.is_enabled) return true;
        }
        return false;
    }

    // --- Scrollable Viewport & Geometry ---

    pub fn getHeaderHeight(self: *const Window) i32 {
        return if (self.title != null) 36 else 6;
    }

    pub fn getContentTop(self: *const Window) i32 {
        return self.y + self.getHeaderHeight();
    }

    pub fn getContentBottom(self: *const Window) i32 {
        const bot_pad: i32 = if (self.title != null) 10 else 6;
        return self.y + @as(i32, @intCast(self.height)) - bot_pad;
    }

    pub fn getViewportHeight(self: *const Window) i32 {
        const vh = self.getContentBottom() - self.getContentTop();
        return @max(1, vh);
    }

    pub fn getContentHeight(self: *const Window) i32 {
        var max_bottom: i32 = 0;
        for (self.icons.items) |*icon| {
            const bottom = icon.rel_y + @as(i32, @intCast(icon.height));
            if (bottom > max_bottom) max_bottom = bottom;
        }
        const pad: i32 = if (self.title != null) 10 else 6;
        const span = max_bottom + pad;
        return @max(@as(i32, @intCast(self.height)), span);
    }

    pub fn getMaxScroll(self: *const Window) i32 {
        const total = self.getContentHeight();
        const win_h = @as(i32, @intCast(self.height));
        return @max(0, total - win_h);
    }

    pub fn isScrollable(self: *const Window) bool {
        return self.getMaxScroll() > 0;
    }

    pub fn scrollBy(self: *Window, delta: i32) bool {
        const max_s = self.getMaxScroll();
        if (max_s == 0) return false;
        const old_s = self.scroll_y;
        self.scroll_y = std.math.clamp(self.scroll_y + delta, 0, max_s);
        if (self.scroll_y != old_s) {
            self.scrollbar_alpha = 240;
            return true;
        }
        return false;
    }

    pub fn scrollTo(self: *Window, target: i32) bool {
        const max_s = self.getMaxScroll();
        const old_s = self.scroll_y;
        self.scroll_y = std.math.clamp(target, 0, max_s);
        if (self.scroll_y != old_s) {
            self.scrollbar_alpha = 240;
            return true;
        }
        return false;
    }

    pub fn scrollToKeepIconVisible(self: *Window, icon_idx: usize) bool {
        if (icon_idx >= self.icons.items.len) return false;
        const icon = &self.icons.items[icon_idx];
        const max_s = self.getMaxScroll();
        if (max_s == 0) return false;

        const c_top = self.getHeaderHeight();
        const vh = self.getViewportHeight();
        const icon_top = icon.rel_y;
        const icon_bottom = icon.rel_y + @as(i32, @intCast(icon.height));

        var new_scroll = self.scroll_y;
        if (icon_top < self.scroll_y + c_top) {
            new_scroll = icon_top - c_top;
        } else if (icon_bottom > self.scroll_y + c_top + vh) {
            new_scroll = icon_bottom - c_top - vh;
        }

        return self.scrollTo(new_scroll);
    }

    pub fn getScrollbarTrackBox(self: *const Window) fb.Box {
        const sb_x = self.x + @as(i32, @intCast(self.width)) -
            SCROLLBAR_MARGIN_RIGHT - @as(i32, @intCast(SCROLLBAR_WIDTH));
        const track_y = self.getContentTop() + 4;
        const track_h = @max(
            16,
            (self.getContentBottom() - self.getContentTop()) - 8,
        );
        return fb.Box.fromPosSize(
            sb_x,
            track_y,
            SCROLLBAR_WIDTH,
            @intCast(track_h),
        );
    }

    pub fn getScrollbarThumbBox(self: *const Window) fb.Box {
        const track = self.getScrollbarTrackBox();
        const max_s = self.getMaxScroll();
        if (max_s == 0) return fb.Box.fromPosSize(0, 0, 0, 0);

        const vh = self.getViewportHeight();
        const ch = self.getContentHeight();
        const track_h = track.y1 - track.y0;

        const thumb_h = std.math.clamp(
            @divTrunc(track_h * vh, ch),
            20,
            track_h,
        );
        const travel = track_h - thumb_h;
        const thumb_y = track.y0 + @divTrunc(self.scroll_y * travel, max_s);

        return fb.Box.fromPosSize(
            track.x0,
            thumb_y,
            SCROLLBAR_WIDTH,
            @intCast(thumb_h),
        );
    }

    pub fn handleScroll(self: *Window, delta: i32) bool {
        if (!self.isScrollable()) return false;
        return self.scrollBy(delta);
    }

    pub fn setFocusedIndex(self: *Window, new_idx: ?usize) void {
        window_input.setFocusedIndex(self, new_idx);
    }

    pub fn getFocusedIcon(self: *Window) ?*Icon {
        return window_input.getFocusedIcon(self);
    }

    pub fn triggerIcon(self: *Window, gui_ctx: *anyopaque, icon: *Icon) void {
        window_input.triggerIcon(self, gui_ctx, icon);
    }

    pub fn handleMouseClick(
        self: *Window,
        gui_ctx: *anyopaque,
        px: i32,
        py: i32,
    ) bool {
        return window_input.handleMouseClick(self, gui_ctx, px, py);
    }

    pub fn clearHover(self: *Window) bool {
        return window_input.clearHover(self);
    }

    pub fn handleMouseMove(
        self: *Window,
        gui_ctx: *anyopaque,
        px: i32,
        py: i32,
        left_down: bool,
    ) bool {
        return window_input.handleMouseMove(self, gui_ctx, px, py, left_down);
    }

    pub fn handleMouseRelease(self: *Window) bool {
        return window_input.handleMouseRelease(self);
    }

    pub fn findIconAt(self: *Window, px: i32, py: i32) ?*Icon {
        return window_input.findIconAt(self, px, py);
    }

    /// Render this window and all its contained icons.
    pub fn render(self: *Window, surface: *fb.Surface, opacity_alpha: u8) void {
        if (!self.is_onscreen) return;

        const box = self.getBox();

        // 1. Draw minimalist Utopian Scholastic paper pane with solid black
        // structural border and crisp superellipse curvature.
        surface.drawGlassPane(
            box,
            CORNER_RADIUS,
            fb.Color.GLASS_BG,
            opacity_alpha,
            fb.Color.GLASS_BORDER,
            true,
            true,
        );

        // 2. Optional Title Banner & Structural Divider Rule.
        if (self.title) |t| {
            const title_w: u32 = if (self.width > 32) self.width - 32 else 0;
            const title_clip = surface.pushClip(
                fb.Box.fromPosSize(self.x + 16, self.y, title_w, 34),
            );
            font.drawText(
                surface,
                t,
                self.x + 16,
                self.y + 11,
                fb.Color.INK,
            );
            surface.popClip(title_clip);

            // Solid black structural rule under title across the pane.
            if (self.width > 4) {
                const div_box = fb.Box.fromPosSize(
                    self.x + 2,
                    self.y + 34,
                    self.width - 4,
                    1,
                );
                surface.fillBox(div_box, fb.Color.GLASS_DIVIDER);
            }
        }

        // 3. Render icons strictly clipped within the content viewport.
        const c_top = self.getContentTop();
        const c_bot = self.getContentBottom();
        const vh = @max(0, c_bot - c_top);
        const viewport_box = fb.Box.fromPosSize(
            self.x + 2,
            c_top,
            if (self.width > 4) self.width - 4 else 0,
            @intCast(vh),
        );

        const win_content_y = self.y - self.scroll_y;
        {
            const prev_content_clip = surface.pushClip(viewport_box);
            defer surface.popClip(prev_content_clip);

            for (self.icons.items) |*icon| {
                const icon_sy = win_content_y + icon.rel_y;
                const icon_bot = icon_sy + @as(i32, @intCast(icon.height));
                // Quick culling of icons completely outside the viewport.
                if (icon_bot <= c_top or icon_sy >= c_bot) continue;

                icon.render(surface, self.x, win_content_y, self.is_active);
            }
        }

        // 4. Render scrollbar if scrollable and visible.
        if (self.isScrollable() and self.scrollbar_alpha > 0) {
            const track = self.getScrollbarTrackBox();
            const thumb = self.getScrollbarThumbBox();

            // Track is very subtle frosted groove.
            const track_alpha = @min(self.scrollbar_alpha, @as(u8, 60));
            surface.drawRoundedTranslucentBox(
                track,
                3,
                fb.Color.GLASS_BG,
                track_alpha,
                null,
            );

            // Thumb is a monochrome structural pill.
            const thumb_bg = if (self.is_dragging_scrollbar)
                fb.Color.THUMB_BG
            else
                fb.Color.GLASS_BTN_BG;
            surface.drawRoundedTranslucentBox(
                thumb,
                3,
                thumb_bg,
                self.scrollbar_alpha,
                fb.Color.GLASS_BTN_BORDER,
            );
        }
    }
};

test {
    _ = window_input;
    std.testing.refAllDecls(@This());
}
