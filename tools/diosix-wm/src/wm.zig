const std = @import("std");
const fb = @import("framebuffer.zig");
const font = @import("font.zig");
const win_mod = @import("window.zig");

pub const Window = win_mod.Window;
pub const WindowFlags = win_mod.WindowFlags;
pub const Task = win_mod.Task;
pub const Event = win_mod.Event;
pub const EventKind = win_mod.EventKind;
pub const Button = win_mod.Button;
pub const MouseAction = win_mod.MouseAction;
pub const FurnitureRegion = win_mod.FurnitureRegion;
pub const DragKind = win_mod.DragKind;

pub const WindowManager = struct {
    allocator: std.mem.Allocator,
    scr_width: u32,
    scr_height: u32,
    windows: std.ArrayList(*Window) = .empty,
    dirty_tracker: fb.DamageTracker = .{},
    drag_window: ?*Window = null,
    drag_kind: DragKind = .none,
    drag_offset: fb.Point = .{ .x = 0, .y = 0 },
    drag_scroll_start: i32 = 0,
    blitted_box: ?fb.Box = null,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) WindowManager {
        return .{
            .allocator = allocator,
            .scr_width = width,
            .scr_height = height,
            .windows = .empty,
            .dirty_tracker = .{},
            .drag_window = null,
            .drag_kind = .none,
            .drag_offset = .{ .x = 0, .y = 0 },
            .drag_scroll_start = 0,
            .blitted_box = null,
        };
    }

    pub fn deinit(self: *WindowManager) void {
        for (self.windows.items) |win| {
            if (win.task.handle) |cb| {
                const ev = Event{ .kind = .quit, .data = .{ .quit = {} } };
                _ = cb(win, &ev, win.task.task_data) catch {};
            }
            self.allocator.destroy(win);
        }
        self.windows.deinit(self.allocator);
    }

    pub fn createWindow(
        self: *WindowManager,
        content_x: i32,
        content_y: i32,
        content_w: u32,
        content_h: u32,
        title: []const u8,
        flags: WindowFlags,
        task: Task,
        doc_w: u32,
        doc_h: u32,
    ) !*Window {
        const win = try self.allocator.create(Window);
        win.* = Window.init(content_x, content_y, content_w, content_h, title, flags, task, doc_w, doc_h);

        // Nudge back on-screen so the titlebar/furniture stay reachable (Wuss create.c)
        var dx: i32 = 0;
        if (win.visible.x0 < 0) {
            dx = -win.visible.x0;
        } else if (win.visible.x1 > self.scr_width) {
            dx = @as(i32, @intCast(self.scr_width)) - win.visible.x1;
        }
        if (win.visible.x0 + dx < 0) {
            dx = -win.visible.x0;
        }

        var dy: i32 = 0;
        if (win.visible.y0 < 0) {
            dy = -win.visible.y0;
        } else if (win.visible.y1 > self.scr_height) {
            dy = @as(i32, @intCast(self.scr_height)) - win.visible.y1;
        }
        if (win.visible.y0 + dy < 0) {
            dy = -win.visible.y0;
        }

        win.visible.x0 += dx;
        win.visible.x1 += dx;
        win.visible.y0 += dy;
        win.visible.y1 += dy;
        win.saved_visible = win.visible;
        win.pre_toggle = win.visible;

        // Wire up window invalidation callback to window manager
        win.wm_ptr = @ptrCast(self);
        win.invalidate_fn = wmInvalidateWindow;
        win.invalidate_furniture_fn = wmInvalidateFurniture;

        // Insert at head (topmost in z-order)
        try self.windows.insert(self.allocator, 0, win);
        self.setActiveWindow(win);
        self.invalidate(win.visible);
        win.notifyOpen();

        return win;
    }

    pub fn setActiveWindow(self: *WindowManager, active_win: ?*Window) void {
        for (self.windows.items) |w| {
            const should_be_active = (active_win != null and w == active_win.?);
            if (w.is_active != should_be_active) {
                w.is_active = should_be_active;
                self.invalidate(w.titlebarBox());
            }
        }
    }

    pub fn closeWindow(self: *WindowManager, doomed: *Window) void {
        var idx: ?usize = null;
        for (self.windows.items, 0..) |w, i| {
            if (w == doomed) {
                idx = i;
                break;
            }
        }
        const i = idx orelse return;

        if (doomed.task.handle) |cb| {
            const ev = Event{ .kind = .quit, .data = .{ .quit = {} } };
            _ = cb(doomed, &ev, doomed.task.task_data) catch {};
        }

        if (self.drag_window == doomed) {
            self.drag_window = null;
            self.drag_kind = .none;
        }

        _ = self.windows.orderedRemove(i);
        self.invalidate(doomed.visible);

        self.setActiveWindow(if (self.windows.items.len > 0) self.windows.items[0] else null);

        self.allocator.destroy(doomed);
    }

    pub fn restackWindow(self: *WindowManager, win: *Window, reason: enum { front, back }) void {
        var idx: ?usize = null;
        for (self.windows.items, 0..) |w, i| {
            if (w == win) {
                idx = i;
                break;
            }
        }
        const i = idx orelse return;

        switch (reason) {
            .front => {
                if (i == 0) {
                    self.setActiveWindow(win);
                    return;
                }
                self.invalidateUncovered(win);
                _ = self.windows.orderedRemove(i);
                self.windows.insert(self.allocator, 0, win) catch return;
                self.setActiveWindow(win);
            },
            .back => {
                if (i == self.windows.items.len - 1) {
                    self.setActiveWindow(if (self.windows.items.len > 0) self.windows.items[0] else null);
                    return;
                }
                _ = self.windows.orderedRemove(i);
                self.windows.append(self.allocator, win) catch return;

                self.invalidate(win.visible);
                self.setActiveWindow(if (self.windows.items.len > 0) self.windows.items[0] else null);
            },
        }
    }

    pub fn invalidate(self: *WindowManager, box: fb.Box) void {
        const clamped = box.intersection(fb.Box.fromPosSize(0, 0, self.scr_width, self.scr_height)) orelse return;
        self.dirty_tracker.markDirty(clamped);
    }

    pub fn clipToVisible(self: *const WindowManager, win: *const Window, box: fb.Box, out_pieces: *[32]fb.Box) usize {
        var win_idx: usize = 0;
        for (self.windows.items, 0..) |w, i| {
            if (w == win) {
                win_idx = i;
                break;
            }
        }

        if (win_idx == 0) {
            out_pieces[0] = box;
            return 1;
        }

        var occluders: [32]fb.Box = undefined;
        var num_occluders: usize = 0;
        for (self.windows.items[0..win_idx]) |w| {
            if (num_occluders < 32) {
                occluders[num_occluders] = w.visible;
                num_occluders += 1;
            }
        }

        return fb.subtractBoxes(box, occluders[0..num_occluders], out_pieces);
    }

    pub fn invalidateUncovered(self: *WindowManager, win: *Window) void {
        var visible_pieces: [32]fb.Box = undefined;
        const nvisible = self.clipToVisible(win, win.visible, &visible_pieces);

        var hidden_pieces: [32]fb.Box = undefined;
        const nhidden = fb.subtractBoxes(win.visible, visible_pieces[0..nvisible], &hidden_pieces);

        for (hidden_pieces[0..nhidden]) |piece| {
            self.invalidate(piece);
        }
    }

    pub fn invalidateMinus(self: *WindowManager, whole: fb.Box, keep: fb.Box) void {
        const cut = keep.intersection(whole) orelse {
            self.invalidate(whole);
            return;
        };
        var slivers: [4]fb.Box = undefined;
        const count = whole.subtract(cut, &slivers);
        for (slivers[0..count]) |sliver| {
            self.invalidate(sliver);
        }
    }

    pub fn invalidateWindow(self: *WindowManager, win: *Window, local_box: ?fb.Box) void {
        const cb = win.contentBox();
        const screen_box = if (local_box) |lb| fb.Box{
            .x0 = cb.x0 - win.scroll.x + lb.x0,
            .y0 = cb.y0 - win.scroll.y + lb.y0,
            .x1 = cb.x0 - win.scroll.x + lb.x1,
            .y1 = cb.y0 - win.scroll.y + lb.y1,
        } else cb;

        var pieces: [32]fb.Box = undefined;
        const npieces = self.clipToVisible(win, screen_box, &pieces);
        for (pieces[0..npieces]) |piece| {
            self.invalidate(piece);
        }
    }

    fn wmInvalidateWindow(win: *Window, local_box: ?fb.Box) void {
        if (win.wm_ptr) |p| {
            const wm: *WindowManager = @ptrCast(@alignCast(p));
            wm.invalidateWindow(win, local_box);
        }
    }

    fn wmInvalidateFurniture(win: *Window) void {
        if (win.wm_ptr) |p| {
            const wm: *WindowManager = @ptrCast(@alignCast(p));
            if (!win.flags.no_vscroll) wm.invalidate(win.vscrollWellBox());
            if (!win.flags.no_hscroll) wm.invalidate(win.hscrollWellBox());
        }
    }

    pub fn windowAt(self: *const WindowManager, p: fb.Point) ?*Window {
        for (self.windows.items) |w| {
            if (w.visible.containsPoint(p)) return w;
        }
        return null;
    }

    pub fn mouseClick(self: *WindowManager, p: fb.Point, button: Button, action: MouseAction) !void {
        if (action == .up and self.drag_window != null) {
            self.drag_window = null;
            self.drag_kind = .none;
            return;
        }

        const win = self.windowAt(p) orelse return;
        const region = win.hitTest(p);

        switch (region) {
            .close => {
                if (action == .down and button == .select) {
                    if (win.task.handle) |cb| {
                        const ev = Event{ .kind = .close, .data = .{ .close = {} } };
                        _ = cb(win, &ev, win.task.task_data) catch {};
                    }
                    self.closeWindow(win);
                }
            },
            .back => {
                if (action == .down) {
                    if (button == .select) {
                        self.restackWindow(win, .back);
                    } else if (button == .adjust) {
                        self.restackWindow(win, .front);
                    }
                }
            },
            .toggle_size => {
                if (action == .down and button == .select) {
                    self.restackWindow(win, .front);
                    const before = win.visible;
                    win.toggleSize(self.scr_width, self.scr_height);
                    self.invalidate(before.unionWith(win.visible));
                }
            },
            .vscroll_up => {
                if (action == .down and button == .select) {
                    self.restackWindow(win, .front);
                    win.scrollStep(.{ .x = 0, .y = -Window.SCROLL_STEP });
                }
            },
            .vscroll_down => {
                if (action == .down and button == .select) {
                    self.restackWindow(win, .front);
                    win.scrollStep(.{ .x = 0, .y = Window.SCROLL_STEP });
                }
            },
            .hscroll_left => {
                if (action == .down and button == .select) {
                    self.restackWindow(win, .front);
                    win.scrollStep(.{ .x = -Window.SCROLL_STEP, .y = 0 });
                }
            },
            .hscroll_right => {
                if (action == .down and button == .select) {
                    self.restackWindow(win, .front);
                    win.scrollStep(.{ .x = Window.SCROLL_STEP, .y = 0 });
                }
            },
            .vscroll_well, .vscroll_sausage => {
                if (action == .down) {
                    if (button == .select) self.restackWindow(win, .front);
                    self.drag_window = win;
                    self.drag_kind = .vscroll_sausage;
                    self.drag_offset = p;
                    self.drag_scroll_start = win.scroll.y;
                }
            },
            .hscroll_well, .hscroll_sausage => {
                if (action == .down) {
                    if (button == .select) self.restackWindow(win, .front);
                    self.drag_window = win;
                    self.drag_kind = .hscroll_sausage;
                    self.drag_offset = p;
                    self.drag_scroll_start = win.scroll.x;
                }
            },
            .resize => {
                if (action == .down) {
                    if (button == .select) self.restackWindow(win, .front);
                    self.drag_window = win;
                    self.drag_kind = .resize;
                }
            },
            .title => {
                if (action == .down) {
                    if (button == .select) self.restackWindow(win, .front);
                    self.drag_window = win;
                    self.drag_kind = .move;
                    self.drag_offset = .{ .x = p.x - win.visible.x0, .y = p.y - win.visible.y0 };
                }
            },
            .content => {
                if (action == .down and button == .select) {
                    self.restackWindow(win, .front);
                }
                if (win.task.handle) |cb| {
                    const cb_box = win.contentBox();
                    const ev = Event{
                        .kind = .mouse,
                        .data = .{
                            .mouse = .{
                                .action = action,
                                .point = .{
                                    .x = p.x - cb_box.x0 + win.scroll.x,
                                    .y = p.y - cb_box.y0 + win.scroll.y,
                                },
                                .button = button,
                            },
                        },
                    };
                    try cb(win, &ev, win.task.task_data);
                }
            },
            .none => {},
        }
    }

    pub fn mouseMove(self: *WindowManager, p: fb.Point, backbuffer: ?*fb.Surface) !void {
        if (self.drag_window) |win| {
            switch (self.drag_kind) {
                .move => {
                    const target_x = p.x - self.drag_offset.x;
                    const target_y = p.y - self.drag_offset.y;
                    if (target_x != win.visible.x0 or target_y != win.visible.y0) {
                        const is_topmost = (self.windows.items.len > 0 and self.windows.items[0] == win);
                        const before = win.visible;
                        const w = win.width();
                        const h = win.height();
                        win.visible.x0 = target_x;
                        win.visible.y0 = target_y;
                        win.visible.x1 = target_x + @as(i32, @intCast(w));
                        win.visible.y1 = target_y + @as(i32, @intCast(h));
                        win.notifyOpen();

                        if (is_topmost and backbuffer != null) {
                            if (backbuffer.?.copyBoxWithin(before, win.visible.x0, win.visible.y0)) |copied| {
                                // Topmost blit succeeded: only vacated slivers need repainting
                                self.invalidateMinus(before, win.visible);
                                self.invalidateMinus(win.visible, copied);
                                const moved_area = before.unionWith(win.visible);
                                self.blitted_box = if (self.blitted_box) |bb| bb.unionWith(moved_area) else moved_area;
                            } else {
                                self.invalidate(before.unionWith(win.visible));
                            }
                        } else {
                            self.invalidate(before.unionWith(win.visible));
                        }
                    }
                },
                .resize => {
                    const before = win.visible;
                    win.dragResize(p);
                    self.invalidate(before.unionWith(win.visible));
                },
                .vscroll_sausage => {
                    win.dragSausage(p.y - self.drag_offset.y, self.drag_scroll_start, false);
                    self.invalidate(win.visible);
                },
                .hscroll_sausage => {
                    win.dragSausage(p.x - self.drag_offset.x, self.drag_scroll_start, true);
                    self.invalidate(win.visible);
                },
                .none => {},
            }
        } else {
            const win = self.windowAt(p) orelse return;
            if (win.hitTest(p) == .content) {
                if (win.task.handle) |cb| {
                    const cb_box = win.contentBox();
                    const ev = Event{
                        .kind = .mouse,
                        .data = .{
                            .mouse = .{
                                .action = .move,
                                .point = .{
                                    .x = p.x - cb_box.x0 + win.scroll.x,
                                    .y = p.y - cb_box.y0 + win.scroll.y,
                                },
                                .button = .select,
                            },
                        },
                    };
                    try cb(win, &ev, win.task.task_data);
                }
            }
        }
    }

    pub fn scroll(self: *WindowManager, p: fb.Point, delta: i32) !void {
        const win = self.windowAt(p) orelse return;
        if (win.hitTest(p) == .content and win.task.handle != null) {
            const cb_box = win.contentBox();
            const ev = Event{
                .kind = .scroll,
                .data = .{
                    .scroll = .{
                        .point = .{
                            .x = p.x - cb_box.x0 + win.scroll.x,
                            .y = p.y - cb_box.y0 + win.scroll.y,
                        },
                        .delta = delta,
                    },
                },
            };
            try win.task.handle.?(win, &ev, win.task.task_data);
        } else if (!win.flags.no_vscroll) {
            win.scrollStep(.{ .x = 0, .y = -delta * Window.SCROLL_STEP });
            self.invalidate(win.visible);
        }
    }

    pub fn idle(self: *WindowManager) !void {
        for (self.windows.items) |win| {
            if (win.task.handle) |cb| {
                const ev = Event{ .kind = .idle, .data = .{ .idle = {} } };
                try cb(win, &ev, win.task.task_data);
            }
        }
    }

    pub fn redrawDirty(self: *WindowManager, surface: *fb.Surface) ?fb.Box {
        const maybe_total_dmg = self.dirty_tracker.consume();
        if (maybe_total_dmg == null and self.blitted_box == null) return null;

        const total_dmg = maybe_total_dmg orelse fb.Box.fromPosSize(0, 0, 0, 0);
        const flush_box = if (self.blitted_box) |bb| bb.unionWith(total_dmg) else total_dmg;
        self.blitted_box = null;

        if (!total_dmg.isEmpty()) {
            // Clear vacated background in damaged area
            surface.fillBox(total_dmg, fb.Color.DESKTOP_BG);

            // Render windows back-to-front (index len-1 down to 0)
            var w_idx = self.windows.items.len;
            while (w_idx > 0) {
                w_idx -= 1;
                const win = self.windows.items[w_idx];
                const win_clip = win.visible.intersection(total_dmg) orelse continue;

                // 1. Draw furniture clipped to dirty region
                win.renderFurniture(surface, win_clip);

                // 2. Draw visible pieces of content
                const cb = win.contentBox();
                if (cb.intersection(win_clip)) |cb_clipped| {
                    var pieces: [32]fb.Box = undefined;
                    const npieces = self.clipToVisible(win, cb_clipped, &pieces);
                    for (pieces[0..npieces]) |piece| {
                        win.renderContentPiece(surface, piece);
                    }
                }
            }

            surface.resetClip();
        }

        return flush_box;
    }

    pub fn redrawAll(self: *WindowManager, surface: *fb.Surface) fb.Box {
        surface.clear(fb.Color.DESKTOP_BG);

        var w_idx = self.windows.items.len;
        while (w_idx > 0) {
            w_idx -= 1;
            const win = self.windows.items[w_idx];
            win.renderFurniture(surface, win.visible);
            win.renderContentPiece(surface, win.contentBox());
        }

        surface.resetClip();
        return fb.Box.fromPosSize(0, 0, self.scr_width, self.scr_height);
    }
};

