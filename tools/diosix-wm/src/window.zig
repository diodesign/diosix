const std = @import("std");
const fb = @import("framebuffer.zig");
const font = @import("font.zig");
const sprites = @import("sprites.zig");

pub const Button = enum {
    select,
    menu,
    adjust,
};

pub const MouseAction = enum {
    down,
    up,
    move,
};

pub const EventKind = enum {
    idle,
    redraw,
    open,
    close,
    mouse,
    scroll,
    key,
    quit,
};

pub const Event = struct {
    kind: EventKind,
    data: union {
        idle: void,
        redraw: struct {
            surface: *fb.Surface,
            content: fb.Box,
            bounds: fb.Box,
            scroll: fb.Point,
        },
        mouse: struct {
            action: MouseAction,
            point: fb.Point,
            button: Button,
        },
        scroll: struct {
            point: fb.Point,
            delta: i32,
        },
        key: struct {
            code: u16,
            value: i32,
        },
        open: void,
        close: void,
        quit: void,
    },
};

pub const Task = struct {
    handle: ?*const fn (win: *Window, ev: *const Event, task_data: ?*anyopaque) anyerror!void = null,
    task_data: ?*anyopaque = null,
    bg: ?u32 = fb.Color.WINDOW_BG,
};

pub const WindowFlags = struct {
    no_titlebar: bool = false,
    no_outline: bool = false,
    no_close: bool = false,
    no_back: bool = false,
    no_toggle_size: bool = false,
    no_vscroll: bool = false,
    no_hscroll: bool = false,
    no_resize: bool = false,
    no_toggle_blit: bool = false,

    pub const none: WindowFlags = .{};
};

pub const FurnitureRegion = enum {
    none,
    content,
    back,
    close,
    title,
    toggle_size,
    vscroll_up,
    vscroll_down,
    vscroll_well,
    vscroll_sausage,
    resize,
    hscroll_left,
    hscroll_right,
    hscroll_well,
    hscroll_sausage,
};

pub const DragKind = enum {
    none,
    move,
    resize,
    vscroll_sausage,
    hscroll_sausage,
};

