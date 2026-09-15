// Diosix GUI Translucent Slate Glass Window System
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

    // Scrollable pane state
    scroll_y: i32 = 0,
    is_dragging_scrollbar: bool = false,
    scrollbar_drag_start_y: i32 = 0,
    scrollbar_drag_start_scroll_y: i32 = 0,
    scrollbar_alpha: u8 = 0,

    pub const CORNER_RADIUS: i32 = 10;
    pub const DEFAULT_OFFSCREEN_OFFSET: i32 = 2000;
    pub const SCROLLBAR_WIDTH: u32 = 6;
    pub const SCROLLBAR_MARGIN_RIGHT: i32 = 8;
    pub const SCROLLBAR_PROXIMITY_PX: i32 = 60;

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

    // --- Scrollable Viewport & Geometry ---

    pub fn getHeaderHeight(self: *const Window) i32 {
        return if (self.title != null) 36 else 10;
    }

    pub fn getContentTop(self: *const Window) i32 {
        return self.y + self.getHeaderHeight();
    }

    pub fn getContentBottom(self: *const Window) i32 {
        return self.y + @as(i32, @intCast(self.height)) - 10;
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
        const span = max_bottom + 10;
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
        const sb_x = self.x + @as(i32, @intCast(self.width)) - SCROLLBAR_MARGIN_RIGHT - @as(i32, @intCast(SCROLLBAR_WIDTH));
        const track_y = self.getContentTop() + 4;
        const track_h = @max(16, (self.getContentBottom() - self.getContentTop()) - 8);
        return fb.Box.fromPosSize(sb_x, track_y, SCROLLBAR_WIDTH, @intCast(track_h));
    }

    pub fn getScrollbarThumbBox(self: *const Window) fb.Box {
        const track = self.getScrollbarTrackBox();
        const max_s = self.getMaxScroll();
        if (max_s == 0) return fb.Box.fromPosSize(0, 0, 0, 0);

        const vh = self.getViewportHeight();
        const ch = self.getContentHeight();
        const track_h = track.y1 - track.y0;

        const thumb_h = std.math.clamp(@divTrunc(track_h * vh, ch), 20, track_h);
        const travel = track_h - thumb_h;
        const thumb_y = track.y0 + @divTrunc(self.scroll_y * travel, max_s);

        return fb.Box.fromPosSize(track.x0, thumb_y, SCROLLBAR_WIDTH, @intCast(thumb_h));
    }

    pub fn handleScroll(self: *Window, delta: i32) bool {
        if (!self.isScrollable()) return false;
        return self.scrollBy(delta);
    }

    // Check if an icon is interactive (eligible for keyboard navigation and activation)
    pub fn isIconInteractive(icon: *const Icon) bool {
        return icon.icon_type != .read_only_text and icon.icon_type != .progress_bar and icon.icon_type != .video_viewport and icon.is_enabled;
    }

    // Check if this window has any enabled interactive icons
    pub fn hasInteractiveIcons(self: *const Window) bool {
        for (self.icons.items) |*ic| {
            if (isIconInteractive(ic)) return true;
        }
        return false;
    }

    // Move keyboard focus to next interactive icon in this window.
    // Returns true if advanced to an icon within this window, or false if the end was reached.
    pub fn focusNextIcon(self: *Window) bool {
        if (self.icons.items.len == 0) return false;
        const start = if (self.focused_icon_idx) |idx| idx + 1 else 0;

        var i = start;
        while (i < self.icons.items.len) : (i += 1) {
            const ic = &self.icons.items[i];
            if (isIconInteractive(ic)) {
                self.setFocusedIndex(i);
                return true;
            }
        }
        return false;
    }

    // Move keyboard focus to previous interactive icon in this window.
    // Returns true if moved backward within this window, or false if the beginning was reached.
    pub fn focusPrevIcon(self: *Window) bool {
        if (self.icons.items.len == 0) return false;
        const cur = self.focused_icon_idx orelse return self.focusLastInteractiveIcon();
        if (cur == 0) return false;

        var i: usize = cur;
        while (i > 0) : (i -= 1) {
            const check_idx = i - 1;
            const ic = &self.icons.items[check_idx];
            if (isIconInteractive(ic)) {
                self.setFocusedIndex(check_idx);
                return true;
            }
        }
        return false;
    }

    // Focus the first enabled interactive icon in this window
    pub fn focusFirstInteractiveIcon(self: *Window) bool {
        for (self.icons.items, 0..) |*ic, idx| {
            if (isIconInteractive(ic)) {
                self.setFocusedIndex(idx);
                return true;
            }
        }
        return false;
    }

    // Focus the last enabled interactive icon in this window
    pub fn focusLastInteractiveIcon(self: *Window) bool {
        var i = self.icons.items.len;
        while (i > 0) : (i -= 1) {
            const idx = i - 1;
            const ic = &self.icons.items[idx];
            if (isIconInteractive(ic)) {
                self.setFocusedIndex(idx);
                return true;
            }
        }
        return false;
    }

    // Move keyboard focus to next interactive icon, wrapping to start if reaching the end
    pub fn focusNextIconWrap(self: *Window) void {
        if (!self.focusNextIcon()) {
            _ = self.focusFirstInteractiveIcon();
        }
    }

    // Move keyboard focus to previous interactive icon, wrapping to end if reaching the start
    pub fn focusPrevIconWrap(self: *Window) void {
        if (!self.focusPrevIcon()) {
            _ = self.focusLastInteractiveIcon();
        }
    }

    pub fn setFocusedIndex(self: *Window, new_idx: ?usize) void {
        if (self.focused_icon_idx) |old_idx| {
            if (old_idx < self.icons.items.len) {
                self.icons.items[old_idx].is_focused = false;
                if (self.icons.items[old_idx].icon_type == .read_write_text) {
                    self.icons.items[old_idx].clearSelection();
                }
            }
        }
        self.focused_icon_idx = new_idx;
        if (new_idx) |idx| {
            if (idx < self.icons.items.len) {
                self.icons.items[idx].is_focused = true;
                _ = self.scrollToKeepIconVisible(idx);
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
            .progress_bar => {},
            .video_viewport => {
                icon.is_active_press = true;
            },
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

        // 1. Scrollbar interaction if scrollable
        if (self.isScrollable()) {
            const track = self.getScrollbarTrackBox();
            const hit_track = fb.Box.fromPosSize(
                track.x0 - 4,
                track.y0,
                @as(u32, @intCast(track.x1 - track.x0)) + 8,
                @as(u32, @intCast(track.y1 - track.y0)),
            );
            if (hit_track.contains(px, py)) {
                const thumb = self.getScrollbarThumbBox();
                if (thumb.contains(px, py)) {
                    self.is_dragging_scrollbar = true;
                    self.scrollbar_drag_start_y = py;
                    self.scrollbar_drag_start_scroll_y = self.scroll_y;
                    self.scrollbar_alpha = 255;
                    return true;
                } else if (py < thumb.y0) {
                    _ = self.scrollBy(-self.getViewportHeight());
                    return true;
                } else if (py >= thumb.y1) {
                    _ = self.scrollBy(self.getViewportHeight());
                    return true;
                }
            }
        }

        // 2. Icon interaction within content viewport
        const c_top = self.getContentTop();
        const c_bot = self.getContentBottom();
        if (py >= c_top and py < c_bot) {
            const win_content_y = self.y - self.scroll_y;
            for (self.icons.items, 0..) |*icon, idx| {
                const icon_sy = win_content_y + icon.rel_y;
                const icon_bot = icon_sy + @as(i32, @intCast(icon.height));
                if (icon_bot <= c_top or icon_sy >= c_bot) continue;

                if (icon.hitTest(self.x, win_content_y, px, py)) {
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
                    } else if (icon.icon_type == .read_write_text) {
                        const char_idx = icon.getCharIndexAtX(self.x, px);
                        icon.cursor_pos = char_idx;
                        icon.selection_start = char_idx;
                        icon.selection_end = char_idx;
                        icon.is_dragging_select = true;
                        if (icon.callback) |cb| cb(gui_ctx, @ptrCast(self), icon);
                    } else {
                        self.triggerIcon(gui_ctx, icon);
                    }
                    return true;
                }
            }
        }
        return true; // Clicked on window background
    }

    // Handle mouse motion for hover highlights, slider drags, text drag-selection, and scrollbar
    // Returns true if visual state changed (requiring repaint)
    pub fn handleMouseMove(self: *Window, gui_ctx: *anyopaque, px: i32, py: i32, left_down: bool) bool {
        if (!self.is_onscreen) return false;

        var changed = false;

        // 1. Scrollbar drag tracking
        if (self.is_dragging_scrollbar) {
            if (left_down) {
                const track = self.getScrollbarTrackBox();
                const thumb = self.getScrollbarThumbBox();
                const track_h = track.y1 - track.y0;
                const thumb_h = thumb.y1 - thumb.y0;
                const travel = track_h - thumb_h;
                const max_s = self.getMaxScroll();
                if (travel > 0 and max_s > 0) {
                    const dy = py - self.scrollbar_drag_start_y;
                    const d_scroll = @divTrunc(dy * max_s, travel);
                    const target_scroll = self.scrollbar_drag_start_scroll_y + d_scroll;
                    if (self.scrollTo(target_scroll)) {
                        changed = true;
                    }
                }
                if (self.scrollbar_alpha != 255) {
                    self.scrollbar_alpha = 255;
                    changed = true;
                }
            } else {
                self.is_dragging_scrollbar = false;
                changed = true;
            }
        }

        // 2. Scrollbar proximity fade
        if (self.isScrollable()) {
            if (!self.is_dragging_scrollbar) {
                const track = self.getScrollbarTrackBox();
                const closest_x = std.math.clamp(px, track.x0, track.x1);
                const closest_y = std.math.clamp(py, track.y0, track.y1);
                const dx: i64 = px - closest_x;
                const dy: i64 = py - closest_y;
                const dist_sq = dx * dx + dy * dy;
                const dist = std.math.sqrt(@as(u64, @intCast(dist_sq)));

                var target_alpha: u8 = 0;
                if (dist <= 8) {
                    target_alpha = 240;
                } else if (dist <= SCROLLBAR_PROXIMITY_PX) {
                    const factor = @as(i32, @intCast(SCROLLBAR_PROXIMITY_PX)) - @as(i32, @intCast(dist));
                    const span = SCROLLBAR_PROXIMITY_PX - 8;
                    target_alpha = @intCast(@divTrunc(@as(i32, 240) * factor, span));
                }

                if (self.scrollbar_alpha != target_alpha) {
                    self.scrollbar_alpha = target_alpha;
                    changed = true;
                }
            }
        } else {
            if (self.scrollbar_alpha != 0) {
                self.scrollbar_alpha = 0;
                changed = true;
            }
        }

        // 3. Icons hover and drag handling
        const c_top = self.getContentTop();
        const c_bot = self.getContentBottom();
        const in_content_viewport = (py >= c_top and py < c_bot);
        const win_content_y = self.y - self.scroll_y;

        for (self.icons.items) |*icon| {
            const icon_sy = win_content_y + icon.rel_y;
            const icon_bot = icon_sy + @as(i32, @intCast(icon.height));
            const in_view = !(icon_bot <= c_top or icon_sy >= c_bot);
            const hit = in_content_viewport and in_view and icon.hitTest(self.x, win_content_y, px, py);

            if (icon.is_hovered != hit) {
                icon.is_hovered = hit;
                changed = true;
            }

            // Slider drag support
            if (left_down and icon.icon_type == .slider and (hit or icon.is_focused)) {
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

            // Read-write text select-drag support
            if (icon.icon_type == .read_write_text) {
                if (left_down and (icon.is_dragging_select or (hit and icon.is_focused))) {
                    icon.is_dragging_select = true;
                    const new_idx = icon.getCharIndexAtX(self.x, px);
                    if (icon.selection_end != new_idx or icon.cursor_pos != new_idx) {
                        icon.selection_end = new_idx;
                        icon.cursor_pos = new_idx;
                        changed = true;
                    }
                } else if (!left_down) {
                    icon.is_dragging_select = false;
                }
            }
        }
        return changed;
    }

    // Handle mouse button release to reset pressed button and drag-selection states
    pub fn handleMouseRelease(self: *Window) bool {
        var changed = false;
        if (self.is_dragging_scrollbar) {
            self.is_dragging_scrollbar = false;
            changed = true;
        }
        for (self.icons.items) |*icon| {
            if (icon.is_active_press) {
                icon.is_active_press = false;
                changed = true;
            }
            if (icon.is_dragging_select) {
                icon.is_dragging_select = false;
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

        // 2. Optional Title Banner (clipped to window width)
        if (self.title) |t| {
            const title_w: u32 = if (self.width > 36) self.width - 36 else 0;
            const title_clip = surface.pushClip(fb.Box.fromPosSize(self.x + 18, self.y, title_w, 34));
            font.drawTextWithShadow(surface, t, self.x + 18, self.y + 12, fb.Color.ACCENT_GOLD, fb.Color.BLACK);
            surface.popClip(title_clip);

            // Thin translucent divider line under title
            const div_box = fb.Box.fromPosSize(self.x + 16, self.y + 34, self.width - 32, 1);
            surface.fillBox(div_box, fb.Color.GLASS_DIVIDER);
        }

        // 3. Render icons strictly clipped within the content viewport
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
                // Quick culling of icons completely outside the viewport
                if (icon_bot <= c_top or icon_sy >= c_bot) continue;

                icon.render(surface, self.x, win_content_y, self.is_active);
            }
        }

        // 4. Render scrollbar if scrollable and visible
        if (self.isScrollable() and self.scrollbar_alpha > 0) {
            const track = self.getScrollbarTrackBox();
            const thumb = self.getScrollbarThumbBox();

            // Track is very subtle frosted groove
            const track_alpha = @min(self.scrollbar_alpha, @as(u8, 60));
            surface.drawRoundedTranslucentBox(track, 3, fb.Color.GLASS_BG, track_alpha, fb.Color.TRANSPARENT);

            // Thumb is sleek rounded pill
            // If dragging, glow cyan; otherwise clean slate highlight
            const thumb_bg = if (self.is_dragging_scrollbar) fb.Color.ACCENT_CYAN else fb.Color.GLASS_BTN_BG;
            const thumb_border = if (self.is_dragging_scrollbar) fb.Color.ACCENT_CYAN else fb.Color.GLASS_BTN_BORDER;
            surface.drawRoundedTranslucentBox(thumb, 3, thumb_bg, self.scrollbar_alpha, thumb_border);
        }
    }
};
