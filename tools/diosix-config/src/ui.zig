// Diosix Configuration Manager UI Primitives.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const Color = struct {
    pub const BG: u32 = 0xff181820;
    pub const SIDEBAR_BG: u32 = 0xff121216;
    pub const CARD_BG: u32 = 0xff22222c;
    pub const CARD_BORDER: u32 = 0xff2e2e3c;
    pub const ACCENT_GREEN: u32 = 0xff2ecc71;
    pub const ACCENT_BLUE: u32 = 0xff3498db;
    pub const ACCENT_RED: u32 = 0xffe74c3c;
    pub const TEXT_TITLE: u32 = 0xffffffff;
    pub const TEXT_BODY: u32 = 0xffc0c0d0;
    pub const TEXT_MUTED: u32 = 0xff7a7a8c;
};

pub const Layout = struct {
    pub const DEFAULT_WINDOW_WIDTH: u32 = 800;
    pub const DEFAULT_WINDOW_HEIGHT: u32 = 500;
    pub const SIDEBAR_WIDTH: u32 = 180;
    pub const SIDEBAR_MARGIN_X: i32 = 10;
    pub const SIDEBAR_PADDING_W: u32 = 20;
    pub const TAB_START_Y: i32 = 20;
    pub const TAB_HEIGHT: u32 = 36;
    pub const TAB_GAP: u32 = 8;
    pub const TAB_INDICATOR_W: u32 = 4;
    pub const TAB_COUNT: usize = 4;
    pub const CONTENT_MARGIN: u32 = 20;
    pub const CARD_HEIGHT: u32 = 50;
    pub const CARD_GAP: u32 = 12;
    pub const CARD_BORDER_WIDTH: u32 = 1;
    pub const BADGE_WIDTH: u32 = 4;
    pub const STATUS_DOT_OFFSET_X: i32 = 12;
    pub const STATUS_DOT_OFFSET_Y: i32 = 12;
    pub const STATUS_DOT_SIZE: u32 = 8;
    pub const BTN_OFFSET_RIGHT: i32 = 80;
    pub const BTN_OFFSET_Y: i32 = 10;
    pub const BTN_WIDTH: u32 = 70;
    pub const BTN_HEIGHT: u32 = 24;
};

const MAX_I32_AS_U32: u32 = @intCast(std.math.maxInt(i32));

pub const Rect = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        const w_u32: u32 = @min(self.w, MAX_I32_AS_U32);
        const h_u32: u32 = @min(self.h, MAX_I32_AS_U32);
        const w_i32: i32 = @intCast(w_u32);
        const h_i32: i32 = @intCast(h_u32);
        return px >= self.x and px < self.x +| w_i32 and
            py >= self.y and py < self.y +| h_i32;
    }
};

pub const Canvas = struct {
    width: u32,
    height: u32,
    pixels: []u32,

    pub fn init(allocator: std.mem.Allocator, w: u32, h: u32) !Canvas {
        const count = try std.math.mul(usize, w, h);
        const p = try allocator.alloc(u32, count);
        @memset(p, Color.BG);
        return Canvas{
            .width = w,
            .height = h,
            .pixels = p,
        };
    }

    pub fn deinit(self: *Canvas, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    pub fn fillRect(self: *Canvas, rect: Rect, color: u32) void {
        const x_start: i32 = @max(@as(i32, 0), rect.x);
        const y_start: i32 = @max(@as(i32, 0), rect.y);
        const cw_u32: u32 = @min(self.width, MAX_I32_AS_U32);
        const ch_u32: u32 = @min(self.height, MAX_I32_AS_U32);
        const rw_u32: u32 = @min(rect.w, MAX_I32_AS_U32);
        const rh_u32: u32 = @min(rect.h, MAX_I32_AS_U32);
        const cw_i32: i32 = @intCast(cw_u32);
        const ch_i32: i32 = @intCast(ch_u32);
        const rw_i32: i32 = @intCast(rw_u32);
        const rh_i32: i32 = @intCast(rh_u32);
        const x_end: i32 = @min(cw_i32, rect.x +| rw_i32);
        const y_end: i32 = @min(ch_i32, rect.y +| rh_i32);

        if (x_start >= x_end or y_start >= y_end) return;

        var y: i32 = y_start;
        while (y < y_end) : (y += 1) {
            const row = @as(usize, @intCast(y)) * self.width;
            var x: i32 = x_start;
            while (x < x_end) : (x += 1) {
                self.pixels[row + @as(usize, @intCast(x))] = color;
            }
        }
    }

    pub fn drawOutline(
        self: *Canvas,
        rect: Rect,
        thickness: u32,
        color: u32,
    ) void {
        const t_u32: u32 = @min(thickness, MAX_I32_AS_U32);
        const rw_u32: u32 = @min(rect.w, MAX_I32_AS_U32);
        const rh_u32: u32 = @min(rect.h, MAX_I32_AS_U32);
        const t: i32 = @intCast(t_u32);
        const rw_i32: i32 = @intCast(rw_u32);
        const rh_i32: i32 = @intCast(rh_u32);

        self.fillRect(
            .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = thickness },
            color,
        );
        self.fillRect(
            .{
                .x = rect.x,
                .y = rect.y +| rh_i32 -| t,
                .w = rect.w,
                .h = thickness,
            },
            color,
        );
        self.fillRect(
            .{ .x = rect.x, .y = rect.y, .w = thickness, .h = rect.h },
            color,
        );
        self.fillRect(
            .{
                .x = rect.x +| rw_i32 -| t,
                .y = rect.y,
                .w = thickness,
                .h = rect.h,
            },
            color,
        );
    }
};

