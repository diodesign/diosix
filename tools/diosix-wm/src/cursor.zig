const std = @import("std");
const fb = @import("framebuffer.zig");

// Classic Acorn RISC OS 16x20 Pointer
pub const POINTER_WIDTH: u32 = 16;
pub const POINTER_HEIGHT: u32 = 20;

const K = fb.Color.BLACK;
const C = fb.Color.POINTER_CYAN;
const B = fb.Color.POINTER_BLUE;
const T = 0x00000000; // Transparent

pub const POINTER_PIXELS = [_]u32{
    K, T, T, T, T, T, T, T, T, T, T, T, T, T, T, T,
    K, K, T, T, T, T, T, T, T, T, T, T, T, T, T, T,
    K, C, K, T, T, T, T, T, T, T, T, T, T, T, T, T,
    K, C, B, K, T, T, T, T, T, T, T, T, T, T, T, T,
    K, C, B, B, K, T, T, T, T, T, T, T, T, T, T, T,
    K, C, B, B, B, K, T, T, T, T, T, T, T, T, T, T,
    K, C, B, B, B, B, K, T, T, T, T, T, T, T, T, T,
    K, C, B, B, B, B, B, K, T, T, T, T, T, T, T, T,
    K, C, B, B, B, B, B, B, K, T, T, T, T, T, T, T,
    K, C, B, B, B, B, B, B, B, K, T, T, T, T, T, T,
    K, C, B, B, B, B, B, B, B, B, K, T, T, T, T, T,
    K, C, B, B, B, B, K, K, K, K, K, K, T, T, T, T,
    K, C, B, B, K, C, B, K, T, T, T, T, T, T, T, T,
    K, C, B, K, T, K, C, B, K, T, T, T, T, T, T, T,
    K, K, K, T, T, T, K, C, B, K, T, T, T, T, T, T,
    K, T, T, T, T, T, T, K, C, B, K, T, T, T, T, T,
    T, T, T, T, T, T, T, T, K, C, B, K, T, T, T, T,
    T, T, T, T, T, T, T, T, T, K, K, K, T, T, T, T,
    T, T, T, T, T, T, T, T, T, T, T, T, T, T, T, T,
    T, T, T, T, T, T, T, T, T, T, T, T, T, T, T, T,
};

pub const Cursor = struct {
    x: i32 = 400,
    y: i32 = 300,
    drawn: bool = false,

    pub fn getBox(self: *const Cursor) fb.Box {
        return fb.Box.fromPosSize(self.x, self.y, POINTER_WIDTH, POINTER_HEIGHT);
    }

    pub fn getRect(self: *const Cursor) fb.Rect {
        return .{ .x = self.x, .y = self.y, .width = POINTER_WIDTH, .height = POINTER_HEIGHT };
    }

    pub fn drawSprite(screen: *fb.Surface, x: i32, y: i32) void {
        const x_start = @max(0, x);
        const y_start = @max(0, y);
        const x_end = @min(@as(i32, @intCast(screen.width)), x + @as(i32, @intCast(POINTER_WIDTH)));
        const y_end = @min(@as(i32, @intCast(screen.height)), y + @as(i32, @intCast(POINTER_HEIGHT)));
        if (x_start >= x_end or y_start >= y_end) return;

        var py = y_start;
        while (py < y_end) : (py += 1) {
            const src_row = @as(usize, @intCast(py - y)) * POINTER_WIDTH;
            const dst_row = @as(usize, @intCast(py)) * screen.width;
            var px = x_start;
            while (px < x_end) : (px += 1) {
                const pixel = POINTER_PIXELS[src_row + @as(usize, @intCast(px - x))];
                if ((pixel >> 24) != 0) {
                    screen.pixels[dst_row + @as(usize, @intCast(px))] = pixel;
                }
            }
        }
    }

    pub fn erase(self: *Cursor, screen: *fb.Surface, backbuffer: *const fb.Surface) void {
        if (!self.drawn) return;
        screen.copyBoxFrom(backbuffer, self.getBox());
        self.drawn = false;
    }

    pub fn draw(self: *Cursor, screen: *fb.Surface) void {
        drawSprite(screen, self.x, self.y);
        self.drawn = true;
    }

    pub fn moveTo(
        self: *Cursor,
        screen: *fb.Surface,
        backbuffer: *const fb.Surface,
        new_x: i32,
        new_y: i32,
    ) bool {
        if (self.drawn and new_x == self.x and new_y == self.y) return false;

        // Erase old cursor from backbuffer
        if (self.drawn) {
            screen.copyBoxFrom(backbuffer, self.getBox());
        }

        self.x = new_x;
        self.y = new_y;

        // Draw cursor at new position
        drawSprite(screen, self.x, self.y);
        self.drawn = true;
        return true;
    }
};

test "cursor: moveTo and erase with pristine restoration" {
    const testing = std.testing;
    var screen = try fb.Surface.init(testing.allocator, 100, 100);
    defer screen.deinit(testing.allocator);
    var bb = try fb.Surface.init(testing.allocator, 100, 100);
    defer bb.deinit(testing.allocator);

    // Fill backbuffer with pattern
    bb.clear(fb.Color.DESKTOP_BG);
    screen.copyBoxFrom(&bb, fb.Box{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 100 });

    var cursor = Cursor{ .x = 10, .y = 10 };
    cursor.draw(&screen);
    try testing.expect(cursor.drawn);
    // Tip at (10, 10) is black
    try testing.expectEqual(fb.Color.BLACK, screen.pixels[10 * 100 + 10]);

    // Move to (20, 20)
    const moved = cursor.moveTo(&screen, &bb, 20, 20);
    try testing.expect(moved);
    // Old position restored to DESKTOP_BG
    try testing.expectEqual(fb.Color.DESKTOP_BG, screen.pixels[10 * 100 + 10]);
    // New position has black tip
    try testing.expectEqual(fb.Color.BLACK, screen.pixels[20 * 100 + 20]);

    // Erase cursor completely
    cursor.erase(&screen, &bb);
    try testing.expect(!cursor.drawn);
    try testing.expectEqual(fb.Color.DESKTOP_BG, screen.pixels[20 * 100 + 20]);
}