test "wm: window creation, z-ordering, and restacking" {
    const testing = std.testing;
    var wm = WindowManager.init(testing.allocator, 1280, 800);
    defer wm.deinit();

    const w1 = try wm.createWindow(50, 50, 300, 200, "Window 1", .{}, .{}, 300, 200);
    const w2 = try wm.createWindow(150, 150, 300, 200, "Window 2", .{}, .{}, 300, 200);

    // w2 was created last, so it is topmost (index 0)
    try testing.expectEqual(@as(usize, 2), wm.windows.items.len);
    try testing.expectEqual(w2, wm.windows.items[0]);
    try testing.expectEqual(w1, wm.windows.items[1]);

    // Send w2 to back
    wm.restackWindow(w2, .back);
    try testing.expectEqual(w1, wm.windows.items[0]);
    try testing.expectEqual(w2, wm.windows.items[1]);

    // Bring w2 to front
    wm.restackWindow(w2, .front);
    try testing.expectEqual(w2, wm.windows.items[0]);
    try testing.expectEqual(w1, wm.windows.items[1]);

    // Close w2
    wm.closeWindow(w2);
    try testing.expectEqual(@as(usize, 1), wm.windows.items.len);
    try testing.expectEqual(w1, wm.windows.items[0]);
}

test "wm: mouse routing and dragging" {
    const testing = std.testing;
    var wm = WindowManager.init(testing.allocator, 1000, 800);
    defer wm.deinit();

    const w1 = try wm.createWindow(100, 100, 300, 200, "Drag Test", .{}, .{}, 300, 200);

    // Mouse down on titlebar starts move drag
    const tb = w1.titlebarBox();
    try wm.mouseClick(.{ .x = tb.x0 + 50, .y = tb.y0 + 10 }, .select, .down);
    try testing.expectEqual(w1, wm.drag_window);
    try testing.expectEqual(DragKind.move, wm.drag_kind);

    // Mouse move updates position
    try wm.mouseMove(.{ .x = tb.x0 + 100, .y = tb.y0 + 60 }, null);
    try testing.expectEqual(@as(i32, 150), w1.contentBox().x0);
    try testing.expectEqual(@as(i32, 150), w1.contentBox().y0);

    // Mouse up ends drag
    try wm.mouseClick(.{ .x = tb.x0 + 100, .y = tb.y0 + 60 }, .select, .up);
    try testing.expect(wm.drag_window == null);
    try testing.expectEqual(DragKind.none, wm.drag_kind);
}
