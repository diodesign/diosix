// Diosix GUI Window Input, Focus, and Mouse Event Handling.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("../framebuffer.zig");
const font = @import("../font.zig");
const icon_mod = @import("../icon.zig");
const Icon = icon_mod.Icon;
const widgets = @import("../icon/widgets.zig");
const window_mod = @import("../window.zig");
const Window = window_mod.Window;

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
            if (self.icons.items[idx].is_selectable) {
                self.icons.items[idx].is_focused = true;
                _ = self.scrollToKeepIconVisible(idx);
            } else {
                self.focused_icon_idx = null;
            }
        }
    }
}

pub fn getFocusedIcon(self: *Window) ?*Icon {
    if (self.focused_icon_idx) |idx| {
        if (idx < self.icons.items.len) {
            return &self.icons.items[idx];
        }
    }
    return null;
}

/// Trigger icon click with grouping exclusivity handling.
pub fn triggerIcon(self: *Window, gui_ctx: *anyopaque, icon: *Icon) void {
    if (!icon.is_enabled) return;

    switch (icon.icon_type) {
        .tick_box => {
            if (icon.group_mode == .exclusive and icon.group_id != null) {
                // Exclusive group (Radio behavior): check this one and uncheck
                // all others in the group.
                const target_group = icon.group_id.?;
                for (self.icons.items) |*other| {
                    if (other.group_id == target_group and
                        other.group_mode == .exclusive)
                    {
                        other.is_ticked = (other.id == icon.id);
                    }
                }
                icon.is_ticked = true;
            } else {
                // Inclusive group or independent toggle.
                icon.is_ticked = !icon.is_ticked;
            }
        },
        .button => {
            icon.is_active_press = true;
        },
        .read_write_text => {},
        .slider => {},
        .read_only_text => {},
        .menu_item, .dropdown => {
            icon.is_active_press = true;
        },
    }

    // Fire optional user callback.
    if (icon.callback) |cb| {
        cb(gui_ctx, @ptrCast(self), icon);
    }
}

/// Compute and apply a slider icon's value from an absolute mouse X position.
pub fn updateSliderFromMouseX(
    self: *Window,
    gui_ctx: *anyopaque,
    icon: *Icon,
    px: i32,
) bool {
    const sx = self.x + icon.rel_x;
    const line_h = font.getActiveLineHeight();
    const thumb_w = widgets.sliderThumbWidth(line_h);
    const bar_w = widgets.sliderBarWidth(icon, line_h);
    const track_w = if (bar_w > thumb_w) bar_w - thumb_w else 1;
    const half_thumb: i32 = @intCast(thumb_w / 2);
    const click_offset = std.math.clamp(
        px - sx - half_thumb,
        0,
        @as(i32, @intCast(track_w)),
    );
    const span = if (icon.slider_max > icon.slider_min)
        icon.slider_max - icon.slider_min
    else
        1;
    const new_val = icon.slider_min + @divTrunc(
        click_offset * span,
        @as(i32, @intCast(track_w)),
    );
    const changed = (icon.slider_val != new_val);
    icon.setSliderValue(new_val);
    if (icon.callback) |cb| cb(gui_ctx, @ptrCast(self), icon);
    return changed;
}