pub const Window = struct {
    visible: fb.Box,
    saved_visible: fb.Box,
    pre_toggle: fb.Box,
    toggled: bool = false,
    title: []const u8,
    flags: WindowFlags,
    task: Task,
    scroll: fb.Point = .{ .x = 0, .y = 0 },
    doc_width: u32,
    doc_height: u32,
    is_active: bool = true,
    titlebar_h: u32 = 22,
    wm_ptr: ?*anyopaque = null,
    invalidate_fn: ?*const fn (win: *Window, local_box: ?fb.Box) void = null,
    invalidate_furniture_fn: ?*const fn (win: *Window) void = null,

    pub const ICON_INSET: i32 = 3;
    pub const MIN_SAUSAGE: i32 = 6;
    pub const SCROLL_STEP: i32 = 20;
    pub const MIN_CONTENT: i32 = 20;

    pub fn invalidateAll(self: *Window) void {
        self.invalidate(null);
    }

    pub fn invalidate(self: *Window, local_box: ?fb.Box) void {
        if (self.invalidate_fn) |f| f(self, local_box);
    }

    pub fn invalidateFurniture(self: *Window) void {
        if (self.invalidate_furniture_fn) |f| f(self);
    }

    pub fn init(
        content_x: i32,
        content_y: i32,
        content_w: u32,
        content_h: u32,
        title: []const u8,
        flags: WindowFlags,
        task: Task,
        doc_w: u32,
        doc_h: u32,
    ) Window {
        const opx: i32 = if (flags.no_outline) 0 else 1;
        const tbh: i32 = if (flags.no_titlebar) 0 else 22;
        const isz: i32 = if (flags.no_titlebar) 16 else @max(12, tbh - 2 * ICON_INSET);

        var carve_x: i32 = 0;
        var carve_y: i32 = 0;
        if (!flags.no_vscroll) carve_x = isz;
        if (!flags.no_hscroll) carve_y = isz;
        if (!flags.no_resize and flags.no_vscroll and flags.no_hscroll) {
            carve_x = isz;
            carve_y = isz;
        }

        const vis = fb.Box{
            .x0 = content_x - opx,
            .y0 = content_y - opx - tbh,
            .x1 = content_x + @as(i32, @intCast(content_w)) + opx + carve_x,
            .y1 = content_y + @as(i32, @intCast(content_h)) + opx + carve_y,
        };

        return .{
            .visible = vis,
            .saved_visible = vis,
            .pre_toggle = vis,
            .toggled = false,
            .title = title,
            .flags = flags,
            .task = task,
            .scroll = .{ .x = 0, .y = 0 },
            .doc_width = @max(content_w, doc_w),
            .doc_height = @max(content_h, doc_h),
            .is_active = true,
            .titlebar_h = @intCast(@max(0, tbh)),
        };
    }

    pub fn setTitle(self: *Window, new_title: []const u8) void {
        self.title = new_title;
        self.invalidateFurniture();
    }

    pub fn setExtent(self: *Window, doc_w: u32, doc_h: u32) void {
        self.doc_width = doc_w;
        self.doc_height = doc_h;
        self.invalidateFurniture();
    }

    pub fn width(self: *const Window) u32 {
        return self.visible.width();
    }

    pub fn height(self: *const Window) u32 {
        return self.visible.height();
    }

    pub fn outlinePx(self: *const Window) i32 {
        return if (self.flags.no_outline) 0 else 1;
    }

    pub fn titlebarHeight(self: *const Window) i32 {
        return if (self.flags.no_titlebar) 0 else @as(i32, @intCast(self.titlebar_h));
    }

    pub fn iconSize(self: *const Window) i32 {
        const tbh = self.titlebarHeight();
        return if (tbh > 0) @max(12, tbh - 2 * ICON_INSET) else 16;
    }

    pub fn furnitureCarve(self: *const Window) fb.Point {
        const isz = self.iconSize();
        var carve = fb.Point{ .x = 0, .y = 0 };
        if (!self.flags.no_vscroll) carve.x = isz;
        if (!self.flags.no_hscroll) carve.y = isz;
        if (!self.flags.no_resize and self.flags.no_vscroll and self.flags.no_hscroll) {
            carve.x = isz;
            carve.y = isz;
        }
        return carve;
    }

    pub fn titlebarBox(self: *const Window) fb.Box {
        if (self.flags.no_titlebar) return fb.Box.fromPosSize(self.visible.x0, self.visible.y0, 0, 0);
        const opx = self.outlinePx();
        return .{
            .x0 = self.visible.x0 + opx,
            .y0 = self.visible.y0 + opx,
            .x1 = self.visible.x1 - opx,
            .y1 = self.visible.y0 + opx + self.titlebarHeight(),
        };
    }

    pub fn backBox(self: *const Window) fb.Box {
        if (self.flags.no_titlebar or self.flags.no_back) return fb.Box.fromPosSize(0, 0, 0, 0);
        const tb = self.titlebarBox();
        const isz = self.iconSize();
        return .{
            .x0 = tb.x0 + ICON_INSET,
            .y0 = tb.y0 + ICON_INSET,
            .x1 = tb.x0 + ICON_INSET + isz,
            .y1 = tb.y0 + ICON_INSET + isz,
        };
    }

    pub fn closeBox(self: *const Window) fb.Box {
        if (self.flags.no_titlebar or self.flags.no_close) return fb.Box.fromPosSize(0, 0, 0, 0);
        const tb = self.titlebarBox();
        const isz = self.iconSize();
        var x0 = tb.x0 + ICON_INSET;
        if (!self.flags.no_back) {
            x0 += isz + ICON_INSET;
        }
        return .{
            .x0 = x0,
            .y0 = tb.y0 + ICON_INSET,
            .x1 = x0 + isz,
            .y1 = tb.y0 + ICON_INSET + isz,
        };
    }

    pub fn toggleBox(self: *const Window) fb.Box {
        if (self.flags.no_titlebar or self.flags.no_toggle_size) return fb.Box.fromPosSize(0, 0, 0, 0);
        const tb = self.titlebarBox();
        const isz = self.iconSize();
        return .{
            .x0 = tb.x1 - ICON_INSET - isz,
            .y0 = tb.y0 + ICON_INSET,
            .x1 = tb.x1 - ICON_INSET,
            .y1 = tb.y0 + ICON_INSET + isz,
        };
    }

    pub fn resizeBox(self: *const Window) fb.Box {
        if (self.flags.no_resize) return fb.Box.fromPosSize(0, 0, 0, 0);
        const opx = self.outlinePx();
        const isz = self.iconSize();
        return .{
            .x0 = self.visible.x1 - opx - isz,
            .y0 = self.visible.y1 - opx - isz,
            .x1 = self.visible.x1 - opx,
            .y1 = self.visible.y1 - opx,
        };
    }

    pub fn contentBox(self: *const Window) fb.Box {
        const opx = self.outlinePx();
        const tbh = self.titlebarHeight();
        const carve = self.furnitureCarve();
        return .{
            .x0 = self.visible.x0 + opx,
            .y0 = self.visible.y0 + opx + tbh,
            .x1 = self.visible.x1 - opx - carve.x,
            .y1 = self.visible.y1 - opx - carve.y,
        };
    }

    fn vscrollColumn(self: *const Window) fb.Box {
        const opx = self.outlinePx();
        const isz = self.iconSize();
        const tb = self.titlebarBox();
        return .{
            .x0 = self.visible.x1 - opx - isz,
            .y0 = tb.y1,
            .x1 = self.visible.x1 - opx,
            .y1 = self.visible.y1 - opx - isz,
        };
    }

    pub fn vscrollUpBox(self: *const Window) fb.Box {
        if (self.flags.no_vscroll) return fb.Box.fromPosSize(0, 0, 0, 0);
        const col = self.vscrollColumn();
        const isz = self.iconSize();
        return .{
            .x0 = col.x0,
            .y0 = col.y0,
            .x1 = col.x1,
            .y1 = col.y0 + isz,
        };
    }

    pub fn vscrollDownBox(self: *const Window) fb.Box {
        if (self.flags.no_vscroll) return fb.Box.fromPosSize(0, 0, 0, 0);
        const col = self.vscrollColumn();
        const isz = self.iconSize();
        return .{
            .x0 = col.x0,
            .y0 = col.y1 - isz,
            .x1 = col.x1,
            .y1 = col.y1,
        };
    }

    pub fn vscrollWellBox(self: *const Window) fb.Box {
        if (self.flags.no_vscroll) return fb.Box.fromPosSize(0, 0, 0, 0);
        const col = self.vscrollColumn();
        const isz = self.iconSize();
        return .{
            .x0 = col.x0,
            .y0 = col.y0 + isz,
            .x1 = col.x1,
            .y1 = col.y1 - isz,
        };
    }

    pub fn vscrollSausageBox(self: *const Window) fb.Box {
        if (self.flags.no_vscroll) return fb.Box.fromPosSize(0, 0, 0, 0);
        const well = self.vscrollWellBox();
        const content = self.contentBox();
        const well_px = well.y1 - well.y0;
        const content_h = content.height();
        var doc_h = self.doc_height;
        if (doc_h < content_h) doc_h = content_h;

        var sausage_px = if (doc_h > 0) @as(i32, @intCast((@as(u64, @intCast(@max(0, well_px))) * content_h) / doc_h)) else well_px;
        if (sausage_px < MIN_SAUSAGE) sausage_px = MIN_SAUSAGE;
        if (sausage_px > well_px) sausage_px = well_px;

        var sausage_y0 = well.y0;
        if (doc_h > content_h and well_px > sausage_px) {
            const num = @as(i64, well_px - sausage_px) * @as(i64, self.scroll.y);
            const den = @as(i64, doc_h - content_h);
            sausage_y0 = well.y0 + @as(i32, @intCast(@divFloor(num, den)));
        }

        return .{
            .x0 = well.x0,
            .y0 = sausage_y0,
            .x1 = well.x1,
            .y1 = sausage_y0 + sausage_px,
        };
    }

    fn hscrollRow(self: *const Window) fb.Box {
        const opx = self.outlinePx();
        const isz = self.iconSize();
        return .{
            .x0 = self.visible.x0 + opx,
            .y0 = self.visible.y1 - opx - isz,
            .x1 = self.visible.x1 - opx - isz,
            .y1 = self.visible.y1 - opx,
        };
    }

    pub fn hscrollLeftBox(self: *const Window) fb.Box {
        if (self.flags.no_hscroll) return fb.Box.fromPosSize(0, 0, 0, 0);
        const row = self.hscrollRow();
        const isz = self.iconSize();
        return .{
            .x0 = row.x0,
            .y0 = row.y0,
            .x1 = row.x0 + isz,
            .y1 = row.y1,
        };
    }

    pub fn hscrollRightBox(self: *const Window) fb.Box {
        if (self.flags.no_hscroll) return fb.Box.fromPosSize(0, 0, 0, 0);
        const row = self.hscrollRow();
        const isz = self.iconSize();
        return .{
            .x0 = row.x1 - isz,
            .y0 = row.y0,
            .x1 = row.x1,
            .y1 = row.y1,
        };
    }

    pub fn hscrollWellBox(self: *const Window) fb.Box {
        if (self.flags.no_hscroll) return fb.Box.fromPosSize(0, 0, 0, 0);
        const row = self.hscrollRow();
        const isz = self.iconSize();
        return .{
            .x0 = row.x0 + isz,
            .y0 = row.y0,
            .x1 = row.x1 - isz,
            .y1 = row.y1,
        };
    }

    pub fn hscrollSausageBox(self: *const Window) fb.Box {
        if (self.flags.no_hscroll) return fb.Box.fromPosSize(0, 0, 0, 0);
        const well = self.hscrollWellBox();
        const content = self.contentBox();
        const well_px = well.x1 - well.x0;
        const content_w = content.width();
        var doc_w = self.doc_width;
        if (doc_w < content_w) doc_w = content_w;

        var sausage_px = if (doc_w > 0) @as(i32, @intCast((@as(u64, @intCast(@max(0, well_px))) * content_w) / doc_w)) else well_px;
        if (sausage_px < MIN_SAUSAGE) sausage_px = MIN_SAUSAGE;
        if (sausage_px > well_px) sausage_px = well_px;

        var sausage_x0 = well.x0;
        if (doc_w > content_w and well_px > sausage_px) {
            const num = @as(i64, well_px - sausage_px) * @as(i64, self.scroll.x);
            const den = @as(i64, doc_w - content_w);
            sausage_x0 = well.x0 + @as(i32, @intCast(@divFloor(num, den)));
        }

        return .{
            .x0 = sausage_x0,
            .y0 = well.y0,
            .x1 = sausage_x0 + sausage_px,
            .y1 = well.y1,
        };
    }

    pub fn hitTest(self: *const Window, p: fb.Point) FurnitureRegion {
        if (!self.visible.containsPoint(p)) return .none;

        if (!self.flags.no_titlebar) {
            if (!self.flags.no_back and self.backBox().containsPoint(p)) return .back;
            if (!self.flags.no_close and self.closeBox().containsPoint(p)) return .close;
            if (!self.flags.no_toggle_size and self.toggleBox().containsPoint(p)) return .toggle_size;
            if (self.titlebarBox().containsPoint(p)) return .title;
        }

        if (!self.flags.no_resize and self.resizeBox().containsPoint(p)) return .resize;

        if (!self.flags.no_vscroll) {
            if (self.vscrollUpBox().containsPoint(p)) return .vscroll_up;
            if (self.vscrollDownBox().containsPoint(p)) return .vscroll_down;
            if (self.vscrollSausageBox().containsPoint(p)) return .vscroll_sausage;
            if (self.vscrollWellBox().containsPoint(p)) return .vscroll_well;
        }

        if (!self.flags.no_hscroll) {
            if (self.hscrollLeftBox().containsPoint(p)) return .hscroll_left;
            if (self.hscrollRightBox().containsPoint(p)) return .hscroll_right;
            if (self.hscrollSausageBox().containsPoint(p)) return .hscroll_sausage;
            if (self.hscrollWellBox().containsPoint(p)) return .hscroll_well;
        }

        if (self.contentBox().containsPoint(p)) return .content;

        return .title;
    }

    pub fn notifyOpen(self: *Window) void {
        if (self.task.handle) |cb| {
            const ev = Event{ .kind = .open, .data = .{ .open = {} } };
            _ = cb(self, &ev, self.task.task_data) catch {};
        }
    }

    pub fn scrollClamp(self: *const Window, desired: fb.Point) fb.Point {
        const content = self.contentBox();
        const max_x = @max(0, @as(i32, @intCast(self.doc_width)) - @as(i32, @intCast(content.width())));
        const max_y = @max(0, @as(i32, @intCast(self.doc_height)) - @as(i32, @intCast(content.height())));
        return .{
            .x = std.math.clamp(desired.x, 0, max_x),
            .y = std.math.clamp(desired.y, 0, max_y),
        };
    }

    pub fn setScroll(self: *Window, p: fb.Point) void {
        const clamped = self.scrollClamp(p);
        if (clamped.x == self.scroll.x and clamped.y == self.scroll.y) return;
        self.scroll = clamped;
        self.invalidate(null);
        self.invalidateFurniture();
    }

    pub fn scrollStep(self: *Window, delta: fb.Point) void {
        self.setScroll(.{
            .x = self.scroll.x + delta.x,
            .y = self.scroll.y + delta.y,
        });
    }

    pub fn dragSausage(self: *Window, delta_px: i32, scroll_start: i32, horizontal: bool) void {
        const content = self.contentBox();
        if (horizontal) {
            const well = self.hscrollWellBox();
            const well_px = well.x1 - well.x0;
            const content_w = content.width();
            const doc_w = self.doc_width;
            const max_scroll = @max(0, @as(i32, @intCast(doc_w)) - @as(i32, @intCast(content_w)));
            if (well_px <= 0 or doc_w <= content_w) {
                self.setScroll(.{ .x = 0, .y = self.scroll.y });
            } else {
                const shift = @divFloor(@as(i64, delta_px) * @as(i64, doc_w), @as(i64, well_px));
                const new_scroll = std.math.clamp(scroll_start + @as(i32, @intCast(shift)), 0, max_scroll);
                self.setScroll(.{ .x = new_scroll, .y = self.scroll.y });
            }
        } else {
            const well = self.vscrollWellBox();
            const well_px = well.y1 - well.y0;
            const content_h = content.height();
            const doc_h = self.doc_height;
            const max_scroll = @max(0, @as(i32, @intCast(doc_h)) - @as(i32, @intCast(content_h)));
            if (well_px <= 0 or doc_h <= content_h) {
                self.setScroll(.{ .x = self.scroll.x, .y = 0 });
            } else {
                const shift = @divFloor(@as(i64, delta_px) * @as(i64, doc_h), @as(i64, well_px));
                const new_scroll = std.math.clamp(scroll_start + @as(i32, @intCast(shift)), 0, max_scroll);
                self.setScroll(.{ .x = self.scroll.x, .y = new_scroll });
            }
        }
    }

    pub fn dragResize(self: *Window, p: fb.Point) void {
        const content = self.contentBox();
        const width_val = std.math.clamp(p.x - content.x0, MIN_CONTENT, @as(i32, @intCast(self.doc_width)));
        const height_val = std.math.clamp(p.y - content.y0, MIN_CONTENT, @as(i32, @intCast(self.doc_height)));
        self.resizeTo(@intCast(width_val), @intCast(height_val));
    }

    pub fn moveTo(self: *Window, target_x: i32, target_y: i32, backbuffer: ?*fb.Surface) ?fb.Box {
        if (target_x == self.visible.x0 and target_y == self.visible.y0) return null;

        const before = self.visible;
        const w = self.width();
        const h = self.height();

        self.visible.x0 = target_x;
        self.visible.y0 = target_y;
        self.visible.x1 = target_x + @as(i32, @intCast(w));
        self.visible.y1 = target_y + @as(i32, @intCast(h));

        self.notifyOpen();

        if (backbuffer) |bb| {
            bb.copyBoxWithin(before, self.visible.x0, self.visible.y0);
            var slivers: [4]fb.Box = undefined;
            const count = fb.Box.subtract(before, self.visible, &slivers);
            for (slivers[0..count]) |sliver| {
                bb.fillBox(sliver, fb.Color.DESKTOP_BG);
            }
        }

        return before.unionWith(self.visible);
    }

    pub fn resizeTo(self: *Window, target_w: u32, target_h: u32) void {
        const clamped_w = @max(MIN_CONTENT, target_w);
        const clamped_h = @max(MIN_CONTENT, target_h);

        const opx = self.outlinePx();
        const tbh = self.titlebarHeight();
        const carve = self.furnitureCarve();

        self.visible.x1 = self.visible.x0 + @as(i32, @intCast(clamped_w)) + 2 * opx + carve.x;
        self.visible.y1 = self.visible.y0 + @as(i32, @intCast(clamped_h)) + tbh + 2 * opx + carve.y;
        self.toggled = false;

        self.notifyOpen();
    }

    pub fn toggleSize(self: *Window, scr_w: u32, scr_h: u32) void {
        if (self.toggled) {
            self.visible = self.pre_toggle;
            self.toggled = false;
        } else {
            const opx = self.outlinePx();
            const tbh = self.titlebarHeight();
            const carve = self.furnitureCarve();

            const avail_w = @as(i32, @intCast(scr_w)) - self.visible.x0 - 2 * opx - carve.x;
            const avail_h = @as(i32, @intCast(scr_h)) - self.visible.y0 - 2 * opx - tbh - carve.y;

            const w = std.math.clamp(@as(i32, @intCast(self.doc_width)), MIN_CONTENT, @max(MIN_CONTENT, avail_w));
            const h = std.math.clamp(@as(i32, @intCast(self.doc_height)), MIN_CONTENT, @max(MIN_CONTENT, avail_h));

            self.pre_toggle = self.visible;
            self.visible.x1 = self.visible.x0 + w + 2 * opx + carve.x;
            self.visible.y1 = self.visible.y0 + h + tbh + 2 * opx + carve.y;
            self.toggled = true;
        }

        self.setScroll(self.scroll);
        self.notifyOpen();
    }

    pub fn renderFurniture(self: *const Window, surface: *fb.Surface, clip_box: fb.Box) void {
        if (self.width() < 40 or self.height() < 30) return;

        // 1. Outer outline
        if (!self.flags.no_outline and self.visible.intersection(clip_box) != null) {
            surface.setClip(clip_box);
            surface.drawBoxOutline(self.visible, 1, fb.Color.BORDER_OUTLINE);
        }

        // 2. Titlebar
        if (!self.flags.no_titlebar) {
            const tb = self.titlebarBox();
            if (tb.intersection(clip_box)) |tb_clip| {
                surface.setClip(tb_clip);
                const tb_bg = if (self.is_active) fb.Color.TITLE_ACTIVE else fb.Color.TITLE_INACTIVE;
                surface.fillBox(tb, tb_bg);
                surface.drawBevel(tb, fb.Color.BEVEL_LIGHT, fb.Color.BEVEL_DARK, false);

                if (!self.flags.no_back) {
                    const back_btn = self.backBox();
                    surface.fillBox(back_btn, fb.Color.WINDOW_FRAME);
                    surface.drawBevel(back_btn, fb.Color.BEVEL_LIGHT, fb.Color.BEVEL_DARK, false);
                    sprites.Sprites.drawBackIcon(surface, back_btn);
                }

                if (!self.flags.no_close) {
                    const close_btn = self.closeBox();
                    surface.fillBox(close_btn, fb.Color.WINDOW_FRAME);
                    surface.drawBevel(close_btn, fb.Color.BEVEL_LIGHT, fb.Color.BEVEL_DARK, false);
                    sprites.Sprites.drawCloseIcon(surface, close_btn);
                }

                if (!self.flags.no_toggle_size) {
                    const max_btn = self.toggleBox();
                    surface.fillBox(max_btn, fb.Color.WINDOW_FRAME);
                    surface.drawBevel(max_btn, fb.Color.BEVEL_LIGHT, fb.Color.BEVEL_DARK, false);
                    sprites.Sprites.drawToggleIcon(surface, max_btn);
                }

                // Title text centered between icons
                var text_x0 = tb.x0 + 4;
                if (!self.flags.no_close) {
                    text_x0 = self.closeBox().x1 + 6;
                } else if (!self.flags.no_back) {
                    text_x0 = self.backBox().x1 + 6;
                }

                var text_x1 = tb.x1 - 4;
                if (!self.flags.no_toggle_size) {
                    text_x1 = self.toggleBox().x0 - 6;
                }

                if (text_x1 > text_x0 and self.title.len > 0) {
                    const tm = font.measureText(self.title, 1);
                    const avail: u32 = @intCast(text_x1 - text_x0);
                    const tx = if (tm.width < avail) text_x0 + @as(i32, @intCast((avail - tm.width) / 2)) else text_x0;
                    const ty = tb.y0 + @as(i32, @intCast((self.titlebar_h - font.GLYPH_HEIGHT) / 2));
                    font.drawText(surface, self.title, tx, ty, fb.Color.TEXT_BLACK);
                }
            }
        }

        // 3. Vertical Scrollbar
        if (!self.flags.no_vscroll) {
            const v_area = fb.Box{
                .x0 = self.vscrollUpBox().x0,
                .y0 = self.vscrollUpBox().y0,
                .x1 = self.vscrollDownBox().x1,
                .y1 = self.vscrollDownBox().y1,
            };
            if (v_area.intersection(clip_box)) |v_clip| {
                surface.setClip(v_clip);
                const ub = self.vscrollUpBox();
                surface.fillBox(ub, fb.Color.WINDOW_FRAME);
                surface.drawBevel(ub, fb.Color.BEVEL_LIGHT, fb.Color.BEVEL_DARK, false);
                sprites.Sprites.drawUpArrow(surface, ub);

                const db = self.vscrollDownBox();
                surface.fillBox(db, fb.Color.WINDOW_FRAME);
                surface.drawBevel(db, fb.Color.BEVEL_LIGHT, fb.Color.BEVEL_DARK, false);
                sprites.Sprites.drawDownArrow(surface, db);

                const wb = self.vscrollWellBox();
                surface.fillBox(wb, fb.Color.WINDOW_FRAME);
                surface.drawBevel(wb, fb.Color.BEVEL_LIGHT, fb.Color.BEVEL_DARK, true);

                const sb = self.vscrollSausageBox();
                surface.fillBox(sb, fb.Color.WINDOW_FRAME);
                surface.drawBevel(sb, fb.Color.BEVEL_LIGHT, fb.Color.BEVEL_DARK, false);
                sprites.Sprites.drawVerticalSausageGrip(surface, sb);
            }
        }

        // 4. Horizontal Scrollbar
        if (!self.flags.no_hscroll) {
            const h_area = fb.Box{
                .x0 = self.hscrollLeftBox().x0,
                .y0 = self.hscrollLeftBox().y0,
                .x1 = self.hscrollRightBox().x1,
                .y1 = self.hscrollRightBox().y1,
            };
            if (h_area.intersection(clip_box)) |h_clip| {
                surface.setClip(h_clip);
                const lb = self.hscrollLeftBox();
                surface.fillBox(lb, fb.Color.WINDOW_FRAME);
                surface.drawBevel(lb, fb.Color.BEVEL_LIGHT, fb.Color.BEVEL_DARK, false);
                sprites.Sprites.drawLeftArrow(surface, lb);

                const rb = self.hscrollRightBox();
                surface.fillBox(rb, fb.Color.WINDOW_FRAME);
                surface.drawBevel(rb, fb.Color.BEVEL_LIGHT, fb.Color.BEVEL_DARK, false);
                sprites.Sprites.drawRightArrow(surface, rb);

                const wb = self.hscrollWellBox();
                surface.fillBox(wb, fb.Color.WINDOW_FRAME);
                surface.drawBevel(wb, fb.Color.BEVEL_LIGHT, fb.Color.BEVEL_DARK, true);

                const sb = self.hscrollSausageBox();
                surface.fillBox(sb, fb.Color.WINDOW_FRAME);
                surface.drawBevel(sb, fb.Color.BEVEL_LIGHT, fb.Color.BEVEL_DARK, false);
                sprites.Sprites.drawHorizontalSausageGrip(surface, sb);
            }
        }

        // 5. Resize Corner Grip
        if (!self.flags.no_resize) {
            const gb = self.resizeBox();
            if (gb.intersection(clip_box)) |g_clip| {
                surface.setClip(g_clip);
                surface.fillBox(gb, fb.Color.WINDOW_FRAME);
                surface.drawBevel(gb, fb.Color.BEVEL_LIGHT, fb.Color.BEVEL_DARK, false);
                var g: i32 = 4;
                while (g < gb.width() - 2) : (g += 3) {
                    surface.setPixel(gb.x1 - g, gb.y0 + g, fb.Color.BEVEL_DARK);
                    surface.setPixel(gb.x1 - g - 1, gb.y0 + g, fb.Color.BEVEL_LIGHT);
                }
            }
        }

        surface.resetClip();
    }

    pub fn renderContentPiece(self: *const Window, surface: *fb.Surface, piece: fb.Box) void {
        const cb = self.contentBox();
        surface.setClip(piece);

        if (self.task.bg) |bg_col| {
            surface.fillBox(cb, bg_col);
            surface.drawBevel(cb, fb.Color.BEVEL_LIGHT, fb.Color.BEVEL_DARK, true);
        }

        if (self.task.handle) |handler| {
            const ev = Event{
                .kind = .redraw,
                .data = .{
                    .redraw = .{
                        .surface = surface,
                        .content = piece,
                        .bounds = cb,
                        .scroll = self.scroll,
                    },
                },
            };
            _ = handler(@constCast(self), &ev, self.task.task_data) catch {};
        }

        surface.resetClip();
    }

    pub fn render(self: *const Window, surface: *fb.Surface) void {
        self.renderFurniture(surface, self.visible);
        self.renderContentPiece(surface, self.contentBox());
    }
};

