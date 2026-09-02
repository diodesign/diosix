const std = @import("std");

pub const Color = struct {
    pub const BG: u32 = 0xFF181820;
    pub const SIDEBAR_BG: u32 = 0xFF121216;
    pub const CARD_BG: u32 = 0xFF22222C;
    pub const CARD_BORDER: u32 = 0xFF2E2E3C;
    pub const ACCENT_GREEN: u32 = 0xFF2ECC71;
    pub const ACCENT_BLUE: u32 = 0xFF3498DB;
    pub const ACCENT_RED: u32 = 0xFFE74C3C;
    pub const TEXT_TITLE: u32 = 0xFFFFFFFF;
    pub const TEXT_BODY: u32 = 0xFFC0C0D0;
    pub const TEXT_MUTED: u32 = 0xFF7A7A8C;
};

pub const Rect = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and px < self.x + @as(i32, @intCast(self.w)) and
               py >= self.y and py < self.y + @as(i32, @intCast(self.h));
    }
};

pub const Canvas = struct {
    width: u32,
    height: u32,
    pixels: []u32,

    pub fn init(allocator: std.mem.Allocator, w: u32, h: u32) !Canvas {
        const p = try allocator.alloc(u32, w * h);
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
        const x_end = @min(@as(i32, @intCast(self.width)), rect.x + @as(i32, @intCast(rect.w)));
        const y_end = @min(@as(i32, @intCast(self.height)), rect.y + @as(i32, @intCast(rect.h)));

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

    pub fn drawOutline(self: *Canvas, rect: Rect, thickness: u32, color: u32) void {
        const t = @as(i32, @intCast(thickness));
        self.fillRect(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = thickness }, color);
        self.fillRect(.{ .x = rect.x, .y = rect.y + @as(i32, @intCast(rect.h)) - t, .w = rect.w, .h = thickness }, color);
        self.fillRect(.{ .x = rect.x, .y = rect.y, .w = thickness, .h = rect.h }, color);
        self.fillRect(.{ .x = rect.x + @as(i32, @intCast(rect.w)) - t, .y = rect.y, .w = thickness, .h = rect.h }, color);
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
        // Card Body
        canvas.fillRect(rect, Color.CARD_BG);
        canvas.drawOutline(rect, 1, Color.CARD_BORDER);

        // Trust badge indicator on left edge
        const badge_color = if (self.is_trusted) Color.ACCENT_GREEN else Color.ACCENT_BLUE;
        canvas.fillRect(.{ .x = rect.x, .y = rect.y, .w = 4, .h = rect.h }, badge_color);

        // Status Indicator Dot
        const status_color = if (self.is_running) Color.ACCENT_GREEN else Color.TEXT_MUTED;
        canvas.fillRect(.{ .x = rect.x + 12, .y = rect.y + 12, .w = 8, .h = 8 }, status_color);

        // Action Button: Start / Stop
        const btn_color = if (self.is_running) Color.ACCENT_RED else Color.ACCENT_GREEN;
        const btn_rect = Rect{
            .x = rect.x + @as(i32, @intCast(rect.w)) - 80,
            .y = rect.y + 10,
            .w = 70,
            .h = 24,
        };
        canvas.fillRect(btn_rect, btn_color);
    }
};