/// Handle mouse click inside window.
pub fn handleMouseClick(
    self: *Window,
    gui_ctx: *anyopaque,
    px: i32,
    py: i32,
) bool {
    if (!self.is_onscreen) return false;
    if (!self.contains(px, py)) return false;

    // 1. Scrollbar interaction if scrollable.
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

    // 2. Icon interaction within content viewport.
    const c_top = self.getContentTop();
    const c_bot = self.getContentBottom();
    if (py >= c_top and py < c_bot) {
        const win_content_y = self.y - self.scroll_y;
        var i = self.icons.items.len;
        while (i > 0) : (i -= 1) {
            const idx = i - 1;
            const icon = &self.icons.items[idx];
            const icon_sy = win_content_y + icon.rel_y;
            const icon_bot = icon_sy + @as(i32, @intCast(icon.height));
            if (icon_bot <= c_top or icon_sy >= c_bot) continue;

            if (icon.is_selectable and
                icon.hitTest(self.x, win_content_y, px, py))
            {
                self.setFocusedIndex(idx);

                // Reset active press and dragging on all other icons in window.
                for (self.icons.items, 0..) |*other, other_idx| {
                    if (other_idx != idx) {
                        other.is_active_press = false;
                        other.is_hovered = false;
                        other.is_dragging_slider = false;
                        other.is_dragging_select = false;
                    }
                }
                icon.is_hovered = true;

                // Handle slider direct position setting and drag capture.
                if (icon.icon_type == .slider) {
                    self.active_drag_icon_idx = idx;
                    icon.is_dragging_slider = true;
                    _ = updateSliderFromMouseX(self, gui_ctx, icon, px);
                } else if (icon.icon_type == .read_write_text) {
                    self.active_drag_icon_idx = idx;
                    const char_idx = icon.getCharIndexAtX(self.x, px);
                    icon.cursor_pos = char_idx;
                    icon.selection_start = char_idx;
                    icon.selection_end = char_idx;
                    icon.is_dragging_select = true;
                    if (icon.callback) |cb| cb(gui_ctx, @ptrCast(self), icon);
                } else {
                    self.active_drag_icon_idx = null;
                    self.triggerIcon(gui_ctx, icon);
                }
                return true;
            }
        }
    }

    // Click landed on window background: clear active press and drag states.
    for (self.icons.items) |*icon| {
        icon.is_active_press = false;
        icon.is_dragging_slider = false;
        icon.is_dragging_select = false;
    }
    self.active_drag_icon_idx = null;
    return true;
}

/// Reset hover on all icons in this window.
pub fn clearHover(self: *Window) bool {
    var changed = false;
    for (self.icons.items) |*icon| {
        if (icon.is_hovered) {
            icon.is_hovered = false;
            changed = true;
        }
    }
    return changed;
}