pub const Tab = enum {
    dashboard,
    vms,
    storage,
    network,
};

pub const VmCard = struct {
    name: []const u8,
    cid: u32,
    vcpus: u32,
    ram_mb: u32,
    is_running: bool,
    is_trusted: bool,
    disk: ?[]const u8 = null,

    pub fn render(self: *const VmCard, canvas: *Canvas, rect: Rect) void {
        // Card body.
        canvas.fillRect(rect, Color.CARD_BG);
        canvas.drawOutline(rect, Layout.CARD_BORDER_WIDTH, Color.CARD_BORDER);

        // Trust badge indicator on left edge.
        const badge_color =
            if (self.is_trusted) Color.ACCENT_GREEN else Color.ACCENT_BLUE;
        canvas.fillRect(
            .{
                .x = rect.x,
                .y = rect.y,
                .w = Layout.BADGE_WIDTH,
                .h = rect.h,
            },
            badge_color,
        );

        // Status indicator dot.
        const status_color =
            if (self.is_running) Color.ACCENT_GREEN else Color.TEXT_MUTED;
        canvas.fillRect(
            .{
                .x = rect.x +| Layout.STATUS_DOT_OFFSET_X,
                .y = rect.y +| Layout.STATUS_DOT_OFFSET_Y,
                .w = Layout.STATUS_DOT_SIZE,
                .h = Layout.STATUS_DOT_SIZE,
            },
            status_color,
        );

        // Action button: Start / Stop.
        const btn_color =
            if (self.is_running) Color.ACCENT_RED else Color.ACCENT_GREEN;
        const rw_u32: u32 = @min(rect.w, MAX_I32_AS_U32);
        const rw_i32: i32 = @intCast(rw_u32);
        const btn_rect = Rect{
            .x = rect.x +| rw_i32 -| Layout.BTN_OFFSET_RIGHT,
            .y = rect.y +| Layout.BTN_OFFSET_Y,
            .w = Layout.BTN_WIDTH,
            .h = Layout.BTN_HEIGHT,
        };
        canvas.fillRect(btn_rect, btn_color);
    }
};

test "ui: Rect.contains and Canvas clipping" {
    const testing = std.testing;
    const r = Rect{ .x = 10, .y = 20, .w = 30, .h = 40 };
    try testing.expect(r.contains(10, 20));
    try testing.expect(r.contains(39, 59));
    try testing.expect(!r.contains(40, 20));
    try testing.expect(!r.contains(9, 20));

    var canvas = try Canvas.init(testing.allocator, 32, 32);
    defer canvas.deinit(testing.allocator);
    canvas.fillRect(.{ .x = -5, .y = -5, .w = 10, .h = 10 }, Color.ACCENT_BLUE);
    try testing.expectEqual(Color.ACCENT_BLUE, canvas.pixels[0]);
}

test {
    std.testing.refAllDecls(@This());
}
