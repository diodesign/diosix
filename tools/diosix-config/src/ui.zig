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

pub const Rect = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        const w_i32: i32 = @intCast(@min(self.w, std.math.maxInt(i32)));
        const h_i32: i32 = @intCast(@min(self.h, std.math.maxInt(i32)));
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
        const x_start = @max(0, rect.x);
        const y_start = @max(0, rect.y);
        const cw_i32: i32 = @intCast(@min(self.width, std.math.maxInt(i32)));
        const ch_i32: i32 = @intCast(@min(self.height, std.math.maxInt(i32)));
        const rw_i32: i32 = @intCast(@min(rect.w, std.math.maxInt(i32)));
        const rh_i32: i32 = @intCast(@min(rect.h, std.math.maxInt(i32)));
        const x_end = @min(cw_i32, rect.x +| rw_i32);
        const y_end = @min(ch_i32, rect.y +| rh_i32);

        if (x_start >= x_end or y_start >= y_end) return;

        var y = y_start;
        while (y < y_end) : (y += 1) {
            const row = @as(usize, @intCast(y)) * self.width;
            var x = x_start;
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
        const t: i32 = @intCast(@min(thickness, std.math.maxInt(i32)));
        const rw_i32: i32 = @intCast(@min(rect.w, std.math.maxInt(i32)));
        const rh_i32: i32 = @intCast(@min(rect.h, std.math.maxInt(i32)));

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
    cid: usize,
    vcpus: usize,
    ram_mb: usize,
    is_running: bool,
    is_trusted: bool,
    disk: ?[]const u8 = null,

    pub fn render(self: *const VmCard, canvas: *Canvas, rect: Rect) void {
        // Card body.
        canvas.fillRect(rect, Color.CARD_BG);
        canvas.drawOutline(rect, 1, Color.CARD_BORDER);

        // Trust badge indicator on left edge.
        const badge_color =
            if (self.is_trusted) Color.ACCENT_GREEN else Color.ACCENT_BLUE;
        canvas.fillRect(
            .{ .x = rect.x, .y = rect.y, .w = 4, .h = rect.h },
            badge_color,
        );

        // Status indicator dot.
        const status_color =
            if (self.is_running) Color.ACCENT_GREEN else Color.TEXT_MUTED;
        canvas.fillRect(
            .{ .x = rect.x +| 12, .y = rect.y +| 12, .w = 8, .h = 8 },
            status_color,
        );

        // Action button: Start / Stop.
        const btn_color =
            if (self.is_running) Color.ACCENT_RED else Color.ACCENT_GREEN;
        const rw_i32: i32 = @intCast(@min(rect.w, std.math.maxInt(i32)));
        const btn_rect = Rect{
            .x = rect.x +| rw_i32 -| 80,
            .y = rect.y +| 10,
            .w = 70,
            .h = 24,
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