/// Handle mouse motion for hover highlights, slider drags, text drag-selection,
/// and scrollbar. Returns true if visual state changed (requiring repaint).
pub fn handleMouseMove(
    self: *Window,
    gui_ctx: *anyopaque,
    px: i32,
    py: i32,
    left_down: bool,
) bool {
    if (!self.is_onscreen) return false;

    var changed = false;

    // 1. Scrollbar drag handling.
    if (self.is_dragging_scrollbar and left_down) {
        const dy = py - self.scrollbar_drag_start_y;
        const track = self.getScrollbarTrackBox();
        const track_h = track.y1 - track.y0;
        const thumb = self.getScrollbarThumbBox();
        const thumb_h = thumb.y1 - thumb.y0;
        const scrollable_range = track_h - thumb_h;
        if (scrollable_range > 0) {
            const total_scroll_range =
                self.getContentHeight() - self.getViewportHeight();
            const delta_scroll = @divTrunc(
                dy * @as(i32, @intCast(total_scroll_range)),
                @as(i32, @intCast(scrollable_range)),
            );
            const new_scroll = std.math.clamp(
                self.scrollbar_drag_start_scroll_y + delta_scroll,
                0,
                @as(i32, @intCast(total_scroll_range)),
            );
            if (new_scroll != self.scroll_y) {
                self.scroll_y = new_scroll;
                changed = true;
            }
        }
    }

    // 2. Scrollbar visibility on hover or active drag.
    if (self.isScrollable()) {
        if (!self.is_dragging_scrollbar) {
            const track = self.getScrollbarTrackBox();
            const closest_x = std.math.clamp(px, track.x0, track.x1);
            const closest_y = std.math.clamp(py, track.y0, track.y1);
            const dx: i64 = px - closest_x;
            const dy: i64 = py - closest_y;
            const dist_sq = dx * dx + dy * dy;

            // Show scrollbar when hovering within 16px of track or dragging.
            const max_dist_sq = Window.SCROLLBAR_PROXIMITY_DIST_SQ;
            const target_alpha: u8 = if (dist_sq <= max_dist_sq) 240 else 0;
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

    // 3. Active icon drag (exclusive dragging for selected slider or text).
    if (self.active_drag_icon_idx) |drag_idx| {
        if (left_down and drag_idx < self.icons.items.len) {
            if (self.icons.items[drag_idx].icon_type == .slider) {
                if (updateSliderFromMouseX(
                    self,
                    gui_ctx,
                    &self.icons.items[drag_idx],
                    px,
                )) {
                    changed = true;
                }
            } else if (self.icons.items[drag_idx].icon_type ==
                .read_write_text)
            {
                const active_icon = &self.icons.items[drag_idx];
                active_icon.is_dragging_select = true;
                const new_idx = active_icon.getCharIndexAtX(self.x, px);
                if (active_icon.selection_end != new_idx or
                    active_icon.cursor_pos != new_idx)
                {
                    active_icon.selection_end = new_idx;
                    active_icon.cursor_pos = new_idx;
                    changed = true;
                }
            }
        } else {
            if (drag_idx < self.icons.items.len) {
                self.icons.items[drag_idx].is_dragging_slider = false;
                self.icons.items[drag_idx].is_dragging_select = false;
            }
            self.active_drag_icon_idx = null;
            changed = true;
        }
    }

    // 4. Hover handling: identify at most the ONE topmost icon under pointer.
    const c_top = self.getContentTop();
    const c_bot = self.getContentBottom();
    const in_content_viewport = (py >= c_top and py < c_bot);
    const win_content_y = self.y - self.scroll_y;
    const is_dragging_any =
        (self.is_dragging_scrollbar or self.active_drag_icon_idx != null);

    var top_hit_idx: ?usize = null;
    if (!is_dragging_any and in_content_viewport and self.contains(px, py)) {
        var i = self.icons.items.len;
        while (i > 0) : (i -= 1) {
            const idx = i - 1;
            const icon = &self.icons.items[idx];
            if (!icon.is_selectable) continue;
            const icon_sy = win_content_y + icon.rel_y;
            const icon_bot = icon_sy + @as(i32, @intCast(icon.height));
            if (icon_bot <= c_top or icon_sy >= c_bot) continue;
            if (icon.hitTest(self.x, win_content_y, px, py)) {
                top_hit_idx = idx;
                break;
            }
        }
    }

    for (self.icons.items, 0..) |*icon, idx| {
        if (!icon.is_selectable) {
            if (icon.is_hovered) {
                icon.is_hovered = false;
                changed = true;
            }
            continue;
        }

        const new_hover = if (is_dragging_any)
            (self.active_drag_icon_idx != null and
                self.active_drag_icon_idx.? == idx)
        else
            (top_hit_idx != null and top_hit_idx.? == idx);

        if (icon.is_hovered != new_hover) {
            icon.is_hovered = new_hover;
            changed = true;
        }

        if (new_hover and !is_dragging_any and icon.icon_type == .menu_item and
            (self.focused_icon_idx == null or self.focused_icon_idx.? != idx))
        {
            self.setFocusedIndex(idx);
            changed = true;
        }
    }
    return changed;
}

/// Handle mouse button release to reset pressed button and drag states.
pub fn handleMouseRelease(self: *Window) bool {
    var changed = false;
    if (self.is_dragging_scrollbar) {
        self.is_dragging_scrollbar = false;
        changed = true;
    }
    if (self.active_drag_icon_idx) |drag_idx| {
        if (drag_idx < self.icons.items.len) {
            self.icons.items[drag_idx].is_dragging_slider = false;
            self.icons.items[drag_idx].is_dragging_select = false;
        }
        self.active_drag_icon_idx = null;
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
        if (icon.is_dragging_slider) {
            icon.is_dragging_slider = false;
        }
    }
    return changed;
}

/// Find an icon at the given absolute screen coordinates (px, py).
pub fn findIconAt(self: *Window, px: i32, py: i32) ?*Icon {
    if (!self.is_onscreen) return null;
    const box = self.getBox();
    if (!box.contains(px, py)) return null;

    const c_top = self.getContentTop();
    const c_bot = self.getContentBottom();
    if (py < c_top or py >= c_bot) return null;

    const win_content_y = self.y - self.scroll_y;
    for (self.icons.items) |*icon| {
        if (icon.containsPoint(self.x, win_content_y, px, py)) {
            return icon;
        }
    }
    return null;
}

test {
    std.testing.refAllDecls(@This());
}