test "window: wuss geometry and hit testing" {
    const testing = std.testing;
    const task = Task{};
    var win = Window.init(100, 100, 400, 300, "Wuss Test", WindowFlags.none, task, 800, 600);

    const cb = win.contentBox();
    try testing.expectEqual(@as(i32, 100), cb.x0);
    try testing.expectEqual(@as(i32, 100), cb.y0);
    try testing.expectEqual(@as(u32, 400), cb.width());
    try testing.expectEqual(@as(u32, 300), cb.height());

    // Hit test regions
    try testing.expectEqual(FurnitureRegion.back, win.hitTest(.{ .x = win.backBox().x0 + 2, .y = win.backBox().y0 + 2 }));
    try testing.expectEqual(FurnitureRegion.close, win.hitTest(.{ .x = win.closeBox().x0 + 2, .y = win.closeBox().y0 + 2 }));
    try testing.expectEqual(FurnitureRegion.toggle_size, win.hitTest(.{ .x = win.toggleBox().x0 + 2, .y = win.toggleBox().y0 + 2 }));
    try testing.expectEqual(FurnitureRegion.resize, win.hitTest(.{ .x = win.resizeBox().x0 + 2, .y = win.resizeBox().y0 + 2 }));
    try testing.expectEqual(FurnitureRegion.vscroll_up, win.hitTest(.{ .x = win.vscrollUpBox().x0 + 2, .y = win.vscrollUpBox().y0 + 2 }));
    try testing.expectEqual(FurnitureRegion.vscroll_down, win.hitTest(.{ .x = win.vscrollDownBox().x0 + 2, .y = win.vscrollDownBox().y0 + 2 }));
    try testing.expectEqual(FurnitureRegion.content, win.hitTest(.{ .x = cb.x0 + 20, .y = cb.y0 + 20 }));
    try testing.expectEqual(FurnitureRegion.none, win.hitTest(.{ .x = 10, .y = 10 }));
}

test "window: scrolling and sausage math" {
    const testing = std.testing;
    var win = Window.init(0, 0, 200, 200, "Scroll Test", WindowFlags.none, .{}, 400, 600);

    // Initial scroll at top
    try testing.expectEqual(@as(i32, 0), win.scroll.y);
    const s0 = win.vscrollSausageBox();
    const w0 = win.vscrollWellBox();
    try testing.expectEqual(w0.y0, s0.y0);

    // Step scroll
    win.scrollStep(.{ .x = 0, .y = 100 });
    try testing.expectEqual(@as(i32, 100), win.scroll.y);
    const s1 = win.vscrollSausageBox();
    try testing.expect(s1.y0 > w0.y0);

    // Clamping to doc extents
    win.scrollStep(.{ .x = 0, .y = 10000 });
    try testing.expectEqual(@as(i32, 400), win.scroll.y); // 600 - 200 = 400
}



